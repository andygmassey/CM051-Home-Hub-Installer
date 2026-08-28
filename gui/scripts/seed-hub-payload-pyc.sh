#!/usr/bin/env bash
# seed-hub-payload-pyc.sh <APP_ROOT> <PYTHON_BUNDLE_TARBALL>
#                         [SUBJECT_LABEL] [MIN_PY] [EXCLUDE_RX]
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
# SUBJECT LABEL and ANTI-VACUITY FLOOR are per-root, because this script now
# seeds TWO roots and they have different populations.
#
# 🔴 NAME THE SUBJECT, NOT THE INSTRUMENT. Before this, the [OK] lines below
# printed the literal string "Ostler.app" regardless of what $APP actually was.
# Pointed at a second root that would have reported a TRUE COUNT UNDER A FALSE
# SUBJECT -- the precise failure this estate has paid for repeatedly.
#
# The floor cannot be shared either: Ostler.app carries ~86 .py and
# OstlerInstaller.app ~1888, but the nested daemon app carries ONE, so a single
# hardcoded >=20 is either vacuous for the big roots or a false "did not stage"
# for a small one. Defaults reproduce the previous behaviour EXACTLY for the
# existing arm-1 call site, which passes neither argument.
LABEL="${3:-Ostler.app}"
MIN_PY="${4:-20}"
# EXCLUDE_RX -- paths compileall must NOT WRITE TO. Default empty, so arm 1's
# call site (which passes neither this nor the two before it) behaves EXACTLY
# as before.
#
# 🔴 WHY THIS ARGUMENT EXISTS. It is not a tidy-up. v1.0.49 attempt 4 died
# here, and the guard below the seed at the arm-8 call site is what caught it:
#
#     [OK] nested Ostler.app: codesign rc=1, file added=0, file modified=86
#     ERROR: seeding $(APP_PATH) disturbed the nested Ostler.app seal.
#
# The comment at the seed itself said "-x is unnecessary, nested bundles are
# resealed by the SAME codesign --force --deep that seals this root". That was
# TRUE of the root it was written for (arm 1 = the source Ostler.app) and FALSE
# of the root arm 8 later pointed it at (OstlerInstaller.app, which
# sign-python-bundle signs WITHOUT --deep). The sentence did not change; the
# subject underneath it did. A reseal claim is only ever true of ONE root.
#
# So the exclusion is per-CALL-SITE, never global: the correct answer differs
# between the two roots, and hardcoding either one is wrong for the other.
EXCLUDE_RX="${5:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$APP" ]     || die "usage: seed-hub-payload-pyc.sh <APP_ROOT> <PYTHON_BUNDLE_TARBALL> [SUBJECT_LABEL] [MIN_PY] [EXCLUDE_RX]"
[ -n "$TARBALL" ] || die "usage: seed-hub-payload-pyc.sh <APP_ROOT> <PYTHON_BUNDLE_TARBALL> [SUBJECT_LABEL] [MIN_PY] [EXCLUDE_RX]"
case "$MIN_PY" in ''|*[!0-9]*) die "MIN_PY must be a non-negative integer, got '$MIN_PY'";; esac
[ -d "$APP" ]     || die "not a directory: $APP"
[ -f "$TARBALL" ] || die "python bundle tarball not found: $TARBALL
       download-python (step 7) produces it; this runs at stage-payload (step 9)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubseed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf '[STEP] Seeding %s bytecode before its seal\n' "$LABEL"

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
# Nested bundles inside this root are seeded too, EXCEPT where the caller names
# an exclusion. Whether seeding a nested bundle is safe is a property of THE
# ROOT, not of this script: safe wherever a later `codesign --force --deep`
# reseals the whole root (arm 1 over the source Ostler.app), unsafe wherever the
# root is signed WITHOUT --deep (arm 8 over OstlerInstaller.app). That is why
# the exclusion is an argument and not a constant. See EXCLUDE_RX above.
CA=(-m compileall -q -f --invalidation-mode unchecked-hash)
if [ -n "$EXCLUDE_RX" ]; then
    # 🔴 PROVE THE EXCLUSION FIRES BEFORE TRUSTING IT.
    # A regex that matches nothing is a silent no-op: compileall still exits 0,
    # every count printed below is identical, and the log reads exactly like a
    # correct run while the seal this exclusion exists to defend breaks again
    # downstream. An exclusion nobody has watched exclude something is a comment.
    HITS="$("$PY" -B -c '
