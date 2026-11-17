#!/usr/bin/env python3
"""Replace the owner's first name with "the owner" in cut paperwork.

Archie ruling 2026-11-17: cut manifests and cuts/<v>/cut.env must carry 0
occurrences of the owner's name. Cut paperwork is CARRIED forward from the
previous cut (new_cut.sh copies cut.env; manifests are carried by
scripts/carry_cut_manifest.sh), so the name propagated by copy. Both carry
paths now pipe through this filter.

Terms come from the operator inventory ($HOME/.ostler-operator-pii.toml,
[family_names].names). No term is ever written in this repo.

  owner_scrub.py            stdin -> stdout, replaced
  owner_scrub.py --count    stdin -> prints occurrence count

Exit 2 (CANNOT-RUN) if the inventory is absent or holds no terms: a scrub
that could not look must never read as a scrub that found nothing.
"""
import os, re, sys, tomllib

def terms():
    p = os.path.join(os.environ.get("HOME", ""), ".ostler-operator-pii.toml")
    try:
        with open(p, "rb") as f:
            names = tomllib.load(f).get("family_names", {}).get("names", [])
    except (OSError, tomllib.TOMLDecodeError) as e:
        print("CANNOT-RUN: operator inventory unreadable (%s)" % type(e).__name__, file=sys.stderr); sys.exit(2)
    names = [n for n in names if isinstance(n, str) and n.strip()]
    if not names:
        print("CANNOT-RUN: inventory has no family_names terms", file=sys.stderr)
        sys.exit(2)
    return names

def main():
    pat = re.compile(r"(?<![A-Za-z])(%s)(?![A-Za-z])" % "|".join(re.escape(n) for n in terms()), re.I)
    data = sys.stdin.read()
    if "--count" in sys.argv[1:]:
        print(len(pat.findall(data)))
    else:
        sys.stdout.write(pat.sub("the owner", data))

main()
