#!/usr/bin/env python3
"""Re-point the RE-ARM comment's line citations after install.sh moves.

WHY THIS EXISTS (CM051 #2152). The RE-ARM STORE CREDENTIAL comment in
install.sh cites fifteen lines BY NUMBER, and
tests/test_store_curl_config_survives_the_promote.sh checks that each cited
line still contains the construct the comment names. That gate is RIGHT: a
comment citing :7574 for a line now at :7627 is worse than one citing
nothing, because a reader checks it once, finds something plausible, and
stops.

But any insertion above a citation invalidates it, so every install.sh change
that adds lines turns the gate red. Measured 2026-09-18, twice in one
session: PR #2143 added 267 lines and moved 7 citations, PR #2151 added 30
and moved 11. Both were repaired by hand.

HOW IT WORKS, AND TWO DESIGNS THAT WERE WRONG FIRST.

NOT AN OFFSET. The tempting repair is to add the line delta. :15296 names
"#177 ALL OVER AGAIN", not the WhatsApp note the surrounding prose is
discussing, and that note sits at :3265, nowhere near either number. A
uniform offset would land that citation on a line the gate's predicate
ACCEPTS while the comment's claim about it is wrong, because the predicate
checks that the line matches the claim, not that the claim is about the right
thing. The gate would go green on a comment that had become a lie.

NOT A TEXT ANCHOR EITHER, which was this script's first design and it failed
on its first run in two separate ways. Taking the exact text of each cited
line and searching for it in the working tree breaks because (a) the text has
to be read at the BASE citation number, not the current one, and (b) the
cited lines are not unique: `_ostler_promote_prelaunch_tree` occurs twice and
`fi` occurs 94 times. It refused rather than guessing, which is the only
reason it did not quietly re-point ten citations at the wrong lines.

WHAT IT DOES: a LINE ALIGNMENT between the base revision and the working
tree, via difflib.SequenceMatcher over the two files' lines. That maps base
line N to working-tree line M for every line that survived, handles duplicate
text correctly because it aligns by position within the edit script, and has
no mapping at all for a line that was deleted. The citations in the comment
are paired with the base comment's citations BY ORDER OF APPEARANCE, since
the prose is unchanged and only the numbers move.

IT REFUSES RATHER THAN GUESSES, at every step: a different number of
citations between base and tree, a base line with no image under the
alignment, or a target that fails the gate's own accept predicate. A citation
silently re-pointed at the wrong line is exactly the failure the gate exists
to prevent, and it would look like a successful repair.

USAGE
    python3 scripts/repair_rearm_citations.py --check   # report, change nothing
    python3 scripts/repair_rearm_citations.py           # rewrite install.sh
    python3 scripts/repair_rearm_citations.py --base <git-rev>

Exit 0 nothing to do, 1 repairs needed or made, 2 CANNOT-RUN.
"""
import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL = ROOT / "install.sh"

START = "    # RE-ARM THE STORE CREDENTIAL AGAINST THE PATH THAT NOW EXISTS."
END = "    if declare -f _ostler_write_store_curl_config"
CITE = re.compile(r":(\d{3,5})\b")


# The gate's own accept predicate, mirrored from
# tests/test_store_curl_config_survives_the_promote.sh. A repair this script
# makes must satisfy the same test the gate applies, or it has not repaired
# anything.
_ACCEPT = (
    "_ostler_write_store_curl_config",
    "_OSTLER_STORE_CURL_ARGS",
    "_ostler_promote_prelaunch_tree",
    "_ostler_set_paths",
    'rm -rf "$OSTLER_PRELAUNCH_DIR"',
    "local _conf=",
    "THIRD OCCURRENCE OF THIS CLASS",
    "#177 ALL OVER AGAIN",
    "A gate keyed to a name does not cover a class",
)


def _accepted(line):
    return any(tok in line for tok in _ACCEPT)


def block_of(text):
    """The re-arm comment, or None if its anchors have moved."""
    try:
        i = text.index(START)
        j = text.index(END, i)
    except ValueError:
        return None
    return text[i:j], i, j


