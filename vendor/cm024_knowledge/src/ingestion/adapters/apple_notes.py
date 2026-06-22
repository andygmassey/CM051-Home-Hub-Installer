"""AppleNotesAdapter: ingest the HR015 FDA Apple Notes export (apple_notes.json).

The HR015 ``ostler_fda`` Apple Notes parser walks the local
``NoteStore.sqlite`` and emits a JSON array of note records, one per
note, already shaped to map straight onto the CM024 ParsedNote /
markdown-writer frontmatter::

    note_id   -> ParsedNote.evernote_guid   (stable per-note id; idempotent re-ingest)
    title     -> ParsedNote.title
    content   -> ParsedNote.content         (plain-text body)
    created   -> ParsedNote.created         (ISO-8601 string)
    updated   -> ParsedNote.updated         (ISO-8601 string)
    tags      -> ParsedNote.tags

Unlike the Evernote (.enex) and Notion (one .md per page) adapters, the
whole export is a single ``.json`` file, so ``discover()`` reads it once
and yields one RawNote per record (the record dict rides in
``RawNote.extras``). ``parse()`` maps the record onto a normalised
ParsedNote.

Out of scope (folded downstream / follow-up):

- ``notebook`` (the Apple Notes folder): ParsedNote has no notebook
  field today, so the record's notebook is preserved in
  ``RawNote.extras`` for a later pipeline step rather than dropped.
- ``compartment_level`` / ``is_locked``: privacy is decided by the
  CM024 convert step's classifier, not the adapter; locked notes are
  already excluded upstream by the FDA parser unless the operator
  opts in.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Iterator, Optional

from ..enex_parser import ParsedNote
from .base import RawNote

logger = logging.getLogger(__name__)


def _parse_iso(value: object) -> Optional[datetime]:
    """Best-effort ISO-8601 -> datetime; None on absent/unparseable input."""
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


class AppleNotesAdapter:
    """Adapter for the HR015 FDA Apple Notes export (apple_notes.json)."""

    @classmethod
    def format_name(cls) -> str:
        return "apple_notes"

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        """Yield one RawNote per note record in apple_notes.json.

        Accepts the path to the ``apple_notes.json`` file (a JSON array
        of note records emitted by the ostler_fda Apple Notes parser).
        A directory is also accepted: the ``apple_notes.json`` at its top
        level is used.
        """
        input_path = Path(input_path)
        if input_path.is_dir():
            candidate = input_path / "apple_notes.json"
            if not candidate.exists():
                raise ValueError(
                    f"AppleNotesAdapter: no apple_notes.json in directory {input_path}"
                )
            input_path = candidate
        if not input_path.is_file():
            raise ValueError(
                "AppleNotesAdapter input must be apple_notes.json or its "
                f"directory: {input_path}"
            )

        try:
            records = json.loads(input_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            logger.warning(
                "AppleNotesAdapter.discover: failed to read %s: %s", input_path, e
            )
            return

        if not isinstance(records, list):
            logger.warning(
                "AppleNotesAdapter.discover: %s is not a JSON array; skipping",
                input_path,
            )
            return

        for record in records:
            if not isinstance(record, dict):
                continue
            yield RawNote(
                source_path=input_path,
                element=None,
                raw_id=record.get("note_id"),
                extras={"record": record},
            )

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        """Map one Apple Notes record onto a normalised ParsedNote.

        Returns None for an empty/malformed record (no title and no
        content), mirroring the other adapters' skip-empties behaviour.
        """
        record = raw.extras.get("record") if raw.extras else None
        if not isinstance(record, dict):
            return None

        title = (record.get("title") or "").strip()
        content = record.get("content") or ""
        if not title and not content.strip():
            return None

        tags = record.get("tags") or []
        if not isinstance(tags, list):
            tags = []

        return ParsedNote(
            title=title or "Untitled",
            content=content,
            content_html=content,  # Apple Notes body is plain text; no separate HTML
            created=_parse_iso(record.get("created")),
            updated=_parse_iso(record.get("updated")),
            tags=tags,
            evernote_guid=record.get("note_id"),  # stable id for idempotent re-ingest
        )
