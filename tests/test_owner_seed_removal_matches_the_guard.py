#!/usr/bin/env python3
"""The owner-employer seed removal deletes what the guard checks for.

ORM, walk 132 (MBP): the removal left a linkedin_positions owner-employer fact live, and
owner_knowledge_score's guard refused. The guard counts facts with
    pwg:source "linkedin_positions" ; pwg:organization <seed org>
but the removal DELETE matched the seed's full pattern, which also required pwg:jobTitle. Any
fact with the same source and organisation but another title survived the removal.

This test reads both patterns from the real library and requires the removal to delete every
fact the guard counts (same source, same organisation, no extra title condition).

RED on the old library: the removal pattern required pwg:jobTitle, so the check fails there.
Control: a copy with the old pattern restored is caught. Exit 0 pass, 1 fail. No box.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib", "owner_employer_seed.sh")
GUARD = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes", "owner_knowledge_score.sh")


def removal_pattern(src):
    """The WHERE clause of the forget's DELETE (the removal) as written in the library."""
    m = re.search(r'DELETE \{ \?f \?p \?o \} WHERE \{ (.*?) \?f \?p \?o \}', src)
    return m.group(1) if m else None


def covers_guard(where):
    """True when the removal matches the guard's shape: same source, same organisation,
    and no further title condition that would leave a guard-counted fact behind."""
    if where is None:
        return False  # e.g. the old removal names the seed through a variable ($M), which carries a title
    return ("linkedin_positions" in where and "pwg:organization" in where
            and "jobTitle" not in where)


def main():
    with open(LIB, encoding="utf-8") as fh:
        src = fh.read()
    with open(GUARD, encoding="utf-8") as fh:
        guard_src = fh.read()
    bad = []
    where = removal_pattern(src)
    if not covers_guard(where):
        bad.append("the removal must delete every fact the guard counts (source and organisation, no title condition); got %r" % where)
    if "linkedin_positions" not in guard_src or "pwg:organization" not in guard_src:
        bad.append("CONTROL: the guard query in owner_knowledge_score.sh must still count by source and organisation")
    mutant = src.replace("?f pwg:source \\\\\\\"linkedin_positions\\\\\\\" ; pwg:organization",
                         "?f pwg:source \\\\\\\"linkedin_positions\\\\\\\" ; pwg:jobTitle \\\\\\\"x\\\\\\\" ; pwg:organization", 1)
    if mutant != src and covers_guard(removal_pattern(mutant)):
        bad.append("CONTROL: a removal that requires a job title must not satisfy the check")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the removal deletes what the guard counts (source and organisation); a title-bound removal is caught")
    return 0


if __name__ == "__main__":
    sys.exit(main())
