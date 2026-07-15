"""Extract bookmarks + Reading List from Safari's Bookmarks.plist.

Safari stores bookmarks in a binary plist at:
    ~/Library/Safari/Bookmarks.plist

This is a nested tree of folders (Reading List, Favourites, the
bookmarks menu, user folders) containing leaf entries with URLs and
titles. Reading List items live in the ``com.apple.ReadingList``
folder and carry extra metadata: a ``ReadingList`` dict with
``DateAdded`` (when the user saved it) and ``PreviewText`` (the first
slab of article text Safari cached for offline reading).

Bookmarks are strong interest signals -- the user deliberately saved
these pages, unlike history which includes incidental browsing. The
Reading List is an even stronger "I mean to read this" signal.

Two source labels are emitted so the wiki Reading + Browsing wings can
tell a saved-to-read item from a plain bookmark:
    safari_bookmarks      -- a normal bookmark (any folder)
    safari_reading_list   -- a Reading List item (saved to read later)

The path is overridable via the ``OSTLER_SAFARI_BOOKMARKS_PATH``
environment variable (default: the standard location above) so the
installer / tests can point at a fixture.

Requires Full Disk Access (FDA) on macOS Sequoia+.

Stdlib only -- ``plistlib`` parses the binary plist; ``uuid`` makes the
stable per-record id so a re-run upserts in place rather than
duplicating rows downstream (same idempotency contract as
safari_history's browsing path).
"""
from __future__ import annotations

import logging
import os
import plistlib
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

DEFAULT_BOOKMARKS_PATH = Path.home() / "Library" / "Safari" / "Bookmarks.plist"

# Operator override for the bookmarks plist location (tests / fixtures /
# a non-standard install). Mirrors the OSTLER_*_PATH overrides the other
# FDA sources expose. Read lazily in resolve_path() so a test can set it
# after import.
PATH_ENV_VAR = "OSTLER_SAFARI_BOOKMARKS_PATH"

# Record kinds. A Reading List item is a bookmark too, but we keep the
# distinction so the reader can surface "saved to read" separately.
KIND_BOOKMARK = "bookmark"
KIND_READING_LIST = "reading-list"

# Source labels emitted on the timeline dicts (the canonical FDA output
# shape -- see safari_history.to_timeline_entries). The reader keys off
# these to split the Reading wing from plain bookmarks.
SOURCE_BOOKMARK = "safari_bookmarks"
SOURCE_READING_LIST = "safari_reading_list"

# Bookmarks are personal-but-not-third-party-PII, so they sit at the
# same default privacy level as the browsing history they sit beside.
DEFAULT_PRIVACY = os.getenv("DEFAULT_PRIVACY_LEVEL", "L1")


@dataclass
class Bookmark:
    """A single Safari bookmark or Reading List item.

    The first four fields are positional + unchanged from the original
    extractor so existing callers (extract_all.py's ``asdict(b)`` dump,
    the tests, ``reading_list``/``top_bookmark_domains``) keep working.
    The rest are keyword fields with defaults -- the new Reading List
    metadata + the flattened folder path.
    """
    title: str
    url: str
    domain: str
    folder: str  # the immediate folder, e.g. "Reading List", "AI Research"
    kind: str = KIND_BOOKMARK  # KIND_BOOKMARK | KIND_READING_LIST
    path: str = ""  # full folder path, e.g. "Favourites / AI Research"
    date_added: Optional[str] = None  # ISO-8601; Reading List items only
    preview_text: str = ""  # cached article preview; Reading List only


def resolve_path(plist_path: Optional[Path] = None) -> Path:
    """Resolve the bookmarks plist path.

    Precedence: explicit ``plist_path`` arg > ``OSTLER_SAFARI_BOOKMARKS_PATH``
    env var > the standard ``~/Library/Safari/Bookmarks.plist``.
    """
    if plist_path is not None:
        return plist_path
    env = os.environ.get(PATH_ENV_VAR, "").strip()
    if env:
        return Path(env).expanduser()
    return DEFAULT_BOOKMARKS_PATH


# Special-folder display names. Safari stores these under opaque
# identifiers; map them to the names a human recognises.
_SPECIAL_FOLDER_NAMES = {
    "com.apple.ReadingList": "Reading List",
    "BookmarksBar": "Favourites",
    "BookmarksMenu": "Bookmarks Menu",
}


def _folder_display_name(node: dict, fallback: str) -> str:
    """Human-readable name for a folder node."""
    raw = node.get("Title", fallback)
    return _SPECIAL_FOLDER_NAMES.get(raw, raw)


