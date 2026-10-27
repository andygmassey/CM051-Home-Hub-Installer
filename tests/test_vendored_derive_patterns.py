#!/usr/bin/env python3
"""Trend, say-vs-do contradiction and time-of-day context, from the SHIPPED tree.

Drives vendor/cm019_preferences (derive_runner, engine, patterns, writer with its
real pyshacl gate, pyoxigraph, reader, endpoint) so a deriver that is green in
the source repo but registered nowhere on a box fails here.

  arm 1  the real runner, a synthetic graph whose evidence is recent and sits in
         the evening: the genre node carries pwg:trend "rising" and
         pwg:timeContext "evening" IN THE GRAPH.
  arm 2  RED CONTROL: the same run with the registration removed has neither.
  arm 3  say-vs-do through writer, store, reader and endpoint: a stated dislike
         against positive behaviour is served with contradiction.winner "stated"
         and suppress true, the strength is the SAME as without the deriver (no
         polarity flip), and the reason quotes nothing of the statement.
  arm 4  an item with no pattern fields serves exactly the v1 keys.
  arm 6  the shipped stated reader + orders -> marker; another person's statement -> none.
  arm 5  MUTANTS: a deriver that raises keeps the base nodes and is reported;
         a non-concentrated time spread gets no context.
Synthetic values only. Exit: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

os.environ["TZ"] = "UTC"
time.tzset()

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
sys.path[:0] = [str(HERE), str(TREE / "services" / "common"), str(SRC)]
try:
    import pyoxigraph  # noqa: F401
    import pyshacl  # noqa: F401
    import rdflib  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyoxigraph rdflib pyshacl pyyaml")
    sys.exit(2)

import derive.patterns as patterns  # noqa: E402
import derive_runner  # noqa: E402
from derive.endpoint import build_derived_preferences_response  # noqa: E402
from derive.engine import Aggregator, DerivationEngine, DimensionConfig  # noqa: E402
from derive.model import DERIVED_GRAPH, ENRICH_NS, PWG_NS, RDFS_NS, EvidenceItem  # noqa: E402
from derive.query import DerivedGraphReader  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402
from derive.writer import DerivedGraphWriter  # noqa: E402
from pyoxigraph import RdfFormat, Store  # noqa: E402
from test_derive_engine_writes_a_derived_preference import (  # noqa: E402
    Gateway, Mirror, OxigraphStore)

NOW = datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc)
GENRE = "synthetic-genre-alpha"
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  ok   " if cond else "  FAIL ") + msg)


def seed(raw):
    """Seven synthetic films, one genre. Six on weekday evenings inside the last
    540 days, one on a weekday evening in the window before."""
    when = [f"2026-09-0{d}T19:15:00Z" for d in (1, 2, 3, 4, 8, 9)] + ["2024-12-02T19:15:00Z"]
    ttl = [f"@prefix enr: <{ENRICH_NS}> .", f"@prefix rdfs: <{RDFS_NS}> .",
           f'<urn:test:genre> rdfs:label "{GENRE}" .']
    points = []
    for i, w in enumerate(when):
        pid = f"00000000-0000-0000-0000-00000000000{i}"
        ttl.append(f"<urn:ostler:preference:{pid}> enr:hasGenre <urn:test:genre> ; "
                   "enr:enrichmentConfidence 0.9 .")
        points.append({"id": pid, "payload": {
            "category": "movie", "subject": f"Synthetic Film {i}", "source": "netflix",
            "strength": 0.8, "observed_at": w}})
    raw.load("\n".join(ttl).encode(), format=RdfFormat.TURTLE)
    # A steady peer genre (4 recent, 4 prior): the share GENRE is judged against.
    ttl2 = ['<urn:test:genreb> rdfs:label "synthetic-genre-beta" .']
    peer = [f"2026-08-1{d}T20:15:00Z" for d in range(4)] + [f"2024-11-1{d}T20:15:00Z" for d in range(4)]
    for j, w in enumerate(peer):
        pid = f"00000000-0000-0000-0000-0000000001{j:02d}"
        ttl2.append(f"<urn:ostler:preference:{pid}> enr:hasGenre <urn:test:genreb> ; "
                    "enr:enrichmentConfidence 0.9 .")
        points.append({"id": pid, "payload": {
            "category": "movie", "subject": f"peer film {j}", "source": "netflix",
            "strength": 0.8, "observed_at": w}})
    raw.load("\n".join(["@prefix enr: <%s> ." % ENRICH_NS, "@prefix rdfs: <%s> ." % RDFS_NS] + ttl2).encode(),
             format=RdfFormat.TURTLE)
    return points


def graph_values(st, predicate):
    q = ("SELECT ?v WHERE { GRAPH <%s> { ?n a <%sDerivedPreference> ; <%s%s> ?v } }"
         % (DERIVED_GRAPH, PWG_NS, PWG_NS, predicate))
    return [r["v"]["value"] for r in st._select(q)]


def run_runner(points_raw_seed=True):
    raw = Store()
    st = OxigraphStore(raw)
    points = seed(raw)
    status = Path(tempfile.mkdtemp(prefix="patterns-")) / "state.json"
    rc = derive_runner.run("synthetic_owner", Gateway(st, points), st,
                           PyShaclValidator(), Mirror(), status, now=NOW)
    return rc, st


print("arm 1: the real runner writes trend and context into the graph")
rc, st = run_runner()
check(rc == 0, f"runner exit 0 (got {rc})")
check("rising" in graph_values(st, "trend"), f"pwg:trend {graph_values(st, 'trend')} (GENRE gains share on a steady peer)")
check("evening" in graph_values(st, "timeContext"),
      f"pwg:timeContext {graph_values(st, 'timeContext')}")

print("arm 2: RED CONTROL, registration removed")
real = patterns.default_derivers
patterns.default_derivers = lambda *a, **k: []
try:
    rc, st0 = run_runner()
finally:
    patterns.default_derivers = real
check(rc == 0 and graph_values(st0, "trend") == [] and graph_values(st0, "timeContext") == [],
      "no pwg:trend, no pwg:timeContext without the derivers")


def stated_reader(with_stated=True):
    class R:
        dimension = "food.drink"

        def read(self, user):
            out = [EvidenceItem(
                preference_id=f"b{i}", user_id="u", domain="food", dimension="food.drink",
                value="coffee", value_qid=None, item_strength=0.5,
                polarity_source="behavioral", source="orders",
                observed_at=NOW - timedelta(days=10 + i), enrichment_confidence=0.8,
                raw_subject="coffee") for i in range(4)]
            if with_stated:
                out.append(EvidenceItem(
                    preference_id="s0", user_id="u", domain="food", dimension="food.drink",
                    value="coffee", value_qid=None, item_strength=-0.8,
                    polarity_source="stated", source="messages",
                    observed_at=NOW - timedelta(days=40), enrichment_confidence=0.9,
                    raw_subject="synthetic-private-sentence"))
            return out
    return R()


def served(derivers):
    raw = Store()
    st = OxigraphStore(raw)
    dims = [DimensionConfig("food.drink", "drink", min_evidence=3)]
    eng = DerivationEngine([stated_reader()], Aggregator(dims),
                           derivers=derivers(dims) if derivers else [])
    nodes = eng.run_result("u", now=NOW).nodes
    DerivedGraphWriter(st, PyShaclValidator(), mirror=None).write(nodes)
    return build_derived_preferences_response(
        DerivedGraphReader(st._select), "u", min_confidence=0.0, tier="all", now=NOW)["items"]


print("arm 3: say-vs-do, written, read back and served")
with_d = {i["label"]: i for i in served(patterns.default_derivers)}
without = {i["label"]: i for i in served(None)}
c = with_d["coffee"]
check(c.get("contradiction", {}).get("winner") == "stated" and c["contradiction"]["suppress"] is True,
      f"contradiction {c.get('contradiction', {}).get('winner')} suppress={c.get('contradiction', {}).get('suppress')}")
check(c["strength"] == without["coffee"]["strength"], "strength identical with and without the deriver (no flip)")
check("synthetic-private-sentence" not in repr(c["contradiction"]),
      "the marker carries counts, not the statement's text")

print("arm 4: backwards compatible")
check("contradiction" not in without["coffee"] and "trend" not in without["coffee"],
      "no deriver, no optional keys")
check({"dimension", "label", "strength", "confidence", "intensity", "because"} <= set(c),
      "the v1 keys are all still present")

print("arm 5: mutants")


class Boom:
    method = "boom"

    def derive(self, items, nodes, now=None):
        raise RuntimeError("x")


dims = [DimensionConfig("food.drink", "drink", min_evidence=3)]
run = DerivationEngine([stated_reader()], Aggregator(dims), derivers=[Boom()]).run_result("u", now=NOW)
check(run.ok and len(run.nodes) == 1 and run.failed_derivers,
      "a deriver that raises keeps the base node and is reported")
spread = [EvidenceItem(preference_id=f"x{i}", user_id="u", domain="food", dimension="food.drink",
                       value="tea", value_qid=None, item_strength=0.5, polarity_source="behavioral",
                       source="orders", observed_at=datetime(2026, 9, 1 + i, h, 15, tzinfo=timezone.utc),
                       enrichment_confidence=0.8, raw_subject="tea")
          for i, h in enumerate((7, 13, 19, 2))]
nodes = Aggregator(dims).aggregate(spread, now=NOW)
patterns.ContextDeriver().derive(spread, nodes, now=NOW)
check(nodes[0].context == [], "evenly spread evidence gets no context")

print("arm 6: say-vs-do through the SHIPPED stated reader")
from derive import stated  # noqa: E402
from derive.config import build_readers, load_dimensions  # noqa: E402


class FactStore:
    """rdflib dataset in CM048's triple shape; answers the reader's real SPARQL."""

    def __init__(self):
        self.ds = rdflib.Dataset()
        self.n = 0

    def fact(self, text, about="user/Tester"):
        self.n += 1
        ttl = (f'<urn:ostler:fact/f{self.n}> a <urn:ostler:Fact> ; '
               f'<urn:ostler:fromConversation> <urn:ostler:conversation/c{self.n}> ;\n'
               f'  <urn:ostler:about> <urn:ostler:{about}> ; <urn:ostler:userId> "Tester" ;\n'
               f'  <urn:ostler:type> "preference" ; <urn:ostler:domain> "food" ;\n'
               f'  <urn:ostler:privacyLevel> "L1" ; <urn:ostler:signalStrength> "strong" ;\n'
               f'  <urn:ostler:provenanceHeader> "[pwg:src=imessage id=x date=2026-09-01]" ;\n'
               f'  <urn:ostler:text> "{text}" .\n')
        self.ds.graph(rdflib.URIRef("urn:ostler:user/Tester")).parse(data=ttl, format="turtle")

    def sparql(self, q):
        return [{str(k): {"value": str(v)} for k, v in r.asdict().items()}
                for r in self.ds.query(q)]


class Orders:
    dimension = "food.drink"

    def read(self, user):
        return [EvidenceItem(
            preference_id=f"o{i}", user_id=user, domain="food", dimension="food.drink",
            value="Coffee", value_qid=None, item_strength=0.5, polarity_source="behavioral",
            source="orders", observed_at=NOW - timedelta(days=5 + 9 * i),
            enrichment_confidence=0.8, raw_subject="Coffee") for i in range(5)]


def marker_for(fact_about):
    fs = FactStore()
    fs.fact("Tester hates coffee.", about=fact_about)
    sr = next(r for r in build_readers(fs) if isinstance(r, stated.StatedConversationReader))
    dd = load_dimensions()
    run_ = DerivationEngine([sr, Orders()], Aggregator(dd), derivers=patterns.default_derivers(dd)
                            ).run_result("Tester", now=NOW)
    return {(n.dimension, n.subject): n for n in run_.nodes}[("food.drink", "Coffee")]


own = marker_for("user/Tester")
check(own.contradiction and own.contradiction["winner"] == "stated" and own.contradiction["suppress"],
      "owner's stated dislike + coffee orders -> contradiction marker (shipped reader)")
check(marker_for("person/John").contradiction is None,
      "control: someone else's statement makes no marker")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
