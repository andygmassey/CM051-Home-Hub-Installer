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
milliseconds / microseconds. A string we cannot parse keeps its message
(never dropped) and is counted as ``undated_messages``; it is filed under
the day of the previous dated message in file order.

Fidelity limits (from the research, not measured): edit history is absent
(final text only), deleted messages are absent, and the org's Chat retention
policy may already have deleted old history before any export runs.

Conversation unit
=================

One conversation per (group, UTC calendar day). A multi-year DM in a single
transcript would be too large for the CM048 pipeline and useless as a page.
Thread replies (``topic_id`` shared by more than one message) are tagged in
the transcript so a reader can follow a thread inside a day. A thread that
crosses midnight UTC is split across two days' conversations (documented,
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
    tz_assumed_utc: int = 0


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

_TZ_TAIL = re.compile(r"\s+([A-Za-z]{2,5}|[+-]\d{2}:?\d{2})$")
_WEEKDAY_HEAD = re.compile(r"^[A-Za-z]+,\s+")
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
)


def parse_timestamp(value: Any) -> Tuple[Optional[datetime], bool]:
    """Parse a Takeout Chat timestamp. Returns ``(datetime_utc, tz_assumed)``.

    ``tz_assumed`` is True when the string carried no zone we recognise and
    UTC was assumed. Returns ``(None, False)`` for anything unparseable.
    """
    if value is None or isinstance(value, bool):
        return None, False
    if isinstance(value, (int, float)):
        n = float(value)
        # Epoch seconds, milliseconds or microseconds, by magnitude.
        if n > 1e17:
            n /= 1e9
        elif n > 1e14:
            n /= 1e6
        elif n > 1e11:
            n /= 1e3
        try:
            return datetime.fromtimestamp(n, tz=timezone.utc), False
        except (OverflowError, OSError, ValueError):
            return None, False
    if isinstance(value, dict):
        # A protobuf-style {"seconds": ..., "nanos": ...} (UNVERIFIED shape).
        secs = value.get("seconds")
        if isinstance(secs, (int, float, str)):
            try:
                return parse_timestamp(int(secs))
            except ValueError:
                return None, False
        return None, False
    if not isinstance(value, str):
        return None, False
    s = value.replace(" ", " ").replace(" ", " ").strip()
    if not s:
        return None, False
    if s.isdigit():
        return parse_timestamp(int(s))
    # ISO 8601.
    iso = s[:-1] + "+00:00" if s.endswith("Z") else s
    try:
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc), True
        return dt.astimezone(timezone.utc), False
    except ValueError:
        pass
    assumed = True
    offset_minutes = 0
    m = _TZ_TAIL.search(s)
    if m:
        tok = m.group(1)
        if tok.upper() in ("UTC", "GMT"):
            assumed = False
            s = s[: m.start()]
        elif tok[0] in "+-":
            digits = tok[1:].replace(":", "")
            offset_minutes = int(digits[:2]) * 60 + int(digits[2:])
            if tok[0] == "-":
                offset_minutes = -offset_minutes
            assumed = False
            s = s[: m.start()]
        elif tok.upper() not in ("AM", "PM"):
            s = s[: m.start()]  # an abbreviation we cannot place: assume UTC
    s = _WEEKDAY_HEAD.sub("", s).strip()
    for fmt in _LONG_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
        except ValueError:
            continue
        dt = dt.replace(tzinfo=timezone.utc) - timedelta(minutes=offset_minutes)
        return dt, assumed
    return None, False


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
        ts, assumed = parse_timestamp(_first(raw, _TIME_KEYS))
        if ts is None:
            export.undated_messages += 1
        elif assumed:
            export.tz_assumed_utc += 1
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


def parse_export(export_root: Path, owner_email: Optional[str] = None) -> ChatExport:
    """Parse a Takeout Chat export. Raises FileNotFoundError when no
    ``Groups/`` directory can be found under ``export_root``; every other
    problem is a per-file entry in ``ChatExport.errors``."""
    root = Path(export_root)
    chat_root = find_chat_root(root)
    if chat_root is None:
        raise FileNotFoundError("no Google Chat Groups/ directory under the export")
    errors: List[FileError] = []
    export = ChatExport(root=chat_root, owner_email=None, owner_name=None,
                        owner_source="none", errors=errors)

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


