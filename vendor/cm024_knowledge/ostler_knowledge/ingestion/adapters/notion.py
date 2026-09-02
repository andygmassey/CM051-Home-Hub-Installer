"""NotionAdapter: ingest a Notion Markdown + CSV export.

Notion's "Export all workspace content" with format "Markdown & CSV"
produces a tree where each page is a ``.md`` file. Page filenames
embed a 32-hex page UUID suffix, e.g.::

    My First Page abc12345abc12345abc12345abc12345.md

Sub-pages live in a subdirectory of the same UUID-suffixed name.
Internal links rewrite to relative paths with the UUID preserved.
Databases ship as ``.csv`` files (one per database). Image assets
live in per-page subdirectories.

This adapter accepts either:

- a path to the ``.zip`` Notion produces (extracted to a tempdir),
- a path to a pre-unzipped directory containing the tree.

``discover()`` yields one RawNote per ``.md`` file. ``parse()`` strips
the 32-hex UUID suffix from the title and emits a normalised
ParsedNote.

Out of scope for this adapter:

- CSV-database conversion. The brief earmarks these for a follow-up
  pass; for now non-``.md`` files are skipped by ``discover()`` with a
  debug log.
- Image-asset copying. The downstream markdown_writer is the right
  place to walk the per-page assets; the adapter passes the raw
  markdown content through verbatim so image references resolve
  relative to the source path.
- Internal-link rewriting. Brief calls this out for the downstream
  pipeline; the adapter records the source path + UUID so a downstream
  step can build the UUID -> slug table once across all pages.
"""
from __future__ import annotations

import logging
import re
import tempfile
import zipfile
from pathlib import Path
from typing import Iterator, Optional

from ..enex_parser import ParsedNote
from .base import RawNote

logger = logging.getLogger(__name__)


# Notion appends a 32-hex page UUID before the ``.md`` extension, joined
# to the page title by a single space. Capture the UUID for raw_id and
# the cleaned title via title-without-suffix.
NOTION_UUID_RE = re.compile(r"\s+([0-9a-fA-F]{32})$")


def _extract_zip_to_tempdir(zip_path: Path) -> Path:
    """Extract a Notion export zip to a tempdir and return that dir.

    Caller is responsible for cleanup; the directory is left in place
    so the adapter can stream RawNotes out of it without prematurely
    deleting the source files.
    """
    tmp = Path(tempfile.mkdtemp(prefix="notion-export-"))
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(tmp)
    return tmp


def _strip_uuid_suffix(name_without_ext: str) -> tuple[str, Optional[str]]:
    """Return (cleaned_title, uuid_or_None) from a Notion filename stem.

    Notion writes ``<title> <32hex>``; strip the suffix for the title
    and surface the UUID separately as the source ID.
    """
    m = NOTION_UUID_RE.search(name_without_ext)
    if not m:
        return name_without_ext, None
    uuid = m.group(1).lower()
    title = name_without_ext[: m.start()].rstrip()
    return title, uuid


class NotionAdapter:
    """Adapter for Notion Markdown + CSV workspace exports."""

    @classmethod
    def format_name(cls) -> str:
        return "notion"

    def __init__(self) -> None:
        # Set by discover() when the input is a zip; subsequent parse()
        # calls share the same extracted tree.
        self._extracted_root: Optional[Path] = None

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        """Yield one RawNote per .md page across the Notion export.

        Accepts a .zip file or a directory. Non-.md files (CSVs, images)
        are skipped at the discover layer; the adapter focuses on the
        page-content path. CSV / image handling is a follow-up.
        """
        input_path = Path(input_path)
        if input_path.is_file() and input_path.suffix.lower() == ".zip":
            logger.debug("NotionAdapter.discover: unzipping %s", input_path)
            root = _extract_zip_to_tempdir(input_path)
            self._extracted_root = root
        elif input_path.is_dir():
            root = input_path
        else:
            raise ValueError(
                f"NotionAdapter input must be a .zip file or a directory: {input_path}"
            )

        for md_path in sorted(root.rglob("*.md")):
            yield RawNote(
                source_path=md_path,
                element=None,
                raw_id=_strip_uuid_suffix(md_path.stem)[1],
                extras={"vault_root": root},
            )

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        """Read a Notion .md page and return a normalised ParsedNote.

        Returns None if the file is empty or unreadable. Title comes
        from the filename (Notion writes the page title there);
        UUID-suffix is stripped. Content is the verbatim file text;
        downstream link-resolution + image-asset handling will rewrite
        references later.
        """
        if raw.source_path is None or not raw.source_path.exists():
            return None

        try:
            text = raw.source_path.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            logger.warning("NotionAdapter.parse: failed to read %s: %s", raw.source_path, e)
            return None

        if not text.strip():
            return None

        title, _uuid = _strip_uuid_suffix(raw.source_path.stem)
        return ParsedNote(
            title=title,
            content=text,
            content_html=text,
            evernote_guid=raw.raw_id,  # repurposed as generic source ID for now
        )
