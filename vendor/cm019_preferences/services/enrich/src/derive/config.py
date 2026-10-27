"""Load the derivation config (DATA files) into engine objects (Chunk 2).

readers.yaml / dimensions.yaml are the ONLY thing that changes to add a
dimension. config.py turns them into DimensionConfig + Reader instances; the
engine never imports a domain module.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import List

import yaml

from .engine import DimensionConfig
from .readers import (
    LexiconReader,
    OxigraphOverlayReader,
    QdrantFieldReader,
    RollupReader,
    StoreGateway,
)
from .stated import StatedConversationReader, StatedMapper
from .thematic import HIERARCHY_GRAPH, ThematicReader
from .stated_messages import StatedTranscriptReader
from .stated_model import VerdictCache

_HERE = Path(__file__).resolve().parent
DIMENSIONS_YAML = _HERE / "dimensions.yaml"
READERS_YAML = _HERE / "readers.yaml"


def load_dimensions(path: Path = DIMENSIONS_YAML) -> List[DimensionConfig]:
    rows = yaml.safe_load(Path(path).read_text()) or []
    return [
        DimensionConfig(
            dimension=r["dimension"],
            category=r.get("category", r["dimension"].split(".")[0]),
            min_evidence=int(r.get("min_evidence", 3)),
            tier=str(r.get("tier", "specific")),
            sensitive_match=str(r.get("sensitive_match", "")),
            max_items=int(r["max_items"]) if r.get("max_items") else None,
            half_life_days=float(r["half_life_days"]) if r.get("half_life_days") else None,
            evergreen=bool(r.get("evergreen", False)),
        )
        for r in rows
    ]


def build_readers(gateway: StoreGateway, path: Path = READERS_YAML, stated_model=None) -> list:
    """``stated_model`` is the optional local-model fallback for stated preferences."""
    rows = yaml.safe_load(Path(path).read_text()) or []
    readers: list = []
    for r in rows:
        kind = r["kind"]
        common = dict(
            gateway=gateway,
            dimension=r["dimension"],
            domain=r["domain"],
            category=r.get("category", r["dimension"].split(".")[0]),
            select_categories=list(r.get("select_categories", [])),
        )
        if kind == "oxigraph_overlay":
            readers.append(
                OxigraphOverlayReader(
                    tag_predicate=r["tag_predicate"],
                    tag_entity_type=r.get("tag_entity_type"),
                    value_exclude_regex=r.get("value_exclude_regex"),
                    vocab=r.get("vocab"),
                    vocab_strict=bool(r.get("vocab_strict", False)),
                    **common,
                )
            )
        elif kind == "qdrant_field":
            readers.append(
                QdrantFieldReader(
                    field_path=r["field"],
                    fallback_field=r.get("fallback_field"),
                    split=r.get("split"),
                    part=r.get("part", "first"),
                    transform=r.get("transform"),
                    strip_regex=r.get("strip_regex"),
                    allowlist=tuple(str(a).lower() for a in r.get("allowlist", [])),
                    evidence_confidence=float(r.get("evidence_confidence", 0.5)),
                    **common,
                )
            )
        elif kind in ("rollup", "lexicon"):
            field_reader = QdrantFieldReader(
                field_path=r["key_field" if kind == "rollup" else "field"],
                fallback_field=r.get("fallback_field"),
                split=r.get("split"),
                part=r.get("part", "first"),
                transform=r.get("transform"),
                strip_regex=r.get("strip_regex"),
                **common,
            )
            if kind == "lexicon":
                readers.append(LexiconReader(
                    source_field=field_reader, vocab=r["vocab"],
                    evidence_confidence=float(r.get("evidence_confidence", 0.6)), **common))
            else:
                readers.append(RollupReader(
                    key=field_reader,
                    tags=OxigraphOverlayReader(
                        tag_predicate=r["tag_predicate"],
                        tag_entity_type=r.get("tag_entity_type"),
                        value_exclude_regex=r.get("value_exclude_regex"),
                        vocab=r.get("vocab"),
                        vocab_strict=bool(r.get("vocab_strict", False)),
                        **common),
                    rollup_factor=float(r.get("rollup_factor", 0.85)), **common))
        elif kind == "thematic":
            # Topic -> Wikidata QID -> broader concept (thematic.py). Degrades to
            # no evidence, with a status, when the QID pass has not run.
            readers.append(
                ThematicReader(
                    hierarchy_graph=r.get("hierarchy_graph", HIERARCHY_GRAPH),
                    min_leaves=int(r.get("min_leaves", 2)),
                    evidence_confidence=float(r.get("evidence_confidence", 0.5)),
                    **common,
                )
            )
        elif kind == "stated_conversation":
            # One reader, many dimensions: the vocabulary decides which. The
            # model may only answer with a dimension the registry carries.
            readers.append(
                StatedConversationReader(
                    gateway=gateway,
                    mapper=StatedMapper(
                        allowed_dimensions=[d.dimension for d in load_dimensions()],
                        model=stated_model,
                    ),
                    dimension=r["dimension"],
                    domain=r["domain"],
                    category=r.get("category", "stated"),
                    fact_types=tuple(r.get("fact_types", ["preference"])),
                )
            )
        elif kind == "stated_transcripts":
            # The owner's own lines in the transcripts CM048 already wrote. Never
            # a message database: that would be a new TCC surface.
            root = Path(r.get("root") or os.environ.get("OSTLER_CONVERSATIONS_DIR")
                        or Path.home() / "Documents" / "Ostler" / "Conversations")
            readers.append(
                StatedTranscriptReader(
                    gateway=gateway,
                    root=root,
                    verdicts=VerdictCache(Path(
                        os.environ.get("OSTLER_STATED_MODEL_CACHE")
                        or Path(os.environ.get("OSTLER_DIR") or Path.home() / ".ostler")
                        / "workspace" / "stated_model_verdicts.json")),
                    mapper=StatedMapper(allowed_dimensions=[d.dimension for d in load_dimensions()]),
                    channels=tuple(r.get("channels", ["im", "imessage", "whatsapp"])),
                    allowed_privacy=tuple(r.get("allowed_privacy", ["L0", "L1", "L2"])),
                    dimension=r["dimension"],
                    domain=r["domain"],
                    category=r.get("category", "stated"),
                )
            )
        else:
            # Unknown kind: loud, never a silent skip.
            raise ValueError(f"unknown reader kind {kind!r} for dimension {r['dimension']!r}")
    return readers
