#!/usr/bin/env python3
"""CX-126 (#660): IdentityResolver fuzzy matching must load the candidate set
ONCE per run (in-memory), not re-query Oxigraph for every contact.

The old _fuzzy_match issued an unbounded "SELECT all persons" for EVERY
resolve(use_fuzzy=True) -> O(n^2). On a real 3,810-connection LinkedIn export
that query measured 8.1s at ~900 people and grew super-linearly, so the
install crawled then effectively hung (CX-126 / #660). This guard proves:
  1. the all-persons candidate query is issued exactly ONCE across many
     resolves (O(n), not O(n^2));
  2. fuzzy matching still returns the right person from the in-memory cache;
  3. register_person() keeps the cache current with no extra DB round-trip.

The SPARQL layer is stubbed, so no live Oxigraph is needed. Synthetic data.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "cm041"))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

# Substring unique to the all-persons fuzzy-candidate SELECT.
FUZZY_SIG = "?person ?name ?org ?linkedinUrl WHERE"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def build_resolver(seed_people):
    r = IdentityResolver("http://localhost:7878")
    calls = {"fuzzy": 0}

    def fake_sparql_query(sparql):
        if FUZZY_SIG in sparql:
            calls["fuzzy"] += 1
            bindings = []
            for p in seed_people:
                row = {
                    "person": {"value": p["uri"]},
                    "name": {"value": p["name"]},
                }
                if p.get("org"):
                    row["org"] = {"value": p["org"]}
                if p.get("url"):
                    row["linkedinUrl"] = {"value": p["url"]}
                bindings.append(row)
            return {"results": {"bindings": bindings}}
        # Tier 1/2 exact-identifier lookups: no match.
        return {"results": {"bindings": []}}

    r._sparql_query = fake_sparql_query  # type: ignore[method-assign]
    return r, calls


def main() -> None:
    seed = [
        {"uri": "urn:p1", "name": "Jane Smith", "org": "Acme"},
        {"uri": "urn:p2", "name": "Bob Jones", "org": "Globex"},
    ]
    r, calls = build_resolver(seed)

    # 1. Many name-only resolves must trigger the all-persons query ONCE.
    for i in range(50):
        r.resolve(PersonIdentity(display_name=f"Unrelated Person {i}"), use_fuzzy=True)
    if calls["fuzzy"] != 1:
        fail(
            f"all-persons candidate query issued {calls['fuzzy']} times across 50 "
            f"resolves; expected exactly 1 -- the O(n^2) is NOT fixed"
        )
    print("PASS: all-persons candidate query issued exactly ONCE across 50 resolves (O(n))")

    # 2. Correctness: an exact name + org still matches the seeded person.
    m = r.resolve(
        PersonIdentity(display_name="Jane Smith", organization="Acme"), use_fuzzy=True
    )
    if not (m and m.person_uri == "urn:p1"):
        fail(f"fuzzy match against the cache failed to find the right person: {m}")
    if calls["fuzzy"] != 1:
        fail("a later resolve re-queried the graph; the cache is not being reused")
    print("PASS: fuzzy match against the in-memory cache returns the right person")

    # 3. register_person makes a NEW person matchable with no extra DB query.
    r.register_person("urn:p3", "Carol Danvers", org="Stark")
    m2 = r.resolve(
        PersonIdentity(display_name="Carol Danvers", organization="Stark"),
        use_fuzzy=True,
    )
    if not (m2 and m2.person_uri == "urn:p3"):
        fail(f"register_person did not make the new person matchable: {m2}")
    if calls["fuzzy"] != 1:
        fail("register_person path triggered a re-query; it must be purely in-memory")
    print("PASS: register_person adds an in-memory candidate (no re-query)")

    # 4. A genuinely new name still returns no match (no false positives).
    m3 = r.resolve(PersonIdentity(display_name="Zxqv Wphtb"), use_fuzzy=True)
    if m3 and m3.person_uri:
        fail(f"unrelated name falsely matched: {m3}")
    print("PASS: an unrelated name returns no match (no false positive)")

    print("\nALL IDENTITY-RESOLVER FUZZY-CACHE TESTS PASSED")


if __name__ == "__main__":
    main()
