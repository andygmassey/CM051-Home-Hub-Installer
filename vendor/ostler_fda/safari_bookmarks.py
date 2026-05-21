"""Extract bookmarks from Safari's Bookmarks.plist.

Safari stores bookmarks in a binary plist at:
    ~/Library/Safari/Bookmarks.plist

This is a nested structure with folders (Reading List, Favourites,
user folders) containing bookmark entries with URLs and titles.

Bookmarks are strong interest signals — the user deliberately saved
these pages, unlike history which includes incidental browsing.

Requires Full Disk Access (FDA) on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import plistlib
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

DEFAULT_BOOKMARKS_PATH = Path.home() / "Library" / "Safari" / "Bookmarks.plist"


@dataclass
class Bookmark:
    """A single Safari bookmark."""
    title: str
    url: str
    domain: str
    folder: str  # e.g. "Favourites", "Reading List", "AI Research"


def _walk_bookmarks(node: dict, folder: str = "Root") -> list[Bookmark]:
    """Recursively walk the plist tree extracting bookmarks."""
    results = []
    node_type = node.get("WebBookmarkType", "")

    if node_type == "WebBookmarkTypeLeaf":
        # This is a bookmark
        url = node.get("URLString", "")
        title = node.get("URIDictionary", {}).get("title", "")

        if url and url.startswith(("http://", "https://")):
            try:
                domain = urlparse(url).netloc.lower()
            except Exception:
                domain = ""

            results.append(Bookmark(
                title=title or url,
                url=url,
                domain=domain,
                folder=folder,
            ))

    elif node_type == "WebBookmarkTypeList":
        # This is a folder — recurse into children
        folder_name = node.get("Title", folder)
        # Use human-readable names for special folders
        if folder_name == "com.apple.ReadingList":
            folder_name = "Reading List"
        elif folder_name == "BookmarksBar":
            folder_name = "Favourites"
        elif folder_name == "BookmarksMenu":
            folder_name = "Bookmarks Menu"

        for child in node.get("Children", []):
            results.extend(_walk_bookmarks(child, folder_name))

    return results


def extract_bookmarks(
    plist_path: Optional[Path] = None,
) -> list[Bookmark]:
    """Extract all bookmarks from Safari.

    Returns:
        List of Bookmark objects.

    Raises:
        PermissionError: If FDA is not granted.
    """
    plist_path = plist_path or DEFAULT_BOOKMARKS_PATH

    if not plist_path.exists():
        raise FileNotFoundError(f"Safari bookmarks not found at {plist_path}")

    try:
        with open(plist_path, "rb") as f:
            data = plistlib.load(f)
    except PermissionError:
        raise PermissionError(
            "Cannot read Safari bookmarks. Grant Full Disk Access."
        )

    bookmarks = _walk_bookmarks(data)

    logger.info(
        "Extracted %d bookmarks from Safari (%d folders)",
        len(bookmarks),
        len(set(b.folder for b in bookmarks)),
    )
    return bookmarks


def reading_list(bookmarks: list[Bookmark]) -> list[Bookmark]:
    """Filter to just Reading List items — things the user saved to read."""
    return [b for b in bookmarks if b.folder == "Reading List"]


def top_bookmark_domains(bookmarks: list[Bookmark], limit: int = 30) -> list[tuple[str, int]]:
    """Most-bookmarked domains — strong interest signals."""
    counts: dict[str, int] = {}
    for b in bookmarks:
        counts[b.domain] = counts.get(b.domain, 0) + 1
    return sorted(counts.items(), key=lambda x: x[1], reverse=True)[:limit]
