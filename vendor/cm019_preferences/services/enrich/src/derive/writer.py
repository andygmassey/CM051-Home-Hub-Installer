"""Materialize derived nodes into a dedicated, regenerable named graph (Chunk 3).

Non-corruption is structural, not hopeful:
- Derived RDF lives ONLY in its own named graph (DERIVED_GRAPH). No existing
  query names that graph, so literal reads are byte-identical before/after.
- The build goes into a TEMP graph, is SHACL-validated, and only then atomically
  swapped into place (DROP live + MOVE temp -> live). A SHACL failure discards
  the temp graph and leaves the live graph untouched.
- The Qdrant mirror uses source="inferred" and integer ids from
  generate_preference_id("derived", ...); literal points (UUID ids) are never
  read-modified-written.
- Re-running yields an identical node set (deterministic URIs) = idempotent.
"""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List, Optional, Protocol, Sequence

from .model import (
    DERIVED_COLLECTION,
    DERIVED_GRAPH,
    LITERAL_COLLECTION,
    PWG_NS,
    RDFS_NS,
    XSD_NS,
    DerivedPreference,
)

_PREFIXES = (
    f"PREFIX pwg: <{PWG_NS}>\n"
    f"PREFIX rdfs: <{RDFS_NS}>\n"
    f"PREFIX xsd: <{XSD_NS}>\n"
)


def generate_preference_id(source: str, subject: str) -> int:
    """Stable integer id for the Qdrant mirror (mirrors the geo precedent).

    Literal points carry UUID-string ids, so an integer id can never collide
    with a literal one.
    """
    raw = f"{source}:{subject}"
    return int(hashlib.md5(raw.encode()).hexdigest()[:16], 16)


class GraphStore(Protocol):
    def update(self, sparql_update: str) -> None: ...
    def graph_triples_turtle(self, graph_iri: str) -> str: ...
    def count_default_graph_triples(self) -> int: ...
    def count_graph_triples(self, graph_iri: str) -> int: ...


class QdrantMirror(Protocol):
    def replace_all(self, points: List[dict]) -> None:
        """WHOLESALE replace the derived mirror with exactly ``points``.

        Must be a replace, not an upsert: a stale inferred pref that is no longer
        derived MUST disappear from the mirror (and therefore from chat/search),
        otherwise removed tastes live forever. An empty ``points`` clears it.
        """
        ...


class SHACLValidator(Protocol):
    def validate_turtle(self, data_ttl: str) -> tuple: ...  # (conforms, text)


@dataclass
class WriteResult:
    node_count: int
    derived_graph: str
    default_triples_before: int
    default_triples_after: int
    mirror_points: int

    @property
    def literals_untouched(self) -> bool:
        return self.default_triples_before == self.default_triples_after


