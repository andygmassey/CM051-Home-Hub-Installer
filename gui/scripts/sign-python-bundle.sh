#!/usr/bin/env bash
# Sign every Mach-O inside the bundled Python tree with hardened runtime.
#
# Why: Apple's notary service requires `--options runtime` on every
# Mach-O executable + dylib + .so inside a notarised .app. xcodebuild's
# `--deep` re-sign at archive time signs embedded binaries with the
# Developer ID identity but DOES NOT enable hardened runtime on them
# (only the main app target gets that from xcodebuild build settings).
# notarytool rejects with "The executable does not have the hardened
# runtime enabled" — see DMG #17 submission 4e3721db-aff2-41fc-ae30-dd2e117ffb87.
#
# This script walks the bundled python tree, detects Mach-O files (file
# header magic, not extension), and re-signs each with --options runtime.
# Then re-signs the outer .app via the caller's codesign step so the
# outer signature seals the new inner signatures.
#
# Usage: sign-python-bundle.sh <APP_PATH> <CODESIGN_ID>
#   APP_PATH    Path to the .app being shipped (.../OstlerInstaller.app)
#   CODESIGN_ID Developer ID Application identity string
#
# Exit 0 on clean. Exit 1 on missing dir, no Mach-O files found
# (something is wrong), or any codesign failure.

set -euo pipefail

APP_PATH="${1:?APP_PATH argument required}"
CODESIGN_ID="${2:?CODESIGN_ID argument required}"

PYTHON_DIR="${APP_PATH}/Contents/Resources/python"
if [ ! -d "$PYTHON_DIR" ]; then
    echo "ERROR: Bundled Python not found at $PYTHON_DIR" >&2
    echo "       This script runs as part of 'make ship' AFTER the postBuildScript" >&2
    echo "       has extracted python-build-standalone into Resources/python/." >&2
    exit 1
fi

# CX-30 (2026-05-24, Studio retest #20): the bundled python3.11 is signed
# with hardened runtime (CX-20) but NO entitlements, so library validation
# is ON by default. When pip installs cryptography (transitive dep of
# ostler_security) into the customer venv, cryptography's _rust.abi3.so
# is signed by the cryptography maintainers' Team ID -- DIFFERENT to
# Creative Machines' V95N2B8X7A. Hardened-runtime library validation
# refuses dlopen() across team IDs and the import fails with:
#   "code signature ... not valid for use in process: mapping process
#    and mapped file (non-platform) have different Team IDs"
# Result: install.sh dies silently at encrypt_db (the setup_passphrase
# Python -c block exits 1, but the diagnostic is lost because the
# || block emits via warn() which only renders prefixed [WARN] lines).
#
# Fix: add the entitlement that disables library validation for the
# bundled Python interpreter. The same entitlements file used for the
# OstlerInstaller .app already declares disable-library-validation,
# allow-dyld-environment-variables (needed for venv to set PYTHONPATH),
# and the other minimal-privilege flags. Re-using it keeps a single
# source of truth.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/../OstlerInstaller/OstlerInstaller.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    echo "       Expected: gui/OstlerInstaller/OstlerInstaller.entitlements" >&2
    echo "       Without this the signed Python cannot load third-party C extensions" >&2
    echo "       (cryptography, etc.) on the customer Mac -- install dies at encrypt_db." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# PRECOMPILE THE BUNDLED STDLIB *BEFORE* SIGNING, SO THE .pyc ARE INSIDE THE SEAL.
