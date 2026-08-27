#!/usr/bin/env bash
# seed-hub-payload-pyc.sh <OSTLER_APP_PATH> <PYTHON_BUNDLE_TARBALL>
#
# Seed every .py inside Ostler.app with an unchecked-hash .pyc, so the customer's
# first import cannot write into the bundle and void its signature.
#
# WHY HERE. Ostler.app carries its OWN Developer ID signature, sealed by
# sparkle-embed's `codesign --force --deep`. sign-python-bundle.sh deliberately
# refuses to seed it -- writing into a bundle it does not sign would leave the
# .pyc outside any seal. The ship chain has exactly one slot where the files
# exist and the signature does not yet:
#
#     8  stage-daemon
#     9  stage-payload      <- HERE. Payload injected, nothing signed yet.
#    10  sparkle-embed      <- codesign --force --deep SEALS Ostler.app
#
# The Makefile says it in its own words at stage-payload: "the whole point is
# that the payload rides inside the Hub signature envelope". A .pyc seeded here
# rides in the same envelope.
#
# MEASURED on the shipped v1.0.47 nested Ostler.app, with the real pinned
# interpreter, before this script was written:
#
#     cpython-311.pyc      0 -> 86,  0 uncovered, 0 not-unchecked-hash
#     reseal --force --deep                     verify rc=0
#     then the import that used to break it     86 -> 86, codesign rc=0
#     bare startup + a payload import           86 -> 86, codesign rc=0
#
# Without this, ONE unguarded import inside Ostler.app takes its codesign 0 -> 1
# and spctl 0 -> 1 with "a sealed resource is missing or invalid" -- macOS
# refuses the Hub. That is the v1.0.45 brick, one bundle down.
#
# 🔴 THE INTERPRETER MUST BE 3.11, AND THAT IS NOT PEDANTRY.
# CPython looks for `<name>.cpython-<tag>.pyc`. A seed written by the runner's
# system python3 lands as `cpython-314.pyc`, which 3.11 NEVER LOOKS AT -- it
# compiles its own and writes it into the bundle. The build would report
# success, the files would be on disk, a .pyc count would be satisfied, and the
# seal would still break on the customer's first run. So this script extracts
# the PINNED tarball and asserts the interpreter's cache_tag before using it.
#
# FAILS CLOSED throughout: a partial seed is worse than none, because whatever
# failed to compile is exactly what the first import writes into the seal.

set -uo pipefail

APP="${1:-}"
TARBALL="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$APP" ]     || die "usage: seed-hub-payload-pyc.sh <OSTLER_APP_PATH> <PYTHON_BUNDLE_TARBALL>"
[ -n "$TARBALL" ] || die "usage: seed-hub-payload-pyc.sh <OSTLER_APP_PATH> <PYTHON_BUNDLE_TARBALL>"
[ -d "$APP" ]     || die "not a directory: $APP"
[ -f "$TARBALL" ] || die "python bundle tarball not found: $TARBALL
       download-python (step 7) produces it; this runs at stage-payload (step 9)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubseed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf '[STEP] Seeding Ostler.app bytecode before the Sparkle seal\n'

# ---- the interpreter ------------------------------------------------------
# Resolve by find rather than hardcoding python/bin/python3.11: the layout is
# python-build-standalone's, not ours, and a silent layout change should be a
# loud failure here rather than a wrong path later.
tar -xzf "$TARBALL" -C "$WORK" || die "could not extract $TARBALL"
N_PY="$(find "$WORK" -type f -perm -111 -name 'python3.11' | wc -l | tr -d ' ')"
[ "$N_PY" = "1" ] || die "expected exactly ONE python3.11 in the bundle, found $N_PY.
       Refusing to guess which interpreter seeds the seal."
PY="$(find "$WORK" -type f -perm -111 -name 'python3.11' | head -1)"

TAG="$("$PY" -c 'import sys; print(sys.implementation.cache_tag)' 2>/dev/null)" \
    || die "the extracted interpreter would not run. CANNOT-RUN is not a pass."