import os, re, sys
try:
    rx = re.compile(sys.argv[2])
except re.error as exc:
    sys.stderr.write("not a valid regular expression: %s\n" % exc)
    sys.exit(2)
n = 0
for dirpath, dirnames, filenames in os.walk(sys.argv[1]):
    for fn in filenames:
        if fn.endswith(".py") and rx.search(os.path.join(dirpath, fn)):
            n += 1
print(n)
' "$APP" "$EXCLUDE_RX")" || die "could not evaluate the exclusion against $APP.
       CANNOT-RUN is neither pass nor fail, and an unevaluated exclusion is not
       an applied one."
    case "$HITS" in
        ''|*[!0-9]*) die "the exclusion probe returned '$HITS', which is not a count." ;;
    esac
    [ "$HITS" -gt 0 ] || die "the exclusion matches ZERO .py under $APP.
       An exclusion that excludes nothing is a no-op that READS AS PROTECTION.
       Either the nested bundle moved or the pattern is wrong, and both mean the
       seal this defends is about to break exactly as it did in v1.0.49."
    CA+=(-x "$EXCLUDE_RX")
    printf '[OK] excluding %s .py from the WRITE (pattern: %s)\n' "$HITS" "$EXCLUDE_RX"
    printf '[--] THIS COUNT IS THE POSITIVE CONTROL, and it is the ONLY line that\n'
    printf '[--] tells you whether the exclusion applied. It must equal the .py\n'
    printf '[--] count reported by the arm that OWNS that bundle. In v1.0.49 both\n'
    printf '[--] were 86: arm 1 at stage-payload said "86 .py / 86 .pyc", and arm 8\n'
    printf '[--] broke exactly 86. 86 == 86 is the proof that excluding loses NO\n'
    printf '[--] coverage -- arm 8 was never covering those files, it was REWRITING\n'
    printf '[--] files arm 1 had already covered, and breaking the seal to do it.\n'
    printf '[--] RESIDUAL, STATED OUT LOUD: this arm does NOT seed those %s files.\n' "$HITS"
    printf '[--] The audit below still WALKS them, so any uncovered one fails here.\n'
    printf '[--] 🔴 THE AUDIT TOTAL BELOW DOES *NOT* DROP BY %s, AND MUST NOT.\n' "$HITS"
    printf '[--] It is os.walk over the WHOLE root and is deliberately blind to -x.\n'
    printf '[--] It printed 1888 before the exclusion and it prints 1888 after.\n'
    printf '[--] A reviewer predicted 1802 and would have read a HEALTHY build as a\n'
    printf '[--] failed exclusion. Worse, the obvious "fix" -- teaching the audit to\n'
    printf '[--] skip the excluded subtree -- deletes the only thing keeping this\n'
    printf '[--] safe: that an uncovered or wrong-mode .py in there still fails HERE.\n'
fi
if ! env PYTHONDONTWRITEBYTECODE=1 "$PY" "${CA[@]}" "$APP"; then
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
printf '[OK] %s: %s .py / %s .pyc -- uncovered %s, wrong-mode %s\n' \
       "$LABEL" "$A_PY" "$A_PYC" "$A_UNCOVERED" "$A_WRONGMODE"

# ANTI-VACUITY. A zero numerator over a missing denominator is not a pass: if
# the payload failed to stage, every count is 0 and this would "succeed" while
# sealing nothing. v1.0.47 measured 86 .py inside Ostler.app.
[ "$A_PY" -ge "$MIN_PY" ] || die "only $A_PY .py inside $APP ($LABEL) -- expected >=$MIN_PY.
       The payload did not stage, so this audit could not look."
[ "$A_UNCOVERED" -eq 0 ] || die "$A_UNCOVERED of $A_PY .py have NO .pyc beside them.
       The customer's first import writes each one into the bundle Sparkle is
       about to seal, and macOS then refuses the Hub as damaged."
[ "$A_WRONGMODE" -eq 0 ] || die "$A_WRONGMODE of $A_PYC .pyc are not unchecked-hash.
       Any other mode can be invalidated and rewritten in place, which breaks
       the seal without changing a single count."

printf '[OK] %s bytecode sealed-pending-seal (%s .pyc, all unchecked-hash)\n' "$LABEL" "$A_PYC"
