"""Extract call history (phone and FaceTime) from macOS CallHistory.storedata.

macOS stores calls (including iPhone calls relayed to the Mac and FaceTime
calls) in a Core Data SQLite database at:

    ~/Library/Application Support/CallHistoryDB/CallHistory.storedata

Table ``ZCALLRECORD`` (columns this reader uses):

    Z_PK              integer primary key
    ZUNIQUE_ID        text, Apple's stable id for the call (optional)
    ZDATE             real, Mac absolute time (seconds since 2001-01-01 UTC)
    ZDURATION         real, seconds
    ZORIGINATED       integer, 1 = the owner placed the call, 0 = received
    ZANSWERED         integer, 1 = the call was picked up
    ZCALLTYPE         integer, 1 = phone, 8 = FaceTime video, 16 = FaceTime audio
    ZADDRESS          blob, the number or Apple ID, UTF-8 bytes
    ZSERVICE_PROVIDER text, e.g. com.apple.Telephony / com.apple.FaceTime

Requires Full Disk Access (FDA) on macOS Sequoia+.

PRIVACY AND SAFETY
  * Metadata only: who (the address), when, direction, duration, kind,
    missed. There is no audio in this database and nothing here reads any.
    ZNAME (the name Apple cached for the number) is deliberately NOT read: a
    name comes from the owner's contact graph, never from a call log.
  * Apple's database is never written. The three files (storedata, -wal,
    -shm) are COPIED into a private temp directory, the copy is queried, and
    the copy is deleted in ``finally``. Opening the original in place would
    risk a lock or a WAL checkpoint against a file this process does not own;
    ``immutable=1`` on the original would ignore the WAL and silently miss the
    newest calls, so a copy is the one route that sees both safely.
  * A schema this reader does not recognise raises
    :class:`CallHistorySchemaError`. It never returns an empty list: "the
    table changed" and "no calls" must not print identically.
  * A call whose address is empty (a withheld number) or undecodable cannot be
    matched to anyone and is counted in ``skipped``, never dropped silently.
  * An unknown ZCALLTYPE becomes kind ``other`` and is counted, never dropped.
"""
from __future__ import annotations

import hashlib
import logging
import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Mac absolute time epoch offset (2001-01-01 to 1970-01-01)
MAC_EPOCH_OFFSET = 978307200

DEFAULT_CALL_DB = (
    Path.home() / "Library" / "Application Support" / "CallHistoryDB"
    / "CallHistory.storedata"
)

REQUIRED_COLUMNS = frozenset({
    "ZDATE", "ZDURATION", "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZADDRESS",
})

KIND_PHONE = "phone"
KIND_FACETIME_VIDEO = "facetime_video"
KIND_FACETIME_AUDIO = "facetime_audio"
KIND_OTHER = "other"
KINDS = (KIND_PHONE, KIND_FACETIME_VIDEO, KIND_FACETIME_AUDIO, KIND_OTHER)

_CALLTYPE_KIND = {
    1: KIND_PHONE,
    8: KIND_FACETIME_VIDEO,
    16: KIND_FACETIME_AUDIO,
}

DIRECTION_INCOMING = "incoming"
DIRECTION_OUTGOING = "outgoing"


class CallHistorySchemaError(RuntimeError):
    """The database is readable but is not the schema this reader knows."""


@dataclass
class CallEvent:
    """One call. Metadata only."""
    event_id: str          # stable, opaque (sha256); never contains the number
    address: str           # normalised: +digits, digits or lower-case email
    when: datetime         # UTC
    direction: str         # incoming | outgoing
    duration_s: int
    kind: str              # phone | facetime_video | facetime_audio | other
    answered: bool
    missed: bool           # incoming and not answered


@dataclass
class CallExtract:
    """Events plus the counts of what could not become an event."""
    events: list
    skipped_no_address: int = 0
    skipped_future: int = 0
    unknown_kind: int = 0


_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+$")


