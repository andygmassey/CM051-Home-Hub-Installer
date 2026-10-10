"""One adapter per source. ``parse_file(source_hint, path) -> [Meeting]``."""
from __future__ import annotations

from pathlib import Path

from . import fireflies, granola, otter, transcript_files

# Drop-folder names under ~/Documents/Ostler/Imports/<source>/
SOURCES = ("granola", "otter", "fireflies", "transcripts")

_BY_SOURCE = {
    "granola": granola.parse,
    "otter": otter.parse,
    "fireflies": fireflies.parse,
    "transcripts": transcript_files.parse,
}


def parse_file(source: str, path: Path):
    return _BY_SOURCE[source](Path(path))
