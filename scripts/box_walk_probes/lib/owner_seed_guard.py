#!/usr/bin/env python3
"""owner_seed_guard: may owner_knowledge_score score the box right now?

Walk 132 scored 0% while the owner-employer seed (the linkedin_positions fact for the
seeded organisation) was still live in the graph. The seed is removed later in the walk,
so the score measured a seed, not the product's knowledge. Scoring must refuse while the
seed is live, and refuse when it cannot tell.

decide(sparql_json_text) -> "LIVE" | "CLEAR" | "UNKNOWN"
  LIVE     the count is above zero: a seed fact is in the graph
  CLEAR    the count is exactly zero
  UNKNOWN  the reply is not a count (no answer, error, wrong shape): never CLEAR

Usage: owner_seed_guard.py decide  (reads the SPARQL JSON on stdin; prints the word)
       owner_seed_guard.py --self-test
"""
import json
import sys


def decide(text):
    try:
        d = json.loads(text)
        v = d["results"]["bindings"][0]["n"]["value"]
        n = int(v)
    except (ValueError, KeyError, IndexError, TypeError):
        return "UNKNOWN"
    if n < 0:
        return "UNKNOWN"
    return "LIVE" if n > 0 else "CLEAR"


def self_test():
    cases = [
        ('{"results":{"bindings":[{"n":{"value":"3"}}]}}', "LIVE"),
        ('{"results":{"bindings":[{"n":{"value":"0"}}]}}', "CLEAR"),
        ("", "UNKNOWN"),
        ("not json", "UNKNOWN"),
        ('{"results":{"bindings":[]}}', "UNKNOWN"),
    ]
    bad = [(t, want, decide(t)) for t, want in cases if decide(t) != want]
    for t, want, got in bad:
        print("BROKEN: %r want %s got %s" % (t, want, got))
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:2] == ["decide"]:
        print(decide(sys.stdin.read()))
        sys.exit(0)
    print(__doc__, file=sys.stderr)
    sys.exit(2)
