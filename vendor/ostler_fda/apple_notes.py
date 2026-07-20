"""Extract notes from Apple Notes' NoteStore.sqlite for the KNOWLEDGE ingest.

Apple Notes (iCloud Notes) stores data in::

    ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite

This is a Core-Data-backed SQLite database. The main table is
``ZICCLOUDSYNCINGOBJECT``, which holds notes, folders and attachments
distinguished by their column population (notes carry ``ZNOTEDATA``;
folders carry a ``ZTITLE2`` title and are referenced via ``ZFOLDER``).

Note bodies are NOT plain HTML. ``ZICNOTEDATA.ZDATA`` is a **gzip-
compressed Apple "notesgardenpb" protobuf** (``NoteStoreProto`` ->
``Document`` -> ``Note`` -> ``note_text``). We recover the plain text
with a tiny hand-rolled protobuf walk (pure stdlib -- no protobuf
dependency, keeps the DMG slim). A gzipped-HTML and a raw-UTF-8 path
are kept as defensive fallbacks for older / future store formats.

KNOWLEDGE, not conversations
============================

Apple Notes are personal knowledge/notes. This extractor emits the
KNOWLEDGE record shape consumed by the CM024 knowledge ingest
(Evernote / Obsidian / Notion adapters -> ``ParsedNote`` ->
markdown_writer -> Qdrant), NOT a ConversationBundle. The emitted dict
keys mirror the CM024 markdown-writer frontmatter so the convert step
can map straight across:

    title, content, created, updated, tags, notebook, source

``source`` is the literal ``"apple_notes"``. Privacy default is L2
(personal), matching the CM024 PrivacyClassifier default for knowledge
notes; password-locked notes are skipped by default (the user
deliberately protected them).

Requires Full Disk Access (FDA) on macOS Sequoia+.
"""
from __future__ import annotations

import argparse
import gzip
import json
import logging
import sqlite3
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

# Core-Data absolute-time epoch (2001-01-01) -> Unix epoch offset.
MAC_EPOCH_OFFSET = 978307200

# Default location of the Apple Notes store. Overridable for tests /
# custom installs via the OSTLER_NOTES_DB_PATH env var or --db-path.
DEFAULT_NOTES_PATH = (
    Path.home() / "Library" / "Group Containers"
    / "group.com.apple.notes" / "NoteStore.sqlite"
)

# Source identifier stamped onto every emitted record. The CM024
# knowledge ingest keys off this to attribute provenance.
SOURCE = "apple_notes"

# Default privacy compartment level for Apple Notes knowledge content.
# Matches CM024's PrivacyClassifier default (L2 = personal).
DEFAULT_COMPARTMENT_LEVEL = 2


# ---------------------------------------------------------------------------
# Body decoding
# ---------------------------------------------------------------------------

class _HTMLTextExtractor(HTMLParser):
    """Strip HTML tags, keep text content (defensive fallback path)."""

    def __init__(self) -> None:
        super().__init__()
        self.text_parts: List[str] = []

    def handle_data(self, data: str) -> None:
        self.text_parts.append(data)

    def get_text(self) -> str:
        return " ".join(self.text_parts).strip()


def _html_to_text(html: str) -> str:
    """Convert HTML to plain text."""
    parser = _HTMLTextExtractor()
    parser.feed(html)
    return parser.get_text()


def _read_varint(buf: bytes, i: int) -> tuple[int, int]:
    """Decode a protobuf base-128 varint at offset ``i``.

    Returns ``(value, new_offset)``. Raises IndexError if the buffer
    ends mid-varint (the caller treats that as a malformed message).
    """
    shift = 0
    result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7
        if shift > 70:  # guard against absurd / corrupt varints
            raise ValueError("varint too long")


