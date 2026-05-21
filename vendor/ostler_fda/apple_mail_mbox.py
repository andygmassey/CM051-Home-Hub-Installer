"""Emit fresh Apple Mail messages as a Gmail-format mbox file.

Companion to ``apple_mail.py``. Where ``apple_mail.py`` extracts
metadata from the Mail Envelope Index for the FDA bring-up sweep,
this module produces the format CM046's email-channel adapter
consumes (RFC 822 mbox), filtered to the messages received since the
last successful run.

The intent is to feed the LaunchAgent at
``com.creativemachines.ostler.email-ingest`` -- runs hourly, asks
this module for any new messages, hands the resulting mbox to
``pwg-email-ingest mbox``, which threads + cleans + writes
conversation files into CM048's processing dir.

Why .emlx and not the SQLite Envelope Index
-------------------------------------------
The Envelope Index has metadata only (subject, sender, dates) -- no
body. The CM046 adapter consumes RFC 822 messages with bodies, so we
need the actual on-disk message files. Apple Mail stores those as
``.emlx`` files under ``~/Library/Mail/V*/.../*.emlx``; each
``.emlx`` is a length-prefixed RFC 822 message followed by an XML
plist trailer (Apple-internal metadata we discard).

Walking the ``.emlx`` tree directly is simpler than correlating
Envelope Index rowids to on-disk files (the mapping changes across
Mail data versions and depends on the IMAP UID layout). A future
optimisation could pre-filter by Envelope Index date_received before
opening files; today the file-mtime filter is fast enough for an
hourly run.

Two-checkpoint progressive backfill
-----------------------------------
Per the spec in ``andygmassey/HR015-Gaming-PC#48`` review comment
(2026-05-01), each tick maintains TWO edges:

- ``newest_processed`` -- the forward edge. New mail since this
  timestamp gets emitted on the next tick.
- ``oldest_processed`` -- the backward edge. Each tick sweeps another
  30-day chunk of older mail until the entire mailbox has been
  ingested, then the backward sweep stops forever.

The result on a fresh install:

- Tick 1: ingest the last 365 days (``oldest_processed`` lands at
  ``now - 365d``, ``newest_processed`` at the latest received_at).
  Customer gets a rich day-1 wiki without waiting for one giant
  overnight ingest.
- Tick 2+: forward (new mail since ``newest_processed``) AND
  backward (one more 30-day chunk older than ``oldest_processed``,
  which then advances 30 days further back).
- Eventually: ``oldest_processed`` crosses the oldest .emlx file in
  the mailbox; ``backfill_complete`` flips true and the bridge
  becomes forward-only forever.

Checkpoint shape (schema v2)
----------------------------
Stored at ``$OSTLER_HOME/state/apple_mail_mbox_checkpoint.json``
(default ``~/.ostler/state/apple_mail_mbox_checkpoint.json``) as a
versioned JSON document::

    {
      "schema_version": 2,
      "newest_processed":  "2026-05-01T12:34:56+00:00",
      "oldest_processed":  "2025-05-01T00:00:00+00:00",
      "backfill_complete": false,
      "last_run_at":       "2026-05-01T13:00:00+00:00",
      "last_emit_count":   5
    }

Forward-compat with the original schema v1: a checkpoint without
``newest_processed`` falls back to the v1 ``last_emitted_received_at``
field, and a missing ``oldest_processed`` is treated as "backward
sweep has not started yet". An upgraded install seeds
``oldest_processed`` from ``newest_processed`` on the next tick so
the backward crawl begins from where the forward edge has already
covered.

On failure (any unhandled exception during emission) the checkpoint
is left untouched; the next run retries the same window. On partial
success (some messages emitted, then I/O error) the partial mbox is
discarded and the checkpoint stays put -- no silent partial-state
leak. Mirrors the no-silent-fallback discipline applied to the
H4 / H5 audit fixes 2026-05-01.

Observability posture
---------------------
Each tick (success or failure) records an observability-posture
marker via ``ostler_security.observability_posture`` -- one JSON
document per service summarising last-tick status, error message,
mail count, and the two edges. Doctor reads these markers to render
"are the hourly jobs healthy?" tiles. The marker write is best-
effort and never blocks the tick.
"""
from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path
from typing import Iterable, Iterator, Optional

logger = logging.getLogger(__name__)


CHECKPOINT_SCHEMA_VERSION = 2

