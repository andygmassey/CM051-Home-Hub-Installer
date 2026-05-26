"""Extract browsing history from Chrome's History sqlite.

Chrome stores history at:
    ~/Library/Application Support/Google/Chrome/Default/History

Tables:
    urls:   id, url, title, visit_count, last_visit_time
    visits: id, url (FK to urls.id), visit_time, transition, ...

Timestamps use WebKit time -- microseconds since 1601-01-01 UTC.
Convert to Unix epoch with: ``(chrome_ts / 1_000_000) - 11644473600``.

Lock-during-running pattern
---------------------------

Chrome holds an exclusive write lock on the History file while running.
A naive ``sqlite3.connect`` would fail with "database is locked" even
in ``mode=ro``, because Chrome's WAL coordinator does not yield to
read-only opens cleanly. Workaround: copy the file (and the matching
``-wal`` / ``-shm`` sidecars if present) to a tempdir first, then read
from there. This is the same pattern Chrome forensic tooling uses
(extracting-without-disturbing-the-running-browser is a stable problem).

The copy is small (Chrome rotates History at ~25MB) and read-only, so
it carries no risk of corrupting the customer's running Chrome session.

FDA required: ``~/Library/`` is gated by Full Disk Access on macOS
Sequoia+, same TCC grant iMessage + Safari + WhatsApp use.
"""
from __future__ import annotations

import logging
import shutil
import sqlite3
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

# WebKit / Chrome epoch offset (1601-01-01 UTC -> 1970-01-01 UTC), seconds.
CHROME_EPOCH_OFFSET = 11644473600

DEFAULT_HISTORY_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Google"
    / "Chrome"
    / "Default"
    / "History"
)

# Domains to skip (mirrors safari_history.py to keep the two extractors
# emitting comparable JSON for downstream pwg_ingest).
SKIP_DOMAINS = {
    "localhost", "127.0.0.1", "0.0.0.0",
    "about:blank", "about:newtab", "chrome://newtab",
}

INFRA_DOMAINS = {
    "www.google.com", "google.com",
    "www.bing.com", "bing.com",
    "duckduckgo.com",
    "search.yahoo.com",
    "t.co",
}


@dataclass
class HistoryEntry:
    """A single browsing history entry.

    Same shape as safari_history.HistoryEntry so the JSON written by
    each extractor is interchangeable from the pwg_ingest perspective.
    """
    url: str
    domain: str
    title: Optional[str]
    visit_time: datetime
    visit_count: int
    redirect_source: Optional[str] = None


@dataclass
class DomainStats:
    """Aggregated stats for a domain (mirrors safari_history shape)."""
    domain: str
    total_visits: int
    first_visit: datetime
    last_visit: datetime
    unique_urls: int


@contextmanager
def _copy_history_db(source: Path) -> Iterator[Path]:
    """Copy Chrome's History (+ WAL sidecars if present) to a tempdir.

    Chrome holds an exclusive lock while running, which would block a
    direct ``sqlite3.connect(..., mode=ro)``. The copy-first pattern
    is standard for non-disruptive Chrome history extraction.

    Yields:
        Path to the copied History file (in a tempdir that auto-cleans).

    The tempdir is removed when the context exits, even on exception,
    so we never leave a partial copy on disk.
    """
    with tempfile.TemporaryDirectory(prefix="chrome-history-") as tmp:
        tmp_path = Path(tmp) / "History"
        # Copy with copy2 -> preserve mtime/atime so the source
        # mtime is observable downstream if anyone correlates with
        # file metadata; ``copy`` would touch mtime.
        shutil.copy2(source, tmp_path)
        # Copy the -wal + -shm sidecars too. They live next to
        # History and contain uncommitted transactions; missing them
        # is the most common reason "the rows we just visited aren't
        # there" appears in forensic extractions. Skip silently if
        # they don't exist (older Chrome / Chrome quit cleanly).
        for sidecar in (source.with_name(source.name + "-wal"),
                        source.with_name(source.name + "-shm")):
            if sidecar.exists():
                shutil.copy2(sidecar, Path(tmp) / sidecar.name)
        yield tmp_path


def _convert_timestamp(chrome_ts: Optional[int]) -> Optional[datetime]:
    """Convert a Chrome WebKit timestamp to a tz-aware datetime.

    Visits inserted via the ``visits.visit_time`` column carry
    microseconds-since-1601 in INTEGER form. Rows with 0 (never
    visited via a ``visits`` row -- typed only) and NULL are
    surfaced as None so the caller can skip them.
    """
    if chrome_ts is None or chrome_ts == 0:
        return None
    unix_ts = (chrome_ts / 1_000_000) - CHROME_EPOCH_OFFSET
    try:
        return datetime.fromtimestamp(unix_ts, tz=timezone.utc)
    except (OSError, ValueError):
        # Defensive: corrupt rows / negative timestamps -> drop.
        return None


