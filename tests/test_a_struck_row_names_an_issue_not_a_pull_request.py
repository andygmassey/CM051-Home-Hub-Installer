#!/usr/bin/env python3
"""CM051. A BOARD ROW MAY NOT BE STRUCK ON THE CLOSURE OF A NUMBER.

WHAT HAPPENED, 2026-09-16 to 2026-09-18. Twenty-nine rows were removed from
the cut's count with the words "the issue this row names is CLOSED on
GitHub". Measured on 2026-09-18: all twenty-nine numbers resolve to a PULL
REQUEST, not an issue. The control settles that this is a real signal and not
the normal shape of the register: rows that were NOT struck resolve to closed
pull requests too (945, 949, 941, 951, 952, 953, 954, 958, 959, 960 among
them), so "closed on GitHub" was true of struck and unstruck rows alike and
could not discriminate between them.

The decisive measurement was the TITLES. Comparing each struck row's title
with the title of the PR its number resolves to, ZERO of twenty-nine shared
two or more distinctive words:

    row  947  iPhone pairing is broken: the QR scanner sheet is never...
    PR   947  cut(v1.0.39): the manifest the tag needs, and the six...

    row  948  The daily brief is sending fabricated iMessages
    PR   948  NOT FOR v1.0.39, make a dying scheduled agent loud

    row 1001  Consent jurisdiction is resolved by GPS, the opposite of...
    PR  1001  fix(install): the runtime guard asked for a CLIENT and...

Row 1014, struck by the same strike, is titled "78 registered rows name
issues that are already CLOSED". The row about this class of error was
removed by the error.

WHY THE GATE IS SHAPED THIS WAY. The obvious gate asks GitHub whether each
struck number is an issue. That gate cannot run without a token and a
network, and a gate that reports CANNOT-RUN for ever is the defect row #2110
already records: a non-answer hiding a real failure. So the BLOCKING arm is
offline and structural, and asks for the one thing nobody could have supplied
while making this mistake: THE TITLE OF WHAT CLOSED IT. Anybody who had to
write down "closed by: cut(v1.0.39): the manifest the tag needs" next to a
row about iPhone pairing would have seen it.

The API arm runs as well, and blocks, whenever a token is actually present.
It never converts its own absence into a pass: it says which arms ran.
"""
import glob
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:                                    # pragma: no cover
    print("CANNOT-RUN: PyYAML is not importable, so the board cannot be parsed.")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A gate carrying a strike VERDICT.
#
# THE FIRST VERSION OF THIS ANCHORED AT THE START OF THE GATE, AND ITS OWN
# MUTATION TEST CAUGHT IT. Measured on the v1.0.100 board: of the 29 rows
# struck on 2026-09-16, only 20 carried the strike as the leading token; the
# other 9 had it appended after existing gate text. An anchored predicate
# would have examined 20 and reported a clean sheet for the 9, which is the
# same silent-undercount shape as the strike it exists to catch.
#
# The form matched is the VERDICT form, "STRUCK <iso date>:", in capitals.
# That is deliberate rather than a bare substring: the reversal text written
# on 2026-09-18 has to quote the invalid reasoning in order to record it, and
# it says "struck on 2026-09-16" in lower case with no colon, so it cannot
# trip this. Asserted in the control below, not assumed.
STRIKE = re.compile(r"\bSTRUCK\s+\d{4}-\d{2}-\d{2}\s*:")

# The evidence a strike must carry. Any ONE of these is enough, and each
# forces the writer to look at the thing that supposedly closed the work.
EVIDENCE = (
    'titled "',
    "titled '",
    "TITLE:",
    "closed by:",
    "CLOSED BY:",
)

# The exact reasoning that removed 41 rows. A strike containing it is refused
# whatever else it says.
#
# DELIBERATELY CONSERVATIVE, and measured: a row whose gate QUOTES this phrase
# in order to record the history, as all 41 reversed rows now do, would also be
# refused if somebody later re-struck it. That is the right way round. A fresh
# strike has no reason to quote it, and a re-strike on a row that carries this
# history is exactly the case that deserves to be argued with a human rather
# than waved through by a substring.
BANNED = "the issue this row names is CLOSED on GitHub"


