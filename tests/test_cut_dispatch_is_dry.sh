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

# mutate <workflow-path>   with the python mutation on stdin
#
# 🔴 A MUTANT THAT DID NOT APPLY LOOKS EXACTLY LIKE ONE THAT WAS NOT CAUGHT,
# and this file proved it on itself. Three controls were added whose python
# carried a real newline inside a string literal. Every one was a SyntaxError,
# so python3 exited non-zero, wrote nothing, and the control then ran the gate
# against a PRISTINE baseline. The two written as must-miss controls reported
# PASS. They were not testing anything at all.
#
# `python3 - "$WF" <<PY` cannot notice that, because the mutation's exit status
# is discarded before the gate is ever invoked. So the mutation now has to
# prove two things before its control is allowed to mean anything: that it RAN,
# and that it CHANGED THE FILE. A control whose mutation did neither is a
# failure, never a pass.
MUT_OK=1
mutate() {
    _mwf="$1"
    _before="$(cksum < "$_mwf")"
    if ! python3 - "$_mwf"; then
        bad "MUTATION DID NOT RUN against $_mwf -- the control below proves nothing"
        MUT_OK=0
        return 1
    fi
    _after="$(cksum < "$_mwf")"
    if [ "$_before" = "$_after" ]; then
        bad "MUTATION LEFT $_mwf BYTE-IDENTICAL -- the control below proves nothing"
        MUT_OK=0
        return 1
    fi
    MUT_OK=1
    return 0
}

# expect <label> <want_rc> <workflow-path> [grep-for-in-output]
expect() {
    _label="$1"; _want="$2"; _wf="$3"; _needle="${4:-}"
    # A control whose mutation did not apply must not print a verdict at all.
    # mutate() has already recorded the failure; grading the PRISTINE file here
    # would print PASS beside that FAIL on every must-miss control, which is
    # the reading that hid the defect in the first place.
    if [ "$MUT_OK" -eq 0 ]; then
        printf '  SKIP  %s -- its mutation did not apply (see the FAIL above)\n' "$_label"
        MUT_OK=1
        return
    fi
    MUT_OK=1
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
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("    if: github.event_name == 'push'\n", "", 1)
open(p, "w").write(s)
PY
# WHY THE REASON CHANGED. Under the contract #2118 introduced, `make ship` in a
# dispatch-reachable job is no longer a violation BY ITSELF: building a
# candidate on a dispatch is the point. What is still a violation is this job
# holding the workflow's `contents: write` while a dispatch can reach it. The
# exit code is unchanged; the reason is now the permission, and the needle
# below pins that, so a future change that reds for the wrong reason fails here.
expect "an UNGATED shipping job still reds, now on the permission" 1 "$WF" "takes write access to contents"

# --- 3. NOT A VIOLATION: a signing step in a dispatch-reachable job ---------
# 🔴 THIS CONTROL USED TO ASSERT THE OPPOSITE, AND THE REVERSAL IS DELIBERATE.
#
# It read: "The job keeps its dispatch gate and its read-only permissions, and
# is still a violation, because it can now sign." That was the contract until
# #2118, which changed it on purpose: a dispatch must be able to build a REAL
# signed, notarised, stapled candidate, because the v1.0.100 walk failed six
# probes that only an installed Ostler can exercise and a candidate that cannot
# be built cannot be walked. Signing on a dispatch is now the intended
# behaviour and its cost is stated in cut.yml: a signing identity and a
# notarisation round trip, which is cheaper than a burnt version number.
#
# The job still holds `contents: read`, so it cannot publish what it signs.
# Control 3b immediately below is where the teeth moved to.
WF="$(baseline signs)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: just a quick resign\n        run: codesign --force --sign \"$ID\" a.app\n")
open(p, "w").write(s)
PY
expect "a codesign step in a read-only dispatch job is NOT a violation" 0 "$WF"

# --- 3b. THE DEFECT: a PUBLISHING step in a dispatch-reachable job ----------
# This is where control 3's teeth went. The step below is the shape cut.yml
# publishes through for real, and it carries no gate of its own, so a
# workflow_dispatch would put a DMG on the customer url with no tag behind it.
WF="$(baseline publishes)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: ship it\n        run: bash scripts/publish_release.sh \"$TAG\" out.dmg\n")
open(p, "w").write(s)
PY
expect "an ungated publishing step in a dispatch job is a violation" 1 "$WF" "can PUBLISH and is reachable by a workflow_dispatch"

