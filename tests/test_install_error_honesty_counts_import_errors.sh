#!/usr/bin/env bash
# test_install_error_honesty_counts_import_errors.sh
#
# GUARDS: scripts/box_walk_probes/probes/install_error_honesty.sh
# (task #270, second pass). That probe fails an install ONLY when the log
# BOTH contains a clean-claim phrase ("no errors detected", "completed
# without errors", "no problems found" -- case-insensitive, ANYWHERE in the
# log) AND its own independent grep for ERROR|FATAL|Traceback|command not
# found|No such file or directory finds more than zero lines. It does not
# understand scope: a narrowly-true claim about one component reads to it
# exactly like a false claim about the whole run, once the words match.
#
# MEASURED ON A REAL INSTALL: 20 error lines (9 JSON-parse failures with an
# undiagnostic identical message, 2 retail-export file parse failures, 1
# encrypted Disney+ export with no password offered, 1 un-retried SPARQL
# 502) sat in the same install.log as
# "ostler-assistant doctor: no errors detected" -- a TRUE, narrowly-scoped
# claim about the assistant doctor's own startup checks that nonetheless
# collided with the probe's clean-claim phrase list. The probe cannot be
# fixed by editing it (its predicate is the whole point of it existing);
# this file proves the FIX was to make install.sh stop emitting the
# colliding phrase and to make the import path's real errors actually
# countable, not to touch the probe.
#
# FOUR ARMS:
#   1. STRUCTURAL. The doctor's "no errors" catalogue string no longer
#      contains any of the probe's three clean-claim phrases.
#   2. BEHAVIOURAL. The import-diagnostics block added to install.sh, run
#      in isolation against a synthetic import.log carrying the four real
#      error shapes, counts them and folds the count into
#      _OSTLER_RUN_ERRORS -- extracted from the SHIPPED file via awk, not
#      restated here, so a future edit that breaks the real block breaks
#      this arm too.
#   3. END TO END, SIMULATING THE PROBE'S OWN PREDICATE. Concatenate the
#      real doctor string with the synthetic import errors into one
#      candidate install.log and run the probe's OWN two regexes (copied
#      verbatim from its source, not restated as English) against it. The
#      combination must not read as a false clean claim.
#   4. MUST-FAIL CONTROL. Repeat arm 3 with the OLD (pre-fix) doctor string
#      spliced in instead of the real one. That combination MUST trip the
#      probe's fail predicate, or arm 3 passing would prove nothing.
#
# No install runs. No real customer data. Synthetic fixtures only.
#
# Exit: 0 all pass, 1 a real failure, 2 CANNOT-RUN (never a silent pass).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

SRC="install.sh"
STRINGS="install.sh.strings.en-GB.sh"
PROBE="scripts/box_walk_probes/probes/install_error_honesty.sh"

for f in "$SRC" "$STRINGS" "$PROBE"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: $f is not readable" >&2; exit 2; }
done

PASS=0
FAIL=0
ok()  { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The probe's own two patterns, read out of ITS source rather than restated,
# so a future edit to the probe's predicate is what this test measures
# against -- never a copy that quietly diverges from the real one.
ERROR_PATTERN="$(grep -oE "^ERROR_PATTERN='[^']*'" "$PROBE" | sed "s/^ERROR_PATTERN='//;s/'$//")"
CLEAN_CLAIM_PATTERN="$(grep -oE "^CLEAN_CLAIM_PATTERN='[^']*'" "$PROBE" | sed "s/^CLEAN_CLAIM_PATTERN='//;s/'$//")"
if [ -z "$ERROR_PATTERN" ] || [ -z "$CLEAN_CLAIM_PATTERN" ]; then
    echo "CANNOT-RUN: could not extract ERROR_PATTERN / CLEAN_CLAIM_PATTERN from $PROBE" >&2
    exit 2
fi

printf '== install_error_honesty: the import path counts and stops colliding with the doctor line ==\n\n'

