"""Extract reminders from macOS Reminders database.

macOS Reminders stores data in a CoreData SQLite database. The path
varies by macOS version:

    macOS 15 (Sequoia) and later (sandboxed Group Container):
        ~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/

    macOS 14 (Sonoma) and earlier (legacy non-sandboxed):
        ~/Library/Reminders/Container_v1/Stores/

The database uses the CoreData schema with tables like
ZREMCDREMINDER for individual reminders and ZREMCDCALENDARLIST
for reminder lists.

Requires Full Disk Access (FDA) on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

MAC_EPOCH_OFFSET = 978307200

# Reminders database lives inside a Container_v1/Stores directory.
# The actual .sqlite file name varies, but there's usually one.
# macOS 15+ (Sequoia) moved the store inside a sandboxed Group
# Container; the legacy non-sandboxed path remains as a fallback
# for older macOS versions.
DEFAULT_REMINDERS_DIR_SEQUOIA = (
    Path.home() / "Library" / "Group Containers"
    / "group.com.apple.reminders" / "Container_v1" / "Stores"
)

DEFAULT_REMINDERS_DIR_LEGACY = (
    Path.home() / "Library" / "Reminders" / "Container_v1" / "Stores"
)

# Public default kept for backwards compatibility with callers that
# referenced DEFAULT_REMINDERS_DIR directly. Resolved at lookup time.
DEFAULT_REMINDERS_DIR = DEFAULT_REMINDERS_DIR_SEQUOIA


@dataclass
class Reminder:
    """A single reminder/task."""
    title: str
    is_completed: bool
    due_date: Optional[datetime]
    completion_date: Optional[datetime]
    creation_date: Optional[datetime]
    priority: int  # 0 = none, 1 = high, 5 = medium, 9 = low
    notes: Optional[str]
    list_name: Optional[str]
    is_flagged: bool


def _find_reminders_db(search_dir: Optional[Path] = None) -> Path:
    """Locate the Reminders SQLite database.

    Apple doesn't use a fixed filename, so we search for .sqlite
    files in the Stores directory.

    Probes the macOS 15+ Group Container path first, then falls back
    to the legacy non-sandboxed path for macOS 14 and earlier.
    """
    # Caller-supplied dir wins (tests + explicit overrides).
    if search_dir is not None:
        candidate_dirs = [search_dir]
    else:
        # New path FIRST so macOS 15+ customers find data; older Macs
        # fall through to the legacy path.
        candidate_dirs = [
            DEFAULT_REMINDERS_DIR_SEQUOIA,
            DEFAULT_REMINDERS_DIR_LEGACY,
        ]

    chosen_dir: Optional[Path] = None
    for d in candidate_dirs:
        if d.exists():
            chosen_dir = d
            break

    if chosen_dir is None:
        raise FileNotFoundError(
            "Reminders directory not found. Tried: "
            + ", ".join(str(d) for d in candidate_dirs)
        )

    # Look for .sqlite files (not -wal or -shm)
    candidates = list(chosen_dir.glob("*.sqlite"))
    if not candidates:
        # Also check one level deeper
        candidates = list(chosen_dir.glob("*/*.sqlite"))

    if not candidates:
        raise FileNotFoundError(
            f"No Reminders database found in {chosen_dir}"
        )

    # If multiple, pick the largest (most likely the active one).
    # macOS 15 keeps multiple per-account stores (Data-<UUID>.sqlite)
    # alongside a Data-local.sqlite; largest is the most populated.
    candidates.sort(key=lambda p: p.stat().st_size, reverse=True)
    return candidates[0]


def extract_reminders(
    db_path: Optional[Path] = None,
    include_completed: bool = True,
    since_days: Optional[int] = None,
) -> list[Reminder]:
    """Extract reminders from the macOS Reminders database.

    Args:
        db_path: Path to the Reminders SQLite database. Auto-detected if None.
        include_completed: Whether to include completed reminders.
        since_days: Only include reminders created in the last N days. None = all.

    Returns:
        List of Reminder objects.
    """
    if db_path is None:
        db_path = _find_reminders_db()

    if not db_path.exists():
        raise FileNotFoundError(f"Reminders database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Reminders data. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    # Build WHERE clause
    conditions = []
    params: list = []

    if not include_completed:
        conditions.append("r.ZCOMPLETED = 0")

    if since_days is not None:
        cutoff_mac = (
            datetime.now(timezone.utc).timestamp()
            - MAC_EPOCH_OFFSET
            - (since_days * 86400)
        )
        conditions.append("r.ZCREATIONDATE > ?")
        params.append(cutoff_mac)

    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    # Try the main schema (macOS Ventura+)
    try:
        rows = conn.execute(f"""
            SELECT
                r.ZTITLE1 as title,
                r.ZCOMPLETED as is_completed,
                r.ZDUEDATE as due_date,
                r.ZCOMPLETIONDATE as completion_date,
                r.ZCREATIONDATE as creation_date,
                r.ZPRIORITY as priority,
                r.ZNOTES as notes,
                r.ZFLAGGED as is_flagged,
                cl.ZTITLE as list_name
            FROM ZREMCDREMINDER r
            LEFT JOIN ZREMCDCALENDARLIST cl
                ON r.ZLIST = cl.Z_PK
            {where}
            ORDER BY r.ZCREATIONDATE DESC
        """, params).fetchall()
    except sqlite3.OperationalError:
        # Try alternative column names (older macOS)
        try:
            rows = conn.execute(f"""
                SELECT
                    r.ZTITLE as title,
                    r.ZCOMPLETED as is_completed,
                    r.ZDUEDATE as due_date,
                    r.ZCOMPLETIONDATE as completion_date,
                    r.ZCREATIONDATE as creation_date,
                    r.ZPRIORITY as priority,
                    r.ZNOTES as notes,
                    r.ZFLAGGED as is_flagged,
                    NULL as list_name
                FROM ZREMCDREMINDER r
                {where}
                ORDER BY r.ZCREATIONDATE DESC
            """, params).fetchall()
        except sqlite3.OperationalError as e:
            logger.error("Reminders schema not recognised: %s", e)
            conn.close()
            return []

    conn.close()

    reminders = []
    for row in rows:
        title = row["title"]
        if not title:
            continue  # Skip blank reminders

        due = None
        if row["due_date"]:
            due = datetime.fromtimestamp(
                row["due_date"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )

        completion = None
        if row["completion_date"]:
            completion = datetime.fromtimestamp(
                row["completion_date"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )

        creation = None
        if row["creation_date"]:
            creation = datetime.fromtimestamp(
                row["creation_date"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )

        reminders.append(Reminder(
            title=title,
            is_completed=bool(row["is_completed"]),
            due_date=due,
            completion_date=completion,
            creation_date=creation,
            priority=row["priority"] or 0,
            notes=row["notes"],
            list_name=row["list_name"],
            is_flagged=bool(row["is_flagged"]),
        ))

    logger.info("Extracted %d reminders", len(reminders))
    return reminders


def reminder_stats(reminders: list[Reminder]) -> dict:
    """Compute summary statistics for extracted reminders."""
    completed = sum(1 for r in reminders if r.is_completed)
    pending = len(reminders) - completed
    flagged = sum(1 for r in reminders if r.is_flagged)
    lists = set(r.list_name for r in reminders if r.list_name)

    overdue = 0
    now = datetime.now(timezone.utc)
    for r in reminders:
        if not r.is_completed and r.due_date and r.due_date < now:
            overdue += 1

    return {
        "total_reminders": len(reminders),
        "completed": completed,
        "pending": pending,
        "flagged": flagged,
        "overdue": overdue,
        "lists": len(lists),
        "list_names": sorted(lists),
    }
