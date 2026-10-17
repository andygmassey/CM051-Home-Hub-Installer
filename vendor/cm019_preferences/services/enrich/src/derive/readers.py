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
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Protocol

from .model import ENRICH_NS, PREF_URN_PREFIX, EvidenceItem

RDFS_LABEL = "http://www.w3.org/2000/01/rdf-schema#label"


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

    def _pred(self) -> str:
        return self.tag_predicate if self.tag_predicate.startswith("http") else ENRICH_NS + self.tag_predicate

    def _overlay_tags(self) -> Dict[str, List[dict]]:
        """pref_id -> [{'label':..., 'qid':.., 'conf':..}] from one SPARQL."""
        pred = self._pred()
        if self.tag_entity_type:
            etype = ENRICH_NS + "entityType"
            q = (
                "SELECT ?s ?label ?conf WHERE { "
                "?s <%s> ?e . ?e <%s> ?label . ?e <%s> ?etype . "
                'FILTER(LCASE(STR(?etype)) = "%s") '
                "OPTIONAL { ?s <%senrichmentConfidence> ?conf } "
                "}" % (pred, RDFS_LABEL, etype, self.tag_entity_type.lower(), ENRICH_NS)
            )
        else:
            q = (
                "SELECT ?s ?label ?conf WHERE { "
                "?s <%s> ?g . OPTIONAL { ?g <%s> ?label } "
                "OPTIONAL { ?s <%senrichmentConfidence> ?conf } "
                "}" % (pred, RDFS_LABEL, ENRICH_NS)
            )
        tags: Dict[str, List[dict]] = {}
        for b in self.gateway.sparql(q):
            subj = b.get("s", {}).get("value", "")
            if not subj.startswith(PREF_URN_PREFIX):
                continue
            label = b.get("label", {}).get("value")
            if not label:
                continue
            pref_id = subj[len(PREF_URN_PREFIX):]
            tags.setdefault(pref_id, []).append(
                {"label": label, "conf": _as_float(b.get("conf", {}).get("value"), 0.5)}
            )
        return tags

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        tags_by_id = self._overlay_tags()
        points = self.gateway.scroll(
            self.select_categories,
            ["category", "preference_id", "subject", "source", "strength", "observed_at"],
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
    """Value and strength both taken straight from a Qdrant payload field."""

    gateway: StoreGateway
    dimension: str
    domain: str
    category: str
    select_categories: List[str]
    field_path: str                 # dotted, e.g. "extra.brand"
    default_polarity: str = "behavioral"

    def _dig(self, payload: dict):
        cur = payload
        for part in self.field_path.split("."):
            if not isinstance(cur, dict):
                return None
            cur = cur.get(part)
        return cur

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        points = self.gateway.scroll(
            self.select_categories,
            ["category", "preference_id", "subject", "source", "strength", "observed_at", "extra"],
        )
        for p in points:
            pl = p.get("payload", {})
            value = self._dig(pl)
            if not value:
                continue
            yield EvidenceItem(
                preference_id=str(p.get("id")),
                user_id=user_id,
                domain=self.domain,
                dimension=self.dimension,
                value=str(value),
                value_qid=None,
                item_strength=_as_float(pl.get("strength"), 0.0),
                polarity_source=self.default_polarity,
                source=pl.get("source") or "",
                observed_at=_parse_dt(pl.get("observed_at")),
                enrichment_confidence=0.5,
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

    def sparql(self, query: str) -> List[dict]:
        req = urllib.request.Request(
            self.oxigraph_url + "/query?query=" + urllib.parse.quote(query),
            headers={"Accept": "application/sparql-results+json"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)["results"]["bindings"]

    def scroll(self, categories: List[str], fields: List[str]) -> List[dict]:
        pts: List[dict] = []
        offset = None
        flt = {"must": [{"key": "category", "match": {"any": list(categories)}}]}
        while True:
            body = {"limit": 2000, "with_payload": fields, "filter": flt}
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
