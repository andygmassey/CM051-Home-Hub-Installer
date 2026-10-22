"""Universal records for the derivation engine (Chunk 1).

Two data types carry the whole pipeline so every stage after the Readers is
domain-agnostic:

- ``EvidenceItem``: one literal observation, already joined across stores
  (Qdrant strength/recency + Oxigraph overlay tag). Readers are the ONLY
  component that knows about stores, namespaces and domains; they emit these.
- ``DerivedPreference``: one materialized ``pwg:DerivedPreference`` node, with
  MANDATORY ``pwg:derivedFrom`` provenance (SHACL-enforced, Chunk 1 shape).

Node URIs are deterministic so a wholesale rebuild overwrites rather than
duplicates (mirrors the geo precedent's stable-hash id).
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

# --- Namespaces (measured against the real graph, Chunk 1 spike) ------------
PWG_NS = "https://schema.ostler.ai/ontology#"
# The enrichment overlay (hasGenre/hasEntity/hasTopic) is written under this
# DIFFERENT namespace and attached to subject urn:ostler:preference:{point_id}.
ENRICH_NS = "https://schema.ostler.ai/enrichment/ontology#"
RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
XSD_NS = "http://www.w3.org/2001/XMLSchema#"

# Dedicated, fully-regenerable named graph for derived nodes. Every existing
# query targets the default graph and never names this one, so literal reads are
# byte-identical before and after derivation runs.
DERIVED_GRAPH = "https://schema.ostler.ai/derived/graph/preferences"

# Dedicated Qdrant collection for the derived mirror. It is STRICTLY separate
# from the literal "preferences" collection: derived (source="inferred") points
# never enter the literal collection, so CM044's deny-list cannot promote them
# back into Films/Music/Topics as a literal "like" (the double-count bug).
LITERAL_COLLECTION = "preferences"
DERIVED_COLLECTION = "derived_preferences"

# The literal enrichment overlay subject prefix (the Chunk 1 join key).
PREF_URN_PREFIX = "urn:ostler:preference:"

_WS = re.compile(r"\s+")


def normalize_value(value: str) -> str:
    """Canonical form used for grouping and for the deterministic node URI.

    Lowercase, trim, collapse internal whitespace. Deliberately conservative: it
    must be stable across rebuilds, so it never does lossy stemming.
    """
    return _WS.sub(" ", (value or "").strip().lower())


def derived_node_uri(user_id: str, dimension: str, value: str) -> str:
    """urn:ostler:derived:{user}:{sha1(dimension + '|' + normalized_value)[:16]}.

    Deterministic: same (user, dimension, value) always yields the same URI, so
    re-running overwrites instead of duplicating.
    """
    key = f"{dimension}|{normalize_value(value)}"
    digest = hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]
    return f"urn:ostler:derived:{user_id}:{digest}"


@dataclass(frozen=True)
class EvidenceItem:
    """One literal observation feeding a derived node. Domain-agnostic."""

    preference_id: str        # join key + provenance target (Qdrant point id)
    user_id: str
    domain: str               # "media.film", "place", "people", ...
    dimension: str            # "media.film.genre", "place.area", ...
    value: str                # "science fiction", "Christopher Nolan", ...
    value_qid: Optional[str]  # Wikidata QID if resolvable
    item_strength: float      # -1..1, the literal item's own strength
    polarity_source: str      # "behavioral" | "stated" (for contradiction)
    source: str               # platform: "netflix"/"spotify"/...
    observed_at: Optional[datetime]
    enrichment_confidence: float   # 0..1, from the overlay
    context: dict = field(default_factory=dict)  # {time_of_day, activity, ...}
    raw_subject: str = ""     # literal item title, for explanations

    @property
    def provenance_uri(self) -> str:
        """The literal subject this evidence links back to (pwg:derivedFrom)."""
        return f"{PREF_URN_PREFIX}{self.preference_id}"


def _esc(s: str) -> str:
    """Escape a string literal for Turtle."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


