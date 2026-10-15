"""Adapters that feed the reply-debt detector with normalised ``Thread``s.

The detector core (``reply_debt``) is source-agnostic and unit-testable with no
live data. These adapters are where the messy, source-specific knowledge lives:
which side of a conversation is "me", how to recover per-message direction, and
how to resolve a counterpart to a CM041 person + relationship strength.

Three adapters, in increasing order of how much live data they need to prove:

  * ``iter_imessage_threads``    -  reads the reply-debt SNAPSHOT that the
    iMessage feed writes under ``~/.ostler/state/reply_debt/``. It NEVER opens
    chat.db. The feed runs as ``ostler-assistant run-source imessage``, so its
    chat.db read happens under the signed assistant's Full Disk Access; this
    module runs inside ical-server, a bare python3.11 that TCC would attribute
    the read to and deny (CM051 #30, studio29: the customer was shown a Full
    Disk Access entry for "python3.11" and then told "you're all caught up").
    ``is_from_me`` from chat.db is still the direction signal, carried in the
    snapshot; ``OSTLER_IMESSAGE_SELF_HANDLES`` is applied here as before.
    A missing, unreadable, malformed or stale snapshot RAISES
    ``ReplyDebtSourceUnavailable``: it is "could not check", never "nothing owed".

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
import json
import os
import re
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
# iMessage adapter: reads the signed feed's snapshot, never chat.db
# ---------------------------------------------------------------------------


class ReplyDebtSourceUnavailable(RuntimeError):
    """A reply-debt source could not be read. ``reason`` is a short stable
    code the endpoint returns as ``degraded`` + ``reason``. Raising (rather
    than yielding nothing) is the whole point: an empty source and an
    unreadable one must never produce the same answer."""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


IMESSAGE_SNAPSHOT_SCHEMA = 1

# Older than this and the snapshot no longer says who is waiting NOW: a reply
# sent since would still read as owed. The feed ticks every 15 minutes but
# yields to live chat and to the shared ingest lock, so allow some slack.
DEFAULT_SNAPSHOT_MAX_AGE_HOURS = 6.0


def imessage_snapshot_path() -> Path:
    """Must agree with ``imessage_source.pipeline.reply_debt_snapshot_path``."""
    explicit = (os.environ.get("OSTLER_REPLY_DEBT_SNAPSHOT") or "").strip()
    if explicit:
        return Path(explicit).expanduser()
    root = (os.environ.get("OSTLER_DIR") or "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".ostler"
    return base / "state" / "reply_debt" / "imessage_threads.json"


def _snapshot_max_age_hours() -> float:
    raw = (os.environ.get("OSTLER_REPLY_DEBT_MAX_AGE_HOURS") or "").strip()
    if not raw:
        return DEFAULT_SNAPSHOT_MAX_AGE_HOURS
    try:
        v = float(raw)
    except ValueError:
        return DEFAULT_SNAPSHOT_MAX_AGE_HOURS
    return v if v > 0 else DEFAULT_SNAPSHOT_MAX_AGE_HOURS


def load_imessage_threads(
    *,
    snapshot_path: Optional[Path] = None,
    strength_lookup=None,
    lookback_days: int = 90,
    max_age_hours: Optional[float] = None,
    now: Optional[datetime] = None,
) -> list[Thread]:
    """Return normalised threads from the iMessage reply-debt snapshot.

    Raises ``ReplyDebtSourceUnavailable`` when the snapshot is absent,
    unreadable, malformed, stale, or records that the feed itself could not
    read Messages. A snapshot whose feed found no chat.db at all
    (``status: absent``) is a true zero and returns ``[]``.
    """
    path = snapshot_path or imessage_snapshot_path()
    now = now or datetime.now(timezone.utc)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ReplyDebtSourceUnavailable(
            "imessage_snapshot_missing",
            "the iMessage feed has not written its reply-debt snapshot yet",
        )
    except OSError as exc:
        raise ReplyDebtSourceUnavailable("imessage_snapshot_unreadable", str(exc)[:200])
    try:
        snap = json.loads(raw)
    except ValueError as exc:
        raise ReplyDebtSourceUnavailable("imessage_snapshot_malformed", str(exc)[:200])
    if not isinstance(snap, dict) or snap.get("schema") != IMESSAGE_SNAPSHOT_SCHEMA:
        raise ReplyDebtSourceUnavailable(
            "imessage_snapshot_malformed", "unknown snapshot schema"
        )

    status = snap.get("status")
    if status == "absent":
        return []
    if status != "ok":
        raise ReplyDebtSourceUnavailable(
            "messages_not_readable",
            str(snap.get("reason") or status or "unknown")[:200],
        )

    generated = _parse_iso(snap.get("generated_at"))
    if generated is None:
        raise ReplyDebtSourceUnavailable(
            "imessage_snapshot_malformed", "no generated_at"
        )
    age_h = (now - generated).total_seconds() / 3600.0
    limit_h = max_age_hours if max_age_hours is not None else _snapshot_max_age_hours()
    if age_h > limit_h:
        raise ReplyDebtSourceUnavailable(
            "imessage_snapshot_stale",
            f"snapshot is {age_h:.1f}h old (limit {limit_h:g}h)",
        )

    threads: list[Thread] = []
    for row in snap.get("threads") or []:
        if not isinstance(row, dict):
            continue
        last = row.get("last") or {}
        ts = _parse_iso(last.get("timestamp"))
        text = last.get("text") or ""
        if ts is None or not text:
            continue
        if (now - ts).days > lookback_days:
            continue
        handle = last.get("sender") or ""
        is_owner = bool(last.get("is_from_me")) or is_owner_handle(handle)
        is_group = bool(row.get("is_group")) or len(row.get("participants") or []) > 1
        counterpart = (
            row.get("display_name")
            or (handle if not is_owner else "")
            or ", ".join(row.get("participants") or [])
            or str(row.get("chat_id") or "")
        )
        person_uri = None
        strength = None
        if strength_lookup and not is_group:
            resolved = strength_lookup(counterpart)
            if resolved:
                person_uri, strength = resolved
        threads.append(
            Thread(
                thread_id=f"imessage:{row.get('chat_id')}",
                channel="imessage",
                messages=(
                    Message(
                        sender="me" if is_owner else (handle or counterpart),
                        text=text,
                        timestamp=ts,
                        is_from_owner=is_owner,
                    ),
                ),
                privacy_level="L2",  # iMessage default; per-thread gating TBD
                is_group=is_group,
                counterpart_name=counterpart,
                person_uri=person_uri,
                relationship_strength=strength,
            )
        )
    return threads


def iter_imessage_threads(**kwargs) -> Iterator[Thread]:
    """Back-compatible name. Loads EAGERLY so an unavailable source raises at
    the call, where ``compute_reply_debts`` can see it, not lazily mid-merge."""
    return iter(load_imessage_threads(**kwargs))


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
    "load_imessage_threads",
    "imessage_snapshot_path",
    "ReplyDebtSourceUnavailable",
    "thread_from_email_transcript",
]
