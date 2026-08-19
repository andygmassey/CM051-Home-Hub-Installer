#!/usr/bin/env bash
#
# tests/test_cut_dispatch_is_dry.sh -- self-test for the dispatch-cannot-ship
# gate, plus the live assertion on this repo's own cut.yml (task #359).
#
# WHY THE CONTROLS AND NOT JUST THE LIVE CHECK.
#
# The gate's whole job is to notice that a workflow_dispatch has become able to
# ship. A checker that never fires is indistinguishable from a repo that is
# safe, and this repo has the scar for it: three orphan-gate proof scripts ran
# in no workflow at all while the gate they proved was relied on by every cut.
# Per feedback_gate_must_prove_it_fires_not_just_compile, a gate with no
# demonstrated RED is a claim, not a gate.
#
# So every control below pins a DIRECTION. Six say "this must fire", four say
# "this must NOT" -- because a gate that flags the innocent gets switched off
# within a week, and that is the same outcome as never having written it.
#
# The last control runs the gate against the REAL .github/workflows/cut.yml, so
# a PR that reopens the route fails here rather than in a reviewer's head.
#
# Exit 0 every control passed / 1 a control failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/verify_dispatch_cannot_ship.py"
LIVE="$REPO_ROOT/.github/workflows/cut.yml"

if ! command -v python3 >/dev/null 2>&1; then
    echo "CANNOT RUN: python3 unavailable, so the gate cannot be exercised." >&2
    echo "This is a cannot-run (exit 2), not a pass." >&2
    exit 2
fi
if [ ! -f "$GATE" ]; then
    echo "CANNOT RUN: gate not found at $GATE" >&2
    exit 2
