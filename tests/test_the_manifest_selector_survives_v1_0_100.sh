#!/usr/bin/env bash
# The "newest cut manifest" selectors must order 100 above 99, not below 9.
#
# WHY NOW. The current manifest is v1.0.99. THE VERY NEXT CUT IS v1.0.100, and
# that is the first version number in this project's history where a text sort
# and a version sort disagree. Measured on this box, same list through both:
#
#   sort -V   ... v1.0.9  v1.0.72  v1.0.99  v1.0.100   <- correct
#   sort      v1.0.100  v1.0.72  v1.0.9  v1.0.99       <- 100 sorts FIRST
#
# A selector on the wrong side of that picks v1.0.99 forever: the cut would
# gate itself against the PREVIOUS cut's checklist, every row would already be
# satisfied, and it would look clean. That is not a hypothetical shape here,
# it is issue 1586.
#
# Both live selectors are already correct (`sort -V` in shell, integer tuples
# in Python). NOTHING ASSERTED THAT. This makes the boundary a measured
# property before the cut that crosses it, rather than after.
#
# The fixture is synthetic and in a temp dir: this asserts the ORDERING RULE,
# not the contents of cut-manifests/, so it keeps working after v1.0.100 ships
# and does not need editing every version.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0; PASS=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/cut-manifests"
for v in v1.0.9 v1.0.72 v1.0.98 v1.0.99 v1.0.100 v1.0.101; do : > "$t/cut-manifests/$v.yaml"; done
WANT="v1.0.101"

# ARM 1: the shell selector, in the exact pipeline the two call sites use.
got="$(ls "$t"/cut-manifests/v*.yaml 2>/dev/null \
       | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//' | sort -V | tail -1)"
if [ "$got" = "$WANT" ]; then
    ok "shell selector (sort -V) picks $got across the 100 boundary"
else
    bad "shell selector picked '$got', wanted $WANT. A cut would gate itself
         against an older checklist whose rows are already satisfied, and read
         as clean."
fi

# ARM 2: the Python selector, same rule as newest_manifest().
got_py="$(python3 - "$t" <<'PY'
import sys, pathlib, re
best=None; best_key=()
for p in (pathlib.Path(sys.argv[1])/"cut-manifests").glob("v*.yaml"):
    m=re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", p.stem)
    if not m: continue
    k=tuple(int(x) for x in m.groups())
    if k>best_key: best_key,best=k,p
print(best.stem if best else "")
PY
)"
if [ "$got_py" = "$WANT" ]; then
    ok "python selector (integer tuples) picks $got_py across the 100 boundary"
else
    bad "python selector picked '$got_py', wanted $WANT"
fi

# ARM 3: POSITIVE CONTROL. The failure mode must be reproducible on this very
# box, or the two passes above could be a fixture that cannot discriminate.
naive="$(ls "$t"/cut-manifests/v*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | sort | tail -1)"
if [ "$naive" != "$WANT" ]; then
    ok "CONTROL: a plain text sort picks '$naive' on the same fixture, so the boundary really does discriminate"
else
    bad "CONTROL FAILED: a plain text sort also picked $WANT, so this fixture
         cannot tell a correct selector from a broken one and both passes above
         are meaningless."
fi

# ARM 4: the selectors in the tree must still BE the ones tested above.
# A test that pins a rule the product no longer uses is a test of nothing.
live="$(/usr/bin/grep -rl 'cut-manifests/v\*\.yaml' tests/ scripts/ 2>/dev/null | sort -u)"
n_live="$(printf '%s\n' "$live" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "${n_live:-0}" -lt 2 ]; then
    echo "  [CANNOT-RUN] found ${n_live:-0} live selector(s), expected at least 2."
    echo "               Either they moved or this search stopped matching; a zero"
    echo "               here is the predicate failing, not a clean tree."
    exit 2
fi
# CHECK THE SELECTOR LINE, NOT THE FILE. The first version of this arm grepped
# the whole file for a version-aware sort, and a mutation that downgraded the
# real selector still passed, because the file happened to contain another
# `sort -V` elsewhere. A file-level predicate answers a different question from
# the one being asked. The selector can wrap, so the region is the matching
# line plus the two after it, which is what both live call sites span.
unsorted="$(printf '%s\n' "$live" | while read -r f; do
    [ -n "$f" ] || continue
    region="$(/usr/bin/grep -A2 'cut-manifests/v\*\.yaml' "$f" 2>/dev/null)"
    printf '%s' "$region" | /usr/bin/grep -q 'sort -V' || printf '%s ' "$f"
done)"
if [ -z "$unsorted" ]; then
    ok "all ${n_live} live selector(s) still use a version-aware sort"
else
    bad "these select a manifest without a version-aware sort: ${unsorted}"
fi

printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
