"""ObsidianAdapter: ingest an Obsidian vault.

An Obsidian vault is a directory of ``.md`` files plus a ``.obsidian/``
config directory. Notes can carry YAML frontmatter, ``[[wikilinks]]``,
and inline ``#tags``. Daily notes follow the ``YYYY-MM-DD.md`` naming
convention, optionally rooted at a folder declared in
``.obsidian/daily-notes.json``.

This adapter:

- Refuses inputs that do not contain a ``.obsidian/`` directory (guards
  against pointing at the wrong dir).
- Walks the vault, skipping ``.obsidian/``, ``.trash/``, and any
  directory whose basename is ``Templates`` (Obsidian convention).
- Parses YAML frontmatter when present.
- Unions YAML ``tags:`` with inline ``#tag`` occurrences in the body.
- Records vault-relative ``original_path`` and (if available)
  ``vault_name`` via the RawNote extras for the downstream pipeline.

Out of scope:

- ``.canvas`` files. The brief explicitly defers these.
- Wikilink resolution (basename-uniqueness disambiguation). The
  adapter records ``[[targets]]`` it sees but leaves resolution to a
  downstream cross-page pass once all pages are known.
- Attachment copying / image rewriting. Handled by the downstream
  markdown_writer / asset pipeline.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

import yaml

from ..enex_parser import ParsedNote
from .base import RawNote

logger = logging.getLogger(__name__)


# Directory names skipped wholesale when walking the vault. Lowercase
# match for the obsidian-internal dirs; basename-Templates is also
# skipped per Obsidian convention.
_OBSIDIAN_SKIP_DIRS = {".obsidian", ".trash"}
_OBSIDIAN_SKIP_BASENAMES = {"Templates"}


# Inline ``#tag`` recogniser. Tag must start with a letter (prevents
# matching ``#1234`` markdown anchors and YAML ``#comment`` patterns
# that aren't real tags). Allows nested tags via ``/``.
_INLINE_TAG_RE = re.compile(r"(?:^|\s)#([A-Za-z][\w/-]*)")


# Wikilink recogniser. Captures the target only; ``|alias`` and
# ``#heading`` suffixes are stripped from the captured target so the
# adapter records a clean target path. Body content is not modified
# at this layer.
_WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


# Daily-note filename: ``YYYY-MM-DD``. Optional ``YYYY-MM-DD-suffix``
# variants are not flagged as daily-notes (would require operator
# config to disambiguate).
_DAILY_NOTE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")


def _split_frontmatter(text: str) -> Tuple[Dict[str, Any], str]:
    """Return ``(yaml_dict, body)``. Empty dict if no frontmatter present.

    Obsidian frontmatter is YAML between two ``---`` lines at the very
    start of the file. Any other ``---`` line in the body is left
    untouched.
    """
    if not text.startswith("---"):
        return {}, text
    # First line is ``---``; find the next ``---`` line.
    lines = text.splitlines(keepends=True)
    if len(lines) < 2:
        return {}, text
    closing = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            closing = i
            break
    if closing is None:
        return {}, text
    yaml_text = "".join(lines[1:closing])
    body = "".join(lines[closing + 1 :])
    try:
        data = yaml.safe_load(yaml_text) or {}
        if not isinstance(data, dict):
            data = {}
    except yaml.YAMLError as e:
        logger.warning("ObsidianAdapter: YAML frontmatter parse failed: %s", e)
        data = {}
    return data, body


def _union_tags(frontmatter_tags: Any, body: str) -> List[str]:
    """Merge YAML ``tags:`` (str|list|None) with inline ``#tag``s. Dedup, preserve first-seen order."""
    seen: Dict[str, None] = {}

    def _add(tag: str) -> None:
        clean = tag.strip().lstrip("#").strip()
        if clean and clean not in seen:
            seen[clean] = None

    if isinstance(frontmatter_tags, str):
        for chunk in re.split(r"[,\s]+", frontmatter_tags):
            _add(chunk)
    elif isinstance(frontmatter_tags, list):
        for t in frontmatter_tags:
            if isinstance(t, str):
                _add(t)

    for m in _INLINE_TAG_RE.finditer(body):
        _add(m.group(1))

    return list(seen.keys())


def _detect_wikilink_targets(body: str) -> List[str]:
    """Return cleaned wikilink targets seen in body. Strips ``|alias`` and ``#heading``."""
    targets: List[str] = []
    for m in _WIKILINK_RE.finditer(body):
        inner = m.group(1).strip()
        # Cut off ``|alias`` first then ``#heading``.
        if "|" in inner:
            inner = inner.split("|", 1)[0].strip()
        if "#" in inner:
            inner = inner.split("#", 1)[0].strip()
        if inner:
            targets.append(inner)
    return targets


