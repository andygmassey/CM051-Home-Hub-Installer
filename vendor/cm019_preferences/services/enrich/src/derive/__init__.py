"""PWG preference-derivation engine (post-ingest materialization).

Self-contained package. Nothing in the existing pipeline imports it; it reads
the already-enriched literal items (Qdrant payloads + the Oxigraph enrichment
overlay) and materializes derived preference nodes into a dedicated, fully
regenerable RDF named graph. It never mutates literal data or the live query
path. See design/PWG_PREFERENCE_INTELLIGENCE_DESIGN.md.
"""

from .model import (
    DERIVED_GRAPH,
    ENRICH_NS,
    PWG_NS,
    DerivedPreference,
    EvidenceItem,
    derived_node_uri,
    normalize_value,
)

__all__ = [
    "DERIVED_GRAPH",
    "ENRICH_NS",
    "PWG_NS",
    "DerivedPreference",
    "EvidenceItem",
    "derived_node_uri",
    "normalize_value",
]
