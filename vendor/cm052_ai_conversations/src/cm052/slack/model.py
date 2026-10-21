"""Shared Slack normalisation: raw Slack message objects -> ``Conversation``.

Both import routes (the workspace export ZIP and the owner's own internal-app
user token) produce the SAME raw message shape, because the export is a dump
of the same Web API objects. Everything route-independent lives here, so the
two routes cannot drift: the same message yields the same conversation id,
the same transcript and the same participant rows whichever route read it
(``tests/test_slack_routes_align.py`` proves it).

Conversation units (the 4-artefact spec is written per unit by CM048):

- a THREAD (root plus every reply) is one conversation, keyed by
  ``(channel_id, thread_ts)``;
- top-level messages with no replies are grouped into one conversation per
  channel per day in the owner's zone (fixed at first import), keyed by
  ``(channel_id, YYYY-MM-DD)``.

Logic ported from the ZeroClaw Slack channel
(ostler-assistant ``crates/zeroclaw-channels/src/slack.rs``): the display-name
precedence (``extract_user_display_name``) and the supported-subtype set
(``is_supported_message_subtype``: none, ``file_share``, ``thread_broadcast``).
Unlike the channel, an unsupported subtype is never dropped silently: it is
counted per subtype in ``ImportCounters.skipped_subtypes``.

File handling is METADATA ONLY. Slack file objects carry ``url_private`` /
``url_private_download`` links, and export links embed a ``?t=xoxe-...``
token. No URL is ever copied into a transcript, metadata or log.
"""
from __future__ import annotations

import hashlib
import html
import json
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone, tzinfo
from typing import Any, Iterable

from ..provenance import ConversationProvenance
from ..schemas import Conversation, Message


SOURCE_SUBTYPE = "slack"
_VALID_LEVELS = ("L0", "L1", "L2", "L3")

# Subtypes that are a human saying something. ``me_message`` (/me) and
# ``tombstone`` (a deleted thread root kept as a placeholder) are added to
# the ZeroClaw set: an importer must keep a thread's shape even when its root
# was deleted.
_KEPT_SUBTYPES = frozenset({"", "file_share", "thread_broadcast", "me_message", "tombstone"})


@dataclass
class SlackUser:
    user_id: str
    display: str
    email: str | None = None
    is_bot: bool = False


@dataclass
class ChannelInfo:
    """One Slack conversation container (channel, private channel, DM, MPIM)."""

    channel_id: str
    name: str
    kind: str  # "public" | "private" | "im" | "mpim"
    members: list[str] = field(default_factory=list)


@dataclass
class ImportCounters:
    """Counts for the run summary. Counts only, never content."""

    messages_seen: int = 0
    messages_kept: int = 0
    skipped_subtypes: Counter = field(default_factory=Counter)
    unknown_users: int = 0
    conversations_built: int = 0
    malformed: int = 0

    def to_dict(self) -> dict:
        return {
            "messages_seen": self.messages_seen,
            "messages_kept": self.messages_kept,
            "skipped_subtypes": dict(self.skipped_subtypes),
            "unknown_users": self.unknown_users,
            "conversations_built": self.conversations_built,
            "malformed": self.malformed,
        }


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------


