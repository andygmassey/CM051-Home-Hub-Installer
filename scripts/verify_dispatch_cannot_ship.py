#!/usr/bin/env python3
"""A workflow_dispatch of the cut must be incapable of shipping (task #359).

THE DIRECTIVE THIS ENFORCES, quoted from .github/workflows/cut.yml:

    TRIGGER IS A TAG PUSH, AND NOTHING ELSE.
    There is deliberately no `workflow_dispatch`. A manually-fired pipeline is
    a hand-cut wearing a costume: same "I'll just run it" pressure, same bypass
    of the tag that pins what was cut. If you want a cut, write the tag down.

The guarantee behind it:

    THERE IS NO ROUTE TO A SIGNED, NOTARISED, PUBLISHABLE ARTEFACT THAT HAS NOT
    PASSED THE ROLLFORWARD GATE VIA A TAG.

cut.yml now carries a `workflow_dispatch` that runs the GATES and stops, so a
broken cut-path check stops costing a version number -- five were spent on that
in one day. The directive is not weakened by a run that manufactures nothing.
It WOULD be weakened the moment a dispatch could produce or publish an artefact,
and that is a one-line change away at any time: an input, a job that forgets its
event gate, a signing step added to the wrong job, a permissions block deleted.

A locked directive needs an enforcer, not a reminder. This is the enforcer.

WHAT IT ASSERTS. Deliberately phrased over CAPABILITY rather than over job
names, so a NEW job cannot slip past by not being called "cut":

  1. The tag route is intact: `on.push.tags` exists, and `on.push` names no
     branches. If the only trigger stopped being a tag, everything else here
     would be guarding a door in a field.
  2. `workflow_dispatch`, if present, declares NOTHING -- no `inputs:`, no
     anything. An input is a switch, and a switch is what the directive
     refuses. There is no safe input; there is only an input nobody has
     flipped yet.
  3. Every job holding a SHIPPING CAPABILITY -- signing, notarising, stapling,
     a `make` of any producing target, creating a release, uploading an
     artefact, reading a signing or notary credential -- is gated with
     `if: ... github.event_name == 'push'`. A dispatch cannot make its own
     event name be `push`, and the only push this workflow answers to is a tag.
  4. Every job NOT so gated declares its own `permissions:` and does NOT take
     `contents: write`. Omitting the block inherits the workflow's
     `contents: write`, which is enough to create a release, so an omission is
     a violation and not a default.
  5. Local composite actions (`uses: ./...`) invoked by a job are opened and
     searched too. Otherwise the whole check is bypassed by moving one signing
     step into an action file.

WHAT IT DELIBERATELY DOES NOT DO. It does not require a dispatch to exist. A
revert that removes the dispatch entirely satisfies the directive completely,
and a gate that forbade that would be enforcing a preference rather than a
guarantee.

FULL-LINE COMMENTS ARE STRIPPED BEFORE THE CAPABILITY SEARCH, for the reason
scripts/verify_test_wiring.sh learned the hard way: a comment BLOCK explaining
that a job does not notarise contains the word "notarise", and a gate that
cannot tell prose from a command reports the documentation as the defect.
Inline `#` is left alone -- a real command can contain one.

Exit 0 the route is closed / 1 it is open / 2 could not run.
"""

import os
import re
import sys

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_CANNOT_RUN = 2

USAGE = "usage: verify_dispatch_cannot_ship.py [WORKFLOW_FILE]"
DEFAULT_WORKFLOW = os.path.join(".github", "workflows", "cut.yml")

# A capability that can put a signed, notarised or published artefact into the
# world, or take a step towards one. Generous on purpose: a miss here is a
# silent hole in the very guarantee this file exists to hold.
#
# `make` is matched on its PRODUCING targets rather than on the word `make`,
# because `make print-version` and `make print-dmg-path` are questions, not
# builds, and a gate that flags a question gets switched off.
SHIPPING_CAPABILITIES = [
    (r"\bmake\b[^\n]*\b(ship|package|release|notarise[a-z-]*|staple[a-z-]*|"
     r"archive|sign-python-bundle|sparkle-embed)\b", "runs a producing `make` target"),
    (r"\bnotarytool\b", "calls notarytool"),
    (r"\bstapler\b", "calls stapler"),
    (r"\bcodesign\b", "calls codesign"),
    (r"\bsecurity\s+import\b", "imports a signing identity"),
    (r"upload-artifact", "uploads an artefact"),
    (r"action-gh-release", "creates a GitHub release"),
    (r"\bgh\s+release\s+create\b", "creates a GitHub release"),
    (r"OSTLER_SIGNING_CERT", "reads a signing credential"),
    (r"OSTLER_NOTARY", "reads a notary credential"),
]