def align_and_report(base, cur, base_label, check, write_path):
    """The whole judgement, over two TEXTS rather than two files.

    Split out of main() so --self-test can drive it with a MUTATED copy held
    in memory: the self-test then needs no git revision, writes nothing, and
    exercises the accept predicate against the REAL install.sh lines rather
    than a synthetic file, which could encode the shape the code handles
    instead of the shape the repository has.

    Exit codes as in the module docstring: 0 nothing to do, 1 repairs needed
    or made, 2 CANNOT-RUN.
    """
    b = block_of(base)
    c = block_of(cur)
    if b is None:
        print("CANNOT-RUN: the re-arm comment's anchors are absent from %s."
              % base_label)
        return 2
    if c is None:
        print("CANNOT-RUN: the re-arm comment's anchors are absent from the"
              " working tree. Re-point START/END in this script rather than"
              " deleting it.")
        return 2
    base_block, _, _ = b
    cur_block, cur_i, cur_j = c

    base_lines = base.split("\n")
    cur_lines = cur.split("\n")

    base_cites = CITE.findall(base_block)
    cur_cites = CITE.findall(cur_block)
    if len(base_cites) != len(cur_cites):
        print("CANNOT-RUN: the comment carries %d citation(s) at %s and %d in"
              " the working tree. The prose itself changed, so they cannot be"
              " paired by position. Repair by hand."
              % (len(base_cites), base_label, len(cur_cites)))
        return 2
    if not cur_cites:
        print("CANNOT-RUN: no line citations found in the re-arm comment.")
        return 2
    print("EXAMINED: %d citation(s), paired by order of appearance, base %s"
          % (len(cur_cites), base_label))

    # The alignment. base line N (1-indexed) -> working-tree line, for every
    # line that survived the edit. A deleted line simply has no entry, which
    # is why a missing key is a refusal and never a fallback.
    sm = difflib.SequenceMatcher(None, base_lines, cur_lines, autojunk=False)
    amap = {}
    for a0, b0, size in sm.get_matching_blocks():
        for k in range(size):
            amap[a0 + k + 1] = b0 + k + 1
    print("  alignment: %d of %d base lines survive into the working tree"
          % (len(amap), len(base_lines)))

    moves, refusals, already = {}, [], 0
    for idx, (b_raw, c_raw) in enumerate(zip(base_cites, cur_cites), 1):
        bn, cn = int(b_raw), int(c_raw)
        if bn < 1 or bn > len(base_lines):
            refusals.append("citation %d: :%d is outside %s (%d lines)"
                            % (idx, bn, base_label, len(base_lines)))
            continue
        target = amap.get(bn)
        if target is None:
            refusals.append("citation %d: base line :%d was DELETED, so there"
                            " is nothing to re-point it at: %r"
                            % (idx, bn, base_lines[bn - 1].strip()[:60]))
            continue
        if not _accepted(cur_lines[target - 1]):
            refusals.append("citation %d: :%d -> :%d, but that line fails the"
                            " gate's own accept predicate, so the alignment"
                            " disagrees with the comment: %r"
                            % (idx, bn, target, cur_lines[target - 1].strip()[:60]))
            continue
        if target == cn:
            already += 1
        else:
            moves[cn] = target

    print("  already correct : %d" % already)
    print("  would move      : %d" % len(moves))
    print("  REFUSED         : %d" % len(refusals))
    for r in refusals:
        print("      %s" % r)
    for old in sorted(moves):
        print("      :%-6d -> :%-6d  %s"
              % (old, moves[old], cur_lines[moves[old] - 1].strip()[:64]))

    if refusals:
        print()
        print("REFUSING TO WRITE. A citation re-pointed by guessing is the"
              " defect this gate exists to catch, and it would look like a"
              " successful repair.")
        return 2
    if not moves:
        print("\nNothing to do: every citation still lands on its anchor.")
        return 0
    if check:
        print("\n--check: %d citation(s) need re-pointing." % len(moves))
        return 1

    new_block = cur_block
    # Two passes through a sentinel, so a value written in pass one cannot be
    # matched again in pass two. Longest number first, so a shorter citation
    # cannot be eaten as the prefix of a longer one.
    #
    # 🔴 AND NO TIDYING REGEX AFTERWARDS. The first version finished with
    # `re.sub(r":(\d{3,5}):", r":\1", ...)` to clean up doubled colons, and it
    # ate a LEGITIMATE one: ":353: #177 baked a staging path" became ":353 #177
    # baked a staging path". The gate did not catch it, because line 353 still
    # contains the construct the comment names, so the citation was still
    # correct and only the prose was damaged. A repair tool that silently
    # edits the sentence around the number is worse than the staleness it
    # fixes. Caught only by diffing the tool's output against the hand repair.
    for i, old in enumerate(sorted(moves, key=lambda x: (-len(str(x)), x))):
        new_block = new_block.replace(":%d" % old, "\x00%d\x00" % i)
    for i, old in enumerate(sorted(moves, key=lambda x: (-len(str(x)), x))):
        new_block = new_block.replace("\x00%d\x00" % i, ":%d" % moves[old])
    assert "\x00" not in new_block, "a sentinel survived the rewrite"
    INSTALL.write_text(cur[:cur_i] + new_block + cur[cur_j:], encoding="utf-8")
    print("\nRewrote %d citation(s) in install.sh. Run"
          " tests/test_store_curl_config_survives_the_promote.sh." % len(moves))
    return 1