@dataclass
class DerivedPreference:
    """A materialized pwg:DerivedPreference node. See design section 1.1."""

    user_id: str
    dimension: str
    subject: str                       # abstract value, e.g. "science fiction"
    preference_strength: float         # -1..1
    confidence: float                  # 0..1
    category: str                      # films / music / ...
    evidence_from: list                # list[str] literal URIs, MUST be >= 1
    evidence_count: int
    evidence_source_count: int = 1
    intensity_tier: str = "casual"
    source: str = "inferred"
    value_qid: Optional[str] = None
    first_observed_at: Optional[datetime] = None
    last_observed_at: Optional[datetime] = None
    derived_at: Optional[datetime] = None
    derivation_version: str = "derive-1.0.0+films"
    derivation_method: str = "rollup"
    is_contested: bool = False
    is_hard_constraint: bool = False
    trend: Optional[str] = None
    # A few literal titles behind this node, for the "because" line.
    evidence_titles: list = field(default_factory=list)
    tier: str = ""       # "broad" | "specific"; "" = not stated (older graphs)

    @property
    def uri(self) -> str:
        return derived_node_uri(self.user_id, self.dimension, self.subject)

    @property
    def polarity_class(self) -> str:
        """pwg:LikePreference or pwg:DislikePreference by sign."""
        return "LikePreference" if self.preference_strength >= 0 else "DislikePreference"

    def to_turtle(self, with_prefixes: bool = True) -> str:
        """Serialize this node to Turtle.

        When ``with_prefixes`` is True the output is a standalone, parseable
        document (used by the SHACL test and the writer's temp-graph load).
        """
        u = f"<{self.uri}>"
        t = []
        if with_prefixes:
            t += [
                f"@prefix pwg: <{PWG_NS}> .",
                f"@prefix rdfs: <{RDFS_NS}> .",
                f"@prefix xsd: <{XSD_NS}> .",
                "",
            ]
        t.append(f"{u} a pwg:DerivedPreference, pwg:{self.polarity_class} ;")
        t.append(f'    pwg:belongsToUser <{PWG_NS}user_{self.user_id}> ;')
        t.append(f'    pwg:dimension "{_esc(self.dimension)}" ;')
        t.append(f'    pwg:subject "{_esc(self.subject)}" ;')
        t.append(f'    rdfs:label "{_esc(self.subject)}" ;')
        t.append(f'    pwg:preferenceStrength "{self.preference_strength!r}"^^xsd:float ;')
        t.append(f'    pwg:confidence "{self.confidence!r}"^^xsd:float ;')
        t.append(f'    pwg:intensityTier "{_esc(self.intensity_tier)}" ;')
        t.append(f'    pwg:source "{_esc(self.source)}" ;')
        t.append(f'    pwg:category "{_esc(self.category)}" ;')
        t.append(f"    pwg:evidenceCount {int(self.evidence_count)} ;")
        t.append(f"    pwg:evidenceSourceCount {int(self.evidence_source_count)} ;")
        t.append(f"    pwg:isContested {str(self.is_contested).lower()} ;")
        t.append(f'    pwg:derivationVersion "{_esc(self.derivation_version)}" ;')
        t.append(f'    pwg:derivationMethod "{_esc(self.derivation_method)}" ;')
        if self.value_qid:
            t.append(f'    pwg:valueQid "{_esc(self.value_qid)}" ;')
        if self.is_hard_constraint:
            t.append("    pwg:isHardConstraint true ;")
        if self.trend:
            t.append(f'    pwg:trend "{_esc(self.trend)}" ;')
        for dt_prop, dt in (
            ("firstObservedAt", self.first_observed_at),
            ("lastObservedAt", self.last_observed_at),
            ("derivedAt", self.derived_at),
        ):
            if dt is not None:
                t.append(f'    pwg:{dt_prop} "{dt.isoformat()}"^^xsd:dateTime ;')
        if self.tier:
            t.append(f'    pwg:tier "{_esc(self.tier)}" ;')
        for title in self.evidence_titles:
            t.append(f'    pwg:evidenceTitle "{_esc(title)}" ;')
        # derivedFrom last; MANDATORY (SHACL sh:minCount 1).
        froms = ",\n                    ".join(f"<{uri}>" for uri in self.evidence_from)
        if froms:
            t.append(f"    pwg:derivedFrom {froms} .")
        else:
            # Emit a node with NO derivedFrom only when explicitly built that
            # way (the SHACL negative control relies on this path). Close the
            # previous statement instead.
            t[-1] = t[-1].rstrip(" ;") + " ."
        return "\n".join(t) + ("\n" if with_prefixes else "")
