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

exit "$fail"
