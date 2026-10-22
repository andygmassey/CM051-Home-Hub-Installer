"""Built-in Reader kinds (Chunk 2).

Readers are the ONLY component that knows about stores, namespaces and domains.
They emit a stream of universal EvidenceItem records; everything downstream is
generic. Two kinds cover the film MVP:

- oxigraph_overlay: the abstract tag (genre/entity) lives in the Oxigraph
  enrichment overlay (enrichment/ontology#), and strength/source/recency are
  joined from the Qdrant payload by the point id (the Chunk 1 join key).
- qdrant_field: value and strength both come straight from a Qdrant payload field.

A StoreGateway abstracts the two stores so readers are unit-testable against a
fake. HttpStoreGateway is the real implementation used by the CLI.
"""

from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Protocol

import yaml

from .model import ENRICH_NS, PREF_URN_PREFIX, EvidenceItem

RDFS_LABEL = "http://www.w3.org/2000/01/rdf-schema#label"

# Every reader asks for the same payload fields, so the gateway can serve a
# repeated category set from one scroll instead of one per reader.
SCROLL_FIELDS = [
    "category", "preference_id", "subject", "source", "strength", "observed_at", "extra",
]


class StoreGateway(Protocol):
    def scroll(self, categories: List[str], fields: List[str]) -> List[dict]:
        """Return Qdrant points [{'id':..., 'payload': {...}}, ...]."""
        ...

    def sparql(self, query: str) -> List[dict]:
        """Return SPARQL SELECT bindings [{var: {'value':...}}, ...]."""
        ...


def _parse_dt(v) -> Optional[datetime]:
    """Parse to a tz-AWARE UTC datetime, always. Real payloads mix tz-aware
    ("...Z") and naive timestamps; returning a mix makes min()/max() crash, so
    naive values are coerced to UTC here at the single boundary."""
    dt = None
    if v is None:
        return None
    if isinstance(v, (int, float)):
        try:
            dt = datetime.fromtimestamp(float(v), tz=timezone.utc)
        except Exception:
            return None
    else:
        s = str(v).strip()
        if not s:
            return None
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        except Exception:
            return None
    if dt is not None and dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


_WS = re.compile(r"\s+")
_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*://")


def _domain(v: str) -> str:
    """Host of a URL or bare host: lowercase, no scheme, port, path or www."""
    s = _SCHEME.sub("", (v or "").strip().lower())
    s = s.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0].rsplit("@", 1)[-1]
    s = s.split(":", 1)[0]
    return s[4:] if s.startswith("www.") else s


def _allowlisted(value: str, allow) -> Optional[str]:
    """The allowlist entry this value is, or is a subdomain of, else None.

    news.bbc.co.uk and www.bbc.co.uk both answer to bbc.co.uk, so one publisher
    is one value.
    """
    for a in allow:
        if value == a or value.endswith("." + a):
            return a
    return None


_VOCAB_DIR = Path(__file__).resolve().parent / "vocab"
_VOCAB_CACHE: Dict[str, list] = {}


def load_vocab(name: str) -> list:
    """[(canonical label, compiled whole-word regex), ...] from vocab/<name>.yaml.

    The vocabularies are SHARED data: every reader of a dimension maps into the
    same labels, so evidence from different sources lands in one group.
    """
    if name not in _VOCAB_CACHE:
        rows = yaml.safe_load((_VOCAB_DIR / f"{name}.yaml").read_text()) or {}
        compiled = []
        for label, words in rows.items():
            alts = "|".join(re.escape(str(w).lower()) for w in words)
            compiled.append((str(label), re.compile(r"(?<![a-z0-9])(?:%s)(?![a-z0-9])" % alts)))
        _VOCAB_CACHE[name] = compiled
    return _VOCAB_CACHE[name]


def canonical_labels(text: str, vocab: Optional[str], strict: bool = False) -> List[str]:
    """Map a raw label onto the shared vocabulary.

    No vocabulary: the label as it is. With one: every canonical label whose
    keywords the text contains; nothing matched keeps the raw label unless
    ``strict`` (a venue type or a price facet is not a cuisine).
    """
    text = (text or "").strip()
    if not text:
        return []
    if not vocab:
        return [text]
    low = text.lower()
    hits = [label for label, rx in load_vocab(vocab) if rx.search(low)]
    if hits:
        return hits
    return [] if strict else [text]


