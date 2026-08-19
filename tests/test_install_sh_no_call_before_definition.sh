#!/usr/bin/env bash
# install.sh must never CALL a shell function before the line that DEFINES it.
#
# WHY THIS EXISTS. On 2026-08-18 v1.0.35 was the first DMG anyone could hold, and
# Andy's install aborted at step 15 of 39:
#
#     install.sh: line 13480: _install_enrichment_agent: command not found
#     #OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L13549
#
# The function was CALLED at 13480 and DEFINED at 18386. Bash creates a function
# when its definition line EXECUTES, so a top-level call 4,906 lines earlier hits
# a name that does not exist yet. Deterministic on every box.
#
# It was introduced by the fix for "enrichment had NO invoker" (#747, re-touched
# by #816). The diagnosis was right and the invoker was placed where it cannot
# resolve, which is the same shape as the upload-artifact defect that destroyed
# two notarised DMGs: a correct fix positioned so that running it breaks the run.
#
# `bash -n` does NOT catch this. It parses, it does not order. Nothing else in
# this repo looked at definition order, so the only instrument that could have
# found it was a customer install, and it cost a version to find out.
#
# THE CHECK. Walk install.sh, record where each function is defined, then flag any
# TOP-LEVEL line whose first word is a locally-defined function whose definition
# line comes later. Calls INSIDE another function body are fine: that body does
# not execute until it is called, by which time later definitions have run.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

TARGET="${1:-install.sh}"
FAILED=0

if [[ ! -f "$TARGET" ]]; then
    echo "CANNOT-RUN: $TARGET not found. This is not a pass."
    exit 2
fi

scan() {
    python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
n = len(lines)
fn = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')

defline = {}
for i, l in enumerate(lines, 1):
    m = fn.match(l)
    if m and m.group(1) not in defline:
        defline[m.group(1)] = i

# Top level = not inside any function body. Brace depth, reset at each def.
toplevel = [False] * (n + 1)
depth, infn = 0, False
for i, l in enumerate(lines, 1):
    m = fn.match(l)
    if m and depth == 0:
        infn = True
        depth = l.count('{') - l.count('}')
        continue
    if infn:
        depth += l.count('{') - l.count('}')
        if depth <= 0:
            infn, depth = False, 0
    else:
        toplevel[i] = True

call = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)(\s|$)')
hits = []
for i, l in enumerate(lines, 1):
    if not toplevel[i]:
        continue
    s = l.strip()
    if not s or s.startswith('#'):
        continue
    m = call.match(l)
    if not m:
        continue
    name = m.group(1)
    if name in defline and defline[name] > i:
        hits.append((i, name, defline[name]))

print(f"DEFINED={len(defline)}")
print(f"TOPLEVEL_LINES={sum(toplevel)}")
for i, name, d in hits:
    print(f"HIT\t{i}\t{name}\t{d}")
PY
}

out="$(scan "$TARGET")"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "CANNOT-RUN: the scanner itself failed (rc=$rc). Not a pass."
    exit 2
fi

defined="$(printf '%s\n' "$out" | sed -n 's/^DEFINED=//p')"
toplines="$(printf '%s\n' "$out" | sed -n 's/^TOPLEVEL_LINES=//p')"
hits="$(printf '%s\n' "$out" | grep -c '^HIT' || true)"

# DENOMINATOR. A scan that examined no functions is not a clean scan, and this
# repo has been burnt by a zero that meant "nothing was checkable".
if [[ -z "$defined" || "$defined" -lt 50 ]]; then
    echo "CANNOT-RUN: found only ${defined:-0} function definitions in $TARGET."
    echo "  install.sh carries ~139. A number this low means the scanner is not"
    echo "  reading what it thinks it is reading. Refusing to report a pass."
    exit 2
fi

# POSITIVE CONTROL. Prove the scanner FIRES before believing its zero.
#
# THE CONTROL IS PLANTED INTO A COPY OF THE REAL TARGET, not a toy file, and
# that is the whole point. TNM ran a sweep of this same class on 2026-08-18
# using global brace depth, and heredocs plus embedded python corrupted the
# counter so badly that the KNOWN-TRUE defect at 13480 was classified as 29
# levels deep inside a function. Their detector was blind to the exact thing
# they had just diagnosed from a crash log, and a toy control would have passed
# happily while it was blind.
#
# A control built from `seq` proves the scanner works on input with no
# heredocs, no embedded python and no brace noise. install.sh has all three.
# So the canary goes into the real file, at a provably top-level line: the
# first line after a function definition's closing brace, which is a structural
# boundary rather than a guess about indentation or column.
ctl="$(mktemp -t cbd_control.XXXXXX.sh)"
python3 - "$TARGET" "$ctl" <<'PLANT'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8', errors='replace').read().split('\n')
fn = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')
# Find a function definition, walk to its closing brace: the line AFTER that
# brace is top level by construction, whatever the heredocs are doing.
plant_at = None
for i, l in enumerate(lines, 1):
    if not fn.match(l):
        continue
    d = 0
    for j in range(i - 1, len(lines)):
        d += lines[j].count('{') - lines[j].count('}')
        if d <= 0 and j > i - 1:
            plant_at = j + 1          # 1-based line of the closing brace
            break
    if plant_at:
        break
if plant_at is None:
    sys.exit(3)                       # no function boundary: cannot plant
out = lines[:plant_at] + ["_synthetic_canary_probe"] + lines[plant_at:]
out += ["_synthetic_canary_probe() {", "    echo planted", "}"]
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
PLANT
plant_rc=$?
if [[ $plant_rc -ne 0 ]]; then
    echo "CANNOT-RUN: could not plant the positive control into a copy of ${TARGET} (rc=$plant_rc)."
    rm -f "$ctl"
    exit 2
fi
ctl_hits="$(scan "$ctl" | grep -c '^HIT' || true)"
rm -f "$ctl"

if [[ "$ctl_hits" -lt 1 ]]; then
    echo "CANNOT-RUN: POSITIVE CONTROL DID NOT FIRE."
    echo "  A synthetic call-before-definition was planted and the scanner found"
    echo "  ${ctl_hits}. Its zero on $TARGET therefore means nothing. Fix the scanner."
    exit 2
fi
echo "positive control: scanner found ${ctl_hits} planted defect(s), so a zero is meaningful"
echo "examined: ${defined} function definitions across ${toplines} top-level lines in ${TARGET}"

if [[ "$hits" -gt 0 ]]; then
    echo
    echo "FAIL: ${hits} function(s) CALLED at top level before being DEFINED in ${TARGET}:"
    printf '%s\n' "$out" | grep '^HIT' | while IFS=$'\t' read -r _ line name defat; do
        echo "  ${TARGET}:${line} calls '${name}', which is not defined until line ${defat} (gap $((defat - line)))"
    done
    echo
    echo "Bash creates a function when its definition line EXECUTES. A top-level"
    echo "call above the definition hits a name that does not exist yet and the"
    echo "install dies with 'command not found'. This exact defect aborted"
    echo "v1.0.35 at step 15 of 39 on a customer-shaped box."
    echo "FIX: move the DEFINITION above its first use. Check first that the body's"
    echo "variables are already set at the call site, or you will trade a missing"
    echo "function for a missing value."
    FAILED=1
fi

if [[ $FAILED -eq 0 ]]; then
    echo "PASS: no function is called before it is defined in ${TARGET}."
fi
exit $FAILED
