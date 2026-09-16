#!/usr/bin/env python3
"""The cut dry run must stay REACHABLE on a workflow_dispatch (#1519).

WHY THIS EXISTS, AND WHY IT IS THE OPPOSITE DIRECTION TO THE GATE NEXT DOOR.

scripts/verify_dispatch_cannot_ship.py asserts that a dispatch CANNOT SHIP.
That is the safety direction, and it is enforced. Nothing asserted the other
direction: that a dispatch can still REACH the job whose entire purpose is to
run the cut path's checks before anyone pushes a tag. A workflow can satisfy
the safety gate perfectly by making the dry run unreachable, and the result
reads as a clean bill of health.

MEASURED ABSENCE, WITH A POSITIVE CONTROL OF THE SAME SHAPE ON THE SAME CORPUS.
Corpus: 618 files in tests/, 118 in scripts/, 150 workflows.
  SUBJECT  files that read cut.yml AND assert the dry run is reachable : 0
  CONTROL  files that read cut.yml AND assert a dispatch cannot ship   : 2
           (scripts/verify_dispatch_cannot_ship.py and its suite)
The control is non-zero through the identical search, so the zero is a finding
about the corpus rather than a statement about the reader.

WHAT ROW 1519 CLAIMED, AND WHAT WAS MEASURED.
The row: "cut.yml: the dry-run job can never run, because it needs a preflight
that can only pass on a tag". That mechanism is STALE, and it was proved by
firing the thing rather than by reading it.

  POSITIVE EVIDENCE, 4 of 4 successful workflow_dispatch runs of cut.yml:
      34767764277  preflight=success  dry-run=success  cut=skipped
      34675539869  preflight=success  dry-run=success  cut=skipped
      34121000824  preflight=success  dry-run=success  cut=skipped
      33760954595  preflight=success  dry-run=success  cut=skipped
  The dry run has run, repeatedly, on the event the row says it cannot run on.

  FRESH EVIDENCE, run 35119027114, fired 2026-09-16 against main c4d4b5af:
      preflight=failure  dry-run=skipped  cut=skipped
  and the three failing steps were, every one of them, CONTENT and not event:
      "The cut record's CM051 pin is the tree being cut"  STALE PIN: cut.env
          names cd475b24, the tree is c4d4b5af
      "The cut checklist is complete and has no ungated rows"  165 registered
          rows, 164 with a gate, 1 NONE YET
      "The tagged commit's own checks are not red"  137 check-runs examined,
          111 completed, digest-auth=failure on the commit itself
  Zero of the three name a missing tag. A tag push at that same commit fails
  the identical three. The dry run being skipped that day is preflight doing
  its job, which is the designed behaviour and not this row's defect.

So the row is closed by proof, and this file is the proof's guard: the
mechanism it names is real and could arrive tomorrow in one careless step.

THE INVARIANT, in the shape the row described it.
  1. on.workflow_dispatch is declared.
  2. a dry-run job exists.
  3. its `if:` admits a workflow_dispatch.
  4. every job in its `needs` closure admits a workflow_dispatch. A closure
     job gated `github.event_name == 'push'` makes the dry run unreachable
     while every other line still reads correct, which is the row verbatim.
  5. no step in the closure can hard-fail on a dispatch through a tag-only
     value. A step consuming GITHUB_REF_NAME / github.ref_name / github.ref
     must either be skipped on a dispatch by a tag guard in its `if:`, or
     carry a dispatch-safe fallback: an event_name branch, or a shell default
     such as ${CUT_VERSION:-${GITHUB_REF_NAME:-}}.

CONSUMER-SIDE, AND THE SUBJECT IS A PERSON. The person here is whoever tags
the cut. The dry run is the only thing that runs the cut path's checks BEFORE
a tag exists. With it unreachable, that person's first news of a bad cut is a
tag already pushed, a build spent, a signing spent and an Apple notarisation
spent, and a tag that now has to be moved. The 2026-08-23 shape the
tagged-commit gate's own message describes is exactly that day.

CANNOT-RUN IS A THIRD STATE. No PyYAML, no file, unparseable, zero jobs or
zero steps examined all exit 2. An empty scan is the one input that would
otherwise manufacture the confidence this file exists to remove.

Exit 0 every assertion held / 1 the dry run is unreachable / 2 could not run.
"""
from __future__ import annotations

import os
import re
import sys

# Carry our own sys.path entry: this file is run by path from a workflow step,
# from a Makefile, and by hand from the repo root, and `python3 tests/x.py`
# puts tests/ on the path but not the repo root. Verified with env -u
# PYTHONPATH, which is the only way to see that an inherited PYTHONPATH was
# doing the work.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