class DerivedGraphWriter:
    def __init__(
        self,
        store: GraphStore,
        validator: SHACLValidator,
        mirror: Optional[QdrantMirror] = None,
        derived_graph: str = DERIVED_GRAPH,
    ):
        self._store = store
        self._validator = validator
        self._mirror = mirror
        self._graph = derived_graph

    def _nodes_turtle(self, nodes: Sequence[DerivedPreference]) -> str:
        body = "\n".join(n.to_turtle(with_prefixes=False) for n in nodes)
        return _PREFIXES + "\n" + body

    def _run_marker_turtle(self, user_id: str, count: int, now: datetime) -> str:
        """A pwg:DerivationRun marker so the live graph is PRESENT even on an
        empty run. It is NOT a pwg:DerivedPreference, so consumers' node queries
        ignore it; it only makes the three states distinguishable:
          ABSENT  (never ran)      = no live graph, no marker
          EMPTY   (ran, nothing)   = live graph present + marker, count 0
          FAILED  (reader error)   = swap aborted, PRIOR graph kept
        CM044's wiki detects presence via `GRAPH ?g {}`, which only matches a
        graph that holds >= 1 triple, so the marker is what carries 'present'.
        """
        uri = f"urn:ostler:derivationRun:{user_id}"
        return (
            f"<{uri}> a pwg:DerivationRun ;\n"
            f'    pwg:derivedAt "{now.isoformat()}"^^xsd:dateTime ;\n'
            f"    pwg:count {int(count)} ."
        )

    def write(
        self,
        nodes: Sequence[DerivedPreference],
        proven_empty: bool = False,
        user_id: Optional[str] = None,
        now: Optional[datetime] = None,
    ) -> WriteResult:
        """Materialize ``nodes`` with a non-destructive atomic swap.

        WIPE-ON-EMPTY GUARD (data-loss fix): an empty ``nodes`` set is only ever
        allowed to clear the live graph when the caller PROVES the emptiness is
        genuine (``proven_empty=True``, i.e. every reader read successfully and
        found nothing). An empty set with ``proven_empty=False`` is treated as a
        possible reader failure and ABORTS: the live derived graph and its mirror
        are left exactly as they were. There is no code path that swaps an empty
        temp graph over live data by accident.

        Both paths build into a TEMP graph that ALWAYS carries a DerivationRun
        marker, then atomically swap, so an empty run leaves an empty-but-PRESENT
        graph (distinguishable from absent) and the swap is never a bare DROP.
        """
        if not nodes and not proven_empty:
            # Refuse: a degraded-to-empty read must never wipe the graph.
            raise RuntimeError(
                "refusing to swap to an EMPTY derived graph: the read was not "
                "proven empty (a reader may have failed). Live graph + mirror "
                "left untouched. Re-run once the readers succeed, or pass "
                "proven_empty=True only when every reader genuinely returned "
                "zero evidence."
            )

        now = now or datetime.now(timezone.utc)
        uid = user_id or (nodes[0].user_id if nodes else "owner")
        before = self._store.count_default_graph_triples()
        temp_graph = f"{self._graph}/tmp-{uuid.uuid4().hex}"

        # 1. build into the TEMP graph: the run marker ALWAYS, plus the nodes.
        #    If the store is unreachable/401 this raises here, BEFORE any DROP,
        #    so an outage can never wipe live data.
        body = self._run_marker_turtle(uid, len(nodes), now)
        if nodes:
            body += "\n" + "\n".join(n.to_turtle(with_prefixes=False) for n in nodes)
        self._store.update(
            f"{_PREFIXES}\nINSERT DATA {{ GRAPH <{temp_graph}> {{\n{body}\n}} }}"
        )

        # 2. SHACL-gate the derived NODES (the marker is not a DerivedPreference);
        #    abort (discard temp) on any violation, live graph untouched.
        if nodes:
            conforms, text = self._validator.validate_turtle(self._nodes_turtle(nodes))
            if not conforms:
                self._store.update(f"DROP SILENT GRAPH <{temp_graph}>")
                raise ValueError(f"SHACL validation failed; live graph untouched:\n{text}")

        # 3. atomic swap: drop live, move temp into place
        self._store.update(
            f"DROP SILENT GRAPH <{self._graph}> ;\n"
            f"MOVE SILENT GRAPH <{temp_graph}> TO <{self._graph}>"
        )

        # 4. Qdrant mirror: WHOLESALE replace (not upsert) so stale inferred
        #    prefs disappear, into the SEPARATE derived collection (never the
        #    literal one). Runs only after the graph swap succeeds. Empty nodes
        #    -> replace_all([]) clears the mirror.
        mirror_points = 0
        if self._mirror is not None:
            points = [self._mirror_point(n) for n in nodes]
            self._mirror.replace_all(points)
            mirror_points = len(points)

        after = self._store.count_default_graph_triples()
        return WriteResult(
            node_count=len(nodes),
            derived_graph=self._graph,
            default_triples_before=before,
            default_triples_after=after,
            mirror_points=mirror_points,
        )

    def _mirror_point(self, node: DerivedPreference) -> dict:
        pid = generate_preference_id("derived", f"{node.dimension}|{node.subject}")
        return {
            "id": pid,
            "payload": {
                "preference_id": node.uri,
                "subject": node.subject,
                "dimension": node.dimension,
                "category": node.category,
                "source": "inferred",
                "strength": node.preference_strength,
                "confidence": node.confidence,
                "intensity": node.intensity_tier,
                "derivation_version": node.derivation_version,
                "privacy_level": node.privacy_level,
            },
        }


