"""Read derived affinities from the derived named graph (Chunk 4/5).

New read path; it NEVER repurposes the existing services/query methods and only
ever names the derived graph, so literal reads are unaffected. Feeds both the
DerivedAffinityScorer and the /api/v1/preferences/derived endpoint.
"""

from __future__ import annotations

from typing import Callable, List, Optional

from .consume import AffinityView
from .model import DERIVED_GRAPH, ENRICH_NS, PWG_NS

_MATCHED_TITLE = ENRICH_NS + "matchedTitle"


class DerivedGraphReader:
    """Wraps a SPARQL-select callable (bindings list) over the store."""

    def __init__(self, sparql: Callable[[str], list], derived_graph: str = DERIVED_GRAPH):
        self._sparql = sparql
        self._graph = derived_graph

    def get_derived_preferences(
        self,
        user_id: str,
        dimension: Optional[str] = None,
        min_confidence: float = 0.35,
        limit: int = 50,
        with_evidence: bool = True,
    ) -> List[AffinityView]:
        dim_filter = ""
        if dimension:
            dim_filter = f'    ?s pwg:dimension "{dimension}" .\n'
        q = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?s ?dimension ?subject ?strength ?confidence ?intensity WHERE {\n"
            f"  GRAPH <{self._graph}> {{\n"
            "    ?s a pwg:DerivedPreference ;\n"
            "       pwg:dimension ?dimension ;\n"
            "       pwg:subject ?subject ;\n"
            "       pwg:preferenceStrength ?strength ;\n"
            "       pwg:confidence ?confidence .\n"
            f'    ?s pwg:belongsToUser <{PWG_NS}user_{user_id}> .\n'
            "    OPTIONAL { ?s pwg:intensityTier ?intensity }\n"
            f"{dim_filter}"
            f"    FILTER(?confidence >= {min_confidence})\n"
            "  }\n"
            "} ORDER BY DESC(?confidence) DESC(?strength)\n"
            f"LIMIT {int(limit)}"
        )
        views: List[AffinityView] = []
        for b in self._sparql(q):
            subj = b["s"]["value"]
            because = self._evidence_titles(subj) if with_evidence else ()
            views.append(
                AffinityView(
                    dimension=b["dimension"]["value"],
                    subject=b["subject"]["value"],
                    strength=float(b["strength"]["value"]),
                    confidence=float(b["confidence"]["value"]),
                    intensity=b.get("intensity", {}).get("value", "casual"),
                    because=because,
                )
            )
        return views

    def _evidence_titles(self, node_uri: str, limit: int = 3) -> tuple:
        """Titles behind a node: its own pwg:evidenceTitle first (written by the
        engine, works for every source), else the overlay's matchedTitle for the
        derivedFrom URIs (default graph), best-effort. Empty tuple when none."""
        own = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?title WHERE {\n"
            f"  GRAPH <{self._graph}> {{ <{node_uri}> pwg:evidenceTitle ?title . }}\n"
            f"}} ORDER BY ?title LIMIT {int(limit)}"
        )
        try:
            titles = [b["title"]["value"] for b in self._sparql(own) if b.get("title", {}).get("value")]
        except Exception:
            titles = []
        if titles:
            return tuple(titles)
        q = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?title WHERE {\n"
            f"  GRAPH <{self._graph}> {{ <{node_uri}> pwg:derivedFrom ?e . }}\n"
            f"  OPTIONAL {{ ?e <{_MATCHED_TITLE}> ?title }}\n"
            f"}} LIMIT {int(limit)}"
        )
        titles = []
        try:
            for b in self._sparql(q):
                t = b.get("title", {}).get("value")
                if t:
                    titles.append(t)
        except Exception:
            return ()
        return tuple(titles)