EXIT_OK = 0
EXIT_UNREACHABLE = 1
EXIT_CANNOT_RUN = 2

DEFAULT_WORKFLOW = os.path.join(_REPO_ROOT, ".github", "workflows", "cut.yml")
DRY_RUN_JOB = "dry-run"

# A step consuming any of these is reading a value that only a tag push
# supplies. On a dispatch github.ref is refs/heads/<branch> and ref_name is the
# branch, so a step that treats either as a version string gets a branch name.
TAG_ONLY_VALUE = re.compile(
    r"GITHUB_REF_NAME|github\.ref_name|GITHUB_REF\b|github\.ref\b")

# Skipped on a dispatch, so it cannot fail one. Any tag-shaped ref test counts.
TAG_GUARD = re.compile(r"refs/tags")

# Branches on the event before using the value, so the dispatch arm is real.
#
# 🔴 THIS USED TO INCLUDE CUT_VERSION_SOURCE AND THAT MADE THE GATE BLIND.
# Caught by a mutant on the REAL cut.yml, which is the only reason it was
# found: deleting the `if [ "${GITHUB_EVENT_NAME}" = "push" ]` arm from the
# version resolver left a bare CUT_VERSION="${GITHUB_REF_NAME}" running on
# every event, and this gate still reported the step protected, because the
# step body mentions CUT_VERSION_SOURCE further down and the pattern accepted
# that as an event branch. A VARIABLE NAME IS NOT A BRANCH. Only a reference
# to the event itself proves the dispatch arm exists.
EVENT_BRANCH = re.compile(r"GITHUB_EVENT_NAME|github\.event_name")

# A shell default that supplies the value when the tag-only one is absent:
#   ${CUT_VERSION:-${GITHUB_REF_NAME:-}}
# The fallback must be the DEFAULT arm, i.e. the tag-only name appears after
# the `:-`, which is what makes it a fallback rather than the primary read.
SHELL_FALLBACK = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*"
                            r"(?:GITHUB_REF_NAME|CUT_VERSION)")


def _load_yaml():
    try:
        import yaml  # noqa: F401
    except ImportError:
        return None
    return yaml


def _on_block(doc):
    """`on:` parses as the boolean True under the YAML 1.1 rules PyYAML uses."""
    if True in doc:
        return doc[True]
    return doc.get("on")


def _cond(obj):
    return str(obj.get("if", "") or "")


def _admits_dispatch(cond):
    """Can this `if:` be true on a workflow_dispatch?

    An empty condition admits everything. A condition naming push and not
    naming workflow_dispatch cannot. Anything else is treated as admitting,
    because this gate must not invent a failure out of an expression it does
    not fully evaluate: a false red here is a gate people switch off.
    """
    c = cond.replace(" ", "")
    if not c:
        return True
    if "workflow_dispatch" in c:
        return True
    if "event_name=='push'" in c or 'event_name=="push"' in c:
        return False
    if TAG_GUARD.search(c):
        return False
    return True


def _strip_full_line_comments(text):
    """Drop whole-line shell comments before looking for a tag-only read.

    MEASURED, ON THE FIRST RUN OF THIS GATE AGAINST THE REAL FILE. The step
    "Rollforward claims" was reported unprotected. Its actual code reads
    ${CUT_VERSION} and is dispatch-safe; what matched was line 38 of its run
    block, a PROSE COMMENT that says "$CUT_VERSION, not $GITHUB_REF_NAME".
    The gate read the sentence explaining the fix as the defect.

    This repo has the scar already: cut.yml carries a warning that the
    maskless CI checker classifies a step by looking for a path "anywhere in
    its `run:` block, comments included". Same trap, one file over.

    Whole-line only, deliberately. Stripping a trailing `#` would need a shell
    parser to know whether it is inside a string, and a half-parser that
    silently eats real code is a worse gate than one that reads a little prose.
    The pair of controls around this pins both directions: prose must not fire,
    code must.
    """
    kept = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        kept.append(line)
    return "\n".join(kept)


def _step_text(step):
    parts = [_strip_full_line_comments(str(step.get("run", "") or "")),
             str(step.get("env", "") or "")]
    with_block = step.get("with")
    if with_block:
        parts.append(str(with_block))
    return "\n".join(parts)


def _needs_of(job):
    needs = job.get("needs")
    if not needs:
        return []
    if isinstance(needs, str):
        return [needs]
    return list(needs)


