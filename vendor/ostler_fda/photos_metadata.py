"""Extract metadata from Apple Photos' database.

Apple Photos stores metadata in:
    ~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite

We extract ONLY metadata — never photo content:
- Face labels (who is in each photo, from Apple's face recognition)
- Locations (GPS coordinates, reverse-geocoded place names)
- Dates (when each photo was taken)
- Albums (user-created organisation)

Cross-referencing face labels with the PWG contact graph tells us
"You were with James in Tokyo on 14 March 2025" without ever
reading the actual photos.

Requires Full Disk Access (FDA) permission on macOS Sequoia+.
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

DEFAULT_PHOTOS_PATH = (
    Path.home() / "Pictures" / "Photos Library.photoslibrary"
    / "database" / "Photos.sqlite"
)


@dataclass
class PersonInPhotos:
    """A person recognised by Apple Photos' face detection."""
    name: str
    photo_count: int
    first_seen: Optional[datetime]
    last_seen: Optional[datetime]
    is_key_face: bool  # user-confirmed face, not just auto-detected


@dataclass
class PhotoEvent:
    """A photo with metadata for timeline integration."""
    date: datetime
    location: Optional[str]
    latitude: Optional[float]
    longitude: Optional[float]
    people: list[str]  # face labels in this photo
    album: Optional[str]


