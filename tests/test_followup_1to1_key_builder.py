#!/usr/bin/env python3
"""followup_keys_match_chat_threads: the product's key builder is measured on a
synthetic 1:1 seeded through the shipped writer.

Walk 132 never wrote a synthetic conversation, so no key was ever checked and
the denominator stayed at zero. The seed now writes one 1:1 (never chat.db), and
the judge FAILs a 1:1 that the product built with NO thread key.

Judge-level, no box. Control: the same capture with the 1:1 fields absent does
not FAIL, so the rule is what changes the verdict. Exit 0 pass, 1 fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
sys.path.insert(0, LIB)
import followup_keys_probe as fk  # noqa: E402

BASE = {"ssh_user_reads_chat_db": "no", "available": True, "measured": True, "enabled": True,
        "chat_db_readable": True, "keyed_rows": 2, "keys_matching_one_to_one": 0,
        "keys_matching_group": 0, "completed_by_followup": 0, "reopened": 0,
        "walk_db_readable": True, "walk_synthetic_keyed": 1, "walk_synthetic_collisions": 0,
        "db_keyed_rows": 2}


def case(**extra):
    c = dict(BASE)
    c.update(extra)
    return fk.judge(c)


def main():
    bad = []
    lines, rc = case(walk_1to1_rows=1, walk_1to1_keyed=0)
    if rc != fk.EX_FAIL or not any("NO thread key" in l for l in lines):
        bad.append("a 1:1 built with no thread key must FAIL, got rc=%s" % rc)
    lines, rc = case(walk_1to1_rows=1, walk_1to1_keyed=1)
    if rc == fk.EX_FAIL:
        bad.append("a 1:1 that carries a key must not FAIL, got rc=%s" % rc)
    # control: with the 1:1 fields absent (seed not run), the same keyless state does not FAIL
    lines, rc = case()
    if rc == fk.EX_FAIL:
        bad.append("CONTROL: without the 1:1 fields the verdict must not be the 1:1 FAIL, got rc=%s" % rc)
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: a keyless synthetic 1:1 FAILs; a keyed one does not; control without the 1:1 fields does not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
