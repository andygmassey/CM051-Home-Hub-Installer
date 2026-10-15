"""Full-history catch-up for Google Takeout and dropped mailboxes (v1.0.108).

WHY
===
The install reads a Gmail mailbox through ``universal_import._dispatch_mbox``
with three caps that are right for a fast install and wrong as the whole
story: five years (``since_days=365 * 5``), 250,000 messages
(``_MBOX_MESSAGE_CAP``) and 20,000 threads (``_EMAIL_MAX_THREADS``). And it
only ever finds ONE mailbox: install.sh keeps the first ``takeout-*.zip`` it
sees and extracts the first ``.mbox`` member of it, so a split Takeout
(``-001.zip``, ``-002.zip``, ...) whose mailbox is in part 2, or an export with
two mailboxes, is never read at all. Nothing ever went back for the rest.

WHAT THIS DOES
==============
``adapters()`` (the catch-up factory, run by ``~/.ostler/bin/catchup.d/
70-takeout.sh`` from com.ostler.export-scan) finds EVERY Takeout part and
EVERY ``.mbox`` member in it, extracts each once, adds every mailbox the
install-time importer read (``state/catchup/mbox-queue/``), and returns one
adapter per distinct mailbox. Each adapter walks its mailbox in three phases:

1. INDEX, headers only, in bounded slices (cursor = byte offset), no date
   window and no message cap. Threads are grouped by EXACTLY the install's
   rule (``_group_email_threads``: Message-ID lineage first, else the
   normalised subject), so a thread gets the same key either way.
2. CORRESPONDENTS: the full-history ``{address: count}`` map, handed to the
   install's own sink (``_persist_mail_contacts`` -> ``ingest_mail_contacts``,
   which looks an identifier up before it creates anyone).
3. THREADS, newest first, through the install's own payload builder and sink
   (``_email_thread_to_payload`` -> ``_persist_conversations`` -> pwg-convo).

NO DUPLICATES
=============
A thread's conversation id is ``email_<first date>_<sha1(thread key)[:12]>``,
built by the install's function. If CM048 already holds a conversation for
that key hash (``processing/email_*_<hash>/``), the install sent it: it is NOT
sent again. CM048 keeps the first raw transcript of an id for ever, so the
messages the install's caps cut off (older than its ``started_at`` or newer
than its ``ended_at``, read back from that id's ``00_metadata.json``) go as
ONE continuation thread under a different key, never as a second copy of the
whole thread. Everything else is new and goes once. The catch-up ledger plus
CM048's per-id state dir make a kill at any point repeat at most one keyed
write.

EXTRACTION IS LAZY AND BOUNDED
==============================
``adapters()`` only LISTS the members of each Takeout part (no bytes are
extracted at setup, outside the time budget and the busy-machine check). A
member is extracted inside the budgeted tick, when its adapter's batch runs
(the core has already checked the budget and the busy predicate), ONE mailbox
at a time machine-wide, in 1 MiB chunks that re-check the busy predicate and a
time cap and resume from a ``.part`` file, and only if there is room for it
plus a 2 GiB margin (otherwise cannot-run, said out loud). The extracted file
is DELETED the moment its walk has consumed every thread. A mailbox the
customer put there (a loose .mbox, the install's own extraction) is read in
place and never deleted.

KEPT AS IT IS: the 4,000-character per-message body clamp
(``OSTLER_EMAIL_BODY_CHARS``). It bounds one prompt, not how far back history
goes, and the install path uses the same value.

Counts only in every log line and state file. No subjects, no addresses in
logs.
"""
from __future__ import annotations

import contextlib
import email
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional

logger = logging.getLogger(__name__)

DOCTOR_ROW = "email"
INDEX_SLICE_MESSAGES = 2000      # messages parsed per index item
THREADS_PER_BATCH = 10           # threads per dispatch batch (a model call each)
CONTACTS_PER_ITEM = 200          # addresses per people-graph item
_FROM_LINE = b"From "
_EXPORT_ID_RE = re.compile(r"^(takeout-[0-9]{8}T[0-9]{6}Z)", re.IGNORECASE)
_FREE_SPACE_MARGIN = 2 * 1024 ** 3


# ── paths (resolved per call) ────────────────────────────────────────────────

