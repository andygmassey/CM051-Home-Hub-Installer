#!/usr/bin/env bash
# A source that found NO INPUT must not claim success, and --repair must work
# ==========================================================================
#
# Behavioural test. Extracts the REAL helpers and the REAL argument parser
# from install.sh and executes them, so this cannot pass against a copy.
#
# ---------------------------------------------------------------------------
# DEFECT 1: FOUR CALL SITES TRIED TO RECORD A STATUS AND WERE OVERRIDDEN
# ---------------------------------------------------------------------------
#
# Measured in source 2026-08-19. Four hydrate branches passed a status through
# the PAYLOAD argument, plainly intending it to be recorded as the status:
#
#     _hydrate_sentinel_record "whatsapp"    "status=no_app"
#     _hydrate_sentinel_record "browsing"    "status=no_data"
#     _hydrate_sentinel_record "imessage"    "status=no_data"
#     _hydrate_sentinel_record "apple_notes" "status=no_data"
#
# _hydrate_sentinel_record hardcodes `status=ok`. The author's intent landed
# one line lower as `payload=status=no_data` and the file's actual status line
# said `ok`. _hydrate_sentinel_fresh greps `^status=ok`, matched it, and
# skipped the source for SEVEN DAYS.
#
# So a source that looked and found nothing recorded itself as KNOWN TO HAVE
# SUCCEEDED. That is the exact distinction #768 was built to enforce, defeated
# through a different door.
#
# ---------------------------------------------------------------------------
# DEFECT 2: THE ADVERTISED ESCAPE HATCH WAS PARSED BY NOTHING
# ---------------------------------------------------------------------------
#
# vendor/doctor/agent/web_ui_copy.py contains TEN separate strings telling the
# customer to "Re-run install.sh --repair". Three more sites treat the flag as
# real in prose (install.sh:17976, imessage_tcc_posture.py:23,
# reminders_posture.py:28 -- "refreshed on each --repair run").
#
# install.sh's argument loop recognised eight flags. `--repair` was not one of
# them, and there is no `*)` arm, so it was silently ignored and an ORDINARY
# install ran -- which honours the 7-day sentinel and therefore skips exactly
# the source the customer was trying to un-stick.
#
# The loop that produced:
#
#     source records status=ok with no data  ->  locked out 7 days
#     Doctor says "Re-run install.sh --repair"
#     customer runs it  ->  flag ignored  ->  sentinel still fresh  ->  SKIPPED
#     Doctor says it again
#
# A closed loop, for a week, in which the product tells the customer to pull a
# lever connected to nothing.
#
# ---------------------------------------------------------------------------
# CONTROLS
# ---------------------------------------------------------------------------
#
#   APPARATUS  extraction of every helper AND the parser must succeed, or this
#              exits 2 CANNOT-RUN rather than passing on an empty harness.
#   POSITIVE   a genuine success must still be fresh (7-day dedupe intact) and
#              --repair must still be ignored by the flags it does not own.
#   NEGATIVE   an unknown flag must NOT turn on repair mode, so the parser
#              assertion cannot pass by matching everything.
#
# The ratchet at the end is the part that outlives this fix: it forbids ANY
# call site from passing `status=` through a payload argument again, which is
# the shape that made defect 1 invisible for months.

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

HARNESS="$(mktemp -d -t nodatasentinel-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

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
    # gui_step_record_rc is called by the error recorder; stub it so the
    # harness does not need the whole GUI layer.
    printf 'gui_step_record_rc() { :; }\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
    extract_fn _hydrate_sentinel_record_no_data
} > "$HARNESS/helpers.sh"

# --- APPARATUS CONTROL ------------------------------------------------------
for fn in _hydrate_sentinel_fresh _hydrate_sentinel_record \
          _hydrate_sentinel_record_error _hydrate_sentinel_record_no_data; do
    if ! grep -q "^${fn}() {" "$HARNESS/helpers.sh"; then
        echo "CANNOT-RUN: could not extract $fn from install.sh." >&2
        echo "  This test drives the REAL helpers; it refuses to run against a copy." >&2
        exit 2
    fi
