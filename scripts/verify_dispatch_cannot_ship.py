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

# 🔴 TWO CLASSES, NOT ONE, AND THE SPLIT IS THE POINT OF THIS FILE NOW.
#
# This gate used to hold one list and one rule: any capability on the list, in
# any job that a workflow_dispatch can reach, is a violation. That rule was
# right for the workflow it was written against and it is wrong for the one we
# have, because #2118 deliberately changed the contract underneath it.
#
# WHAT CHANGED AND WHY. Under the old rule a dispatch could do nothing that
# resembled a cut, so a real DMG existed only AFTER a tag. That meant a
# candidate could never be walked before it became the ship. The v1.0.100 walk
# then failed six probes, every one of which can only run against an INSTALLED
# Ostler, four of them introduced since v1.0.95, while CI had 80+ green checks
# and had measured none of it. So the order was changed, not the guarantee:
# a dispatch MAY BUILD a real signed, notarised, stapled candidate, and MUST
# NOT PUBLISH it.
#
# PRODUCING makes an artefact. On a dispatch that artefact is a candidate: it
# is uploaded under a `candidate-<ref>-<run>` name, no release object is
# created, and no customer-reachable pointer changes. Permitted in a
# dispatch-reachable job, on the conditions enforced below.
#
# PUBLISHING puts an artefact, or a pointer to one, where a CUSTOMER can fetch
# it. Never permitted on a dispatch, in any job, at any indent.
#
# `make` is matched on its PRODUCING targets rather than on the word `make`,
# because `make print-version` and `make print-dmg-path` are questions, not
# builds, and a gate that flags a question gets switched off.
PRODUCING_CAPABILITIES = [
    (r"\bmake\b[^\n]*\b(ship|package|notarise[a-z-]*|staple[a-z-]*|"
     r"archive|sign-python-bundle|sparkle-embed)\b", "runs a producing `make` target"),
    (r"\bnotarytool\b", "calls notarytool"),
    (r"\bstapler\b", "calls stapler"),
    (r"\bcodesign\b", "calls codesign"),
    (r"\bsecurity\s+import\b", "imports a signing identity"),
    (r"upload-artifact", "uploads an artefact"),
    (r"OSTLER_SIGNING_CERT", "reads a signing credential"),
    (r"OSTLER_NOTARY", "reads a notary credential"),
]

# 🔴 THE TWO SHAPES CUT.YML ACTUALLY PUBLISHES THROUGH WERE NEVER ON THE OLD
# LIST, AND THAT IS THE MORE SERIOUS HALF OF THIS CHANGE.
#
# The old list caught `gh release create` and `action-gh-release`. cut.yml uses
# NEITHER. It publishes by running scripts/publish_release.sh, and it moves the
# update feed with `make publish-appcast`. Measured on this repo: neither string
# matches any pattern in the old list, so for the whole life of this gate the
# two steps that actually reach a customer went ungraded, while the gate spent
# its attention refusing the job the right to run codesign.
#
# `publish-appcast` is listed separately from the PRODUCING `make` targets on
# purpose. It is not a build, it is the pointer a customer's updater reads.
PUBLISHING_CAPABILITIES = [
    (r"action-gh-release", "creates a GitHub release"),
    (r"\bgh\s+release\s+(create|edit|upload|delete)\b", "writes a GitHub release"),
    (r"publish_release\.sh", "runs the release publisher"),
    (r"\bmake\b[^\n]*\bpublish-appcast\b", "publishes the update feed"),
    (r"\bmake\b[^\n]*\brelease\b", "runs a `make` release target"),
    (r"\bgit\s+push\b", "pushes to the repository"),
]

# Kept as the union so any reader or caller asking "what does this gate look
# for" still gets the whole answer from one name.
SHIPPING_CAPABILITIES = PRODUCING_CAPABILITIES + PUBLISHING_CAPABILITIES

PUSH_GATE = re.compile(r"github\.event_name\s*==\s*['\"]push['\"]")
CONTENTS_WRITE = re.compile(r"contents:\s*write|permissions:\s*write-all")

