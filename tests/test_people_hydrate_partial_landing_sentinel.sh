#!/usr/bin/env bash
# A partial people-sweep landing must not write a success sentinel
# =========================================================================
#
# Behavioural test. Extracts the REAL hydrate_people message + sentinel
# block from install.sh and executes it, so this cannot pass against a
# copy of the logic.
#
# THE DEFECT, measured on a real customer install ten hours after it
# completed: graph 8679 Person nodes, vector store 8643 points, a gap of
# 36 that never closed. ingest_people_to_qdrant's own upsert helper drops
# any point with an empty vector and keeps going after a failed chunk, so
# a partial sweep still exits its python invocation at rc=0 -- the ONLY
# thing install.sh used to read to decide the sentinel. sent=8643 is
# neither zero (the pre-existing all-zero guard) nor a process failure
# (rc=0), so it fell all the way through to the plain success recorder and
# the sentinel's multi-day freshness window suppressed the retry that
# would otherwise have picked the 36 back up.
#
# THE FIX install.sh now carries: compare 'sent' against 'total' (both
# read from the same JSON ingest_people_to_qdrant already returns) and
# treat a shortfall as an error for sentinel purposes, via a THIRD arm
# alongside "process failed" and "process succeeded" -- "process
# succeeded but did not fully land".
#
# Control (0) pins the pre-fix shape: sent=8643 with total unset/absent
# (as every OTHER hydrate source's JSON looks today) must still read as
# a plain success, so this test cannot pass merely by making the sentinel
# stricter across the board.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

FAILURES=0
CHECKS=0
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS  $*"; }
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }

# --- extract the REAL block, not a copy -------------------------------------
HARNESS="$(mktemp -d -t peoplepartialsentinel-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

extract_block() {
    # Print install.sh from the line CONTAINING $1 (inclusive) to the line
    # BEFORE the line CONTAINING $2 (exclusive). Plain substring match
    # (awk index(), not a regex) so the shell brackets and dollar signs in
    # the anchors need no regex escaping, and anchored on the CONSTRUCT'S
    # OWN TEXT rather than a line number, so this survives any edit that
    # shifts where the block sits in the file.
    awk -v startpat="$1" -v endpat="$2" '
        index($0, endpat) > 0 && inside { exit }
        index($0, startpat) > 0 { inside = 1 }
        inside { print }
    ' "$INSTALL"
}

BLOCK="$(extract_block \
    'if [[ "$_HYDRATE_PEOPLE_TIMED_OUT" == "true" ]]; then' \
    'unset _HYDRATE_PEOPLE_TIMED_OUT _HYDRATE_PEOPLE_JSON')"

if [[ -z "$BLOCK" ]]; then
    echo "CANNOT-RUN: could not extract the hydrate_people message+sentinel block from install.sh." >&2
    echo "  This test drives the REAL block; it refuses to run against a copy." >&2
    exit 2
fi

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

{
    printf '_HYDRATE_SENTINEL_DIR="%s/state"\n' "$HARNESS"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    # Stubs for callables the block reaches that are irrelevant to what
    # this test measures (the customer-facing message text and the GUI
    # step log), and for MSG_* catalogue entries the block prints.
    printf 'gui_step_record_rc() { :; }\n'
    printf 'ok() { printf "OK:%%s\\n" "$1" >> "%s/messages.log"; }\n' "$HARNESS"
    printf 'info() { printf "INFO:%%s\\n" "$1" >> "%s/messages.log"; }\n' "$HARNESS"
    printf 'warn() { printf "WARN:%%s\\n" "$1" >> "%s/messages.log"; }\n' "$HARNESS"
    printf '_hydrate_qdrant_points() { printf "0"; }\n'
    printf 'MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="background"\n'
    printf 'MSG_HYDRATE_PEOPLE_DONE="done %%s"\n'
    printf 'MSG_HYDRATE_PEOPLE_PARTIAL="partial %%s of %%s"\n'
    printf 'MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="no data"\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_payload_is_all_zero
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
} > "$HARNESS/helpers.sh"

# THE RUNNABLE BLOCK IS A SEPARATE FILE, sourced ON TOP of helpers.sh only
# when a case actually wants to execute it. Appending the block to
# helpers.sh itself would re-run it every time helpers.sh is sourced --
# including the freshness check below, which wants to READ the sentinel a
# prior case wrote, not silently overwrite it with a second, unset-variable
# run of the same block.
cp "$HARNESS/helpers.sh" "$HARNESS/run_block.sh"
printf '%s\n' "$BLOCK" >> "$HARNESS/run_block.sh"

for fn in _hydrate_sentinel_fresh _hydrate_payload_is_all_zero \
          _hydrate_sentinel_record _hydrate_sentinel_record_error; do
    if ! grep -q "^${fn}() {" "$HARNESS/helpers.sh"; then
        echo "CANNOT-RUN: could not extract $fn from install.sh." >&2
        exit 2
    fi
done

bash -n "$HARNESS/run_block.sh" || { echo "CANNOT-RUN: extracted block does not parse" >&2; exit 2; }

