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
#
# 🔴🔴 PYTHONDONTWRITEBYTECODE=1 AND -f ARE BOTH LOAD-BEARING TOO, AND THE
# REASON IS THE DEFECT THAT SHIPPED IN v1.0.46 WITH THIS FLAG ALREADY SET.
#
# --invalidation-mode governs ONLY what compileall itself compiles. The
# interpreter that RUNS compileall must first import ~45 stdlib modules to boot
# and to load compileall -- and those .pyc are written by the IMPORT SYSTEM,
# which is always TIMESTAMP mode. compileall then walks the tree, sees them as
# up to date, and SKIPS them. They stay in the one mode this flag exists to
# eliminate.
#
# MEASURED ON THE PUBLISHED v1.0.46 ARTEFACT, 2026-08-26, read-only mount:
#     1448 .pyc total -- 1403 unchecked-hash, 45 TIMESTAMP
#     all 45 record source mtime 1704067200 while the .py on disk reads
#     1787713192 (build time); sizes identical. 45 of 45 already STALE as
#     PUBLISHED, so `ditto` is not implicated -- every one is primed to rewrite.
#     A writable copy + `import` of 3 modules rewrote 19 of them and
#     codesign --verify --deep --strict went to rc=1
#     "a sealed resource is missing or invalid". File count 1448 -> 1448.
#     THE COUNT NEVER MOVED. v1.0.46 bricks exactly as v1.0.45 did.
#
# PYTHONDONTWRITEBYTECODE=1 stops the boot imports polluting the tree; -f makes
# compileall rewrite rather than skip anything already present. Verified on the
# shipped bundle: 45 timestamp-mode -> 0, and a 30-module no-env import then
# changed 0 of 1448 .pyc by sha256 (positive control: the same harness in
# timestamp mode reports 1 changed, so the instrument is not blind).
if ! env PYTHONDONTWRITEBYTECODE=1 "$BUNDLED_PY" -m compileall -q -f \
        --invalidation-mode unchecked-hash "${PYTHON_DIR}/lib"; then
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

# ---------------------------------------------------------------------------
# 🔴 THE PRODUCT TREE, NOT ONLY THE STDLIB -- v1.0.47's RESIDUAL
# ---------------------------------------------------------------------------
#
# v1.0.47 seeded 1448 stdlib .pyc, every one unchecked-hash, and the audit below
# printed "0 of 1448 in timestamp mode". Both statements were true and the
# artefact still failed its walk, because THE AUDIT'S ROOT WAS $PYTHON_DIR --
# the one directory that same commit had just fixed. It asserted a property over
# a subset chosen so as to exclude the defect.
#
# MEASURED on the published v1.0.47 bundle: 1888 .py, 1448 .pyc, so 440 .py
# shipped with NO .pyc AT ALL. ORM's walk arm 8b (#1092) imported one of them,
# Contents/Resources/assistant_api/tests, and the count went 1448 -> 1449 with
# codesign rc=1. That is the v1.0.45 defect -- an ADD, not a MODIFY -- surviving
# in the compartment the v1.0.46 fix never looked at. Two different failures
# wear the same colour, and only one of them changes a mode bit.
#
# Of the 440: 353 are in the OUTER bundle, sealed by this script's own signing
# pass, so they are ours to fix here. 87 are inside a NESTED .app (Ostler.app)
# which carries its OWN signature, sealed later by sparkle-embed's
# `codesign --force --deep`. Seeding those from here would write into a bundle
# this script does not sign. They are EXCLUDED BY REGEX below and then COUNTED
# AND PRINTED by the audit, never silently dropped -- a residual nobody states
# is a residual nobody fixes. Hub lane owns them.
#
# -x is a regex matched with rx.search() against the FULL path, not a relative
# one -- and that is the trap. `\.app/` matched the OUTER bundle too, because
# every path under it contains `OstlerInstaller.app/`, so the exclusion swallowed
# the entire tree and compileall compiled NOTHING while exiting 0.
#
# Measured on a faithful path shape (outer .app, nested .app, stdlib), counting
# what each regex actually seeds:
#
#     -x '(/python/|\.app/)'                    product=0  stdlib=0  nested=0
#     no -x at all              (control)        product=1  stdlib=1  nested=1
#     -x '(/python/|/Contents/Resources/.*\.app/)'  product=1  stdlib=0  nested=0
#
# The middle row is the control: it proves the tree IS compilable, so the zero
# in the first row is the regex and not the sources.
#
# The anchored form works because the OUTER bundle's `.app` comes BEFORE
# `/Contents/Resources/`, while every NESTED one appears AFTER it.
#
# 🔴 `.*` AND NOT `[^/]+`, AND THAT DISTINCTION IS THE WHOLE CORRECTION.
# My first attempt used `/Resources/[^/]+\.app/`, which only matches a nested
# bundle sitting DIRECTLY under Resources. This artefact has FIVE signed
# bundles, and one of them does not:
#
#   Contents/Resources/Ostler.app                                  hub
#   Contents/Resources/assistant-agent/OstlerAssistant.app         <- one level DOWN
#   Contents/Resources/Ostler.app/.../assistant-agent/OstlerAssistant.app
#   Contents/Resources/Ostler.app/.../Sparkle.framework/.../Updater.app
#
# `[^/]+` missed the sibling, so compileall would have SEEDED INTO IT -- writing
# .pyc into a bundle this script does not sign, and which the caller's outer
# codesign does NOT reseal (it signs without --deep; only the VERIFY is --deep).
# The build would then have failed at `codesign --verify --deep --strict`, one
# compartment away from the cause. Measured: importing that bundle's single
# uncovered .py takes its own codesign 0 -> 1.
#
# /python/ is the stdlib, already seeded above.
#
# VERIFIED ON THE REAL v1.0.47 BUNDLE BEFORE THIS WAS WRITTEN, not after:
# rc=0, 1448 -> 1801 (exactly the 353 predicted, nothing failed to compile),
# 0 uncovered outer .py, 0 timestamp-mode, and re-running arm 8b's import left
# the count at 1801 -- the add that vetoed v1.0.47 no longer happens.
PRODUCT_ROOT="${APP_PATH}/Contents/Resources"
if ! env PYTHONDONTWRITEBYTECODE=1 "$BUNDLED_PY" -m compileall -q -f \
        --invalidation-mode unchecked-hash \
        -x '(/python/|/Contents/Resources/.*\.app/)' "$PRODUCT_ROOT"; then
    echo "ERROR: compileall failed on the product tree $PRODUCT_ROOT" >&2
    echo "       A PARTIAL seed is worse than none: whatever failed to compile" >&2
    echo "       is exactly what the customer's first import writes into the" >&2
    echo "       signed bundle, voiding the seal. Refusing to sign." >&2
    exit 1