PUSH_GATE = re.compile(r"github\.event_name\s*==\s*['\"]push['\"]")
CONTENTS_WRITE = re.compile(r"contents:\s*write|permissions:\s*write-all")


def read_lines(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().splitlines()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line):
    s = line.strip()
    return not s or s.startswith("#")


def child_lines(lines, start, indent):
    """Every line belonging under lines[start], i.e. indented deeper than it."""
    out = []
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line.strip():
            out.append(line)
            continue
        if indent_of(line) <= indent:
            break
        out.append(line)
    return out


def keys_at(lines, indent):
    """[(name, line_index)] for `name:` keys at exactly `indent`, top down."""
    found = []
    pattern = re.compile(r"^ {%d}([A-Za-z_][A-Za-z0-9_.-]*):" % indent)
    for i, line in enumerate(lines):
        if is_blank_or_comment(line):
            continue
        if indent_of(line) != indent:
            continue
        m = pattern.match(line)
        if m:
            found.append((m.group(1), i))
    return found


def strip_full_line_comments(lines):
    return [l for l in lines if not l.lstrip().startswith("#")]


def capabilities_in(text):
    out = []
    for pattern, what in SHIPPING_CAPABILITIES:
        if re.search(pattern, text):
            out.append(what)
    return out


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    if len(args) > 1:
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT_RUN
    path = args[0] if args else DEFAULT_WORKFLOW

    try:
        lines = read_lines(path)
    except OSError as exc:
        print("CANNOT RUN: %s" % exc, file=sys.stderr)
        print("Nothing was examined. This is not a pass.", file=sys.stderr)
        return EXIT_CANNOT_RUN
    if not lines:
        print("CANNOT RUN: %s is empty." % path, file=sys.stderr)
        return EXIT_CANNOT_RUN

    problems = []
    checked = []

    # --- the `on:` block ---------------------------------------------------
    on_idx = None
    jobs_idx = None
    for name, i in keys_at(lines, 0):
        if name == "on":
            on_idx = i
        elif name == "jobs":
            jobs_idx = i

    if on_idx is None:
        print("CANNOT RUN: %s has no top-level `on:` block." % path, file=sys.stderr)
        return EXIT_CANNOT_RUN
    if lines[on_idx].strip() != "on:":
        # `on: [push]` inline form. Refuse rather than guess: every check below
        # is structural, and an inline list would defeat them silently.
        print("CANNOT RUN: `on:` is written inline (%r). This gate reads the block "
              "form only and cannot honestly analyse the inline one."
              % lines[on_idx].strip(), file=sys.stderr)
        return EXIT_CANNOT_RUN

    on_block = child_lines(lines, on_idx, 0)
    on_keys = keys_at(on_block, 2)
    on_names = [n for n, _ in on_keys]

    # 1. the tag route is intact
    if "push" not in on_names:
        problems.append("`on:` no longer has a `push:` trigger -- the tag route is gone.")
    else:
        push_i = [i for n, i in on_keys if n == "push"][0]
        push_block = child_lines(on_block, push_i, 2)
        push_keys = [n for n, _ in keys_at(push_block, 4)]
        if "tags" not in push_keys:
            problems.append("`on.push` no longer filters on `tags:` -- a cut could fire "
                            "without a tag being written down.")
        elif "branches" in push_keys:
            problems.append("`on.push` names `branches:` -- a branch push would cut, and "
                            "a branch is not a tag anyone wrote down.")
        else:
            checked.append("on.push is tag-filtered, and names no branches")

    # 2. workflow_dispatch declares nothing
    if "workflow_dispatch" in on_names:
        wd_i = [i for n, i in on_keys if n == "workflow_dispatch"][0]
        wd_block = [l for l in child_lines(on_block, wd_i, 2)
                    if l.strip() and not l.lstrip().startswith("#")]
        if wd_block:
            problems.append(
                "`workflow_dispatch:` declares something. It must declare NOTHING -- no "
                "inputs, no knobs. There is no safe input, only one nobody has flipped "
                "yet. Found: %s" % "; ".join(l.strip() for l in wd_block[:4]))
        else:
            checked.append("workflow_dispatch declares no inputs")
    else:
        checked.append("workflow_dispatch is absent (the directive is satisfied trivially)")

    # --- the jobs ----------------------------------------------------------
    if jobs_idx is None:
        print("CANNOT RUN: %s has no top-level `jobs:` block." % path, file=sys.stderr)
        return EXIT_CANNOT_RUN

    jobs_block = child_lines(lines, jobs_idx, 0)
    job_keys = keys_at(jobs_block, 2)
    if not job_keys:
        print("CANNOT RUN: no jobs found under `jobs:` in %s. An empty scan is not a "
              "clean report." % path, file=sys.stderr)
        return EXIT_CANNOT_RUN

    workflow_dir = os.path.dirname(os.path.abspath(path))
    repo_root = os.path.abspath(os.path.join(workflow_dir, "..", ".."))

    for job_name, job_i in job_keys:
        body = child_lines(jobs_block, job_i, 2)
        text = "\n".join(strip_full_line_comments(body))

        gated = False
        perms = None
        for k, ki in keys_at(body, 4):
            if k == "if" and PUSH_GATE.search(body[ki]):
                gated = True
            if k == "permissions":
                perms = "\n".join([body[ki]] + child_lines(body, ki, 4))

        # Capabilities in the job AND in every local composite action it uses.
        found = []
        for what in capabilities_in(text):
            found.append("%s (in the job)" % what)
        for m in re.finditer(r"uses:\s*(\./[^\s'\"]+)", text):
            rel = m.group(1)
            for candidate in ("action.yml", "action.yaml"):
                ap = os.path.normpath(os.path.join(repo_root, rel, candidate))
                if not os.path.isfile(ap):
                    continue
                try:
                    sub = strip_full_line_comments(read_lines(ap))
                except OSError as exc:
                    problems.append("job `%s` uses %s and it could not be read (%s), so "
                                    "this gate did not look inside it."
                                    % (job_name, rel, exc))
                    continue
                for what in capabilities_in("\n".join(sub)):
                    found.append("%s (in %s)" % (what, rel))

        if found:
            if gated:
                checked.append("job `%s` can ship, and is gated on "
                               "github.event_name == 'push'" % job_name)
            else:
                problems.append(
                    "job `%s` can ship and is NOT gated on a tag push. It %s. Add "
                    "`if: github.event_name == 'push'` to the job, or move the "
                    "capability out of it."
                    % (job_name, ", ".join(sorted(set(found)))))
            continue

        # A job with no shipping capability today must still not hold the
        # permission to publish, because the next step someone adds inherits it.
        if gated:
            checked.append("job `%s` is tag-push only" % job_name)
        elif perms is None:
            problems.append(
                "job `%s` is not gated on a tag push and declares no `permissions:`, so "
                "it inherits the workflow's `contents: write` -- enough to create a "
                "release. Declare `permissions: contents: read`." % job_name)
        elif CONTENTS_WRITE.search(perms):
            problems.append(
                "job `%s` is not gated on a tag push and takes write access to contents, "
                "which is enough to create a release." % job_name)
        else:
            checked.append("job `%s` is dispatch-reachable and cannot write contents"
                           % job_name)

    # --- verdict -----------------------------------------------------------
    print("verify_dispatch_cannot_ship: %s" % path)
    print("  jobs examined: %d  (%s)" % (len(job_keys), ", ".join(n for n, _ in job_keys)))
    for c in checked:
        print("  [OK] %s" % c)

    if problems:
        print("", file=sys.stderr)
        print("THE DISPATCH ROUTE IS OPEN. A workflow_dispatch of this file could produce "
              "or publish an artefact with no tag behind it:", file=sys.stderr)
        for p in problems:
            print("    * %s" % p, file=sys.stderr)
        print("", file=sys.stderr)
        print('cut.yml\'s own header: "If you want a cut, write the tag down."',
              file=sys.stderr)
        return EXIT_VIOLATION

    print("  OK: no dispatch-reachable job can sign, notarise, package, release or upload.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