def _parse_reading_list_date(value: object) -> Optional[str]:
    """Normalise a Reading List ``DateAdded`` to an ISO-8601 string.

    Safari writes ``DateAdded`` as a plist ``<date>`` which plistlib
    decodes to a (usually timezone-naive, UTC) ``datetime``. Some older
    exports carry a string instead. Returns ``None`` for anything
    unparseable rather than guessing.
    """
    if isinstance(value, datetime):
        dt = value
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()
    if isinstance(value, str) and value.strip():
        try:
            dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.isoformat()
        except ValueError:
            return None
    return None


def _walk_bookmarks(
    node: dict,
    folder: str = "Root",
    path_parts: Optional[tuple[str, ...]] = None,
) -> list[Bookmark]:
    """Recursively walk the plist tree extracting bookmarks.

    ``folder`` is the immediate parent folder name (kept for backward
    compatibility with the original signature + callers). ``path_parts``
    accumulates the full ancestry so each leaf carries a flattened
    "A / B / C" folder path. A node is classed as a Reading List item if
    it carries a ``ReadingList`` dict or sits anywhere under the
    Reading List folder.
    """
    if path_parts is None:
        path_parts = ()
    results: list[Bookmark] = []
    node_type = node.get("WebBookmarkType", "")

    if node_type == "WebBookmarkTypeLeaf":
        url = node.get("URLString", "")
        title = (node.get("URIDictionary", {}) or {}).get("title", "")

        if url and url.startswith(("http://", "https://")):
            try:
                domain = urlparse(url).netloc.lower()
            except Exception:
                domain = ""

            rl = node.get("ReadingList")
            in_reading_list_folder = "Reading List" in path_parts or folder == "Reading List"
            is_reading_list = isinstance(rl, dict) or in_reading_list_folder

            date_added = None
            preview_text = ""
            if isinstance(rl, dict):
                date_added = _parse_reading_list_date(rl.get("DateAdded"))
                preview_text = (rl.get("PreviewText") or "").strip()

            results.append(Bookmark(
                title=title or url,
                url=url,
                domain=domain,
                folder=folder,
                kind=KIND_READING_LIST if is_reading_list else KIND_BOOKMARK,
                path=" / ".join(path_parts),
                date_added=date_added,
                preview_text=preview_text,
            ))

    elif node_type == "WebBookmarkTypeList":
        folder_name = _folder_display_name(node, folder)
        # The synthetic "Root" wrapper is not a real folder -- don't let
        # it pollute the path. Every real folder contributes one segment.
        child_path = path_parts if folder_name == "Root" else path_parts + (folder_name,)
        for child in node.get("Children", []):
            if isinstance(child, dict):
                results.extend(_walk_bookmarks(child, folder_name, child_path))

    return results


def extract_bookmarks(
    plist_path: Optional[Path] = None,
) -> list[Bookmark]:
    """Extract all bookmarks + Reading List items from Safari.

    Args:
        plist_path: Override the plist location. If ``None``, falls back
            to ``OSTLER_SAFARI_BOOKMARKS_PATH`` then the standard path.

    Returns:
        List of :class:`Bookmark` (bookmarks and Reading List items).

    Raises:
        FileNotFoundError: If the plist does not exist.
        PermissionError: If FDA is not granted.
    """
    plist_path = resolve_path(plist_path)

    if not plist_path.exists():
        raise FileNotFoundError(f"Safari bookmarks not found at {plist_path}")

    try:
        with open(plist_path, "rb") as f:
            data = plistlib.load(f)
    except PermissionError:
        raise PermissionError(
            "Cannot read Safari bookmarks. Grant Full Disk Access to this "
            "application in System Settings > Privacy & Security."
        )

    bookmarks = _walk_bookmarks(data)

    logger.info(
        "Extracted %d bookmarks from Safari (%d in Reading List, %d folders)",
        len(bookmarks),
        sum(1 for b in bookmarks if b.kind == KIND_READING_LIST),
        len(set(b.folder for b in bookmarks)),
    )
    return bookmarks


def reading_list(bookmarks: list[Bookmark]) -> list[Bookmark]:
    """Filter to just Reading List items -- things the user saved to read.

    Matches on ``kind`` (set during the walk for any item with Reading
    List metadata or under the Reading List folder) and, for backward
    compatibility, the old folder-name heuristic.
    """
    return [
        b for b in bookmarks
        if b.kind == KIND_READING_LIST or b.folder == "Reading List"
    ]