fi

# 🔴 ASSERT THE PROPERTY, NOT THE FLAG. THIS IS THE CHECK v1.0.46 DID NOT HAVE.
#
# The command line above carries --invalidation-mode unchecked-hash, and it
# carried it in v1.0.46 too, and v1.0.46 still shipped 45 timestamp-mode .pyc.
# A test that greps the flag out of this script passes in both worlds. So does
# every count-based assertion, because a REWRITE does not change the count.
# The only honest question is what mode the bytes on disk are actually in, so
# that is what this reads: byte 4 of each .pyc header, bit 0 = hash-based.
#
# -B on the audit interpreter so this check cannot itself write a .pyc into the
# bundle it is judging -- a self-test must not write into the ledger it judges.
#
# CANNOT-RUN IS NOT A PASS: if the audit cannot read a file or the interpreter
# fails, this refuses rather than treating an empty count as zero.
if ! PYC_TIMESTAMP="$("$BUNDLED_PY" -B -c '
import os, struct, sys
root = sys.argv[1]
n = 0
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        if not fn.endswith(".pyc"):
            continue
        p = os.path.join(dirpath, fn)
        try:
            with open(p, "rb") as fh:
                head = fh.read(8)
        except OSError as exc:
            sys.stderr.write("unreadable %s: %s\n" % (p, exc))
            sys.exit(3)
        if len(head) < 8:
            sys.stderr.write("truncated %s\n" % p)
            sys.exit(3)
        if not (struct.unpack("<I", head[4:8])[0] & 1):
            n += 1
            if n <= 10:
                sys.stderr.write("  timestamp-mode: %s\n" % os.path.relpath(p, root))
print(n)
' "$PYTHON_DIR")"; then
    echo "ERROR: could not audit .pyc invalidation modes in $PYTHON_DIR" >&2
    echo "       This is CANNOT-RUN, which is neither pass nor fail -- and an" >&2
    echo "       unverified seal is not a verified one. Refusing to sign." >&2
    exit 1
fi
case "$PYC_TIMESTAMP" in
    ''|*[!0-9]*)
        echo "ERROR: .pyc mode audit returned '$PYC_TIMESTAMP', not a count." >&2
        echo "       Refusing to sign on an unparseable measurement." >&2
        exit 1 ;;
esac
if [ "$PYC_TIMESTAMP" -ne 0 ]; then
    echo "ERROR: $PYC_TIMESTAMP of $PYC_AFTER seeded .pyc are in TIMESTAMP mode." >&2
    echo "       CPython REWRITES a timestamp-mode .pyc whose recorded source" >&2
    echo "       mtime does not match the .py beside it. That rewrite is a MODIFY" >&2
    echo "       inside the signed bundle: the seal breaks and macOS refuses the" >&2
    echo "       app as damaged, WITHOUT the .pyc count ever changing." >&2
    echo "       This is the v1.0.45/v1.0.46 brick. Refusing to sign." >&2
    exit 1
fi
echo "Invalidation-mode audit: 0 of $PYC_AFTER .pyc in timestamp mode"

