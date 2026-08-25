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
mkdir -p "$APP/Contents/Resources/python/lib" "$APP/Contents/Resources/python/bin"
echo "not really a binary" > "$APP/Contents/Resources/python/lib/libfake.dylib"

# A STUB INTERPRETER, because the script now precompiles the stdlib before it
# signs anything and REFUSES a bundle with no interpreter -- correctly, since
# shipping one means the customer's first import writes .pyc into the signed
# bundle and Gatekeeper refuses the app as damaged.
#
# It is resolved by absolute path inside the bundle, not via PATH, so it has to
# exist HERE rather than in $WORK/bin. `-m compileall` seeds a controlled number
# of .pyc so the harness can drive the seed count from the outside: a normal
# count for the codesign assertions, a tiny one to prove the anti-vacuity floor
# fires, and FAIL to prove compileall failure is fatal.
seed_count() { echo "$1" > "$WORK/seed"; }
cat >"$APP/Contents/Resources/python/bin/python3.11" <<STUB
#!/bin/bash
if [ "\$1" = "-m" ] && [ "\$2" = "compileall" ]; then
    n="\$(cat "$WORK/seed" 2>/dev/null || echo 600)"
    [ "\$n" = "FAIL" ] && { echo "stub: compileall refused" >&2; exit 1; }
    mkdir -p "$APP/Contents/Resources/python/lib/__pycache__"
    i=0
    while [ "\$i" -lt "\$n" ]; do
        : > "$APP/Contents/Resources/python/lib/__pycache__/m\${i}.cpython-311.pyc"
        i=\$(( i + 1 ))
    done
    exit 0
fi
exit 0
STUB
chmod +x "$APP/Contents/Resources/python/bin/python3.11"
seed_count 600

# The script resolves entitlements relative to ITS OWN directory, so the real
# repo file is used. Assert it rather than assume it: if it moves, this test
# must say "could not run", not "pass".
[ -f "$REPO_ROOT/gui/OstlerInstaller/OstlerInstaller.entitlements" ] \
    || { echo "::error::entitlements moved; this harness cannot drive the script"; exit 2; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/file" <<'STUB'
#!/bin/bash
# ONLY .dylib is Mach-O. This used to answer "Mach-O" for EVERYTHING, which was
# fine when the fixture held exactly one file -- and became wrong the moment the
# bundle also contained a stub interpreter and 600 seeded .pyc, because the
# signing walk would then have signed all 601 and the "exactly one codesign
# call" assertion below would have measured the fixture rather than the script.
case "$*" in
  *.dylib) echo "Mach-O 64-bit dynamically linked shared library arm64" ;;
  *)       echo "ASCII text" ;;
esac
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

# --- THE PRECOMPILE STEP MUST REFUSE A BUNDLE IT CANNOT SEAL ----------------
#
# These three exist because the .pyc seeding is the ONLY part of this script
# that is invoker-independent, and an invoker-independent fix that silently
# no-ops is worse than no fix: it looks green while shipping the exact defect.
# MEASURED on the shipped v1.0.45 artefact 2026-08-26 -- a writable copy, no
# env, `import secrets,hmac,platform`: .pyc in bundle 0 -> 26 and codesign
# rc=1 "a sealed resource is missing or invalid". Seeded first: 0 new.

# (a) NO INTERPRETER -> refuse. Cannot precompile, so cannot promise the seal.
make_codesign ok
mv "$APP/Contents/Resources/python/bin/python3.11" "$WORK/py.hidden"
rc="$(run)"
check "no interpreter: refuses to sign" "1" "$rc"
if grep -q "bundled interpreter not found" "$WORK/out"; then
    echo "  PASS  no interpreter: the reason reaches the log"
else
    echo "  FAIL  no interpreter: reason swallowed"; fail=1
fi
check "no interpreter: nothing was signed" "0" "$(attempts)"
mv "$WORK/py.hidden" "$APP/Contents/Resources/python/bin/python3.11"

# (b) compileall FAILS -> refuse. A PARTIAL seed is the dangerous state:
#     whatever failed to compile is what the customer's first import writes.
make_codesign ok
seed_count FAIL
rc="$(run)"
check "compileall failure: refuses to sign" "1" "$rc"
if grep -q "compileall failed" "$WORK/out"; then
    echo "  PASS  compileall failure: the reason reaches the log"
else
    echo "  FAIL  compileall failure: reason swallowed"; fail=1
fi

# (c) THE ANTI-VACUITY FLOOR. A compileall that compiles almost nothing exits 0
#     and would leave the step green while shipping the defect -- the uniform-
#     zero-from-a-broken-predicate shape. This arm exists because I could NOT
#     drive it red by hand: a real interpreter without its stdlib cannot boot,
#     so compileall failed and limb (b) fired first. That was a CANNOT-RUN, not
#     a pass, and the floor had never been seen to fire. The stub gives it the
#     one state reality would not: compileall SUCCEEDS and seeds too few.
make_codesign ok
rm -rf "$APP/Contents/Resources/python/lib/__pycache__"
seed_count 3
rc="$(run)"
check "floor: too few .pyc refuses to sign" "1" "$rc"
if grep -q "only 3 .pyc after compileall" "$WORK/out"; then
    echo "  PASS  floor: names the count it measured"
else
    echo "  FAIL  floor: did not fire, or did not say what it counted"; fail=1
fi
check "floor: nothing was signed" "0" "$(attempts)"
seed_count 600

# (d) THE INVALIDATION MODE IS LOAD-BEARING AND MUST STAY unchecked-hash.
#
# The default (timestamp) records source mtime+size and CPython REWRITES any
# .pyc whose recorded mtime does not match the .py -- a MODIFY inside the signed
# bundle, which breaks the seal exactly as an add would, WITHOUT CHANGING THE
# FILE COUNT. Every other assertion here counts files, so none of them can see
# it. MEASURED on the shipped v1.0.45 app (secrets.cpython-311.pyc, after
# touching the .py): timestamp ba2e9334 -> 0176fd93 REWRITTEN;
# unchecked-hash ce2e1e6e -> ce2e1e6e UNCHANGED; count 1448 -> 1448 in both.
#
# This asserts the FLAG because the behaviour it buys cannot be observed
# through the stub interpreter -- and says so, rather than implying it proved
# the rewrite. The rewrite itself is proved in the commit message's measurement.
if grep -q -- "--invalidation-mode unchecked-hash" "$SCRIPT"; then
    echo "  PASS  compileall pins unchecked-hash (timestamp mode would allow a reseal-breaking rewrite)"
else
    echo "  FAIL  compileall lost --invalidation-mode unchecked-hash -- a .pyc REWRITE can now break the seal, and the file count will not show it"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "sign-python-bundle: all assertions pass"; else echo "sign-python-bundle: FAILURES ABOVE"; fi
exit "$fail"