# ---------------------------------------------------------------------------
# THE DEFECT THIS CLOSES, MEASURED ON THE SHIPPED v1.0.45 ARTEFACT 2026-08-26:
#
#   OstlerInstaller-1.0.45.dmg, sha256 70ebd926...989b57, dittoed to a WRITABLE
#   dir (the only place the defect exists -- see below), then:
#
#     env -u PYTHONPYCACHEPREFIX -u PYTHONDONTWRITEBYTECODE \
#         .../python/bin/python3.11 -c 'import secrets,hmac,platform'
#
#     .pyc inside the bundle   BEFORE 0  ->  AFTER 26
#     codesign --verify --deep --strict   rc=1
#       "a sealed resource is missing or invalid"
#
#   CPython writes __pycache__/*.pyc next to the source it imports. That source
#   is inside the notarised .app, so the first import from a writable location
#   ADDS files to a signed bundle and voids the seal. macOS then refuses the app
#   as "damaged and can't be opened. You should move it to the Bin." It reaches
#   EVERY customer: quarantine is attached by every browser download and the
#   failure is on FIRST RUN.
#
# WHY PYTHONPYCACHEPREFIX ALONE IS NOT ENOUGH, AND THIS IS THE WHOLE POINT.
#
# InstallerCoordinator.swift sets PYTHONPYCACHEPREFIX on the process it spawns,
# and that WORKS -- measured, same binary, same import, second arm:
#     .pyc inside the bundle 0 -> 0, 26 redirected to the cache dir, codesign rc=0
# But it is a fix conditional on a fact about the CALLER. v1.0.45 SHIPPED that
# Swift fix (the string is in the shipped Mach-O: PYTHONPYCACHEPREFIX greps 2)
# and v1.0.45 STILL BRICKED on hardware. After a full sweep of this repo --
# 16 ProgramArguments blocks, only one python reference and it is the Doctor's
# own venv, not this bundle; both install.sh resolution sites under the Swift
# env -- the invoker that wrote those bytes REMAINS UNIDENTIFIED.
#
# So this step does not depend on knowing it. A file that is already present
# cannot be added. Seeding is a fact about the ARTEFACT, not about its callers,
# and it holds for callers nobody has found and callers that do not exist yet.
#
# MEASURED, same artefact, same harness:
#     compileall           ->  1448 .pyc seeded, rc=0
#     then the no-env run  ->  1448, NEW FILES WRITTEN = 0
#     then a broad no-env import (json ssl sqlite3 subprocess urllib.request
#       venv plistlib shutil tempfile)
#                          ->  1448, NEW SINCE SEED = 0
#
# KEEP BOTH MECHANISMS. They are not redundant and they are not fighting:
# the prefix keeps stray caches out of the bundle for callers that carry it,
# the seeding makes breaking the seal structurally impossible for those that
# do not. Removing either one re-opens a limb.
#
# ORDER MATTERS: this runs BEFORE the Mach-O walk below and therefore before
# the caller's outer codesign, so the .pyc are sealed rather than added later.
# .pyc are not Mach-O, so the walk skips them -- they need no signature of
# their own, only to be inside the seal.
#
# 🔴 FAILS CLOSED. compileall exits non-zero if ANY file fails to compile, and
# a partial seed is the dangerous state: the modules that did NOT compile are
# exactly the ones a customer's first import will write. There is no
# `|| true` here on purpose.
BUNDLED_PY="${PYTHON_DIR}/bin/python3.11"
if [ ! -x "$BUNDLED_PY" ]; then
    echo "ERROR: bundled interpreter not found at $BUNDLED_PY" >&2
    echo "       Cannot precompile the stdlib, so the shipped .app would write" >&2
    echo "       .pyc into its own signed bundle on the customer's first run and" >&2
    echo "       be refused by Gatekeeper as damaged. Refusing to sign." >&2
    exit 1
fi

PYC_BEFORE="$(find "$PYTHON_DIR" -name '*.pyc' | wc -l | tr -d ' ')"
echo "Precompiling bundled stdlib (.pyc before: $PYC_BEFORE)..."
# 🔴 --invalidation-mode unchecked-hash IS LOAD-BEARING. DO NOT DROP IT.
#
# compileall's DEFAULT is TIMESTAMP: each .pyc records the source's mtime+size,
# and CPython REWRITES any .pyc whose recorded mtime does not match the .py on
# disk. That rewrite is a MODIFY inside the signed bundle -- the seal breaks
# exactly as it did with an add, and the .pyc COUNT DOES NOT CHANGE, so a
# count-based check reports clean.
#
# Under timestamp mode the fix would rest on an unstated invariant: that .py
# mtimes survive DMG -> mount -> install -> /Applications. `ditto` preserves
# them; plain `cp` does not. Nobody has measured that path end to end, and
# v1.0.45 already shipped a .pyc fix that still bricked, so an unmeasured
# invariant is not good enough here.
#
# MEASURED 2026-08-26 on the shipped v1.0.45 app, after touching the .py to
# simulate a copy path that did not preserve mtimes:
#     secrets.cpython-311.pyc
#       timestamp        ba2e9334b5a31dc7 -> 0176fd93027b7b2a   REWRITTEN
#       unchecked-hash   ce2e1e6edd258248 -> ce2e1e6edd258248   UNCHANGED
#     file count 1448 -> 1448 in BOTH arms -- the count cannot see this.
#
# unchecked-hash records a source hash and never validates it, so no rewrite
# can be provoked at all. That is what turns "works because the copy path
# happens to preserve timestamps" into "cannot break".
# Found by Archie1 in review of #1052; verified here rather than taken on trust.
if ! "$BUNDLED_PY" -m compileall -q --invalidation-mode unchecked-hash "${PYTHON_DIR}/lib"; then
    echo "ERROR: compileall failed on ${PYTHON_DIR}/lib" >&2
    echo "       A PARTIAL seed is worse than none: whatever failed to compile is" >&2
    echo "       what the customer's first import will write into the signed" >&2
    echo "       bundle, voiding the seal. Refusing to sign." >&2
    exit 1