# --- Real implementations for the CLI --------------------------------------
@dataclass
class HttpGraphStore:
    oxigraph_url: str = "http://localhost:7878"

    def update(self, sparql_update: str) -> None:
        import urllib.request
        req = urllib.request.Request(
            self.oxigraph_url + "/update",
            data=sparql_update.encode(),
            headers={"Content-Type": "application/sparql-update"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            r.read()

    def _select(self, query: str):
        import json
        import urllib.parse
        import urllib.request
        req = urllib.request.Request(
            self.oxigraph_url + "/query?query=" + urllib.parse.quote(query),
            headers={"Accept": "application/sparql-results+json"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)["results"]["bindings"]

    def count_default_graph_triples(self) -> int:
        b = self._select("SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")
        return int(b[0]["c"]["value"])

    def count_graph_triples(self, graph_iri: str) -> int:
        b = self._select("SELECT (COUNT(*) AS ?c) WHERE { GRAPH <%s> { ?s ?p ?o } }" % graph_iri)
        return int(b[0]["c"]["value"])

    def graph_triples_turtle(self, graph_iri: str) -> str:
        import json
        import urllib.parse
        import urllib.request
        q = "CONSTRUCT { ?s ?p ?o } WHERE { GRAPH <%s> { ?s ?p ?o } }" % graph_iri
        req = urllib.request.Request(
            self.oxigraph_url + "/query?query=" + urllib.parse.quote(q),
            headers={"Accept": "text/turtle"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return r.read().decode()


@dataclass
class QdrantDerivedMirror:
    """Real mirror: a SEPARATE Qdrant collection for derived (inferred) prefs.

    Three invariants, one per bug the writer was bounced for:
    - SEPARATE COLLECTION: it refuses to target the literal ``preferences``
      collection, so an inferred pref can never be read back as a literal like.
    - WHOLESALE REPLACE: ``replace_all`` clears the collection then writes the
      current set, so a pref that is no longer derived vanishes from the mirror
      (no upsert-only staleness).
    - PAYLOAD-ONLY: a tiny constant vector is used; the mirror is a filterable
      key/value store for consumers, not a semantic index, so no embedding model
      is pulled onto the write path.

    Runs under the hub interpreter, where the store-auth .pth shim attaches the
    Qdrant api-key to loopback:6333 automatically (confirmed in the shim's
    urllib arm), so ``qdrant_url`` is the authenticated path on enforce-ON boxes.
    """

    qdrant_url: str = "http://localhost:6333"
    collection: str = DERIVED_COLLECTION
    vector_size: int = 1

    def __post_init__(self):
        if self.collection == LITERAL_COLLECTION:
            # Loud refusal: writing derived points into the literal collection is
            # the double-count bug. Never silent.
            raise ValueError(
                f"QdrantDerivedMirror refuses the literal collection "
                f"{LITERAL_COLLECTION!r}; derived prefs are strictly separate"
            )

    def _req(self, method: str, path: str, body: Optional[dict] = None):
        import json
        import urllib.request
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.qdrant_url + path,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)

    def _ensure_collection(self) -> None:
        import urllib.error
        try:
            self._req("GET", f"/collections/{self.collection}")
            return  # already exists
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        self._req(
            "PUT",
            f"/collections/{self.collection}",
            {"vectors": {"size": self.vector_size, "distance": "Dot"}},
        )

    def replace_all(self, points: List[dict]) -> None:
        self._ensure_collection()
        # Clear the whole collection (delete by match-all filter), then write the
        # current set. This is the wholesale replace: stale points cannot survive.
        self._req(
            "POST",
            f"/collections/{self.collection}/points/delete?wait=true",
            {"filter": {}},
        )
        if not points:
            return
        vec = [0.0] * self.vector_size
        upsert = {
            "points": [
                {"id": p["id"], "vector": vec, "payload": p["payload"]}
                for p in points
            ]
        }
        self._req(
            "PUT",
            f"/collections/{self.collection}/points?wait=true",
            upsert,
        )