# A backslash immediately before a newline, GitHub-Actions-YAML style, is a
# shell line continuation: the two physical lines are ONE logical command.
# SHIPPING_CAPABILITIES bounds its `make` pattern to `[^\n]*` on purpose (so a
# `make` on one line can never be satisfied by an unrelated `release` many
# lines later in the same job body), but that same bound made it BLIND to
#     run: make \
#            ship
# which is one command split across two YAML lines. Undo exactly that split,
# and nothing else, before the capability regex ever runs.
LINE_CONTINUATION = re.compile(r"\\\r?\n[ \t]*")


def join_line_continuations(text):
    return LINE_CONTINUATION.sub(" ", text)


def is_safely_push_gated(if_line):
    """True only if this `if:` line CANNOT be satisfied by any event other
    than a tag push.

    A plain substring search on `github.event_name == 'push'` is not enough:
    it is satisfied by

        if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'

    which is TRUE on a dispatch -- the substring is present, the boolean is
    not push-only. Reject any `if:` containing a top-level `||`: an OR can
    only ever widen what the condition accepts, never narrow it, so its mere
    presence alongside the push check means the check no longer bounds the
    condition. An `&&` is safe by construction -- it can only narrow -- so it
    is not checked for here.
    """
    return "||" not in if_line and bool(PUSH_GATE.search(if_line))


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


def permissions_text(lines):
    """A `permissions:` block with every comment removed.

    🔴 THIS EXISTS BECAUSE THE BLOCK WAS READ AS RAW TEXT AND A COMMENT COULD
    DECIDE THE VERDICT. CONTENTS_WRITE was matched against the block verbatim,
    so a line of prose inside it mentioning `contents: write` reported the job
    as holding write access it does not hold. Found by writing exactly such a
    comment: cut.yml's permissions block was changed to `contents: read` and
    this gate still called it a violation, quoting a scope that was no longer
    in the file.

    It fails closed, so no unsafe workflow was ever passed by it. It is still
    wrong, and wrong in the direction that gets a gate switched off: an
    enforcer that reds on a file someone has just made safer, and names a
    cause the file no longer contains, does not survive contact with the
    person trying to ship.

    This is control 10's class exactly, one layer down. That control already
    proves prose cannot invent a CAPABILITY, because capability text is
    comment-stripped before the regex sees it. The permissions path never was.

    Trailing comments go too: `contents: read     # create the release` is the
    shape the old block was written in, and the words after the `#` are not
    the grant.
    """
    out = []
    for l in lines:
        if l.lstrip().startswith("#"):
            continue
        out.append(l.split("#", 1)[0])
    return "\n".join(out)


def capabilities_in(text, table=None):
    out = []
    for pattern, what in (SHIPPING_CAPABILITIES if table is None else table):
        if re.search(pattern, text):
            out.append(what)
    return out


def steps_of(job_body):
    """[(first_line_index, [lines])] for each `- ` item under this job's
    `steps:`. Returns [] when the job declares no steps, which is a real
    answer and not an error: a job with no steps cannot publish.

    Written as a list-item split rather than a YAML parse for the same reason
    the rest of this file is: the gate must give an honest answer on a file
    that a real parser would reject, and it must never depend on a dependency
    the cut runner might not have.
    """
    steps_i = [i for k, i in keys_at(job_body, 4) if k == "steps"]
    if not steps_i:
        return []
    block = child_lines(job_body, steps_i[0], 4)
    marks = [i for i, l in enumerate(block)
             if not is_blank_or_comment(l) and l.lstrip().startswith("- ")
             and indent_of(l) == min(indent_of(x) for x in block
                                     if not is_blank_or_comment(x))]
    out = []
    for n, start in enumerate(marks):
        end = marks[n + 1] if n + 1 < len(marks) else len(block)
        out.append((start, block[start:end]))
    return out