def _proto_fields(buf: bytes) -> List[tuple[int, bytes]]:
    """Walk one protobuf message, returning ``(field_number, payload)``.

    Only length-delimited (wire type 2) fields carry a payload we care
    about; we skip varint / 32-bit / 64-bit fields. On any framing
    error we return what we have so far (best-effort, never raises to
    the caller).
    """
    out: List[tuple[int, bytes]] = []
    i = 0
    n = len(buf)
    while i < n:
        try:
            key, i = _read_varint(buf, i)
        except (IndexError, ValueError):
            break
        field = key >> 3
        wire = key & 0x7
        if wire == 2:  # length-delimited
            try:
                length, i = _read_varint(buf, i)
            except (IndexError, ValueError):
                break
            payload = buf[i:i + length]
            i += length
            out.append((field, payload))
        elif wire == 0:  # varint
            try:
                _, i = _read_varint(buf, i)
            except (IndexError, ValueError):
                break
        elif wire == 5:  # 32-bit
            i += 4
        elif wire == 1:  # 64-bit
            i += 8
        else:  # groups / unknown -- stop, can't safely advance
            break
    return out


def _extract_proto_text(raw: bytes) -> Optional[str]:
    """Extract ``note_text`` from a decompressed notesgardenpb message.

    Path through the schema:
        NoteStoreProto.document (field 2)
          -> Document.note      (field 3)
            -> Note.note_text   (field 2, UTF-8 string)

    Returns the decoded note text, or None if the structure does not
    match (caller falls back to HTML / plain decode).
    """
    document = [p for f, p in _proto_fields(raw) if f == 2]
    if not document:
        return None
    note = [p for f, p in _proto_fields(document[0]) if f == 3]
    if not note:
        return None
    note_text = [p for f, p in _proto_fields(note[0]) if f == 2]
    if not note_text:
        return None
    try:
        return note_text[0].decode("utf-8", "replace")
    except Exception:  # pragma: no cover - decode w/ replace is robust
        return None


def _decode_body(blob: Optional[bytes], title: str, snippet: Optional[str]) -> str:
    """Turn the raw ``ZDATA`` blob into plain-text body content.

    Decode order:
        1. gzip -> notesgardenpb protobuf -> note_text  (the real path)
        2. gzip -> HTML -> stripped text                (legacy stores)
        3. gzip -> raw UTF-8                             (last resort)
        4. snippet                                       (no usable body)

    The protobuf ``note_text`` includes the title as its first line.
    We strip a leading duplicate of the title so the body is just the
    note content.
    """
    if not blob:
        return (snippet or "").strip()

    decompressed: Optional[bytes] = None
    try:
        decompressed = gzip.decompress(blob)
    except (OSError, EOFError, gzip.BadGzipFile):
        # Some stores / fixtures may hold uncompressed bytes.
        decompressed = blob

    # 1. protobuf
    text = _extract_proto_text(decompressed)

    # 2 / 3. HTML or raw text fallback
    if not text:
        try:
            payload = decompressed.decode("utf-8", "replace")
        except Exception:
            payload = ""
        if "<" in payload and ">" in payload:
            text = _html_to_text(payload)
        else:
            text = payload

    if not text:
        return (snippet or "").strip()

    return _strip_leading_title(text, title)