def top_bookmark_domains(bookmarks: list[Bookmark], limit: int = 30) -> list[tuple[str, int]]:
    """Most-bookmarked domains -- strong interest signals."""
    counts: dict[str, int] = {}
    for b in bookmarks:
        counts[b.domain] = counts.get(b.domain, 0) + 1
    return sorted(counts.items(), key=lambda x: x[1], reverse=True)[:limit]


def _stable_id(url: str, kind: str) -> str:
    """Deterministic id for a bookmark/reading-list record.

    Keyed on url + kind so a re-run upserts the same row in place
    (idempotent re-install) and a URL that is both a bookmark and a
    Reading List item stays two distinct records. Mirrors the
    ``browsing|...`` id scheme in pwg_ingest.ingest_browser_history.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"bookmark|{kind}|{url}"))


def to_timeline_entries(bookmarks: list[Bookmark]) -> list[dict]:
    """Convert bookmarks to the canonical FDA timeline-dict shape.

    Same shape the other on-device sources emit (see
    safari_history.to_timeline_entries): a list of plain dicts the
    pwg_ingest layer / readers consume. Reading List items carry their
    save-date as ``timestamp`` (the strongest signal we have for "when
    did this enter your world"); plain bookmarks have no reliable date
    so ``timestamp`` is empty.

    Extra fields beyond the browsing contract:
        id            -- stable, url+kind derived (idempotent upsert)
        kind          -- "bookmark" | "reading-list"
        path          -- flattened folder path ("A / B / C")
        preview_text  -- cached article preview (Reading List only)
        privacy_level -- defaults to L1
    """
    entries: list[dict] = []
    for b in bookmarks:
        is_rl = b.kind == KIND_READING_LIST
        source = SOURCE_READING_LIST if is_rl else SOURCE_BOOKMARK
        timestamp = b.date_added or ""
        entries.append({
            "type": "bookmark",
            "id": _stable_id(b.url, b.kind),
            "timestamp": timestamp,
            "url": b.url,
            "domain": b.domain,
            "title": b.title,
            "kind": b.kind,
            "folder": b.folder,
            "path": b.path,
            "preview_text": b.preview_text,
            "source": source,
            "privacy_level": DEFAULT_PRIVACY,
        })
    return entries


def _build_parser():
    import argparse

    parser = argparse.ArgumentParser(
        prog="ostler-safari-bookmarks",
        description=(
            "Extract Safari bookmarks + Reading List from Bookmarks.plist "
            "into the canonical FDA timeline-dict shape. On-device, "
            "stdlib only."
        ),
    )
    parser.add_argument(
        "--plist-path",
        type=Path,
        default=None,
        help=(
            "Override the Bookmarks.plist location. Defaults to "
            f"${PATH_ENV_VAR} then ~/Library/Safari/Bookmarks.plist."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the extracted records as JSON to stdout.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Parse + report counts only; emit no record bodies "
            "(no URLs/titles cross the process boundary)."
        ),
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    """Self-contained CLI for the extract leg.

    ``--dry-run`` prints a counts-only status line (mirrors the privacy
    contract of the other extractors: no URLs/titles leak). ``--json``
    prints the full timeline records. With neither flag it prints a
    human summary. The ingest/upsert leg stays in pwg_ingest, matching
    the extract_all / pwg_ingest split.

    Exit codes: 0 = success or graceful skip (no plist / FDA pending);
    2 = argparse failure.
    """
    import json as _json
    import sys

    parser = _build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    try:
        bookmarks = extract_bookmarks(plist_path=args.plist_path)
    except FileNotFoundError:
        logger.info("[skip] Safari Bookmarks: Bookmarks.plist not found")
        if args.json:
            print(_json.dumps({"status": "not_found", "records": []}))
        return 0
    except PermissionError:
        logger.info("[skip] Safari Bookmarks: Full Disk Access not granted")
        if args.json:
            print(_json.dumps({"status": "no_fda", "records": []}))
        return 0

    entries = to_timeline_entries(bookmarks)
    reading = sum(1 for b in bookmarks if b.kind == KIND_READING_LIST)

    if args.dry_run:
        # Counts only -- no record bodies cross the boundary.
        payload = {
            "status": "ok",
            "bookmarks": len(bookmarks) - reading,
            "reading_list": reading,
            "total": len(bookmarks),
        }
        print(_json.dumps(payload))
        return 0

    if args.json:
        print(_json.dumps(
            {"status": "ok", "records": entries},
            indent=2,
            default=str,
        ))
        return 0

    print(
        f"Extracted {len(bookmarks)} Safari record(s): "
        f"{len(bookmarks) - reading} bookmark(s), {reading} in Reading List.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