# --- 3c. NOT A VIOLATION: the same publishing step, with its own push gate --
# This is cut.yml's actual shape, and the reason publishing is graded per STEP
# rather than per job: the job is dispatch-reachable so a candidate can be
# built, and every step that reaches a customer carries `github.event_name ==
# 'push'`. A gate that could not express this would force the file back to the
# build-then-ship-then-find-out order that burnt two version numbers.
WF="$(baseline publishes_gated)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: ship it\n        if: github.event_name == 'push'\n"
    "        run: bash scripts/publish_release.sh \"$TAG\" out.dmg\n")
open(p, "w").write(s)
PY
expect "a publishing step WITH its own push gate is NOT a violation" 0 "$WF"

# --- 3d. THE DEFECT: the publishing step's gate is OR-widened ---------------
# The same step, gated, but with an OR. `is_safely_push_gated` rejects any
# top-level `||` and this proves that rejection reaches the per-STEP path too,
# not only the per-job one it was written for.
WF="$(baseline publishes_or)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: ship it\n"
    "        if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'\n"
    "        run: bash scripts/publish_release.sh \"$TAG\" out.dmg\n")
open(p, "w").write(s)
PY
expect "an OR-widened gate on a publishing STEP is a violation" 1 "$WF" "can PUBLISH and is reachable by a workflow_dispatch"

# --- 3e. THE DEFECT: publishing sits in the job but in NO step -------------
# A job-level `env:` is not inside any step, so no step `if:` can ever gate it.
# Without this branch the per-step grading would find nothing to grade and the
# job would fall through to the permission check and pass on `contents: read`.
WF="$(baseline publishes_joblevel)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "  dry-run:\n    needs: preflight\n",
    "  dry-run:\n    needs: preflight\n    env:\n      HELPER: scripts/publish_release.sh\n")
open(p, "w").write(s)
PY
expect "publishing outside any step is a violation" 1 "$WF" "NOT inside any step"

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
      # 🔴 A PUBLISHING capability, not a producing one, and that is the
      # change. Producing inside a composite is permitted on a dispatch now,
      # so hiding `notarytool` here would no longer be a violation and this
      # control would have quietly stopped proving that `uses: ./...` is
      # followed at all. Hiding the thing that reaches a CUSTOMER still is.
      run: gh release create "$TAG" out.dmg --repo ostler-ai/thing
YAML
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n",
    "      - uses: ./.github/actions/helper\n      - name: gates only\n")
open(p, "w").write(s)
PY
expect "publishing hidden in a local composite action is a violation" 1 "$WF" "in ./.github/actions/helper"

# --- 5. THE DEFECT: the dispatch-reachable job takes contents: write --------
# It ships nothing today. It could publish tomorrow, and nothing would fire.
WF="$(baseline perms)"
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
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
mutate "$WF" <<'PY'
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

# --- 11. THE DEFECT: the push gate is widened with an OR --------------------
# The substring `github.event_name == 'push'` is still there -- a plain
# .search() over the `if:` line finds it and calls the job gated -- but the OR
# means the job also runs on a dispatch. A gate reading the substring instead
# of the boolean would report this CLEAN while `make -C gui ship` is
# dispatch-reachable.
WF="$(baseline or-widened)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "    if: github.event_name == 'push'\n",
    "    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'\n", 1)
open(p, "w").write(s)
PY
# Same reason change as control 2: the OR still defeats the job's gate, and the
# violation it now exposes is that this job holds the workflow's write scope
# while a dispatch can reach it. The needle pins the new reason.
expect "an OR-widened push gate is a violation" 1 "$WF" "takes write access to contents"

# --- 12. THE DEFECT: a producing make target split by a line continuation ---
# `run: make \` then `       ship` on the next physical line is ONE shell
# command. SHIPPING_CAPABILITIES bounds its `make` pattern to `[^\n]*` so a
# `make` on one line is never satisfied by an unrelated word many lines below
# -- but the same bound made the regex blind to a command a backslash split
# across two YAML lines. The step lands in dry-run, which is dispatch-only
# with `permissions: contents: read`, so a gate that finds no capability here
# calls it merely read-only rather than a shipping route.
WF="$(baseline backslash-split)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n",
    "      - name: gates only\n        run: bash scripts/dry_run_cut_checks.sh\n"
    "      - name: a quiet publish helper\n"
    "        run: |\n"
    "          make \\\n"
    "            publish-appcast\n")
