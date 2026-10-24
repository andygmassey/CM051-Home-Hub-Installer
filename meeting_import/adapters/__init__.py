"""One adapter per source. ``parse_file(source_hint, path) -> [Meeting]``.

``detect(path)`` names the source of a LOOSE file (e.g. in ~/Downloads) from
its documented name or its content, and returns None for anything it cannot
attribute with confidence. Generic VTT/SRT/DOCX are never guessed from a loose
folder: they import only from ``Imports/transcripts/``.
"""
from __future__ import annotations

import csv
import io
import json
import re
from pathlib import Path

from . import fathom, fireflies, granola, otter, transcript_files

# Drop-folder names under ~/Documents/Ostler/Imports/<source>/
SOURCES = ("granola", "otter", "fireflies", "fathom", "transcripts")

_BY_SOURCE = {
    "granola": granola.parse,
    "otter": otter.parse,
    "fireflies": fireflies.parse,
    "fathom": fathom.parse,
    "transcripts": transcript_files.parse,
}

_OTTER_NAME = re.compile(r"_otter_ai\.(txt|docx|srt)$", re.I)
_GRANOLA_ID = re.compile(r"^not_[A-Za-z0-9]{14}$")
_MAX_JSON = 200 * 1024 * 1024


def parse_file(source: str, path: Path):
    return _BY_SOURCE[source](Path(path))


def _json_source(d) -> str | None:
    if isinstance(d, dict) and isinstance(d.get("data"), dict) and (
            "transcript" in d["data"] or "transcripts" in d["data"]):
        return "fireflies"
    rows = d.get("items") if isinstance(d, dict) and isinstance(d.get("items"), list) else \
        d.get("notes") if isinstance(d, dict) and isinstance(d.get("notes"), list) else \
        d if isinstance(d, list) else [d]
    first = next((r for r in rows if isinstance(r, dict)), None)
    if first is None:
        return None
    if "recording_id" in first and ("transcript" in first or "default_summary" in first
                                    or "calendar_invitees" in first):
        return "fathom"
    if first.get("object") == "note" or _GRANOLA_ID.match(str(first.get("id") or "")):
        return "granola"
    if "sentences" in first and ("dateString" in first or "speakers" in first):
        return "fireflies"
    return None


def detect(path: Path) -> str | None:
    path = Path(path)
    name = path.name.lower()
    if _OTTER_NAME.search(name):
        return "otter"
    if name.endswith(".json"):
        try:
            if path.stat().st_size > _MAX_JSON:
                return None
            return _json_source(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            return None
    if name.endswith(".csv") and "granola" in name:
        try:
            hdr = next(csv.reader(io.StringIO(path.read_text(encoding="utf-8-sig")[:65536])), [])
        except (OSError, ValueError, StopIteration):
            return None
        low = [h.strip().lower() for h in hdr]
        return "granola" if any("transcript" in h or "summary" in h for h in low) else None
    return None
