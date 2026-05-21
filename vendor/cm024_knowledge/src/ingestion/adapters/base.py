"""KnowledgeSourceAdapter protocol + shared dataclasses.

Each adapter wraps a knowledge source (Evernote .enex, Obsidian vault,
Notion export, etc.) and produces normalised ParsedNote objects that the
downstream chunker / embedder / markdown_writer / qdrant_store consume
without knowing the source format.

The interface is intentionally minimal:

- format_name() -> str
    Short identifier for the source format (``"evernote"``, ``"obsidian"``).
- discover(input_path) -> Iterator[RawNote]
    Yield source-format-specific note handles. May walk a directory,
    parse an archive, etc.
- parse(raw) -> Optional[ParsedNote]
    Turn one RawNote into a normalised ParsedNote, or return None if
    the note should be skipped (empty, malformed, etc).

Add new adapters by:

1. Subclass / implement KnowledgeSourceAdapter in a new module under
   ``src/ingestion/adapters/<name>.py``.
2. Register the class in the ``ADAPTERS`` dict in
   ``src/ingestion/adapters/__init__.py``.

ParsedNote (the normalised shape) lives in ``src/ingestion/enex_parser.py``
for backwards-compatibility with existing imports. The adapter package
re-exports it from this module so adapter authors can write
``from src.ingestion.adapters import ParsedNote``.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator, Optional, Protocol, runtime_checkable

# Re-export ParsedNote from its existing home so adapter consumers
# import it from one place (``adapters``), regardless of where the
# implementation eventually lives.
from ..enex_parser import ParsedNote  # noqa: F401


@dataclass
class RawNote:
    """Source-format-specific note handle yielded by ``discover()``.

    Adapters fill in fields they need; ``parse()`` consumes the same
    shape and returns the normalised ParsedNote.

    Examples:
        - EvernoteAdapter populates ``source_path`` (the .enex file) and
          ``element`` (the parsed <note> XML element).
        - A future ObsidianAdapter would populate ``source_path`` (the .md
          file path) and leave ``element`` None.
    """

    source_path: Path
    element: Any = None
    raw_id: Optional[str] = None
    extras: dict = field(default_factory=dict)


@runtime_checkable
class KnowledgeSourceAdapter(Protocol):
    """Protocol for a knowledge-source adapter."""

    @classmethod
    def format_name(cls) -> str:
        ...

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        ...

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        ...