def normalise_address(raw: str) -> str:
    """Normalise a call address to the form identifiers are stored in.

    An email is lower-cased. A phone keeps a leading ``+`` and its digits
    only. Anything else is returned stripped; the caller decides.
    """
    s = (raw or "").strip()
    if not s:
        return ""
    if _EMAIL_RE.match(s):
        return s.lower()
    digits = re.sub(r"\D", "", s)
    if not digits:
        return s
    return ("+" if s.startswith("+") else "") + digits


def _event_id(unique_id: Optional[str], pk: int, ts: float, address: str,
              originated: int) -> str:
    basis = unique_id if unique_id else f"pk:{pk}|{ts!r}|{address}|{originated}"
    return hashlib.sha256(("call|" + basis).encode("utf-8")).hexdigest()


def _to_utc(mac_seconds: float) -> datetime:
    return datetime.fromtimestamp(mac_seconds + MAC_EPOCH_OFFSET, tz=timezone.utc)


def _copy_db(db_path: Path, dest_dir: Path) -> Path:
    """Copy storedata (+ -wal, -shm if present) into ``dest_dir``."""
    target = dest_dir / db_path.name
    shutil.copy2(db_path, target)
    for suffix in ("-wal", "-shm"):
        side = db_path.with_name(db_path.name + suffix)
        if side.exists():
            shutil.copy2(side, dest_dir / (db_path.name + suffix))
    return target


def _open_copy(db_path: Path, work: Path) -> sqlite3.Connection:
    try:
        copy = _copy_db(db_path, work)
    except PermissionError as e:
        raise PermissionError(
            "Cannot read call history. Grant Full Disk Access to this "
            "application in System Settings > Privacy & Security."
        ) from e
    try:
        conn = sqlite3.connect(str(copy))
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read call history. Grant Full Disk Access to this "
                "application in System Settings > Privacy & Security."
            ) from e
        raise
    conn.row_factory = sqlite3.Row
    return conn


def _check_schema(conn: sqlite3.Connection) -> set:
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(ZCALLRECORD)")}
    if not cols:
        raise CallHistorySchemaError("ZCALLRECORD table not found in call history")
    missing = REQUIRED_COLUMNS - cols
    if missing:
        raise CallHistorySchemaError(
            "ZCALLRECORD is missing column(s): " + ", ".join(sorted(missing))
        )
    return cols


def _decode_address(blob) -> str:
    if blob is None:
        return ""
    if isinstance(blob, (bytes, bytearray, memoryview)):
        try:
            text = bytes(blob).decode("utf-8")
        except UnicodeDecodeError:
            return ""
    else:
        text = str(blob)
    return normalise_address(text.replace("\x00", ""))