def _day_buckets(group: ChatGroup) -> List[Tuple[str, List[ChatMessage]]]:
    """Messages bucketed by UTC day, in time order. Undated messages follow
    the previous dated message in file order; leading undated ones go to
    ``00000000``."""
    buckets: Dict[str, List[ChatMessage]] = {}
    current = "00000000"
    for m in sorted(group.messages, key=lambda x: x.index):
        if m.timestamp is not None:
            current = m.timestamp.strftime("%Y%m%d")
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
                      owner_name: Optional[str], thread_sizes: Dict[str, int]) -> str:
    """``**Speaker** (YYYY-MM-DD HH:MM): text`` per message, the speaker
    shape CM048's seed pass reads. A message in a thread of more than one
    message is tagged ``[thread <short id>]``."""
    lines: List[str] = []
    for m in messages:
        when = m.timestamp.strftime("%Y-%m-%d %H:%M") if m.timestamp else "undated"
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
    if group.tier == TIER_T3_SKIP:
        return []
    owner = export.owner_email
    thread_sizes: Dict[str, int] = {}
    for m in group.messages:
        if m.topic_id:
            thread_sizes[m.topic_id] = thread_sizes.get(m.topic_id, 0) + 1
    payloads: List[dict] = []
    for day, msgs in _day_buckets(group):
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
        }
        payloads.append({
            "conversation_id": conversation_id,
            "transcript": render_transcript(msgs, owner, export.owner_name, thread_sizes),
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
        "tz_assumed_utc": export.tz_assumed_utc,
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
# THE CONVERSATION ROUTE (Archie's ruling for every connector, 2026-10-19):
# through the CM052 wire's transport into CM048's writer, the canonical path
# that writes the summaries. No local bundle writer, and no L3 short-circuit
# before CM048: an L3 conversation still gets its four artefacts, because
# CM048's writer is the one that skips the gist arm for L3.
#
# ``cm052.wire.post`` itself takes a CM052 ``Conversation``, whose roles are
# user/assistant and whose metadata renderer flattens participants to bare
# strings (losing the email the People join needs), and it still carries its
# own L3 short-circuit. So this sends the CM048 payload over the SAME
# transport wire.post uses: the same endpoint (``CM052_CM048_ENDPOINT``, else
# the Hub API on ``OSTLER_API_PORT``, default 8090), the same service token
# (``OSTLER_SERVICE_TOKEN`` / ``PWG_SERVICE_TOKEN`` / ~/.ostler/secrets/
# service_token), and the same body (``transcript``, ``metadata``,
# ``transcript_path``, ``metadata_path``; the Hub handler requires the paths
# to exist, so the pair is staged in an outbox first).


def _cm048_endpoint() -> str:
    override = os.environ.get("CM052_CM048_ENDPOINT")
    if override:
        return override
    port = (os.environ.get("OSTLER_API_PORT") or "8090").strip() or "8090"
    return f"http://127.0.0.1:{port}/api/v1/conversation/process"


def _service_token() -> str:
    for name in ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN"):
        value = (os.environ.get(name) or "").strip()
        if value:
            return value
    try:
        return (Path.home() / ".ostler" / "secrets" / "service_token").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def default_outbox() -> Path:
    return Path.home() / ".ostler" / "imports" / "google_chat" / "outbox"


def post_to_cm048(payloads: List[dict], *, source: str = SOURCE,
                  outbox: Optional[Path] = None, endpoint: Optional[str] = None,
                  timeout: float = 120.0) -> dict:
    """POST CM048 payloads to the Hub's conversation endpoint, one at a time.

    Same return shape as ``universal_import._persist_conversations`` (counts
    only). An unreachable endpoint is ``no_pipeline`` (an outage, never a
    verdict on the conversation); a 502/503/504 or a transport error is also
    counted ``unavailable``; any other non-2xx is a failure of that
    conversation. The token is sent as a header and never logged.
    """
    import httpx

    url = endpoint or _cm048_endpoint()
    token = _service_token()
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    root = Path(outbox) if outbox else default_outbox()
    persisted = failed = unavailable = 0
    status = "ok"
    transport = httpx.HTTPTransport(proxy=None)  # a local proxy must not answer for the Hub
    with httpx.Client(timeout=timeout, transport=transport) as client:
        for p in payloads:
            cid = p.get("conversation_id")
            if not cid or p.get("transcript") is None or p.get("metadata") is None:
                failed += 1
                continue
            d = root / _slugify(str(cid))
            d.mkdir(parents=True, exist_ok=True)
            t_file, m_file = d / "transcript.md", d / "metadata.json"
            t_file.write_text(p["transcript"], encoding="utf-8")
            m_file.write_text(json.dumps(p["metadata"]), encoding="utf-8")
            body = {"transcript": p["transcript"], "metadata": p["metadata"],
                    "transcript_path": str(t_file), "metadata_path": str(m_file)}
            try:
                r = client.post(url, json=body, headers=headers)
            except (httpx.ConnectError, httpx.ConnectTimeout):
                logger.info("%s: CM048 endpoint unreachable; not persisted", source)
                return {"persist_status": "no_pipeline", "persisted": persisted,
                        "persist_failed": failed + 1, "persist_unavailable": unavailable + 1}
            except httpx.HTTPError as exc:
                logger.warning("%s: CM048 POST failed (%s)", source, type(exc).__name__)
                failed += 1
                unavailable += 1
                continue
            if 200 <= r.status_code < 300:
                persisted += 1
            else:
                logger.warning("%s: CM048 rejected a conversation (HTTP %s)", source, r.status_code)
                failed += 1
                if r.status_code in (502, 503, 504):
                    unavailable += 1
    if failed:
        status = "partial" if persisted else "error"
    return {"persist_status": status, "persisted": persisted,
            "persist_failed": failed, "persist_unavailable": unavailable}



def persist(export: ChatExport, *, ledger: ImportLedger, conversations_fn=None,
            people_fn=None, name_fn=None) -> dict:
    """Send new or changed conversations to CM048 (:func:`post_to_cm048`) and
    correspondents to the people sink. The ``*_fn`` hooks default to the real sinks and
    exist so a test can drive the same code path against fakes.

    Returns counts only.
    """
    from . import universal_import as ui

    conversations_fn = conversations_fn or post_to_cm048
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

    try:
        export = parse_export(args.export_path, owner_email=args.owner_email)
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
