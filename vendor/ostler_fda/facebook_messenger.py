"""Parse a Facebook Messenger "Download Your Information" (DYI) export
into CM048 conversation payloads.

Background
==========

Facebook / Meta lets a user download their data as a ZIP. The
Messenger slice of that export lives under::

    <export-root>/messages/inbox/<thread_slug>/message_1.json
    <export-root>/messages/inbox/<thread_slug>/message_2.json   (long threads)
    <export-root>/messages/inbox/<thread_slug>/photos/...
    <export-root>/messages/inbox/<thread_slug>/gifs/...
    <export-root>/messages/inbox/<thread_slug>/files/...

(Older exports nest the same ``inbox/`` tree under
``messages/inbox`` directly; some variants use ``your_activity_
across_facebook/messages/inbox``. We accept any of the known roots
-- see ``find_inbox_dirs``.)

Each ``message_N.json`` carries::

    {
      "participants": [{"name": "Some One"}, {"name": "You"}],
      "messages": [
        {"sender_name": "Some One",
         "timestamp_ms": 1609459200000,
         "content": "hello",
         "reactions": [...],          # optional
         "photos": [...],             # optional
         "share": {...},              # optional (a shared link/post)
         "type": "Generic"},
        ...
      ],
      "title": "Some One",
      "thread_type": "Regular",       # "Regular" = 1:1/DM; "RegularGroup" = group
      "thread_path": "inbox/someone_abc123"
    }

This parser is the body-carrying sibling of ``whatsapp_history.py``.
WhatsApp's extractor reads metadata only (no bodies) and feeds
``pwg_ingest``; the Facebook export, by contrast, ships the full
message bodies, so this module produces the richer CM048
conversation payload: a ``(conversation_id, transcript, metadata)``
triple per thread, ready for ``cm048.processor.process(...)`` which
in turn drives the shared ``conversation_writer`` /
``ConversationBundle`` four-artefact pipeline.

The famous mojibake gotcha
==========================

Facebook's DYI export double-encodes every string: UTF-8 bytes are
emitted as latin-1 escape sequences inside the JSON. So an accented
character like "e-acute" arrives as the two bytes "A-tilde" +
"copyright-sign", and emoji arrive as a run of "eth" / box bytes.
The fix is to re-interpret each decoded JSON string as latin-1
bytes and decode THOSE as UTF-8::

    fixed = raw.encode("latin-1").decode("utf-8")

Some strings are genuinely plain ASCII / already correct and will
raise ``UnicodeDecodeError`` / ``UnicodeEncodeError`` on that round
trip -- we fall back to the raw string in that case. See
``fix_mojibake``.

Three-tier privacy posture (mirrors whatsapp_history.py)
========================================================

The privacy classifier mirrors the WhatsApp three-tier discipline,
adapted to the export's thread shape:

T1 -- DM (1:1 thread, ``thread_type == "Regular"`` with exactly two
      participants incl. the operator). Personal correspondence.
      privacy_level "L2".

T2 -- Group thread (``thread_type == "RegularGroup"`` OR more than
      two participants) that is small enough OR active enough to be
      worth ingesting. privacy_level "L2".

T3 -- Oversized + passive group. SKIPPED entirely (no payload
      emitted) so a downstream ingest cannot act on it. Mirrors
      WhatsApp's "large + passive group" skip.

Thresholds mirror whatsapp_history.py's lock-ins where they map
cleanly: intimate cutoff < 10 participants. The engagement floors
use the operator's own sent-message share within the thread
(``sender_name == operator``) because the export does not carry a
90-day index the way ChatStorage does -- we measure share over the
whole thread instead, which is the natural analogue for a static
export.

Privacy default note for CM048 wiring
=====================================

CM048's ``privacy._CHANNEL_DEFAULTS`` table does not yet carry a
``"facebook_messenger"`` key, so an unknown-channel bundle would
fall through to the L3 defence-in-depth fallback. This parser
therefore sets ``metadata['privacy_level']`` EXPLICITLY on every
payload (L2 for ingestible threads) so the CM048 adapter never
relies on the channel default. The trivial CM048 follow-up is to
add ``"facebook_messenger": "L2"`` to that table; until then the
explicit level keeps the posture correct.

Operator identity
=================

The export does not label "me". The operator is the participant
whose name matches the configured operator display name, read from
the ``OSTLER_USER_DISPLAY_NAME`` env var (the canonical operator-
name variable across the install; ``WIKI_OPERATOR_NAME`` is the
wiki-side mirror and is accepted as a fallback). When the operator
cannot be identified within a thread, the thread is skipped with a
log line rather than crashing -- direction would be unknowable and
a mis-attributed transcript is worse than a missing one.

Privacy of output
=================

This module reads message bodies (that is the point -- the
ConversationBundle path wants the transcript). The ``--json``
stdout status payload, however, is counts-only: no names, no
bodies, no thread titles. Mirrors the whatsapp_history.py CLI
privacy contract so install.sh can parse stdout safely.
"""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Channel + source naming. WhatsApp names its channel "whatsapp"
# (bare app slug); we follow the same convention.
CHANNEL = "facebook_messenger"
SOURCE = "facebook_messenger"
SOURCE_APP = "messenger"

