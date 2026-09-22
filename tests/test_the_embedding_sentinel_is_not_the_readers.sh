#!/usr/bin/env bash
# The knowledge-embedding sentinel is not the FDA reader's sentinel (#775)
# =======================================================================
#
# WHAT WENT WRONG, measured on the v1.0.101 walk (run 35769568715) and not
# reconstructed from the code. The install log carried BOTH of these, same
# run, twenty-four lines apart:
#
#     [ok] Reminders: 2369 total (6 pending, 2363 completed)
#     msg=No Reminders to read. You can re-run later from Settings.
#     STEP_END id=hydrate_reminders status=ok elapsed_s=0
#
# ~/.ostler/state/hydrate/reminders.done, written DURING that install at
# 19:27:55Z, read `status=ok item_count=2369
# payload=pending=6,completed=2363,total_reminders=2369` -- the FDA READER's
# payload shape. The knowledge-embedding leg then called
# `_hydrate_sentinel_fresh "reminders"`, saw that sentinel, and skipped in
# zero seconds while reporting ok. reminders_knowledge was never created,
# install_manifest_complete went FAIL, and the customer was told there were
# no reminders to read about 2369 reminders.
#
# ONE SENTINEL WAS ANSWERING TWO QUESTIONS. `reminders` answers "did the
# reader read them". The embedding leg needs "are they EMBEDDED". The second
# is not entailed by the first. apple_notes had the identical collision in
# the same run, and evernote_knowledge existed with 0 points.
#
# WHY THIS TEST RUNS THE FUNCTION INSTEAD OF GREPPING FOR IT. A grep for a
# mechanism is not a test of it -- this repo has been bitten by that four
# times. Arms 1-4 EXECUTE the real `_hydrate_sentinel_*` functions, lifted
# out of install.sh at run time, against a real sentinel directory.
#
# EXIT: 0 all arms pass, 1 any arm fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"
fails=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; fails=$((fails+1)); }

[[ -r "$INSTALL" ]] || { echo "CANNOT-RUN: no install.sh at $INSTALL"; exit 2; }

# ---- lift the real functions out of the shipped script -------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LIB="${WORK}/lib.sh"
{
  echo '_HYDRATE_SENTINEL_DIR="${SENT_DIR}"'
  for fn in _hydrate_compute_change _hydrate_sentinel_fresh _hydrate_sentinel_record \
            _hydrate_sentinel_record_no_data _hydrate_sentinel_record_error; do
    awk -v f="^${fn}\\\\(\\\\) \\\\{" '$0 ~ f,/^\}/' "$INSTALL"
  done
} > "$LIB"

# The lift itself is a claim; prove it carried real code before trusting any
# verdict below. A silently empty LIB would make every "not fresh" arm pass.
if ! grep -q '_hydrate_sentinel_fresh() {' "$LIB"; then
    echo "CANNOT-RUN: could not lift _hydrate_sentinel_fresh out of install.sh"; exit 2
fi
echo "lifted $(grep -c '^_hydrate_sentinel[a-z_]*() {' "$LIB") sentinel function(s) from install.sh"

export SENT_DIR="${WORK}/hydrate"; mkdir -p "$SENT_DIR"
# Normally set by _hydrate_compute_change during a real run. Declared here so
# `set -u` inside the lifted recorder is exercised rather than tripped -- an
# unbound variable would abort the harness and look like a failing arm.
_HY_ITEM_COUNT=""; _HY_LAST_UPDATE_AT=""
# shellcheck source=/dev/null
source "$LIB"

# The reader's sentinel, byte-for-byte the shape the v1.0.101 box carried.
_write_reader_sentinel() {
    cat > "${SENT_DIR}/$1.done" <<SENT
recorded_at=2026-09-22T19:27:55Z
source=$1
status=ok
item_count=2369
last_update_at=2026-09-22T19:27:55Z
payload=pending=6,completed=2363,total_reminders=2369
SENT
}

echo
echo "1. POSITIVE CONTROL -- the lifted freshness check can say YES at all"
_write_reader_sentinel "reminders"
if _hydrate_sentinel_fresh "reminders"; then
    pass "a reader sentinel IS fresh under its own key (so a NO below means the key, not a dead function)"
else
    fail "the lifted _hydrate_sentinel_fresh never returns fresh -- every other arm is meaningless"
fi