# ---------------------------------------------------------------------------
# 🔴 WHOLE-BUNDLE AUDIT: TWO DEFECTS WEAR THE SAME COLOUR
# ---------------------------------------------------------------------------
#
# The audit above is scoped to $PYTHON_DIR and asks ONE question: what mode are
# the .pyc in. That was enough for v1.0.46's defect (a MODIFY) and blind to
# v1.0.45's (an ADD), and v1.0.47 shipped carrying the second one because the
# root excluded the files that had it. Both break the same seal:
#
#     .py with NO .pyc          -> first import ADDS a file      (v1.0.45)
#     .pyc in timestamp mode    -> first import REWRITES a file  (v1.0.46)
#
# So this asks BOTH, over the WHOLE outer bundle rather than one subdirectory.
#
# 🔴 ANTI-VACUITY ON THE DENOMINATOR, NOT JUST THE NUMERATOR. "0 uncovered" is
# also what an empty tree prints. If Resources/ failed to stage, every count
# here is 0 and the audit would pass while shipping nothing -- the uniform-zero
# shape. The floor asserts the .py denominator is real BEFORE trusting a zero.
#
# Nested .app bundles are EXCLUDED and PRINTED, never silently dropped: they
# carry their own signature (sparkle-embed seals Ostler.app with
# `codesign --force --deep` later), so seeding them from here would write into
# a bundle this script does not sign. v1.0.47 measured 87 such .py. That is a
# real residual owned by the hub lane, and it is stated so it can be tracked.
#
# -B again: this check must not write a .pyc into the bundle it is judging.
if ! BUNDLE_AUDIT="$("$BUNDLED_PY" -B -c '
import os, re, struct, sys
root = sys.argv[1]
py = pyc = uncovered = timestamp = nested = 0
have = set()
pycs = []
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        if ".app/" in rel:
            if fn.endswith(".py"):
                nested += 1
            continue
        if fn.endswith(".py"):
            py += 1
        elif fn.endswith(".pyc"):
            pyc += 1
            pycs.append((rel, p))
for rel, p in pycs:
    m = re.match(r"(.*)__pycache__/([^/]+)\.cpython-[0-9]+[^.]*\.pyc$", rel)
    if m:
        have.add(m.group(1) + m.group(2) + ".py")
    try:
        with open(p, "rb") as fh:
            head = fh.read(8)
    except OSError as exc:
        sys.stderr.write("unreadable %s: %s\n" % (p, exc))
        sys.exit(3)
    if len(head) < 8:
        sys.stderr.write("truncated %s\n" % p)
        sys.exit(3)
    if not (struct.unpack("<I", head[4:8])[0] & 1):
        timestamp += 1
        if timestamp <= 10:
            sys.stderr.write("  timestamp-mode: %s\n" % rel)
shown = 0
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        if not fn.endswith(".py"):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fn), root)
        if ".app/" in rel:
            continue
        if rel not in have:
            uncovered += 1
            if shown < 10:
                sys.stderr.write("  no .pyc: %s\n" % rel)
                shown += 1
print("%d %d %d %d %d" % (py, pyc, uncovered, timestamp, nested))
' "$APP_PATH")"; then
    echo "ERROR: could not audit the bundle at $APP_PATH" >&2
    echo "       CANNOT-RUN is neither pass nor fail, and an unverified seal is" >&2
    echo "       not a verified one. Refusing to sign." >&2
    exit 1
fi
set -- $BUNDLE_AUDIT
if [ "$#" -ne 5 ]; then
    echo "ERROR: bundle audit returned '$BUNDLE_AUDIT', not five counts." >&2
    echo "       Refusing to sign on an unparseable measurement." >&2
    exit 1
fi
B_PY="$1"; B_PYC="$2"; B_UNCOVERED="$3"; B_TIMESTAMP="$4"; B_NESTED="$5"
echo "Bundle audit: $B_PY .py / $B_PYC .pyc outside nested apps" \
     "-- uncovered $B_UNCOVERED, timestamp-mode $B_TIMESTAMP;" \
     "$B_NESTED .py inside nested .app EXCLUDED (own signature)"

if [ "$B_PY" -lt 1000 ]; then
    echo "ERROR: only $B_PY .py in the bundle -- expected >=1000 (v1.0.47: 1801)." >&2
    echo "       A zero numerator over a missing denominator is not a pass: the" >&2
    echo "       Resources tree did not stage, so this audit could not look." >&2
    exit 1
fi
if [ "$B_UNCOVERED" -ne 0 ]; then
    echo "ERROR: $B_UNCOVERED of $B_PY .py have NO .pyc beside them." >&2
    echo "       The customer's first import WRITES each one into the signed" >&2
    echo "       bundle. An ADD breaks the seal exactly as a REWRITE does, and" >&2
    echo "       macOS then refuses the app as damaged. This is the v1.0.45" >&2
    echo "       brick, and the residual that vetoed v1.0.47. Refusing to sign." >&2
    exit 1
fi
if [ "$B_TIMESTAMP" -ne 0 ]; then
    echo "ERROR: $B_TIMESTAMP of $B_PYC .pyc in the bundle are TIMESTAMP mode." >&2
    echo "       This is the v1.0.46 brick, outside \$PYTHON_DIR. Refusing." >&2
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
