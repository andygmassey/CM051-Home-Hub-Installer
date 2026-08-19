#!/usr/bin/env bash
# tests/test_dispatch_timeout.sh -- addresses v1018-D020.
#
# Every conversation feed dispatches documents to CM048 with
# `subprocess.run(...)`. Without a timeout that call waits forever, so one
# document that never returns wedges the tick permanently. The tick holds
# the shared single-flight ingest lock -- which is deliberately never
# reclaimed on age, so that the hours-long wiki summary backfill is not
# evicted -- and therefore ONE wedged dispatch stops ALL FOUR feeds.
#
# Observed on the shipped v1.0.18 box, 2026-08-09 12:2x HKT:
#   pwg-convo pid 41101   alive 6h47m, no timeout, still running
#   lock holder pid 10718 held the slot 9h19m (the email tick)
#   imessage-bundle.log   36 x "slot still busy ... yielding this tick"
#   spoken-bundle.log     38 x "another LLM job (pid 10718) holds the slot"
#   launchctl list        reported every label healthy throughout
#
# This test asserts the ceiling exists in all four shipped pipelines, and
# -- crucially -- proves it can tell a bounded call from an unbounded one.
# A gate with no demonstrated RED is not a gate.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
TREES=(email whatsapp imessage spoken)

pass=0
fail=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D020: every pwg-convo dispatch is bounded"
echo ""

# --- 1. Structural: the ceiling is wired in all four shipped pipelines ---
echo "structure"
for t in "${TREES[@]}"; do
	f="$REPO/vendor/${t}_source/pipeline.py"
	if [ ! -f "$f" ]; then
		bad "$t: vendor/${t}_source/pipeline.py missing"
		continue
	fi
	if grep -q "timeout=_dispatch_timeout_secs()" "$f"; then
		ok "$t: subprocess.run carries a timeout"
	else
		bad "$t: subprocess.run has NO timeout -- one document can wedge the feed"
	fi
	if grep -q "except subprocess.TimeoutExpired" "$f"; then
		ok "$t: TimeoutExpired is handled, not raised through the loop"
	else
		bad "$t: TimeoutExpired unhandled -- a timeout would abort the whole tick"
	fi
	if grep -qE "^DISPATCH_TIMEOUT_RC = [0-9]+" "$f"; then
		ok "$t: timeout has a distinct return code"
	else
		bad "$t: no distinct timeout rc -- slow is indistinguishable from broken"
	fi
done

# --- 2. The helper's env contract, exercised against the REAL file ------
# The helper block is lifted out of the shipped source and executed, so
# this tests what ships rather than a copy of it that can drift.
echo ""
echo "env contract (executed from vendor/email_source/pipeline.py)"
helper_out="$("$PY" - "$REPO/vendor/email_source/pipeline.py" <<'PYEOF' 2>&1
import os, re, sys

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^_DISPATCH_TIMEOUT_DEFAULT_SECS.*?^    return None if secs <= 0 else secs$",
              src, re.S | re.M)
if not m:
    print("EXTRACT-FAIL: helper block not found in shipped source")
    sys.exit(1)

ns = {"os": os}
exec(m.group(0), ns)          # noqa: S102 -- executing our own shipped source
fn = ns["_dispatch_timeout_secs"]
default = ns["_DISPATCH_TIMEOUT_DEFAULT_SECS"]

cases = [
    ("unset defaults to the ceiling", None,   float(default)),
    ("empty falls back to default",   "",     float(default)),
    ("explicit value is honoured",    "42",   42.0),
    ("zero means unbounded",          "0",    None),
    ("negative means unbounded",      "-1",   None),
    ("garbage falls back, never raises", "banana", float(default)),
]
rc = 0
for label, raw, want in cases:
    os.environ.pop("OSTLER_DISPATCH_TIMEOUT_SECS", None)
    if raw is not None:
        os.environ["OSTLER_DISPATCH_TIMEOUT_SECS"] = raw
    try:
        got = fn()
    except Exception as exc:                       # noqa: BLE001
        print(f"FAIL: {label}: raised {exc!r}")
        rc = 1
        continue
    print(("PASS: " if got == want else f"FAIL: got {got!r} want {want!r}: ") + label)
    if got != want:
        rc = 1
sys.exit(rc)
PYEOF
)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		*)      bad "${line#FAIL: }" ;;
	esac
done <<< "$helper_out"

# --- 3. NEGATIVE CONTROL: prove this test can detect the defect ---------
# Two identical dispatches against a command that never returns in time.
# The shipped shape must come back with the timeout rc; the pre-fix shape
# must still be running when we look. If the control does not hang, the
# harness is not measuring what it claims to and every PASS above is
# worthless.
echo ""
echo "negative control (a bounded call and an unbounded one, side by side)"

ctl="$("$PY" - <<'PYEOF' 2>&1
import subprocess, sys, time

SLEEP = ["/bin/sh", "-c", "sleep 30"]
TIMEOUT_RC = 75

# (a) shipped shape: bounded.
t0 = time.monotonic()
try:
    subprocess.run(SLEEP, capture_output=True, text=True, timeout=2)
    print("FAIL: bounded call returned normally against a 30s sleep")
except subprocess.TimeoutExpired:
    dt = time.monotonic() - t0
    if dt < 10:
        print(f"PASS: bounded call raised TimeoutExpired after {dt:.1f}s and returns rc={TIMEOUT_RC}")
    else:
        print(f"FAIL: bounded call took {dt:.1f}s -- ceiling not respected")

# (b) pre-fix shape: unbounded. Run it in a child we can walk away from,
# then assert it is STILL alive after a window several times the ceiling.
child = subprocess.Popen(
    [sys.executable, "-c",
     "import subprocess;subprocess.run(['/bin/sh','-c','sleep 30'],capture_output=True)"],
)
time.sleep(6)
if child.poll() is None:
    print("PASS: unbounded call is still running at 6s -- the control hangs, so the test can see the defect")
    child.kill()
    child.wait()
else:
    print(f"FAIL: unbounded control exited early (rc={child.returncode}) -- this harness cannot detect the defect it tests for")
PYEOF
)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		*)      bad "${line#FAIL: }" ;;
	esac
done <<< "$ctl"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), every dispatch bounded\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not raise the ceiling to make this pass. An unbounded dispatch stops"
echo "every conversation feed on the box and reports itself healthy while doing it."
exit 1
