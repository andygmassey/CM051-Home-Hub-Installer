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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main",
                    help="revision whose citations are known good")
    ap.add_argument("--check", action="store_true",
                    help="report only, write nothing")
    args = ap.parse_args()

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

    b = block_of(base)
    c = block_of(cur)
    if b is None:
        print("CANNOT-RUN: the re-arm comment's anchors are absent from %s."
              % args.base)
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
              % (len(base_cites), args.base, len(cur_cites)))
        return 2
    if not cur_cites:
        print("CANNOT-RUN: no line citations found in the re-arm comment.")
        return 2
    print("EXAMINED: %d citation(s), paired by order of appearance, base %s"
          % (len(cur_cites), args.base))

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
                            % (idx, bn, args.base, len(base_lines)))
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
    if args.check:
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


if __name__ == "__main__":
    sys.exit(main())