def _as_float(v, default: float = 0.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


@dataclass
class OxigraphOverlayReader:
    """Tag in the RDF overlay, strength joined from Qdrant by point id."""

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]        # Qdrant categories to scan (films)
    tag_predicate: str                  # e.g. enrichment hasGenre / hasEntity
    tag_entity_type: Optional[str] = None  # for hasEntity: "director"/"actor"
    default_polarity: str = "behavioral"
    # Drop tags whose label matches this regex (case-insensitive). For
    # predicates that carry mixed facets, e.g. a place's topics hold cuisine
    # AND a "Price: $$" facet.
    value_exclude_regex: Optional[str] = None
    # Map each label onto a shared vocabulary (vocab/<name>.yaml); vocab_strict
    # drops labels that match nothing in it.
    vocab: Optional[str] = None
    vocab_strict: bool = False

    def _pred(self) -> str:
        return self.tag_predicate if self.tag_predicate.startswith("http") else ENRICH_NS + self.tag_predicate

    def _overlay_tags(self) -> Dict[str, List[dict]]:
        """pref_id -> [{'label':..., 'qid':.., 'conf':..}] from one SPARQL."""
        pred = self._pred()
        if self.tag_entity_type:
            etype = ENRICH_NS + "entityType"
            q = (
                "SELECT ?s ?e ?label ?conf WHERE { "
                "?s <%s> ?e . ?e <%s> ?label . ?e <%s> ?etype . "
                'FILTER(LCASE(STR(?etype)) = "%s") '
                "OPTIONAL { ?s <%senrichmentConfidence> ?conf } "
                "}" % (pred, RDFS_LABEL, etype, self.tag_entity_type.lower(), ENRICH_NS)
            )
        else:
            q = (
                "SELECT ?s ?g ?label ?conf WHERE { "
                "?s <%s> ?g . OPTIONAL { ?g <%s> ?label } "
                "OPTIONAL { ?s <%senrichmentConfidence> ?conf } "
                "}" % (pred, RDFS_LABEL, ENRICH_NS)
            )
        tags: Dict[str, List[dict]] = {}
        rows = list(self.gateway.sparql(q))
        # A tag node that carries two different labels names neither of them:
        # the enrichment mints a node's IRI from its normalised name, so names
        # that normalise to the same text (non-latin scripts, for one) share a
        # node and every label ever written piles onto it. Attributing all of
        # them to every preference that points at the node invents evidence.
        labels_by_node: Dict[str, set] = {}
        for b in rows:
            node = (b.get("g") or b.get("e") or {}).get("value")
            lab = b.get("label", {}).get("value")
            if node and lab:
                labels_by_node.setdefault(node, set()).add(lab.strip().lower())
        ambiguous = {n for n, labs in labels_by_node.items() if len(labs) > 1}
        exclude = re.compile(self.value_exclude_regex, re.I) if self.value_exclude_regex else None
        for b in rows:
            subj = b.get("s", {}).get("value", "")
            if not subj.startswith(PREF_URN_PREFIX):
                continue
            if (b.get("g") or b.get("e") or {}).get("value") in ambiguous:
                continue
            label = b.get("label", {}).get("value")
            if not label or (exclude and exclude.search(label)):
                continue
            pref_id = subj[len(PREF_URN_PREFIX):]
            conf = _as_float(b.get("conf", {}).get("value"), 0.5)
            for canon in canonical_labels(label, self.vocab, self.vocab_strict):
                tags.setdefault(pref_id, []).append({"label": canon, "conf": conf})
        return tags

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        tags_by_id = self._overlay_tags()
        points = self.gateway.scroll(
            self.select_categories,
            SCROLL_FIELDS,
        )
        for p in points:
            pid = str(p.get("id"))
            tags = tags_by_id.get(pid)
            if not tags:
                continue  # no overlay tag for this film -> no evidence here
            pl = p.get("payload", {})
            for tag in tags:
                yield EvidenceItem(
                    preference_id=pid,
                    user_id=user_id,
                    domain=self.domain,
                    dimension=self.dimension,
                    value=tag["label"],
                    value_qid=None,
                    item_strength=_as_float(pl.get("strength"), 0.0),
                    polarity_source=self.default_polarity,
                    source=pl.get("source") or "",
                    observed_at=_parse_dt(pl.get("observed_at")),
                    enrichment_confidence=tag["conf"],
                    raw_subject=pl.get("subject") or "",
                )


