#!/usr/bin/env bash
# tests/test_intelligence_eval_selftest.sh
#
# The brief and owner-knowledge eval (scripts/intelligence_eval/) must be able to
# tell a good brief from a bad one, and a right answer from a fabrication, before
# any number it prints is read. This runs the harness self-test (18+ assertions,
# including the mutant that switches the acted-outcome scorer off) and then the
# synthetic control run, whose control assertions must all hold.
# Synthetic data only. No model, no box: runs anywhere.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${OSTLER_PYTHON:-python3}"
fail=0

"$PY" -I "$HERE/scripts/intelligence_eval/run.py" --self-test || fail=1

out="$("$PY" -I "$HERE/scripts/intelligence_eval/run.py" --mode synthetic 2>&1)"
rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
    echo "FAIL: synthetic control run exited $rc"; fail=1
fi
# grep -F on a here-string, never a pipe into grep -q (pipefail ratchet)
if ! grep -Fq "CONTROL ASSERTIONS: ALL HOLD" <<< "$out"; then
    echo "FAIL: control assertions did not all hold"; fail=1
fi

# ARM: the model endpoint is DOWN. The run must exit non-zero and count every reply as ERROR,
# never ABSTAINED. Port 9 (discard) refuses connections. This is a control, not a model run.
down="$("$PY" -I "$HERE/scripts/intelligence_eval/run.py" --mode synthetic --model qwen3.5:4b \
    --ollama http://127.0.0.1:9 2>&1)"
down_rc=$?
printf '%s\n' "$down" | grep -E "ERROR" | head -3
if [ "$down_rc" -eq 0 ]; then
    echo "FAIL: endpoint-down run exited 0"; fail=1
fi
if ! grep -Fq "ERROR" <<< "$down"; then
    echo "FAIL: endpoint-down run printed no ERROR bucket"; fail=1
fi
if grep -Fq "CONTROL ASSERTIONS: ALL HOLD" <<< "$down"; then
    echo "FAIL: endpoint-down run reported control assertions holding"; fail=1
fi

# ARM: made-up-answer measurement on the shipped /ws/chat path (owner_fabrication.py). Dry run
# against a stand-in gateway and a fixture store, with known verdicts per mode, planted grader
# controls, and refusals. It never touches a box; the real run is on Mini16, by hand.
out_fab="$("$PY" -I "$HERE/scripts/intelligence_eval/owner_fabrication_selftest.py" 2>&1)"
rc_fab=$?
printf '%s\n' "$out_fab" | tail -3
if [ "$rc_fab" -ne 0 ]; then
    echo "FAIL: owner_fabrication dry run exited $rc_fab"; fail=1
fi
if ! grep -Fq "18 passed, 0 failed" <<< "$out_fab"; then
    echo "FAIL: owner_fabrication dry run did not report 18 passed, 0 failed"; fail=1
fi

exit "$fail"
