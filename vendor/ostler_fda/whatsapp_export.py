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
import json
import os
import re
import unicodedata
from collections import Counter
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


def chat_to_payload(chat: WhatsAppChat, cid: Optional[str] = None) -> dict:
    """CM048 ``process()`` payload: conversation_id, transcript, metadata.

    ``cid`` pins the id of the FULL chat when ``chat`` holds only the messages
    not already in the live store, so a supplement keeps the same conversation.
    """
    cid = cid or conversation_id(chat)
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


# --- Dedupe against the live WhatsApp store (2026-11-14) ----------------------
#
# The live path (vendor/whatsapp_source/pipeline.py) writes a per-chat index of
# message keys on every successful bundle. An export is a SUPPLEMENT: a message
# whose key is already in the index is dropped before persisting, and a chat
# with nothing left is skipped. Key = minute | hash(sender) | hash(text), with
# the minute in the owner's LOCAL zone (export times are local; live times are
# UTC and are converted). Only hashes are stored, never names or bodies.
#
# The normaliser strips ONLY invisible marks (Unicode category Cf) and collapses
# whitespace runs. It never touches digits, punctuation or case, so "12" and "21"
# stay distinct. Matching is a multiset: each live message consumes one export
# message, so two identical lines in the same minute are both kept if the live
# store has only one.

LIVE_INDEX_FILENAME = "whatsapp_live_message_keys.json"
_LIVE_HEADER = re.compile(r"^\*\*(.+?)\*\* \((\d{4}-\d{2}-\d{2}T[^)]+)\):$")
_NO_TEXT = "[no text]"  # what the live renderer writes for an empty body


def _plain(text: str) -> str:
    """Strip invisible marks and collapse whitespace. Nothing else changes."""
    kept = "".join(ch for ch in text if unicodedata.category(ch) != "Cf")
    return re.sub(r"\s+", " ", kept).strip()


def _digest(text: str, n: int) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:n]


def message_key(local_dt: datetime, sender: str, text: str,
                owner_names: Iterable[str] = ()) -> str:
    """The key both paths compute. ``local_dt`` is naive, in the owner's zone."""
    who = _plain(sender)
    owners = {_plain(n).casefold() for n in owner_names if _plain(n)}
    if who == "You" or who.casefold() in owners:
        who = "You"
    minute = local_dt.strftime("%Y-%m-%dT%H:%M")
    return f"{minute}|{_digest(who, 16)}|{_digest(_plain(text), 32)}"


def live_messages_from_transcript(transcript_md: str) -> List[Tuple[datetime, str, str]]:
    """Parse the live renderer's output: ``**Speaker** (ISO):`` then the text.

    Returns (local naive timestamp, speaker, text). The renderer writes
    ``[no text]`` for an empty body; that maps back to an empty text.
    """
    blocks: List[dict] = []
    for line in transcript_md.splitlines():
        m = _LIVE_HEADER.match(line)
        if m:
            blocks.append({"speaker": m.group(1), "ts": m.group(2), "lines": []})
        elif blocks:
            blocks[-1]["lines"].append(line)
    out: List[Tuple[datetime, str, str]] = []
    for b in blocks:
        text = "\n".join(b["lines"]).strip()
        if text == _NO_TEXT:
            text = ""
        aware = datetime.fromisoformat(b["ts"].replace("Z", "+00:00"))
        if aware.tzinfo is None:
            raise ValueError(f"live timestamp has no zone: {b['ts']!r}")
        local = aware.astimezone().replace(tzinfo=None)
        out.append((local, b["speaker"], text))
    return out


def default_live_index_path() -> Path:
    """The same state dir the live pipeline uses (OSTLER_STATE_DIR, STATE_DIR)."""
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    base = Path(override).expanduser() if override else Path.home() / ".ostler" / "workspace"
    return base / LIVE_INDEX_FILENAME


def owner_names_from_env() -> List[str]:
    """Names the export uses for the owner (comma separated). Empty by default."""
    raw = os.getenv("OSTLER_WHATSAPP_OWNER_NAMES", "")
    return [n for n in (x.strip() for x in raw.split(",")) if n]


def record_live_transcript(conv_id: str, transcript_md: str, index_path: Path,
                           owner_names: Iterable[str] = ()) -> int:
    """Replace this chat's entry in the live index with its current message keys.

    A chat is re-bundled whole on every new reply, so the entry is REPLACED,
    never appended: a re-bundled message is never counted twice. Written to a
    temp file and moved into place. Returns the number of keys recorded.
    """
    keys = [message_key(ts, sp, tx, owner_names)
            for ts, sp, tx in live_messages_from_transcript(transcript_md)]
    index_path = Path(index_path)
    index_path.parent.mkdir(parents=True, exist_ok=True)
    data: dict = {}
    if index_path.exists():
        data = json.loads(index_path.read_text(encoding="utf-8"))
    data[conv_id] = keys
    tmp = index_path.with_name(index_path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, index_path)
    return len(keys)


def live_key_counts(index_path: Path) -> Counter:
    """Every live message key, as a multiset. Missing index: empty (nothing live)."""
    index_path = Path(index_path)
    if not index_path.exists():
        return Counter()
    data = json.loads(index_path.read_text(encoding="utf-8"))
    counts: Counter = Counter()
    for keys in data.values():
        counts.update(keys)
    return counts


def drop_already_live(chat: WhatsAppChat, live: Counter,
                      owner_names: Iterable[str] = ()) -> Tuple[WhatsAppChat, int]:
    """Return the chat with messages already in the live store removed, and how
    many were matched. Each live key matches at most its own count."""
    remaining = Counter(live)
    kept: List[Message] = []
    matched = 0
    for m in chat.messages:
        k = message_key(m.timestamp, m.sender, m.text, owner_names)
        if remaining[k] > 0:
            remaining[k] -= 1
            matched += 1
        else:
            kept.append(m)
    return WhatsAppChat(name=chat.name, messages=kept), matched
