#!/usr/bin/env bash
# Row #1774, the half the probe wrapper does not cover.
#
# THE DEFECT. scripts/box_walk_probes/probes/usage_journal_producers.sh refuses
# a journal path that lies in a staging tree. scripts/verify_usage_journal_producers.py,
# which is the ADJUDICATOR, did not. Measured on the branch before the fix, with
# a control of the same shape in the same file:
#
#     prelaunch|staging in verify_usage_journal_producers.py     0 lines
#     journal            in verify_usage_journal_producers.py    55 lines   CONTROL
#
# so the reader worked and the absence was real. That matters because the probe
# wrapper is not the only caller: .github/workflows/usage-journal-producers.yml
# invokes the adjudicator directly as `python3 "$G" --journal "$F"`, and so could
# OS003 or a person at a terminal. A guard living in one of several callers
# guards one of several callers.
#
# REFUSED, NEVER FAILED. A staging path means the live journal was not found,
# which is coverage lost. Calling it FAIL accuses the producers of a silence
# nobody looked for. Exit 2, the third state.
#
# GRADED ON THE MESSAGE, NOT THE EXIT CODE, and that is deliberate. The first
# version of this measurement graded rc and was INCONCLUSIVE: rc=2 is shared by
# every CANNOT-RUN path in the adjudicator, so a control journal that was
# refused for being empty looked identical to one refused for being staging, and
# the mutant scored the same as the subject. The message is emitted by this
# guard and nothing else.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADJ="${REPO}/scripts/verify_usage_journal_producers.py"
MARK="names a STAGING tree"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$ADJ" ] || cant "no adjudicator at ${ADJ}; nothing to measure"
command -v python3 >/dev/null 2>&1 || cant "no python3 on PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/ostler-prelaunch-9999/state" "${WORK}/real/state"
printf '%s\n' '{}' > "${WORK}/ostler-prelaunch-9999/state/costs.jsonl"
printf '%s\n' '{}' > "${WORK}/real/state/costs.jsonl"
STAGED="${WORK}/ostler-prelaunch-9999/state/costs.jsonl"
LIVEISH="${WORK}/real/state/costs.jsonl"

# grep -c, never grep -q: -q exits at the first match and SIGPIPEs the producer,
# which under pipefail hands the pipeline the producer's status.
refused() { python3 "$ADJ" --journal "$1" 2>&1 | grep -c "$MARK"; }

echo "== the adjudicator refuses a staging journal (#1774) =="

[ "$(refused "$STAGED")" -gt 0 ] \
    && ok "a journal under an ostler-prelaunch tree is REFUSED by name" \
    || bad "a staging journal was adjudicated rather than refused"

# CONTROL, same predicate, same corpus. A temp-dir journal that is NOT staging
# must not be refused for being staging, or every fixture in CI refuses and the
# guard gets removed for being useless.
[ "$(refused "$LIVEISH")" -eq 0 ] \
    && ok "CONTROL: an ordinary temp-dir journal is not refused for being staging" \
    || bad "a non-staging fixture was refused, which would make every fixture CANNOT-RUN"

# The refusal must be exit 2 and not exit 1. A FAIL here would accuse the
# producers; CANNOT-RUN says the reader never got to the box.
python3 "$ADJ" --journal "$STAGED" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] \
    && ok "the refusal is CANNOT-RUN (exit 2), not FAIL (exit 1)" \
    || bad "a staging journal exited ${rc}; expected 2, the third state"

# MUTATION. Blind the signature arm in a COPY of the real file, assert the
# mutation APPLIED, then require the refusal to disappear. A mutant that did not
# apply looks exactly like one that was not caught.
MUT="${WORK}/mutant.py"
python3 - "$ADJ" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "    if _STAGING_SIGNATURE in text:\n        return True\n"
if s.count(old) != 1:
    sys.exit("MUTANT-ANCHOR: expected exactly 1 occurrence, found %d" % s.count(old))
open(dst, "w").write(s.replace(old, "    if False:\n        return True\n", 1))
PY
if [ $? -ne 0 ] || [ ! -s "$MUT" ]; then
    cant "the mutant could not be built, so the guard was NOT proved"
fi
if [ "$(grep -c 'if _STAGING_SIGNATURE in text:' "$MUT")" -eq 0 ]; then
    ok "MUTANT APPLIED: the signature arm is gone from the mutated copy"
    if [ "$(python3 "$MUT" --journal "$STAGED" 2>&1 | grep -c "$MARK")" -eq 0 ]; then
        ok "and with it blinded the staging journal is NO LONGER refused, so the arm does the work"
    else
        bad "the mutated adjudicator still refused, so the refusal comes from somewhere else"
    fi
else
    cant "the mutation did not apply; a mutant that did not apply proves nothing"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
