#!/usr/bin/env bash
# GUARD THE REASON, NOT ONLY THE FLAG.
#
# The nested-bundle exclusion in gui/Makefile's seed-installer-app-pyc exists
# for exactly one reason: `compileall` bakes the ABSOLUTE SOURCE PATH into every
# code object as co_filename, so the SAME interpreter compiling the SAME bytes
# at two different paths emits two DIFFERENT .pyc.
#
# That property is what makes re-seeding an already-sealed bundle at its new
# nested location a content change, and therefore a broken signature. It is
# also the property a future reader is most likely to doubt -- the intuition
# "codesign hashes content, and identical sources give identical bytecode" is
# strong, and it is what the estate believed until the v1.0.49 cut measured
# codesign rc=1, file added=0, file modified=86 on the real artefact.
#
# 🔴 THE ORIGINAL CONTROL WAS IN THE WRONG COMPARTMENT.
# The benign case was measured by compiling ONE tree TWICE and getting an
# identical corpus digest, with a caveat about the interpreter being homebrew
# rather than the pinned build. The interpreter was never the variable. Varying
# it would not have found this; varying the PATH does, on any host, in a second.
#
# If this test ever goes green-by-refutation -- bytes identical across paths --
# the exclusion's justification is gone and somebody must re-derive it before
# touching the Makefile. That is why it asserts a DIFFERENCE and says so.

set -uo pipefail

FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

PY="$(command -v python3.11 || command -v python3 || true)"
[[ -n "$PY" ]] || { echo "FAIL [no-python3]: no python3 on PATH. CANNOT-RUN is not a pass." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TAG="$("$PY" -c 'import sys; print(sys.implementation.cache_tag)')" \
    || { echo "FAIL [interpreter-dead]: $PY would not report its cache_tag." >&2; exit 2; }

# Identical bytes, two roots. Same interpreter, same flags, same content.
mkdir -p "$WORK/A/pkg" "$WORK/B/pkg"
printf 'def f():\n    return 42\n' > "$WORK/A/pkg/m.py"
cp "$WORK/A/pkg/m.py" "$WORK/B/pkg/m.py"

if ! cmp -s "$WORK/A/pkg/m.py" "$WORK/B/pkg/m.py"; then
    echo "FAIL [fixture]: the two sources differ; the experiment would be meaningless." >&2
    exit 2
fi

for r in A B; do
    env PYTHONDONTWRITEBYTECODE=1 "$PY" -m compileall -q -f \
        --invalidation-mode unchecked-hash "$WORK/$r" >/dev/null 2>&1 \
        || { echo "FAIL [compile]: compileall failed on $r. CANNOT-RUN is not a pass." >&2; exit 2; }
done

PA="$WORK/A/pkg/__pycache__/m.${TAG}.pyc"
PB="$WORK/B/pkg/__pycache__/m.${TAG}.pyc"
for p in "$PA" "$PB"; do
    [[ -f "$p" ]] || { echo "FAIL [no-pyc]: expected $p. The compile produced nothing to compare." >&2; exit 2; }
done

HA="$(shasum -a 256 "$PA" | cut -d' ' -f1)"
HB="$(shasum -a 256 "$PB" | cut -d' ' -f1)"

if [[ "$HA" == "$HB" ]]; then
    fail "path-independent-bytecode" "identical sources at two paths produced IDENTICAL .pyc on this host ($PY, $TAG). The nested-bundle exclusion in gui/Makefile is justified by the opposite fact, measured on the runner as 'file modified=86'. Re-derive the justification before trusting either"
else
    pass "same interpreter + same source at two paths => DIFFERENT .pyc (${HA:0:16}... vs ${HB:0:16}...)"
fi

# NAME THE CAUSE, do not merely observe the difference. If the bytes differ for
# some other reason (a timestamp, a nondeterminism), the exclusion is resting on
# a coincidence rather than on co_filename.
NAMES="$("$PY" -B -c '
import marshal, sys
out = []
for p in sys.argv[1:]:
    with open(p, "rb") as fh:
        fh.read(16)
        out.append(marshal.load(fh).co_filename)
print("\n".join(out))
' "$PA" "$PB")" || { fail "unreadable-pyc" "could not read the code objects back to name the cause"; NAMES=""; }

FA="$(head -1 <<< "$NAMES")"
FB="$(tail -1 <<< "$NAMES")"
if [[ -z "$NAMES" ]]; then
    :
elif [[ "$FA" == "$FB" ]]; then
    fail "cause-not-co_filename" "the .pyc differ but both carry the SAME co_filename ($FA), so the difference is something else and the Makefile comment names the wrong cause"
elif [[ "$FA" != *"/A/"* || "$FB" != *"/B/"* ]]; then
    fail "cause-unrecognised" "co_filename values do not match the two roots: '$FA' / '$FB'"
else
    pass "the cause IS co_filename: the absolute compile-time path is embedded in each code object"
fi

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo
echo "PYC PATH-DEPENDENCE MECHANISM CONFIRMED"
