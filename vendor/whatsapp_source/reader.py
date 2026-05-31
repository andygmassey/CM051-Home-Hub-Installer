"""Read WhatsApp message BODIES out of the macOS app's ChatStorage.sqlite.

This is the body-extraction leg the metadata-only extractor
(``ostler_fda.whatsapp_history``) deliberately deferred. It reuses that
module's read-only open (``_open_readonly``) and three-tier classifier
(``classify_chat`` / ``extract_conversations``) wholesale so there is
exactly one WhatsApp reader on the Hub, exactly one set of tier
threshold lock-ins, and exactly one read-only safety contract. This
reader does not re-derive any of that; it only adds the message-body
pull and the per-chat utterance assembly the four-artefact feed needs.

The macOS WhatsApp Desktop client stores messages locally in a
Core-Data-backed SQLite database at::

    ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite

Full Disk Access (the same grant that gives iMessage's chat.db) covers
the WhatsApp container, so no new TCC prompt is needed.

Body columns (verified plaintext-readable in the read-only open the
metadata extractor already uses):

  - ``ZWAMESSAGE.ZTEXT``         the message text. NULL on media-only /
                                 system rows; we skip those.
  - ``ZWAMESSAGE.ZFROMJID``      the per-message author JID. NULL on
                                 messages the operator sent (ZISFROMME=1).
  - ``ZWAMESSAGE.ZISFROMME``     1 when the operator sent the message.
  - ``ZWAMESSAGE.ZMESSAGEDATE``  Mac-epoch REAL (seconds since
                                 2001-01-01 UTC).
  - ``ZWAMESSAGE.ZMESSAGETYPE``  0 = text. Non-zero = media / system /
                                 call event; ZTEXT is usually NULL there.

Privacy: this reader handles message TEXT, which the metadata extractor
never touched. The tier gate is enforced up front (T3 large-passive
chats are never read, exactly as the metadata extractor skips them) and
the L1/L2/L3 ladder is applied downstream by CM048. T3 stays a complete
skip here too: ``read_chats`` never pulls a single body for a T3 chat.

No real-person data is hard-coded here. ``db_path`` is injectable so
tests run against a synthetic ChatStorage-shaped sqlite fixture.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from ostler_fda.whatsapp_history import (
    DEFAULT_CHAT_DB,
    TIER_T3_SKIP,
    WhatsAppChat,
    _convert_timestamp,
    _is_real_participant_jid,
    _now_mac_ts,
    _open_readonly,
    classify_chat,
)

logger = logging.getLogger(__name__)

# Core-Data message-type literal for a plain text message. Non-text
# rows (media, calls, group system events) carry a non-zero type and a
# NULL / placeholder ZTEXT; we ingest text rows only so the transcript
# is words, not "[image omitted]" noise.
MESSAGE_TYPE_TEXT = 0


@dataclass
class WhatsAppUtterance:
    """One text message after body extraction.

    ``author_jid`` is the per-message sender (NULL in the DB for
    operator-sent rows; we normalise that to ``None`` and rely on
    ``is_from_me``). ``text`` is the plaintext ``ZTEXT`` body.
    """

    author_jid: Optional[str]
    is_from_me: bool
    timestamp: Optional[datetime]
    text: str


@dataclass
class WhatsAppConversation:
    """One in-tier WhatsApp chat with its message bodies attached.

    Wraps the classifier's ``WhatsAppChat`` verdict (tier, participants,
    group flag) and adds the ordered list of text utterances the
    transcript renderer + metadata builder consume.
    """

    chat: WhatsAppChat
    utterances: list[WhatsAppUtterance] = field(default_factory=list)
    group_subject: Optional[str] = None

    @property
    def chat_id(self) -> str:
        return self.chat.chat_id

    @property
    def tier(self) -> str:
        return self.chat.tier

    @property
    def is_group(self) -> bool:
        return self.chat.is_group

    @property
    def started_at(self) -> Optional[datetime]:
        for u in self.utterances:
            if u.timestamp is not None:
                return u.timestamp
        return None

    @property
    def ended_at(self) -> Optional[datetime]:
        for u in reversed(self.utterances):
            if u.timestamp is not None:
                return u.timestamp
        return self.chat.last_message


def _read_bodies_for_chat(
    conn: sqlite3.Connection,
    chat_pk: int,
    *,
    cutoff_mac_ts: Optional[float],
    max_messages: Optional[int],
) -> list[WhatsAppUtterance]:
    """Pull the text-message bodies for one chat session, oldest-first.

    Only ``ZMESSAGETYPE = 0`` (text) rows with a non-NULL, non-empty
    ``ZTEXT`` are returned, so media / system / call-event rows never
    pollute the transcript. ``cutoff_mac_ts`` bounds the window (the
    ``--since-days`` clamp); ``max_messages`` caps a runaway thread so a
    single huge chat cannot blow up one tick (newest ``max_messages``
    kept, then re-sorted oldest-first for the transcript).
    """
    sql = (
        "SELECT ZFROMJID, ZISFROMME, ZMESSAGEDATE, ZTEXT "
        "FROM ZWAMESSAGE "
        "WHERE ZCHATSESSION = ? AND ZMESSAGETYPE = ? "
        "AND ZTEXT IS NOT NULL AND ZTEXT != ''"
    )
    params: list = [chat_pk, MESSAGE_TYPE_TEXT]
    if cutoff_mac_ts is not None:
        sql += " AND ZMESSAGEDATE > ?"
        params.append(cutoff_mac_ts)
    # Newest-first + LIMIT so the cap keeps the most recent messages;
    # we reverse to oldest-first below for a readable transcript.
    sql += " ORDER BY ZMESSAGEDATE DESC"
    if max_messages is not None:
        sql += " LIMIT ?"
        params.append(max_messages)

    rows = conn.execute(sql, params).fetchall()
    utterances: list[WhatsAppUtterance] = []
    for row in rows:
        text = (row["ZTEXT"] or "").strip()
        if not text:
            continue
        is_from_me = bool(row["ZISFROMME"])
        author = row["ZFROMJID"]
        if not _is_real_participant_jid(author):
            author = None
        utterances.append(
            WhatsAppUtterance(
                author_jid=None if is_from_me else author,
                is_from_me=is_from_me,
                timestamp=_convert_timestamp(row["ZMESSAGEDATE"]),
                text=text,
            )
        )
    # We pulled newest-first (so LIMIT kept the recent tail); flip to
    # oldest-first for the rendered transcript.
    utterances.reverse()
    return utterances


def _group_subject(conn: sqlite3.Connection, chat_pk: int) -> Optional[str]:
    """Best-effort group display name for a group chat.

    ZWAGROUPINFO.ZSUBJECT holds the group subject on the macOS schema.
    The join is defensive: a missing column / table (older schema) just
    yields ``None`` rather than aborting the tick. The subject is a
    convenience for the bundle's ``group_subject`` extra-metadata field;
    its absence does not block ingest.
    """
    try:
        row = conn.execute(
            "SELECT gi.ZSUBJECT FROM ZWACHATSESSION cs "
            "JOIN ZWAGROUPINFO gi ON cs.ZGROUPINFO = gi.Z_PK "
            "WHERE cs.Z_PK = ?",
            (chat_pk,),
        ).fetchone()
    except sqlite3.OperationalError:
        return None
    if not row:
        return None
    subject = row[0]
    if isinstance(subject, str) and subject.strip():
        return subject.strip()
    return None


def read_chats(
    db_path: Optional[Path] = None,
    *,
    since_days: Optional[int] = 365,
    now_utc: Optional[datetime] = None,
    max_messages_per_chat: Optional[int] = 2000,
) -> list[WhatsAppConversation]:
    """Extract in-tier WhatsApp chats WITH message bodies.

    Reuses ``ostler_fda.whatsapp_history``'s read-only open + tier
    classifier, then pulls ``ZTEXT`` bodies for every T1 (DM) and T2
    (intimate / active group) chat. T3 (large-passive) chats are
    classified and then skipped without a single body read, exactly as
    the metadata extractor skips them.

    Args:
        db_path: ChatStorage.sqlite path (injectable for tests). Default
            is the standard container path.
        since_days: window clamp (default 365 -- "your last year of
            WhatsApp"). ``0`` or ``None`` disables the cutoff (matching
            the email + spoken readers). A positive value bounds BOTH the
            session-level last-message filter AND the per-message body
            pull so a fresh install does not bundle the whole store.
        now_utc: override for "now" (tests).
        max_messages_per_chat: cap on messages pulled per chat (newest
            kept). ``None`` for unbounded.

    Returns:
        List of ``WhatsAppConversation`` for the in-tier chats only
        (T3 dropped), each carrying its ordered text utterances. A chat
        with zero text bodies in-window is dropped (no empty bundle).

    Raises:
        PermissionError: FDA not granted.
        FileNotFoundError: ChatStorage.sqlite missing.
    """
    db_path = Path(db_path) if db_path else DEFAULT_CHAT_DB
    if not db_path.exists():
        raise FileNotFoundError(
            f"WhatsApp ChatStorage.sqlite not found at {db_path}. "
            "Install WhatsApp Desktop from the Mac App Store, then re-run."
        )
    now_utc = now_utc or datetime.now(timezone.utc)

    cutoff_mac_ts: Optional[float] = None
    session_cutoff_unix: Optional[float] = None
    # ``since_days`` of 0 (or None) disables the cutoff, matching the
    # email + spoken readers' ``if since_days:`` convention. Only a
    # positive window clamps.
    if since_days:
        cutoff_mac_ts = _now_mac_ts(now_utc - timedelta(days=since_days))
        session_cutoff_unix = (
            now_utc - timedelta(days=since_days)
        ).timestamp()

    conn = _open_readonly(db_path)
    out: list[WhatsAppConversation] = []
    try:
        sessions = conn.execute(
            "SELECT Z_PK, ZGROUPINFO, ZCONTACTJID, ZLASTMESSAGEDATE "
            "FROM ZWACHATSESSION "
            "ORDER BY ZLASTMESSAGEDATE DESC"
        ).fetchall()

        for row in sessions:
            last_dt = _convert_timestamp(row["ZLASTMESSAGEDATE"])
            if (
                session_cutoff_unix is not None
                and last_dt is not None
                and last_dt.timestamp() < session_cutoff_unix
            ):
                continue

            chat = classify_chat(
                chat_pk=row["Z_PK"],
                group_info_id=row["ZGROUPINFO"],
                contact_jid=row["ZCONTACTJID"],
                last_message=last_dt,
                conn=conn,
                now_utc=now_utc,
            )
            # T3 large-passive: never read a body. Complete skip, exactly
            # like the metadata extractor.
            if chat.tier == TIER_T3_SKIP:
                continue
            # A T1 chat with no real contact JID (status@broadcast et al.)
            # is not a conversation.
            if not chat.is_group and not chat.contact_jid:
                continue

            utterances = _read_bodies_for_chat(
                conn,
                row["Z_PK"],
                cutoff_mac_ts=cutoff_mac_ts,
                max_messages=max_messages_per_chat,
            )
            if not utterances:
                # In-tier but no text in-window (media-only, or all older
                # than the clamp). No empty bundle.
                continue

            subject = _group_subject(conn, row["Z_PK"]) if chat.is_group else None
            out.append(
                WhatsAppConversation(
                    chat=chat,
                    utterances=utterances,
                    group_subject=subject,
                )
            )
    finally:
        conn.close()

    logger.info(
        "Read %d in-tier WhatsApp chats with bodies (t1+t2; t3 skipped)",
        len(out),
    )
    return out
