#!/usr/bin/env bash
# tests/test_dispatch_timing.sh -- addresses v1018-D021.
#
# D021 wants a defensible email throughput floor. It could not have one,
# because the feed threw away the only evidence that could establish it.
#
# `_dispatch_to_cm048` runs pwg-convo with capture_output=True. On rc != 0
# the captured stderr is logged. On rc == 0 -- the overwhelmingly common
# case -- it is discarded, taking pwg-convo's own per-step instrumentation
# with it. The only remaining signal was the gap between consecutive
# "Dispatching" lines, which folds queueing, lock waits and the document's
# real cost into one number and attributes all of it to the document.
#
# Measured that way on the shipped box, 2026-08-09, two windows 13h apart:
#   pre-wedge   03:40-03:47   n=4   mean  98.4s   p50 102.3s   p90 111.8s
#   post-unwedge 16:47-16:57  n=6   mean 100.3s   p50  83.5s   p90 142.7s
# Stable and reproducible, and still not a breakdown. The one document
# whose internals I did see (because killing it surfaced its stderr) spent
# 9.6s of ~100s in Ollama -- but n=1 is an anecdote, not a calibration.
#
# So the floor is not defensible until every dispatch reports its own
# duration on SUCCESS. That is what this gate asserts.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREES=(email whatsapp imessage spoken)

pass=0
fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D021: every dispatch reports its own duration, including on success"
echo ""

for t in "${TREES[@]}"; do
	f="$REPO/vendor/${t}_source/pipeline.py"
	if [ ! -f "$f" ]; then
		bad "$t: vendor/${t}_source/pipeline.py missing"
		continue
	fi

	# The success branch must exist at all. Before D021 there was no `else`:
	# rc == 0 fell straight through to `return proc.returncode` in silence.
	if grep -q "pwg-convo completed %s in %.1fs" "$f"; then
		ok "$t: successful dispatches report their duration"
	else
		bad "$t: successful dispatches are silent -- throughput cannot be calibrated"
	fi

	# A wall-clock that starts after the process has already been spawned
	# measures nothing useful, so pin the ordering rather than the presence.
	if awk '/started = time.monotonic\(\)/{s=NR} /proc = subprocess.run\(/{r=NR} END{exit !(s && r && s < r)}' "$f"; then
		ok "$t: the clock starts before the subprocess, not after"
	else
		bad "$t: timing does not bracket the subprocess call"
	fi

	if grep -q "^import time" "$f"; then
		ok "$t: time is imported"
	else
		bad "$t: uses time.monotonic without importing time"
	fi

	# Failures were already logged; they must not lose their duration now
	# that we have one, or a slow failure reads like a fast one.
	if grep -q "pwg-convo failed for %s after %.1fs" "$f"; then
		ok "$t: failed dispatches report their duration too"
	else
		bad "$t: failure path drops the duration"
	fi
done

# --- The file must still be valid Python -------------------------------
echo ""
echo "syntax"
for t in "${TREES[@]}"; do
	if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" \
	     "$REPO/vendor/${t}_source/pipeline.py" 2>/dev/null; then
		ok "$t: parses"
	else
		bad "$t: does not parse"
	fi
done

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), every dispatch is measurable\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "A feed that discards its own instrumentation on success cannot be given a"
echo "throughput floor, only a guess with a number attached."
exit 1
