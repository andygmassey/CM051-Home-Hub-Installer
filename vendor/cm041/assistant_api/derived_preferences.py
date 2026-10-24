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

from dataclasses import dataclass, replace
from datetime import datetime, timezone
from typing import Callable, List, Optional, Tuple

CONTRACT_VERSION = "derived-preferences.v1"

# --- Namespaces + graph (mirrors CM019 derive/model.py, Chunk 1) ------------
PWG_NS = "https://schema.ostler.ai/ontology#"
ENRICH_NS = "https://schema.ostler.ai/enrichment/ontology#"
# The levels a derived node may carry and still be served. L3 is never served and
# neither is a level that is present but not one of these (pwg_privacy doctrine:
# an unparseable level fails closed). A node with NO level is served: it is
# behavioural evidence, or a graph written before CM019 #423.
SERVED_PRIVACY_LEVELS = ("L0", "L1", "L2")
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
    category: str = ""   # films / tv / music / ...; "" when the store did not say
    node: str = ""       # the derived node's URI, to resolve "because" later
    tier: str = ""       # "broad" | "specific"; "" for graphs written before tiers
    privacy: str = ""    # highest privacy level of the evidence (CM019 #423); "" = none stated


def interleave_by_category(views, limit: int) -> list:
    """Round-robin a ranked list by category, so one category cannot own the top-N.

    Round 1 takes each category's best item, round 2 each category's second, and
    so on. Inside a round the items are ordered by confidence then strength;
    within a category the input order is kept (the input is already ranked). A
    category that runs out drops out of later rounds, so when the others are
    empty the one left still fills the list. Same function as CM019
    derive/consume.py (personal-world-graph #422).
    """
    by_cat: dict = {}
    for v in views:
        by_cat.setdefault(v.category, []).append(v)
    # Inside a category a broad item leads a specific one (stable: confidence
    # order is kept within each tier).
    for items in by_cat.values():
        items.sort(key=lambda v: v.tier != "broad")
    out: list = []
    rnd = 0
    while len(out) < limit:
        this_round = [items[rnd] for items in by_cat.values() if len(items) > rnd]
        if not this_round:
            break
        # Types before things: inside a round a broad item leads a specific one.
        this_round.sort(key=lambda v: (v.tier != "broad", -v.confidence, -v.strength))
        out.extend(this_round[: limit - len(out)])
        rnd += 1
    return out


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
        served = ", ".join(f'"{lvl}"' for lvl in SERVED_PRIVACY_LEVELS)
        q = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?s ?dimension ?subject ?strength ?confidence ?intensity ?category ?tier ?privacy WHERE {\n"
            f"  GRAPH <{self._graph}> {{\n"
            "    ?s a pwg:DerivedPreference ;\n"
            "       pwg:dimension ?dimension ;\n"
            "       pwg:subject ?subject ;\n"
            "       pwg:preferenceStrength ?strength ;\n"
            "       pwg:confidence ?confidence .\n"
            "    OPTIONAL { ?s pwg:intensityTier ?intensity }\n"
            "    OPTIONAL { ?s pwg:category ?category }\n"
            "    OPTIONAL { ?s pwg:tier ?tier }\n"
            "    OPTIONAL { ?s pwg:privacyLevel ?privacy }\n"
            f"    FILTER(!BOUND(?privacy) || UCASE(STR(?privacy)) IN ({served}))\n"
            f"    FILTER(?confidence >= {float(min_confidence)})\n"
            "  }\n"
            "} ORDER BY DESC(?confidence) DESC(?strength)\n"
            f"LIMIT {int(limit)}"
        )
        views: List[AffinityView] = []
        for b in self._sparql(q):
            privacy = (b.get("privacy") or "").strip().upper()
            if privacy and privacy not in SERVED_PRIVACY_LEVELS:
                # Belt to the query's braces: never serve an L3 or unparseable row.
                continue
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
                    category=b.get("category") or "",
                    node=subj_uri or "",
                    tier=b.get("tier") or "",
                    privacy=privacy,
                )
            )
        return views

    def get_mixed_preferences(
        self,
        user_id: str,
        min_confidence: float = 0.4,
        limit: int = 8,
        pool: int = 600,
        tier: str = "all",
    ) -> List[AffinityView]:
        """The top ``limit`` interleaved round-robin by category.

        Ranked by confidence alone, one wide category (every TV series, every
        site) owns the whole list. Reads a candidate pool WITHOUT evidence,
        interleaves it, then resolves the "because" titles for the few kept.
        """
        ranked = self.get_derived_preferences(
            user_id, min_confidence=min_confidence, limit=max(pool, limit),
            with_evidence=False,
        )
        if tier != "all":
            # A node with no tier (a graph written before tiers) is "specific":
            # never a type; the next derive run restamps it.
            ranked = [v for v in ranked if (v.tier or "specific") == tier]
        picked = interleave_by_category(ranked, limit)
        return [replace(v, because=self._evidence_titles(v.node)) for v in picked]

    def _evidence_titles(self, node_uri: str, limit: int = 3) -> tuple:
        """Titles behind a node: its own pwg:evidenceTitle first (written by the
        CM019 engine, works for every source), else the overlay's matchedTitle for
        the derivedFrom evidence, best-effort. Empty tuple when none."""
        own = (
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?title WHERE {\n"
            f"  GRAPH <{self._graph}> {{ <{node_uri}> pwg:evidenceTitle ?title . }}\n"
            f"}} ORDER BY ?title LIMIT {int(limit)}"
        )
        try:
            own_titles = [b["title"] for b in self._sparql(own) if b.get("title")]
        except Exception:
            own_titles = []
        if own_titles:
            return tuple(own_titles)
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


# --- Response builder: from CM019 derive/endpoint.py (PR #410 + #422 mix) ----


def _now_iso(now: Optional[datetime]) -> str:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _item(view) -> dict:
    d = {
        "dimension": view.dimension,
        "label": view.subject,
        "strength": round(float(view.strength), 4),
        "confidence": round(float(view.confidence), 4),
        "intensity": view.intensity,
        "because": list(view.because),
    }
    # Only when the evidence carried a level: consumers apply their L2 handling
    # (same shape as CM019 derive/endpoint.py, PWG #423).
    if getattr(view, "privacy", ""):
        d["privacy_level"] = view.privacy
    return d


def build_derived_preferences_response(
    reader,
    user_id: str,
    limit: int = 8,
    min_confidence: float = 0.4,
    now: Optional[datetime] = None,
    tier: Optional[str] = None,
) -> dict:
    """Build the endpoint payload. Never raises; degrades loudly instead.

    ``tier``: ``broad`` (types of things: genres, cuisines, topics), ``specific``
    (single things) or ``all`` (every tier, broad first). The round-robin by
    category applies within the tier. A reader without ``get_mixed_preferences``
    ignores the tier and serves the plain ranked read.

    ``None`` means the caller did not ask: it reads ``broad``, and if that is
    EMPTY it serves ``all`` and says so (``"tier": "all", "tier_fallback": true``).
    An upgraded box holds a graph written before tiers until the next derive run;
    without the fallback the first look after an update would be empty. An
    EXPLICIT ``broad`` stays strict.
    """
    defaulted = tier is None
    tier = tier or "broad"
    ts = _now_iso(now)
    try:
        # Prefer the category-interleaved read: ranked by confidence alone, one
        # wide category (every TV series, every site) owns the whole list.
        mixed = getattr(reader, "get_mixed_preferences", None)
        if mixed is not None:
            views = mixed(user_id, min_confidence=min_confidence, limit=limit, tier=tier)
        else:
            views = reader.get_derived_preferences(
                user_id, min_confidence=min_confidence, limit=limit
            )
        fell_back = False
        if not views and defaulted and mixed is not None and tier == "broad":
            views = mixed(user_id, min_confidence=min_confidence, limit=limit, tier="all")
            fell_back = bool(views)
    except Exception as exc:  # dependency down: degrade, do not 200 []
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": f"derived graph unavailable: {type(exc).__name__}",
        }

    if not views:  # empty graph is NOT a healthy empty result
        reason = (
            "no derived preferences materialized yet"
            if tier == "all"
            else f"no derived preferences materialized yet in the {tier} tier (tier=all shows every tier)"
        )
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": reason,
        }

    out = {
        "generated_at": ts,
        "items": [_item(v) for v in views],
        "degraded": False,
    }
    if fell_back:
        out["tier"] = "all"
        out["tier_fallback"] = True
    return out