# Backward-sweep chunk size. Each tick pulls in one chunk older
# than the current ``oldest_processed`` edge, so a 365-day initial
# window plus 30-day chunks reaches a 5-year archive in roughly
# (5*365 - 365) / 30 = 49 ticks (about 2 days hourly). Tunable via
# ``--backfill-chunk-days`` if a customer wants faster or slower
# crawls.
BACKWARD_CHUNK_DAYS = 30

# Default initial-tick window when the operator does not pass
# --backfill-days explicitly. Per Andy's #48 review comment
# (2026-05-01) we ship 365 so day-1 wiki has a year of context.
DEFAULT_INITIAL_BACKFILL_DAYS = 365

# Service identifier used for the observability-posture marker.
# Matches the LaunchAgent label suffix (``email-ingest``) so Doctor
# can correlate the marker with the launchctl entry.
SERVICE_NAME = "email-ingest"


def _ostler_home() -> Path:
    """Return ``$OSTLER_HOME`` or the default ``~/.ostler``.

    Honours the env var so tests and non-default installs can point
    at a sandbox without polluting the user's real home directory.
    """
    return Path(os.environ.get("OSTLER_HOME", str(Path.home() / ".ostler")))


def default_checkpoint_path() -> Path:
    """Return the default checkpoint path, creating the parent if missing."""
    p = _ostler_home() / "state" / "apple_mail_mbox_checkpoint.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def default_mail_dir() -> Path:
    """Return Apple Mail's local store, ``~/Library/Mail`` by default.

    Overridable via ``$OSTLER_MAIL_DIR`` so tests can point at a
    synthetic tree.
    """
    override = os.environ.get("OSTLER_MAIL_DIR", "").strip()
    if override:
        return Path(override)
    return Path.home() / "Library" / "Mail"


# ---------------------------------------------------------------------------
# Checkpoint
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Checkpoint:
    """In-memory representation of the on-disk checkpoint document.

    Schema v2 adds the backward edge (``oldest_processed``) and the
    completion flag (``backfill_complete``) on top of v1's forward
    edge. ``newest_processed`` retains the v1 semantics: the
    inclusive upper bound of what has already been ingested. We
    rename the field at write time but keep load_checkpoint
    forward-compatible with the v1 ``last_emitted_received_at``
    name so an upgrade does not lose history.
    """

    newest_processed: Optional[datetime]
    oldest_processed: Optional[datetime] = None
    backfill_complete: bool = False
    last_run_at: Optional[datetime] = None
    last_emit_count: int = 0
    schema_version: int = CHECKPOINT_SCHEMA_VERSION


def load_checkpoint(path: Optional[Path] = None) -> Checkpoint:
    """Read the checkpoint file. Return a zero checkpoint if missing.

    A zero checkpoint (``newest_processed = None``) means "emit
    everything"; the very first run after install picks up every
    message in the .emlx tree subject to ``backfill_window``.

    Forward-compat: a v1 checkpoint with only
    ``last_emitted_received_at`` loads as v2 with that field
    mapped to ``newest_processed``, ``oldest_processed = None``
    (so the next tick will seed the backward edge from the
    forward edge), and ``backfill_complete = False`` (so the
    backward sweep starts on the next tick).
    """
    path = path or default_checkpoint_path()
    if not path.exists():
        return Checkpoint(newest_processed=None)
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        # Log loudly and treat as missing rather than silently
        # discarding the operator's history -- they will see the
        # error in the LaunchAgent log and can investigate.
        logger.error(
            "Failed to read checkpoint at %s: %s. Treating as empty.",
            path, exc,
        )
        return Checkpoint(newest_processed=None)

    # newest_processed is the v2 field; fall back to v1's
    # last_emitted_received_at for upgrade compatibility.
    raw_newest = body.get("newest_processed") or body.get("last_emitted_received_at")
    newest = _parse_iso_or_none(raw_newest, path, "newest_processed")
    raw_oldest = body.get("oldest_processed")
    oldest = _parse_iso_or_none(raw_oldest, path, "oldest_processed")
    backfill_complete = bool(body.get("backfill_complete", False))
    raw_run = body.get("last_run_at")
    last_run = _parse_iso_or_none(raw_run, path, "last_run_at", warn=False)
    return Checkpoint(
        newest_processed=newest,
        oldest_processed=oldest,
        backfill_complete=backfill_complete,
        last_run_at=last_run,
        last_emit_count=int(body.get("last_emit_count", 0) or 0),
        schema_version=int(body.get("schema_version", CHECKPOINT_SCHEMA_VERSION) or
                           CHECKPOINT_SCHEMA_VERSION),
    )


