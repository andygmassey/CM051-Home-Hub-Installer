"""Full-history catch-up for WhatsApp bundles (v1.0.108, catch-up 2/6).

The forward feed (``pipeline.process_whatsapp``) bundles each in-tier chat as
ONE conversation built from its newest 2,000 text messages inside the last
365 days, and skips any chat quiet for longer than that. Everything older was
never bundled. This adapter walks every in-tier chat (T1 DMs, T2 intimate and
active groups; T3 large passive groups stay skipped, by tier, exactly as the
forward feed and the metadata extractor skip them) BACKWARDS from that edge to
its first message, and bundles the older messages one conversation per
session (a new session after a 6-hour quiet gap, the same gap the iMessage
feed uses).

WHERE EACH CHAT STARTS. A chat in the forward state (``chats``) has had its
forward window bundled, so the walk starts just below the oldest message of
that window (the newest ``max_messages_per_chat`` text rows after the
``since_days`` cutoff, both read from ``process_whatsapp``'s own defaults).
Any other chat starts at its newest message.

IDS. ``renderer.conversation_id_for`` on the session (chat id + the session's
first message time). Every session is strictly older than the forward edge,
so no catch-up id can equal the forward bundle's.

ORDER. Same frontier rule as the iMessage adapter: each batch takes the chat
whose next unread message is newest, so the largest frontier only falls and
is the honest "back to" date. Counts only in logs.
"""
from __future__ import annotations

import inspect
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import ostler_catchup as oc
from ostler_fda.imessage import is_assistant_send
from ostler_fda.whatsapp_history import (
    DEFAULT_CHAT_DB,
    TIER_T3_SKIP,
    _convert_timestamp,
    _is_real_participant_jid,
    _now_mac_ts,
    _open_readonly,
    classify_chat,
)

from .pipeline import (
    _dispatch_to_cm048,
    _label_lookup,
    _load_contacts_map,
    _load_label_map,
    _name_resolver,
    _resolve_pwg_convo_cmd,
    process_whatsapp,
)
from .reader import (
    MESSAGE_TYPE_TEXT,
    WhatsAppConversation,
    WhatsAppUtterance,
    _group_subject,
)
from .renderer import build_metadata, conversation_id_for, render_transcript

logger = logging.getLogger(__name__)

_FWD = inspect.signature(process_whatsapp).parameters
FORWARD_SINCE_DAYS = _FWD["since_days"].default
FORWARD_PER_CHAT_LIMIT = _FWD["max_messages_per_chat"].default

SESSION_GAP = timedelta(hours=6)
_PAGE = 500
_NO_BOUND = float(1 << 62)
_BIG_PK = 1 << 62

_ROWS_SQL = (
    "SELECT Z_PK, ZFROMJID, ZISFROMME, ZMESSAGEDATE, ZTEXT FROM ZWAMESSAGE "
    "WHERE ZCHATSESSION = ? AND ZMESSAGETYPE = ? AND ZTEXT IS NOT NULL AND ZTEXT != '' "
    "AND ZMESSAGEDATE IS NOT NULL "
    "AND (ZMESSAGEDATE < ? OR (ZMESSAGEDATE = ? AND Z_PK < ?)) "
    "ORDER BY ZMESSAGEDATE DESC, Z_PK DESC LIMIT ?"
)


def _row_to_utterance(row) -> Optional[WhatsAppUtterance]:
    """``reader._read_bodies_for_chat``'s own per-row rule."""
    text = (row["ZTEXT"] or "").strip()
    if not text:
        return None
    is_from_me = bool(row["ZISFROMME"])
    if is_assistant_send(text, from_owner=is_from_me):
        return None
    author = row["ZFROMJID"]
    if not _is_real_participant_jid(author):
        author = None
    return WhatsAppUtterance(
        author_jid=None if is_from_me else author,
        is_from_me=is_from_me,
        timestamp=_convert_timestamp(row["ZMESSAGEDATE"]),
        text=text,
    )