# Privacy levels (string literals; CM048 compares strings).
PRIVACY_L2 = "L2"

# Classifier tier literals (parallel to whatsapp_history's TIER_*).
TIER_T1_DM = "facebook_dm"
TIER_T2_GROUP = "facebook_group"
TIER_T3_SKIP = "facebook_skipped"  # internal only -- never emitted

# Thresholds (mirror whatsapp_history.py's lock-ins where they map).
INTIMATE_PARTICIPANT_MAX = 10        # < 10 participants -> always ingest
ENGAGEMENT_FLOOR_RELATIVE = 0.02     # operator-sent share >= 2% -> ingest

# Facebook thread_type values.
THREAD_TYPE_REGULAR = "Regular"       # 1:1 OR small group DM
THREAD_TYPE_GROUP = "RegularGroup"    # explicit group thread

# Known inbox roots inside a DYI export (newest first).
_INBOX_RELATIVE_ROOTS = (
    "your_activity_across_facebook/messages/inbox",
    "messages/inbox",
    "inbox",
)

# Media / non-text placeholders. Matches the spirit of how WhatsApp /
# iMessage represent media in a rendered transcript.
PLACEHOLDER_PHOTO = "[photo]"
PLACEHOLDER_VIDEO = "[video]"
PLACEHOLDER_GIF = "[gif]"
PLACEHOLDER_AUDIO = "[audio message]"
PLACEHOLDER_STICKER = "[sticker]"
PLACEHOLDER_FILE = "[file]"
PLACEHOLDER_SHARE = "[shared a link]"
PLACEHOLDER_CALL = "[call]"

# Facebook message "type" values that are pure system events, not
# conversational content. Subscribe/Unsubscribe = someone added/left
# the group. We drop these from the transcript rather than render an
# empty line. ("Share" is NOT dropped -- it carries a placeholder.)
_SYSTEM_MESSAGE_TYPES = {"Subscribe", "Unsubscribe"}


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------


@dataclass
class FacebookMessage:
    """A single message inside a thread, post-decode."""

    sender_name: str
    timestamp_ms: int
    text: str            # decoded content OR a media placeholder
    is_from_operator: bool

    @property
    def timestamp(self) -> datetime:
        return datetime.fromtimestamp(self.timestamp_ms / 1000.0, tz=timezone.utc)


@dataclass
class FacebookThread:
    """A parsed + classified Facebook Messenger thread."""

    thread_slug: str
    title: str
    tier: str
    is_group: bool
    participants: List[str]          # display names, operator excluded
    operator_name: Optional[str]
    messages: List[FacebookMessage] = field(default_factory=list)
    operator_is_participant: bool = False  # operator listed in raw participants

    @property
    def started_at(self) -> Optional[datetime]:
        if not self.messages:
            return None
        return min(m.timestamp for m in self.messages)

    @property
    def ended_at(self) -> Optional[datetime]:
        if not self.messages:
            return None
        return max(m.timestamp for m in self.messages)


# ---------------------------------------------------------------------------
# Mojibake fix
# ---------------------------------------------------------------------------


