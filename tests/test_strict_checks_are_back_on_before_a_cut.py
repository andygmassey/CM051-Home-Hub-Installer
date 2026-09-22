#!/usr/bin/env python3
"""strict_required_status_checks_policy must be back ON before a cut.

🔴 WHY THIS EXISTS. It was turned OFF on 2026-09-18, deliberately, by Archie on
Andy's approval, and board row 2208 records the reasoning and the measurement.
The row also records its own weakness, in its own words:

    GATE: NONE YET, AND THIS ROW IS THE ONLY RECORD THAT IT WAS TURNED OFF.

A setting that was turned off for a good reason, whose only trace is a line of
prose on a 200-row board, gets shipped in that state. Not because anyone decides
to, but because nobody is holding the thread on cut day. This turns that prose
into a mechanism.

WHY IT IS OFF, kept here so this file is not read as disagreement. Strict makes
every merge re-behind every other open pull request: at 36 open PRs that is 36
sequential update-and-rerun cycles re-running 45 to 151 check-runs to re-confirm
ONE required context. The row sampled 50 merged PRs for the signature of strict
having caught something and found zero. Its honest form is "weaker than it has
never fired, stronger than nobody has looked".

WHAT THIS ASSERTS, AND WHEN. Outside a cut it REPORTS and passes: turning it off
during the queue is the decision that was taken and this gate does not relitigate
it. With OSTLER_CUT_IN_PROGRESS=1 it FAILS while strict is off, because the cut
branch must be cut from a main whose required check was confirmed against the
tip it actually merged into.

🔴 AND IT REFUSES RATHER THAN PASSING WHEN IT CANNOT READ. A gate about a
repository setting that silently passes when the API is unreachable is worse
than no gate: it reports the setting is fine on every runner without a token.
No answer is CANNOT-RUN, never a pass.
"""
import json
import os
import subprocess
import sys

REPO = os.environ.get("OSTLER_GATE_REPO", "andygmassey/CM051-Home-Hub-Installer")
BRANCH = os.environ.get("OSTLER_GATE_BRANCH", "main")
CUT = os.environ.get("OSTLER_CUT_IN_PROGRESS", "") == "1"


def read_rules():
    """The rules on the branch, or a reason we could not read them."""
    override = os.environ.get("OSTLER_GATE_RULES_JSON")
    if override:                       # the self-test injects here, never the API
        try:
            return json.loads(override), None
        except ValueError as exc:
            return None, "the injected rules payload is not JSON (%s)" % exc
    try:
        out = subprocess.run(
            ["gh", "api", "repos/%s/rules/branches/%s" % (REPO, BRANCH)],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "could not run gh (%s)" % exc
    if out.returncode != 0:
        return None, ("gh exited %d reading the rules for %s@%s: %s"
                      % (out.returncode, REPO, BRANCH,
                         (out.stderr or "").strip()[:160] or "no stderr"))
    try:
        return json.loads(out.stdout), None
    except ValueError as exc:
        return None, "the rules endpoint did not return JSON (%s)" % exc


def strict_of(rules):
    """(strict, contexts) from the required_status_checks rule, or (None, []).

    None means NO SUCH RULE, which is a different answer from False and must not
    be collapsed into it: a branch with no required check at all is worse than
    one whose check is non-strict, and reporting them the same hides that.
    """
    for r in rules:
        if r.get("type") == "required_status_checks":
            p = r.get("parameters") or {}
            return (p.get("strict_required_status_checks_policy"),
                    [c.get("context") for c in p.get("required_status_checks", [])])
    return None, []


def main():
    rules, why = read_rules()
    if rules is None:
        print("CANNOT-RUN: %s. NOTHING about the branch protection was measured, "
              "and that is NOT a pass." % why)
        return 2
    if not isinstance(rules, list):
        print("CANNOT-RUN: the rules payload is %s, not a list. NOTHING was "
              "measured." % type(rules).__name__)
        return 2

    strict, contexts = strict_of(rules)
    print("EXAMINED: %d rule(s) on %s@%s" % (len(rules), REPO, BRANCH))
    print("  required_status_checks rule present : %s" % (strict is not None))
    print("  strict_required_status_checks_policy: %s" % strict)
    print("  required context(s)                 : %s" % (contexts or "NONE"))

    if strict is None:
        print("\nFAIL: %s@%s has NO required_status_checks rule at all, so nothing "
              "is required to pass before a merge. That is a stronger finding "
              "than strict being off and must not be read as the same thing."
              % (REPO, BRANCH))
        return 1

    if not contexts:
        print("\nFAIL: the rule exists and requires NO context, so it gates "
              "nothing.")
        return 1

    if strict:
        print("\nOK: strict is on and %d context(s) are required." % len(contexts))
        return 0

    if CUT:
        print("\nFAIL: strict_required_status_checks_policy is OFF and a cut is "
              "in progress. Board row 2208 records that it was turned off "
              "deliberately during the merge queue and MUST go back on before "
              "the cut branch is cut: a cut branch has to come from a main whose "
              "required check was confirmed against the tip it actually merged "
              "into. Turn it back on, then re-run.")
        return 1

    print("\nOK, OUTSIDE A CUT: strict is off, which is the decision recorded on "
          "board row 2208, and %d context(s) are still required. This becomes a "
          "FAIL under OSTLER_CUT_IN_PROGRESS=1." % len(contexts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