class WhatsAppCatchup(oc.Adapter):
    source = "whatsapp"
    doctor_row = "whatsapp"
    batch_size = 120  # text rows per batch, extended to a whole session

    def __init__(self, *, db_path: Optional[Path] = None, contacts_path: Optional[Path] = None,
                 user_display_name: Optional[str] = None, state_path: Optional[Path] = None,
                 pwg_convo_cmd: Optional[list] = None, now_utc: Optional[datetime] = None):
        self.db_path = Path(db_path) if db_path else DEFAULT_CHAT_DB
        self.state_path = state_path
        self.user_display_name = user_display_name or os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
        self.pwg_convo_cmd = pwg_convo_cmd
        self.now_utc = now_utc
        contacts = _load_contacts_map(contacts_path)
        self._name = _name_resolver(contacts)
        self._contact_labels = _load_label_map(contacts_path, "contacts", "contact_label")
        self._contact_privacy = _load_label_map(contacts_path, "contacts", "privacy_level")
        self._group_labels = _load_label_map(contacts_path, "groups", "group_label")
        self._group_privacy = _load_label_map(contacts_path, "groups", "privacy_level")
        self._chats: dict = {}

    def start_cursor(self):
        return None  # built on the first batch, inside the loop's error handling

    def _classify(self, conn, now):
        """In-tier chats only: {chat_id: WhatsAppChat} keyed by session pk."""
        out = {}
        for row in conn.execute(
                "SELECT Z_PK, ZGROUPINFO, ZCONTACTJID, ZLASTMESSAGEDATE FROM ZWACHATSESSION").fetchall():
            chat = classify_chat(chat_pk=row["Z_PK"], group_info_id=row["ZGROUPINFO"],
                                 contact_jid=row["ZCONTACTJID"],
                                 last_message=_convert_timestamp(row["ZLASTMESSAGEDATE"]),
                                 conn=conn, now_utc=now)
            if chat.tier == TIER_T3_SKIP:
                continue
            if not chat.is_group and not chat.contact_jid:
                continue
            out[str(row["Z_PK"])] = chat
        return out

    def _head(self, conn, pk, before):
        r = conn.execute(_ROWS_SQL, (int(pk), MESSAGE_TYPE_TEXT, before[0], before[0], before[1], 1)).fetchone()
        return None if r is None else r["ZMESSAGEDATE"]

    def _initial(self, conn, now):
        """Where each chat's walk starts: just below the window the forward
        feed bundles (or will bundle) for it.

        EVERY in-tier chat starts below that window, whether or not the forward
        state has recorded it yet. A chat the forward feed has not reached (a
        new chat, or this tick running before the next forward tick) used to
        start at its newest message, so catch-up bundled the newest sessions
        under session ids and the forward feed then bundled the same messages
        again as one chat-wide conversation under another id: the same message
        in two conversations."""
        cutoff = _now_mac_ts(now - timedelta(days=FORWARD_SINCE_DAYS)) if FORWARD_SINCE_DAYS else None
        chats = {}
        for pk, chat in self._classify(conn, now).items():
            before = [_NO_BOUND, _BIG_PK]
            sql = ("SELECT ZMESSAGEDATE, Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION = ? "
                   "AND ZMESSAGETYPE = ? AND ZTEXT IS NOT NULL AND ZTEXT != ''")
            params = [int(pk), MESSAGE_TYPE_TEXT]
            if cutoff is not None:
                sql += " AND ZMESSAGEDATE > ?"
                params.append(cutoff)
            sql += " ORDER BY ZMESSAGEDATE DESC LIMIT 1 OFFSET ?"
            params.append(FORWARD_PER_CHAT_LIMIT - 1)
            edge = conn.execute(sql, params).fetchone()
            if edge is not None:
                before = [edge["ZMESSAGEDATE"], edge["Z_PK"]]
            elif cutoff is not None:
                before = [cutoff, _BIG_PK]   # the forward read everything after the cutoff
            else:
                continue                      # no cutoff, under the cap: all bundled
            head = self._head(conn, pk, before)
            if head is not None:
                chats[pk] = {"before": before, "head": head}
        return chats

    def next_batch(self, cursor, limit):
        now = self.now_utc or datetime.now(timezone.utc)
        conn = _open_readonly(self.db_path)
        try:
            if not self._chats:
                self._chats = self._classify(conn, now)
            if cursor is None:
                chats = self._initial(conn, now)
            else:
                chats = {k: dict(v) for k, v in cursor.get("chats", {}).items()}
            if not chats:
                return oc.Batch(items=[], next_cursor={"chats": {}}, oldest_at=None, exhausted=True)
            pk = max(chats, key=lambda k: chats[k]["head"])
            before = list(chats[pk]["before"])
            gap = SESSION_GAP.total_seconds()
            rows = []
            while True:
                page = conn.execute(_ROWS_SQL, (int(pk), MESSAGE_TYPE_TEXT, before[0], before[0],
                                                before[1], _PAGE)).fetchall()
                start = len(rows)
                rows.extend(page)
                cut = None
                for i in range(max(start, limit, 1), len(rows)):
                    if rows[i - 1]["ZMESSAGEDATE"] - rows[i]["ZMESSAGEDATE"] > gap:
                        cut = i
                        break
                if cut is not None:
                    rows = rows[:cut]
                    break
                if len(page) < _PAGE:
                    break
                before = [rows[-1]["ZMESSAGEDATE"], rows[-1]["Z_PK"]]
            chat = self._chats.get(pk)
            subject = _group_subject(conn, int(pk)) if chat is not None and chat.is_group else None
            last = rows[-1] if rows else None
            nxt = None
            if last is not None:
                nxt = self._head(conn, pk, [last["ZMESSAGEDATE"], last["Z_PK"]])
        finally:
            conn.close()

        items = []
        if chat is not None:
            utts = [u for u in (_row_to_utterance(r) for r in reversed(rows)) if u is not None]
            session: list = []
            for u in utts:
                if session and (u.timestamp - session[-1].timestamp) > SESSION_GAP:
                    items.append(WhatsAppConversation(chat=chat, utterances=session, group_subject=subject))
                    session = []
                session.append(u)
            if session:
                items.append(WhatsAppConversation(chat=chat, utterances=session, group_subject=subject))
        if nxt is None:
            del chats[pk]
        else:
            chats[pk] = {"before": [last["ZMESSAGEDATE"], last["Z_PK"]], "head": nxt}
        if chats:
            oldest = _convert_timestamp(max(v["head"] for v in chats.values()))
        else:
            oldest = _convert_timestamp(last["ZMESSAGEDATE"]) if last is not None else None
        return oc.Batch(items=items, next_cursor={"chats": chats},
                        oldest_at=oc.to_iso(oldest), exhausted=not chats)

    def key(self, conv):
        return conversation_id_for(conv)

    def process(self, conv):
        if conv.is_group:
            gkey = f"group:{conv.chat_id}"
            group_label = _label_lookup(self._group_labels, gkey)
            privacy = _label_lookup(self._group_privacy, gkey)
            contact_label = None
        else:
            contact_label = _label_lookup(self._contact_labels, conv.chat.contact_jid)
            privacy = _label_lookup(self._contact_privacy, conv.chat.contact_jid)
            group_label = None
        transcript = render_transcript(conv, name_for_jid=self._name,
                                       user_display_name=self.user_display_name)
        metadata = build_metadata(conv, name_for_jid=self._name,
                                  user_display_name=self.user_display_name,
                                  privacy_level=privacy, contact_label=contact_label,
                                  group_label=group_label)
        rc = _dispatch_to_cm048(transcript, metadata,
                                pwg_convo_cmd=self.pwg_convo_cmd or _resolve_pwg_convo_cmd(),
                                dry_run=False)
        return rc == 0


def adapters():
    """Factory for ``ostler_catchup run --adapters whatsapp_source.catchup:adapters``."""
    db = os.environ.get("OSTLER_WHATSAPP_CHAT_DB", "").strip()
    contacts = os.environ.get("OSTLER_CONTACTS", "").strip()
    return [WhatsAppCatchup(db_path=Path(db) if db else None,
                            contacts_path=Path(contacts) if contacts else None)]