def _fixture():
    """An install.sh-shaped text whose citations are correct BY CONSTRUCTION.

    🔴 THE FIXTURE MUST NOT BE THE WORKING TREE, AND THIS FUNCTION EXISTS
    BECAUSE IT WAS. The first version of this self-test read the real
    install.sh and passed it as BOTH base and current to arm 1, then demanded
    exit 0 on the grounds that an unchanged tree is clean. That conflates two
    different properties: "no citation MOVED" is a fact about the checker, and
    "every citation lands on its anchor" is a fact about the FILE. Any branch
    part-way through an install.sh change fails the second while satisfying
    the first, so the self-test went red on exactly the trees the tool exists
    to repair, and it reported the tool broken rather than the citations
    stale. Measured 2026-09-18 on a branch with 40 lines of real drift: arm 1
    got exit 2 wanting 0, arm 2 got 2 wanting 1, and arms 3 and 4 PASSED FOR
    THE WRONG REASON, because they demand exit 2 and a refusal is exit 2
    whatever caused it. Two arms silently stopped testing anything.

    Same shape as the mutant whose baseline was a moving ref: a fixture that
    moves under the test it anchors is not a fixture.

    The line numbers below are COMPUTED, never written down, because a
    hand-written citation in a test about hand-written citations going stale
    would be the defect wearing the costume of its own guard.
    """
    body = ["# filler %d" % i for i in range(1, 120)]

    def place(text):
        body.append(text)
        return len(body)          # 1-indexed line number of what was just added

    n_def = place("_ostler_write_store_curl_config() {")
    n_conf = place('    local _conf="${OSTLER_DIR}/secrets/store-curl.conf"')
    body.extend(["# filler %d" % i for i in range(120, 150)])
    n_args = place('    _OSTLER_STORE_CURL_ARGS=( -K "$_conf" )')
    body.extend(["# filler %d" % i for i in range(150, 180)])
    n_prom = place("_ostler_promote_prelaunch_tree() {")

    body += [
        START,
        "    # the writer captures the path by value:",
        "    #     :%d   the writer's definition" % n_def,
        "    #     :%d   the config path it captures" % n_conf,
        "    #     :%d   the array it arms" % n_args,
        "    #     :%d   the promote that invalidates it" % n_prom,
        END + " >/dev/null 2>&1; then",
        "        _ostler_write_store_curl_config || true",
        "    fi",
    ]
    return "\n".join(body), [n_def, n_conf, n_args, n_prom]


