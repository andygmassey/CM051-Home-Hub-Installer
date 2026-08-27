#!/usr/bin/env python3
"""A test invoked by a paths-filtered workflow must be watched by that filter.

THE HOLE THIS CLOSES, measured on origin/main 19bd9a09 before it was written.

A test can be genuinely `run:` by a workflow, recorded WIRED in
tests/TEST_WIRING.tsv, and pass scripts/verify_critical_tests_stay_invoked.sh,
and still never execute on the pull request that breaks it -- because the
workflow's `on.pull_request.paths` filter does not list the test. Editing the
test does not trigger the only workflow that runs it. Editing the subject it
guards may not either.

Measured: 141 script/test files are invoked by a PR-triggered workflow in this
repo. TWELVE of them were dark on self-edit -- every workflow that ran them was
blind to a change to them. Three arrived with #995 (the container-engine
supervisor and the dead-wiki announcement), so the gates written for the v1.0.38
walk finding could have been edited to nothing on a green PR.

WHY THE EXISTING READERS CANNOT SEE IT.

  tests/TEST_WIRING.tsv                      records the `run:` step. True, and
                                             still true when nothing triggers.
  scripts/verify_critical_tests_stay_invoked  asks "is it INVOKED?" and its
                                             predicate deliberately EXCLUDES
                                             paths: entries, so a watched test
                                             and an unwatched one score the same.
  scripts/verify_ci_steps_are_maskless        asks "can an earlier failure skip
                                             it?" -- a different way for a wired
                                             step not to run.

All three are answers about the file. This is the answer about the EVENT.

The three hand-written comments in vendor-integrity.yml that say "a path entry
alone would only make the workflow TRIGGER; the run step is what makes it
CHECK" state the rule from the other side. A rule written three times in prose
in one file is a rule waiting to be a gate.

THREE AXES, one idea: a workflow must fire on the change that could break it.

  1. A file a paths-filtered workflow RUNS must be a path it WATCHES.
  2. A paths-filtered workflow must watch ITSELF, or it can be narrowed to
     nothing in a pull request that never runs it.
  3. A paths entry naming .github/workflows/<name> must name a workflow that
     EXISTS. A rename that leaves the old name behind produces an entry that
     matches no file, which is a self-watch that silently stopped working.

Axes 2 and 3 were measured on 2c583597 after axis 1 landed: of 61 filtered
workflows, TWO did not watch themselves, and one of those two was
container-runtime-guard.yml naming
'.github/workflows/installer-stream-and-runtime-guards.yml' -- its own name
before a rename, and a file that has not existed since. It had a self-watch, the
self-watch pointed at nothing, and nothing said so.

SCOPE, stated so a later reader does not over-trust it.

  * Only `on.pull_request.paths` is modelled. `paths-ignore` is NOT modelled,
    and if any workflow starts using it this gate exits CANNOT-RUN rather than
    guessing. Measured 2026-08-24: zero workflows use it.
  * A file is "covered" if ANY PR-triggered workflow that runs it either has no
    paths filter or has one that matches it. Six files looked dark in a single
    workflow and were covered by a second home; they are not violations.
  * This checks that the workflow FIRES on a change to the test itself. It does
    not, and cannot from the workflow alone, check that it fires on a change to
    everything the test reads. That is a strictly weaker claim, deliberately:
    the weaker one is decidable.

Exit 0 clean / 1 a violation / 2 cannot-run.
"""

import os
import re
import sys

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_CANNOT_RUN = 2

# Extract repo-relative script paths out of a `run:` body.
#
# The leading `(?:\./)?` is load-bearing and was added after the first version
# of this predicate MISSED `python3 ./tests/test_a_dead_wiki_announces_itself.py`
# and reported 16 violations where there were 18. The negative lookbehind must
# still reject `vendor/tests/foo.sh`, so it sits BEFORE the optional `./`.
FILE_RE = re.compile(
    r'(?<![\w./-])(?:\./)?((?:tests|scripts|bin|lib)/[A-Za-z0-9_./-]+\.(?:sh|py))'
)