echo
echo "2. THE DEFECT -- the key the SHIPPED EMBEDDING LEG passes, run against the reader's sentinel"
# THE KEY IS READ OUT OF install.sh, NOT HARDCODED. An earlier draft of this
# test called _hydrate_sentinel_fresh "reminders_knowledge" directly and
# passed on the UNFIXED tree too, because the function was never the defect --
# the call site was. A behavioural arm that does not consume the call site is
# decorative. This extracts the key the installer actually passes and runs
# the real function with it, so the arm is red exactly when the product is.
_key_for() {
    local marker="$1"
    awk -v m="$marker" '
        $0 ~ m { seen = 1 }
        seen && /_hydrate_sentinel_fresh "/ {
            if (match($0, /_hydrate_sentinel_fresh "[a-z_]+"/)) {
                k = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", k); sub(/"$/, "", k)
                print k; exit
            }
        }
    ' "$INSTALL"
}
RK="$(_key_for '_HYDRATE_REMINDERS_COLLECTION=')"
AK="$(_key_for '_HYDRATE_APPLENOTES_JSON_FILE=')"
echo "  install.sh's reminders embedding leg asks for: '${RK:-<none found>}'"
echo "  install.sh's apple-notes embedding leg asks for: '${AK:-<none found>}'"
if [[ -z "$RK" || -z "$AK" ]]; then
    echo "CANNOT-RUN: could not read the sentinel key out of install.sh"; exit 2
fi
if _hydrate_sentinel_fresh "$RK"; then
    fail "with only the READER's reminders.done present, the embedding leg (key '$RK') decides it is already done and skips -- this is #775, and it is why reminders_knowledge was never created"
else
    pass "with only the reader's reminders.done present, the embedding leg (key '$RK') still runs"
fi

echo
echo "3. SAME COLLISION, APPLE NOTES"
_write_reader_sentinel "apple_notes"
if ! _hydrate_sentinel_fresh "apple_notes"; then
    fail "control: apple_notes.done is not fresh under its own key"
elif _hydrate_sentinel_fresh "$AK"; then
    fail "apple_notes.done made the embedding leg (key '$AK') skip"
else
    pass "the apple-notes embedding leg (key '$AK') still runs"
fi

echo
echo "4. THE EMBEDDING LEG STILL WORKS -- its own sentinel does suppress a re-run"
_hydrate_sentinel_record "$RK" "reminders=2369" >/dev/null 2>&1 || true
if _hydrate_sentinel_fresh "$RK"; then
    pass "once the embedding leg records its own sentinel, it is fresh"
else
    fail "the embedding leg cannot mark itself done -- the fix would re-embed on every install"
fi

echo
echo "5. WIRING -- install.sh asks the right key on each side"
grep -q '_hydrate_sentinel_fresh "reminders_knowledge"' "$INSTALL" \
    && pass "embedding leg checks reminders_knowledge" \
    || fail "embedding leg does not check reminders_knowledge"
grep -q '_hydrate_sentinel_fresh "apple_notes_knowledge"' "$INSTALL" \
    && pass "embedding leg checks apple_notes_knowledge" \
    || fail "embedding leg does not check apple_notes_knowledge"
grep -qE '_hydrate_sentinel_record +reminders ' "$INSTALL" \
    && pass "the FDA reader still records the bare 'reminders' key (unchanged)" \
    || fail "the reader's own key was changed -- that is a different fix and breaks its callers"

echo
echo "6. THREE CAUSES, THREE STRINGS -- a skip message must say WHICH skip"
if [[ -r "$STRINGS" ]]; then
    # shellcheck source=/dev/null
    source "$STRINGS"
    for pair in \
        "MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA:MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED" \
        "MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA:MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT" \
        "MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA:MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED" \
        "MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA:MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT" ; do
        a="${pair%%:*}"; b="${pair##*:}"
        if [[ -z "${!b:-}" ]]; then
            fail "$b is not defined"
        elif [[ "${!a:-}" == "${!b}" ]]; then
            fail "$b is the same sentence as $a -- the reader still cannot tell the causes apart"
        else
            pass "$b is distinct from $a"
        fi
    done
else
    fail "CANNOT-RUN: strings file unreadable at $STRINGS"
fi

echo
if (( fails )); then echo "== ${fails} arm(s) FAILED =="; exit 1; fi
echo "== all arms passed =="