def self_test():
    """Prove this checker can still go red, can still refuse, and can pass.

    🔴 A GATE THAT CANNOT FAIL IS NOT A GATE, and this one is at particular
    risk of becoming one: on most pull requests install.sh is untouched, so
    base and tree are identical, the alignment is the identity map and the
    step reports 18 of 18 already correct. That green says the base revision
    resolved. It says NOTHING about whether the checker would notice a moved
    citation, so CI watches it notice one on every run.

    Four hermetic arms over a fixture that is clean by construction, plus two
    arms over the REAL install.sh that assert only what is true whatever the
    state of that file's citations. The real-file arms are what stops the
    fixture encoding the shape the code handles rather than the shape the
    repository has; the hermetic arms are what stops the tree's own staleness
    being read as a broken checker. Nothing is written by any arm.
    """
    fixture, cited = _fixture()
    lines = fixture.split("\n")

    failures = []

    def arm(name, base, cur, want):
        print("\n--- SELF-TEST ARM: %s (demands exit %d) ---" % (name, want))
        got = align_and_report(base, cur, "self-test fixture", True, None)
        print("    exit %d, wanted %d" % (got, want))
        if got != want:
            failures.append("%s: exit %d, wanted %d" % (name, got, want))

    # 1. A fixture whose citations are right reads clean. Without this arm the
    #    others could all pass on a checker that never returns zero.
    arm("a fixture with correct citations is clean", fixture, fixture, 0)

    # 2. THE ARM THAT MATTERS. Three lines inserted at the top shift every
    #    citation, and none of the inserted text goes anywhere near the
    #    comment, so a checker that compared only the comment block would see
    #    nothing and pass.
    shifted = "\n".join(["# self-test insertion"] * 3 + lines)
    arm("three lines inserted above everything", fixture, shifted, 1)

    # 3. A refusal, not a guess: the anchors gone means the block cannot be
    #    located at all.
    arm("the comment's start anchor is deleted",
        fixture, fixture.replace(START, "    # (anchor removed)", 1), 2)

    # 4. A refusal of the other kind: a CITED line is deleted, so the
    #    alignment has no image for it. Re-pointing that citation at whatever
    #    sits at the same number afterwards is exactly the silent damage this
    #    tool refuses to do.
    n = cited[0]
    gutted = "\n".join(lines[:n - 1] + lines[n:])
    arm("a cited line is deleted (citation :%d)" % n, fixture, gutted, 2)

    # 5 and 6 keep the checker in contact with the REAL file. Neither asserts
    #   that the tree's citations are correct, because on a branch mid-change
    #   they are not, and that is the tool's input rather than its verdict.
    if not INSTALL.is_file():
        print("\nREAL-FILE ARMS CANNOT-RUN: install.sh not found at %s"
              % INSTALL)
        failures.append("real-file arms could not be built")
    elif block_of(INSTALL.read_text(encoding="utf-8")) is None:
        print("\nREAL-FILE ARMS CANNOT-RUN: the re-arm comment's anchors are"
              " absent from install.sh, so there is nothing to align.")
        failures.append("real-file arms could not be built")
    else:
        real = INSTALL.read_text(encoding="utf-8")

        # 5. Identity in, no movement out. True however stale the citations
        #    are, because nothing can have moved when nothing changed. A 1
        #    here means the aligner invented a move.
        print("\n--- SELF-TEST ARM: the real install.sh against itself"
              " (demands anything but 1) ---")
        got = align_and_report(real, real, "install.sh itself", True, None)
        print("    exit %d, wanted 0 or 2, never 1" % got)
        if got == 1:
            failures.append("real file against itself reported a move: the"
                            " alignment is not the identity map")

        # 6. And it must never call a shifted real file clean. This is the
        #    real-file half of arm 2, weakened to the one claim that survives
        #    a tree whose citations are already stale.
        print("\n--- SELF-TEST ARM: the real install.sh shifted by three"
              " lines (demands anything but 0) ---")
        got = align_and_report(
            real, "\n".join(["# self-test insertion"] * 3
                            + real.split("\n")), "install.sh itself", True, None)
        print("    exit %d, wanted 1 or 2, never 0" % got)
        if got == 0:
            failures.append("a shifted real file was reported clean")

    print()
    if failures:
        print("SELF-TEST FAIL: %d arm(s) did not behave" % len(failures))
        for f in failures:
            print("    %s" % f)
        return 1
    print("SELF-TEST PASS: 6 of 6 arms behaved, exits 0/1/2 all represented.")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main",
                    help="revision whose citations are known good")
    ap.add_argument("--check", action="store_true",
                    help="report only, write nothing")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the checker still goes red, and still refuses")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not INSTALL.is_file():
        print("CANNOT-RUN: install.sh not found at %s" % INSTALL)
        return 2
    cur = INSTALL.read_text(encoding="utf-8")

    try:
        base = subprocess.run(
            ["git", "-C", str(ROOT), "show", "%s:install.sh" % args.base],
            capture_output=True, text=True, check=True).stdout
    except Exception as exc:
        print("CANNOT-RUN: could not read install.sh at %s (%s)"
              % (args.base, exc))
        return 2

    return align_and_report(base, cur, args.base, args.check, INSTALL)


if __name__ == "__main__":
    sys.exit(main())
