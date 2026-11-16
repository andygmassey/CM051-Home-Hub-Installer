#!/usr/bin/env python3
"""The owner-employer seed is removed by the probe that judged against it, at that probe's end.

Walk 132 (MBP): owner_knowledge_score scored while the employer fact was still live and was
refused by its guard. The fix is on the seeding side: owner_digest_knows_the_owner, which
judges against the employer seed, removes that seed after its judgement. No later probe sees
it, and the owner_knowledge guard stays as the safety net.

Checks (source-level, no box):
  - the removal runs AFTER the judgement (the verdict is taken first, so removal changes no verdict)
  - the removal runs BEFORE probe_pass / probe_cannot_run, so every verdict path reaches it
  - it reads the before and after counts, so a removal that acted is visible (positive control)
  - control: the same probe with the removal call taken out fails the check

Exit 0 pass, 1 fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes",
                     "owner_digest_knows_the_owner.sh")


def removes_own_seed(src):
    judged = src.find('out="$(python3 "${_HERE}/lib/owner_digest.py" judge')
    removal = src.find("owner_employer_seed_forget 2>&1")
    verdict = src.find('case "${rc}" in')
    counted_before = src.find("OES before=")
    counted_after = src.find("OES after=")
    return (judged != -1 and removal != -1 and verdict != -1
            and judged < removal < verdict
            and counted_before != -1 and counted_after != -1)


def main():
    with open(PROBE, encoding="utf-8") as fh:
        src = fh.read()
    bad = []
    if not removes_own_seed(src):
        bad.append("owner_digest_knows_the_owner must remove the employer seed after its judgement and before its verdict, reading before and after counts")
    mutant = src.replace("owner_employer_seed_forget 2>&1", "owner_employer_seed_NOT_CALLED 2>&1", 1)
    if removes_own_seed(mutant):
        bad.append("CONTROL: with the removal call taken out, the check must fail")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the seeding probe removes its employer seed after judging, before the verdict; control red without the call")
    return 0


if __name__ == "__main__":
    sys.exit(main())