def fix_mojibake(raw: Optional[str]) -> str:
    """Repair Facebook DYI double-encoding.

    Facebook emits UTF-8 text as latin-1-escaped bytes in its JSON.
    Re-encoding the decoded string as latin-1 and decoding as UTF-8
    recovers the original text. ASCII-only / already-correct strings
    raise on that round trip; we return them unchanged.

    Meta's DYI JSON is not schema-stable: a field the docs describe as
    a string can arrive as a dict, a list or null (the same shape
    variance that caused the #249 data-loss bug class). We never assume
    the input is a string -- any non-string value is treated as "no
    usable display text" and yields an empty string rather than
    crashing the whole thread parse on ``.encode``.
    """
    if not isinstance(raw, str):
        return ""
    if not raw:
        return ""
    try:
        return raw.encode("latin-1").decode("utf-8")
    except (UnicodeDecodeError, UnicodeEncodeError):
        # Already valid (pure ASCII, or a string that does not survive
        # the latin-1 round trip) -- keep the original.
        return raw


# ---------------------------------------------------------------------------
# Operator identity
# ---------------------------------------------------------------------------


def resolve_operator_name(explicit: Optional[str] = None) -> Optional[str]:
    """Resolve the operator's display name.

    Precedence:
        1. ``explicit`` argument (tests pass this).
        2. ``OSTLER_USER_DISPLAY_NAME`` env var (canonical).
        3. ``WIKI_OPERATOR_NAME`` env var (wiki-side mirror).

    Returns ``None`` (not a crash) when none is set -- the caller
    skips threads whose operator cannot be identified.
    """
    if explicit and explicit.strip():
        return explicit.strip()
    for var in ("OSTLER_USER_DISPLAY_NAME", "WIKI_OPERATOR_NAME"):
        value = os.environ.get(var, "").strip()
        # "You" is the install's unconfigured sentinel -- treat it as
        # "not configured" so we do not silently match a participant
        # literally named "You".
        if value and value != "You":
            return value
    return None


# ---------------------------------------------------------------------------
# Single-message rendering
# ---------------------------------------------------------------------------


def _render_message(raw: dict, operator_name: Optional[str]) -> Optional[FacebookMessage]:
    """Convert one raw export message dict to a FacebookMessage.

    Returns ``None`` for messages that should be dropped entirely
    (system join/leave rows, rows with no usable timestamp).
    """
    msg_type = raw.get("type")
    if msg_type in _SYSTEM_MESSAGE_TYPES:
        return None

    timestamp_ms = raw.get("timestamp_ms")
    if not isinstance(timestamp_ms, (int, float)):
        return None

    sender = fix_mojibake(raw.get("sender_name") or "").strip()

    # ``content`` is documented as a string but Meta's DYI JSON is not
    # schema-stable (#249 class): it can arrive as a dict / list / null.
    # Only a non-empty string is real message text; anything else falls
    # through to media-placeholder detection rather than being treated
    # as empty text and dropped.
    content = raw.get("content")
    if isinstance(content, str) and content:
        text = fix_mojibake(content)
    else:
        text = _media_placeholder(raw)

    if not text:
        # Pure-reaction row or an empty unparseable message -- skip.
        return None

    is_from_operator = bool(
        operator_name and sender and sender == operator_name
    )

    return FacebookMessage(
        sender_name=sender,
        timestamp_ms=int(timestamp_ms),
        text=text,
        is_from_operator=is_from_operator,
    )


def _media_placeholder(raw: dict) -> str:
    """Pick a placeholder for a no-text (media / share / call) message.

    Mirrors how WhatsApp / iMessage transcripts represent non-text
    content: a short bracketed token rather than an empty line.
    """
    if raw.get("photos"):
        return PLACEHOLDER_PHOTO
    if raw.get("videos"):
        return PLACEHOLDER_VIDEO
    if raw.get("gifs"):
        return PLACEHOLDER_GIF
    if raw.get("audio_files"):
        return PLACEHOLDER_AUDIO
    if raw.get("sticker"):
        return PLACEHOLDER_STICKER
    if raw.get("files"):
        return PLACEHOLDER_FILE
    if raw.get("share"):
        return PLACEHOLDER_SHARE
    if raw.get("call_duration") is not None or raw.get("type") == "Call":
        return PLACEHOLDER_CALL
    return ""


# ---------------------------------------------------------------------------
# Thread file loading + merge
# ---------------------------------------------------------------------------