# ---------------------------------------------------------------------------
# ARM 1. STRUCTURAL. The doctor's catalogue string must not contain any of
# the probe's clean-claim phrases.
# ---------------------------------------------------------------------------
doctor_line="$(grep -oE '^MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="[^"]*"' "$STRINGS" | sed 's/^[^=]*=//')"
if [ -z "$doctor_line" ]; then
    bad "1a. could not extract MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED from $STRINGS; every later arm is meaningless"
else
    ok "1a. extracted the doctor's catalogue string: $doctor_line"
fi
if grep -qiE "$CLEAN_CLAIM_PATTERN" <<< "$doctor_line"; then
    bad "1b. the doctor's catalogue string still matches the probe's clean-claim pattern: $doctor_line"
else
    ok "1b. the doctor's catalogue string no longer matches the probe's clean-claim pattern"
fi
# The closing-verdict messages must not have picked up the same collision.
for var in MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED MSG_WARN_INSTALL_FINISHED_WITH_ERRORS; do
    v="$(grep -oE "^${var}=\"[^\"]*\"" "$STRINGS" | sed 's/^[^=]*=//')"
    if [ -z "$v" ]; then
        bad "1c. could not extract ${var} from $STRINGS"
    elif grep -qiE "$CLEAN_CLAIM_PATTERN" <<< "$v"; then
        bad "1c. ${var} matches the probe's clean-claim pattern: $v"
    else
        ok "1c. ${var} does not match the probe's clean-claim pattern"
    fi
done

# ---------------------------------------------------------------------------
# ARM 2. BEHAVIOURAL. Extract the import-diagnostics block install.sh added
# (task #270 second pass) and run it, unmodified, against a synthetic
# import.log carrying the four real error shapes measured on the box.
# ---------------------------------------------------------------------------
block="$(awk '
    /^    # ── install_error_honesty \(task #270\): count what the import path/ { f = 1 }
    f { print }
    f && /^    fi$/ { c++; if (c == 2) exit }
' "$SRC")"
if [ -z "$block" ]; then
    bad "2a. could not extract the import-diagnostics block from $SRC; arm 2 cannot run"
else
    n_lines="$(printf '%s\n' "$block" | grep -c .)"
    ok "2a. extracted the import-diagnostics block from $SRC (${n_lines} lines)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Synthetic import.log: nine JSON-parse failures (all identical, as measured
# -- the message shape, not the count, is what task #270's second half
# fixed), two retail-export file parse errors, one encrypted skip, one
# un-retried-turned-retried SPARQL failure. 13 ERROR lines total; the
# remaining "repeats of the same shapes" from the real 20 are not needed to
# prove the counter works.
import_log="$WORK/import.log"
{
    for _ in 1 2 3 4 5 6 7 8 9; do
        echo "2026-01-01 00:00:00,000 - ERROR - Failed to parse JSON from /synthetic/export.json: empty file (0 bytes) -- likely an export category with nothing in it, not a failure"
    done
    echo "2026-01-01 00:00:01,000 - ERROR - Error parsing /synthetic/retail_orders.csv: 'str' object has no attribute 'get'"
    echo "2026-01-01 00:00:01,500 - ERROR - Error parsing /synthetic/retail_digital.csv: 'str' object has no attribute 'get'"
    echo "2026-01-01 00:00:02,000 - ERROR - File is encrypted. Provide password via 'password' kwarg or DISNEY_XLSX_PASSWORD env var"
    echo "2026-01-01 00:00:03,000 - ERROR - All 3 retries exhausted. Last error: None"
} > "$import_log"
n_synthetic_errors="$(grep -cE ' - (ERROR|FATAL) - ' "$import_log")"
if [ "$n_synthetic_errors" -ne 13 ]; then
    bad "2b. fixture itself carries ${n_synthetic_errors} ERROR lines, expected 13 -- the fixture is wrong, not the code under test"
else
    ok "2b. fixture carries 13 planted ERROR lines"
fi