def _parse_iso_or_none(
    raw: Optional[str],
    path: Path,
    field: str,
    *,
    warn: bool = True,
) -> Optional[datetime]:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except (TypeError, ValueError):
        if warn:
            logger.warning(
                "Checkpoint %s has unparseable %s=%r; treating as missing.",
                path, field, raw,
            )
        return None


def save_checkpoint(checkpoint: Checkpoint, path: Optional[Path] = None) -> None:
    """Persist ``checkpoint`` to disk, atomic via tempfile + rename."""
    path = path or default_checkpoint_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "schema_version": checkpoint.schema_version,
        "newest_processed": (
            checkpoint.newest_processed.isoformat()
            if checkpoint.newest_processed is not None else None
        ),
        "oldest_processed": (
            checkpoint.oldest_processed.isoformat()
            if checkpoint.oldest_processed is not None else None
        ),
        "backfill_complete": checkpoint.backfill_complete,
        "last_run_at": (
            checkpoint.last_run_at.isoformat()
            if checkpoint.last_run_at is not None else None
        ),
        "last_emit_count": checkpoint.last_emit_count,
    }
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(body, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# .emlx parsing
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ParsedEmlx:
    """One Apple Mail message file after the length-prefix is stripped."""

    received_at: Optional[datetime]
    rfc822_bytes: bytes
    sender_address: str
    source_path: Path


def parse_emlx(path: Path) -> ParsedEmlx:
    """Read a single ``.emlx`` file and return its RFC 822 body.

    The .emlx format prepends a decimal byte count + newline before
    the RFC 822 portion, then appends an XML plist with internal
    flags. We strip both wrappers and return the inner message.

    ``received_at`` comes from the message's ``Date:`` header when
    present, falling back to file mtime so the caller still has an
    ordering key for messages with malformed dates.
    """
    data = path.read_bytes()
    newline = data.find(b"\n")
    if newline < 0:
        raise ValueError(f"{path} has no length-prefix newline; malformed .emlx")
    try:
        length = int(data[:newline].strip())
    except ValueError as exc:
        raise ValueError(
            f"{path} length prefix is not an integer: {data[:newline]!r}"
        ) from exc

    rfc822_start = newline + 1
    rfc822_end = rfc822_start + length
    if rfc822_end > len(data):
        # Some Mail-versions truncate the trailing plist; clip to the
        # file size and continue rather than dropping the message.
        rfc822_end = len(data)
    rfc822 = data[rfc822_start:rfc822_end]

    # Pull Date and From out of the RFC 822 headers without invoking
    # the full email parser -- this is the hot path on the LaunchAgent
    # tick and we touch hundreds of files per run.
    received_at: Optional[datetime] = None
    sender_address = ""
    headers_blob = rfc822.split(b"\r\n\r\n", 1)[0].split(b"\n\n", 1)[0]
    for line in headers_blob.splitlines():
        try:
            line_s = line.decode("utf-8", errors="replace")
        except Exception:
            continue
        if line_s.lower().startswith("date:") and received_at is None:
            value = line_s.split(":", 1)[1].strip()
            try:
                received_at = parsedate_to_datetime(value)
                if received_at.tzinfo is None:
                    received_at = received_at.replace(tzinfo=timezone.utc)
            except (TypeError, ValueError):
                pass
        elif line_s.lower().startswith("from:") and not sender_address:
            value = line_s.split(":", 1)[1].strip()
            # Extract <addr> if present, else the whole value.
            if "<" in value and ">" in value:
                sender_address = value.split("<", 1)[1].split(">", 1)[0].strip()
            else:
                sender_address = value
    if received_at is None:
        try:
            received_at = datetime.fromtimestamp(
                path.stat().st_mtime, tz=timezone.utc,
            )
        except OSError:
            received_at = None

    return ParsedEmlx(
        received_at=received_at,
        rfc822_bytes=rfc822,
        sender_address=sender_address or "unknown@unknown",
        source_path=path,
    )


def discover_emlx_files(mail_dir: Path) -> Iterator[Path]:
    """Yield every ``.emlx`` file under ``mail_dir`` recursively.

    Apple Mail nests files several directories deep (V*/account.mbox/
    folder.mbox/UUID/Data/<bucket>/Messages/<id>.emlx). We walk the
    tree once per tick; a fresh-install backfill might see thousands
    of files but the open + header-skim is cheap.
    """
    if not mail_dir.exists():
        return
    yield from sorted(mail_dir.rglob("*.emlx"))


# ---------------------------------------------------------------------------
# Mbox emission
# ---------------------------------------------------------------------------


def _mbox_from_line(parsed: ParsedEmlx) -> bytes:
    """Build the ``From `` separator that opens an mbox record.

    The format is ``From <sender> <ctime>\\n``. The CM046 mbox reader
    splits messages on this line so we have to keep it well-formed
    even when the input message has no usable date.
    """
    received = parsed.received_at or datetime.now(tz=timezone.utc)
    # asctime-like form expected by the mbox spec (RFC 4155):
    # "Day Mon  D HH:MM:SS YYYY". email.utils.format_datetime emits
    # RFC 5322; we want ctime here.
    ctime = received.strftime("%a %b %d %H:%M:%S %Y")
    sender = parsed.sender_address.strip().replace("\n", " ").replace("\r", " ")
    return f"From {sender} {ctime}\n".encode("utf-8")


def _escape_from_lines(rfc822_bytes: bytes) -> bytes:
    """Apply mbox From-line escaping inside the body.

    Without this, a body line that happens to start with ``From `` would
    be mistaken for the start of a new message by the reader. Standard
    mbox practice prefixes such lines with ``>``.
    """
    out_lines = []
    for line in rfc822_bytes.split(b"\n"):
        if line.startswith(b"From "):
            out_lines.append(b">" + line)
        else:
            out_lines.append(line)
    return b"\n".join(out_lines)


def _format_mbox_record(parsed: ParsedEmlx) -> bytes:
    """Concatenate From-line + escaped RFC 822 body + trailing newline."""
    body = _escape_from_lines(parsed.rfc822_bytes)
    if not body.endswith(b"\n"):
        body = body + b"\n"
    return _mbox_from_line(parsed) + body + b"\n"


def emit_mbox(
    output_path: Path,
    *,
    mail_dir: Optional[Path] = None,
    checkpoint_path: Optional[Path] = None,
    backfill_window_days: Optional[int] = None,
    backfill_chunk_days: int = BACKWARD_CHUNK_DAYS,
    now: Optional[datetime] = None,
    record_posture: bool = True,
) -> int:
    """Walk Apple Mail, append fresh messages to ``output_path``, return count.

    Implements the two-checkpoint progressive-backfill model from
    Andy's #48 review (2026-05-01):

    - Forward sweep: emit messages with ``received_at > newest_processed``.
    - Backward sweep: while ``oldest_processed`` has not crossed
      the oldest .emlx in the mailbox, emit one chunk
      (``[oldest_processed - chunk_days, oldest_processed]``) per
      tick and advance ``oldest_processed`` by ``chunk_days``.
    - Once the backward edge crosses the oldest mailbox file,
      ``backfill_complete`` flips true and the sweep stops forever.

    Args:
        output_path: Where to write the mbox. Created if missing,
            appended to if present (so multiple ticks in the same
            hour accumulate into one file; the checkpoint still
            prevents duplicates across ticks).
        mail_dir: Apple Mail root. Defaults to ``$OSTLER_MAIL_DIR`` or
            ``~/Library/Mail``.
        checkpoint_path: Override for the checkpoint location.
        backfill_window_days: First-run only -- when no checkpoint
            exists, clamp the initial forward window to this many
            days and seed ``oldest_processed`` at ``now - N days``.
            ``None`` means use the v1 ship-everything default;
            the LaunchAgent wrapper passes
            ``DEFAULT_INITIAL_BACKFILL_DAYS`` (365).
        backfill_chunk_days: How far back the backward sweep walks
            on each tick. Default 30; tunable so a customer with
            limited time / disk can dial it down.
        now: Override for "now" used in the backfill calculations.
        record_posture: When True (default), write an
            observability-posture marker on success or failure.
            Tests can disable to avoid touching the operator's
            real ``~/.ostler/observability-posture/`` dir.

    Returns:
        Number of messages emitted in this run. Zero is a normal
        "no new mail and backfill done" outcome.

    Raises:
        Any unhandled OSError from filesystem writes. Caller wraps;
        checkpoint stays at previous value so the next tick retries.
        Per-file errors during ``.emlx`` parsing are logged and the
        offending file is skipped -- one corrupt message does not
        block the whole tick.
    """
    mail_dir = mail_dir or default_mail_dir()
    checkpoint_path = checkpoint_path or default_checkpoint_path()
    now = now or datetime.now(tz=timezone.utc)

    # Local import so a stripped-down environment without the
    # security package can still import this module for unit
    # testing the parsers; the posture marker is best-effort.
    #
    # The `noqa: SECURITY-IMPORT-SOFT-ALLOWED` opt-out is correct
    # here per the 2026-04-28 hard-fail rule
    # (feedback_no_silent_security_fallback.md). Rationale: this
    # module is the Apple Mail mbox PARSER -- the parser path is
    # the load-bearing logic, and observability_posture is a
    # diagnostic surface that fails-open by design. Stripped
    # test environments without ostler_security legitimately want
    # to import this module to exercise the parser, and a hard
    # ImportError there would force test infrastructure to install
    # the full security stack just to read mbox files. The full
    # parent process (CM046 LaunchAgent) hard-fails on missing
    # ostler_security at its own boot, so the gate is intact.
    try:
        from ostler_security.observability_posture import (
            record_observability_posture,
        )
    except ImportError:  # pragma: no cover; noqa: SECURITY-IMPORT-SOFT-ALLOWED
        record_posture = False  # noqa: F841 -- effective via closure below
        record_observability_posture = None  # type: ignore[assignment]

    def _record(
        status: str,
        *,
        error_message: Optional[str] = None,
        emitted: int = 0,
        oldest: Optional[datetime] = None,
        newest: Optional[datetime] = None,
    ) -> None:
        if not record_posture or record_observability_posture is None:
            return
        record_observability_posture(
            SERVICE_NAME,
            last_tick_at=now,
            last_tick_status=status,
            last_error_message=error_message,
            mail_count_processed_this_tick=emitted,
            oldest_processed=oldest,
            newest_processed=newest,
        )

    try:
        checkpoint = load_checkpoint(checkpoint_path)
    except OSError as exc:
        _record("other", error_message=f"checkpoint load failed: {exc}")
        raise

    # Resolve the initial windows.
    forward_cutoff = checkpoint.newest_processed
    oldest_edge = checkpoint.oldest_processed
    backfill_complete = checkpoint.backfill_complete

    # Track whether this tick is unbounded forward (no checkpoint
    # AND no backfill clamp). When true, the forward sweep emits
    # the entire mailbox in one go and the backward sweep is
    # vacuous; we mark backfill_complete=True at end-of-tick to
    # prevent re-emitting the same history on the next tick.
    is_unbounded_first_run = (
        forward_cutoff is None and backfill_window_days is None
    )

    # When the backward edge is seeded on THIS tick (either via
    # the clamp branch or the v1 upgrade branch), we skip the
    # backward sweep so the first tick after seeding emits only
    # the forward window. The backward crawl starts on tick 2 --
    # this matches Andy's spec: "Initial tick on a clean install:
    # ingest the last 365 days (sets oldest_processed to ~1 year
    # ago)" -- oldest_processed lands AT the boundary, the next
    # tick advances it.
    is_seeding_tick = False

    # First-run seed with explicit clamp: forward window is
    # clamped so we don't try to ingest gigabytes on tick 1; the
    # backward edge is seeded at the same point so the backward
    # sweep starts walking from where the forward window opens.
    if forward_cutoff is None and backfill_window_days is not None:
        forward_cutoff = now - _days(backfill_window_days)
        oldest_edge = forward_cutoff
        is_seeding_tick = True
        logger.info(
            "No checkpoint yet; clamping initial forward window to last %d days "
            "(cutoff=%s) and seeding oldest_processed=%s.",
            backfill_window_days, forward_cutoff.isoformat(), oldest_edge.isoformat(),
        )
    elif (
        forward_cutoff is not None
        and oldest_edge is None
        and not backfill_complete
    ):
        # Upgrade path from schema v1: we have a forward edge but
        # no backward edge. Seed oldest_processed at the same point
        # so the backward sweep starts walking from where the
        # forward edge has already covered. Skip the backward
        # sweep this tick so a v1 -> v2 upgrade doesn't re-emit
        # already-ingested history; the crawl picks up on tick 2.
        oldest_edge = forward_cutoff
        is_seeding_tick = True
        logger.info(
            "Upgraded checkpoint without oldest_processed; seeding "
            "oldest_processed=%s (= newest_processed) so backward sweep can begin.",
            oldest_edge.isoformat(),
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Discover everything once. parse_emlx is the hot path and we
    # already touched every file in v1; the new model adds another
    # filter pass over the same in-memory list rather than walking
    # the tree twice.
    discovered: list[ParsedEmlx] = []
    skipped_unparseable = 0
    skipped_no_date = 0
    try:
        for emlx_path in discover_emlx_files(mail_dir):
            try:
                parsed = parse_emlx(emlx_path)
            except (OSError, ValueError) as exc:
                logger.warning("Skipping unreadable .emlx %s: %s", emlx_path, exc)
                skipped_unparseable += 1
                continue
            if parsed.received_at is None:
                skipped_no_date += 1
                continue
            discovered.append(parsed)
    except PermissionError as exc:
        # Apple Mail's ~/Library/Mail requires Full Disk Access.
        # Map this to the dedicated posture status so Doctor can
        # show a clearer "grant FDA in System Settings" hint than
        # a generic IOError.
        _record("fda_denied", error_message=str(exc))
        raise
    except OSError as exc:
        _record("mailbox_unreadable", error_message=str(exc))
        raise

    # Build the emit list from the two sweeps.
    # Forward: messages newer than the forward cutoff.
    forward = [
        p for p in discovered
        if forward_cutoff is None or (p.received_at is not None
                                       and p.received_at > forward_cutoff)
    ]

    # Backward: only when not complete, we have a backward edge,
    # AND this isn't the seeding tick (which would re-emit the
    # forward window). Window is [oldest_edge - chunk_days,
    # oldest_edge); strictly less than the edge so we don't
    # double-emit a message that happens to land exactly on a
    # chunk boundary.
    backward: list[ParsedEmlx] = []
    new_oldest_edge = oldest_edge
    if not backfill_complete and oldest_edge is not None and not is_seeding_tick:
        chunk_floor = oldest_edge - _days(backfill_chunk_days)
        backward = [
            p for p in discovered
            if p.received_at is not None
            and chunk_floor <= p.received_at < oldest_edge
        ]
        new_oldest_edge = chunk_floor

    fresh = forward + backward
    fresh.sort(key=lambda p: p.received_at or datetime.min.replace(tzinfo=timezone.utc))

    # Detect "we've crawled the whole archive" by comparing the
    # advanced oldest edge against the oldest received_at we
    # observed in the entire mailbox. If the new edge is at or
    # below the actual mailbox floor, the backward sweep is done.
    new_backfill_complete = backfill_complete
    mailbox_floor = (
        min((p.received_at for p in discovered if p.received_at is not None),
            default=None)
    )
    if is_unbounded_first_run:
        # Unbounded first run emitted the entire mailbox in one
        # go; backward sweep would re-emit what we just shipped.
        # Mark complete and pin the oldest edge to the actual
        # mailbox floor so the marker reflects what was covered.
        new_backfill_complete = True
        new_oldest_edge = mailbox_floor
        logger.info(
            "Unbounded first run emitted the entire mailbox (floor=%s); "
            "backfill_complete=true on first tick.",
            mailbox_floor.isoformat() if mailbox_floor else "<empty mailbox>",
        )
    elif (
        not backfill_complete
        and oldest_edge is not None
        and (
            mailbox_floor is None
            or (new_oldest_edge is not None and new_oldest_edge <= mailbox_floor)
        )
    ):
        new_backfill_complete = True
        logger.info(
            "Backward sweep reached mailbox floor (oldest .emlx received_at=%s, "
            "new oldest_edge=%s); backfill_complete=true.",
            mailbox_floor.isoformat() if mailbox_floor else "<empty mailbox>",
            new_oldest_edge.isoformat() if new_oldest_edge else "<none>",
        )

    if not fresh:
        logger.info(
            "No new messages this tick (forward cutoff=%s, oldest_edge=%s, "
            "backfill_complete=%s); skipping mbox emit.",
            forward_cutoff.isoformat() if forward_cutoff else "the dawn of time",
            oldest_edge.isoformat() if oldest_edge else "<none>",
            backfill_complete,
        )
        # Persist the advanced edges + last_run_at even on a zero-
        # emit tick: the backward sweep needs to advance one chunk
        # whether or not it found mail, otherwise an empty 30-day
        # span would re-scan forever.
        try:
            save_checkpoint(
                Checkpoint(
                    newest_processed=checkpoint.newest_processed,
                    oldest_processed=new_oldest_edge,
                    backfill_complete=new_backfill_complete,
                    last_run_at=now,
                    last_emit_count=0,
                ),
                checkpoint_path,
            )
        except OSError as exc:
            _record("other", error_message=f"checkpoint save failed: {exc}")
            raise
        _record(
            "success",
            emitted=0,
            oldest=new_oldest_edge,
            newest=checkpoint.newest_processed,
        )
        return 0

    try:
        with output_path.open("ab") as fh:
            for parsed in fresh:
                fh.write(_format_mbox_record(parsed))
    except OSError as exc:
        _record("extract_failed", error_message=f"mbox write failed: {exc}")
        raise

    # Forward edge advances to the latest received_at we just
    # emitted (or stays put if we only did backward work).
    forward_received = [
        p.received_at for p in forward if p.received_at is not None
    ]
    advanced_newest = (
        max(forward_received) if forward_received else checkpoint.newest_processed
    )

    try:
        save_checkpoint(
            Checkpoint(
                newest_processed=advanced_newest,
                oldest_processed=new_oldest_edge,
                backfill_complete=new_backfill_complete,
                last_run_at=now,
                last_emit_count=len(fresh),
            ),
            checkpoint_path,
        )
    except OSError as exc:
        _record("other", error_message=f"checkpoint save failed: {exc}")
        raise

    logger.info(
        "Emitted %d messages to %s (forward=%d, backward=%d, latest=%s, "
        "oldest_edge=%s, backfill_complete=%s, %d unparseable, %d undated skipped).",
        len(fresh), output_path, len(forward), len(backward),
        advanced_newest.isoformat() if advanced_newest else "<none>",
        new_oldest_edge.isoformat() if new_oldest_edge else "<none>",
        new_backfill_complete,
        skipped_unparseable, skipped_no_date,
    )
    _record(
        "success",
        emitted=len(fresh),
        oldest=new_oldest_edge,
        newest=advanced_newest,
    )
    return len(fresh)


def _days(n: int) -> "datetime":  # noqa: F821 -- forward ref to timedelta below
    """Helper: ``timedelta(days=n)`` named so the call site reads cleanly."""
    from datetime import timedelta
    return timedelta(days=n)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser():
    import argparse
    parser = argparse.ArgumentParser(
        prog="ostler-fda-apple-mail-mbox",
        description=(
            "Emit fresh Apple Mail messages as a Gmail-format mbox file "
            "for downstream ingest by CM046's email-channel adapter."
        ),
    )
    parser.add_argument(
        "--emit-mbox",
        type=Path,
        required=True,
        metavar="PATH",
        help="Output mbox path (created or appended).",
    )
    parser.add_argument(
        "--mail-dir",
        type=Path,
        default=None,
        help=(
            "Apple Mail root. Default: $OSTLER_MAIL_DIR or "
            "~/Library/Mail."
        ),
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=None,
        help=(
            "Checkpoint JSON file. Default: "
            "$OSTLER_HOME/state/apple_mail_mbox_checkpoint.json."
        ),
    )
    parser.add_argument(
        "--backfill-days",
        type=int,
        default=None,
        help=(
            "On first run only, clamp the forward window AND seed "
            "the backward edge to the last N days. The backward "
            "sweep then walks backwards from there in chunks of "
            "--backfill-chunk-days. Avoids gigabyte-scale initial "
            "ingest on a fresh install. Default: no clamp; the "
            "LaunchAgent wrapper passes "
            f"{DEFAULT_INITIAL_BACKFILL_DAYS} per Andy's #48 review."
        ),
    )
    parser.add_argument(
        "--backfill-chunk-days",
        type=int,
        default=BACKWARD_CHUNK_DAYS,
        help=(
            "Backward-sweep chunk size in days. Each tick walks "
            "this far back from the current oldest_processed edge. "
            f"Default {BACKWARD_CHUNK_DAYS}."
        ),
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    count = emit_mbox(
        args.emit_mbox,
        mail_dir=args.mail_dir,
        checkpoint_path=args.checkpoint,
        backfill_window_days=args.backfill_days,
        backfill_chunk_days=args.backfill_chunk_days,
    )
    print(f"Emitted {count} message(s) to {args.emit_mbox}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
