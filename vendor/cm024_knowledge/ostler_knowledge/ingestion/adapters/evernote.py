"""EvernoteAdapter: wraps the existing ENEXParser as a KnowledgeSourceAdapter.

``discover()`` walks the input path (file or directory) for .enex files
and yields one RawNote per <note> XML element. ``parse()`` converts the
element into a normalised ParsedNote via the existing ENEXParser logic.

The ENEX-specific parsing logic stays in ``enex_parser.ENEXParser`` --
this adapter is a thin wrapper that exposes that logic through the
common KnowledgeSourceAdapter interface.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Iterator, Optional
from xml.etree import ElementTree as ET

from ..enex_parser import ENEXParser, ParsedNote
from .base import RawNote

logger = logging.getLogger(__name__)


class EvernoteAdapter:
    """Adapter for Evernote .enex export files."""

    @classmethod
    def format_name(cls) -> str:
        return "evernote"

    def __init__(self, extract_attachments: bool = True):
        self._parser = ENEXParser(extract_attachments=extract_attachments)

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        """Yield one RawNote per <note> across all .enex files under input_path.

        Accepts either a single .enex file or a directory; if a
        directory, recurses for .enex files.
        """
        input_path = Path(input_path)
        if input_path.is_file():
            files = [input_path]
        else:
            files = sorted(input_path.rglob("*.enex"))

        for enex_path in files:
            logger.debug("EvernoteAdapter.discover: scanning %s", enex_path)
            context = ET.iterparse(str(enex_path), events=("end",))
            for _event, elem in context:
                if elem.tag == "note":
                    yield RawNote(
                        source_path=enex_path,
                        element=elem,
                        raw_id=elem.findtext("guid"),
                    )

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        """Convert a RawNote (carrying an Evernote <note> XML element) into
        a normalised ParsedNote.

        Returns None if the note should be skipped (no title, no content,
        malformed, etc). Clears the underlying XML element after parsing
        to bound memory while iterating large .enex files.
        """
        if raw.element is None:
            return None
        note = self._parser._parse_note(raw.element)
        raw.element.clear()
        return note

    @property
    def stats(self) -> dict:
        """Pass-through stats from the underlying ENEXParser."""
        return self._parser.stats