def step_is_push_gated(step_lines):
    """True when this step carries its own `if:` that cannot be satisfied by a
    dispatch. The `if:` may sit at any indent inside the step; a step is small
    and flat, so there is no ambiguity to resolve."""
    for l in step_lines:
        if is_blank_or_comment(l):
            continue
        if re.match(r"^\s*(-\s+)?if:", l) and is_safely_push_gated(l):
            return True
    return False


def step_name(step_lines):
    for l in step_lines:
        m = re.match(r"^\s*(?:-\s+)?name:\s*(.+?)\s*$", l)
        if m:
            return m.group(1)
    for l in step_lines:
        if not is_blank_or_comment(l):
            return l.strip()[:60]
    return "(unnamed step)"


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

    # 🔴 THE WORKFLOW-LEVEL BLOCK, BECAUSE A JOB THAT DECLARES NOTHING INHERITS
    # IT. The old code read only the job's own `permissions:` and, finding
    # none, asserted the job "inherits the workflow's `contents: write`". That
    # sentence was hard-coded, not measured. It is true of the workflow this
    # gate was written against and it is false the moment the workflow-level
    # block is tightened, at which point the gate would refuse a file that had
    # just been made SAFER. An enforcer that reds on the fix is an enforcer
    # people delete.
    #
    # Unknown is not safe. If neither level declares a block the effective
    # permission is the repository default, which is not in this file and which
    # this gate therefore cannot read. That case fails closed and says why.
    wf_perms = None
    for _n, _i in keys_at(lines, 0):
        if _n == "permissions":
            wf_perms = permissions_text([lines[_i]] + child_lines(lines, _i, 0))

    workflow_dir = os.path.dirname(os.path.abspath(path))
    repo_root = os.path.abspath(os.path.join(workflow_dir, "..", ".."))

    for job_name, job_i in job_keys:
        body = child_lines(jobs_block, job_i, 2)
        text = join_line_continuations("\n".join(strip_full_line_comments(body)))

        gated = False
        perms = None
        for k, ki in keys_at(body, 4):
            if k == "if" and is_safely_push_gated(body[ki]):
                gated = True
            if k == "permissions":
                perms = permissions_text([body[ki]] + child_lines(body, ki, 4))

        # Capabilities in the job AND in every local composite action it uses.
        produce = capabilities_in(text, PRODUCING_CAPABILITIES)
        publish = capabilities_in(text, PUBLISHING_CAPABILITIES)

        # A composite action is attributed to the JOB and never to a step,
        # deliberately. The `uses:` step's own `if:` does not travel into the
        # action file, so a per-step verdict on a capability found in a
        # composite would be a guess about the ship route. Fail closed instead.
        publish_hidden = []
        for m in re.finditer(r"uses:\s*(\./[^\s'\"]+)", text):
            rel = m.group(1)
            for candidate in ("action.yml", "action.yaml"):
                ap = os.path.normpath(os.path.join(repo_root, rel, candidate))
                if not os.path.isfile(ap):
                    continue
                try:
                    sub_lines = strip_full_line_comments(read_lines(ap))
                except OSError as exc:
                    problems.append("job `%s` uses %s and it could not be read (%s), so "
                                    "this gate did not look inside it."
                                    % (job_name, rel, exc))
                    continue
                sub_text = join_line_continuations("\n".join(sub_lines))
                for what in capabilities_in(sub_text, PRODUCING_CAPABILITIES):
                    produce.append("%s (in %s)" % (what, rel))
                for what in capabilities_in(sub_text, PUBLISHING_CAPABILITIES):
                    publish_hidden.append("%s (in %s)" % (what, rel))

        # --- PUBLISHING. Graded per STEP, because that is how cut.yml guards it.
        #
        # The publishing steps sit inside a job a dispatch can reach and each
        # carries its own `if: github.event_name == 'push'`. Grading publishing
        # at job level would force one of two wrong answers: refuse a file that
        # is in fact safe, or bless a job because some OTHER step in it was
        # gated. Neither is the question. The question is whether the step that
        # reaches a customer can run without a tag.
        if gated:
            if publish or publish_hidden:
                checked.append("job `%s` can publish, and the whole job is gated on "
                               "github.event_name == 'push'" % job_name)
        else:
            for what in sorted(set(publish_hidden)):
                problems.append(
                    "job `%s` can PUBLISH through a composite action and is reachable "
                    "by a workflow_dispatch. It %s. This gate cannot see a step `if:` "
                    "from inside an action file, so the capability has to leave the "
                    "dispatch-reachable job, or the job has to be tag-gated."
                    % (job_name, what))

            graded = 0
            for _si, step_lines in steps_of(body):
                stext = join_line_continuations(
                    "\n".join(strip_full_line_comments(step_lines)))
                what = capabilities_in(stext, PUBLISHING_CAPABILITIES)
                if not what:
                    continue
                graded += 1
                if step_is_push_gated(step_lines):
                    checked.append("job `%s` step `%s` publishes and carries its own "
                                   "push gate" % (job_name, step_name(step_lines)))
                else:
                    problems.append(
                        "job `%s` step `%s` can PUBLISH and is reachable by a "
                        "workflow_dispatch. It %s. Publishing is the one thing a "
                        "dispatch must never do: add `if: github.event_name == "
                        "\'push\'` to the step, or move it into a tag-gated job."
                        % (job_name, step_name(step_lines), ", ".join(sorted(set(what)))))

            # The capability is in the job text but in no step: a job-level
            # `env:`, a `defaults:`, a `container:`. Nothing here can be gated
            # by a step `if:`, so there is no safe reading of it.
            if publish and graded == 0 and not publish_hidden:
                problems.append(
                    "job `%s` can PUBLISH and is reachable by a workflow_dispatch, and "
                    "the capability is NOT inside any step, so no step `if:` can gate "
                    "it. It %s." % (job_name, ", ".join(sorted(set(publish)))))

        # --- PRODUCING. Permitted on a dispatch, and reported rather than
        #     waved through, so `cut.yml`'s cost is visible in the gate's own
        #     output: a dispatch spends the signing identity and a notarisation
        #     round trip. That is the price of finding out before shipping.
        if produce and not gated:
            checked.append("job `%s` can BUILD a candidate on a dispatch (%s), which "
                           "#2118 permits so a candidate can be walked before it is "
                           "tagged" % (job_name, ", ".join(sorted(set(produce)))))

        # --- THE PERMISSION, CHECKED ON EVERY DISPATCH-REACHABLE JOB.
        #
        # This used to be skipped entirely whenever a capability was found: the
        # old code `continue`d out of the loop after the capability verdict, so
        # the most dangerous jobs in the file were the only ones whose
        # permissions were never examined. Now nothing skips it.
        if gated:
            checked.append("job `%s` is tag-push only" % job_name)
            continue

        effective = perms if perms is not None else wf_perms
        where = "its own `permissions:`" if perms is not None else "the workflow's"
        if effective is None:
            problems.append(
                "job `%s` is not gated on a tag push and NEITHER it nor the workflow "
                "declares a `permissions:` block, so its token is whatever the "
                "repository default happens to be. That default is not in this file "
                "and this gate cannot read it, so it cannot be called safe. Declare "
                "`permissions: contents: read`." % job_name)
        elif CONTENTS_WRITE.search(effective):
            problems.append(
                "job `%s` is not gated on a tag push and takes write access to "
                "contents from %s, which is enough to create a release. A dispatch "
                "may build a candidate; it may not hold the key to publishing one."
                % (job_name, where))
        else:
            checked.append("job `%s` is dispatch-reachable and cannot write contents "
                           "(from %s)" % (job_name, where))

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

    # The old summary here said "no dispatch-reachable job can sign,
    # notarise, package, release or upload". Under the contract this file
    # now enforces that sentence is false, and it was printed directly
    # below a line reporting that the `cut` job does exactly those things.
    # A verdict that contradicts its own evidence teaches the reader to
    # stop reading the evidence.
    print("  OK: no dispatch-reachable job can PUBLISH, and none holds write\n        access to contents. Building a candidate on a dispatch is allowed\n        and is listed above where it applies.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