done
bash -n "$HARNESS/helpers.sh" || { echo "CANNOT-RUN: extracted helpers do not parse" >&2; exit 2; }

# Extract the REAL argument parser -- the `for arg in "$@"` loop and its case.
awk '
    /^for arg in "\$@"; do$/ { inside = 1 }
    inside { print }
    inside && /^done$/ { exit }
' "$INSTALL" > "$HARNESS/parser.sh"
if ! grep -q 'case "\$arg" in' "$HARNESS/parser.sh"; then
    echo "CANNOT-RUN: could not extract the argument parser from install.sh." >&2
    exit 2
fi
bash -n "$HARNESS/parser.sh" || { echo "CANNOT-RUN: extracted parser does not parse" >&2; exit 2; }

echo "test_no_data_is_not_success.sh"

run_in_harness() { bash -c "source '$HARNESS/helpers.sh'; $1"; echo "$?"; }

# Run the REAL parser over a given argv and print the resulting REPAIR_MODE.
parse_repair() {
    bash -c '
        set -u
        CHECK_ONLY=false; SHOW_HELP=false; SHOW_LICENSES=false
        ALLOW_PLAINTEXT=0; ALLOW_UNLICENSED=0; NO_EXTENSIONS=false
        REPAIR_MODE=0
        source "'"$HARNESS"'/parser.sh"
        printf "%s" "$REPAIR_MODE"
    ' _ "$@"
}

# ---------------------------------------------------------------------------
# (1) POSITIVE CONTROL. A genuine success is still fresh. Without this the
#     "fix" could be to make nothing ever fresh, which destroys the dedupe the
#     sentinel exists for.
# ---------------------------------------------------------------------------
rc=$(run_in_harness '_hydrate_sentinel_record browsing "sent=12"; _hydrate_sentinel_fresh browsing')
check "(1) POSITIVE: a real success IS fresh, 7-day dedupe intact" "$rc" "0"

# ---------------------------------------------------------------------------
# (2) THE DEFECT. A no-data run must NOT be fresh.
#     Against the old code this line recorded status=ok and returned 0.
# ---------------------------------------------------------------------------
rc=$(run_in_harness '_hydrate_sentinel_record_no_data browsing "no_export_json"; _hydrate_sentinel_fresh browsing')
check "(2) DEFECT: a NO-DATA run is NOT fresh, so the next run looks again" "$rc" "1"

# ---------------------------------------------------------------------------
# (3) The evidence survives. Refusing to write the file would lose the
#     distinction between "looked, found nothing" and "never looked", which is
#     the four-states-one-appearance problem this whole area suffers from.
# ---------------------------------------------------------------------------
out="$(bash -c "source '$HARNESS/helpers.sh'
                _hydrate_sentinel_record_no_data apple_notes 'no_export_json'
                cat \"\$_HYDRATE_SENTINEL_DIR/apple_notes.done\"")"
CHECKS=$((CHECKS + 1))
if grep -q '^status=no_data' <<< "$out" && grep -q '^detail=no_export_json' <<< "$out"; then
    pass "(3) the no-data run is still RECORDED (status=no_data + detail), not discarded"
else
    fail "(3) the no-data record lost its status or detail: $out"
fi

