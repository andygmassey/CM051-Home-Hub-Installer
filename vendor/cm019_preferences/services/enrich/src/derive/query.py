"""Read derived affinities from the derived named graph (Chunk 4/5).

New read path; it NEVER repurposes the existing services/query methods and only
ever names the derived graph, so literal reads are unaffected. Feeds both the
DerivedAffinityScorer and the /api/v1/preferences/derived endpoint.
"""

from __future__ import annotations

from typing import Callable, List, Optional

from dataclasses import replace

from .consume import AffinityView, interleave_by_category
from .model import DERIVED_GRAPH, ENRICH_NS, PWG_NS
from .sensitive import derived_value_is_sensitive, is_sensitive, never_read_categories

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
            "SELECT ?s ?dimension ?subject ?strength ?confidence ?intensity ?category ?tier ?privacy ?trend ?cwin ?creason ?csup ?ctx WHERE {\n"
            f"  GRAPH <{self._graph}> {{\n"
            "    ?s a pwg:DerivedPreference ;\n"
            "       pwg:dimension ?dimension ;\n"
            "       pwg:subject ?subject ;\n"
            "       pwg:preferenceStrength ?strength ;\n"
            "       pwg:confidence ?confidence .\n"
            f'    ?s pwg:belongsToUser <{PWG_NS}user_{user_id}> .\n'
            "    OPTIONAL { ?s pwg:intensityTier ?intensity }\n"
            "    OPTIONAL { ?s pwg:category ?category }\n"
            "    OPTIONAL { ?s pwg:tier ?tier }\n"
            "    OPTIONAL { ?s pwg:privacyLevel ?privacy }\n"
            "    OPTIONAL { ?s pwg:trend ?trend }\n"
            "    OPTIONAL { ?s pwg:contradictionWinner ?cwin }\n"
            "    OPTIONAL { ?s pwg:contradictionReason ?creason }\n"
            "    OPTIONAL { ?s pwg:suppressSuggestion ?csup }\n"
            "    OPTIONAL { ?s pwg:timeContext ?ctx }\n"
            f"{dim_filter}"
            f"    FILTER(?confidence >= {min_confidence})\n"
            "  }\n"
            "} ORDER BY DESC(?confidence) DESC(?strength)\n"
            f"LIMIT {int(limit)}"
        )
        views: List[AffinityView] = []
        banned = set(never_read_categories())
        self.withheld_sensitive = 0
        for b in self._sparql(q):
            subj = b["s"]["value"]
            # READ-OUT GATE (defence in depth): a node written before the
            # write-side gate existed, or by any other writer, is still never
            # served if its label is sensitive or its category is never surfaced.
            category = b.get("category", {}).get("value", "")
            if (category.lower() in banned
                    or derived_value_is_sensitive(b["dimension"]["value"], b["subject"]["value"])):
                self.withheld_sensitive += 1
                continue
            because = self._evidence_titles(subj) if with_evidence else ()
            views.append(
                AffinityView(
                    dimension=b["dimension"]["value"],
                    subject=b["subject"]["value"],
                    strength=float(b["strength"]["value"]),
                    confidence=float(b["confidence"]["value"]),
                    intensity=b.get("intensity", {}).get("value", "casual"),
                    because=because,
                    category=category,
                    node=subj,
                    tier=b.get("tier", {}).get("value", ""),
                    privacy=b.get("privacy", {}).get("value", ""),
                    trend=b.get("trend", {}).get("value", ""),
                    contradiction_winner=b.get("cwin", {}).get("value", ""),
                    contradiction_reason=b.get("creason", {}).get("value", ""),
                    suppress=b.get("csup", {}).get("value", "") == "true",
                    context=tuple(
                        c for c in b.get("ctx", {}).get("value", "").split(",") if c),
                )
            )
        return views

    def get_mixed_preferences(
        self,
        user_id: str,
        min_confidence: float = 0.35,
        limit: int = 8,
        pool: int = 600,
        tier: str = "all",
    ) -> List[AffinityView]:
        """The top ``limit`` interleaved round-robin by category, within ``tier``
        (``broad``, ``specific`` or ``all``).

        Ranking by confidence alone lets one wide category (every TV series, every
        site) own the whole list. This reads a candidate pool WITHOUT evidence,
        interleaves it, and only then resolves the "because" titles for the few
        items kept.
        """
        ranked = self.get_derived_preferences(
            user_id, min_confidence=min_confidence, limit=max(pool, limit),
            with_evidence=False,
        )
        if tier != "all":
            # A node with no tier (a graph written before tiers) is "specific":
            # it is never a type, and the next derive run restamps it.
            ranked = [v for v in ranked if (v.tier or "specific") == tier]
        picked = interleave_by_category(ranked, limit)
        return [replace(v, because=self._evidence_titles(v.node)) for v in picked]

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
            return tuple(t for t in titles if not is_sensitive(t))
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
                if t and not is_sensitive(t):
                    titles.append(t)
        except Exception:
            return ()
        return tuple(titles)
