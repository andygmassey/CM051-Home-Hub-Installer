"""Per-writer default privacy level (134). Vendored reader.

Reads ``privacy_scale_canonical.tsv`` ``[source_default]`` beside this file.
The TSV is a VENDORED COPY of CM048's canonical table. Its digest is pinned
in ``tests/test_source_defaults_pin.py``; re-pinning happens only in a PR
that updates the bytes and the digest together. Never read CM048's copy live.
"""
from __future__ import annotations

from pathlib import Path

_TSV = Path(__file__).resolve().parent / "privacy_scale_canonical.tsv"
_LEVELS = ("L0", "L1", "L2", "L3")


def _table(path: Path = _TSV) -> dict[str, tuple[str, str]]:
    rows: dict[str, tuple[str, str]] = {}
    in_section = False
    header_seen = False
    for line in path.read_text().splitlines():
        if line.startswith("["):
            in_section = line.strip() == "[source_default]"
            continue
        if not in_section or not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if not header_seen:
            header_seen = True  # writer / default_level / rule
            continue
        rows[cols[0]] = (cols[1], cols[2])
    return rows


def default_level(writer: str, path: Path = _TSV) -> str:
    """The table level for a writer; an unknown or unlisted writer is L3."""
    entry = _table(path).get(writer)
    return "L3" if entry is None else entry[0]


def stamp(writer: str, computed: str | None, floor: str | None = None,
          path: Path = _TSV) -> str:
    """Absent level -> writer default. Computed kept (L0/L1 included).
    Unrecognised computed -> L3. Floor raises only."""
    rank = {lvl: i for i, lvl in enumerate(_LEVELS)}
    if computed is None or computed == "":
        level = default_level(writer, path)
    elif computed in rank:
        level = computed
    else:
        level = "L3"
    if floor in rank and rank[floor] > rank[level]:
        level = floor
    return level
