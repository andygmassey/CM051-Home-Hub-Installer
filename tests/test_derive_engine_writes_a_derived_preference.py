#!/usr/bin/env python3
"""The VENDORED derive engine writes pwg:DerivedPreference nodes from a graph.

"What you like" shipped with no producer: nothing on a box ever wrote the
derived named graph, so the wiki page and the oa tool read an empty graph on
every install. This drives the copy that SHIPS
(vendor/cm019_preferences/services/enrich/src/derive_runner.py) end to end:

  real derive_runner.run()
    -> real readers (readers.yaml), real Aggregator (dimensions.yaml)
    -> real DerivedGraphWriter: temp graph, real pyshacl gate, DROP + MOVE
    -> pyoxigraph, the engine the Hub runs

Only the two stores are replaced: Qdrant by a list of synthetic points, and
Oxigraph's HTTP surface by an in-memory pyoxigraph Store that executes the
writer's real SPARQL. Every title and name below is synthetic.

  arm 1  three films sharing a genre and two sharing a director produce
         pwg:DerivedPreference nodes in the named graph, each with
         pwg:derivedFrom back to the literal items; the default graph is not
         touched; the status file says "written" with the real node count and
         carries no preference label.
  arm 2  a reader that fails writes NOTHING: the graph from arm 1 survives
         byte for byte and the status says "not_written".
  arm 3  a SHACL rejection writes nothing either, and the prior graph survives.
  arm 4  RED CONTROL: the same fixture under the min-evidence floor derives 0
         nodes. The graph is PRESENT (run marker) and the node count is 0, so
         arm 1's count is measuring nodes, not graph presence.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
COMMON = TREE / "services" / "common"
RUNNER = SRC / "derive_runner.py"

for p in (RUNNER, SRC / "derive" / "writer.py", COMMON / "strength.py",
          TREE / "ontology" / "shacl" / "derived-preference-shapes.ttl"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)

try:
    import pyoxigraph  # noqa: F401
    import pyshacl  # noqa: F401
    import rdflib  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyoxigraph rdflib pyshacl pyyaml")
    sys.exit(2)

sys.path.insert(0, str(COMMON))
sys.path.insert(0, str(SRC))

import derive_runner  # noqa: E402
from derive.model import DERIVED_GRAPH, ENRICH_NS, PWG_NS, RDFS_NS  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402
from pyoxigraph import RdfFormat, Store  # noqa: E402

NOW = datetime(2026, 10, 17, tzinfo=timezone.utc)
GENRE = "synthetic-genre-alpha"
DIRECTOR = "Director Example One"

PASS = 0
FAIL = 0


def check(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


def _bindings(results) -> list:
    out = []
    for sol in results:
        row = {}
        for var in results.variables:
            term = sol[var]
            if term is not None:
                row[var.value] = {"value": term.value}
        out.append(row)
    return out


class OxigraphStore:
    """The writer's GraphStore + the reader's SPARQL surface, over pyoxigraph."""

    def __init__(self, store: Store):
        self.s = store

    def update(self, sparql_update: str) -> None:
        self.s.update(sparql_update)

    def _select(self, query: str) -> list:
        return _bindings(self.s.query(query))

    def count_default_graph_triples(self) -> int:
        return int(self._select("SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")[0]["c"]["value"])

    def count_graph_triples(self, graph_iri: str) -> int:
        q = "SELECT (COUNT(*) AS ?c) WHERE { GRAPH <%s> { ?s ?p ?o } }" % graph_iri
        return int(self._select(q)[0]["c"]["value"])

    def graph_triples_turtle(self, graph_iri: str) -> str:
        q = "SELECT ?s ?p ?o WHERE { GRAPH <%s> { ?s ?p ?o } } ORDER BY ?s ?p ?o" % graph_iri
        return "\n".join(f"{r['s']['value']} {r['p']['value']} {r['o']['value']}"
                         for r in self._select(q))


class Gateway:
    """StoreGateway: Qdrant is a list of points; SPARQL goes to the store."""

    def __init__(self, store: OxigraphStore, points: list, fail_scroll: bool = False):
        self.store, self.points, self.fail_scroll = store, points, fail_scroll

    def sparql(self, query: str) -> list:
        return self.store._select(query)

    def scroll(self, categories, fields) -> list:
        if self.fail_scroll:
            raise ConnectionError("qdrant unreachable (synthetic)")
        return [p for p in self.points if p["payload"].get("category") in categories]


class Mirror:
    def __init__(self):
        self.points = None

    def replace_all(self, points):
        self.points = list(points)


class RejectingValidator:
    def validate_turtle(self, data_ttl):
        return False, "synthetic SHACL rejection"


def seed(store: Store, n_films: int) -> list:
    """n synthetic films: all share GENRE, the first two share DIRECTOR."""
    ttl = [f"@prefix enr: <{ENRICH_NS}> .", f"@prefix rdfs: <{RDFS_NS}> .",
           "<urn:test:genre> rdfs:label \"%s\" ." % GENRE,
           "<urn:test:director> rdfs:label \"%s\" ; enr:entityType \"director\" ." % DIRECTOR]
    points = []
    for i in range(n_films):
        pid = f"00000000-0000-0000-0000-00000000000{i}"
        subj = f"<urn:ostler:preference:{pid}>"
        ttl.append(f"{subj} enr:hasGenre <urn:test:genre> ; enr:enrichmentConfidence 0.9 .")
        if i < 2:
            ttl.append(f"{subj} enr:hasEntity <urn:test:director> .")
        points.append({"id": pid, "payload": {
            "category": "movie", "subject": f"Synthetic Film {i}", "source": "netflix",
            "strength": 0.8, "observed_at": "2026-09-01T00:00:00Z"}})
    store.load("\n".join(ttl).encode(), format=RdfFormat.TURTLE)
    return points


def status_of(path: Path) -> dict:
    return json.loads(path.read_text())


def node_count(st: OxigraphStore) -> int:
    return derive_runner.count_derived_nodes(st, DERIVED_GRAPH)


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="derive-test-"))
    status_path = tmp / "state" / "derived-preferences.json"

    print("arm 1: a fixture graph produces pwg:DerivedPreference nodes")
    raw = Store()
    st = OxigraphStore(raw)
    points = seed(raw, 3)
    default_before = st.count_default_graph_triples()
    mirror = Mirror()
    rc = derive_runner.run("synthetic_owner", Gateway(st, points), st,
                           PyShaclValidator(), mirror, status_path, now=NOW)
    check(rc == 0, f"runner exit 0 (got {rc})")
    n = node_count(st)
    check(n >= 2, f"{n} pwg:DerivedPreference node(s) in <{DERIVED_GRAPH}> (want genre + director)")
    labels = {r["l"]["value"] for r in st._select(
        "SELECT ?l WHERE { GRAPH <%s> { ?n a <%sDerivedPreference> ; <%slabel> ?l } }"
        % (DERIVED_GRAPH, PWG_NS, RDFS_NS))}
    check(GENRE in labels and DIRECTOR in labels, f"labels derived: {sorted(labels)}")
    froms = st._select(
        "SELECT ?f WHERE { GRAPH <%s> { ?n <%sderivedFrom> ?f } }" % (DERIVED_GRAPH, PWG_NS))
    check(froms and all(r["f"]["value"].startswith("urn:ostler:preference:") for r in froms),
          f"every pwg:derivedFrom points at a literal item ({len(froms)} links)")
    check(st.count_default_graph_triples() == default_before,
          "default graph untouched (literal data not modified)")
    s = status_of(status_path)
    check(s.get("outcome") == "written" and s.get("graph_node_count") == n,
          f"status outcome=written graph_node_count={s.get('graph_node_count')}")
    blob = status_path.read_text()
    check(GENRE not in blob and DIRECTOR not in blob and "Synthetic Film" not in blob,
          "status file carries counts only, no preference label or title")
    check(mirror.points is not None and len(mirror.points) == n,
          "mirror replaced with exactly the derived set")
    snapshot = st.graph_triples_turtle(DERIVED_GRAPH)

    print("arm 2: a failed reader writes nothing and keeps the prior graph")
    rc = derive_runner.run("synthetic_owner", Gateway(st, points, fail_scroll=True), st,
                           PyShaclValidator(), Mirror(), status_path, now=NOW)
    check(rc == 1, f"runner exit 1 (got {rc})")
    check(st.graph_triples_turtle(DERIVED_GRAPH) == snapshot, "prior derived graph unchanged")
    s = status_of(status_path)
    check(s.get("outcome") == "not_written" and s.get("readers_failed", 0) > 0,
          f"status outcome={s.get('outcome')} readers_failed={s.get('readers_failed')}")
    check(s.get("graph_node_count") == n, "status still reports the surviving node count")

    print("arm 3: a SHACL rejection writes nothing and keeps the prior graph")
    rc = derive_runner.run("synthetic_owner", Gateway(st, points), st,
                           RejectingValidator(), Mirror(), status_path, now=NOW)
    check(rc == 1, f"runner exit 1 (got {rc})")
    check(st.graph_triples_turtle(DERIVED_GRAPH) == snapshot, "prior derived graph unchanged")
    leftovers = st._select("SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }")
    check(all("/tmp-" not in r["g"]["value"] for r in leftovers), "no temp graph left behind")

    print("arm 4: RED CONTROL -- under the evidence floor, the graph is present and empty")
    raw2 = Store()
    st2 = OxigraphStore(raw2)
    points2 = seed(raw2, 1)
    rc = derive_runner.run("synthetic_owner", Gateway(st2, points2), st2,
                           PyShaclValidator(), Mirror(), status_path, now=NOW)
    check(rc == 0, f"runner exit 0 on a proven-empty run (got {rc})")
    check(st2.count_graph_triples(DERIVED_GRAPH) > 0, "graph PRESENT (run marker written)")
    check(node_count(st2) == 0, "but 0 pwg:DerivedPreference nodes: the count measures nodes")
    check(status_of(status_path).get("outcome") == "empty", "status outcome=empty")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