def _thread_message_files(thread_dir: Path) -> List[Path]:
    """Return message_N.json files in numeric order.

    Long threads split across message_1.json, message_2.json, ...
    Facebook writes the NEWEST messages in message_1.json and older
    ones in higher-numbered files, but we sort the resulting messages
    by timestamp anyway, so file order is not load-bearing -- we sort
    the file list numerically purely for deterministic logging.
    """
    files = list(thread_dir.glob("message_*.json"))

    def _index(p: Path) -> int:
        m = re.search(r"message_(\d+)\.json$", p.name)
        return int(m.group(1)) if m else 0

    return sorted(files, key=_index)


def load_thread(thread_dir: Path, operator_name: Optional[str]) -> Optional[FacebookThread]:
    """Load + decode + classify a single thread directory.

    Merges all message_N.json files, decodes mojibake, sorts messages
    chronologically, and classifies the thread into a tier.

    Returns ``None`` when the thread cannot be parsed (no message
    files, unreadable JSON, or operator not identifiable in a thread
    that needs direction).
    """
    message_files = _thread_message_files(thread_dir)
    if not message_files:
        return None

    title = ""
    thread_type = THREAD_TYPE_REGULAR
    raw_participants: List[str] = []
    raw_messages: List[dict] = []

    for mf in message_files:
        try:
            data = json.loads(mf.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning(
                "facebook_messenger: could not read %s (%s)",
                mf.name, type(exc).__name__,
            )
            continue
        if not isinstance(data, dict):
            continue
        # Title / thread_type live on every part file; take the first
        # non-empty value.
        if not title:
            title = fix_mojibake(data.get("title") or "")
        thread_type = data.get("thread_type") or thread_type
        for p in data.get("participants") or []:
            if isinstance(p, dict):
                name = fix_mojibake(p.get("name") or "").strip()
                if name and name not in raw_participants:
                    raw_participants.append(name)
        msgs = data.get("messages")
        if isinstance(msgs, list):
            raw_messages.extend(msgs)

    # Some threads carry only one participant in the file (the other
    # party deleted their account); fall back to the title as the
    # counterpart name so a DM still resolves to a person.
    if title and title not in raw_participants:
        # Group titles are free-form ("Weekend Crew") and should not be
        # treated as a participant; only adopt the title as a participant
        # for non-group threads with a thin participant list.
        if thread_type == THREAD_TYPE_REGULAR and len(raw_participants) < 2:
            raw_participants.append(title)

    is_group = (
        thread_type == THREAD_TYPE_GROUP
        or len(raw_participants) > 2
    )

    # Decode + render messages.
    messages: List[FacebookMessage] = []
    for raw in raw_messages:
        if not isinstance(raw, dict):
            continue
        rendered = _render_message(raw, operator_name)
        if rendered is not None:
            messages.append(rendered)

    # Chronological order (oldest first) -- the export stores newest
    # first within each file and splits across files, so an explicit
    # sort is required.
    messages.sort(key=lambda m: m.timestamp_ms)

    # Drop the operator from the participants list -- the bundle's
    # participants are the OTHER parties (matches CM048's role="other"
    # convention; the operator is implicit).
    other_participants = [
        p for p in raw_participants if not (operator_name and p == operator_name)
    ]
    operator_is_participant = bool(
        operator_name and operator_name in raw_participants
    )

    thread = FacebookThread(
        thread_slug=thread_dir.name,
        title=title or thread_dir.name,
        tier=TIER_T1_DM,  # provisional; set by classify()
        is_group=is_group,
        participants=other_participants,
        operator_name=operator_name,
        messages=messages,
        operator_is_participant=operator_is_participant,
    )
    thread.tier = classify_thread(thread)
    return thread


# ---------------------------------------------------------------------------
# Classifier
# ---------------------------------------------------------------------------


def classify_thread(
    thread: FacebookThread,
    *,
    intimate_max: int = INTIMATE_PARTICIPANT_MAX,
    engagement_floor_rel: float = ENGAGEMENT_FLOOR_RELATIVE,
) -> str:
    """Classify a thread into T1 / T2 / T3.

    - 1:1 (not group) -> T1 DM.
    - Group with participant_count < intimate_max -> T2 (always).
    - Group otherwise: T2 if the operator's sent-message share within
      the thread is >= engagement_floor_rel; else T3 (skip).

    Mirrors whatsapp_history.classify_chat's intimate-vs-engagement
    shape. The "participant_count" includes the operator (+1) to match
    WhatsApp's informal "< 10 including self" cutoff.
    """
    if not thread.is_group:
        return TIER_T1_DM

    participant_count = len(thread.participants) + 1  # +1 for the operator

    if participant_count < intimate_max:
        return TIER_T2_GROUP

    total = len(thread.messages)
    if total == 0:
        return TIER_T3_SKIP
    operator_sent = sum(1 for m in thread.messages if m.is_from_operator)
    if (operator_sent / total) >= engagement_floor_rel:
        return TIER_T2_GROUP

    return TIER_T3_SKIP


# ---------------------------------------------------------------------------
# Export traversal
# ---------------------------------------------------------------------------


def find_inbox_dirs(export_root: Path) -> List[Path]:
    """Find every ``inbox`` directory inside a DYI export root.

    Accepts the export root, an already-pointed-at ``messages`` dir,
    or an ``inbox`` dir directly. Returns all that exist (de-duped,
    order-stable).
    """
    export_root = Path(export_root)
    found: List[Path] = []

    # If pointed directly at an inbox dir.
    if export_root.name == "inbox" and export_root.is_dir():
        found.append(export_root)

    for rel in _INBOX_RELATIVE_ROOTS:
        candidate = export_root / rel
        if candidate.is_dir() and candidate not in found:
            found.append(candidate)

    # Also accept "<root>/messages" pointed directly.
    if export_root.name == "messages":
        candidate = export_root / "inbox"
        if candidate.is_dir() and candidate not in found:
            found.append(candidate)

    return found


def parse_export(
    export_root: Path,
    operator_name: Optional[str] = None,
) -> List[FacebookThread]:
    """Parse every thread under a DYI export root.

    Args:
        export_root: Path to the unzipped export (or a messages/inbox
            dir directly).
        operator_name: Operator display name override. Falls back to
            ``resolve_operator_name()`` (env-driven) when None.

    Returns:
        List of FacebookThread (including T3-skipped threads so callers
        can inspect the verdict; the payload + JSON writers filter T3
        out). Threads whose operator cannot be identified are skipped
        with a log line and excluded from the list.

    Raises:
        FileNotFoundError: no inbox directory under the export root.
    """
    export_root = Path(export_root)
    resolved_operator = resolve_operator_name(operator_name)

    inbox_dirs = find_inbox_dirs(export_root)
    if not inbox_dirs:
        raise FileNotFoundError(
            f"No Facebook Messenger inbox found under {export_root}. "
            "Point --export-path at the unzipped 'Download Your "
            "Information' folder."
        )

    threads: List[FacebookThread] = []
    skipped_no_operator = 0

    for inbox in inbox_dirs:
        for thread_dir in sorted(p for p in inbox.iterdir() if p.is_dir()):
            thread = load_thread(thread_dir, resolved_operator)
            if thread is None:
                continue
            if not thread.messages:
                # No conversational content (pure system / media-less /
                # empty) -- skip gracefully.
                continue
            # Direction needs the operator. If we could not identify the
            # operator at all, or this thread does not contain them, we
            # cannot attribute direction reliably -> skip with a log.
            if resolved_operator is None:
                skipped_no_operator += 1
                continue
            # The operator counts as "present" if they sent at least one
            # message OR they appear in the thread's raw participant list
            # (a thread where the operator only received messages is still
            # attributable). ``operator_is_participant`` is captured from
            # the raw participants at load time, before the operator was
            # stripped out of ``thread.participants``.
            operator_present = (
                thread.operator_is_participant
                or any(m.is_from_operator for m in thread.messages)
            )
            if not operator_present:
                # Operator name set but never appears in this thread --
                # cannot establish "me"; skip rather than mis-attribute.
                logger.info(
                    "facebook_messenger: skipping thread %s "
                    "(operator not present)", thread.thread_slug,
                )
                skipped_no_operator += 1
                continue
            threads.append(thread)

    if skipped_no_operator:
        logger.info(
            "facebook_messenger: skipped %d thread(s) with no identifiable "
            "operator", skipped_no_operator,
        )
    logger.info(
        "facebook_messenger: parsed %d thread(s) (t1_dm=%d, t2_group=%d, "
        "t3_skip=%d)",
        len(threads),
        sum(1 for t in threads if t.tier == TIER_T1_DM),
        sum(1 for t in threads if t.tier == TIER_T2_GROUP),
        sum(1 for t in threads if t.tier == TIER_T3_SKIP),
    )
    return threads


# ---------------------------------------------------------------------------
# CM048 payload construction
# ---------------------------------------------------------------------------


def _slugify(value: str) -> str:
    """A conservative slug for the conversation id."""
    value = fix_mojibake(value).lower()
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    return value or "thread"


def thread_conversation_id(thread: FacebookThread) -> str:
    """Stable conversation id for a thread.

    Keyed off the thread slug (which Facebook makes stable across
    re-exports) plus the date of the first message, so a re-run of the
    same export produces the same id -- the CM048 writer's idempotency
    contract.
    """
    started = thread.started_at
    date_part = started.strftime("%Y%m%d") if started else "00000000"
    return f"fbm_{date_part}_{_slugify(thread.thread_slug)}"


def render_transcript(thread: FacebookThread) -> str:
    """Render a thread to a speaker-labelled transcript string.

    One line per message: ``[ISO timestamp] Sender: text``. This is
    the ``transcript`` field CM048's processor + conversation_writer
    consume.
    """
    lines: List[str] = []
    for m in thread.messages:
        ts = m.timestamp.strftime("%Y-%m-%d %H:%M")
        speaker = m.sender_name or "Unknown"
        lines.append(f"[{ts}] {speaker}: {m.text}")
    return "\n".join(lines)


def thread_to_payload(thread: FacebookThread) -> dict:
    """Convert a thread to a CM048 ``process()`` payload.

    Returns a dict with the three top-level keys CM048's
    ``processor.process(conversation_id, transcript, metadata)``
    expects, plus the metadata dict shaped per ``schemas.py`` and the
    facebook-channel ``channel_adapter`` extra keys.

    The ``metadata['privacy_level']`` is set EXPLICITLY (L2) so the
    CM048 adapter does not fall through to the L3 default for an
    unregistered channel.
    """
    conversation_id = thread_conversation_id(thread)
    started = thread.started_at
    ended = thread.ended_at
    started_iso = started.isoformat() if started else None
    ended_iso = ended.isoformat() if ended else None

    participants: List[dict] = []
    if thread.operator_name:
        participants.append(
            {"id": thread.operator_name, "display": thread.operator_name,
             "role": "user"}
        )
    for name in thread.participants:
        participants.append(
            {"id": name, "display": name, "role": "other"}
        )

    metadata = {
        "conversation_id": conversation_id,
        "date": (started.strftime("%Y-%m-%d") if started else "1970-01-01"),
        "source": SOURCE,
        "channel": CHANNEL,
        "source_app": SOURCE_APP,
        "participants": participants,
        "started_at": started_iso,
        "ended_at": ended_iso,
        "privacy_level": PRIVACY_L2,
        # Facebook-specific extra metadata (channel_adapter pulls a
        # subset of these into the bundle's extra_metadata when the
        # facebook adapter lands in CM048).
        "chat_type": "group" if thread.is_group else "private",
        "is_group_chat": thread.is_group,
        "group_subject": thread.title if thread.is_group else None,
        "thread_slug": thread.thread_slug,
        "contact_source_tier": thread.tier,
        "message_count": len(thread.messages),
    }

    return {
        "conversation_id": conversation_id,
        "transcript": render_transcript(thread),
        "metadata": metadata,
    }


# ---------------------------------------------------------------------------
# Summary stats (privacy-safe, counts only)
# ---------------------------------------------------------------------------


def conversation_stats(threads: Iterable[FacebookThread]) -> dict:
    """Counts-only summary for the install summary screen.

    Privacy: counts only -- no names, no titles, no bodies. Mirrors
    whatsapp_history.conversation_stats.
    """
    threads = list(threads)
    t1 = [t for t in threads if t.tier == TIER_T1_DM]
    t2 = [t for t in threads if t.tier == TIER_T2_GROUP]
    t3 = [t for t in threads if t.tier == TIER_T3_SKIP]

    unique_people: set[str] = set()
    for t in t1 + t2:
        unique_people.update(t.participants)

    total_messages = sum(len(t.messages) for t in t1 + t2)

    return {
        "tier_t1_dm_threads": len(t1),
        "tier_t2_group_threads": len(t2),
        "tier_t3_skipped_threads": len(t3),
        "ingestible_threads": len(t1) + len(t2),
        "total_messages": total_messages,
        "people_added": len(unique_people),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    """CLI for the install.sh hydrate sub-phase.

    Mirrors whatsapp_history.main: extract + classify + write a JSON
    file of CM048 payloads (T3 filtered out), and emit a counts-only
    JSON status line to stdout for install.sh to parse.

    Exit codes
    ----------
    0    success or graceful-skip (export missing, no operator name).
    2    argparse failure (Python default).
    1    unexpected crash.
    """
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        prog="pwg-facebook-messenger",
        description=(
            "Parse a Facebook Messenger 'Download Your Information' export "
            "into CM048 conversation payloads. Three-tier privacy posture: "
            "T1 DM, T2 group, T3 large+passive group (SKIP)."
        ),
    )
    parser.add_argument(
        "--export-path",
        type=Path,
        required=True,
        help=(
            "Path to the unzipped 'Download Your Information' export "
            "(or a messages/inbox directory directly)."
        ),
    )
    parser.add_argument(
        "--operator-name",
        type=str,
        default=None,
        help=(
            "Operator display name as it appears in the export. Defaults "
            "to OSTLER_USER_DISPLAY_NAME / WIKI_OPERATOR_NAME env vars."
        ),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory to write facebook_messenger_conversations.json. "
            "Default: ~/.ostler/imports/fda/"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a counts-only JSON status line to stdout.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse + classify but do not write the JSON output file.",
    )
    args = parser.parse_args(argv)

    result: dict = {
        "tier_t1_dm_threads": 0,
        "tier_t2_group_threads": 0,
        "tier_t3_skipped_threads": 0,
        "ingestible_threads": 0,
        "total_messages": 0,
        "people_added": 0,
        "errors": [],
        "status": "ok",
    }

    def _stderr(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    try:
        threads = parse_export(
            export_root=args.export_path,
            operator_name=args.operator_name,
        )
    except FileNotFoundError as exc:
        _stderr(f"pwg-facebook-messenger: export not found ({exc})")
        result["status"] = "not_found"
        if args.json:
            print(json.dumps(result))
        return 0
    except Exception as exc:  # noqa: BLE001 -- surface type only (privacy)
        msg = type(exc).__name__
        _stderr(f"pwg-facebook-messenger: unexpected failure ({msg})")
        result["status"] = "error"
        result["errors"].append(msg)
        if args.json:
            print(json.dumps(result))
        return 1

    # If no operator name could be resolved at all, the parser will
    # have skipped every thread; surface that as a graceful skip so
    # install.sh can render a "set your name" hint rather than a fail.
    if resolve_operator_name(args.operator_name) is None:
        _stderr(
            "pwg-facebook-messenger: operator name not configured "
            "(set OSTLER_USER_DISPLAY_NAME); skipping"
        )
        result["status"] = "no_operator"
        if args.json:
            print(json.dumps(result))
        return 0

    stats = conversation_stats(threads)
    result.update(stats)

    if not args.dry_run:
        output_dir = args.output_dir or (
            Path.home() / ".ostler" / "imports" / "fda"
        )
        output_dir.mkdir(parents=True, exist_ok=True)
        ingestible = [t for t in threads if t.tier != TIER_T3_SKIP]
        payloads = [thread_to_payload(t) for t in ingestible]
        try:
            (output_dir / "facebook_messenger_conversations.json").write_text(
                json.dumps(payloads, indent=2)
            )
        except OSError as exc:
            msg = type(exc).__name__
            _stderr(f"pwg-facebook-messenger: could not write JSON ({msg})")
            result["status"] = "write_error"
            result["errors"].append(msg)
            if args.json:
                print(json.dumps(result))
            return 0

    _stderr(
        f"pwg-facebook-messenger: parsed {stats['ingestible_threads']} "
        f"ingestible thread(s) "
        f"(t1={stats['tier_t1_dm_threads']}, "
        f"t2={stats['tier_t2_group_threads']}, "
        f"t3_skipped={stats['tier_t3_skipped_threads']}, "
        f"messages={stats['total_messages']}, "
        f"people_added={stats['people_added']})"
    )

    if args.json:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