def _clean(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def display_name(user: dict) -> str | None:
    """Port of ZeroClaw ``extract_user_display_name`` precedence."""
    profile = user.get("profile") if isinstance(user.get("profile"), dict) else {}
    for candidate in (
        profile.get("display_name"),
        profile.get("display_name_normalized"),
        profile.get("real_name_normalized"),
        profile.get("real_name"),
        user.get("real_name"),
        user.get("name"),
    ):
        cleaned = _clean(candidate)
        if cleaned:
            return cleaned
    return None


def parse_user(raw: dict) -> SlackUser | None:
    if not isinstance(raw, dict):
        return None
    uid = _clean(raw.get("id"))
    if not uid:
        return None
    profile = raw.get("profile") if isinstance(raw.get("profile"), dict) else {}
    email = _clean(profile.get("email"))
    return SlackUser(
        user_id=uid,
        display=display_name(raw) or uid,
        email=email.lower() if email else None,
        is_bot=bool(raw.get("is_bot")) or uid == "USLACKBOT",
    )


def parse_users(raw_users: Iterable[dict]) -> dict[str, SlackUser]:
    out: dict[str, SlackUser] = {}
    for raw in raw_users or []:
        user = parse_user(raw)
        if user:
            out[user.user_id] = user
    return out


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------


@dataclass
class NormMessage:
    ts: str
    thread_ts: str | None
    user_id: str | None
    text: str
    reply_count: int = 0


_USER_MENTION = re.compile(r"<@([A-Z0-9]+)(?:\|[^>]*)?>")
_CHANNEL_MENTION = re.compile(r"<#([A-Z0-9]+)(?:\|([^>]*))?>")
_SPECIAL = re.compile(r"<!(here|channel|everyone)(?:\|[^>]*)?>")
_SUBTEAM = re.compile(r"<!subteam\^[A-Z0-9]+(?:\|([^>]*))?>")
_LINK = re.compile(r"<((?:https?|mailto):[^>|]+)(?:\|([^>]*))?>")


def render_text(text: str, users: dict[str, SlackUser]) -> str:
    """Slack mrkdwn escapes into readable text.

    ``<@U1>`` -> ``@Jane Doe``; ``<#C1|general>`` -> ``#general``;
    ``<https://x|label>`` -> ``label (https://x)``; entities unescaped last
    (Slack escapes only ``& < >``).
    """
    if not text:
        return ""

    def user_sub(m: re.Match) -> str:
        u = users.get(m.group(1))
        return "@" + (u.display if u else m.group(1))

    out = _USER_MENTION.sub(user_sub, text)
    out = _CHANNEL_MENTION.sub(lambda m: "#" + (m.group(2) or m.group(1)), out)
    out = _SPECIAL.sub(lambda m: "@" + m.group(1), out)
    out = _SUBTEAM.sub(lambda m: m.group(1) or "@group", out)
    out = _LINK.sub(lambda m: f"{m.group(2)} ({m.group(1)})" if m.group(2) else m.group(1), out)
    return html.unescape(out).strip()


def _file_note(f: dict) -> str:
    # Name and type only. NEVER a url_* field (export links carry a token).
    name = _clean(f.get("name")) or _clean(f.get("title")) or "file"
    ftype = _clean(f.get("pretty_type")) or _clean(f.get("filetype")) or _clean(f.get("mimetype"))
    return f"[file: {name}{' (' + ftype + ')' if ftype else ''}]"


def _reaction_note(reactions: Any) -> str:
    parts = []
    for r in reactions or []:
        if not isinstance(r, dict):
            continue
        name = _clean(r.get("name"))
        if not name:
            continue
        count = r.get("count")
        count = count if isinstance(count, int) and count > 0 else len(r.get("users") or []) or 1
        parts.append(f":{name}: x{count}")
    return f"[reactions: {', '.join(parts)}]" if parts else ""


def normalise_message(
    raw: dict, users: dict[str, SlackUser], counters: ImportCounters
) -> NormMessage | None:
    """One raw Slack message -> ``NormMessage``, or None (counted) when it is
    not a human message."""
    counters.messages_seen += 1
    if not isinstance(raw, dict) or not _clean(raw.get("ts")):
        counters.malformed += 1
        return None
    subtype = raw.get("subtype") or ""
    if not isinstance(subtype, str):
        subtype = "<non-string>"
    if subtype not in _KEPT_SUBTYPES:
        counters.skipped_subtypes[subtype] += 1
        return None
    user_id = _clean(raw.get("user"))
    if user_id and user_id in users and users[user_id].is_bot:
        counters.skipped_subtypes["bot_user"] += 1
        return None

    if subtype == "tombstone":
        body = "[message deleted]"
    else:
        body = render_text(raw.get("text") or "", users)
    notes = [_file_note(f) for f in raw.get("files") or [] if isinstance(f, dict)]
    if isinstance(raw.get("edited"), dict):
        notes.append("(edited)")
    reaction = _reaction_note(raw.get("reactions"))
    if reaction:
        notes.append(reaction)
    text = " ".join([p for p in [body, *notes] if p]).strip()
    if not text:
        counters.skipped_subtypes["empty"] += 1
        return None
    thread_ts = _clean(raw.get("thread_ts"))
    rc = raw.get("reply_count")
    counters.messages_kept += 1
    return NormMessage(
        ts=str(raw["ts"]).strip(),
        thread_ts=thread_ts,
        user_id=user_id,
        text=text,
        reply_count=rc if isinstance(rc, int) else 0,
    )


# ---------------------------------------------------------------------------
# Grouping and Conversation building
# ---------------------------------------------------------------------------


def ts_float(ts: str) -> float:
    try:
        return float(ts)
    except (TypeError, ValueError):
        return 0.0


def ts_iso(ts: str, tz: tzinfo = timezone.utc) -> str:
    """ISO 8601 in the owner's day zone, with its offset. CM048 takes the
    bundle's folder date from the first 10 characters, so this is what puts a
    morning in Hong Kong under today's folder and not yesterday's."""
    return datetime.fromtimestamp(ts_float(ts), tz=tz).isoformat()


def local_day(ts: str, tz: tzinfo = timezone.utc) -> str:
    return ts_iso(ts, tz)[:10]


def conversation_id(channel_id: str, unit_kind: str, unit_key: str) -> str:
    """Deterministic id. ``sk-`` prefix keeps the namespace apart from
    ``og-`` (ChatGPT), ``cc-`` (Claude Code) and ``ch-`` (channel JSONL)."""
    payload = f"channel:slack:{channel_id}:{unit_kind}:{unit_key}".encode()
    return f"sk-{hashlib.sha1(payload).hexdigest()[:16]}"


def resolve_privacy_level(raw: str | None) -> str | None:
    """The owner's explicit level for every Slack conversation, or None.

    Unset -> None: the per-unit default below applies. Any unrecognised
    value -> L3, so a typo can never publish.
    """
    if raw is None or raw == "":
        return None
    value = raw.strip().upper()
    return value if value in _VALID_LEVELS else "L3"


def default_unit_level(channel: "ChannelInfo", authors: list[str], self_user_id: str | None) -> str:
    """Default level for one unit when the owner set none.

    DECISION (red team, 19 Oct: "public channels at L2, decide and justify"):
    - DMs and group DMs: L2. They are addressed to the owner; they are the
      owner's own conversations, like iMessage and WhatsApp (L2 there too).
    - Channels (public AND private): L2 only for a unit the owner WROTE in;
      a thread or day the owner never posted in is L3.
    Why: a channel is mostly colleagues talking to each other. Mining their
    chatter into facts about them (L2 reaches Qdrant/Oxigraph) is storing
    third parties' words the owner never took part in. L3 still writes the
    4-artefact bundle, so the owner can browse and search their files; it
    only keeps it out of facts, the assistant's answers and person pages.
    "Why was X parked" is answered from threads the owner was in, and the
    owner can lift everything with OSTLER_SLACK_PRIVACY_LEVEL=L2.
    """
    if channel.kind in ("im", "mpim"):
        return "L2"
    if self_user_id and self_user_id in authors:
        return "L2"
    return "L3"


@dataclass
class BuildContext:
    users: dict[str, SlackUser]
    self_user_id: str | None
    privacy_level: str | None  # explicit owner override, or None
    route: str  # "export" | "api"
    workspace: str | None = None
    day_tz: tzinfo = timezone.utc


def _speaker(user_id: str | None, ctx: BuildContext) -> str:
    if not user_id:
        return "Unknown"
    u = ctx.users.get(user_id)
    return u.display if u else user_id


def _participant_rows(user_ids: list[str], ctx: BuildContext) -> tuple[list[str], list[dict]]:
    ids: list[str] = []
    rows: list[dict] = []
    for uid in user_ids:
        u = ctx.users.get(uid)
        email = u.email if u else None
        pid = email or f"slack:{uid}"
        if pid in ids:
            continue
        ids.append(pid)
        row = {
            "id": pid,
            "display": u.display if u else uid,
            "role": "user" if uid == ctx.self_user_id else "other",
            "slack_user_id": uid,
        }
        # ``handle`` is what CM048 keys the Person URI from. Only a real
        # email is a key; a bare Slack id would mint a phantom person.
        if email:
            row["handle"] = email
        rows.append(row)
    return ids, rows


def channel_label(channel: ChannelInfo, ctx: BuildContext) -> str:
    """Human label, derived the same way on both routes (the export names a
    DM folder by its id, the API by nothing at all)."""
    if channel.kind in ("im", "mpim"):
        others = [m for m in channel.members if m != ctx.self_user_id]
        names = [_speaker(m, ctx) for m in others]
        if names:
            prefix = "DM with" if channel.kind == "im" else "Group DM with"
            return f"{prefix} {', '.join(names)}"
        return "Direct message"
    return f"#{channel.name}"


def _build(
    channel: ChannelInfo,
    unit_kind: str,
    unit_key: str,
    msgs: list[NormMessage],
    ctx: BuildContext,
) -> Conversation:
    msgs = sorted(msgs, key=lambda m: ts_float(m.ts))
    messages = [
        Message(
            role="user" if m.user_id and m.user_id == ctx.self_user_id else "participant",
            content=m.text,
            timestamp=ts_iso(m.ts, ctx.day_tz),
            line_index=i,
            speaker=_speaker(m.user_id, ctx),
        )
        for i, m in enumerate(msgs)
    ]
    authors = [m.user_id for m in msgs if m.user_id]
    # DM/MPIM members are participants even if they never spoke in this unit.
    ordered = list(dict.fromkeys(authors + list(channel.members)))
    participants, rows = _participant_rows(ordered, ctx)
    label = channel_label(channel, ctx)
    if unit_kind == "thread":
        first = msgs[0].text if msgs else ""
        name = f"{label} thread: {first[:60]}".rstrip()
    else:
        name = f"{label} {unit_key}"
    cid = conversation_id(channel.channel_id, unit_kind, unit_key)
    metadata = {
        "source_app": "slack",
        "privacy_level": ctx.privacy_level or default_unit_level(channel, authors, ctx.self_user_id),
        "participant_details": rows,
        "slack_channel_id": channel.channel_id,
        "slack_channel_kind": channel.kind,
        "slack_unit": unit_kind,
        "slack_unit_key": unit_key,
        "import_route": ctx.route,
    }
    if ctx.workspace:
        metadata["slack_workspace"] = ctx.workspace
    return Conversation(
        conversation_id=cid,
        provenance=ConversationProvenance(
            source_kind="channel",
            source_subtype=SOURCE_SUBTYPE,
            original_session_id=f"{channel.channel_id}:{unit_kind}:{unit_key}",
        ),
        channel="im",
        participants=participants,
        messages=messages,
        last_activity=messages[-1].timestamp if messages else ts_iso("0", ctx.day_tz),
        created_at=messages[0].timestamp if messages else None,
        name=name,
        metadata=metadata,
    )


def build_conversations(
    channel: ChannelInfo,
    raw_messages: Iterable[dict],
    ctx: BuildContext,
    counters: ImportCounters,
) -> list[Conversation]:
    """Group one channel's messages into thread and day conversations."""
    by_ts: dict[str, NormMessage] = {}
    for raw in raw_messages:
        m = normalise_message(raw, ctx.users, counters)
        if m is None:
            continue
        if m.user_id and m.user_id not in ctx.users:
            counters.unknown_users += 1
        # A thread_broadcast reply appears both in history and in replies:
        # one ts is one message.
        by_ts.setdefault(m.ts, m)

    threads: dict[str, list[NormMessage]] = {}
    roots_with_replies = {
        m.thread_ts for m in by_ts.values()
        if m.thread_ts and m.thread_ts != m.ts
    }
    for m in by_ts.values():
        if m.thread_ts and m.thread_ts != m.ts:
            threads.setdefault(m.thread_ts, []).append(m)
        elif m.ts in roots_with_replies or m.reply_count > 0:
            threads.setdefault(m.ts, []).append(m)

    days: dict[str, list[NormMessage]] = {}
    for m in by_ts.values():
        in_thread = (m.thread_ts and m.thread_ts != m.ts) or m.ts in threads
        if not in_thread:
            days.setdefault(local_day(m.ts, ctx.day_tz), []).append(m)

    out = [_build(channel, "thread", key, msgs, ctx) for key, msgs in threads.items()]
    out += [_build(channel, "day", key, msgs, ctx) for key, msgs in days.items()]
    counters.conversations_built += len(out)
    return out


# Fields that say HOW a conversation was read, not what it says. Excluded from
# the digest so the export route and the API route agree that the same
# conversation is unchanged (no re-post when the owner switches route).
_ROUTE_ONLY_FIELDS = ("import_route", "slack_workspace")


def digest(conv: Conversation) -> str:
    """Content digest for idempotent re-import: an unchanged conversation is
    not posted again; an edit, a new reply, a new reaction or a privacy
    change alters it."""
    data = conv.to_dict()
    data["metadata"] = {
        k: v for k, v in data["metadata"].items() if k not in _ROUTE_ONLY_FIELDS
    }
    blob = json.dumps(data, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()