@dataclass
class QdrantFieldReader:
    """Value taken straight from a Qdrant payload field (or the subject).

    The value pipeline, every step optional and driven by readers.yaml:
    ``field_path`` (else ``fallback_field``) -> ``strip_regex`` removes noise
    -> ``split``/``part`` keeps one side of a delimiter ("Show - Episode" ->
    "Show") -> ``transform`` (``domain`` or ``lower``) -> ``allowlist`` keeps
    only listed values. One point yields at most one evidence item, so a
    dimension can never count a single preference twice.
    """

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]
    field_path: str                 # dotted, e.g. "extra.brand" or "subject"
    default_polarity: str = "behavioral"
    fallback_field: Optional[str] = None
    split: Optional[str] = None
    part: str = "first"             # "first" | "last"
    transform: Optional[str] = None  # None | "domain" | "lower"
    strip_regex: Optional[str] = None
    allowlist: tuple = ()
    evidence_confidence: float = 0.5

    def _dig(self, payload: dict, path: Optional[str] = None):
        cur = payload
        for part in (path or self.field_path).split("."):
            if not isinstance(cur, dict):
                return None
            cur = cur.get(part)
        return cur

    def _value(self, payload: dict) -> str:
        raw = self._dig(payload)
        if (raw is None or str(raw).strip() == "") and self.fallback_field:
            raw = self._dig(payload, self.fallback_field)
        if raw is None or isinstance(raw, (dict, list)):
            return ""
        v = str(raw)
        if self.strip_regex:
            v = re.sub(self.strip_regex, "", v, flags=re.I)
        if self.split and self.split in v:
            segs = v.split(self.split)
            v = segs[0] if self.part == "first" else segs[-1]
        if self.transform == "domain":
            v = _domain(v)
        elif self.transform == "lower":
            v = v.lower()
        v = _WS.sub(" ", v).strip()
        if len(v) < 2:
            return ""
        if self.allowlist:
            return _allowlisted(v.lower(), self.allowlist) or ""
        return v

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        points = self.gateway.scroll(self.select_categories, SCROLL_FIELDS)
        for p in points:
            pl = p.get("payload", {})
            value = self._value(pl)
            if not value:
                continue
            yield EvidenceItem(
                preference_id=str(p.get("id")),
                user_id=user_id,
                domain=self.domain,
                dimension=self.dimension,
                value=value,
                value_qid=None,
                item_strength=_as_float(pl.get("strength"), 0.0),
                polarity_source=self.default_polarity,
                source=pl.get("source") or "",
                observed_at=_parse_dt(pl.get("observed_at")),
                enrichment_confidence=self.evidence_confidence,
                raw_subject=pl.get("subject") or "",
            )