[ "$TAG" = "cpython-311" ] || die "interpreter cache_tag is '$TAG', not cpython-311.
       A .pyc named for the wrong tag is invisible to the interpreter that
       ships, so it would be regenerated INTO THE SEAL at first import while
       every count here looked correct."
printf '[OK] seeding interpreter: %s (cache_tag %s)\n' "$("$PY" -c 'import sys;print(sys.version.split()[0])')" "$TAG"

# ---- the seed -------------------------------------------------------------
# No -x. Nested bundles inside Ostler.app (the agent app, Sparkle's Updater)
# are resealed by the SAME `codesign --force --deep` that seals Ostler.app, so
# seeding them is safe here in a way it is NOT in sign-python-bundle.sh.
if ! env PYTHONDONTWRITEBYTECODE=1 "$PY" -m compileall -q -f \
        --invalidation-mode unchecked-hash "$APP"; then
    die "compileall failed inside $APP.
       A PARTIAL seed is worse than none: whatever failed to compile is exactly
       what the customer's first import writes into the signed bundle."
fi

# ---- assert the property, not the flag ------------------------------------
# -B so this audit cannot itself write a .pyc into the bundle it is judging.
AUDIT="$("$PY" -B -c '
import os, struct, sys
root = sys.argv[1]
py = pyc = uncovered = wrongmode = 0
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        if fn.endswith(".py"):
            py += 1
            if not os.path.exists(os.path.join(dirpath, "__pycache__",
                                               fn[:-3] + ".cpython-311.pyc")):
                uncovered += 1
                if uncovered <= 10:
                    sys.stderr.write("  no .pyc: %s\n" % os.path.relpath(p, root))
        elif fn.endswith(".pyc"):
            pyc += 1
            try:
                head = open(p, "rb").read(8)
            except OSError as exc:
                sys.stderr.write("unreadable %s: %s\n" % (p, exc)); sys.exit(3)
            if len(head) < 8:
                sys.stderr.write("truncated %s\n" % p); sys.exit(3)
            fl = struct.unpack("<I", head[4:8])[0]
            if not (fl & 1) or (fl & 2):
                wrongmode += 1
                if wrongmode <= 10:
                    sys.stderr.write("  not unchecked-hash: %s\n" % os.path.relpath(p, root))
print("%d %d %d %d" % (py, pyc, uncovered, wrongmode))
' "$APP")" || die "could not audit $APP. CANNOT-RUN is neither pass nor fail,
       and an unverified seal is not a verified one."

set -- $AUDIT
[ "$#" -eq 4 ] || die "audit returned '$AUDIT', not four counts."
A_PY="$1"; A_PYC="$2"; A_UNCOVERED="$3"; A_WRONGMODE="$4"
printf '[OK] Ostler.app: %s .py / %s .pyc -- uncovered %s, wrong-mode %s\n' \
       "$A_PY" "$A_PYC" "$A_UNCOVERED" "$A_WRONGMODE"

# ANTI-VACUITY. A zero numerator over a missing denominator is not a pass: if
# the payload failed to stage, every count is 0 and this would "succeed" while
# sealing nothing. v1.0.47 measured 86 .py inside Ostler.app.
[ "$A_PY" -ge 20 ] || die "only $A_PY .py inside $APP -- expected >=20 (v1.0.47: 86).
       The payload did not stage, so this audit could not look."
[ "$A_UNCOVERED" -eq 0 ] || die "$A_UNCOVERED of $A_PY .py have NO .pyc beside them.
       The customer's first import writes each one into the bundle Sparkle is
       about to seal, and macOS then refuses the Hub as damaged."
[ "$A_WRONGMODE" -eq 0 ] || die "$A_WRONGMODE of $A_PYC .pyc are not unchecked-hash.
       Any other mode can be invalidated and rewritten in place, which breaks
       the seal without changing a single count."

printf '[OK] Ostler.app bytecode sealed-pending-sparkle (%s .pyc, all unchecked-hash)\n' "$A_PYC"
