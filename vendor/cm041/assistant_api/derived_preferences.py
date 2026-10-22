"""Producer for GET /api/v1/preferences/derived (PWG Chunk 5, hub side).

This is the shipped-hub binding of the derived-preference CONTRACT. The response
builder is lifted VERBATIM from the CM019 producer
(services/enrich/src/derive/endpoint.py, PR #410) so the hub cannot drift from
the shape the digest ("What you like", ostler-assistant #550) and the Rust
pwg_* tool were built against. The ONE shared fixture
(contract/derived_preferences_response.example.json, byte-identical in all three
repos) pins it; tests/test_derived_preferences_route.py drives this module and
goes red if the shape moves.

Data source: the dedicated, fully-regenerable derived named graph in Oxigraph
(materialized by the CM019 derivation engine). On a single-user hub that named
graph IS the owner's compartment, so the read is scoped by the graph name alone
and does NOT re-apply the CM048 user-graph UNION scoper (which would multiply
rows for an explicitly-named graph). The caller passes an UNSCOPED SELECT.

Silent-empty rule (checklist): a missing/empty/failed dependency MUST NOT return
`{"items": []}` as if it were a healthy empty result. Unavailable -> degraded
with cannot_check; empty -> degraded with a reason. Only a real, non-empty read
returns degraded=false.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, List, Optional, Tuple

CONTRACT_VERSION = "derived-preferences.v1"

# --- Namespaces + graph (mirrors CM019 derive/model.py, Chunk 1) ------------
PWG_NS = "https://schema.ostler.ai/ontology#"
ENRICH_NS = "https://schema.ostler.ai/enrichment/ontology#"
# Dedicated, fully-regenerable named graph for derived nodes.
DERIVED_GRAPH = "https://schema.ostler.ai/derived/graph/preferences"
_MATCHED_TITLE = ENRICH_NS + "matchedTitle"


@dataclass(frozen=True)
class AffinityView:
    """A derived affinity as a consumer sees it (CM019 derive/consume.py)."""

    dimension: str
    subject: str
    strength: float
    confidence: float
    intensity: str = "casual"
    because: Tuple[str, ...] = ()


class DerivedGraphReader:
    """Read derived affinities from the derived named graph.

    ``sparql`` is an UNSCOPED SELECT callable returning FLAT binding dicts
    ({var: value}), i.e. the hub's ``_sparql_select_unscoped`` shape. It is NOT
    the CM048-scoped reader: this graph is named explicitly and is the owner's
    compartment on a single-user hub, so scoping it through the user-graph UNION
    would double every row.
    """

    def __init__(self, sparql: Callable[[str], list], derived_graph: str = DERIVED_GRAPH):
        self._sparql = sparql
        self._graph = derived_graph

    def get_derived_preferences(
        self,
        user_id: str,
        min_confidence: float = 0.4,
        limit: int = 8,
        with_evidence: bool = True,
        **_kw,
    ) -> List[AffinityView]:
        q = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?s ?dimension ?subject ?strength ?confidence ?intensity WHERE {\n"
            f"  GRAPH <{self._graph}> {{\n"
            "    ?s a pwg:DerivedPreference ;\n"
            "       pwg:dimension ?dimension ;\n"
            "       pwg:subject ?subject ;\n"
            "       pwg:preferenceStrength ?strength ;\n"
            "       pwg:confidence ?confidence .\n"
            "    OPTIONAL { ?s pwg:intensityTier ?intensity }\n"
            f"    FILTER(?confidence >= {float(min_confidence)})\n"
            "  }\n"
            "} ORDER BY DESC(?confidence) DESC(?strength)\n"
            f"LIMIT {int(limit)}"
        )
        views: List[AffinityView] = []
        for b in self._sparql(q):
            subj_uri = b.get("s")
            because = (
                self._evidence_titles(subj_uri)
                if (with_evidence and subj_uri)
                else ()
            )
            views.append(
                AffinityView(
                    dimension=b.get("dimension", ""),
                    subject=b.get("subject", ""),
                    strength=float(b.get("strength", 0.0)),
                    confidence=float(b.get("confidence", 0.0)),
                    intensity=b.get("intensity") or "casual",
                    because=because,
                )
            )
        return views

    def _evidence_titles(self, node_uri: str, limit: int = 3) -> tuple:
        """Resolve derivedFrom evidence to human titles (matchedTitle),
        best-effort. Empty tuple when none."""
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
                t = b.get("title")
                if t:
                    titles.append(t)
        except Exception:
            return ()
        return tuple(titles)


# --- Response builder: VERBATIM from CM019 derive/endpoint.py (PR #410) ------


def _now_iso(now: Optional[datetime]) -> str:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _item(view) -> dict:
    return {
        "dimension": view.dimension,
        "label": view.subject,
        "strength": round(float(view.strength), 4),
        "confidence": round(float(view.confidence), 4),
        "intensity": view.intensity,
        "because": list(view.because),
    }


def build_derived_preferences_response(
    reader,
    user_id: str,
    limit: int = 8,
    min_confidence: float = 0.4,
    now: Optional[datetime] = None,
) -> dict:
    """Build the endpoint payload. Never raises; degrades loudly instead."""
    ts = _now_iso(now)
    try:
        views = reader.get_derived_preferences(
            user_id, min_confidence=min_confidence, limit=limit
        )
    except Exception as exc:  # dependency down: degrade, do not 200 []
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": f"derived graph unavailable: {type(exc).__name__}",
        }

    if not views:  # empty graph is NOT a healthy empty result
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": "no derived preferences materialized yet",
        }

    return {
        "generated_at": ts,
        "items": [_item(v) for v in views],
        "degraded": False,
    }
