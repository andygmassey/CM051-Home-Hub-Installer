"""Parse a Google Takeout "Google Chat" export into CM048 conversation payloads.

Background
==========

Google Chat history leaves Google, without any developer API, through
Takeout (takeout.google.com, product "Google Chat"). The Chat API route is
deliberately NOT used: its only read scope (``chat.messages.readonly``) is a
Google RESTRICTED scope, which needs restricted-scope verification plus an
annual CASA assessment for an Ostler-owned client. Takeout needs neither: it
is the owner exporting their own data with Google's own feature.

Layout (UNVERIFIED against a real export)
=========================================

No Google page documents this layout. It is taken from community parsers and
guides, and every field below is UNVERIFIED until a real export is opened.
The parser is therefore tolerant: every key it reads has fallbacks, an
unknown or missing key degrades that one field, and a file that cannot be
read is reported per file and never aborts the rest of the export::

    Takeout/Google Chat/
        Groups/
            DM <group id>/                 (UNVERIFIED: "DM " prefix)
                group_info.json            (UNVERIFIED)
                messages.json              (UNVERIFIED)
                File-<name>.<ext>          (attachments, UNVERIFIED naming)
            Space <group id>/              (UNVERIFIED: "Space " prefix)
                group_info.json
                messages.json
        Users/
            User <user id>/
                user_info.json             (UNVERIFIED)

``group_info.json`` (UNVERIFIED)::

    {"name": "<space name, absent for a DM>",
     "members": [{"name": "...", "email": "...", "user_type": "Human"}]}

``messages.json`` (UNVERIFIED)::

    {"messages": [
       {"creator": {"name": "...", "email": "...", "user_type": "Human"},
        "created_date": "Wednesday, 1 February 2023 at 15:04:05 UTC",
        "text": "...",
        "topic_id": "<thread id>",
        "message_id": "<id>",
        "annotations": [...],
        "attached_files": [{"original_name": "...", "export_name": "..."}]}
    ]}

``user_info.json`` (UNVERIFIED)::

    {"user": {"name": "...", "email": "...", "user_type": "Human"},
     "membership_info": [{"group_name": "...", "group_id": "...",
                          "membership_state": "..."}]}

Field tolerance, per field (first key present wins; every alias after the
first is a GUESS at a rename and is UNVERIFIED):

    author      creator | sender | author
    body        text | content | message
    timestamp   created_date | create_time | createTime | timestamp
    thread      topic_id | thread_id | topicId
    message id  message_id | id | name
    files       attached_files | attachments
    members     members | participants | memberships

``created_date`` is a human-readable, LOCALE-DEPENDENT string in every
community sample (UNVERIFIED). We parse the English long forms, with and
without the weekday, 12- and 24-hour, with the narrow no-break space newer
Google surfaces put before AM/PM, plus ISO 8601 and epoch seconds /
milliseconds / microseconds, and the long forms of German, French, Spanish,
Italian, Portuguese and Dutch (month names and joining words mapped to
English; UNVERIFIED shapes). Zones: UTC/GMT, numeric offsets and "GMT+8"
style are honoured; a string with no zone is read in the owner's zone and
counted ``tz_assumed_local``; a zone ABBREVIATION we cannot place ("HKT",
"PST") is never guessed: that timestamp is undated and counted
``tz_unplaced``. An undated message is kept (never dropped) and filed under
the previous dated message's day. A messages.json where more than half the
messages are undated is reported LOUDLY per file (``unparsed_dates`` /
``unplaced_zone``) and produces no conversations, rather than collapsing a
whole non-English export into one undated pile.

Fidelity limits (from the research, not measured): edit history is absent
(final text only), deleted messages are absent, and the org's Chat retention
policy may already have deleted old history before any export runs.

Conversation unit
=================

One conversation per (group, calendar day in the OWNER'S local zone:
``OSTLER_OWNER_TZ`` / ``TZ`` / the Mac's /etc/localtime, or ``--tz``). A multi-year DM in a single
transcript would be too large for the CM048 pipeline and useless as a page.
Thread replies (``topic_id`` shared by more than one message) are tagged in
the transcript so a reader can follow a thread inside a day. A thread that
crosses the owner's local midnight is split across two days' conversations (documented,
deliberate: the day boundary is the stable id).

``conversation_id = gchat_<YYYYMMDD>_<slug of the group folder id>``: a
re-run of the same export produces the same ids, the CM048 writer's
idempotency contract. On top of that, :class:`ImportLedger` records a
content hash per conversation id once the pipeline has accepted it, so a
second run of the same export hands the pipeline NOTHING (0 new artefacts,
and no model time spent re-reading unchanged history). A later export that
adds messages to a day changes that day's hash and only that day is re-sent.

Channel and privacy
===================

``metadata['channel'] = "im"``, ``metadata['source'] = "google_chat"``.
CM048's bundle adapter table has an ``im`` adapter (the iMessage/SMS one,
which keeps ``source`` as the bundle's ``source_subtype``); it has NO entry
for a source-named channel, so a channel like ``"google_chat"`` would write
no four-artefact bundle at all (the NotImplementedError is swallowed in
``processor._step_ingest`` and in ``seed.seed_conversation``). The
privacy level is set EXPLICITLY (``L2``) on every payload, as the Facebook
parser does, so no table default is relied on. Large passive spaces are
skipped entirely (T3, same thresholds as ``facebook_messenger``).

People
======

Every human author carries an EMAIL, the strongest join into the People
graph of any chat source. :func:`correspondents` returns ``{email: count}``
of messages each non-owner human sent; :func:`persist` hands that map to the
EXISTING email-correspondent sink (``universal_import._persist_mail_contacts``
driving ``pwg_ingest.ingest_mail_contacts``), which resolves an address that
any person already holds before it creates anything. Then each display name
is offered through ``pwg_ingest._upsert_display_name``, which only ever moves
a name UP the tier table (an address-named node gains a real name; a real
name is never replaced). This module owns no graph writes of its own.

Owner identity
==============

The owner is the exporting account: ``Users/User */user_info.json``
``user.email``. ``--owner-email`` overrides it. Without either, the owner is
inferred ONLY when exactly one email is a member of every group in the
export; otherwise the run reports ``status="no_owner"`` and emits nothing (a
transcript with the direction wrong is worse than none).

Privacy of output
=================

This module reads message bodies (the transcript is the point). Every log
line, error record and the ``--json`` stdout status are counts and relative
file paths only: no names, no emails, no bodies, no space names.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SOURCE = "google_chat"
SOURCE_APP = "google_chat"
# CM048 routes on ``channel``; "im" is the registered chat adapter (see the
# module docstring for why a source-named channel would write no bundle).
CHANNEL = "im"
PRIVACY_L2 = "L2"

TIER_T1_DM = "google_chat_dm"
TIER_T2_GROUP = "google_chat_group"
TIER_T3_SKIP = "google_chat_skipped"  # never emitted as a payload

# Same lock-ins as facebook_messenger / whatsapp_history.
INTIMATE_PARTICIPANT_MAX = 10
ENGAGEMENT_FLOOR_RELATIVE = 0.02

PLACEHOLDER_ATTACHMENT = "[attachment]"

# More than this share of a file's messages undated: the file is reported and
# skipped (loud), never bucketed as one undated conversation.
UNPARSED_DATE_RATIO = 0.5

# Field aliases. The FIRST entry is the community-documented name; every
# later entry is a guess at a rename and is UNVERIFIED.
_AUTHOR_KEYS = ("creator", "sender", "author")
_BODY_KEYS = ("text", "content", "message")
_TIME_KEYS = ("created_date", "create_time", "createTime", "timestamp")
_TOPIC_KEYS = ("topic_id", "thread_id", "topicId")
_ID_KEYS = ("message_id", "id", "name")
_FILES_KEYS = ("attached_files", "attachments")
_MEMBER_KEYS = ("members", "participants", "memberships")
_DELETED_STATES = {"DELETED", "deleted"}

_DM_PREFIX = "DM "
_SPACE_PREFIX = "Space "


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class FileError:
    """One file that could not be read as expected. Path is RELATIVE to the
    export root and the reason is a fixed vocabulary: safe to log."""

    path: str
    reason: str          # missing | unreadable | bad_json | unexpected_shape
    detail: str = ""     # exception TYPE or the offending key, never content

    def to_dict(self) -> dict:
        return {"path": self.path, "reason": self.reason, "detail": self.detail}


@dataclass
class ChatAuthor:
    name: str
    email: str           # lowercased, "" when the export omits it
    user_type: str       # "human" | "bot" | "unknown"

    @property
    def key(self) -> str:
        return self.email or f"name:{self.name}"


@dataclass
class ChatMessage:
    author: ChatAuthor
    text: str
    timestamp: Optional[datetime]
    topic_id: str
    message_id: str
    attachments: List[dict] = field(default_factory=list)
    index: int = 0       # file order, the tiebreak for undated messages


@dataclass
class ChatGroup:
    folder: str          # folder name, e.g. "DM abc" (relative id source)
    group_key: str       # folder id with the DM/Space prefix removed
    kind: str            # "dm" | "space"
    name: Optional[str]  # space name (None for a DM)
    members: List[ChatAuthor]
    messages: List[ChatMessage] = field(default_factory=list)
    tier: str = TIER_T1_DM
    dates_unparsed: bool = False

    @property
    def is_group(self) -> bool:
        humans = [m for m in self.members if m.user_type != "bot"]
        return self.kind == "space" or len(humans) > 2


@dataclass
class ChatExport:
    root: Path
    owner_email: Optional[str]
    owner_name: Optional[str]
    owner_source: str    # "user_info" | "argument" | "inferred" | "none"
    groups: List[ChatGroup] = field(default_factory=list)
    errors: List[FileError] = field(default_factory=list)
    undated_messages: int = 0
    tz_assumed_local: int = 0
    tz_unplaced: int = 0
    tz: Any = timezone.utc


# ---------------------------------------------------------------------------
# Small tolerant readers
# ---------------------------------------------------------------------------


def _first(d: dict, keys: Iterable[str]) -> Any:
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def _norm_email(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    v = value.strip().lower()
    if v.startswith("mailto:"):
        v = v[len("mailto:"):]
    return v if "@" in v else ""


def _user_type(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        return "unknown"
    v = value.strip().lower()
    if v in ("bot", "app"):
        return "bot"
    if v == "human":
        return "human"
    return "unknown"


def _author(raw: Any) -> ChatAuthor:
    if isinstance(raw, str):
        email = _norm_email(raw)
        return ChatAuthor(name=raw.strip() if not email else "", email=email,
                          user_type="unknown")
    if not isinstance(raw, dict):
        return ChatAuthor(name="", email="", user_type="unknown")
    name = raw.get("name") or raw.get("display_name") or raw.get("displayName") or ""
    if not isinstance(name, str):
        name = ""
    return ChatAuthor(
        name=name.strip(),
        email=_norm_email(raw.get("email")),
        user_type=_user_type(raw.get("user_type") or raw.get("type")),
    )


def _rel(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return path.name


def _load_json(path: Path, root: Path, errors: List[FileError]) -> Any:
    """Read one JSON file, recording a per-file error instead of raising."""
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        errors.append(FileError(_rel(root, path), "missing"))
        return None
    except OSError as exc:
        errors.append(FileError(_rel(root, path), "unreadable", type(exc).__name__))
        return None
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as exc:
        errors.append(FileError(_rel(root, path), "bad_json", type(exc).__name__))
        return None


# ---------------------------------------------------------------------------
# Timestamps
# ---------------------------------------------------------------------------

# A trailing zone: a bare abbreviation, a numeric offset, or "GMT+8" /
# "UTC+05:30" style.
_TZ_TAIL = re.compile(r"\s+((?:UTC|GMT)[+-]\d{1,2}(?::?\d{2})?|[A-Za-z]{2,5}|[+-]\d{2}:?\d{2})$")
_WEEKDAY_HEAD = re.compile(r"^[^\W\d_]+\.?,\s+")
_LONG_FORMATS = (
    "%B %d, %Y at %I:%M:%S %p",   # February 1, 2023 at 3:04:05 PM
    "%d %B %Y at %H:%M:%S",       # 1 February 2023 at 15:04:05
    "%B %d, %Y at %H:%M:%S",
    "%d %B %Y at %I:%M:%S %p",
    "%B %d, %Y, %I:%M:%S %p",
    "%d %B %Y, %H:%M:%S",
    "%b %d, %Y at %I:%M:%S %p",
    "%d %b %Y at %H:%M:%S",
    "%B %d, %Y at %I:%M %p",
    "%d %B %Y at %H:%M",
    "%d %B %Y %H:%M:%S",
    "%d %B %Y %H:%M",
)

# Exports in other languages (UNVERIFIED: the shapes below are the long-date
# conventions of each language, not samples from a real export). Month names
# are mapped to English and the joining word to "at" before the English
# formats above are tried. A date in a language not listed here stays
# unparsed, and a file that is mostly unparsed is reported LOUDLY (see
# UNPARSED_DATE_RATIO) instead of collapsing into one undated conversation.
_MONTHS = {
    "January": ("januar", "janvier", "enero", "gennaio", "janeiro", "januari", "jänner"),
    "February": ("februar", "février", "fevrier", "febrero", "febbraio", "fevereiro", "februari"),
    "March": ("märz", "maerz", "mars", "marzo", "março", "marco", "maart"),
    "April": ("april", "avril", "abril", "aprile"),
    "May": ("mai", "mayo", "maggio", "maio", "mei"),
    "June": ("juni", "juin", "junio", "giugno", "junho"),
    "July": ("juli", "juillet", "julio", "luglio", "julho"),
    "August": ("august", "août", "aout", "agosto", "augustus"),
    "September": ("september", "septembre", "septiembre", "setiembre", "settembre", "setembro"),
    "October": ("oktober", "octobre", "octubre", "ottobre", "outubro"),
    "November": ("november", "novembre", "noviembre", "novembro"),
    "December": ("dezember", "décembre", "decembre", "diciembre", "dicembre", "dezembro"),
}
_MONTH_WORD = {w: en for en, words in _MONTHS.items() for w in words}
_JOIN_WORD = re.compile(r"\s+(?:um|à|a las|às|alle|om|a les|kl\.)\s+", re.I)
_DE_ORDINAL = re.compile(r"(\d)\.\s")
_BARE_WEEKDAY = re.compile(r"^([^\W\d_]+)\s+(?=\d)")
_EN_MONTH_WORDS = {m.lower() for m in _MONTHS} | {m[:3].lower() for m in _MONTHS} | {"sept"}
_ES_DE = re.compile(r"(\d)\s+de\s+([^\W\d_]+)\s+de\s+(\d{4})", re.I)


def _englishise(s: str) -> str:
    s = _ES_DE.sub(r"\1 \2 \3", s)
    s = _DE_ORDINAL.sub(r"\1 ", s)
    s = _JOIN_WORD.sub(" at ", s)

    def month(m):
        return _MONTH_WORD.get(m.group(0).lower(), m.group(0))

    return re.sub(r"[^\W\d_]+", month, s)


# Notes parse_timestamp attaches to a value.
TS_OK = ""
TS_ASSUMED_LOCAL = "assumed_local"   # no zone at all: read in the owner's zone
TS_UNPLACED_ZONE = "unplaced_zone"   # a zone word we cannot place: NOT guessed


def _offset_minutes(tok: str) -> int:
    body = tok.upper().replace("UTC", "").replace("GMT", "")
    sign = -1 if body.startswith("-") else 1
    digits = body[1:].replace(":", "")
    if len(digits) <= 2:
        return sign * int(digits) * 60
    return sign * (int(digits[:-2]) * 60 + int(digits[-2:]))


def parse_timestamp(value: Any, local_tz=None) -> Tuple[Optional[datetime], str]:
    """Parse a Takeout Chat timestamp. Returns ``(datetime_utc, note)``.

    ``note`` is ``TS_OK``, ``TS_ASSUMED_LOCAL`` (the string carried no zone,
    so it was read in ``local_tz``, the owner's zone, default UTC) or
    ``TS_UNPLACED_ZONE`` (a zone abbreviation such as "HKT" that this parser
    cannot place: the timestamp is NOT guessed, it is ``None``). Returns
    ``(None, TS_OK)`` for anything else unparseable.
    """
    local = local_tz or timezone.utc
    if value is None or isinstance(value, bool):
        return None, TS_OK
    if isinstance(value, (int, float)):
        n = float(value)
        # Epoch seconds, milliseconds, microseconds or nanoseconds, by magnitude.
        if n > 1e17:
            n /= 1e9
        elif n > 1e14:
            n /= 1e6
        elif n > 1e11:
            n /= 1e3
        try:
            return datetime.fromtimestamp(n, tz=timezone.utc), TS_OK
        except (OverflowError, OSError, ValueError):
            return None, TS_OK
    if isinstance(value, dict):
        # A protobuf-style {"seconds": ..., "nanos": ...} (UNVERIFIED shape).
        secs = value.get("seconds")
        if isinstance(secs, (int, float, str)):
            try:
                return parse_timestamp(int(secs))
            except ValueError:
                return None, TS_OK
        return None, TS_OK
    if not isinstance(value, str):
        return None, TS_OK
    s = value.replace(" ", " ").replace(" ", " ").strip()
    if not s:
        return None, TS_OK
    if s.isdigit():
        return parse_timestamp(int(s))
    # ISO 8601.
    iso = s[:-1] + "+00:00" if s.endswith("Z") else s
    try:
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=local).astimezone(timezone.utc), TS_ASSUMED_LOCAL
        return dt.astimezone(timezone.utc), TS_OK
    except ValueError:
        pass
    note = TS_ASSUMED_LOCAL
    fixed: Optional[timezone] = None
    m = _TZ_TAIL.search(s)
    if m:
        tok = m.group(1)
        up = tok.upper()
        if up in ("UTC", "GMT", "Z"):
            fixed, note = timezone.utc, TS_OK
            s = s[: m.start()]
        elif tok[0] in "+-" or up.startswith(("UTC+", "UTC-", "GMT+", "GMT-")):
            fixed, note = timezone(timedelta(minutes=_offset_minutes(tok))), TS_OK
            s = s[: m.start()]
        elif up not in ("AM", "PM"):
            return None, TS_UNPLACED_ZONE   # never guess a zone we cannot place
    s = _englishise(_WEEKDAY_HEAD.sub("", s).strip())
    # A weekday with no comma ("mercredi 1 February ..."): drop a leading word
    # before a digit unless that word is itself the month.
    head = _BARE_WEEKDAY.match(s)
    if head and head.group(1).lower() not in _EN_MONTH_WORDS:
        s = s[head.end():]
    for fmt in _LONG_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
        except ValueError:
            continue
        return dt.replace(tzinfo=fixed or local).astimezone(timezone.utc), note
    return None, TS_OK


def local_zone():
    """The owner's zone: ``OSTLER_OWNER_TZ`` or ``TZ`` (an IANA name), else the
    Mac's own /etc/localtime, else the process's fixed local offset."""
    try:
        from zoneinfo import ZoneInfo
    except ImportError:  # pragma: no cover -- 3.9+ always has it
        ZoneInfo = None
    for name in (os.environ.get("OSTLER_OWNER_TZ"), os.environ.get("TZ")):
        if name and ZoneInfo is not None:
            try:
                return ZoneInfo(name.lstrip(":"))
            except Exception:  # noqa: BLE001 -- an unknown name falls through
                pass
    try:
        target = os.readlink("/etc/localtime")
        if "zoneinfo/" in target and ZoneInfo is not None:
            return ZoneInfo(target.split("zoneinfo/", 1)[1])
    except (OSError, ValueError):
        pass
    except Exception:  # noqa: BLE001
        pass
    return datetime.now().astimezone().tzinfo or timezone.utc


# ---------------------------------------------------------------------------
# Export discovery
# ---------------------------------------------------------------------------


def find_chat_root(export_root: Path) -> Optional[Path]:
    """Return the ``Google Chat`` directory (the one holding ``Groups/``).

    Accepts the extracted archive root, ``Takeout/``, ``Google Chat/`` or
    ``Groups/`` itself. None when no Groups directory can be found.
    """
    root = Path(export_root)
    candidates = [
        root,
        root / "Google Chat",
        root / "Takeout" / "Google Chat",
    ]
    if root.name == "Groups":
        candidates.insert(0, root.parent)
    for c in candidates:
        if (c / "Groups").is_dir():
            return c
    # One level of unknown wrapper (e.g. "takeout-20260101T000000Z-001/").
    if root.is_dir():
        for child in sorted(root.iterdir()):
            if child.is_dir():
                for c in (child / "Google Chat", child / "Takeout" / "Google Chat"):
                    if (c / "Groups").is_dir():
                        return c
    return None


def _group_kind_and_key(folder: str, info: dict) -> Tuple[str, str]:
    if folder.startswith(_DM_PREFIX):
        return "dm", folder[len(_DM_PREFIX):].strip() or folder
    if folder.startswith(_SPACE_PREFIX):
        return "space", folder[len(_SPACE_PREFIX):].strip() or folder
    # Unknown prefix (UNVERIFIED naming): a named group is a space.
    return ("space" if info.get("name") else "dm"), folder


def _read_owner(chat_root: Path, errors: List[FileError]) -> Tuple[Optional[str], Optional[str]]:
    users = chat_root / "Users"
    if not users.is_dir():
        return None, None
    found: List[Tuple[str, str]] = []
    for info_path in sorted(users.glob("*/user_info.json")):
        data = _load_json(info_path, chat_root, errors)
        if data is None:
            continue
        if not isinstance(data, dict):
            errors.append(FileError(_rel(chat_root, info_path), "unexpected_shape", "not_object"))
            continue
        user = data.get("user") if isinstance(data.get("user"), dict) else data
        a = _author(user)
        if a.email:
            found.append((a.email, a.name))
        else:
            errors.append(FileError(_rel(chat_root, info_path), "unexpected_shape", "no_email"))
    emails = {e for e, _ in found}
    if len(emails) == 1:
        email = found[0][0]
        name = next((n for e, n in found if n), None)
        return email, name
    return None, None


def _load_group(chat_root: Path, group_dir: Path, errors: List[FileError], export: ChatExport) -> Optional[ChatGroup]:
    info_path = group_dir / "group_info.json"
    info: dict = {}
    if info_path.exists():
        data = _load_json(info_path, chat_root, errors)
        if isinstance(data, dict):
            info = data
        elif data is not None:
            errors.append(FileError(_rel(chat_root, info_path), "unexpected_shape", "not_object"))
    else:
        errors.append(FileError(_rel(chat_root, info_path), "missing"))

    kind, key = _group_kind_and_key(group_dir.name, info)
    raw_members = _first(info, _MEMBER_KEYS) or []
    members: List[ChatAuthor] = []
    if isinstance(raw_members, list):
        for rm in raw_members:
            # A membership row may wrap the member (UNVERIFIED alias shape).
            if isinstance(rm, dict) and isinstance(rm.get("member"), dict):
                rm = rm["member"]
            a = _author(rm)
            if a.email or a.name:
                members.append(a)
    elif raw_members:
        errors.append(FileError(_rel(chat_root, info_path), "unexpected_shape", "members_not_list"))

    name = info.get("name") if isinstance(info.get("name"), str) else None
    group = ChatGroup(folder=group_dir.name, group_key=key, kind=kind,
                      name=(name or None) if kind == "space" else None,
                      members=members)

    msg_path = group_dir / "messages.json"
    data = _load_json(msg_path, chat_root, errors)
    if data is None:
        return group if members else None
    if isinstance(data, dict):
        raw_messages = data.get("messages")
        if raw_messages is None:
            errors.append(FileError(_rel(chat_root, msg_path), "unexpected_shape", "no_messages_key"))
            raw_messages = []
    elif isinstance(data, list):
        raw_messages = data   # a bare list (UNVERIFIED variant)
    else:
        errors.append(FileError(_rel(chat_root, msg_path), "unexpected_shape", "not_object"))
        raw_messages = []
    if not isinstance(raw_messages, list):
        errors.append(FileError(_rel(chat_root, msg_path), "unexpected_shape", "messages_not_list"))
        raw_messages = []

    bad_rows = 0
    group_undated = 0
    group_unplaced = 0
    for i, raw in enumerate(raw_messages):
        if not isinstance(raw, dict):
            bad_rows += 1
            continue
        state = raw.get("message_state") or raw.get("state")
        if isinstance(state, str) and state in _DELETED_STATES:
            continue
        author = _author(_first(raw, _AUTHOR_KEYS))
        body = _first(raw, _BODY_KEYS)
        text = body.strip() if isinstance(body, str) else ""
        files_raw = _first(raw, _FILES_KEYS) or []
        attachments: List[dict] = []
        if isinstance(files_raw, list):
            for f in files_raw:
                if isinstance(f, dict):
                    original = f.get("original_name") or f.get("name") or ""
                    exported = f.get("export_name") or ""
                    present = bool(exported) and (group_dir / str(exported)).exists()
                    attachments.append({
                        "original_name": str(original),
                        "export_name": str(exported),
                        "present": present,
                    })
        if not text and not attachments:
            continue  # annotation-only / system row: nothing to transcribe
        ts, note = parse_timestamp(_first(raw, _TIME_KEYS), export.tz)
        if ts is None:
            export.undated_messages += 1
            group_undated += 1
            if note == TS_UNPLACED_ZONE:
                export.tz_unplaced += 1
                group_unplaced += 1
        elif note == TS_ASSUMED_LOCAL:
            export.tz_assumed_local += 1
        topic = _first(raw, _TOPIC_KEYS)
        mid = _first(raw, _ID_KEYS)
        group.messages.append(ChatMessage(
            author=author, text=text, timestamp=ts,
            topic_id=str(topic) if topic is not None else "",
            message_id=str(mid) if mid is not None else f"{group.folder}#{i}",
            attachments=attachments, index=i,
        ))
    if bad_rows:
        errors.append(FileError(_rel(chat_root, msg_path), "unexpected_shape",
                                f"{bad_rows}_non_object_rows"))
    # LOUD, per file: a messages.json whose dates are mostly unreadable (a
    # language or zone this parser does not know) is reported and NOT turned
    # into conversations, rather than collapsing into one undated pile.
    if group.messages and group_undated / len(group.messages) > UNPARSED_DATE_RATIO:
        group.dates_unparsed = True
        reason = "unplaced_zone" if group_unplaced * 2 > group_undated else "unparsed_dates"
        errors.append(FileError(_rel(chat_root, msg_path), reason,
                                f"{group_undated}_of_{len(group.messages)}"))
    # Members missing from group_info are still authors of messages.
    known = {m.key for m in group.members}
    for m in group.messages:
        if m.author.key not in known and (m.author.email or m.author.name):
            group.members.append(m.author)
            known.add(m.author.key)
    return group


def _infer_owner(groups: List[ChatGroup]) -> Optional[str]:
    """The one email that is a member of EVERY group, or None."""
    sets = [{m.email for m in g.members if m.email} for g in groups if g.members]
    if not sets:
        return None
    common = set.intersection(*sets)
    return next(iter(common)) if len(common) == 1 else None


def classify_group(group: ChatGroup, owner_email: Optional[str]) -> str:
    if not group.is_group:
        return TIER_T1_DM
    humans = [m for m in group.members if m.user_type != "bot"]
    if len(humans) < INTIMATE_PARTICIPANT_MAX:
        return TIER_T2_GROUP
    total = len(group.messages)
    if total == 0:
        return TIER_T3_SKIP
    mine = sum(1 for m in group.messages if owner_email and m.author.email == owner_email)
    if mine / total >= ENGAGEMENT_FLOOR_RELATIVE:
        return TIER_T2_GROUP
    return TIER_T3_SKIP


def parse_export(export_root: Path, owner_email: Optional[str] = None, tz=None) -> ChatExport:
    """Parse a Takeout Chat export. Raises FileNotFoundError when no
    ``Groups/`` directory can be found under ``export_root``; every other
    problem is a per-file entry in ``ChatExport.errors``."""
    root = Path(export_root)
    chat_root = find_chat_root(root)
    if chat_root is None:
        raise FileNotFoundError("no Google Chat Groups/ directory under the export")
    errors: List[FileError] = []
    export = ChatExport(root=chat_root, owner_email=None, owner_name=None,
                        owner_source="none", errors=errors,
                        tz=tz if tz is not None else local_zone())

    info_email, info_name = _read_owner(chat_root, errors)
    for gdir in sorted((chat_root / "Groups").iterdir()):
        if not gdir.is_dir():
            continue
        try:
            g = _load_group(chat_root, gdir, errors, export)
        except Exception as exc:  # noqa: BLE001 -- one group never aborts the export
            errors.append(FileError(_rel(chat_root, gdir), "unexpected_shape", type(exc).__name__))
            continue
        if g is not None:
            export.groups.append(g)

    arg = _norm_email(owner_email) if owner_email else ""
    if arg:
        export.owner_email, export.owner_source = arg, "argument"
    elif info_email:
        export.owner_email, export.owner_source = info_email, "user_info"
    else:
        inferred = _infer_owner(export.groups)
        if inferred:
            export.owner_email, export.owner_source = inferred, "inferred"
    if export.owner_email:
        export.owner_name = info_name if export.owner_source == "user_info" else None
        if not export.owner_name:
            for g in export.groups:
                for m in g.members:
                    if m.email == export.owner_email and m.name:
                        export.owner_name = m.name
                        break
                if export.owner_name:
                    break
    for g in export.groups:
        g.tier = classify_group(g, export.owner_email)
    return export


# ---------------------------------------------------------------------------
# Payloads
# ---------------------------------------------------------------------------


def _slugify(value: str) -> str:
    v = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return v or "group"


def _day_buckets(group: ChatGroup, tz) -> List[Tuple[str, List[ChatMessage]]]:
    """Messages bucketed by the OWNER'S local calendar day (``tz``), in time
    order. An undated message follows the previous dated message in file
    order; undated messages before the first dated one join the first dated
    day. (A file that is mostly undated never gets here: it is reported.)"""
    buckets: Dict[str, List[ChatMessage]] = {}
    current: Optional[str] = None
    pending: List[ChatMessage] = []
    for m in sorted(group.messages, key=lambda x: x.index):
        if m.timestamp is not None:
            current = m.timestamp.astimezone(tz).strftime("%Y%m%d")
            if pending:
                buckets.setdefault(current, []).extend(pending)
                pending = []
        if current is None:
            pending.append(m)
        else:
            buckets.setdefault(current, []).append(m)
    out = []
    for day in sorted(buckets):
        msgs = buckets[day]
        msgs.sort(key=lambda x: (x.timestamp or datetime.min.replace(tzinfo=timezone.utc), x.index))
        out.append((day, msgs))
    return out


def _speaker(author: ChatAuthor, owner_email: Optional[str], owner_name: Optional[str]) -> str:
    if owner_email and author.email == owner_email:
        return owner_name or author.name or "Me"
    label = author.name or author.email or "Unknown"
    return f"{label} (bot)" if author.user_type == "bot" else label


def render_transcript(messages: List[ChatMessage], owner_email: Optional[str],
                      owner_name: Optional[str], thread_sizes: Dict[str, int],
                      tz=timezone.utc) -> str:
    """``**Speaker** (YYYY-MM-DD HH:MM): text`` per message, the speaker
    shape CM048's seed pass reads. A message in a thread of more than one
    message is tagged ``[thread <short id>]``."""
    lines: List[str] = []
    for m in messages:
        when = m.timestamp.astimezone(tz).strftime("%Y-%m-%d %H:%M") if m.timestamp else "undated"
        body = m.text
        if m.attachments:
            names = ", ".join(a["original_name"] for a in m.attachments if a["original_name"])
            tag = f"{PLACEHOLDER_ATTACHMENT[:-1]}: {names}]" if names else PLACEHOLDER_ATTACHMENT
            body = f"{body} {tag}".strip()
        if m.topic_id and thread_sizes.get(m.topic_id, 0) > 1:
            body = f"[thread {hashlib.sha1(m.topic_id.encode()).hexdigest()[:6]}] {body}"
        body = body.replace("\n", "\n    ")
        lines.append(f"**{_speaker(m.author, owner_email, owner_name)}** ({when}): {body}")
    return "\n".join(lines)


def group_payloads(group: ChatGroup, export: ChatExport) -> List[dict]:
    """CM048 ``process()`` payloads for one group, one per UTC day."""
    if group.tier == TIER_T3_SKIP or group.dates_unparsed:
        return []
    owner = export.owner_email
    thread_sizes: Dict[str, int] = {}
    for m in group.messages:
        if m.topic_id:
            thread_sizes[m.topic_id] = thread_sizes.get(m.topic_id, 0) + 1
    payloads: List[dict] = []
    for day, msgs in _day_buckets(group, export.tz):
        conversation_id = f"gchat_{day}_{_slugify(group.group_key)}"
        dated = [m.timestamp for m in msgs if m.timestamp]
        started = min(dated) if dated else None
        ended = max(dated) if dated else None
        participants: List[dict] = []
        if owner:
            participants.append({"id": owner, "display": export.owner_name or owner,
                                 "role": "user", "email": owner})
        seen = {owner} if owner else set()
        speakers = {m.author.key for m in msgs}
        for a in group.members:
            if a.user_type == "bot" or a.key in seen:
                continue
            # A DM's other member is a participant every day; in a space only
            # those who spoke that day are (a 200-member space is not 200
            # participants of every conversation).
            if group.kind == "space" and a.key not in speakers:
                continue
            seen.add(a.key)
            entry = {"id": a.email or a.name, "display": a.name or a.email, "role": "other"}
            if a.email:
                entry["email"] = a.email
                entry["handle"] = a.email
            participants.append(entry)
        topics = {m.topic_id for m in msgs if m.topic_id}
        date_str = f"{day[:4]}-{day[4:6]}-{day[6:]}" if day != "00000000" else "1970-01-01"
        metadata = {
            "conversation_id": conversation_id,
            "date": date_str,
            "source": SOURCE,
            "channel": CHANNEL,
            "source_app": SOURCE_APP,
            "source_session_id": f"{group.group_key}:{day}",
            "participants": participants,
            "started_at": started.isoformat() if started else None,
            "ended_at": ended.isoformat() if ended else None,
            "privacy_level": PRIVACY_L2,
            "chat_type": "group" if group.is_group else "private",
            "is_group_chat": group.is_group,
            "group_subject": group.name if group.kind == "space" else None,
            "group_key": group.group_key,
            "contact_source_tier": group.tier,
            "message_count": len(msgs),
            "thread_count": len(topics),
            "attachment_count": sum(len(m.attachments) for m in msgs),
            # The day and the transcript times are the owner's local zone.
            "timezone": str(export.tz),
        }
        payloads.append({
            "conversation_id": conversation_id,
            "transcript": render_transcript(msgs, owner, export.owner_name, thread_sizes, export.tz),
            "metadata": metadata,
        })
    return payloads


def export_payloads(export: ChatExport) -> List[dict]:
    out: List[dict] = []
    if not export.owner_email:
        return out
    for g in export.groups:
        out.extend(group_payloads(g, export))
    return out


def correspondents(export: ChatExport) -> Dict[str, int]:
    """``{email: messages sent}`` for every non-owner HUMAN author in an
    ingestible group. Bots and authors without an email are excluded."""
    counts: Dict[str, int] = {}
    if not export.owner_email:
        return counts
    for g in export.groups:
        if g.tier == TIER_T3_SKIP:
            continue
        for m in g.messages:
            a = m.author
            if not a.email or a.email == export.owner_email or a.user_type == "bot":
                continue
            counts[a.email] = counts.get(a.email, 0) + 1
    return counts


def correspondent_names(export: ChatExport) -> Dict[str, str]:
    names: Dict[str, str] = {}
    for g in export.groups:
        for a in g.members:
            if a.email and a.name and a.email != export.owner_email and a.user_type != "bot":
                names.setdefault(a.email, a.name)
    return names


def stats(export: ChatExport) -> dict:
    """Counts only: safe for logs and the install summary."""
    tiers = [g.tier for g in export.groups]
    ingestible = [g for g in export.groups if g.tier != TIER_T3_SKIP]
    return {
        "groups": len(export.groups),
        "dm_groups": sum(1 for t in tiers if t == TIER_T1_DM),
        "space_groups": sum(1 for t in tiers if t == TIER_T2_GROUP),
        "skipped_groups": sum(1 for t in tiers if t == TIER_T3_SKIP),
        "messages": sum(len(g.messages) for g in ingestible),
        "undated_messages": export.undated_messages,
        "tz_assumed_local": export.tz_assumed_local,
        "tz_unplaced": export.tz_unplaced,
        "unparsed_date_groups": sum(1 for g in export.groups if g.dates_unparsed),
        "file_errors": len(export.errors),
        "owner_source": export.owner_source,
    }


# ---------------------------------------------------------------------------
# Idempotency ledger
# ---------------------------------------------------------------------------


def payload_hash(payload: dict) -> str:
    blob = json.dumps({"t": payload.get("transcript"), "m": payload.get("metadata")},
                      sort_keys=True, default=str)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


class ImportLedger:
    """``{conversation_id: content hash}`` of payloads the pipeline ACCEPTED.

    Written only after a successful hand-off, so a failed or skipped send is
    retried next run. A corrupt ledger file is treated as empty (re-sending is
    safe: the CM048 writer is idempotent by conversation id) and reported.
    """

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.corrupt = False
        self.entries: Dict[str, str] = {}
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                if isinstance(data, dict) and isinstance(data.get("entries"), dict):
                    self.entries = {str(k): str(v) for k, v in data["entries"].items()}
                else:
                    self.corrupt = True
            except (OSError, ValueError):
                self.corrupt = True

    def is_current(self, payload: dict) -> bool:
        return self.entries.get(payload["conversation_id"]) == payload_hash(payload)

    def record(self, payload: dict) -> None:
        self.entries[payload["conversation_id"]] = payload_hash(payload)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"version": 1, "entries": self.entries}, indent=1, sort_keys=True))
        os.replace(tmp, self.path)


def default_state_path() -> Path:
    return Path.home() / ".ostler" / "imports" / "google_chat" / "ledger.json"


# ---------------------------------------------------------------------------
# Persistence: reuse the existing sinks, own no writes
# ---------------------------------------------------------------------------
#
# Archie's binding connector rulings (2026-10-19): one architecture, CM048
# ``processor.process``, reached by ``pwg-convo`` for ostler_fda sources (this
# one) or ``wire.post`` for CM052. No local bundle writer. EVERY level,
# including L3, reaches processor.process: CM048's writer still writes an L3
# conversation's four artefacts and is the one that skips its gist arm. So
# nothing here filters on privacy_level before the hand-off. Google Chat is
# PRO (Andy, 2026-10-19): the G7 gate below runs at the entry point, before the
# export is read (``main``) and again before any hand-off (``persist``), never
# inside processor.process.


# ---------------------------------------------------------------------------
# G7: Google Chat is an Ostler Pro source (Andy, 2026-10-19), and the FIRST
# export import of each source is free (Andy's refinement, same day)
# ---------------------------------------------------------------------------
#
# Both rules live in ONE shared helper, ``ostler_fda/first_import.py`` (a
# byte-identical copy of CM052 ``src/cm052/first_import.py``, vendored by the
# small-sources agent next to ``subscription_gate.py`` from CM051 #3024).
# Building a second one here is what Archie ruled out, so this module only
# RESOLVES it. The gate runs at the ENTRY POINT, before the export is read
# (``main``) and again before any hand-off (``persist``); never inside
# processor.process.
#
# ``entry_gate("google_chat", export_import=True)`` answers, and this maps it:
#   "pro"               allowed.
#   "first_import_free" allowed; ``mark_first_import`` runs ONLY after every
#                       payload was accepted, so a failed first try does not
#                       burn the taster.
#   "pro_required"      nothing is read, staged or sent; ledger untouched;
#                       Andy's refusal copy; exit 5 (EXIT_PAUSED_NOT_PRO).
#   "could_not_check"   CANNOT-RUN, never a refusal: "Try again"; exit 3.
#   "unknown"           the helper raised or answered off-contract: fail OPEN,
#                       logged. A customer is never paused because we could
#                       not ask.
#   "gate_helper_absent" a build without the helper refuses (exit 5): a
#                       missing enforcement surface on a Pro source is a
#                       build defect, not a runtime outage.
SHARED_GATE_MODULE = "ostler_fda.first_import"
SOURCE_LABEL = "Google Chat"
EXIT_PAUSED_NOT_PRO = 5     # the shared contract (first_import.EXIT_PAUSED_NOT_PRO)
EXIT_COULD_NOT_CHECK = 3    # the shared contract (first_import.EXIT_COULD_NOT_CHECK)
GATE_ALLOWED = ("pro", "first_import_free", "unknown")
_GATE_REASONS = ("pro", "first_import_free", "pro_required", "could_not_check")


def _gate_module():
    import importlib

    try:
        return importlib.import_module(SHARED_GATE_MODULE)
    except ImportError:
        return None


def default_gate() -> str:
    """Ask the shared helper about this source. Returns one of
    ``_GATE_REASONS``, ``"unknown"`` or ``"gate_helper_absent"``."""
    mod = _gate_module()
    fn = getattr(mod, "entry_gate", None) if mod is not None else None
    if fn is None:
        return "gate_helper_absent"
    try:
        decision = fn(SOURCE, export_import=True)
    except Exception as exc:  # noqa: BLE001 -- could not ask: fail open
        logger.info("google_chat: G7 gate raised (%s); failing open", type(exc).__name__)
        return "unknown"
    reason = getattr(decision, "reason", None)
    allowed = getattr(decision, "allowed", None)
    if reason not in _GATE_REASONS or not isinstance(allowed, bool):
        return "unknown"
    if allowed != (reason in ("pro", "first_import_free")):
        return "unknown"   # self-contradictory answer: not an answer
    return reason


def default_mark() -> None:
    mod = _gate_module()
    if mod is not None:
        mod.mark_first_import(SOURCE)


def gate_text(reason: str) -> str:
    """The owner-facing line for a gate outcome (Andy's copy, from the helper)."""
    mod = _gate_module()
    if reason == "pro_required" and mod is not None:
        return mod.refusal_text(SOURCE_LABEL)
    if reason == "could_not_check" and mod is not None:
        return mod.COULD_NOT_CHECK_TEXT
    if reason == "first_import_free" and mod is not None:
        return mod.pre_import_notice(SOURCE_LABEL)
    if reason == "gate_helper_absent":
        return ("Ostler couldn't check your Ostler Pro status on this build, "
                "so nothing was imported.")
    return ""


def persist(export: ChatExport, *, ledger: ImportLedger, conversations_fn=None,
            people_fn=None, name_fn=None, gate_fn=None, mark_fn=None) -> dict:
    """Send new or changed conversations to the CM048 sink and correspondents
    to the people sink, if the G7 gate allows. The ``*_fn`` hooks default to
    the real sinks and helper and exist so a test can drive the same code
    path against fakes.

    Returns counts only.
    """
    from . import universal_import as ui

    gate = (gate_fn or default_gate)()
    if gate not in GATE_ALLOWED:
        logger.info("google_chat: import not run (%s); nothing sent", gate)
        return {
            "conversations_total": len(export_payloads(export)),
            "conversations_unchanged": 0, "conversations_sent": 0,
            "conversations_failed": 0, "conversations_unavailable": 0,
            "conversations_status": "cannot_run" if gate == "could_not_check" else "paused",
            "paused_reason": gate,
            "people_status": "paused", "people_created": 0, "names_offered": 0,
            "gate": gate, "first_import_marked": False,
        }
    if gate == "unknown":
        logger.info("google_chat: G7 gate could not answer; failing open")

    conversations_fn = conversations_fn or ui._persist_conversations
    people_fn = people_fn or ui._persist_mail_contacts
    if name_fn is None:
        name_fn = _upsert_names

    payloads = export_payloads(export)
    fresh = [p for p in payloads if not ledger.is_current(p)]
    sent = 0
    failed = 0
    conv_status = "ok"
    unavailable = 0
    # One payload per call so the ledger records exactly what was accepted.
    for p in fresh:
        r = conversations_fn([p], source=SOURCE)
        if r.get("persist_status") == "ok" and int(r.get("persisted", 0)) == 1:
            ledger.record(p)
            sent += 1
        else:
            failed += 1
            unavailable += int(r.get("persist_unavailable", 0) or 0)
            if r.get("persist_status") == "no_pipeline":
                conv_status = "no_pipeline"
                break  # the pipeline is absent: nothing else can land either
    if failed and conv_status == "ok":
        conv_status = "partial" if sent else "error"
    ledger.save()

    # The free taster is spent only by a COMPLETE first import: every payload
    # accepted, at least one handed over.
    marked = False
    if gate == "first_import_free" and sent > 0 and failed == 0:
        (mark_fn or default_mark)()
        marked = True

    people = people_fn(correspondents(export), source=SOURCE)
    names_upgraded = 0
    if people.get("persist_status") == "ok":
        names_upgraded = name_fn(correspondent_names(export))
    return {
        "conversations_total": len(payloads),
        "conversations_unchanged": len(payloads) - len(fresh),
        "conversations_sent": sent,
        "conversations_failed": failed,
        "conversations_unavailable": unavailable,
        "conversations_status": conv_status,
        "people_status": people.get("persist_status"),
        "people_created": int(people.get("people_created", 0)),
        "names_offered": names_upgraded,
        "gate": gate,
        "first_import_marked": marked,
    }


def _upsert_names(names: Dict[str, str]) -> int:
    """Offer each correspondent's Chat display name to the person who holds
    that address. Upward-only (pwg_ingest's tier table). Returns how many
    were offered to a resolved person."""
    from . import pwg_ingest as pwg

    offered = 0
    for email, name in names.items():
        uri = pwg._person_uri_by_identifier_value(email)
        if not uri or uri is pwg._LOOKUP_FAILED:
            continue
        try:
            pwg._upsert_display_name(uri, name)
            offered += 1
        except Exception as exc:  # noqa: BLE001 -- type only (privacy)
            logger.info("google_chat: name upsert skipped (%s)", type(exc).__name__)
    return offered


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    """Exit 0 on success or graceful skip (``status`` says which), 1 on an
    unexpected crash, 2 on usage error. stdout with ``--json`` is counts only."""
    import argparse
    import sys

    ap = argparse.ArgumentParser(
        prog="ostler-google-chat-takeout",
        description="Import a Google Takeout 'Google Chat' export (owner-initiated).",
    )
    ap.add_argument("--export-path", type=Path, required=True)
    ap.add_argument("--owner-email", default=None,
                    help="The exporting account's address (overrides user_info.json).")
    ap.add_argument("--tz", default=None,
                    help="The owner's IANA zone for day boundaries and times (default: this Mac's).")
    ap.add_argument("--output-dir", type=Path, default=None,
                    help="Where to stage google_chat_conversations.json (default ~/.ostler/imports/fda).")
    ap.add_argument("--state", type=Path, default=None, help="Idempotency ledger path.")
    ap.add_argument("--persist", action="store_true",
                    help="Send to the CM048 pipeline and the people graph (default: stage only).")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    result: dict = {"status": "ok", "errors": []}

    def _emit() -> None:
        if args.json:
            print(json.dumps(result))

    # G7 FIRST: a customer without Ostler Pro (and with the free first import
    # already used) has nothing of this export read, staged or sent, and
    # nothing already in the Hub is touched.
    gate = default_gate()
    result["gate"] = gate
    text = gate_text(gate)
    if gate not in GATE_ALLOWED:
        result["status"] = "cannot_run" if gate == "could_not_check" else "paused_not_pro"
        if text:
            print(text, file=sys.stderr)
        _emit()
        return EXIT_COULD_NOT_CHECK if gate == "could_not_check" else EXIT_PAUSED_NOT_PRO
    if text:
        print(text, file=sys.stderr)   # the first-import notice

    try:
        tz = None
        if args.tz:
            from zoneinfo import ZoneInfo

            tz = ZoneInfo(args.tz)
        export = parse_export(args.export_path, owner_email=args.owner_email, tz=tz)
    except FileNotFoundError:
        print("google-chat-takeout: no Google Chat export found at that path", file=sys.stderr)
        result["status"] = "not_found"
        _emit()
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"google-chat-takeout: unexpected failure ({type(exc).__name__})", file=sys.stderr)
        result["status"] = "error"
        result["errors"].append(type(exc).__name__)
        _emit()
        return 1

    result.update(stats(export))
    result["file_error_list"] = [e.to_dict() for e in export.errors]
    for e in export.errors:
        print(f"google-chat-takeout: {e.path}: {e.reason}"
              + (f" ({e.detail})" if e.detail else ""), file=sys.stderr)
    if not export.owner_email:
        print("google-chat-takeout: cannot tell which account is yours; "
              "pass --owner-email", file=sys.stderr)
        result["status"] = "no_owner"
        _emit()
        return 0

    payloads = export_payloads(export)
    result["conversations"] = len(payloads)
    out = args.output_dir or (Path.home() / ".ostler" / "imports" / "fda")
    try:
        out.mkdir(parents=True, exist_ok=True)
        (out / "google_chat_conversations.json").write_text(json.dumps(payloads, indent=1))
    except OSError as exc:
        result["status"] = "write_error"
        result["errors"].append(type(exc).__name__)
        _emit()
        return 0

    if args.persist:
        ledger = ImportLedger(args.state or default_state_path())
        if ledger.corrupt:
            result["errors"].append("ledger_corrupt")
        result.update(persist(export, ledger=ledger))
    _emit()
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