def _home() -> Path:
    for var in ("OSTLER_HOME", "OSTLER_DIR"):
        raw = os.environ.get(var, "").strip()
        if raw:
            return Path(raw).expanduser()
    return Path.home() / ".ostler"


def _catchup_state() -> Path:
    raw = os.environ.get("OSTLER_CATCHUP_STATE_DIR", "").strip()
    return Path(raw).expanduser() if raw else _home() / "state" / "catchup"


def queue_dir() -> Path:
    return _catchup_state() / "mbox-queue"


def _processing_dir() -> Path:
    for var in ("OSTLER_PROCESSING_DIR", "PWG_PROCESSING_DIR"):
        raw = os.environ.get(var, "").strip()
        if raw:
            return Path(raw).expanduser()
    return _home() / "processing"


def _user_email() -> Optional[str]:
    return os.environ.get("OSTLER_USER_EMAIL", "").strip() or None


# ── the queue the install-time importer writes ──────────────────────────────

def queue_mailbox(path: Path) -> Optional[Path]:
    """Record a mailbox the install-time importer read under its caps, so
    catch-up finishes it. A temp extraction (deleted when the import ends) is
    not queued: there would be nothing left to read."""
    try:
        p = Path(path).resolve()
        tmp = Path(tempfile.gettempdir()).resolve()
        if str(p).startswith(str(tmp) + os.sep) or not p.is_file():
            return None
        q = queue_dir()
        q.mkdir(parents=True, exist_ok=True)
        f = q / (hashlib.sha1(str(p).encode("utf-8")).hexdigest()[:16] + ".json")
        tmpf = f.with_name(f.name + ".tmp")
        tmpf.write_text(json.dumps({"path": str(p)}), encoding="utf-8")
        os.replace(tmpf, f)
        return f
    except OSError as exc:
        logger.info("catch-up: could not queue a mailbox (%s)", type(exc).__name__)
        return None