def extract_people(
    db_path: Optional[Path] = None,
) -> list[PersonInPhotos]:
    """Extract all recognised people from Photos.

    Returns people with their photo counts and date ranges.
    Only includes people that Apple Photos has labelled (either
    auto-detected or user-confirmed).

    Raises:
        PermissionError: If FDA is not granted.
    """
    db_path = db_path or DEFAULT_PHOTOS_PATH

    if not db_path.exists():
        raise FileNotFoundError(f"Photos database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Photos metadata. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    # macOS 26+ renamed the ZDETECTEDFACE foreign keys:
    #   ZPERSON  -> ZPERSONFORFACE
    #   ZASSET   -> ZASSETFORFACE
    # Probe the new schema first, fall back to the macOS 14-15 names,
    # then to the legacy ZGENERICASSET shape from older systems.
    try:
        # macOS 26+ (Tahoe): ZPERSONFORFACE / ZASSETFORFACE
        rows = conn.execute("""
            SELECT
                p.ZFULLNAME as name,
                p.ZTYPE as person_type,
                COUNT(DISTINCT df.ZASSETFORFACE) as photo_count,
                MIN(a.ZDATECREATED) as first_seen,
                MAX(a.ZDATECREATED) as last_seen
            FROM ZPERSON p
            JOIN ZDETECTEDFACE df ON df.ZPERSONFORFACE = p.Z_PK
            JOIN ZASSET a ON a.Z_PK = df.ZASSETFORFACE
            WHERE p.ZFULLNAME IS NOT NULL
              AND p.ZFULLNAME != ''
            GROUP BY p.Z_PK
            ORDER BY photo_count DESC
        """).fetchall()
    except sqlite3.OperationalError as e:
        logger.debug("macOS 26+ Photos schema failed: %s", e)
        try:
            # macOS 14-15 (Sonoma/Sequoia): ZPERSON / ZASSET
            rows = conn.execute("""
                SELECT
                    p.ZFULLNAME as name,
                    p.ZTYPE as person_type,
                    COUNT(DISTINCT df.ZASSET) as photo_count,
                    MIN(a.ZDATECREATED) as first_seen,
                    MAX(a.ZDATECREATED) as last_seen
                FROM ZPERSON p
                JOIN ZDETECTEDFACE df ON df.ZPERSON = p.Z_PK
                JOIN ZASSET a ON a.Z_PK = df.ZASSET
                WHERE p.ZFULLNAME IS NOT NULL
                  AND p.ZFULLNAME != ''
                GROUP BY p.Z_PK
                ORDER BY photo_count DESC
            """).fetchall()
        except sqlite3.OperationalError as e2:
            logger.debug("macOS 14-15 Photos schema failed: %s", e2)
            # Legacy schema: ZGENERICASSET + ZDISPLAYNAME
            try:
                rows = conn.execute("""
                    SELECT
                        p.ZDISPLAYNAME as name,
                        1 as person_type,
                        COUNT(DISTINCT df.ZASSET) as photo_count,
                        MIN(a.ZDATECREATED) as first_seen,
                        MAX(a.ZDATECREATED) as last_seen
                    FROM ZPERSON p
                    JOIN ZDETECTEDFACE df ON df.ZPERSON = p.Z_PK
                    JOIN ZGENERICASSET a ON a.Z_PK = df.ZASSET
                    WHERE p.ZDISPLAYNAME IS NOT NULL
                      AND p.ZDISPLAYNAME != ''
                    GROUP BY p.Z_PK
                    ORDER BY photo_count DESC
                """).fetchall()
            except sqlite3.OperationalError:
                logger.error("Photos schema not recognised on this macOS version")
                conn.close()
                return []

    conn.close()

    people = []
    for row in rows:
        first = None
        last = None
        if row["first_seen"]:
            first = datetime.fromtimestamp(
                row["first_seen"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )
        if row["last_seen"]:
            last = datetime.fromtimestamp(
                row["last_seen"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )

        people.append(PersonInPhotos(
            name=row["name"],
            photo_count=row["photo_count"],
            first_seen=first,
            last_seen=last,
            # Type 1 = user-confirmed, Type 0 = auto-detected
            is_key_face=(row["person_type"] == 1),
        ))

    logger.info("Found %d named people in Photos", len(people))
    return people


def extract_photo_events(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    with_people_only: bool = True,
) -> list[PhotoEvent]:
    """Extract photo events for timeline integration.

    Args:
        db_path: Path to Photos.sqlite.
        since_days: Only extract from last N days.
        with_people_only: Only include photos that have recognised faces.

    Returns:
        List of PhotoEvent objects for timeline display.
    """
    db_path = db_path or DEFAULT_PHOTOS_PATH

    if not db_path.exists():
        raise FileNotFoundError(f"Photos database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Photos metadata. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    cutoff_mac = (
        datetime.now(timezone.utc).timestamp() - (since_days * 86400)
    ) - MAC_EPOCH_OFFSET

    # Schema probe identical to extract_people: macOS 26+ FK names
    # first (ZASSETFORFACE / ZPERSONFORFACE), then macOS 14-15
    # (ZASSET / ZPERSON), then the very-old ZGENERICASSET layout.
    rows = None
    try:
        # macOS 26+ (Tahoe). ZREVERSELOCATIONDATA moved out of ZASSET
        # into ZADDITIONALASSETATTRIBUTES; we drop location_data here
        # rather than add another join (location parsing is a v1.0.1
        # follow-on anyway, TODO at line 252).
        query = """
            SELECT
                a.ZDATECREATED as date,
                a.ZLATITUDE as lat,
                a.ZLONGITUDE as lon,
                NULL as location_data,
                GROUP_CONCAT(DISTINCT p.ZFULLNAME) as people
            FROM ZASSET a
            LEFT JOIN ZDETECTEDFACE df ON df.ZASSETFORFACE = a.Z_PK
            LEFT JOIN ZPERSON p ON p.Z_PK = df.ZPERSONFORFACE
            WHERE a.ZDATECREATED > ?
              AND a.ZTRASHEDSTATE = 0
        """
        if with_people_only:
            query += " AND p.ZFULLNAME IS NOT NULL"
        query += " GROUP BY a.Z_PK ORDER BY a.ZDATECREATED DESC"
        rows = conn.execute(query, (cutoff_mac,)).fetchall()
    except sqlite3.OperationalError as e:
        logger.debug("macOS 26+ photo events schema failed: %s", e)

    if rows is None:
        try:
            # macOS 14-15 (Sonoma/Sequoia)
            query = """
                SELECT
                    a.ZDATECREATED as date,
                    a.ZLATITUDE as lat,
                    a.ZLONGITUDE as lon,
                    a.ZREVERSELOCATIONDATA as location_data,
                    GROUP_CONCAT(DISTINCT p.ZFULLNAME) as people
                FROM ZASSET a
                LEFT JOIN ZDETECTEDFACE df ON df.ZASSET = a.Z_PK
                LEFT JOIN ZPERSON p ON p.Z_PK = df.ZPERSON
                WHERE a.ZDATECREATED > ?
                  AND a.ZTRASHEDSTATE = 0
            """
            if with_people_only:
                query += " AND p.ZFULLNAME IS NOT NULL"
            query += " GROUP BY a.Z_PK ORDER BY a.ZDATECREATED DESC"
            rows = conn.execute(query, (cutoff_mac,)).fetchall()
        except sqlite3.OperationalError as e:
            logger.debug("macOS 14-15 photo events schema failed: %s", e)

    if rows is None:
        try:
            # Legacy ZGENERICASSET layout
            query = """
                SELECT
                    a.ZDATECREATED as date,
                    a.ZLATITUDE as lat,
                    a.ZLONGITUDE as lon,
                    NULL as location_data,
                    GROUP_CONCAT(DISTINCT p.ZDISPLAYNAME) as people
                FROM ZGENERICASSET a
                LEFT JOIN ZDETECTEDFACE df ON df.ZASSET = a.Z_PK
                LEFT JOIN ZPERSON p ON p.Z_PK = df.ZPERSON
                WHERE a.ZDATECREATED > ?
                  AND a.ZTRASHEDSTATE = 0
            """
            if with_people_only:
                query += " AND p.ZDISPLAYNAME IS NOT NULL"
            query += " GROUP BY a.Z_PK ORDER BY a.ZDATECREATED DESC"
            rows = conn.execute(query, (cutoff_mac,)).fetchall()
        except sqlite3.OperationalError as e:
            logger.error("Photo events schema not recognised: %s", e)
            conn.close()
            return []

    conn.close()

    events = []
    for row in rows:
        date = datetime.fromtimestamp(
            (row["date"] or 0) + MAC_EPOCH_OFFSET, tz=timezone.utc
        )

        people = []
        if row["people"]:
            people = [p.strip() for p in row["people"].split(",") if p.strip()]

        events.append(PhotoEvent(
            date=date,
            location=None,  # TODO: parse ZREVERSELOCATIONDATA (plist blob)
            latitude=row["lat"] if row["lat"] and row["lat"] != 0 else None,
            longitude=row["lon"] if row["lon"] and row["lon"] != 0 else None,
            people=people,
            album=None,  # TODO: join with ZALBUM table
        ))

    logger.info("Extracted %d photo events", len(events))
    return events