def glob_to_regex(pattern):
    """GitHub path-filter globbing: ** spans /, * does not."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile("^" + out + "$")


def collect_runs(node, acc):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "run" and isinstance(value, str):
                acc.append(value)
            else:
                collect_runs(value, acc)
    elif isinstance(node, list):
        for value in node:
            collect_runs(value, acc)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    root = args[0] if args else "."

    workflow_dir = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(workflow_dir):
        print("COULD NOT RUN: no .github/workflows under %s, so nothing could "
              "be examined. This is a cannot-run, NOT a pass (exit 2)" % root,
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    try:
        import yaml
    except ImportError:
        print("COULD NOT RUN: PyYAML is not installed, so no workflow could be "
              "parsed. This is a cannot-run, NOT a pass (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    names = sorted(f for f in os.listdir(workflow_dir)
                   if f.endswith((".yml", ".yaml")))
    if not names:
        print("COULD NOT RUN: .github/workflows holds no workflow files, so the "
              "denominator is zero. Zero of zero is not clean (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    covered = {}
    homes = {}
    parsed = 0
    pr_workflows = 0
    filtered_workflows = 0
    self_blind = []
    ghost_entries = []
    workflow_names = set(names)

    for name in names:
        path = os.path.join(workflow_dir, name)
        raw = open(path, encoding="utf-8").read()
        try:
            doc = yaml.safe_load(raw)
        except Exception as exc:
            print("COULD NOT RUN: %s failed to parse (%s). A workflow this gate "
                  "cannot read is a workflow it cannot clear (exit 2)"
                  % (name, exc), file=sys.stderr)
            return EXIT_CANNOT_RUN
        if not isinstance(doc, dict):
            continue
        parsed += 1

        # PyYAML resolves a bare `on:` key to the boolean True.
        on = doc.get("on", doc.get(True))
        if isinstance(on, list):
            pull_request = {} if "pull_request" in on else None
        elif isinstance(on, dict):
            pull_request = on.get("pull_request")
            if "pull_request" in on and pull_request is None:
                pull_request = {}
        else:
            pull_request = None
        if pull_request is None:
            continue
        pr_workflows += 1

        if isinstance(pull_request, dict) and pull_request.get("paths-ignore"):
            print("COULD NOT RUN: %s uses paths-ignore, which this gate does "
                  "not model. Treating it as unfiltered would silently bless "
                  "an ignored test (exit 2)" % name, file=sys.stderr)
            return EXIT_CANNOT_RUN

        patterns = (pull_request.get("paths")
                    if isinstance(pull_request, dict) else None)
        regexes = ([glob_to_regex(str(p)) for p in patterns]
                   if patterns else None)

        if regexes is not None:
            filtered_workflows += 1
            own = ".github/workflows/" + name
            if not any(r.match(own) for r in regexes):
                self_blind.append(name)
            for pattern in patterns:
                pattern = str(pattern)
                if (pattern.startswith(".github/workflows/")
                        and "*" not in pattern and "?" not in pattern):
                    if os.path.basename(pattern) not in workflow_names:
                        ghost_entries.append((name, pattern))

        bodies = []
        collect_runs(doc.get("jobs", {}), bodies)
        invoked = set()
        for body in bodies:
            for match in FILE_RE.findall(body):
                if os.path.exists(os.path.join(root, match)):
                    invoked.add(match)

        for target in invoked:
            fires = regexes is None or any(r.match(target) for r in regexes)
            homes.setdefault(target, []).append(
                (name, "unfiltered" if regexes is None
                 else ("watches" if fires else "BLIND")))
            covered[target] = covered.get(target, False) or fires

    if parsed == 0:
        print("COULD NOT RUN: no workflow file parsed to a mapping (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    if not covered:
        print("COULD NOT RUN: %d workflow(s) parsed, %d take pull_request, and "
              "not one invokes a tests/ or scripts/ file that exists on disk. "
              "An empty numerator with an empty denominator is not clean "
              "(exit 2)" % (parsed, pr_workflows), file=sys.stderr)
        return EXIT_CANNOT_RUN

    dark = sorted(f for f, ok in covered.items() if not ok)
    self_blind.sort()
    ghost_entries.sort()

    print("EXAMINED: %d workflow(s), %d taking pull_request, %d of those with a "
          "paths filter, invoking %d script/test file(s) that exist on disk."
          % (parsed, pr_workflows, filtered_workflows, len(covered)))

    if not (dark or self_blind or ghost_entries):
        print("OK: every invoked file is watched by a workflow that runs it, "
              "every filtered workflow watches itself, and every workflow named "
              "in a paths list exists.")
        return EXIT_OK

    if dark:
        print()
        print("%d file(s) are DARK ON SELF-EDIT -- every workflow that runs them "
              "is blind to a change to them:" % len(dark), file=sys.stderr)
        for target in dark:
            print("  %s" % target, file=sys.stderr)
            for workflow, state in homes[target]:
                print("       %-10s %s" % (state, workflow), file=sys.stderr)
        print(file=sys.stderr)
        print("Add the file to that workflow's on.pull_request.paths list. A "
              "`run:` step without a matching path entry is a gate you have "
              "read, not a gate you have run.", file=sys.stderr)

    if self_blind:
        print()
        print("%d workflow(s) DO NOT WATCH THEMSELVES -- each can be narrowed, "
              "gutted or disabled in a pull request that never runs it:"
              % len(self_blind), file=sys.stderr)
        for name in self_blind:
            print("  %s" % name, file=sys.stderr)
        print(file=sys.stderr)
        print("Add '.github/workflows/<name>' to its own paths list.",
              file=sys.stderr)

    if ghost_entries:
        print()
        print("%d paths entr(y/ies) name a workflow that DOES NOT EXIST -- "
              "almost always a rename that left the old name behind, so the "
              "self-watch matches nothing:" % len(ghost_entries),
              file=sys.stderr)
        for name, pattern in ghost_entries:
            print("  %-42s -> %s" % (name, pattern), file=sys.stderr)

    return EXIT_VIOLATION


if __name__ == "__main__":
    sys.exit(main(sys.argv))
