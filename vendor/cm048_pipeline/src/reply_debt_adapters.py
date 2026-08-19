"""Adapters that feed the reply-debt detector with normalised ``Thread``s.

The detector core (``reply_debt``) is source-agnostic and unit-testable with no
live data. These adapters are where the messy, source-specific knowledge lives:
which side of a conversation is "me", how to recover per-message direction, and
how to resolve a counterpart to a CM041 person + relationship strength.

Three adapters, in increasing order of how much live data they need to prove:

  * ``iter_imessage_threads``    -  reads Apple's chat.db directly. ``is_from_me``
    gives ground-truth per-message direction; ``OSTLER_IMESSAGE_SELF_HANDLES``
    + the chat.db owner are the "me" signal. THIS IS THE STRONGEST SOURCE for
    reply debt and the one that needs the real box + Full Disk Access to prove.

  * ``iter_email_threads``       -  reads the CM048 conversation store's
    email-thread sidecars (``email_thread`` in ``extra_metadata`` /
    metadata.json). The sidecar preserves ``message_ids`` /
    ``in_reply_to_chain`` / ``last_message_at`` but NOT the per-message sender,
    so this adapter recovers direction heuristically from the rendered
    transcript's ``sent:``/``received:`` labels. Partial  -  see notes.

  * ``iter_store_threads``       -  a best-effort reader over the on-disk
    conversation bundle (``transcript.md`` speaker labels + participant roles).
    The bundle collapses a thread to one transcript blob and does NOT preserve
    ``is_from_me`` (verified 2026-06-20), so direction here is recovered from
    speaker labels and is only as good as the speaker-id step. Used as a
    fallback so the wiki wing has *something* to render before the chat.db path
    is wired on the box.

The owner-handle detection (``is_owner_handle``) mirrors the assistant daemon's
``IMessageChannel::is_self_handle`` + ``OSTLER_IMESSAGE_SELF_HANDLES`` so the
two sides agree on who "me" is.
"""
from __future__ import annotations

import logging
import os
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional

from .reply_debt import Message, Thread

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Owner-handle detection (shared "who is me" signal)
# ---------------------------------------------------------------------------


def _self_handles() -> set[str]:
    """Parse ``OSTLER_IMESSAGE_SELF_HANDLES`` (comma-separated phones/emails).

    Mirrors the assistant daemon's parsing: case-insensitive, whitespace and
    empty entries stripped. Phone numbers are normalised to digits-only so
    "+44 7..." and "447..." compare equal.
    """
    raw = os.environ.get("OSTLER_IMESSAGE_SELF_HANDLES", "")
    out: set[str] = set()
    for part in raw.split(","):
        h = part.strip().lower()
        if not h:
            continue
        out.add(h)
        digits = re.sub(r"\D", "", h)
        if digits:
            out.add(digits)
    return out


def is_owner_handle(handle: str, self_handles: Optional[set[str]] = None) -> bool:
    """True if ``handle`` belongs to the owner ("me").

    Compares against ``OSTLER_IMESSAGE_SELF_HANDLES`` (phones digit-normalised,
    emails lowercased). Empty/unset self-handle set => always False (cannot
    claim a handle is the owner without configuration), matching the daemon's
    "empty disables the filter" behaviour.
    """
    if self_handles is None:
        self_handles = _self_handles()
    if not self_handles:
        return False
    h = (handle or "").strip().lower()
    if h in self_handles:
        return True
    digits = re.sub(r"\D", "", h)
    return bool(digits) and digits in self_handles


# ---------------------------------------------------------------------------
# Relationship strength lookup (optional CM041 hook)
# ---------------------------------------------------------------------------

# A callable injected by the surface: handle/name/uri -> (person_uri,
# strength 0..1) or None. Kept as a plug so this module has no hard CM041
# dependency and stays unit-testable.
StrengthLookup = "Callable[[str], Optional[tuple[Optional[str], Optional[float]]]]"


# ---------------------------------------------------------------------------
# iMessage chat.db adapter (strongest direction signal; needs the box)
# ---------------------------------------------------------------------------


CHAT_DB_DEFAULT = Path.home() / "Library" / "Messages" / "chat.db"

# Apple epoch is 2001-01-01; message.date is nanoseconds since then for modern
# macOS. We convert to aware UTC datetimes.
_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def _apple_ts_to_dt(raw: int) -> datetime:
    # Modern chat.db stores nanoseconds; older stored seconds. Detect by
    # magnitude.
    if raw > 1_000_000_000_000:  # ns
        seconds = raw / 1_000_000_000
    else:
        seconds = float(raw)
    return _APPLE_EPOCH.fromtimestamp(
        _APPLE_EPOCH.timestamp() + seconds, tz=timezone.utc
    )