open(p, "w").write(s)
PY
# 🔴 THE TARGET CHANGED FROM `ship` TO `publish-appcast`, AND THE CONTROL IS
# THE SAME CONTROL. What it proves is that LINE_CONTINUATION is undone before
# the capability regex runs, so a command split across two YAML lines is still
# one command. It could only ever prove that against a capability that is still
# forbidden here, and `make ship` no longer is. `make publish-appcast` moves
# the update feed a customer's updater reads, so it is.
expect "a publish target split by a backslash continuation is a violation" 1 "$WF" "can PUBLISH and is reachable by a workflow_dispatch"

# --- 12b. NOT A VIOLATION: a COMMENT inside a permissions block ------------
# 🔴 THIS IS A DEFECT THIS GATE ACTUALLY HAD, FOUND BY TRIPPING IT.
#
# The `permissions:` block was matched as raw text, so a line of PROSE inside
# it containing the write scope reported the job as holding write access it did
# not hold. It was found by changing cut.yml's block to `contents: read` and
# writing a comment that explained why: the gate went on refusing the file,
# quoting a scope that was no longer in it.
#
# It fails closed, so nothing unsafe was ever passed by it. It is still the
# shape that gets an enforcer deleted: it reds on the person who has just made
# the file safer, and names a cause the file does not contain. Control 10
# already proves prose cannot invent a CAPABILITY. This proves prose cannot
# invent a GRANT.
WF="$(baseline perms_comment)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
before = """    runs-on: macos-26
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
after = """    runs-on: macos-26
    permissions:
      # deliberately not the write scope here, see the cut job
      contents: read     # and never contents: write
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
s = open(p).read()
assert s.count(before) == 1, "anchor matched %d" % s.count(before)
open(p, "w").write(s.replace(before, after, 1))
PY
expect "a comment naming the write scope is NOT a grant" 0 "$WF"

# --- 12c. NOT A VIOLATION: a job inheriting a READ-ONLY workflow block ------
# The old code asserted, in a hard-coded sentence, that a job declaring no
# `permissions:` "inherits the workflow's contents: write". That is a fact
# about one file, not a rule, and it made the gate refuse the very change that
# fixes it: tighten the workflow-level block and the job it protects is
# reported as holding the scope that was just taken away. Inheritance is now
# resolved rather than assumed.
WF="$(baseline inherits_read)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
wf_before = """permissions:
  contents: write
  id-token: write
"""
wf_after = """permissions:
  contents: read
  id-token: write
"""
job_before = """    runs-on: macos-26
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
job_after = """    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
assert s.count(wf_before) == 1, "wf anchor matched %d" % s.count(wf_before)
assert s.count(job_before) == 1, "job anchor matched %d" % s.count(job_before)
s = s.replace(wf_before, wf_after, 1).replace(job_before, job_after, 1)
open(p, "w").write(s)
PY
expect "a job inheriting a READ-ONLY workflow block is NOT a violation" 0 "$WF"

# --- 12d. THE DEFECT: neither level declares a permissions block ------------
# Then the token is whatever the repository default happens to be, which is not
# in this file. Unknown is not safe. A gate that cannot read the grant has to
# say so rather than assume the friendly answer, which is the same rule as
# CANNOT-RUN below: not looking and looking and finding nothing are different
# answers and must not print the same.
WF="$(baseline no_perms_anywhere)"
mutate "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
wf_block = """permissions:
  contents: write
  id-token: write

"""
job_before = """    runs-on: macos-26
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
job_after = """    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: gates only
"""
assert s.count(wf_block) == 1, "wf anchor matched %d" % s.count(wf_block)
assert s.count(job_before) == 1, "job anchor matched %d" % s.count(job_before)
s = s.replace(wf_block, "", 1).replace(job_before, job_after, 1)
open(p, "w").write(s)
PY
expect "no permissions block at either level is a violation" 1 "$WF" "repository default"

# --- 13. CANNOT RUN is not a pass ------------------------------------------
expect "a missing workflow is CANNOT RUN, not a pass" 2 "$WORK/nope/cut.yml"
printf 'on: [push, workflow_dispatch]\njobs:\n  a:\n    runs-on: x\n' > "$WORK/inline.yml"
expect "an inline 'on:' list is CANNOT RUN, not a pass" 2 "$WORK/inline.yml"

# --- 14. THE LIVE ASSERTION ------------------------------------------------
expect "this repo's own .github/workflows/cut.yml is CLEAN" 0 "$LIVE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
