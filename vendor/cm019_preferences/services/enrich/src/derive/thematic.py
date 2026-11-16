"""Thematic rollup: specific topics roll up into broad themes (broad before specific).

A topic the enrichment attached to a preference ("psychology", "economics")
carries a Wikidata QID once the enricher's QID pass has run, and the topic
hierarchy graph holds that QID's broader concepts ("social science"). This
reader joins the three and emits one evidence item per (preference, broader
concept), so the ordinary Aggregator turns "a book on psychology" plus "a
podcast on economics" into a broad ``theme.concept`` node "social science"
with both as derivedFrom evidence. Ported from PWG #413 (Chunk 9), rebuilt as a
Reader so every gate the engine already runs applies to it unchanged.

THE JOIN, as the stores actually hold it:

    ?pref  enr:hasTopic    ?topic            (enrichment overlay)
    ?topic enr:wikidataId  "Q9418"           (a STRING literal, the QID pass)
    BIND IRI(wd: + "Q9418") AS ?wd           (the bridge, at query time)
    GRAPH <hierarchy> { ?wd enr:broaderConcept ?broader }

``hierarchy.find_preferences_by_broader_concept`` used to join
``?pref pwg:hasWikidataTopic ?topic`` with ``?topic`` an entity IRI. Nothing
writes that shape for an enriched topic, so it returned a FALSE ZERO on real
data; it now uses :func:`bridge_query`. tests/derive/test_thematic_rollup.py
keeps the old template and proves it reads zero where this one reads rows.

GATES, in order:
  * no QIDs in the store (the QID pass is absent or never ran) or no hierarchy
    edges: no evidence, no error, and ``stats["status"]`` says which. A QID is
    never guessed or minted here.
  * a leaf topic that is sensitive (Art. 9, diet, minors) or an abstention value
    (alcohol, pork...) contributes nothing to ANY theme, so "beer" never
    surfaces as "beverage" and "diabetes" never as "disease";
  * a theme whose label is sensitive under the theme rule
    (``sensitive.derived_value_is_sensitive("theme.concept", ...)``) is withheld,
    and so is a theme with NO label (an unlabelled QID cannot be checked);
  * a preference about a minor, in a never-read category, or at privacy level L3
    is not evidence. L0-L2 is carried onto the evidence, so the theme node
    inherits the highest level of what it was built from;
  * a theme needs at least ``min_leaves`` distinct leaf topics: one topic under
    a broader name is a renamed topic, not a theme.
Every withheld row is counted in ``stats``, never a silent drop.

Local only: two SPARQL reads and one Qdrant scroll. No network call.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Set

from .model import ENRICH_NS, PREF_URN_PREFIX, EvidenceItem
from .readers import SCROLL_FIELDS, StoreGateway, _as_float, _not_minor, _parse_dt
from .sensitive import derived_value_is_sensitive, is_abstention_value, is_sensitive

RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
WD_ENTITY = "http://www.wikidata.org/entity/"
HIERARCHY_GRAPH = "https://schema.ostler.ai/enrichment/graph/hierarchy"
THEME_DIMENSION = "theme.concept"

_QID = re.compile(r"^Q[1-9][0-9]*$")

# Status codes (stable; the CLI prints them).
STATUS_OK = "ok"
STATUS_NO_QIDS = "degraded:no_topic_qids"          # QID pass absent or never ran
STATUS_NO_HIERARCHY = "degraded:no_hierarchy_edges"  # QIDs, but no broader concepts stored
STATUS_NOT_RUN = "not_run"

# Canonical privacy levels a theme may be built from. L3 (body-private,
# index-only) never feeds a surfaced node.
_ADMITTED_LEVELS = frozenset({"L0", "L1", "L2"})
# Legacy compartment 5 is written by the notes and health producers meaning
# "highest privacy" (see src/privacy_gate.py), so it is read as L3 here.
_LEGACY_BLOCKED = frozenset({"5", "l5commercial"})


def _topic_triple(var_pref: str, var_topic: str, graph_var: str) -> str:
    """hasTopic in the default graph OR any named graph (the enricher writes the
    default graph; older stores and tests used named graphs)."""
    return (
        f"  {{ {var_pref} enr:hasTopic {var_topic} }} UNION "
        f"{{ GRAPH {graph_var} {{ {var_pref} enr:hasTopic {var_topic} }} }}\n"
    )


def _qid_triple(var_topic: str, graph_var: str) -> str:
    return (
        f"  {{ {var_topic} enr:wikidataId ?qid }} UNION "
        f"{{ GRAPH {graph_var} {{ {var_topic} enr:wikidataId ?qid }} }}\n"
        '  FILTER(REGEX(STR(?qid), "^Q[1-9][0-9]*$"))\n'
    )


def bridge_query(hierarchy_graph: str = HIERARCHY_GRAPH,
                 target_qid: Optional[str] = None,
                 with_title: bool = False) -> str:
    """The real-shape thematic join: pref -> topic -> QID string -> wd: IRI ->
    broader concept in the hierarchy graph. ``target_qid`` scopes it to one
    broader concept (the hierarchy service's lookup); ``with_title`` adds the
    overlay's matched title as ?title."""
    if target_qid is not None and not _QID.match(target_qid):
        raise ValueError(f"not a Wikidata QID: {target_qid!r}")
    target = (f"  FILTER(?broader = <{WD_ENTITY}{target_qid}>)\n" if target_qid else "")
    title = ("  OPTIONAL { ?pref enr:matchedTitle ?title }\n" if with_title else "")
    return (
        f"PREFIX enr: <{ENRICH_NS}>\n"
        f"PREFIX rdfs: <{RDFS_NS}>\n"
        "SELECT DISTINCT ?pref ?topic ?topicLabel ?qid ?broader ?broaderLabel"
        + (" ?title" if with_title else "") + " WHERE {\n"
        + _topic_triple("?pref", "?topic", "?g1")
        + _qid_triple("?topic", "?g2")
        + f'  BIND(IRI(CONCAT("{WD_ENTITY}", STR(?qid))) AS ?wd)\n'
        f"  GRAPH <{hierarchy_graph}> {{\n"
        "    ?wd enr:broaderConcept ?broader .\n"
        "    OPTIONAL { ?broader rdfs:label ?broaderLabel }\n"
        "  }\n"
        "  OPTIONAL { { ?topic rdfs:label ?topicLabel } UNION "
        "{ GRAPH ?g3 { ?topic rdfs:label ?topicLabel } } }\n"
        f"{title}"
        f"{target}"
        "}"
    )


def qid_count_query() -> str:
    """How many topic nodes carry a QID at all: tells "the QID pass never ran"
    apart from "it ran and nothing has a broader concept"."""
    return (
        f"PREFIX enr: <{ENRICH_NS}>\n"
        "SELECT (COUNT(DISTINCT ?topic) AS ?n) WHERE {\n"
        + _qid_triple("?topic", "?g2")
        + "}"
    )


def legacy_broken_query(target_qid: str, hierarchy_graph: str = HIERARCHY_GRAPH) -> str:
    """The join ``find_preferences_by_broader_concept`` shipped with. Kept ONLY so
    a test can show it returns a false zero on the shape the stores hold."""
    return (
        "PREFIX wd: <http://www.wikidata.org/entity/>\n"
        f"PREFIX pwg: <{ENRICH_NS}>\n"
        "SELECT DISTINCT ?pref ?name WHERE {\n"
        f"  GRAPH <{hierarchy_graph}> {{ ?topic pwg:broaderConcept wd:{target_qid} . }}\n"
        "  ?pref pwg:hasWikidataTopic ?topic .\n"
        "  ?pref pwg:name ?name .\n"
        "}"
    )


def _val(b: dict, k: str) -> str:
    v = b.get(k)
    return str(v.get("value", "")).strip() if isinstance(v, dict) else ""


def leaf_is_sensitive(label: str) -> bool:
    """A leaf topic that may never feed a theme: sensitive or an abstention value."""
    return is_sensitive(label) or is_abstention_value(label)


def privacy_of(payload: dict) -> Optional[str]:
    """The level to carry onto evidence, "" when unstated, None when the point
    must not feed a surfaced theme (L3, or the legacy highest-privacy 5)."""
    raw = payload.get("privacy_level")
    if raw is not None and str(raw).strip():
        level = str(raw).strip().upper()
        if level not in _ADMITTED_LEVELS:
            return None         # L3, or a value we cannot read: fail closed
        lvl = level
    else:
        lvl = ""
    legacy = payload.get("compartment_level")
    if legacy is not None and str(legacy).strip().lower().rsplit("#", 1)[-1] in _LEGACY_BLOCKED:
        return None
    return lvl


@dataclass
class ThematicReader:
    """Reader kind ``thematic`` (readers.yaml). See the module docstring."""

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]
    hierarchy_graph: str = HIERARCHY_GRAPH
    min_leaves: int = 2
    evidence_confidence: float = 0.5
    stats: Dict[str, object] = field(default_factory=dict)

    def _reset(self) -> None:
        self.stats = {
            "status": STATUS_NOT_RUN,
            "topics_with_qid": 0,
            "bridge_rows": 0,
            "withheld_sensitive_leaf": 0,
            "withheld_sensitive_theme": 0,
            "withheld_unlabelled_theme": 0,
            "withheld_private": 0,
            "withheld_few_leaves": 0,
            "evidence": 0,
        }

    def _count_qids(self) -> int:
        rows = list(self.gateway.sparql(qid_count_query()))
        if not rows:
            return 0
        try:
            return int(float(_val(rows[0], "n") or 0))
        except ValueError:
            return 0

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        self._reset()
        self.stats["topics_with_qid"] = n_qid = self._count_qids()
        if n_qid == 0:
            # The enricher's QID pass is absent or has not run on this store:
            # nothing to roll up. Degrade, say so, never guess a QID.
            self.stats["status"] = STATUS_NO_QIDS
            return []
        rows = list(self.gateway.sparql(bridge_query(self.hierarchy_graph)))
        self.stats["bridge_rows"] = len(rows)
        if not rows:
            self.stats["status"] = STATUS_NO_HIERARCHY
            return []
        self.stats["status"] = STATUS_OK

        # Which preferences may feed a theme at all: not about a minor, not in a
        # never-read category, not L3. Read BEFORE grouping, so a theme's leaf
        # count is counted over admitted evidence only.
        candidates = {_val(b, "pref")[len(PREF_URN_PREFIX):] for b in rows
                      if _val(b, "pref").startswith(PREF_URN_PREFIX)}
        admitted: Dict[str, tuple] = {}
        for p in _not_minor(self.gateway.scroll(self.select_categories, SCROLL_FIELDS)):
            pid = str(p.get("id"))
            if pid not in candidates:
                continue
            pl = p.get("payload") or {}
            level = privacy_of(pl)
            if level is None:
                self.stats["withheld_private"] += 1
                continue
            admitted[pid] = (pl, level)

        # theme IRI -> {"label", "leaves": set, "prefs": {pref_id: set(leaves)}}
        themes: Dict[str, dict] = {}
        dropped_leaf: Set[tuple] = set()
        for b in rows:
            pref = _val(b, "pref")
            broader = _val(b, "broader")
            if not pref.startswith(PREF_URN_PREFIX) or not broader.startswith(WD_ENTITY):
                continue
            pid = pref[len(PREF_URN_PREFIX):]
            if pid not in admitted:
                continue
            leaf = _val(b, "topicLabel") or _val(b, "topic")
            if leaf_is_sensitive(leaf):
                key = (pid, leaf)
                if key not in dropped_leaf:
                    dropped_leaf.add(key)
                    self.stats["withheld_sensitive_leaf"] += 1
                continue
            t = themes.setdefault(broader, {"label": "", "leaves": set(), "prefs": set()})
            label = _val(b, "broaderLabel")
            if label and (not t["label"] or label < t["label"]):
                t["label"] = label      # deterministic when a concept has two labels
            t["leaves"].add(leaf.lower())
            t["prefs"].add(pid)

        out: List[EvidenceItem] = []
        for iri, t in sorted(themes.items()):
            if not t["label"]:
                # An unlabelled concept cannot be checked by the sensitive gate.
                self.stats["withheld_unlabelled_theme"] += 1
                continue
            if derived_value_is_sensitive(self.dimension, t["label"]):
                self.stats["withheld_sensitive_theme"] += 1
                continue
            if len(t["leaves"]) < self.min_leaves:
                self.stats["withheld_few_leaves"] += 1
                continue
            qid = iri[len(WD_ENTITY):]
            for pid in sorted(t["prefs"]):
                pl, level = admitted[pid]
                out.append(EvidenceItem(
                    preference_id=pid,
                    user_id=user_id,
                    domain=self.domain,
                    dimension=self.dimension,
                    value=t["label"],
                    value_qid=qid,
                    item_strength=_as_float(pl.get("strength"), 0.0),
                    polarity_source="behavioral",
                    source=pl.get("source") or "",
                    observed_at=_parse_dt(pl.get("observed_at")),
                    enrichment_confidence=self.evidence_confidence,
                    raw_subject=pl.get("subject") or "",
                    privacy_level=level,
                ))
        self.stats["evidence"] = len(out)
        return out