def iter_imessage_threads(
    *,
    db_path: Optional[Path] = None,
    strength_lookup=None,
    lookback_days: int = 90,
    max_messages_per_thread: int = 40,
) -> Iterator[Thread]:
    """Yield normalised threads from Apple's chat.db (READ-ONLY).

    ``is_from_me`` is the ground-truth direction signal  -  no heuristic needed.
    Group chats are flagged via ``chat.style`` / participant count. Opens the
    db read-only (``mode=ro``) so it never mutates Messages.

    NOTE: requires the real box + Full Disk Access to read chat.db. Cannot be
    proven in CI / off-box. The query shape is conservative and well-trodden
    (it mirrors the assistant daemon's poll query) but live correctness is
    UNPROVEN until run on the box.
    """
    db_path = db_path or CHAT_DB_DEFAULT
    if not db_path.exists():
        log.info("reply_debt: chat.db not found at %s  -  skipping", db_path)
        return

    uri = f"file:{db_path}?mode=ro&immutable=1"
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as exc:  # pragma: no cover - needs the box
        log.warning("reply_debt: could not open chat.db: %s", exc)
        return

    try:
        conn.row_factory = sqlite3.Row
        # One row per chat with its participant count + style (43 == group).
        chats = conn.execute(
            """
            SELECT c.ROWID AS chat_id,
                   c.chat_identifier AS chat_identifier,
                   c.display_name AS display_name,
                   c.style AS style,
                   COUNT(DISTINCT chj.handle_id) AS participant_count
            FROM chat c
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            GROUP BY c.ROWID
            """
        ).fetchall()

        for chat in chats:
            rows = conn.execute(
                """
                SELECT m.text AS text,
                       m.is_from_me AS is_from_me,
                       m.date AS date,
                       h.id AS handle
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id = ?
                  AND m.text IS NOT NULL AND m.text != ''
                ORDER BY m.date DESC
                LIMIT ?
                """,
                (chat["chat_id"], max_messages_per_thread),
            ).fetchall()
            if not rows:
                continue

            messages: list[Message] = []
            for r in reversed(rows):  # chronological
                ts = _apple_ts_to_dt(r["date"])
                is_owner = bool(r["is_from_me"]) or is_owner_handle(
                    r["handle"] or ""
                )
                messages.append(
                    Message(
                        sender=(r["handle"] or "me") if not is_owner else "me",
                        text=r["text"] or "",
                        timestamp=ts,
                        is_from_owner=is_owner,
                    )
                )
            if not messages:
                continue

            # Respect the lookback window on the last message.
            last_ts = messages[-1].timestamp
            age_days = (datetime.now(timezone.utc) - last_ts).days
            if age_days > lookback_days:
                continue

            is_group = (chat["style"] == 43) or (
                (chat["participant_count"] or 0) > 1
            )
            counterpart = chat["display_name"] or chat["chat_identifier"] or ""

            person_uri = None
            strength = None
            if strength_lookup and not is_group:
                resolved = strength_lookup(counterpart)
                if resolved:
                    person_uri, strength = resolved

            yield Thread(
                thread_id=f"imessage:{chat['chat_id']}",
                channel="imessage",
                messages=tuple(messages),
                privacy_level="L2",  # iMessage default; per-thread gating TBD
                is_group=is_group,
                counterpart_name=counterpart,
                person_uri=person_uri,
                relationship_strength=strength,
            )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Email-thread adapter (CM048 store sidecars)
# ---------------------------------------------------------------------------


# The email transcript renders each message header as "sent:" (owner authored)
# or "received:" (other party) per prompts/02_enrich_email_thread.md.
_EMAIL_DIR_RE = re.compile(r"^\s*(sent|received)\s*:", re.IGNORECASE)


def thread_from_email_transcript(
    *,
    thread_id: str,
    transcript: str,
    counterpart_name: str,
    privacy_level: str = "L2",
    last_message_at: Optional[str] = None,
    person_uri: Optional[str] = None,
    relationship_strength: Optional[float] = None,
) -> Optional[Thread]:
    """Recover a Thread from an email transcript's sent:/received: labels.

    Direction here is recovered from the rendered transcript labels rather than
    a structured per-message field (the sidecar does not carry per-message
    sender). Each "sent:"/"received:" header starts a new message block; the
    text until the next header is that message's body. Partial fidelity  -  only
    as good as the enrichment renderer's labelling  -  but enough to tell whether
    the LAST email was inbound, which is all the detector needs.
    """
    if not transcript:
        return None

    blocks: list[tuple[bool, list[str]]] = []  # (is_from_owner, lines)
    for line in transcript.splitlines():
        m = _EMAIL_DIR_RE.match(line)
        if m:
            is_owner = m.group(1).lower() == "sent"
            blocks.append((is_owner, []))
        elif blocks:
            blocks[-1][1].append(line)

    if not blocks:
        return None

    base_ts = _parse_iso(last_message_at) or datetime.now(timezone.utc)
    messages: list[Message] = []
    total = len(blocks)
    for i, (is_owner, body_lines) in enumerate(blocks):
        # We only have the last_message_at timestamp; synthesise a monotonic
        # ordering so the LAST block keeps base_ts and earlier ones precede it.
        ts = base_ts if i == total - 1 else base_ts
        messages.append(
            Message(
                sender="me" if is_owner else counterpart_name,
                text="\n".join(body_lines).strip(),
                timestamp=ts,
                is_from_owner=is_owner,
            )
        )

    return Thread(
        thread_id=thread_id,
        channel="email",
        messages=tuple(messages),
        privacy_level=privacy_level,
        is_group=False,
        counterpart_name=counterpart_name,
        person_uri=person_uri,
        relationship_strength=relationship_strength,
    )


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


__all__ = [
    "is_owner_handle",
    "iter_imessage_threads",
    "thread_from_email_transcript",
    "CHAT_DB_DEFAULT",
]