# A row's number is only meaningful in the repo the row names. `repo: none`
# means a measured finding rather than a tracker item, so its id resolves
# nowhere and must not be looked up against anything.
REPO_BY_DECLARATION = {
    "CM051": os.environ.get("OSTLER_REPO_CM051",
                            "andygmassey/CM051-Home-Hub-Installer"),
    "HR015": os.environ.get("OSTLER_REPO_HR015",
                            "andygmassey/HR015-Gaming-PC"),
}


def _cited_title(gate):
    """The title the strike wrote down, pulled back out for the reader.

    Deliberately forgiving about WHERE it sits, and deliberately silent about
    whether it is apt. This gate cannot tell whether a citation matches the
    row; that judgement stays with a person. All it does is put the two
    strings on adjacent lines so the person can make it in one glance.
    """
    for opener, closer in (('titled "', '"'), ("titled '", "'")):
        i = gate.find(opener)
        if i != -1:
            j = gate.find(closer, i + len(opener))
            if j != -1:
                return gate[i + len(opener):j].strip()
    for marker in ("closed by:", "CLOSED BY:", "TITLE:"):
        i = gate.find(marker)
        if i != -1:
            tail = gate[i + len(marker):].strip()
            # Up to the first sentence end that is not inside a version number.
            for end in (". ", "\n"):
                k = tail.find(end)
                if k > 0:
                    return tail[:k].strip()
            return tail.strip()
    return "<no title written down, which arm 1 should have caught>"


def newest_board():
    files = glob.glob(os.path.join(ROOT, "cut-manifests", "v1.0.*.yaml"))
    if not files:
        return None
    # By NUMBER. Lexically "v1.0.100" sorts before "v1.0.93", which is how a
    # reader of this directory gets the wrong board.
    def key(p):
        return [int(x) for x in re.findall(r"\d+", os.path.basename(p))]
    return sorted(files, key=key)[-1]


