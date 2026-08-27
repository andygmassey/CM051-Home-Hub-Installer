#!/usr/bin/env bash
# seed-hub-payload-pyc.sh must refuse an interpreter that is not cpython-311.
#
# WHY THIS IS THE GUARD THAT MATTERS. CPython looks for
# `<name>.cpython-<tag>.pyc`. A seed written by the runner's system python3
# lands as `cpython-314.pyc`, which a 3.11 interpreter NEVER LOOKS AT -- it
# compiles its own and writes it into the signed bundle. Every observable the
# build has would say success: compileall exits 0, the .pyc files are on disk,
# a count is satisfied. The seal still breaks on the customer's first run.
#
# So the tag check is the difference between a seed and a decoration, and a
# script that fails closed everywhere else is worth nothing if that one check
# silently passes.
#
# THIS TEST USES SHIM TARBALLS, not the real 27 MB python-build-standalone
# bundle, so it costs nothing in CI. It therefore tests the REFUSALS and not
# the happy path -- the happy path is exercised by the ship chain itself, and
# was measured by hand on the shipped v1.0.47 nested Ostler.app: 0 -> 86
# cpython-311.pyc, 0 uncovered, 0 wrong-mode, and after a reseal an unguarded
# import left it at 86 with codesign rc=0.

# 🔴 HERESTRINGS, NOT `printf | grep -q`. This file sets `set -uo pipefail`,
# and under pipefail `producer | grep -q X` returns NON-ZERO ON A MATCH once the
# producer is still writing when grep exits -- so a successful match reads as no
# match. In an assertion that inverts the verdict silently.
#
# I wrote this test to prove I understood that mechanism and then used the
# construct anyway, twice. The repo's own ratchet
# (tests/test_pipefail_shortcircuit_inversion.sh) caught it on the first CI run:
# "NEW instances, not listed in the baseline (70 found, baseline 69)".
#
# Knowing a rule is not the same as being subject to it. The gate is.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/gui/scripts/seed-hub-payload-pyc.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL [script-missing]: $SCRIPT not found or not executable. NOT a pass." >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# a plausible app: enough .py to clear the anti-vacuity floor
APP="$WORK/Ostler.app"
mkdir -p "$APP/Contents/Resources"
i=0
while [[ $i -lt 25 ]]; do printf 'v = %d\n' "$i" > "$APP/Contents/Resources/m$i.py"; i=$((i+1)); done

# build a tarball whose python3.11 reports $1 as its cache_tag
make_shim() {
    local tag="$1" dir="$2" extra="${3:-}"
    rm -rf "$dir"; mkdir -p "$dir/src/python/bin"
    cat > "$dir/src/python/bin/python3.11" <<SHIM
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *cache_tag*) echo "$tag"; exit 0 ;;
    *version*)   echo "3.11.15"; exit 0 ;;
  esac
done
exit 0
SHIM
    chmod +x "$dir/src/python/bin/python3.11"
    if [[ -n "$extra" ]]; then
        mkdir -p "$dir/src/python/other/bin"
        cp "$dir/src/python/bin/python3.11" "$dir/src/python/other/bin/python3.11"
    fi
    ( cd "$dir/src" && tar -czf "$dir/bundle.tar.gz" python )
}

# ---- 1. wrong cache_tag must be refused -----------------------------------
make_shim "cpython-314" "$WORK/wrong"
set +e; OUT="$("$SCRIPT" "$APP" "$WORK/wrong/bundle.tar.gz" 2>&1)"; RC=$?; set -e
# 🔴 THE DISCRIMINATOR HAS TO BE THE REFUSAL, NOT MERELY A NON-ZERO EXIT.
# With the tag guard removed the script still exits non-zero -- it gets further
# and dies on compileall or the audit instead. An assertion that accepts ANY
# failure passes in both worlds and proves nothing. Measured: neutering the
# guard left this test GREEN until it was tightened to look for the refusal
# itself.
#
# And not a bare `grep cache_tag` either: the happy path PRINTS
# "[OK] seeding interpreter: ... (cache_tag cpython-314)", so that substring is
# present even when the guard is gone. It has to be the ERROR wording.
if [[ "$RC" -eq 0 ]]; then
    fail "wrong-tag-accepted" "an interpreter reporting cpython-314 was ACCEPTED. Its .pyc are invisible to the 3.11 that ships, so they would be regenerated into the seal while every count looked right"
elif ! grep -q "cache_tag is 'cpython-314', not cpython-311" <<< "$OUT"; then
    fail "wrong-tag-not-the-reason" "the script exited $RC, but NOT on the tag check -- its output never says \"cache_tag is 'cpython-314', not cpython-311\". It failed for some later reason, so this assertion would pass even with the tag guard deleted"
else
    pass "an interpreter with the wrong cache_tag is refused ON THAT GROUND, and says so"
fi

# ---- 2. CONTROL: the right tag must get PAST the tag check -----------------
# Without this, a check that refuses EVERYTHING would pass assertion 1.
make_shim "cpython-311" "$WORK/right"
set +e; OUT2="$("$SCRIPT" "$APP" "$WORK/right/bundle.tar.gz" 2>&1)"; RC2=$?; set -e
if grep -q 'cache_tag is' <<< "$OUT2"; then
    fail "control-refuses-everything" "an interpreter reporting cpython-311 was ALSO refused on the tag check; assertion 1 then proves nothing"
else
    pass "control: cpython-311 passes the tag check (it fails later, on the audit, which is a different guard)"
fi

# ---- 3. a missing tarball is CANNOT-RUN, not a silent skip ----------------
set +e; OUT3="$("$SCRIPT" "$APP" "$WORK/does-not-exist.tar.gz" 2>&1)"; RC3=$?; set -e
if [[ "$RC3" -eq 0 ]]; then
    fail "missing-tarball-passed" "a missing python bundle exited 0. Nothing was seeded and the build would carry on to seal an unseeded bundle"
else
    pass "a missing python bundle is refused (rc=$RC3)"
fi

# ---- 4. two interpreters must not be guessed between --------------------
make_shim "cpython-311" "$WORK/two" "extra"
set +e; OUT4="$("$SCRIPT" "$APP" "$WORK/two/bundle.tar.gz" 2>&1)"; RC4=$?; set -e
if [[ "$RC4" -eq 0 ]]; then
    fail "ambiguous-accepted" "a bundle containing TWO python3.11 was accepted; the script picked one without saying which"
else
    pass "an ambiguous bundle (two interpreters) is refused rather than guessed"
fi

# ---- 5. a missing app directory ------------------------------------------
set +e; "$SCRIPT" "$WORK/no-such.app" "$WORK/right/bundle.tar.gz" >/dev/null 2>&1; RC5=$?; set -e
if [[ "$RC5" -eq 0 ]]; then
    fail "missing-app-passed" "a non-existent app path exited 0"
else
    pass "a missing app path is refused (rc=$RC5)"
fi

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo
echo "ALL HUB PAYLOAD SEED GUARD TESTS PASSED"