@dataclass
class RollupReader:
    """Roll a tag known for SOME of an item's siblings up to ALL of them.

    Most of the graph is not enriched (the enrichment reaches a few hundred
    points of a hundred thousand), but the items share a key: the tracks of one
    artist, the episodes of one series, the orders from one restaurant. When ANY
    point under a key carries an enrichment tag (a genre, a cuisine), every
    point under that key is evidence for it. So a settled broad group (a genre)
    is built from the specific items already known, not only from the few the
    enrichment has reached. Local only: it reads the same two stores as every
    other reader and makes no network call; the consent-gated enrichment tick is
    what fills the tags.

    ``key`` is a QdrantFieldReader (field, split, ...) that names the group;
    ``tags`` is an OxigraphOverlayReader that supplies the tag per point.
    """

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]
    key: "QdrantFieldReader"
    tags: "OxigraphOverlayReader"
    rollup_factor: float = 0.85    # a rolled-up tag is less sure than a direct one

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        tags_by_id = self.tags._overlay_tags()
        points = self.gateway.scroll(self.select_categories, SCROLL_FIELDS)
        keyed = []
        group_tags: Dict[str, Dict[str, float]] = {}
        for p in points:
            k = self.key._value(p.get("payload", {})).lower()
            if not k:
                continue
            keyed.append((k, p))
            for t in tags_by_id.get(str(p.get("id")), ()):
                best = group_tags.setdefault(k, {})
                best[t["label"]] = max(best.get(t["label"], 0.0), t["conf"])
        for k, p in keyed:
            pl = p.get("payload", {})
            for label, conf in group_tags.get(k, {}).items():
                yield EvidenceItem(
                    preference_id=str(p.get("id")),
                    user_id=user_id,
                    domain=self.domain,
                    dimension=self.dimension,
                    value=label,
                    value_qid=None,
                    item_strength=_as_float(pl.get("strength"), 0.0),
                    polarity_source=self.key.default_polarity,
                    source=pl.get("source") or "",
                    observed_at=_parse_dt(pl.get("observed_at")),
                    enrichment_confidence=conf * self.rollup_factor,
                    raw_subject=pl.get("subject") or "",
                )


@dataclass
class LexiconReader:
    """Value from a payload field, mapped onto a shared vocabulary by keyword.

    A restaurant named for what it serves is evidence for that cuisine with no
    lookup at all. The field goes through the same value pipeline as
    QdrantFieldReader; each canonical label whose keywords the text contains is
    one evidence item. Nothing matched is no evidence (never a guess).
    """

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]
    source_field: "QdrantFieldReader"
    vocab: str
    evidence_confidence: float = 0.6

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        for p in self.gateway.scroll(self.select_categories, SCROLL_FIELDS):
            pl = p.get("payload", {})
            text = self.source_field._value(pl)
            for label in canonical_labels(text, self.vocab, strict=True):
                yield EvidenceItem(
                    preference_id=str(p.get("id")),
                    user_id=user_id,
                    domain=self.domain,
                    dimension=self.dimension,
                    value=label,
                    value_qid=None,
                    item_strength=_as_float(pl.get("strength"), 0.0),
                    polarity_source=self.source_field.default_polarity,
                    source=pl.get("source") or "",
                    observed_at=_parse_dt(pl.get("observed_at")),
                    enrichment_confidence=self.evidence_confidence,
                    raw_subject=pl.get("subject") or "",
                )


@dataclass
class HttpStoreGateway:
    """Real gateway: Oxigraph SPARQL + Qdrant HTTP. Relies on the store-auth
    .pth shim (hub interpreter) to attach credentials on loopback."""

    oxigraph_url: str = "http://localhost:7878"
    qdrant_url: str = "http://localhost:6333"
    collection: str = "preferences"
    scroll_cap: int = 200000
    _memo: dict = field(default_factory=dict, repr=False)

    def sparql(self, query: str) -> List[dict]:
        req = urllib.request.Request(
            self.oxigraph_url + "/query?query=" + urllib.parse.quote(query),
            headers={"Accept": "application/sparql-results+json"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)["results"]["bindings"]

    def scroll(self, categories: List[str], fields: List[str]) -> List[dict]:
        key = tuple(sorted(categories))
        if key in self._memo:
            return self._memo[key]
        self._memo[key] = self._scroll(categories)
        return self._memo[key]

    def _scroll(self, categories: List[str]) -> List[dict]:
        pts: List[dict] = []
        offset = None
        # No categories means "no filter". An empty "any" would match nothing.
        flt = (
            {"must": [{"key": "category", "match": {"any": list(categories)}}]}
            if categories else None
        )
        while True:
            body = {"limit": 2000, "with_payload": SCROLL_FIELDS}
            if flt is not None:
                body["filter"] = flt
            if offset is not None:
                body["offset"] = offset
            req = urllib.request.Request(
                self.qdrant_url + "/collections/%s/points/scroll" % self.collection,
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=180) as r:
                res = json.load(r)["result"]
            pts.extend(res["points"])
            offset = res.get("next_page_offset")
            if offset is None or len(pts) >= self.scroll_cap:
                break
        return pts