def extract_history(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    min_visits: int = 1,
) -> list[HistoryEntry]:
    """Extract browsing history entries from Chrome.

    Args:
        db_path: Override the default ``History`` path (tests pass a
            fixture path; install-time uses the default).
        since_days: Only return entries whose last visit_time is
            within the last N days. Default mirrors safari_history.py
            (365). Override via ``OSTLER_BROWSER_BACKFILL_DAYS`` env
            at the extract_all.py layer.
        min_visits: Drop URLs whose ``urls.visit_count`` is below
            this threshold. Default 1 to match Safari.

    Returns:
        List of HistoryEntry, most-recent visit first.

    Raises:
        PermissionError: FDA not granted.
        FileNotFoundError: Chrome History not present (Chrome not
            installed on this Mac).
    """
    db_path = Path(db_path) if db_path else DEFAULT_HISTORY_PATH
    if not db_path.exists():
        raise FileNotFoundError(
            f"Chrome history not found at {db_path}. "
            "Install Google Chrome and visit at least one page, then re-run."
        )

    # Calculate cutoff in Chrome time. Chrome time uses microseconds
    # since 1601, so the cutoff is a large integer; comparing in the
    # WHERE clause keeps the query index-driven via visits_url_index +
    # visits.visit_time monotonicity.
    now_unix = datetime.now(timezone.utc).timestamp()
    cutoff_unix = now_unix - (since_days * 86400)
    cutoff_chrome = int((cutoff_unix + CHROME_EPOCH_OFFSET) * 1_000_000)

    with _copy_history_db(db_path) as tmp_path:
        try:
            conn = sqlite3.connect(f"file:{tmp_path}?mode=ro", uri=True)
        except sqlite3.OperationalError as exc:
            msg = str(exc).lower()
            if "authorization denied" in msg or "permission" in msg:
                raise PermissionError(
                    "Cannot read Chrome history. Grant Full Disk Access "
                    "(System Settings > Privacy & Security > Full Disk Access)."
                ) from exc
            raise

        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                """
                SELECT
                    u.url,
                    u.title,
                    u.visit_count,
                    v.visit_time,
                    v.from_visit
                FROM urls u
                JOIN visits v ON v.url = u.id
                WHERE v.visit_time > ?
                  AND u.visit_count >= ?
                ORDER BY v.visit_time DESC
                """,
                (cutoff_chrome, min_visits),
            ).fetchall()
        except sqlite3.OperationalError as exc:
            logger.error("Failed to query Chrome history: %s", exc)
            conn.close()
            return []
        conn.close()

    entries: list[HistoryEntry] = []
    for row in rows:
        url = row["url"]
        try:
            parsed = urlparse(url)
            domain = parsed.netloc.lower()
        except Exception:
            continue
        domain_no_port = domain.split(":")[0]
        if not domain or domain_no_port in SKIP_DOMAINS:
            continue
        if parsed.scheme not in ("http", "https"):
            continue
        visit_dt = _convert_timestamp(row["visit_time"])
        if visit_dt is None:
            continue
        # `redirect_source` keeps the same nullable shape as safari's
        # equivalent. Chrome's `from_visit` is an int FK; we surface
        # whether it's non-zero so downstream consumers can treat
        # redirect chains identically across browsers.
        redirect_source = (
            f"chrome_visit_{row['from_visit']}" if row["from_visit"] else None
        )
        entries.append(HistoryEntry(
            url=url,
            domain=domain,
            title=row["title"],
            visit_time=visit_dt,
            visit_count=row["visit_count"],
            redirect_source=redirect_source,
        ))

    logger.info("Extracted %d history entries from Chrome", len(entries))
    return entries


def top_domains(
    entries: list[HistoryEntry],
    limit: int = 50,
    exclude_infra: bool = True,
) -> list[DomainStats]:
    """Aggregate Chrome history entries by domain.

    Same signature + semantics as ``safari_history.top_domains`` so a
    caller iterating both sources can use a single helper.
    """
    domain_data: dict[str, dict] = {}

    for entry in entries:
        if exclude_infra and entry.domain in INFRA_DOMAINS:
            continue
        bucket = domain_data.setdefault(entry.domain, {
            "total_visits": 0,
            "first_visit": entry.visit_time,
            "last_visit": entry.visit_time,
            "urls": set(),
        })
        bucket["total_visits"] += 1
        bucket["urls"].add(entry.url)
        if entry.visit_time < bucket["first_visit"]:
            bucket["first_visit"] = entry.visit_time
        if entry.visit_time > bucket["last_visit"]:
            bucket["last_visit"] = entry.visit_time

    stats = [
        DomainStats(
            domain=d,
            total_visits=v["total_visits"],
            first_visit=v["first_visit"],
            last_visit=v["last_visit"],
            unique_urls=len(v["urls"]),
        )
        for d, v in domain_data.items()
    ]
    stats.sort(key=lambda s: s.total_visits, reverse=True)
    return stats[:limit]


def to_timeline_entries(entries: list[HistoryEntry]) -> list[dict]:
    """Convert Chrome history entries to gateway-compatible payloads.

    Mirrors ``safari_history.to_timeline_entries`` so the
    ``source`` field is the only difference between the two
    extractors' downstream JSON.
    """
    return [
        {
            "type": "web_visit",
            "timestamp": entry.visit_time.isoformat(),
            "url": entry.url,
            "domain": entry.domain,
            "title": entry.title,
            "visit_count": entry.visit_count,
            "source": "chrome_history",
        }
        for entry in entries
    ]