def _is_daily_note(stem: str, daily_root: Optional[str], vault_relative_parent: str) -> bool:
    """Match ``YYYY-MM-DD.md`` and respect the operator's daily-notes folder."""
    if not _DAILY_NOTE_RE.match(stem):
        return False
    if daily_root is None or daily_root == "":
        # No operator-configured root: treat any ``YYYY-MM-DD.md`` as a daily note.
        return True
    # Normalise both paths for comparison; daily_root in Obsidian config
    # uses forward slashes regardless of OS.
    return vault_relative_parent.replace("\\", "/").startswith(daily_root.rstrip("/"))


def _load_daily_notes_root(vault_root: Path) -> Optional[str]:
    """Return the configured daily-notes folder if Obsidian config provides one."""
    cfg = vault_root / ".obsidian" / "daily-notes.json"
    if not cfg.is_file():
        return None
    try:
        data = json.loads(cfg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    folder = data.get("folder")
    if isinstance(folder, str):
        return folder
    return None


def _parse_iso_datetime(value: Any) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        return None
    raw = value.strip().replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


class ObsidianAdapter:
    """Adapter for Obsidian vault directories."""

    @classmethod
    def format_name(cls) -> str:
        return "obsidian"

    def __init__(self) -> None:
        self._daily_root: Optional[str] = None
        self._vault_root: Optional[Path] = None

    def discover(self, input_path: Path) -> Iterator[RawNote]:
        """Yield one RawNote per ``.md`` file in the vault. Refuses non-vault dirs."""
        input_path = Path(input_path)
        if not input_path.is_dir():
            raise ValueError(
                f"ObsidianAdapter input must be a directory: {input_path}"
            )
        if not (input_path / ".obsidian").is_dir():
            raise ValueError(
                f"ObsidianAdapter input is missing .obsidian/ config: {input_path}. "
                "Point at the vault root, not a subdirectory."
            )

        self._vault_root = input_path.resolve()
        self._daily_root = _load_daily_notes_root(self._vault_root)
        vault_name = self._vault_root.name

        for md_path in self._walk_vault(self._vault_root):
            rel = md_path.relative_to(self._vault_root)
            yield RawNote(
                source_path=md_path,
                element=None,
                raw_id=None,
                extras={
                    "vault_root": self._vault_root,
                    "vault_name": vault_name,
                    "relative_path": str(rel),
                    "daily_root": self._daily_root,
                },
            )

    def parse(self, raw: RawNote) -> Optional[ParsedNote]:
        """Parse one Obsidian note into a ParsedNote."""
        if raw.source_path is None or not raw.source_path.exists():
            return None
        try:
            text = raw.source_path.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            logger.warning("ObsidianAdapter.parse: failed to read %s: %s", raw.source_path, e)
            return None
        if not text.strip():
            return None

        fm, body = _split_frontmatter(text)
        tags = _union_tags(fm.get("tags"), body)
        wikilink_targets = _detect_wikilink_targets(body)

        title = fm.get("title")
        if not isinstance(title, str) or not title.strip():
            title = raw.source_path.stem
        title = title.strip()

        created = _parse_iso_datetime(fm.get("created") or fm.get("date"))
        updated = _parse_iso_datetime(fm.get("updated") or fm.get("modified"))

        # Daily-note detection: only the filename axis is durable across
        # vaults; the operator's daily-notes folder narrows the match.
        relative_path = raw.extras.get("relative_path") or ""
        relative_parent = str(Path(relative_path).parent) if relative_path else ""
        if _is_daily_note(raw.source_path.stem, raw.extras.get("daily_root"), relative_parent):
            if "daily-note" not in tags:
                tags.append("daily-note")

        # Wikilink targets are not currently surfaced through ParsedNote
        # (no field), so they only log at debug level for now. Downstream
        # link-resolution will likely re-walk the bodies once the cross-
        # vault page table is built.
        if wikilink_targets:
            logger.debug(
                "ObsidianAdapter.parse: %s references %d wikilinks",
                raw.source_path,
                len(wikilink_targets),
            )

        return ParsedNote(
            title=title,
            content=body if fm else text,
            content_html=text,
            created=created,
            updated=updated,
            tags=tags,
        )

    @staticmethod
    def _walk_vault(vault_root: Path) -> Iterator[Path]:
        """Yield .md paths under vault_root, skipping internal + template dirs."""
        for path in sorted(vault_root.rglob("*.md")):
            rel = path.relative_to(vault_root)
            parts = rel.parts
            # Reject any path component matching the skip rules.
            skip = False
            for part in parts[:-1]:
                if part in _OBSIDIAN_SKIP_DIRS or part in _OBSIDIAN_SKIP_BASENAMES:
                    skip = True
                    break
            if skip:
                continue
            yield path
