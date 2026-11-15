"""pyshacl-backed validator for the derived-preference shape (Chunk 3).

Loaded lazily so the engine imports without rdflib/pyshacl present until a write
actually needs the gate.
"""

from __future__ import annotations

from pathlib import Path

_SHAPES_PATH = (
    Path(__file__).resolve().parents[4]
    / "ontology"
    / "shacl"
    / "derived-preference-shapes.ttl"
)


class PyShaclValidator:
    def __init__(self, shapes_path: Path = _SHAPES_PATH):
        self._shapes_ttl = Path(shapes_path).read_text()

    def validate_turtle(self, data_ttl: str):
        import pyshacl
        import rdflib

        data = rdflib.Graph().parse(data=data_ttl, format="turtle")
        shapes = rdflib.Graph().parse(data=self._shapes_ttl, format="turtle")
        conforms, _g, text = pyshacl.validate(
            data, shacl_graph=shapes, inference="none", abort_on_first=False
        )
        return conforms, text
