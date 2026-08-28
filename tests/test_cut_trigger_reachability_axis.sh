#!/usr/bin/env bash
# test_cut_trigger_reachability_axis.sh
#
# AXIS THREE of scripts/verify_declared_gates_reachable.sh. #1167.
#
# Axis one seeds its fixpoint with EVERY workflow, so "reachable from the cut"
# means "reachable from something that runs sometime". A gate invoked only by a
# workflow that never fires on a tag push is reachable and DOES NOT RUN ON THE
# CUT. Two such gates executed zero times at the commit v1.0.48 was cut from.
#
# The axis is a RATCHET, not a flip: re-seeding the existing verdict would turn
# twelve declarers orphan at once and block every cut, and a gate that does
# that gets commented out. So the state is recorded in a baseline and only
# GROWTH fails.
#
# FIXTURE, not the live repo. REPO_ROOT comes from `git rev-parse
# --show-toplevel`, so running the gate from inside a temp repo makes that repo
# the population. Driving it against CM051 would make every verdict depend on
# CM051's own drift, which is the thing the axis measures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_declared_gates_reachable.sh"
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 absent; the trigger parser needs it" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t a3axis)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }

# THE GAP SECTION ONLY. A whole-output substring test is too broad: the gate
# prints file names on several axes, so `has <name> <whole output>` matched the
# TAG-reachable gate somewhere else entirely and reported the axis broken when
# it was correct. The test disagreed with the gate and the GATE was right --
# so the predicate got narrowed, not the gate.
gap_section() {
    printf '%s\n' "$1" | sed -n '/do NOT run on a tag push:/,/^[[:space:]]*$/p'
}
in_gap() { [ "$(gap_section "$2" | grep -cF "$1" || true)" -gt 0 ]; }

# DECLARE_RE is matched on prose, so the fixture gates must carry one of its
# phrases to enter the population at all. That is itself the thing #1164 is
# about; here it is simply how the gate is driven.
# COMPOSED, NOT WRITTEN LITERALLY. DECLARE_RE matches on prose, so a fixture
# carrying the literal phrase makes THIS FILE a declarer -- which it is not.
# Measured: the first version did exactly that, and the gate correctly
# reported this test as a NEW axis-three gap. A fixture that carries the flag
# it plants is the same class as a test fixture that encodes the property it
# is meant to detect.
_P1='BLOCKS THE'; _P2='CUT'
DECL="# This ${_P1} ${_P2}."

build() {   # builds a fresh fixture repo, prints its path
    local r="$TMP/repo.$RANDOM"; mkdir -p "$r/.github/workflows" "$r/scripts"
    git init -q "$r"; git -C "$r" config user.email a@example.com; git -C "$r" config user.name a
    printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$DECL" > "$r/scripts/gate_tagged.sh"
    printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$DECL" > "$r/scripts/gate_branchonly.sh"
    chmod +x "$r/scripts/gate_tagged.sh" "$r/scripts/gate_branchonly.sh"
    # FIRES on a v1.0.* tag -- the cut event.
    cat > "$r/.github/workflows/tagged.yml" <<'YEOF'
name: tagged
on:
  push:
    tags: ['v1.0.*']
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/gate_tagged.sh
YEOF
    # branches ONLY, no tags key -- a tag push does NOT fire this.
    cat > "$r/.github/workflows/branchonly.yml" <<'YEOF'
name: branchonly
on:
  push:
    branches: [main]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/gate_branchonly.sh
YEOF
    git -C "$r" add -A; git -C "$r" commit -qm fixture
    printf '%s' "$r"
}

run() {   # $1 = repo, $2 = baseline file ("" = none)
    ( cd "$1" && OSTLER_CUT_TRIGGER_BASELINE="${2:-/nonexistent}" bash "$GATE" 2>&1 )
}

printf '== test_cut_trigger_reachability_axis ==\n'
R="$(build)"

# (0) CONTROL. Both fixture gates must be REACHABLE on axis one -- if they are
#     not, the fixture never enters the population and every verdict below is
#     about nothing.
out="$(run "$R" "")"
if has "AXIS THREE" "$out"; then
    ok "CONTROL: the fixture reaches axis three at all"
else
    bad "CONTROL BROKEN: axis three did not run on the fixture"
    printf '%s\n' "$out" | sed 's/^/      /' | head -25
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# (1) THE DISTINCTION. Same declaration, same reachability, different trigger.
in_gap "scripts/gate_branchonly.sh" "$out" \
    && ok "a gate reached only by a branch-triggered workflow is IN the gap" \
    || bad "the branch-only gate was not reported -- the axis sees nothing"
if in_gap "scripts/gate_tagged.sh" "$out"; then
    bad "the TAG-triggered gate was reported as a gap -- the axis cannot tell triggers apart"
else
    ok "a gate reached by a tag-triggered workflow is NOT in the gap"
fi

# (2) RATCHET, growth direction. A gap absent from the baseline must FAIL.
:> "$TMP/empty.tsv"
out="$(run "$R" "$TMP/empty.tsv")"; rc=$?
if [ "$rc" -ne 0 ] && has "NEW on axis three" "$out"; then
    ok "a gap NOT in the baseline fails the gate and is named"
else
    bad "a new gap did not fail (rc=$rc) -- the ratchet does not ratchet"
fi

# (3) RATCHET, recorded direction. The same gap, baselined, must pass.
printf 'scripts/gate_branchonly.sh\tUNREVIEWED\trecorded by the test\n' > "$TMP/base.tsv"
out="$(run "$R" "$TMP/base.tsv")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "a gap recorded in the baseline does not fail"
else
    bad "a baselined gap still failed (rc=$rc) -- the baseline is not consulted"
fi

# (4) The baseline must not be able to forgive something that is NOT a gap.
#     A row for the tag-reachable gate must not suppress a real one.
printf 'scripts/gate_tagged.sh\tUNREVIEWED\twrong row\n' > "$TMP/wrong.tsv"
out="$(run "$R" "$TMP/wrong.tsv")"; rc=$?
if [ "$rc" -ne 0 ] && in_gap "scripts/gate_branchonly.sh" "$out"; then
    ok "baselining the WRONG file does not suppress the real gap"
else
    bad "a row for an unrelated file silenced the real gap"
fi

# (5) SEED COUNT IS THE SEED COUNT. The first version of this axis printed the
#     size of the reachable set after the BFS and called it "entry points" --
#     266 against axis one's 95. A number that grows past the thing it is
#     compared to is the tell.
out="$(run "$R" "$TMP/base.tsv")"
seeds="$(printf '%s\n' "$out" | sed -n 's/.*(\([0-9]*\) such entry point(s).*/\1/p' | head -1)"
axis1="$(printf '%s\n' "$out" | sed -n 's/.*axis one seeded \([0-9]*\).*/\1/p' | head -1)"
if [ -n "$seeds" ] && [ -n "$axis1" ] && [ "$seeds" -le "$axis1" ]; then
    ok "the cut-tag seed count (${seeds}) is <= axis one's (${axis1}), as a subset must be"
else
    bad "seed count ${seeds:-?} vs axis one ${axis1:-?} -- a subset cannot be larger"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