# ---------------------------------------------------------------------------
# (4) It converges. Once the input arrives and the retry succeeds, the source
#     is suppressed again -- one re-attempt per install, not a loop.
# ---------------------------------------------------------------------------
rc=$(run_in_harness '_hydrate_sentinel_record_no_data imessage "no_export_json"
                     _hydrate_sentinel_fresh imessage || _hydrate_sentinel_record imessage "people=41"
                     _hydrate_sentinel_fresh imessage')
check "(4) after the input arrives and the retry succeeds it IS fresh again" "$rc" "0"

# ---------------------------------------------------------------------------
# (5) A no-data sentinel is stale IMMEDIATELY, not merely after 7 days.
#     Guards against a fix that only works once the mtime has aged.
# ---------------------------------------------------------------------------
rc=$(run_in_harness '_hydrate_sentinel_record_no_data whatsapp "no_app"; _hydrate_sentinel_fresh whatsapp')
check "(5) a no-data sentinel is stale immediately, not after 7 days" "$rc" "1"

# ---------------------------------------------------------------------------
# (6) --repair defeats freshness. This is the ONLY thing that makes the flag
#     Doctor advertises in 10 strings do anything.
# ---------------------------------------------------------------------------
rc=$(run_in_harness 'REPAIR_MODE=1; _hydrate_sentinel_record browsing "sent=12"; _hydrate_sentinel_fresh browsing')
check "(6) under --repair NOTHING is fresh, so every source re-attempts" "$rc" "1"

# ---------------------------------------------------------------------------
# (7) ...and freshness is unchanged when repair mode is off or unset. Without
#     this, (6) would pass for a helper that always returns 1.
# ---------------------------------------------------------------------------
rc=$(run_in_harness 'REPAIR_MODE=0; _hydrate_sentinel_record browsing "sent=12"; _hydrate_sentinel_fresh browsing')
check "(7) with REPAIR_MODE=0 a success is fresh again (6 is not vacuous)" "$rc" "0"

# ---------------------------------------------------------------------------
# (8) THE PARSER. --repair must actually be recognised. Against the old
#     parser this returned 0: eight flags, no --repair arm, no *) fallthrough.
# ---------------------------------------------------------------------------
check "(8) DEFECT: install.sh --repair sets REPAIR_MODE" "$(parse_repair --repair)" "1"

# ---------------------------------------------------------------------------
# (9) NEGATIVE CONTROL. An unknown flag must NOT set it, so (8) cannot pass by
#     a parser that turns repair mode on for anything.
# ---------------------------------------------------------------------------
check "(9) NEGATIVE: an unrelated flag does NOT set REPAIR_MODE" "$(parse_repair --no-extensions)" "0"
check "(9b) NEGATIVE: a bogus flag does NOT set REPAIR_MODE" "$(parse_repair --repair-not-really)" "0"
check "(9c) NEGATIVE: no arguments at all leaves REPAIR_MODE off" "$(parse_repair)" "0"

# ---------------------------------------------------------------------------
# (10) RATCHET. No call site may pass `status=` through a PAYLOAD argument
#      again. That shape is what made defect 1 invisible: the payload looks
#      like it sets the status and cannot. Comments are excluded so this file's
#      own documentation of the defect does not trip it.
# ---------------------------------------------------------------------------
echo
echo "  -- payload-shape ratchet --"
OFFENDERS="$(grep -nE '_hydrate_sentinel_record(_error)? "[a-z_]+" .*status=' "$INSTALL" \
             | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
CHECKS=$((CHECKS + 1))
if [[ -z "$OFFENDERS" ]]; then
    pass "(10) RATCHET: no call site passes status= through a payload argument"
else
    fail "(10) RATCHET: a payload argument carries status=, which the recorder ignores:"
    printf '%s\n' "$OFFENDERS" >&2
fi

# ---------------------------------------------------------------------------
# (11) COVERAGE REPORT + FLOOR. Which no-input branches use the honest
#      recorder? Named individually so a regression is visible in the output
#      rather than absent from it.
# ---------------------------------------------------------------------------
echo
echo "  -- no-data recorder coverage --"
NO_DATA_SOURCES="whatsapp browsing imessage apple_notes"
COVERED=0
for src in $NO_DATA_SOURCES; do
    if grep -q "_hydrate_sentinel_record_no_data \"$src\"" "$INSTALL"; then
        echo "     honest     $src"
        COVERED=$((COVERED + 1))
    else
        echo "     CLAIMS OK  $src   <- its no-input branch still records success"
    fi
done
echo
NO_DATA_FLOOR=4
CHECKS=$((CHECKS + 1))
if [[ "$COVERED" -ge "$NO_DATA_FLOOR" ]]; then
    pass "(11) every no-input branch records honestly (covered=$COVERED, floor=$NO_DATA_FLOOR of 4)"
else
    fail "(11) coverage went BACKWARDS: covered=$COVERED, floor is $NO_DATA_FLOOR"
fi

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
