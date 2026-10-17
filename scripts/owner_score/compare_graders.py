#!/usr/bin/env python3
"""Grade ONE run under the OLD grader (revision 1, grading_legacy.py) and the
NEW one (revision 2, grading.py), side by side, so a score is always reported
both ways and a grader change is never mistaken for a product change.

    python3 -I compare_graders.py --evidence-dir DIR      replies kept by a live run
    python3 -I compare_graders.py --answers answers.json  {question id: reply}

Prints ids, scores and the grader's reason only. It never prints a reply or a
question, and it never reads a reply from anywhere but the file you name. It
refuses (exit 3) if the instrument no longer matches CHECKSUM.lock, which now
covers grading_legacy.py too, so the OLD side cannot be quietly edited.
Questions that moved are listed with both reasons; a question that scores
differently under the two graders but is NOT one of the intended changes
(a date_range question or an absent question) is flagged UNEXPECTED.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grading         # noqa: E402
import grading_legacy  # noqa: E402
import owner_score     # noqa: E402


def load_replies(args):
    if args.answers:
        return json.load(open(args.answers))
    out = {}
    for name in ("replies.jsonl", "replies_heldout.jsonl"):
        path = os.path.join(args.evidence_dir, name)
        if os.path.exists(path):
            for line in open(path, encoding="utf-8"):
                if line.strip():
                    r = json.loads(line)
                    out[r["id"]] = r.get("reply")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="compare_graders")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--answers")
    g.add_argument("--evidence-dir")
    ap.add_argument("--set", choices=("visible", "heldout", "all"), default="all")
    a = ap.parse_args(argv)

    ok, combined, msg = owner_score.verify_checksum(
        [os.path.join(HERE, f) for f in owner_score.CHECKED], owner_score.LOCK)
    print("CHECK  built-in sha256 %s" % combined)
    print("CHECK  %s" % msg)
    if not ok:
        return owner_score.EX_TAMPERED

    qs = []
    if a.set in ("visible", "all"):
        qs += owner_score.load_questions(os.path.join(HERE, "questions_visible.jsonl"))
    if a.set in ("heldout", "all"):
        qs += owner_score.load_questions(os.path.join(HERE, "questions_heldout.jsonl"))
    replies = load_replies(a)
    asked = [q for q in qs if q["id"] in replies]
    if not asked:
        print("CANNOT-RUN: none of the %d questions has a reply in the input" % len(qs))
        return owner_score.EX_CANNOT_RUN
    if len(asked) < len(qs):
        print("NOTE   %d of %d questions have a reply; the rest are left out of BOTH scores" % (len(asked), len(qs)))

    old_o, old_c, old_q = grading_legacy.score_set(asked, replies)
    new_o, new_c, new_q = grading.score_set(asked, replies)
    print("OLD GRADER (revision 1)  %.1f%%  (%d questions)" % (old_o * 100, len(asked)))
    print("NEW GRADER (revision 2)  %.1f%%  (%d questions)" % (new_o * 100, len(asked)))
    print("DELTA                    %+.1f points" % ((new_o - old_o) * 100))
    print("PER-CATEGORY  old -> new")
    for c in grading.CATEGORIES:
        if c in new_c:
            print("  %-14s %5.1f%% -> %5.1f%%" % (c, old_c[c] * 100, new_c[c] * 100))
    moved = [q for q in asked if old_q[q["id"]][0] != new_q[q["id"]][0]]
    print("MOVED %d" % len(moved))
    unexpected = 0
    for q in moved:
        intended = bool(q.get("date_range")) or q["kind"] == "absent"
        unexpected += 0 if intended else 1
        print("  [%s] %s (%s) -> %s (%s)%s" % (q["id"], old_q[q["id"]][0], old_q[q["id"]][1],
              new_q[q["id"]][0], new_q[q["id"]][1], "" if intended else "  UNEXPECTED"))
    worse = [q for q in moved if new_q[q["id"]][0] < old_q[q["id"]][0]]
    if worse:
        print("REGRESSIONS %d: %s" % (len(worse), ", ".join(q["id"] for q in worse)))
    return 1 if unexpected or worse else 0


if __name__ == "__main__":
    sys.exit(main())