def _strip_leading_title(text: str, title: str) -> str:
    """Drop a leading line that merely repeats the note title.

    Apple stores the title as the first line of ``note_text``. The
    title column gives us the title separately, so we avoid emitting it
    twice in the body.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not title:
        return text.strip()
    lines = text.split("\n")
    if lines and lines[0].strip() == title.strip():
        lines = lines[1:]
        # Also drop an immediately-following blank line.
        while lines and not lines[0].strip():
            lines.pop(0)
    return "\n".join(lines).strip()


# ---------------------------------------------------------------------------
# Date conversion
# ---------------------------------------------------------------------------

def _mac_to_datetime(raw: Optional[float]) -> Optional[datetime]:
    """Convert a Core-Data absolute timestamp to a UTC datetime.

    Returns None for null / non-positive / out-of-range values so the
    caller can fall back to a sibling timestamp rather than fabricate a
    bogus date.
    """
    if not raw or raw <= 0:
        return None
    try:
        return datetime.fromtimestamp(raw + MAC_EPOCH_OFFSET, tz=timezone.utc)
    except (ValueError, OSError, OverflowError):
        return None


# ---------------------------------------------------------------------------
# Record shape
# ---------------------------------------------------------------------------

@dataclass
class Note:
    """A single Apple Note, in KNOWLEDGE record shape.

    Field names mirror the CM024 markdown-writer frontmatter so the
    knowledge convert step maps straight across:
    ``title / content / created / updated / tags / notebook / source``.
    """

    title: str
    content: str            # plain-text body
    notebook: Optional[str]  # Apple Notes folder name (-> knowledge notebook)
    created: Optional[datetime]
    updated: Optional[datetime]
    tags: List[str]
    source: str
    compartment_level: int
    is_pinned: bool
    is_locked: bool
    word_count: int


def _note_to_record(n: Note) -> dict:
    """Serialise a Note to a JSON-friendly KNOWLEDGE record dict."""
    d = asdict(n)
    d["created"] = n.created.isoformat() if n.created else None
    d["updated"] = n.updated.isoformat() if n.updated else None
    return d


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

# Primary query against the real Apple Notes schema. Title is ZTITLE1;
# the folder name lives on the referenced folder object's ZTITLE2.
# Creation / modification dates have several columns across macOS
# versions; COALESCE picks the first populated one.
_QUERY_REAL = """
    SELECT
        n.ZTITLE1                                       AS title,
        n.ZSNIPPET                                      AS snippet,
        COALESCE(n.ZCREATIONDATE3, n.ZCREATIONDATE1,
                 n.ZCREATIONDATE, n.ZMODIFICATIONDATE1) AS created,
        COALESCE(n.ZMODIFICATIONDATE1, n.ZMODIFICATIONDATE,
                 n.ZCREATIONDATE3, n.ZCREATIONDATE1)    AS modified,
        n.ZISPINNED                                     AS pinned,
        n.ZISPASSWORDPROTECTED                          AS locked,
        f.ZTITLE2                                       AS folder_name,
        nb.ZDATA                                        AS body_data
    FROM ZICCLOUDSYNCINGOBJECT n
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
    LEFT JOIN ZICNOTEDATA nb          ON n.ZNOTEDATA = nb.Z_PK
    WHERE n.ZNOTEDATA IS NOT NULL
      AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION != 1)
    ORDER BY modified DESC
"""

# Fallback for older stores that used the un-suffixed column names.
_QUERY_LEGACY = """
    SELECT
        n.ZTITLE                          AS title,
        n.ZSNIPPET                        AS snippet,
        n.ZCREATIONDATE                   AS created,
        n.ZMODIFICATIONDATE               AS modified,
        COALESCE(n.ZISPINNED, 0)          AS pinned,
        COALESCE(n.ZISPASSWORDPROTECTED, 0) AS locked,
        f.ZTITLE                          AS folder_name,
        nb.ZDATA                          AS body_data
    FROM ZICCLOUDSYNCINGOBJECT n
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
    LEFT JOIN ZICNOTEDATA nb          ON n.ZNOTEDATA = nb.Z_PK
    WHERE n.ZTITLE IS NOT NULL
      AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION != 1)
    ORDER BY n.ZMODIFICATIONDATE DESC
