"""Load the derivation config (DATA files) into engine objects (Chunk 2).

readers.yaml / dimensions.yaml are the ONLY thing that changes to add a
dimension. config.py turns them into DimensionConfig + Reader instances; the
engine never imports a domain module.
"""

from __future__ import annotations

from pathlib import Path
from typing import List

import yaml

from .engine import DimensionConfig
from .readers import OxigraphOverlayReader, QdrantFieldReader, StoreGateway

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
        )
        for r in rows
    ]


def build_readers(gateway: StoreGateway, path: Path = READERS_YAML) -> list:
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
                    **common,
                )
            )
        elif kind == "qdrant_field":
            readers.append(QdrantFieldReader(field_path=r["field"], **common))
        else:
            # Unknown kind: loud, never a silent skip.
            raise ValueError(f"unknown reader kind {kind!r} for dimension {r['dimension']!r}")
    return readers