run_block() {  # $1 = import log path; prints _import_error_count and the resulting _OSTLER_RUN_ERRORS
    (
        set -uo pipefail
        _import_log="$1"
        _OSTLER_RUN_ERRORS=0
        info() { :; }
        eval "$block"
        printf 'COUNT=%s\nTOTAL=%s\n' "${_import_error_count:-unset}" "${_OSTLER_RUN_ERRORS:-unset}"
    )
}

out="$(run_block "$import_log" 2>&1)"
got_count="$(printf '%s\n' "$out" | sed -n 's/^COUNT=//p')"
got_total="$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"

if [ "$got_count" = "13" ]; then
    ok "2c. the block counted 13 import errors from the synthetic log"
else
    bad "2c. the block counted [$got_count] import errors, expected 13" "$out"
fi
if [ "$got_total" = "13" ]; then
    ok "2d. _OSTLER_RUN_ERRORS came out of the block as 13, starting from 0"
else
    bad "2d. _OSTLER_RUN_ERRORS came out as [$got_total], expected 13" "$out"
fi

# MUST-FAIL: an EMPTY import log must count zero, or arm 2c/2d pass by
# always reporting a positive number regardless of input.
empty_log="$WORK/empty.log"
: > "$empty_log"
out_empty="$(run_block "$empty_log" 2>&1)"
got_empty="$(printf '%s\n' "$out_empty" | sed -n 's/^COUNT=//p')"
if [ "$got_empty" = "0" ]; then
    ok "2e. MUST-FAIL CONTROL: a clean import log counts zero, so 2c/2d are not vacuous"
else
    bad "2e. a clean import log counted [$got_empty], expected 0 -- the counter fires on nothing" "$out_empty"
fi

# ---------------------------------------------------------------------------
# ARM 3. END TO END: does the ACTUAL current doctor string, sitting beside
# the real error shapes, read as a false clean claim under the probe's OWN
# predicate?
# ---------------------------------------------------------------------------
combined_now="$WORK/combined_now.log"
cat "$import_log" > "$combined_now"
printf '2026-01-01 00:01:00 - INFO - %s\n' "$doctor_line" >> "$combined_now"

now_claims_clean=0
grep -qiE "$CLEAN_CLAIM_PATTERN" "$combined_now" && now_claims_clean=1
now_errs="$(grep -cE "$ERROR_PATTERN" "$combined_now")"

if [ "$now_claims_clean" -eq 1 ] && [ "$now_errs" -gt 0 ]; then
    bad "3a. the CURRENT doctor string + real import errors still trips the probe's fail predicate (claims_clean=1, errs=${now_errs})"
else
    ok "3a. the CURRENT doctor string + real import errors does NOT trip the probe's fail predicate (claims_clean=${now_claims_clean}, errs=${now_errs})"
fi

# ---------------------------------------------------------------------------
# ARM 4. MUST-FAIL CONTROL. The identical fixture, with the OLD (pre-fix)
# doctor string spliced in, MUST trip the fail predicate -- proving arm 3's
# pass is not vacuous (a predicate that never fires on anything would pass
# arm 3 for the wrong reason).
# ---------------------------------------------------------------------------
old_doctor_line='ostler-assistant doctor: no errors detected'
combined_old="$WORK/combined_old.log"
cat "$import_log" > "$combined_old"
printf '2026-01-01 00:01:00 - INFO - %s\n' "$old_doctor_line" >> "$combined_old"

old_claims_clean=0
grep -qiE "$CLEAN_CLAIM_PATTERN" "$combined_old" && old_claims_clean=1
old_errs="$(grep -cE "$ERROR_PATTERN" "$combined_old")"

if [ "$old_claims_clean" -eq 1 ] && [ "$old_errs" -gt 0 ]; then
    ok "4. MUST-FAIL CONTROL: the OLD doctor string + the same errors DOES trip the fail predicate (claims_clean=${old_claims_clean}, errs=${old_errs}), so arm 3 is measuring something real"
else
    bad "4. CONTROL DID NOT FIRE: the OLD doctor string + real import errors did not trip the probe's fail predicate either (claims_clean=${old_claims_clean}, errs=${old_errs}) -- arm 3 proves nothing"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