def extract_calls(
    db_path: Optional[Path] = None,
    since_days: Optional[int] = None,
    since: Optional[datetime] = None,
    until: Optional[datetime] = None,
    now: Optional[datetime] = None,
) -> CallExtract:
    """Read calls from CallHistory.storedata.

    Args:
        db_path: Default ~/Library/Application Support/CallHistoryDB/CallHistory.storedata
        since_days: only calls newer than N days ago (ignored if ``since`` given)
        since: only calls strictly after this instant (exclusive)
        until: only calls at or before this instant (inclusive)
        now: clock, injectable for tests

    Raises:
        PermissionError: Full Disk Access not granted.
        FileNotFoundError: the database does not exist.
        CallHistorySchemaError: the schema is not the one this reader knows.
    """
    db_path = Path(db_path) if db_path else DEFAULT_CALL_DB
    if not db_path.exists():
        raise FileNotFoundError(f"Call history not found at {db_path}")
    now = now or datetime.now(timezone.utc)
    if since is None and since_days is not None:
        since = datetime.fromtimestamp(now.timestamp() - since_days * 86400,
                                       tz=timezone.utc)

    work = Path(tempfile.mkdtemp(prefix="ostler-calls-"))
    work.chmod(0o700)
    try:
        conn = _open_copy(db_path, work)
        try:
            cols = _check_schema(conn)
            sel_uid = "ZUNIQUE_ID" if "ZUNIQUE_ID" in cols else "NULL"
            sql = (
                f"SELECT Z_PK AS pk, {sel_uid} AS uid, ZDATE, ZDURATION, "
                "ZORIGINATED, ZANSWERED, ZCALLTYPE, ZADDRESS "
                "FROM ZCALLRECORD WHERE ZDATE IS NOT NULL"
            )
            params: list = []
            if since is not None:
                sql += " AND ZDATE > ?"
                params.append(since.timestamp() - MAC_EPOCH_OFFSET)
            if until is not None:
                sql += " AND ZDATE <= ?"
                params.append(until.timestamp() - MAC_EPOCH_OFFSET)
            sql += " ORDER BY ZDATE DESC, Z_PK DESC"
            rows = conn.execute(sql, params).fetchall()
        finally:
            conn.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)

    out = CallExtract(events=[])
    for row in rows:
        address = _decode_address(row["ZADDRESS"])
        if not address:
            out.skipped_no_address += 1
            continue
        when = _to_utc(row["ZDATE"])
        if when > now:
            out.skipped_future += 1
            continue
        originated = 1 if row["ZORIGINATED"] else 0
        answered = bool(row["ZANSWERED"])
        kind = _CALLTYPE_KIND.get(row["ZCALLTYPE"])
        if kind is None:
            kind = KIND_OTHER
            out.unknown_kind += 1
        direction = DIRECTION_OUTGOING if originated else DIRECTION_INCOMING
        out.events.append(CallEvent(
            event_id=_event_id(row["uid"], row["pk"], row["ZDATE"], address,
                               originated),
            address=address,
            when=when,
            direction=direction,
            duration_s=max(0, int(row["ZDURATION"] or 0)),
            kind=kind,
            answered=answered,
            missed=(not originated) and (not answered),
        ))
    logger.info("Extracted %d call events (%d without an address, %d future)",
                len(out.events), out.skipped_no_address, out.skipped_future)
    return out


def oldest_call(db_path: Optional[Path] = None) -> Optional[datetime]:
    """The oldest call the database still holds, or None if it holds none.

    Raises like :func:`extract_calls` when the database cannot be read, so a
    caller never mistakes "unreadable" for "empty".
    """
    db_path = Path(db_path) if db_path else DEFAULT_CALL_DB
    if not db_path.exists():
        raise FileNotFoundError(f"Call history not found at {db_path}")
    work = Path(tempfile.mkdtemp(prefix="ostler-calls-"))
    work.chmod(0o700)
    try:
        conn = _open_copy(db_path, work)
        try:
            _check_schema(conn)
            row = conn.execute(
                "SELECT MIN(ZDATE) AS d FROM ZCALLRECORD WHERE ZDATE IS NOT NULL"
            ).fetchone()
        finally:
            conn.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if row is None or row["d"] is None:
        return None
    return _to_utc(row["d"])


def to_interaction_events(events: list) -> list[dict]:
    """JSON-ready dicts for the people-graph ingest (``ingest_calls``)."""
    return [
        {
            "type": "call",
            "event_id": e.event_id,
            "address": e.address,
            "timestamp": e.when.isoformat(),
            "direction": e.direction,
            "duration_seconds": e.duration_s,
            "kind": e.kind,
            "answered": e.answered,
            "missed": e.missed,
            "source": "call_history",
        }
        for e in events
    ]


def call_stats(extract: CallExtract) -> dict:
    """Counts for the extract summary and the Doctor row."""
    by_kind = {k: 0 for k in KINDS}
    missed = 0
    for e in extract.events:
        by_kind[e.kind] += 1
        if e.missed:
            missed += 1
    return {
        "total_calls": len(extract.events),
        "missed": missed,
        "by_kind": by_kind,
        "unique_contacts": len({e.address for e in extract.events}),
        "skipped_no_address": extract.skipped_no_address,
        "skipped_future": extract.skipped_future,
        "unknown_kind": extract.unknown_kind,
    }