fi
if [ ! -f "$LIVE" ]; then
    echo "CANNOT RUN: no workflow at $LIVE" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatchgate-XXXXXX")" || {
    echo "CANNOT RUN: could not make a scratch dir" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# expect <label> <want_rc> <workflow-path> [grep-for-in-output]
expect() {
    _label="$1"; _want="$2"; _wf="$3"; _needle="${4:-}"
    _out="$(python3 "$GATE" "$_wf" 2>&1)"; _rc=$?
    if [ "$_rc" != "$_want" ]; then
        bad "$_label -- expected exit $_want, got $_rc"
        printf '%s\n' "$_out" | sed 's/^/        /'
        return
    fi
    if [ -n "$_needle" ] && ! printf '%s' "$_out" | grep -q "$_needle"; then
        bad "$_label -- exit $_rc was right but the reason never mentioned '$_needle'"
        printf '%s\n' "$_out" | sed 's/^/        /'
        return
    fi
    ok "$_label (exit $_rc)"
}

# A minimal but structurally faithful cut.yml: a read-only dispatch-reachable
# gate job, and a tag-gated job that ships. Controls mutate ONE thing at a time
# from this baseline, so each red has exactly one cause.
baseline() {
    _d="$WORK/$1"; rm -rf "$_d"; mkdir -p "$_d/.github/workflows"
    cat > "$_d/.github/workflows/cut.yml" <<'YAML'
name: cut

on:
  push:
    tags:
      - 'v1.0.*'
  workflow_dispatch:

permissions:
  contents: write
  id-token: write

jobs:
  preflight:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: gates
        run: ./tests/some_gate.sh

  cut:
    needs: preflight
    if: github.event_name == 'push'
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Build, sign, notarise, staple
        run: make -C gui ship
      - uses: actions/upload-artifact@v4
        with:
          name: dmg
          path: dist/*.dmg

  dry-run:
    needs: preflight
    if: github.event_name == 'workflow_dispatch'
    runs-on: macos-26
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: gates only
        run: bash scripts/dry_run_cut_checks.sh
YAML
    printf '%s' "$_d/.github/workflows/cut.yml"
}

printf '== test_cut_dispatch_is_dry ==\n'

# --- 0. the baseline is CLEAN. Without this every red below is meaningless,
#        because a gate that fires on everything proves nothing. -------------
WF="$(baseline clean)"
expect "a gates-only dispatch + tag-gated cut is CLEAN" 0 "$WF" "no dispatch-reachable job can"

# --- 1. THE DEFECT: an input appears on workflow_dispatch --------------------
# This is the shape the ratified header refuses: a knob. It does not matter
# that its default is the safe one; a default is a suggestion.
WF="$(baseline input)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "  workflow_dispatch:\n",
    "  workflow_dispatch:\n    inputs:\n      really_ship:\n        type: boolean\n        default: false\n")
open(p, "w").write(s)
PY
expect "a workflow_dispatch INPUT is a violation" 1 "$WF" "declares something"

# --- 2. THE DEFECT: the shipping job loses its event gate -------------------
WF="$(baseline ungated)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("    if: github.event_name == 'push'\n", "", 1)
open(p, "w").write(s)
PY
expect "an UNGATED job that runs 'make ship' is a violation" 1 "$WF" "NOT gated on a tag push"

# --- 3. THE DEFECT: a signing step is added to the dispatch-reachable job ---
# The job keeps its dispatch gate and its read-only permissions, and is still a
# violation, because it can now sign.
WF="$(baseline signs)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: just a quick resign\n        run: codesign --force --sign \"$ID\" a.app\n")
open(p, "w").write(s)
PY
expect "a codesign step in a dispatch-reachable job is a violation" 1 "$WF" "NOT gated on a tag push"

# --- 4. THE DEFECT: the capability is hidden in a local composite action ----
# The step in the workflow is innocent; the action it calls is not. Without
# following `uses: ./...` the whole gate is bypassed by one file move.
WF="$(baseline composite)"
mkdir -p "$WORK/composite/.github/actions/helper"
cat > "$WORK/composite/.github/actions/helper/action.yml" <<'YAML'
name: helper
runs:
  using: composite
  steps:
    - shell: bash
      run: xcrun notarytool submit thing.zip --keychain-profile ostler-ci --wait
YAML
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n",
    "      - uses: ./.github/actions/helper\n      - name: gates only\n")
open(p, "w").write(s)
PY
expect "a capability hidden in a local composite action is a violation" 1 "$WF" "in ./.github/actions/helper"

# --- 5. THE DEFECT: the dispatch-reachable job takes contents: write --------
# It ships nothing today. It could publish tomorrow, and nothing would fire.
WF="$(baseline perms)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
head, sep, tail = s.partition("  dry-run:")
tail = tail.replace("    permissions:\n      contents: read\n",
                    "    permissions:\n      contents: write\n", 1)
open(p, "w").write(head + sep + tail)
PY
expect "a dispatch-reachable job with contents: write is a violation" 1 "$WF" "write access to contents"

# --- 6. THE DEFECT: a dispatch-reachable job with NO permissions block ------
# Silence inherits contents: write from the workflow. An omission is not a
# default here, it is the violation.
WF="$(baseline noperms)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
head, sep, tail = s.partition("  dry-run:")
tail = tail.replace("    permissions:\n      contents: read\n", "", 1)
open(p, "w").write(head + sep + tail)
PY
expect "a dispatch-reachable job with no permissions block is a violation" 1 "$WF" "declares no"

# --- 7. THE DEFECT: the tag route itself is loosened ------------------------
# Everything else here guards the dispatch. If `push` stopped meaning "a tag",
# the guarantee would be gone by the other door.
WF="$(baseline branches)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "  push:\n    tags:\n      - 'v1.0.*'\n",
    "  push:\n    branches: [main]\n")
open(p, "w").write(s)
PY
expect "losing the tag filter on push is a violation" 1 "$WF" "tags"

# --- 8. NOT A VIOLATION: no workflow_dispatch at all ------------------------
# A revert satisfies the directive completely. A gate that forbade the revert
# would be enforcing a preference, not a guarantee.
WF="$(baseline nodispatch)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("  workflow_dispatch:\n", "")
open(p, "w").write(s)
PY
expect "removing workflow_dispatch entirely is CLEAN" 0 "$WF" "satisfied trivially"

# --- 9. NOT A VIOLATION: a job that only ASKS make a question ---------------
# `make print-version` is a question, not a build. A gate that reds on it is a
# gate people route around.
WF="$(baseline question)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n",
    "      - name: which version\n        run: make -C gui --no-print-directory print-version\n"
    "      - name: gates only\n")
open(p, "w").write(s)
PY
expect "'make print-version' in a dispatch job is NOT a violation" 0 "$WF" "cannot write contents"

# --- 10. NOT A VIOLATION: prose. A comment saying the job does not notarise -
# contains the word. verify_test_wiring.sh was corrupted by exactly this shape:
# a comment block documenting dark tests recorded them as live.
WF="$(baseline prose)"
python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n",
    "      # Nothing here signs, notarises or staples. There is no codesign,\n"
    "      # no notarytool and no upload-artifact in this job, on purpose.\n"
    "      - name: gates only\n")
open(p, "w").write(s)
PY
expect "a COMMENT naming codesign/notarytool is NOT a violation" 0 "$WF" "cannot write contents"

# --- 11. CANNOT RUN is not a pass ------------------------------------------
expect "a missing workflow is CANNOT RUN, not a pass" 2 "$WORK/nope/cut.yml"
printf 'on: [push, workflow_dispatch]\njobs:\n  a:\n    runs-on: x\n' > "$WORK/inline.yml"
expect "an inline 'on:' list is CANNOT RUN, not a pass" 2 "$WORK/inline.yml"

# --- 12. THE LIVE ASSERTION ------------------------------------------------
expect "this repo's own .github/workflows/cut.yml is CLEAN" 0 "$LIVE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