def _queued_paths() -> List[Path]:
    out = []
    try:
        files = sorted(queue_dir().glob("*.json"))
    except OSError:
        return out
    for f in files:
        try:
            p = Path(json.loads(f.read_text(encoding="utf-8"))["path"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if p.is_file():
            out.append(p)
    return out


# ── discovery: every part, every mailbox ────────────────────────────────────

def _zip_search_dirs() -> List[Path]:
    """Where Takeout parts are looked for: the folders the export watcher
    already imports from (Downloads, Downloads/Takeout), the drop zone, our
    own imports/takeout, and the folder of the Takeout the customer confirmed
    at install (OSTLER_TAKEOUT_ZIP_PATH), so its sibling parts are found."""
    home = Path(os.environ.get("OSTLER_TAKEOUT_HOME", "") or Path.home())
    dirs = [home / "Downloads", home / "Downloads" / "Takeout",
            _home() / "imports" / "preferences", _home() / "imports" / "takeout"]
    confirmed = os.environ.get("OSTLER_TAKEOUT_ZIP_PATH", "").strip()
    if confirmed:
        dirs.append(Path(confirmed).expanduser().parent)
    seen, out = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out


def find_takeout_parts(dirs: Optional[Iterable[Path]] = None) -> List[Path]:
    """Every takeout-*.zip, every part, in the search dirs (two levels deep,
    the same depth install.sh's own find uses)."""
    found = set()
    for d in (dirs if dirs is not None else _zip_search_dirs()):
        try:
            if not d.is_dir():
                continue
            for pattern in ("takeout-*.zip", "*/takeout-*.zip"):
                for z in d.glob(pattern):
                    if z.is_file():
                        found.add(z.resolve())
        except OSError:
            continue
    return sorted(found)


def _export_id(zip_path: Path) -> str:
    m = _EXPORT_ID_RE.match(zip_path.name)
    return m.group(1) if m else zip_path.stem


class ZipMember:
    """One .mbox inside a Takeout part. Listing it costs nothing; its bytes are
    extracted only when its adapter's batch runs."""

    def __init__(self, zip_path: Path, info, root: Path):
        self.zip_path = Path(zip_path)
        self.name = info.filename
        self.size = int(info.file_size)
        self.crc = int(info.CRC)
        self.export_id = _export_id(self.zip_path)
        member = Path(info.filename)
        self.ours = root / self.export_id / member
        self.installs = root / member       # install.sh 9.4's extract layout

    @property
    def identity(self) -> str:
        raw = "%s|%s|%d|%d" % (self.export_id, self.name, self.crc, self.size)
        return "zip" + hashlib.sha1(raw.encode("utf-8")).hexdigest()

    def existing(self) -> Optional[Path]:
        """A complete copy already on disk (ours, or the install's own)."""
        for p in (self.ours, self.installs):
            try:
                if p.is_file() and p.stat().st_size == self.size:
                    return p
            except OSError:
                continue
        return None


def list_zip_members(zips: Iterable[Path], dest_root: Optional[Path] = None) -> List[ZipMember]:
    """Every .mbox member of every part, LISTED and not extracted."""
    root = dest_root or (_home() / "imports" / "takeout")
    out = []
    for z in zips:
        try:
            zf = zipfile.ZipFile(z)
        except (OSError, zipfile.BadZipFile) as exc:
            logger.info("catch-up: an unreadable Takeout part was skipped (%s)", type(exc).__name__)
            continue
        with zf:
            for info in zf.infolist():
                if info.is_dir() or not info.filename.lower().endswith(".mbox"):
                    continue
                member = Path(info.filename)
                if member.is_absolute() or ".." in member.parts:
                    continue
                out.append(ZipMember(z, info, root))
    return out


_CHUNK = 1024 * 1024
_BUSY_EVERY_CHUNKS = 16


def _extract_seconds() -> float:
    raw = os.environ.get("OSTLER_CATCHUP_EXTRACT_SECONDS", "").strip()
    try:
        return max(1.0, float(raw)) if raw else 300.0
    except ValueError:
        return 300.0


def extract_member(zm: ZipMember, *, busy=None, max_seconds: Optional[float] = None,
                   clock=None) -> str:
    """Extract one member to ``zm.ours``. Returns "done", "partial" (time cap)
    or "busy" (the machine stopped being quiet); both leave a ``.part`` file the
    next call resumes. Raises oc.CannotRun when the part cannot be read or
    there is no room.

    Resume re-decompresses and discards the bytes already written (a deflate
    stream cannot be entered part-way), then appends; the stream's CRC is
    checked as it is read through, so a damaged part never becomes a mailbox."""
    import ostler_catchup as oc
    import time as _time
    clock = clock or _time.monotonic
    busy = busy or oc.busy_reason
    cap = _extract_seconds() if max_seconds is None else max_seconds
    t0 = clock()
    zm.ours.parent.mkdir(parents=True, exist_ok=True)
    part = zm.ours.with_name(zm.ours.name + ".part")
    have = part.stat().st_size if part.is_file() else 0
    if have > zm.size:
        part.unlink(missing_ok=True)
        have = 0
    if shutil.disk_usage(zm.ours.parent).free < (zm.size - have) + _FREE_SPACE_MARGIN:
        raise oc.CannotRun("no_space")
    try:
        with zipfile.ZipFile(zm.zip_path) as zf, zf.open(zm.name) as src, open(part, "ab") as dst:
            skipped = 0
            while skipped < have:
                chunk = src.read(min(_CHUNK, have - skipped))
                if not chunk:
                    raise zipfile.BadZipFile("part shorter than the bytes already extracted")
                skipped += len(chunk)
            n = 0
            while True:
                chunk = src.read(_CHUNK)
                if not chunk:
                    break
                dst.write(chunk)
                n += 1
                if n % _BUSY_EVERY_CHUNKS == 0:
                    if busy():
                        return "busy"
                    if clock() - t0 >= cap:
                        return "partial"
        os.replace(part, zm.ours)
        return "done"
    except (OSError, zipfile.BadZipFile, EOFError) as exc:
        # A damaged or vanished part: start over next time rather than resume
        # from bytes that may be wrong.
        part.unlink(missing_ok=True)
        raise oc.CannotRun("part_unreadable") from exc


def _loose_mailboxes() -> List[Path]:
    home = Path(os.environ.get("OSTLER_TAKEOUT_HOME", "") or Path.home())
    imports_takeout = _home() / "imports" / "takeout"
    roots = [home / "Downloads" / "Takeout", imports_takeout,
             _home() / "imports" / "preferences"]
    confirmed = os.environ.get("OSTLER_TAKEOUT_PATH", "").strip()
    out = []
    if confirmed and Path(confirmed).expanduser().is_file():
        out.append(Path(confirmed).expanduser())
    for r in roots:
        try:
            if r.is_dir():
                for p in r.rglob("*.mbox"):
                    if not p.is_file():
                        continue
                    if r == imports_takeout:
                        # Our own lazy extractions live under <export id>/ and
                        # are walked by their zip member's adapter, not as a
                        # second, loose mailbox.
                        rel = p.relative_to(r)
                        if rel.parts and _EXPORT_ID_RE.match(rel.parts[0]):
                            continue
                    out.append(p)
        except OSError:
            continue
    return out


def _same_as_member(path: Path, zm: ZipMember) -> bool:
    """Is this loose file the Takeout member's bytes (same size, same first
    64 KiB)? A cheap test that needs no extraction, so a copy of a mailbox the
    importer already read is not walked a second time under a second identity."""
    try:
        if path.stat().st_size != zm.size:
            return False
        with open(path, "rb") as fh:
            head = fh.read(65536)
        with zipfile.ZipFile(zm.zip_path) as zf, zf.open(zm.name) as src:
            return src.read(65536) == head
    except (OSError, zipfile.BadZipFile, EOFError):
        return False


def mailbox_identity(path: Path) -> str:
    """Content identity, so one mailbox found at two paths (the install's
    extraction and ours, or a queue entry) is walked once."""
    h = hashlib.sha1()
    size = path.stat().st_size
    h.update(str(size).encode())
    with open(path, "rb") as fh:
        h.update(fh.read(65536))
        if size > 131072:
            fh.seek(size - 65536)
            h.update(fh.read(65536))
    return h.hexdigest()


# ── mbox framing, the same rule as mailbox.mbox ─────────────────────────────

def scan_boundaries(path: Path, start: int, max_messages: int):
    """(offsets, next_offset, eof): up to max_messages (start, stop) pairs of
    messages beginning at or after ``start``. Mirrors mailbox.mbox's table of
    contents: every line starting with ``From `` opens a message, and the
    blank line before it belongs to neither."""
    out = []
    with open(path, "rb") as fh:
        fh.seek(start)
        msg_start = None
        last_was_empty = False
        pos = start
        while True:
            line = fh.readline()
            if not line:
                if msg_start is not None:
                    out.append((msg_start, pos))
                return out, pos, True
            if line.startswith(_FROM_LINE):
                if msg_start is not None:
                    stop = pos - (len(b"\n") if last_was_empty else 0)
                    out.append((msg_start, stop))
                    if len(out) >= max_messages:
                        return out, pos, False
                msg_start = pos
                last_was_empty = False
            else:
                last_was_empty = line in (b"\n", b"\r\n")
            pos += len(line)


def _read_message(fh, start: int, stop: int):
    fh.seek(start)
    raw = fh.read(stop - start)
    nl = raw.find(b"\n")
    body = raw[nl + 1:] if nl >= 0 else b""
    return email.message_from_bytes(body)


def _slice_messages() -> int:
    """Messages parsed per index item (OSTLER_CATCHUP_MBOX_SLICE). Smaller
    means a kill repeats less work and the watermark moves more often."""
    raw = os.environ.get("OSTLER_CATCHUP_MBOX_SLICE", "").strip()
    try:
        return max(1, int(raw)) if raw else INDEX_SLICE_MESSAGES
    except ValueError:
        return INDEX_SLICE_MESSAGES


# ── the adapter ─────────────────────────────────────────────────────────────

class MailboxAdapter:
    doctor_row = DOCTOR_ROW
    batch_size = 25

    def __init__(self, path: Path, identity: str, zip_member: Optional[ZipMember] = None):
        self.zip_member = zip_member
        existing = zip_member.existing() if zip_member is not None else None
        self.path = Path(existing) if existing is not None else Path(path)
        self.identity = identity
        self.source = "mbox_" + identity[:10]
        self._db = None
        self._sent = None

    # lazy extraction -------------------------------------------------------
    @property
    def owned(self) -> bool:
        """True when the file at ``self.path`` is one WE extract (and so delete
        once consumed), never the customer's own or the install's copy."""
        zm = self.zip_member
        return zm is not None and self.path == zm.ours

    def _marker(self) -> Path:
        return _catchup_state() / "mbox-extracting" / self.source

    def _another_extraction_is_live(self) -> bool:
        d = _catchup_state() / "mbox-extracting"
        try:
            others = [m for m in d.iterdir() if m.name != self.source]
        except OSError:
            return False
        for m in others:
            try:
                wm = json.loads((_catchup_state() / (m.name + ".json")).read_text(encoding="utf-8"))
                finished = bool(wm.get("complete"))
            except (OSError, ValueError):
                finished = False
            try:
                stale = time.time() - m.stat().st_mtime > 7 * 86400
            except OSError:
                stale = True
            if finished or stale:
                with contextlib.suppress(OSError):
                    m.unlink()
                continue
            return True
        return False

    def _ensure_file(self, cursor):
        """None when the mailbox is ready to read, else a Batch that steps
        aside this tick. Extraction happens here, i.e. inside the budgeted tick
        after the core's busy check, one mailbox at a time."""
        import ostler_catchup as oc
        zm = self.zip_member
        if zm is None:
            return None
        found = zm.existing()
        if found is not None:
            self.path = found
            return None
        if self._another_extraction_is_live():
            return oc.Batch(items=[], next_cursor=cursor, pause=True)
        m = self._marker()
        m.parent.mkdir(parents=True, exist_ok=True)
        m.touch()
        self.path = zm.ours
        state = extract_member(zm)
        if state == "done":
            return None
        return oc.Batch(items=[], next_cursor=cursor, pause=True)

    def _release(self) -> None:
        """Every thread of this mailbox is consumed: delete what we extracted."""
        if self.owned:
            zm = self.zip_member
            for f in (zm.ours, zm.ours.with_name(zm.ours.name + ".part")):
                with contextlib.suppress(OSError):
                    f.unlink()
            root = _home() / "imports" / "takeout"
            d = zm.ours.parent
            while d != root and root in d.parents:
                try:
                    d.rmdir()
                except OSError:
                    break
                d = d.parent
        with contextlib.suppress(OSError):
            self._marker().unlink()

    # index store ---------------------------------------------------------
    def db(self) -> sqlite3.Connection:
        if self._db is None:
            p = _catchup_state() / f"{self.source}.index.sqlite"
            p.parent.mkdir(parents=True, exist_ok=True)
            db = sqlite3.connect(str(p), timeout=30)
            db.executescript(
                "CREATE TABLE IF NOT EXISTS msgs (off INTEGER PRIMARY KEY, stop INTEGER NOT NULL,"
                " key TEXT NOT NULL, epoch REAL, sent INTEGER NOT NULL);"
                "CREATE INDEX IF NOT EXISTS msgs_key ON msgs(key);"
                "CREATE TABLE IF NOT EXISTS ids (mid TEXT PRIMARY KEY, key TEXT NOT NULL);"
                "CREATE TABLE IF NOT EXISTS contacts (addr TEXT PRIMARY KEY, n INTEGER NOT NULL);"
                "CREATE TABLE IF NOT EXISTS threads (key TEXT PRIMARY KEY, newest REAL NOT NULL);")
            db.commit()
            self._db = db
        return self._db

    # contract ------------------------------------------------------------
    def start_cursor(self):
        return {"phase": "index", "off": 0}

    def key(self, item) -> str:
        kind = item[0]
        if kind == "index":
            return "index:%d" % item[1][0][0]
        if kind == "contacts":
            return "contacts:" + hashlib.sha1("\n".join(a for a, _ in item[1]).encode()).hexdigest()[:16]
        return "thread:" + hashlib.sha1(item[1].encode("utf-8")).hexdigest()[:12]

    def next_batch(self, cursor, limit):
        import ostler_catchup as oc
        cursor = cursor or self.start_cursor()
        phase = cursor.get("phase")
        if phase == "index":
            wait = self._ensure_file(cursor)
            if wait is not None:
                return wait
            per = _slice_messages()
            offs, nxt, eof = scan_boundaries(self.path, int(cursor["off"]), per * max(1, limit))
            items = [("index", offs[i:i + per]) for i in range(0, len(offs), per)]
            nc = {"phase": "contacts", "after": ""} if eof else {"phase": "index", "off": nxt}
            return oc.Batch(items=items, next_cursor=nc, oldest_at=None, exhausted=False)
        db = self.db()
        if phase == "contacts":
            rows = db.execute("SELECT addr, n FROM contacts WHERE n >= 3 AND addr > ? ORDER BY addr LIMIT ?",
                              (cursor.get("after", ""), CONTACTS_PER_ITEM * max(1, limit))).fetchall()
            if not rows:
                with db:
                    db.execute("INSERT OR IGNORE INTO threads (key, newest) SELECT key, "
                               "COALESCE(MAX(epoch), -1e18) FROM msgs GROUP BY key")
                return oc.Batch(items=[], next_cursor={"phase": "threads", "newest": 1e300, "key": ""},
                                oldest_at=None, exhausted=False)
            items = [("contacts", rows[i:i + CONTACTS_PER_ITEM])
                     for i in range(0, len(rows), CONTACTS_PER_ITEM)]
            return oc.Batch(items=items, next_cursor={"phase": "contacts", "after": rows[-1][0]},
                            oldest_at=None, exhausted=False)
        # threads, newest first, keyset (newest DESC, key ASC)
        n = min(limit, THREADS_PER_BATCH)
        rows = db.execute(
            "SELECT key, newest FROM threads WHERE newest < ? OR (newest = ? AND key > ?) "
            "ORDER BY newest DESC, key ASC LIMIT ?",
            (cursor["newest"], cursor["newest"], cursor["key"], n)).fetchall()
        if not rows:
            # Every earlier batch finished (the cursor only moves past a batch
            # whose items were all sent or quarantined), so the mailbox is
            # fully consumed. Delete what we extracted. No file access above,
            # so a kill after this and before the watermark says complete
            # re-enters here and does not re-extract.
            self._release()
            return oc.Batch(items=[], next_cursor=cursor, oldest_at=None, exhausted=True)
        wait = self._ensure_file(cursor)
        if wait is not None:
            return wait
        last_key, last_newest = rows[-1]
        oldest = oc.to_iso(last_newest) if last_newest > -1e17 else None
        # Never exhausted WITH items: the final, empty call is what proves the
        # last batch was consumed and releases the extracted file.
        return oc.Batch(items=[("thread", k) for k, _ in rows],
                        next_cursor={"phase": "threads", "newest": last_newest, "key": last_key},
                        oldest_at=oldest, exhausted=False)

    def process(self, item) -> bool:
        kind = item[0]
        if kind == "index":
            return self._index(item[1])
        if kind == "contacts":
            from .universal_import import _persist_mail_contacts
            r = _persist_mail_contacts(dict(item[1]), source="mbox_catchup")
            return r.get("persist_status") == "ok"
        return self._dispatch(item[1])

    # phase 1 -------------------------------------------------------------
    def _index(self, offsets) -> bool:
        from . import google_takeout as gt
        from .universal_import import _normalise_subject
        user = _user_email()
        db = self.db()
        with open(self.path, "rb") as fh, db:
            for start, stop in offsets:
                if db.execute("SELECT 1 FROM msgs WHERE off = ?", (start,)).fetchone():
                    continue      # this slice already committed before a kill
                try:
                    m = gt._build_message(_read_message(fh, start, stop), user_email=user,
                                          body_preview_chars=0)
                except Exception:  # noqa: BLE001 - same skip as stream_messages
                    continue
                key = None
                for parent in [m.in_reply_to, *m.references]:
                    if parent:
                        row = db.execute("SELECT key FROM ids WHERE mid = ?", (parent,)).fetchone()
                        if row:
                            key = row[0]
                            break
                if key is None:
                    key = _normalise_subject(m.subject)
                epoch = None
                if m.date is not None:
                    d = m.date if m.date.tzinfo else m.date.replace(tzinfo=timezone.utc)
                    epoch = d.timestamp()
                db.execute("INSERT INTO msgs (off, stop, key, epoch, sent) VALUES (?, ?, ?, ?, ?)",
                           (start, stop, key, epoch, 1 if m.is_sent else 0))
                if m.message_id:
                    db.execute("INSERT OR REPLACE INTO ids (mid, key) VALUES (?, ?)", (m.message_id, key))
                addrs = [a for a in m.to_addresses if a] if m.is_sent else (
                    [m.from_address] if m.from_address else [])
                for a in addrs:
                    db.execute("INSERT INTO contacts (addr, n) VALUES (?, 1) "
                               "ON CONFLICT(addr) DO UPDATE SET n = n + 1", (a,))
        return True

    # phase 3 -------------------------------------------------------------
    def _install_sent(self, key_hash: str) -> Optional[dict]:
        """CM048's metadata for the conversation the install sent for this
        thread, {} if sent but unreadable, None if never sent."""
        if self._sent is None:
            # One listing per run, not one per thread: a glob per thread over a
            # directory of tens of thousands of conversations is quadratic.
            self._sent = {}
            try:
                for d in sorted(_processing_dir().glob("email_*_*")):
                    self._sent.setdefault(d.name.rsplit("_", 1)[-1], d)
            except OSError:
                pass
        hit = self._sent.get(key_hash)
        if hit is None:
            return None
        try:
            return json.loads((hit / "00_metadata.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _dispatch(self, key: str) -> bool:
        from . import google_takeout as gt
        from . import universal_import as ui
        key_hash = hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]
        sent = self._install_sent(key_hash)
        user = _user_email()
        body_chars = ui._email_body_chars()
        rows = self.db().execute("SELECT off, stop FROM msgs WHERE key = ? ORDER BY off", (key,)).fetchall()
        msgs = []
        with open(self.path, "rb") as fh:
            for start, stop in rows:
                try:
                    m = gt._build_message(_read_message(fh, start, stop), user_email=user,
                                          body_preview_chars=body_chars)
                except Exception:  # noqa: BLE001
                    continue
                msgs.append(ui._EmailMessage(
                    message_id=m.message_id or "", from_address=m.from_address or "",
                    from_name=m.from_name or "", to_addresses=list(m.to_addresses or []),
                    subject=m.subject or "", date=m.date, body=m.body_preview or "",
                    is_sent=bool(m.is_sent), in_reply_to=m.in_reply_to or "",
                    references=list(m.references or [])))
        if not msgs:
            return True
        thread_key = key
        if sent is not None:
            # The install sent this thread. Only what its caps cut off goes,
            # as one continuation, never the whole thread a second time.
            lo, hi = _parse_iso(sent.get("started_at")), _parse_iso(sent.get("ended_at"))
            if lo is None or hi is None:
                # The install sent this thread but its metadata is unreadable,
                # so which messages it cut off cannot be known. Returning True
                # marked the thread done and its capped messages were never
                # sent. Fail instead: the core retries it, then quarantines it
                # and counts it where the Doctor shows it.
                logger.info("catch-up mbox: an installed thread's metadata is unreadable; not done")
                return False

            def _outside(m):
                if m.date is None:
                    return False
                d = m.date if m.date.tzinfo else m.date.replace(tzinfo=timezone.utc)
                return d < lo or d > hi
            msgs = [m for m in msgs if _outside(m)]
            if not msgs:
                return True
            thread_key = key + "#catchup"
        thread = ui._EmailThread(key=thread_key, subject=msgs[0].subject or "(no subject)")
        for m in msgs:
            thread.messages.append(m)
            for a in [m.from_address, *m.to_addresses]:
                if a and a.lower() != (user or "").lower():
                    thread.participants.add(a)
        payload = ui._email_thread_to_payload(thread, user_email=user)
        payload["metadata"]["privacy_level"] = ui._EMAIL_PRIVACY_LEVEL
        r = ui._persist_conversations([payload], source="email_mbox_catchup")
        return r.get("persisted") == 1


def _parse_iso(v) -> Optional[datetime]:
    if not v:
        return None
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


# ── the factory ──────────────────────────────────────────────────────────────

def adapters() -> list:
    """One adapter per distinct mailbox found right now. Runs at every tick,
    so a Takeout dropped next month is found next month. Nothing is extracted
    here: Takeout members are only listed (see EXTRACTION IS LAZY AND BOUNDED)."""
    out, claimed, seen = [], set(), set()
    for zm in list_zip_members(find_takeout_parts()):
        for p in (zm.ours, zm.installs):
            claimed.add(p)
        if zm.identity in seen:
            continue
        seen.add(zm.identity)
        out.append(MailboxAdapter(zm.ours, zm.identity, zip_member=zm))
    zms = [a.zip_member for a in out]
    loose = []
    for p in (_loose_mailboxes() + _queued_paths()):
        if p in claimed or any(_same_as_member(p, zm) for zm in zms):
            continue
        loose.append(p)
    by_identity = {}
    for p in loose:
        try:
            ident = mailbox_identity(p)
        except OSError:
            continue
        by_identity.setdefault(ident, p)
    out += [MailboxAdapter(p, ident) for ident, p in sorted(by_identity.items())]
    logger.info("catch-up takeout: %d mailbox(es) found", len(out))
    return out