def main():
    board = newest_board()
    if board is None:
        print("CANNOT-RUN: no cut manifest found under cut-manifests/.")
        return 2
    with open(board, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    rows = (doc or {}).get("open_issues") or []
    if not rows:
        print("CANNOT-RUN: %s carries no open_issues rows, so nothing was"
              " examined." % board)
        return 2

    print("EXAMINED: %s, %d rows" % (os.path.relpath(board, ROOT), len(rows)))

    struck = [r for r in rows if STRIKE.search(str(r.get("gate", "")))]
    print("          %d of them carry a STRUCK verdict" % len(struck))

    failures = []

    # ARM 1, BLOCKING AND OFFLINE. A strike must name what closed it.
    for r in struck:
        gate = str(r.get("gate", ""))
        if BANNED in gate:
            failures.append(
                "#%s is struck with the exact reasoning that removed 29 rows"
                " on 2026-09-16: bare closure of a number." % r.get("issue"))
        elif not any(tok in gate for tok in EVIDENCE):
            failures.append(
                "#%s is struck without naming the TITLE of what closed it."
                " Write it down: a strike nobody can check is a row deleted"
                " from the count on trust." % r.get("issue"))

    if not struck:
        print("  ok    (1) no row carries a strike, so none can be unevidenced")
    elif not failures:
        print("  ok    (1) every struck row names the title of what closed it")
        # THE WHOLE VALUE OF ARM 1 IS THAT A READER SEES THE MISMATCH, so the
        # two strings have to end up ADJACENT. "cut(v1.0.39): the manifest the
        # tag needs" sitting on the line under "iPhone pairing is broken: the
        # QR scanner sheet is never presented" is self-evidently absurd; the
        # same two strings a screen apart are not, and a gate that collects
        # evidence nobody reads has done nothing. (Archie, 2026-09-18.)
        for r in struck:
            print("          #%-6s row    : %s" % (r.get("issue"),
                                                   str(r.get("title", ""))[:86]))
            print("          %-7s closed : %s" % ("", _cited_title(str(r.get("gate", "")))[:86]))

    # ARM 1 CONTROL. The predicate must reject a row it should reject, or a
    # clean sheet above means only that the loop never bites.
    probe_bad = {"issue": "SYNTHETIC", "gate":
                 "STRUCK 2026-01-01: " + BANNED + " so it is no longer counted."}
    probe_good = {"issue": "SYNTHETIC", "gate":
                  'STRUCK 2026-01-01: closed by: a PR titled "fix(x): the '
                  'thing this row describes", merged on main.'}
    bad_caught = (BANNED in probe_bad["gate"]) or not any(
        t in probe_bad["gate"] for t in EVIDENCE)
    good_passed = (BANNED not in probe_good["gate"]) and any(
        t in probe_good["gate"] for t in EVIDENCE)
    # And the reversal narrative, which must QUOTE the invalid reasoning in
    # order to record it, must not be read as a fresh strike.
    reversal_sample = ("STRIKE REVERSED 2026-09-18. This row was struck on "
                       "2026-09-16 with the words \"" + BANNED + "\".")
    reversal_clean = STRIKE.search(reversal_sample) is None
    if bad_caught and good_passed and reversal_clean:
        print("  ok    (1-CONTROL) the predicate rejects an unevidenced strike,"
              " accepts an evidenced one, and does NOT flag a reversal that"
              " quotes the old reasoning")
    else:
        failures.append(
            "the predicate itself is broken: bad_caught=%s good_passed=%s"
            " reversal_clean=%s" % (bad_caught, good_passed, reversal_clean))

    # ARM 2. The API arm. Blocks when a token is present; says so when not.
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not struck:
        print("  ----  (2) NOT RUN: there are no struck rows to resolve")
    elif not token:
        print("  ----  (2) NOT RUN: no GH_TOKEN or GITHUB_TOKEN in the"
              " environment, so issue-versus-pull-request cannot be resolved."
              " This is NOT a pass. Arm 1 is the blocking arm and it ran.")
    else:
        # RESOLVE AGAINST THE REPO THE ROW DECLARES, NEVER A DEFAULT.
        #
        # The first version of this arm hard-coded CM051 and I reported "41 of
        # 41 are pull requests" on that basis. Measured afterwards: 10 of the
        # 41 declare `repo: HR015` and resolve, in HR015-Gaming-PC, to OPEN
        # issues every one titled [LAUNCH]. Resolving a number against the
        # wrong repository is the SAME category error the strike made, and the
        # gate written to catch it had it too. A row's number is only
        # meaningful in the repo the row names.
        checked = prs = skipped = 0
        for r in struck:
            num = str(r.get("issue", "")).strip()
            if not num.isdigit():
                continue
            declared = str(r.get("repo", "")).strip()
            repo = REPO_BY_DECLARATION.get(declared)
            if repo is None:
                # `repo: none` means a measured finding, not a tracker item.
                # There is no issue for a strike to have found closed, and
                # resolving the id anywhere would invent a referent.
                skipped += 1
                continue
            try:
                out = subprocess.run(
                    ["gh", "api", "repos/%s/issues/%s" % (repo, num)],
                    capture_output=True, text=True, timeout=30,
                    env=dict(os.environ, GH_TOKEN=token))
            except Exception as exc:                    # pragma: no cover
                print("  ----  (2) stopped after %d: %s" % (checked, exc))
                break
            if out.returncode != 0:
                continue
            checked += 1
            try:
                if json.loads(out.stdout).get("pull_request"):
                    prs += 1
                    failures.append(
                        "#%s is struck, but in %s that number is a PULL"
                        " REQUEST, not an issue." % (num, repo))
            except ValueError:
                continue
        if skipped:
            print("          (2) %d struck row(s) declare `repo: none`, so their"
                  " number is an internal finding id with no tracker referent."
                  " Not resolved, and NOT counted as passing." % skipped)
        if checked == 0:
            print("  ----  (2) NOT RUN: resolved 0 of %d numbers, so this arm"
                  " measured nothing and is not a pass." % len(struck))
        else:
            print("  %s (2) resolved %d struck number(s) against the repo each"
                  " row DECLARES; %d are pull requests"
                  % ("ok   " if prs == 0 else "FAIL ", checked, prs))

    print()
    if failures:
        for f in failures:
            print("  FAIL  %s" % f)
        print()
        print("=== %d failure(s) ===" % len(failures))
        return 1
    print("=== clean ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
