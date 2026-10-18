"""RemindersAdapter: ingest the HR015 FDA Reminders export (reminders.json).

LOCAL GRAFT, not yet upstreamed. See vendor/divergences/cm024_knowledge.patch
and VENDOR_MANIFEST.toml's cm024_knowledge entry: this file, like
apple_notes.py before it, is carried across a re-vendor as a tracked
divergence until the CM024 owner lands it upstream in andygmassey/
evernote-knowledge. Filed for that landing the same way apple_notes.py was.

The HR015 ``ostler_fda`` Reminders parser (``ostler_fda/reminders.py``)
walks the local macOS Reminders CoreData store and emits a JSON array of
``Reminder`` dataclass records, one per reminder::

    title            -> ParsedNote.title
    notes            -> folded into ParsedNote.content (see _record_content)
    due_date         -> folded into ParsedNote.content (ISO-8601 string or null)
    completion_date  -> folded into ParsedNote.content (ISO-8601 string or null)
    creation_date    -> ParsedNote.created
    priority         -> folded into ParsedNote.content (0/1/5/9, Reminders.app scale)
    list_name        -> ParsedNote.tags, as ``list:<name>``
    is_completed     -> ParsedNote.tags, as ``completed`` when true
    is_flagged       -> ParsedNote.tags, as ``flagged`` when true

NO STABLE ID, UNLIKE apple_notes.json. The apple_notes export re-emits a
per-note ``evernote_guid`` the adapter keys dedup on for idempotent re-scan.
``ostler_fda/reminders.py`` selects no primary key column at all (its SQL
reads ``ZREMCDREMINDER`` but never ``r.Z_PK``), so there is nothing
per-record to key on here. ``_record_id`` below derives a SYNTHETIC id by
hashing (title, creation_date, due_date) -- stable across an unedited
reminder's re-scans, but it will mint a NEW id (a duplicate knowledge-base
entry, not an update) if the operator edits a reminder's title or due date
between scans. That is a real, known limitation, not silently
worked around: surfacing ``r.Z_PK`` in the extractor is the correct fix and
belongs in ``ostler_fda/reminders.py`` (HR015), which this graft does not
touch. Recorded here rather than left implicit, per the discipline that
produced this file's own docstring conventions (see apple_notes.py).

Unlike the Evernote (.enex) and Notion (one .md per page) adapters, the
whole export is a single ``.json`` file, so ``discover()`` reads it once
and yields one RawNote per record (the record dict rides in
``RawNote.extras``), mirroring AppleNotesAdapter exactly.

Out of scope (folded downstream / follow-up):

- ``priority`` as a first-class sort/filter facet: ParsedNote has no
  priority field today, so it is folded into the content body instead of
  being dropped, but a structured facet would need a ParsedNote field the
  same way ``notebook`` is flagged as future work in apple_notes.py.
"""
from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Iterator, Optional

from ..enex_parser import ParsedNote
from .base import RawNote

logger = logging.getLogger(__name__)

_PRIORITY_LABELS = {0: "none", 1: "high", 5: "medium", 9: "low"}


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


def _record_id(record: dict) -> str:
    """Synthetic stable id: see the module docstring's "NO STABLE ID" note.

    Hashes (title, creation_date, due_date) rather than the full record so
    an unrelated field (notes edited, flag toggled) does not mint a new id
    for what is still recognisably the same reminder.
    """
    basis = "|".join([
        str(record.get("title") or ""),
        str(record.get("creation_date") or ""),
        str(record.get("due_date") or ""),
    ])
    return "reminder-" + hashlib.sha256(basis.encode("utf-8")).hexdigest()[:16]


def _record_content(record: dict) -> str:
    """Build a readable body: the notes text plus a metadata footer.

    A bare title with no body would be thin for semantic search --
    Reminders.app's due date, priority and list carry real retrieval
    signal (e.g. "what did I need to buy"), so they are folded into the
    text rather than dropped on the floor, mirroring how apple_notes.py
    preserves ``notebook`` in extras rather than discarding it.
    """
    lines: list[str] = []
    notes = (record.get("notes") or "").strip()
    if notes:
        lines.append(notes)
        lines.append("")

    meta: list[str] = []
    list_name = record.get("list_name")
    if list_name:
        meta.append(f"List: {list_name}")
    due = record.get("due_date")
    if due:
        meta.append(f"Due: {due}")
    priority = record.get("priority")
    if priority:
        meta.append(f"Priority: {_PRIORITY_LABELS.get(priority, priority)}")
    if record.get("is_completed"):
        completed = record.get("completion_date")
        meta.append(f"Completed: {completed}" if completed else "Completed: yes")
    if record.get("is_flagged"):
        meta.append("Flagged: yes")

    if meta:
        lines.extend(meta)

    return "\n".join(lines).strip()


class RemindersAdapter:
    """Adapter for the HR015 FDA Reminders export (reminders.json)."""

    @classmethod
    def format_name(cls) -> str:
        return "reminders"

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        """Yield one RawNote per reminder record in reminders.json.

        Accepts the path to the ``reminders.json`` file (a JSON array of
        reminder records emitted by the ostler_fda Reminders parser). A
        directory is also accepted: the ``reminders.json`` at its top level
        is used. Mirrors AppleNotesAdapter.discover exactly.
        """
        input_path = Path(input_path)
        if input_path.is_dir():
            candidate = input_path / "reminders.json"
            if not candidate.exists():
                raise ValueError(
                    f"RemindersAdapter: no reminders.json in directory {input_path}"
                )
            input_path = candidate
        if not input_path.is_file():
            raise ValueError(
                "RemindersAdapter input must be reminders.json or its "
                f"directory: {input_path}"
            )

        try:
            records = json.loads(input_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            logger.warning(
                "RemindersAdapter.discover: failed to read %s: %s", input_path, e
            )
            return

        if not isinstance(records, list):
            logger.warning(
                "RemindersAdapter.discover: %s is not a JSON array; skipping",
                input_path,
            )
            return

        for record in records:
            if not isinstance(record, dict):
                continue
            yield RawNote(
                source_path=input_path,
                element=None,
                raw_id=_record_id(record),
                extras={"record": record},
            )

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        """Map one Reminder record onto a normalised ParsedNote.

        Returns None for an empty/malformed record (no title), mirroring
        the other adapters' skip-empties behaviour. ``ostler_fda/
        reminders.py`` already drops title-less rows at extraction, so this
        is a defensive second check, not the primary filter.
        """
        record = raw.extras.get("record") if raw.extras else None
        if not isinstance(record, dict):
            return None

        title = (record.get("title") or "").strip()
        if not title:
            return None

        tags: list[str] = []
        list_name = record.get("list_name")
        if list_name:
            tags.append(f"list:{list_name}")
        if record.get("is_completed"):
            tags.append("completed")
        if record.get("is_flagged"):
            tags.append("flagged")

        content = _record_content(record)

        return ParsedNote(
            title=title,
            content=content,
            content_html=content,  # Reminders body is plain text; no separate HTML
            created=_parse_iso(record.get("creation_date")),
            updated=_parse_iso(record.get("completion_date")) if record.get("is_completed") else None,
            tags=tags,
            evernote_guid=_record_id(record),  # synthetic id; see module docstring
        )
