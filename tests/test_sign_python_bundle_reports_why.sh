#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign-python-bundle.sh must SAY WHY it failed, and must not retry a real fault.
#
# WHAT THIS CAUGHT, 2026-08-13.
#
# Run 31692208160 died at sign-python-bundle on two files out of twelve:
#
#     FAIL: codesign .../python/lib/itcl4.3.5/libitcl4.3.5.dylib
#     FAIL: codesign .../python/lib/itcl4.3.5/libtcl9itcl4.3.5.dylib
#     ERROR: 2 codesign failures -- refusing to ship a partially-signed bundle
#
# and the cause was UNKNOWABLE from the log, because the signing call ended
# `>/dev/null 2>&1`. The script reported a verdict while destroying the only
# evidence for it. That is the same defect class the rest of this cut has spent
# the day clearing, and it does not get an exception for being ours.
#
# WHY THE RETRY IS NARROW, AND WHY THAT MATTERS MORE THAN THE RETRY.
#
# `--timestamp` contacts Apple's timestamp authority over the network, which is
# the one part of that command that can fail for reasons unrelated to the
# artefact. The timings fit: ten files signed in well under a second each, the
# two failures took 34s and 15s. But that is a HYPOTHESIS, not a finding -- the
# evidence was discarded -- so the retry matches ONLY the timestamp-service
# message and everything else still fails closed on the first attempt.
#
# A retry that swallowed a malformed Mach-O, a missing identity or a bad
# entitlements file would turn a real defect into an intermittent one, which is
# strictly worse than the bug it replaces.
#
# Exit: 0 all assertions pass, 1 a failure, 2 the harness could not run.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/gui/scripts/sign-python-bundle.sh"
[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake .app whose bundled Python holds one "Mach-O" file. `file` is stubbed
# too, so no real binary is needed and the test runs identically on any host.
APP="$WORK/Fake.app"
mkdir -p "$APP/Contents/Resources/python/lib"
echo "not really a binary" > "$APP/Contents/Resources/python/lib/libfake.dylib"

# The script resolves entitlements relative to ITS OWN directory, so the real
# repo file is used. Assert it rather than assume it: if it moves, this test
# must say "could not run", not "pass".
[ -f "$REPO_ROOT/gui/OstlerInstaller/OstlerInstaller.entitlements" ] \
    || { echo "::error::entitlements moved; this harness cannot drive the script"; exit 2; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/file" <<'STUB'
#!/bin/bash
# Everything under the fake python dir is a Mach-O shared library.
echo "Mach-O 64-bit dynamically linked shared library arm64"
STUB
chmod +x "$WORK/bin/file"

make_codesign() {  # $1 = mode
    cat >"$WORK/bin/codesign" <<STUB
#!/bin/bash
COUNT_FILE="$WORK/attempts"
n=\$(( \$(cat "\$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$COUNT_FILE"
case "$1" in
  timestamp_forever)
    echo "libfake.dylib: The timestamp service is not available." >&2; exit 1 ;;
  timestamp_then_ok)
    if [ "\$n" -lt 3 ]; then
      echo "libfake.dylib: The timestamp service is not available." >&2; exit 1
    fi
    exit 0 ;;
  real_fault)
    echo "libfake.dylib: bundle format unrecognized, invalid, or unsuitable" >&2; exit 1 ;;
  ok)
    exit 0 ;;
esac
STUB
    chmod +x "$WORK/bin/codesign"
    rm -f "$WORK/attempts"
}

run() { PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$APP" "Fake ID" >"$WORK/out" 2>&1; echo $?; }
attempts() { cat "$WORK/attempts" 2>/dev/null || echo 0; }

fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"
    else printf '  FAIL  %s  (expected %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi
}

# --- CONTROL: the harness can drive the script to success at all -----------
make_codesign ok
rc="$(run)"
check "control: clean run succeeds" "0" "$rc"
check "control: exactly one codesign call" "1" "$(attempts)"

# --- THE DEFECT: a failure must print codesign's own message ---------------
make_codesign real_fault
rc="$(run)"
check "real fault fails the script" "1" "$rc"
if grep -q "bundle format unrecognized" "$WORK/out"; then
    echo "  PASS  real fault: codesign's message reaches the log"
else
    echo "  FAIL  real fault: the reason was swallowed -- this is the 31692208160 defect"
    echo "        script output was:"; sed 's/^/          /' "$WORK/out"; fail=1
fi

# --- A REAL FAULT MUST NOT BE RETRIED --------------------------------------
check "real fault is not retried" "1" "$(attempts)"

# --- A TIMESTAMP TIMEOUT IS RETRIED, AND CAN RECOVER -----------------------
make_codesign timestamp_then_ok
rc="$(run)"
check "timestamp timeout then success: script succeeds" "0" "$rc"
check "timestamp timeout: retried to the third attempt" "3" "$(attempts)"

# --- A PERSISTENT TIMESTAMP FAILURE STILL FAILS CLOSED ---------------------
make_codesign timestamp_forever
rc="$(run)"
check "persistent timestamp failure still fails" "1" "$rc"
check "persistent timestamp failure is bounded at 3 attempts" "3" "$(attempts)"
if grep -q "timestamp service is not available" "$WORK/out"; then
    echo "  PASS  persistent timestamp failure: the reason reaches the log"
else
    echo "  FAIL  persistent timestamp failure: reason swallowed"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "sign-python-bundle: all assertions pass"; else echo "sign-python-bundle: FAILURES ABOVE"; fi
exit "$fail"
