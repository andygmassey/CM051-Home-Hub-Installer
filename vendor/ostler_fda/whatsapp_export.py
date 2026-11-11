"""Parse a WhatsApp per-chat export (.txt) into CM048 conversation payloads.

WhatsApp's "Export chat" writes one text file per chat. The file is either
dropped loose as ``WhatsApp Chat with <name>.txt`` or sits inside a .zip as
``_chat.txt`` (iOS). Two line shapes exist, and both are handled:

    iOS      [dd/mm/yyyy, hh:mm:ss] Name: text
    Android  dd/mm/yyyy, hh:mm - Name: text

Rules, all pinned by tests/test_whatsapp_export_autoprocess.py:

- A line that starts with a timestamp and has a ``Name: `` part opens a new
  message. Any other line is a continuation of the previous message, joined
  with a newline. A continuation with no previous message is dropped.
- A timestamped line with no ``Name: `` part is a system line ("Messages and
  calls are end-to-end encrypted", "X joined using this group's invite link")
  and is skipped, never attached to the message before it.
- ``<attached: ...>`` and ``<Media omitted>`` are not content. Each becomes
  the placeholder ``[attachment]`` so the turn stays visible in the transcript
  without leaking a filename.
- Dates are day-first, the WhatsApp default. Two-digit years mean 20xx.

Privacy: the payload carries L2 explicitly (the same level the Messenger
dispatcher uses), so CM048 never falls through to its L3 default. Counts-only
stats are returned for the install summary; no names or bodies leave here.

Synthetic fixtures only in tests. No real chat is ever read by the test suite.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

SOURCE = "whatsapp_export"
CHANNEL = "whatsapp"
SOURCE_APP = "whatsapp_desktop_export"
PRIVACY_L2 = "L2"
OUTPUT_FILENAME = "whatsapp_export_conversations.json"

_DATE = r"(\d{1,2}/\d{1,2}/\d{2,4})"
_TIME = r"(\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?)"
_PREFIX_IOS = re.compile(r"^\[" + _DATE + r",?\s+" + _TIME + r"\]\s?(.*)$")
_PREFIX_ANDROID = re.compile(r"^" + _DATE + r",?\s+" + _TIME + r"\s[-–]\s(.*)$")
_SENDER = re.compile(r"^([^:]{1,80}?):\s(.*)$", re.DOTALL)
_MEDIA = re.compile(r"<attached:[^>]*>|<Media omitted>", re.IGNORECASE)
_BIDI = "‎‏﻿"


@dataclass
class Message:
    timestamp: datetime
    sender: str
    text: str


@dataclass
class WhatsAppChat:
    name: str
    messages: List[Message] = field(default_factory=list)

    @property
    def senders(self) -> List[str]:
        seen: List[str] = []
        for m in self.messages:
            if m.sender not in seen:
                seen.append(m.sender)
        return seen


def _parse_timestamp(date_s: str, time_s: str) -> Optional[datetime]:
    d, mth, y = date_s.split("/")
    year = int(y)
    if year < 100:
        year += 2000
    t = time_s.replace(" ", "").upper()
    fmt_time = "%I:%M:%S%p" if t.endswith(("AM", "PM")) and t.count(":") == 2 else (
        "%I:%M%p" if t.endswith(("AM", "PM")) else ("%H:%M:%S" if t.count(":") == 2 else "%H:%M"))
    try:
        hm = datetime.strptime(t, fmt_time)
        return datetime(year, int(mth), int(d), hm.hour, hm.minute, hm.second)
    except ValueError:
        return None


def _split_line(line: str) -> Optional[Tuple[datetime, str]]:
    """Return (timestamp, rest-after-timestamp) when the line opens with a stamp."""
    for rx in (_PREFIX_IOS, _PREFIX_ANDROID):
        m = rx.match(line)
        if m:
            ts = _parse_timestamp(m.group(1), m.group(2))
            if ts is None:
                return None
            return ts, m.group(3)
    return None


def _clean_text(text: str) -> str:
    text = _MEDIA.sub("[attachment]", text)
    return text.strip()


def chat_name_for(path: Path) -> str:
    stem = path.stem
    if stem.lower() == "_chat":
        return path.parent.name or "WhatsApp chat"
    name = re.sub(r"^whatsapp chat with\s+", "", stem, flags=re.IGNORECASE)
    return name.strip() or "WhatsApp chat"


def parse_chat_text(text: str, name: str) -> WhatsAppChat:
    chat = WhatsAppChat(name=name)
    for raw in text.splitlines():
        line = raw.lstrip(_BIDI).rstrip("\r")
        split = _split_line(line)
        if split is None:
            # Continuation of the previous message, if there is one.
            if chat.messages and line.strip():
                chat.messages[-1].text = f"{chat.messages[-1].text}\n{line}"
            continue
        ts, rest = split
        sm = _SENDER.match(rest)
        if sm is None:
            continue  # system line: no sender, never attached to the message above
        sender = sm.group(1).strip().lstrip(_BIDI).strip()
        body = sm.group(2)
        if not sender:
            continue
        chat.messages.append(Message(timestamp=ts, sender=sender, text=body))
    for m in chat.messages:
        m.text = _clean_text(m.text)
    return chat


def parse_chat_file(path: Path) -> WhatsAppChat:
    raw = Path(path).read_bytes().decode("utf-8", errors="ignore")
    return parse_chat_text(raw, chat_name_for(Path(path)))


def conversation_id(chat: WhatsAppChat) -> str:
    """Stable id: the same export re-run gives the same id (CM048 idempotency)."""
    first = chat.messages[0].timestamp.isoformat() if chat.messages else ""
    digest = hashlib.sha256(f"{chat.name}|{first}".encode("utf-8")).hexdigest()[:12]
    slug = re.sub(r"[^a-z0-9]+", "-", chat.name.lower()).strip("-")[:40] or "chat"
    return f"wae_{digest}_{slug}"


def render_transcript(chat: WhatsAppChat) -> str:
    lines: List[str] = []
    for m in chat.messages:
        ts = m.timestamp.strftime("%Y-%m-%d %H:%M")
        lines.append(f"[{ts}] {m.sender}: {m.text}")
    return "\n".join(lines)


def chat_to_payload(chat: WhatsAppChat) -> dict:
    """CM048 ``process()`` payload: conversation_id, transcript, metadata."""
    cid = conversation_id(chat)
    first = chat.messages[0].timestamp if chat.messages else None
    last = chat.messages[-1].timestamp if chat.messages else None
    participants = [{"id": s, "display": s, "role": "other"} for s in chat.senders]
    metadata = {
        "conversation_id": cid,
        "date": first.strftime("%Y-%m-%d") if first else "1970-01-01",
        "source": SOURCE,
        "channel": CHANNEL,
        "source_app": SOURCE_APP,
        "participants": participants,
        "started_at": first.isoformat() if first else None,
        "ended_at": last.isoformat() if last else None,
        "privacy_level": PRIVACY_L2,
        "chat_type": "group" if len(chat.senders) > 2 else "private",
        "is_group_chat": len(chat.senders) > 2,
        "group_subject": chat.name if len(chat.senders) > 2 else None,
        "message_count": len(chat.messages),
    }
    return {"conversation_id": cid, "transcript": render_transcript(chat), "metadata": metadata}


def conversation_stats(chats: Iterable[WhatsAppChat]) -> dict:
    """Counts only. No names, no bodies."""
    chats = list(chats)
    return {
        "chats": len(chats),
        "messages": sum(len(c.messages) for c in chats),
    }