fi
PYC_AFTER="$(find "$PYTHON_DIR" -name '*.pyc' | wc -l | tr -d ' ')"
echo "Precompiled: $PYC_AFTER .pyc now inside the bundle (was $PYC_BEFORE)"

# ANTI-VACUITY. A compileall that silently compiled nothing exits 0 and would
# leave this step looking green while shipping the exact defect it exists to
# prevent -- the "uniform zero from a broken predicate" shape. The v1.0.45
# bundle seeds 1448; a floor of 500 catches a python tree that failed to
# extract or a lib/ path that moved, without pinning us to an exact count that
# a python patch bump would legitimately change.
if [ "$PYC_AFTER" -lt 500 ]; then
    echo "ERROR: only $PYC_AFTER .pyc after compileall -- expected >=500" >&2
    echo "       (v1.0.45's bundled stdlib seeds 1448). A near-zero count means" >&2
    echo "       compileall found no stdlib to compile: check that" >&2
    echo "       ${PYTHON_DIR}/lib exists and python-build-standalone extracted." >&2
    exit 1
fi

echo "Walking $PYTHON_DIR for Mach-O files..."
echo "Entitlements: $ENTITLEMENTS"

SIGNED=0
FAILED=0

while IFS= read -r -d '' f; do
    # file(1) header magic test — works regardless of extension. Catches
    # python3.11 / libpython3.11.dylib / *.so extension modules / any
    # nested binary tools shipped by python-build-standalone.
    if file -b "$f" 2>/dev/null | grep -qE "Mach-O.*(executable|dynamically linked shared library|bundle)"; then
        # CX-30: --entitlements applies library-validation-disabling entitlements
        # to the bundled Python so dlopen() of third-party C extensions
        # (cryptography, sqlcipher3, etc.) does NOT fail with Team ID mismatch
        # at runtime on the customer Mac. Entitlements are only effective on
        # main executables (python3.11), not libraries, but passing them
        # on every codesign call is harmless and keeps the signing flow uniform.
        # WHY THE STDERR IS CAPTURED AND PRINTED (2026-08-13).
        #
        # This line used to end `>/dev/null 2>&1`, so a failure printed
        # "FAIL: codesign <path>" and NOTHING ELSE. Run 31692208160 died here
        # on two files out of twelve and the cause was unknowable from the log,
        # because the script had thrown the only evidence away. A gate that
        # reports a verdict while destroying the reason is the defect class
        # this cut has spent the day clearing; it does not get an exception for
        # being ours.
        #
        # WHY THE RETRY IS NARROW.
        #
        # `--timestamp` contacts Apple's timestamp authority over the network.
        # That is the one part of this command that can fail for reasons having
        # nothing to do with the artefact, and the timings on 31692208160 fit:
        # ten files signed in well under a second each, the two failures took
        # 34s and 15s. That is the shape of a network timeout, not a bad
        # binary. It is a HYPOTHESIS -- the evidence to confirm it was
        # discarded -- and the next failure will now print the actual message
        # and settle it.
        #
        # So the retry matches ONLY the timestamp-service message. Any other
        # failure fails closed on the first attempt, exactly as before: a
        # malformed Mach-O, a missing identity or a bad entitlements file must
        # never be retried into looking transient.
        attempt=1
        err=""
        while :; do
            if err="$(codesign --force --sign "$CODESIGN_ID" --options runtime \
                        --timestamp --entitlements "$ENTITLEMENTS" "$f" 2>&1)"; then
                SIGNED=$((SIGNED + 1))
                [ "$attempt" -gt 1 ] && echo "  (signed on attempt $attempt: $f)"
                break
            fi
            if [ "$attempt" -lt 3 ] && printf '%s' "$err" | grep -qiE "timestamp (service|server).*(not available|unavailable)|The timestamp service is not available"; then
                echo "  timestamp service unavailable, retry $attempt/2: $(basename "$f")" >&2
                attempt=$((attempt + 1))
                sleep $((attempt * 5))
                continue
            fi
            echo "FAIL: codesign $f" >&2
            printf '%s\n' "$err" | sed 's/^/      codesign: /' >&2
            FAILED=$((FAILED + 1))
            break
        done
    fi
done < <(find "$PYTHON_DIR" -type f -print0)

echo "Signed $SIGNED Mach-O files in bundled Python ($FAILED failures)"

if [ "$FAILED" -gt 0 ]; then
    echo "ERROR: $FAILED codesign failures — refusing to ship a partially-signed bundle" >&2
    exit 1
fi

if [ "$SIGNED" -eq 0 ]; then
    echo "ERROR: 0 Mach-O files signed — bundled Python tree is missing binaries" >&2
    echo "       Expected at least python3.11 + libpython3.11.dylib + extension .so files." >&2
    exit 1
fi

echo "OK: all bundled Python Mach-O files signed with hardened runtime."
