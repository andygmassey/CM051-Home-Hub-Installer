#!/usr/bin/env bash
# tests/test_stderr_tail.sh -- addresses v1018-D032.
#
# When a dispatch fails, the captured stderr is the only record of what
# pwg-convo was doing. The original code kept the FIRST 500 characters of
# it. For a process that HUNG, those are the least informative 500
# characters available: they record the run starting normally. The last
# thing it did before wedging -- the one line that localises the hang --
# is at the far end, and was thrown away every time.
#
# This is not hypothetical. A document that hung 13 hours on the shipped
# box surfaced exactly 500 characters, clipped mid-word, all of them from
# the first ten seconds of a thirteen-hour run. It read like an ending.
# A localisation was inferred from it and had to be retracted.
#
# So the gate asserts three things, and the third is not cosmetic:
#   1. no head-truncation of a captured stream survives anywhere;
#   2. the excerpt is taken from the tail;
#   3. a clipped excerpt SAYS it was clipped -- an unmarked window is
#      exactly what invited the wrong inference in the first place.
#
# Plus a fourth that came out of reviewing the D020 ceiling: the timeout
# branch must log the excerpt too. The first cut of that ceiling logged
# the timeout and dropped the captured output, which would have bounded
# the hang while discarding its diagnosis on every future occurrence.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
TREES=(email whatsapp imessage spoken)

pass=0
fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D032: keep the tail of a captured stream, and say when it is clipped"
echo ""

for t in "${TREES[@]}"; do
	f="$REPO/vendor/${t}_source/pipeline.py"
	if [ ! -f "$f" ]; then
		bad "$t: vendor/${t}_source/pipeline.py missing"
		continue
	fi

	if grep -qE "stderr(\.strip\(\))?\[:[0-9]+\]" "$f"; then
		bad "$t: still head-truncates stderr -- the tail is where a hang localises"
	else
		ok "$t: no head-truncation of a captured stream"
	fi

	if grep -q "text\[-limit:\]" "$f"; then
		ok "$t: excerpt is taken from the tail"
	else
		bad "$t: no tail slice -- cannot show what it did last"
	fi

	if grep -q "earlier chars dropped" "$f"; then
		ok "$t: a clipped excerpt says it was clipped"
	else
		bad "$t: clipped excerpt is unmarked -- invites the same wrong inference"
	fi

	# The D020 ceiling must surface what it killed, not merely that it killed.
	if awk '/except subprocess.TimeoutExpired/{i=1} i && /_stderr_excerpt\(exc.stderr\)/{found=1} /return DISPATCH_TIMEOUT_RC/{i=0} END{exit !found}' "$f"; then
		ok "$t: the timeout branch logs what the process was doing when killed"
	else
		bad "$t: timeout bounds the hang but discards its diagnosis"
	fi
done

# --- Behaviour, executed from the shipped source (not a copy) ----------
#
# The first cut of this block extracted the helper with `.*$` under re.S,
# which is greedy to end-of-file and silently swallowed the rest of the
# module, then exec'd function definitions annotated `Optional[Path]`.
#
# It passed locally on Python 3.14 -- where deferred annotation evaluation
# is the default, so those annotations were never evaluated -- and failed
# on CI's older Python, which evaluates them and raised NameError. A
# harness that only works on its author's interpreter is not a gate.
#
# Two changes: the match is bounded by the helper's own closing sentinel,
# and the extraction must PROVE it did not overshoot before a single line
# is executed.
echo ""
echo "behaviour (helper lifted out of vendor/email_source/pipeline.py)"
out="$("$PY" "$REPO/tests/helpers/check_stderr_excerpt.py" \
        "$REPO/vendor/email_source/pipeline.py" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), the useful end of stderr survives\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