echo "test_people_hydrate_partial_landing_sentinel.sh"

# run_people_case <_HYDRATE_PEOPLE_TIMED_OUT> <_HYDRATE_PEOPLE_JSON> <_HYDRATE_PEOPLE_RC>
# Executes the REAL extracted block fresh each time (a new subshell sourcing
# run_block.sh, so no variable leaks between cases) and prints the resulting
# sentinel's status line, or NONE if no sentinel file was written. The block
# hardcodes the sentinel source name "people", so every case shares that one
# file and each run clears it first.
run_people_case() {
    local timedout="$1" json="$2" rc="$3"
    rm -f "${HARNESS}/state/people.done" "${HARNESS}/messages.log"
    (
        _HYDRATE_PEOPLE_TIMED_OUT="$timedout"
        _HYDRATE_PEOPLE_JSON="$json"
        _HYDRATE_PEOPLE_RC="$rc"
        source "$HARNESS/run_block.sh"
    ) 2>>"${HARNESS}/stderr.log"
    if [[ -f "${HARNESS}/state/people.done" ]]; then
        grep '^status=' "${HARNESS}/state/people.done"
    else
        echo "status=NONE"
    fi
}

# freshness_of_last_sentinel: calls the REAL _hydrate_sentinel_fresh against
# whatever run_people_case most recently wrote, WITHOUT re-executing the
# block (sourcing run_block.sh a second time would re-run it with none of
# the case's variables set, silently overwriting the very file this is
# meant to read). helpers.sh carries the functions only, not the block.
freshness_of_last_sentinel() {
    bash -c "source '$HARNESS/helpers.sh'; _hydrate_sentinel_fresh people"
    echo "$?"
}

# (1) THE DEFECT'S EXACT MEASURED SHAPE. sent=8643, total=8679, rc=0.
out="$(run_people_case false '{"status":"error","reason":"partial_landing","sent":8643,"total":8679}' 0)"
check "(1) a partial landing (8643 of 8679, rc=0) does NOT record status=ok" \
    "$out" "status=error"

# (2) The sentinel is consequently NOT fresh, so the retry is not
#     suppressed -- the customer-visible half of the defect. Reuses the
#     file case (1) just wrote; does NOT re-run the block.
run_people_case false '{"status":"error","reason":"partial_landing","sent":8643,"total":8679}' 0 >/dev/null
rc2="$(freshness_of_last_sentinel)"
check "(2) a partial-landing sentinel is NOT fresh, so the next run retries" "$rc2" "1"

# (3) CONTROL: a FULL landing (sent == total) is still a plain success.
out="$(run_people_case false '{"status":"ok","sent":8679,"total":8679}' 0)"
check "(3) CONTROL a complete landing (8679 of 8679) still records status=ok" \
    "$out" "status=ok"

# (4) CONTROL: the pre-existing ALL-ZERO guard is untouched. sent=0 must
#     still demote to no_data (not ok, and not newly promoted to error
#     either -- this is _hydrate_payload_is_all_zero's job, unchanged).
out="$(run_people_case false '{"status":"error","sent":0,"total":10}' 0)"
check "(4) CONTROL a zero landing (0 of 10) still records status=no_data" \
    "$out" "status=no_data"

# (5) CONTROL: a real process failure (rc!=0) is still an error, exactly
#     as before -- this must take priority over the new partial check even
#     when the (empty) JSON carries no total at all.
out="$(run_people_case false '' 78)"
check "(5) CONTROL a process failure (rc=78) still records status=error" \
    "$out" "status=error"

# (6) THE SHAPE THAT MUST NOT REGRESS. If 'total' is ABSENT from the JSON
#     entirely (every OTHER hydrate source's shape today, and this
#     source's own shape before this fix), sent=8643 alone must still
#     read as a plain, complete success -- proving this fix compares
#     sent-to-total rather than merely getting stricter about a raw count.
out="$(run_people_case false '{"status":"ok","sent":8643}' 0)"
check "(6) CONTROL sent alone with no 'total' in the payload is still status=ok" \
    "$out" "status=ok"

# (7) The customer-facing message on a partial landing is the PARTIAL
#     string, not the DONE string claiming full delivery.
run_people_case false '{"status":"error","reason":"partial_landing","sent":8643,"total":8679}' 0 >/dev/null
if grep -q '^WARN:partial 8643 of 8679$' "${HARNESS}/messages.log" 2>/dev/null; then
    pass "(7) the customer message says 'partial 8643 of 8679', not 'done'"
else
    fail "(7) the customer message did not report the partial shape: $(cat "${HARNESS}/messages.log" 2>/dev/null)"
fi
CHECKS=$((CHECKS + 1))
if grep -q '^OK:done' "${HARNESS}/messages.log" 2>/dev/null; then
    fail "(7b) a partial landing ALSO printed the full-success 'done' message"
else
    pass "(7b) a partial landing did not also claim full delivery"
fi
CHECKS=$((CHECKS + 1))

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