"""


def extract_notes(
    db_path: Optional[Path] = None,
    include_locked: bool = False,
) -> List[Note]:
    """Extract all notes from Apple Notes as KNOWLEDGE records.

    Args:
        db_path: Path to NoteStore.sqlite. Defaults to the standard
            Group Container path (or ``OSTLER_NOTES_DB_PATH``).
        include_locked: Include password-locked notes. Default False --
            locked notes hold info the user deliberately protected.

    Returns:
        List of Note records, most recently modified first.

    Raises:
        PermissionError: If FDA is not granted.
        FileNotFoundError: If NoteStore.sqlite does not exist.
    """
    db_path = db_path or DEFAULT_NOTES_PATH

    if not db_path.exists():
        raise FileNotFoundError(f"Apple Notes database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Apple Notes. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    try:
        try:
            rows = conn.execute(_QUERY_REAL).fetchall()
        except sqlite3.OperationalError as e:
            logger.debug("Primary Apple Notes query failed (%s); trying legacy", e)
            try:
                rows = conn.execute(_QUERY_LEGACY).fetchall()
            except sqlite3.OperationalError:
                logger.error(
                    "Apple Notes schema not recognised on this macOS version"
                )
                return []
    finally:
        conn.close()

    notes: List[Note] = []
    for row in rows:
        locked = bool(row["locked"])
        if locked and not include_locked:
            continue

        title = (row["title"] or "Untitled").strip() or "Untitled"
        body = _decode_body(row["body_data"], title, row["snippet"])

        created = _mac_to_datetime(row["created"])
        updated = _mac_to_datetime(row["modified"])
        # Cross-fill so a record always has both if it has either.
        if created is None:
            created = updated
        if updated is None:
            updated = created

        notes.append(Note(
            title=title,
            content=body,
            notebook=row["folder_name"],
            created=created,
            updated=updated,
            tags=[],
            source=SOURCE,
            compartment_level=DEFAULT_COMPARTMENT_LEVEL,
            is_pinned=bool(row["pinned"]),
            is_locked=locked,
            word_count=len(body.split()),
        ))

    logger.info("Extracted %d notes from Apple Notes", len(notes))
    return notes


def notes_stats(notes: List[Note]) -> dict:
    """Aggregate counts for the CLI / extract_all summary."""
    return {
        "notes": len(notes),
        "total_words": sum(n.word_count for n in notes),
        "notebooks": len({n.notebook for n in notes if n.notebook}),
    }


# ---------------------------------------------------------------------------
# CLI (mirrors whatsapp_history.py / facebook_messenger.py shape)
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    """CLI entrypoint.

    ``python -m ostler_fda.apple_notes --json`` extracts Apple Notes
    knowledge records and writes ``apple_notes.json`` into the FDA
    import dir. Only counts go to stdout (privacy: never echo note
    bodies). Default DB path is overridable via ``OSTLER_NOTES_DB_PATH``
    or ``--db-path``.
    """
    import os

    parser = argparse.ArgumentParser(
        prog="pwg-apple-notes",
        description=(
            "Extract Apple Notes (iCloud Notes) as KNOWLEDGE records from "
            "NoteStore.sqlite. Feeds the CM024 knowledge ingest, NOT the "
            "conversation pipeline."
        ),
    )
    parser.add_argument(
        "--db-path",
        type=Path,
        default=None,
        help=(
            "Override the NoteStore.sqlite path. Defaults to "
            "$OSTLER_NOTES_DB_PATH then the standard Group Container path."
        ),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory to write apple_notes.json. "
            "Default: ~/.ostler/imports/fda/"
        ),
    )
    parser.add_argument(
        "--include-locked",
        action="store_true",
        help="Include password-locked notes (default: skip them).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a single structured JSON status line to stdout (counts only).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Extract but do not write the JSON output file.",
    )
    args = parser.parse_args(argv)

    result: dict = {
        "notes": 0,
        "total_words": 0,
        "notebooks": 0,
        "errors": [],
        "status": "ok",
    }

    def _stderr(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    db_path = args.db_path
    if db_path is None:
        env = os.environ.get("OSTLER_NOTES_DB_PATH")
        if env:
            db_path = Path(env)

    try:
        notes = extract_notes(db_path=db_path, include_locked=args.include_locked)
    except PermissionError as exc:
        _stderr(f"pwg-apple-notes: FDA pending ({exc})")
        result["status"] = "no_fda"
        if args.json:
            print(json.dumps(result))
        return 0
    except FileNotFoundError as exc:
        _stderr(f"pwg-apple-notes: NoteStore.sqlite not found ({exc})")
        result["status"] = "not_found"
        if args.json:
            print(json.dumps(result))
        return 0
    except Exception as exc:  # noqa: BLE001 - never leak note content
        msg = type(exc).__name__
        _stderr(f"pwg-apple-notes: unexpected failure ({msg})")
        result["status"] = "error"
        result["errors"].append(msg)
        if args.json:
            print(json.dumps(result))
        return 1

    stats = notes_stats(notes)
    result.update(stats)

    if not args.dry_run:
        output_dir = args.output_dir or (
            Path.home() / ".ostler" / "imports" / "fda"
        )
        output_dir.mkdir(parents=True, exist_ok=True)
        try:
            (output_dir / "apple_notes.json").write_text(
                json.dumps([_note_to_record(n) for n in notes], indent=2)
            )
        except OSError as exc:
            msg = type(exc).__name__
            _stderr(f"pwg-apple-notes: could not write JSON ({msg})")
            result["status"] = "write_error"
            result["errors"].append(msg)
            if args.json:
                print(json.dumps(result))
            return 0

    _stderr(
        f"pwg-apple-notes: extracted {stats['notes']} notes "
        f"({stats['total_words']} words, {stats['notebooks']} notebooks)"
    )

    if args.json:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
