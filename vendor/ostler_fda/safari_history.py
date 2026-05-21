"""Extract browsing history from Safari's History.db.

Safari stores history in a SQLite database at:
    ~/Library/Safari/History.db

Tables:
    history_items: URLs with unique IDs
    history_visits: individual visits with timestamps

The timestamp format is "Mac absolute time" – seconds since
2001-01-01 00:00:00 UTC. Add 978307200 to convert to Unix epoch.

Requires Full Disk Access (FDA) permission on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

# Mac absolute time epoch offset (2001-01-01 to 1970-01-01)
MAC_EPOCH_OFFSET = 978307200

DEFAULT_HISTORY_PATH = Path.home() / "Library" / "Safari" / "History.db"

# Domains to skip (not useful for knowledge graph)
SKIP_DOMAINS = {
    "localhost", "127.0.0.1", "0.0.0.0",
    "about:blank", "about:newtab",
}

# Domains that are navigation/infrastructure, not content
INFRA_DOMAINS = {
    "www.google.com", "google.com",
    "www.bing.com", "bing.com",
    "duckduckgo.com",
    "search.yahoo.com",
    "t.co",  # Twitter redirects
}


@dataclass
class HistoryEntry:
    """A single browsing history entry."""
    url: str
    domain: str
    title: Optional[str]
    visit_time: datetime
    visit_count: int
    redirect_source: Optional[str] = None


@dataclass
class DomainStats:
    """Aggregated stats for a domain."""
    domain: str
    total_visits: int
    first_visit: datetime
    last_visit: datetime
    unique_urls: int


def extract_history(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    min_visits: int = 1,
) -> list[HistoryEntry]:
    """Extract browsing history entries from Safari.

    Args:
        db_path: Path to History.db. Default: ~/Library/Safari/History.db
        since_days: Only extract entries from the last N days. Default: 365.
        min_visits: Minimum visit count to include. Default: 1.

    Returns:
        List of HistoryEntry objects, most recent first.

    Raises:
        PermissionError: If FDA is not granted.
        FileNotFoundError: If History.db doesn't exist.
    """
    db_path = db_path or DEFAULT_HISTORY_PATH

    if not db_path.exists():
        raise FileNotFoundError(f"Safari history not found at {db_path}")

    try:
        # Open read-only to avoid any risk of corruption
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Safari history. Grant Full Disk Access to "
                "this application in System Settings > Privacy & Security."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    # Calculate the Mac absolute time for our since_days cutoff
    now_unix = datetime.now(timezone.utc).timestamp()
    cutoff_mac = (now_unix - (since_days * 86400)) - MAC_EPOCH_OFFSET

    try:
        rows = conn.execute("""
            SELECT
                hi.url,
                hi.visit_count,
                hv.visit_time,
                hv.title,
                hv.redirect_source
            FROM history_items hi
            JOIN history_visits hv ON hi.id = hv.history_item
            WHERE hv.visit_time > ?
              AND hi.visit_count >= ?
            ORDER BY hv.visit_time DESC
        """, (cutoff_mac, min_visits)).fetchall()
    except sqlite3.OperationalError as e:
        logger.error("Failed to query Safari history: %s", e)
        conn.close()
        return []

    conn.close()

    entries = []
    for row in rows:
        url = row["url"]

        # Parse domain
        try:
            parsed = urlparse(url)
            domain = parsed.netloc.lower()
        except Exception:
            continue

        # Skip non-content URLs (strip port for comparison)
        domain_no_port = domain.split(":")[0]
        if not domain or domain_no_port in SKIP_DOMAINS:
            continue
        if parsed.scheme not in ("http", "https"):
            continue

        # Convert Mac absolute time to datetime
        visit_unix = row["visit_time"] + MAC_EPOCH_OFFSET
        visit_dt = datetime.fromtimestamp(visit_unix, tz=timezone.utc)

        entries.append(HistoryEntry(
            url=url,
            domain=domain,
            title=row["title"],
            visit_time=visit_dt,
            visit_count=row["visit_count"],
            redirect_source=row["redirect_source"],
        ))

    logger.info("Extracted %d history entries from Safari", len(entries))
    return entries


def top_domains(
    entries: list[HistoryEntry],
    limit: int = 50,
    exclude_infra: bool = True,
) -> list[DomainStats]:
    """Aggregate history entries by domain, sorted by visit count.

    Args:
        entries: List from extract_history().
        limit: Max domains to return.
        exclude_infra: Skip search engines and redirect services.

    Returns:
        List of DomainStats, most-visited first.
    """
    domain_data: dict[str, dict] = {}

    for entry in entries:
        if exclude_infra and entry.domain in INFRA_DOMAINS:
            continue

        if entry.domain not in domain_data:
            domain_data[entry.domain] = {
                "total_visits": 0,
                "first_visit": entry.visit_time,
                "last_visit": entry.visit_time,
                "urls": set(),
            }

        d = domain_data[entry.domain]
        d["total_visits"] += 1
        d["urls"].add(entry.url)
        if entry.visit_time < d["first_visit"]:
            d["first_visit"] = entry.visit_time
        if entry.visit_time > d["last_visit"]:
            d["last_visit"] = entry.visit_time

    stats = [
        DomainStats(
            domain=domain,
            total_visits=data["total_visits"],
            first_visit=data["first_visit"],
            last_visit=data["last_visit"],
            unique_urls=len(data["urls"]),
        )
        for domain, data in domain_data.items()
    ]

    stats.sort(key=lambda s: s.total_visits, reverse=True)
    return stats[:limit]


def to_timeline_entries(entries: list[HistoryEntry]) -> list[dict]:
    """Convert history entries to timeline-compatible format for the
    Ostler timeline view.

    Returns list of dicts ready for the PWG gateway.
    """
    return [
        {
            "type": "web_visit",
            "timestamp": entry.visit_time.isoformat(),
            "url": entry.url,
            "domain": entry.domain,
            "title": entry.title,
            "visit_count": entry.visit_count,
            "source": "safari_history",
        }
        for entry in entries
    ]