def _closure(jobs, start):
    """Every job the dry run transitively depends on, plus the dry run."""
    seen = []
    stack = [start]
    while stack:
        name = stack.pop()
        if name in seen or name not in jobs:
            continue
        seen.append(name)
        stack.extend(_needs_of(jobs[name]))
    return seen


def check(path):
    """Returns (exit_code, report_lines)."""
    out = []
    yaml = _load_yaml()
    if yaml is None:
        return EXIT_CANNOT_RUN, [
            "CANNOT RUN: PyYAML is not importable, so no workflow was parsed.",
            "Nothing was examined. This is not a pass."]

    if not os.path.isfile(path):
        return EXIT_CANNOT_RUN, [
            "CANNOT RUN: no workflow at %s" % path,
            "Nothing was examined. This is not a pass."]

    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - any parse failure is cannot-run
        return EXIT_CANNOT_RUN, [
            "CANNOT RUN: %s did not parse: %s" % (path, exc),
            "Nothing was examined. This is not a pass."]

    if not isinstance(doc, dict):
        return EXIT_CANNOT_RUN, [
            "CANNOT RUN: %s is not a mapping." % path,
            "Nothing was examined. This is not a pass."]

    jobs = doc.get("jobs") or {}
    if not jobs:
        return EXIT_CANNOT_RUN, [
            "CANNOT RUN: %s declares 0 jobs." % path,
            "An empty scan asserts nothing. This is not a pass."]

    out.append("dry-run reachability: %s" % path)
    out.append("  EXAMINED %d job(s)" % len(jobs))

    failures = []

    # 1. the dispatch event itself
    on = _on_block(doc) or {}
    has_dispatch = isinstance(on, dict) and "workflow_dispatch" in on
    if not has_dispatch:
        failures.append(
            "on.workflow_dispatch is NOT declared, so no dispatch can ever "
            "start this workflow and the dry run is unreachable by "
            "construction.")

    # 2. the job exists
    if DRY_RUN_JOB not in jobs:
        failures.append(
            "there is no `%s` job, so the cut path's checks cannot be run "
            "before a tag exists at all." % DRY_RUN_JOB)
        out.append("  jobs present: %s" % ", ".join(sorted(jobs)))
        return EXIT_UNREACHABLE, out + [""] + [
            "UNREACHABLE -- %s" % f for f in failures]

    # 3. and 4. the job and its whole needs closure admit a dispatch
    closure = _closure(jobs, DRY_RUN_JOB)
    out.append("  needs closure of `%s`: %d job(s) -- %s"
               % (DRY_RUN_JOB, len(closure), ", ".join(closure)))
    for name in closure:
        cond = _cond(jobs[name])
        if not _admits_dispatch(cond):
            role = ("the dry run itself" if name == DRY_RUN_JOB
                    else "a job the dry run needs")
            failures.append(
                "job `%s` (%s) is gated `if: %s`, which no workflow_dispatch "
                "can satisfy. The dry run is unreachable." % (name, role, cond))

    # 5. no closure step hard-fails on a dispatch through a tag-only value
    steps_seen = 0
    ref_steps = 0
    guarded = 0
    fallback = 0
    branched = 0
    for name in closure:
        for step in jobs[name].get("steps") or []:
            steps_seen += 1
            text = _step_text(step)
            cond = _cond(step)
            if not TAG_ONLY_VALUE.search(text + " " + cond):
                continue
            ref_steps += 1
            if TAG_GUARD.search(cond):
                guarded += 1
                continue
            if SHELL_FALLBACK.search(text):
                fallback += 1
                continue
            if EVENT_BRANCH.search(text):
                branched += 1
                continue
            failures.append(
                "job `%s` step %r reads a tag-only value (github.ref / "
                "GITHUB_REF_NAME) with no tag guard in its `if:`, no "
                "event_name branch and no shell fallback. On a dispatch it "
                "gets a BRANCH name where it expects a tag, and a step that "
                "fails takes the whole preflight down with it, which is "
                "exactly how the dry run stops being reachable."
                % (name, step.get("name") or step.get("uses") or "(unnamed)"))

    out.append("  EXAMINED %d step(s) across the closure" % steps_seen)
    out.append("  tag-only-value steps: %d  (tag-guarded %d, shell fallback "
               "%d, event branch %d, unprotected %d)"
               % (ref_steps, guarded, fallback, branched,
                  ref_steps - guarded - fallback - branched))

    if steps_seen == 0:
        return EXIT_CANNOT_RUN, out + [
            "",
            "CANNOT RUN: 0 steps were examined across the needs closure.",
            "An empty scan asserts nothing. This is not a pass."]

    if failures:
        return EXIT_UNREACHABLE, out + [""] + [
            "UNREACHABLE -- %s" % f for f in failures]

    out.append("")
    out.append("  OK: a workflow_dispatch reaches `%s` -- the event is "
               "declared, every job in its %d-job needs closure admits a "
               "dispatch, and %d of %d tag-only-value step(s) are protected."
               % (DRY_RUN_JOB, len(closure), ref_steps, ref_steps))
    return EXIT_OK, out


