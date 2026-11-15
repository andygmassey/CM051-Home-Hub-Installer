#!/usr/bin/env python3
"""The VENDORED hub route module (vendor/cm041/assistant_api/derived_preferences.py,
the producer behind GET /api/v1/preferences/derived) passes a derived node's
pwg:privacyLevel through as the item's `privacy_level` and never serves L3.

CM019 #423 stamps the level; the oa tool, the brief and the digest drop L3
client-side. This pins the route agreeing with them, using the hub's existing
pwg_privacy doctrine (L3 hidden, L0/L1/L2 served, unparseable fails closed, no
level = served untagged so older graphs do not go blank). The reader runs
against a REAL in-memory pyoxigraph store. Synthetic values only.

  arm 1  L1 and L2 nodes are served and tagged with their level.
  arm 2  an L3 node is not served.
  arm 3  a present-but-unparseable level is not served.
  arm 4  CONTROL: a node with no level IS served, untagged.
  arm 5  the Python guard holds when the store ignores the query filter.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AAPI = REPO / "vendor" / "cm041" / "assistant_api"
if not (AAPI / "derived_preferences.py").is_file():
    print("CANNOT-RUN: vendored derived_preferences.py is missing")
    sys.exit(2)
try:
    import pyoxigraph as ox
except ImportError:
    print("CANNOT-RUN: pyoxigraph is not installed")
    sys.exit(2)
sys.path.insert(0, str(AAPI))
from derived_preferences import (  # noqa: E402
    DERIVED_GRAPH, PWG_NS, DerivedGraphReader, build_derived_preferences_response,
)

PASS = FAIL = 0
DBL = ox.NamedNode("http://www.w3.org/2001/XMLSchema#double")


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


def store_with(nodes):
    store = ox.Store()
    g = ox.NamedNode(DERIVED_GRAPH)
    typ = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    for nid, label, level in nodes:
        s = ox.NamedNode(f"urn:synthetic:derived:{nid}")
        quads = [
            (typ, ox.NamedNode(PWG_NS + "DerivedPreference")),
            (ox.NamedNode(PWG_NS + "dimension"), ox.Literal("media.film.genre")),
            (ox.NamedNode(PWG_NS + "subject"), ox.Literal(label)),
            (ox.NamedNode(PWG_NS + "preferenceStrength"), ox.Literal("0.8", datatype=DBL)),
            (ox.NamedNode(PWG_NS + "confidence"), ox.Literal("0.9", datatype=DBL)),
        ]
        if level is not None:
            quads.append((ox.NamedNode(PWG_NS + "privacyLevel"), ox.Literal(level)))
        for p, o in quads:
            store.add(ox.Quad(s, p, o, g))
    return store


def sparql(store):
    def run(q):
        res = store.query(q)
        names = [v.value for v in res.variables]
        return [{n: sol[i].value for i, n in enumerate(names) if sol[i] is not None}
                for sol in res]
    return run


NODES = [("a", "synthetic noir", "L1"), ("b", "synthetic opera", "L2"),
         ("c", "synthetic sealed", "L3"), ("d", "synthetic plain", None),
         ("e", "synthetic odd", "secret")]
resp = build_derived_preferences_response(
    DerivedGraphReader(sparql(store_with(NODES))), "synthetic_owner_01", limit=20)
items = {i["label"]: i for i in resp["items"]}

print("arm 1: L1 and L2 are served and tagged")
check(not resp["degraded"], "response is not degraded")
check(items.get("synthetic noir", {}).get("privacy_level") == "L1", "L1 tagged L1")
check(items.get("synthetic opera", {}).get("privacy_level") == "L2", "L2 tagged L2")
print("arm 2: L3 is not served")
check("synthetic sealed" not in items, "the L3 node is absent")
print("arm 3: an unparseable level is not served")
check("synthetic odd" not in items, "the 'secret' node is absent")
print("arm 4: control, no level is served untagged")
check("synthetic plain" in items and "privacy_level" not in items["synthetic plain"],
      "the unlevelled node is served without privacy_level")
print("arm 5: the Python guard holds when the store ignores the filter")
rows = [{"s": "urn:d:1", "dimension": "x", "subject": "synthetic sealed",
         "strength": "0.5", "confidence": "0.9", "privacy": "L3"},
        {"s": "urn:d:2", "dimension": "x", "subject": "synthetic opera",
         "strength": "0.5", "confidence": "0.9", "privacy": "l2"}]
r5 = build_derived_preferences_response(
    DerivedGraphReader(lambda q: rows if "DerivedPreference" in q else []), "synthetic_owner_01")
check([i["label"] for i in r5["items"]] == ["synthetic opera"], "only the L2 row is served")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