# ---------------------------------------------------------------------------
# CONTROLS. Both directions, because a gate that flags the innocent gets
# switched off inside a week and that is the same outcome as never writing it.
# ---------------------------------------------------------------------------
BASELINE = """
name: cut

on:
  push:
    tags:
      - 'v1.0.*'
  workflow_dispatch:

jobs:
  preflight:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Resolve which cut this run is about
        run: |
          if [ "${GITHUB_EVENT_NAME}" = "push" ]; then
            CUT_VERSION="${GITHUB_REF_NAME}"
          else
            CUT_VERSION="v$(read_the_plist)"
          fi
      - name: BOM rows must be in the pinned tree
        if: startsWith(github.ref, 'refs/tags/v1.0.')
        run: bom_check "${GITHUB_REF_NAME}"
      - name: Repo-side gates
        run: CUT_VERSION="${CUT_VERSION:-${GITHUB_REF_NAME:-}}" ./gates.sh

  cut:
    needs: preflight
    if: github.event_name == 'push'
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: ship
        run: make -C gui ship

  dry-run:
    needs: preflight
    if: github.event_name == 'workflow_dispatch'
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: gates only
        run: bash scripts/dry_run_cut_checks.sh
"""


def _controls(tmpdir):
    """[(label, yaml_text, want_rc)] -- six must fire, four must not."""
    b = BASELINE
    return [
        # MUST NOT FIRE. A correct workflow, and three benign edits.
        ("baseline is reachable", b, EXIT_OK),
        ("a tag-guarded step reading the ref name is fine",
         b.replace("run: bom_check", "run: other_check"), EXIT_OK),
        ("an extra unrelated job does not matter",
         b + "\n  unrelated:\n    runs-on: ubuntu-latest\n"
             "    steps:\n      - run: true\n", EXIT_OK),
        # THE COMMENT PAIR. Both halves are needed: the first alone would be
        # satisfied by a gate that had gone blind altogether, and the second
        # alone would be satisfied by a gate that reads prose as code. Only
        # the pair says the gate reads code and not prose.
        ("prose naming the ref name in a comment is NOT a finding",
         b.replace('      - name: Repo-side gates\n'
                   '        run: CUT_VERSION="${CUT_VERSION:-'
                   '${GITHUB_REF_NAME:-}}" ./gates.sh',
                   '      - name: Repo-side gates\n'
                   '        run: |\n'
                   '          # $CUT_VERSION, not $GITHUB_REF_NAME: on a '
                   'dispatch the ref name is a branch\n'
                   '          ./gates.sh'),
         EXIT_OK),
        ("the SAME step reading it in CODE is a finding",
         b.replace('      - name: Repo-side gates\n'
                   '        run: CUT_VERSION="${CUT_VERSION:-'
                   '${GITHUB_REF_NAME:-}}" ./gates.sh',
                   '      - name: Repo-side gates\n'
                   '        run: |\n'
                   '          # $CUT_VERSION, not $GITHUB_REF_NAME: on a '
                   'dispatch the ref name is a branch\n'
                   '          CUT_VERSION="${GITHUB_REF_NAME}" ./gates.sh'),
         EXIT_UNREACHABLE),
        ("a dry run gated on both events is still reachable",
         b.replace("if: github.event_name == 'workflow_dispatch'\n    "
                   "runs-on: macos-26",
                   "if: github.event_name == 'workflow_dispatch' || "
                   "github.event_name == 'push'\n    runs-on: macos-26"),
         EXIT_OK),

        # MUST FIRE. Each is one mutation from the baseline, so each red has
        # exactly one cause.
        ("the dry run is push-gated",
         b.replace("if: github.event_name == 'workflow_dispatch'\n    "
                   "runs-on: macos-26\n    steps:\n      - uses: "
                   "actions/checkout@v4\n      - name: gates only",
                   "if: github.event_name == 'push'\n    runs-on: macos-26\n"
                   "    steps:\n      - uses: actions/checkout@v4\n"
                   "      - name: gates only"),
         EXIT_UNREACHABLE),
        ("ROW 1519 VERBATIM: preflight becomes tag-only",
         b.replace("  preflight:\n    runs-on: ubuntu-latest",
                   "  preflight:\n    if: github.event_name == 'push'\n"
                   "    runs-on: ubuntu-latest"),
         EXIT_UNREACHABLE),
        ("preflight is gated on a tag ref",
         b.replace("  preflight:\n    runs-on: ubuntu-latest",
                   "  preflight:\n    if: startsWith(github.ref, "
                   "'refs/tags/v1.0.')\n    runs-on: ubuntu-latest"),
         EXIT_UNREACHABLE),
        # THE MUTANT THAT CAUGHT THIS GATE BEING BLIND, kept as a control so
        # the looseness cannot come back. The resolver keeps every other line,
        # including the variable named CUT_VERSION_SOURCE, and loses only the
        # branch on the event. That must be a finding.
        ("losing the event branch is a finding even though the step still "
         "mentions CUT_VERSION_SOURCE",
         b.replace('          if [ "${GITHUB_EVENT_NAME}" = "push" ]; then\n'
                   '            CUT_VERSION="${GITHUB_REF_NAME}"\n'
                   '          else\n'
                   '            CUT_VERSION="v$(read_the_plist)"\n'
                   '          fi',
                   '          if true; then\n'
                   '            CUT_VERSION="${GITHUB_REF_NAME}"\n'
                   '            CUT_VERSION_SOURCE="tag"\n'
                   '          fi'),
         EXIT_UNREACHABLE),
        ("a closure step reads the ref name with no protection",
         b.replace('          if [ "${GITHUB_EVENT_NAME}" = "push" ]; then\n'
                   '            CUT_VERSION="${GITHUB_REF_NAME}"\n'
                   '          else\n'
                   '            CUT_VERSION="v$(read_the_plist)"\n'
                   '          fi',
                   '          CUT_VERSION="${GITHUB_REF_NAME}"'),
         EXIT_UNREACHABLE),
        ("the dry-run job is deleted",
         b[:b.index("  dry-run:")], EXIT_UNREACHABLE),
        ("workflow_dispatch is not declared",
         b.replace("  workflow_dispatch:\n", ""), EXIT_UNREACHABLE),

        # CANNOT-RUN, the third state.
        ("a workflow with no jobs is cannot-run, never a pass",
         "name: cut\non:\n  workflow_dispatch:\n", EXIT_CANNOT_RUN),
    ]


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    if len(args) > 1:
        print("usage: test_the_dry_run_job_is_reachable.py [WORKFLOW]",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    if _load_yaml() is None:
        print("CANNOT RUN: PyYAML is not importable, so nothing was parsed.",
              file=sys.stderr)
        print("This is a cannot-run (exit 2), not a pass.", file=sys.stderr)
        return EXIT_CANNOT_RUN

    import tempfile

    passed = 0
    failed = 0
    tmpdir = tempfile.mkdtemp(prefix="dryrunreach-")
    controls = _controls(tmpdir)
    print("== CONTROLS (%d) ==" % len(controls))
    for i, (label, text, want) in enumerate(controls):
        p = os.path.join(tmpdir, "wf%02d.yml" % i)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
        # A CONTROL THAT DID NOT APPLY LOOKS EXACTLY LIKE ONE THAT WAS CAUGHT.
        # Every mutant here is a string replace, and a replace whose needle
        # has drifted silently returns the baseline unchanged, which then
        # "passes" for the wrong reason. So a mutant must differ from the
        # baseline it was cut from, and that is asserted before it is scored.
        if want != EXIT_OK and text == BASELINE:
            print("  FAIL  %s -- the mutation did not apply (identical to "
                  "the baseline), so its verdict means nothing" % label)
            failed += 1
            continue
        rc, lines = check(p)
        if rc == want:
            print("  PASS  %s (exit %d)" % (label, rc))
            passed += 1
        else:
            print("  FAIL  %s -- wanted exit %d, got %d" % (label, want, rc))
            for line in lines:
                print("        %s" % line)
            failed += 1

    print("")
    print("== LIVE: this repo's own .github/workflows/cut.yml ==")
    path = args[0] if args else DEFAULT_WORKFLOW
    rc, lines = check(path)
    for line in lines:
        print(line)

    print("")
    print("CONTROLS: %d pass / %d fail of %d" % (passed, failed,
                                                 len(controls)))
    if rc == EXIT_CANNOT_RUN:
        print("LIVE: CANNOT-RUN. Nothing was measured, which is not a pass.")
        return EXIT_CANNOT_RUN
    if failed or rc != EXIT_OK:
        return EXIT_UNREACHABLE
    print("LIVE: the dry run is reachable on a workflow_dispatch.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
