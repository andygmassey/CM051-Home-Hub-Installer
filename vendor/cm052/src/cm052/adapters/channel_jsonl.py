"""Adapter for hub channel JSONL transcripts.

Source: ``~/.zeroclaw/workspace/sessions/`` and its ``archive/``
subdirectory. Files are written by ZeroClaw's channel bridges
(iMessage, WhatsApp, email, telegram). Filenames embed channel and
conversation identity. Lines carry only ``role`` + ``content`` – no
per-message timestamps, no message ids.

Filename grammar (per Andy's spec, verified against production
archives):

::

    imessage__<phone>__<phone>.jsonl
    whatsapp_<conversation_id>_g_us__<participant>.jsonl   (group)
    whatsapp_<conversation_id>_g_us__<conversation_id>.jsonl
    whatsapp_<participant>_lid__<participant>.jsonl        (DM)

Parser rule: split on ``__`` (double underscore) to separate the
channel/conversation prefix from the participant suffix(es). The
channel name is the first ``_``-separated token of the prefix. For
whatsapp, the trailing marker ``_g_us`` (group) or ``_lid`` (DM)
distinguishes group from direct.

Per-message chronology relies on file mtime + line index per
PLAN.md recommendation (b). The SQLite ``sessions`` table has
per-row ``created_at``, but the JSONL writer does not currently
emit timestamps in the line itself; v0.2 may patch ZeroClaw to
include them.
"""
from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from ..provenance import ConversationProvenance
from ..schemas import Channel, Conversation, Message


# Channel-name → CM046/CM052 ``metadata.channel`` discriminator.
# Matches the 7-field cross-repo PR coordinated with CM046 Phase 3.
_CHANNEL_MAP: dict[str, Channel] = {
    "imessage": "im",
    "whatsapp": "im",
    "telegram": "im",
    "email": "email",
    "sms": "sms",
}


@dataclass
class _ParsedFilename:
    channel_name: str  # imessage | whatsapp | telegram | email | sms
    conversation_key: str  # filename-derived stable identity
    participants: list[str]
    is_group: bool


def _parse_filename(stem: str) -> _ParsedFilename | None:
    """Parse a JSONL filename stem (without ``.jsonl``).

    Returns ``None`` if the filename doesn't match the expected grammar
    rather than raising – so the adapter can skip unrecognised files
    instead of crashing on the next ZeroClaw filename change.
    """
    parts = stem.split("__")
    if len(parts) < 2:
        return None
    prefix, *suffixes = parts
    if not prefix:
        return None
    prefix_tokens = prefix.split("_")
    channel_name = prefix_tokens[0].lower()
    if not channel_name:
        return None

    # WhatsApp encodes group/DM via a trailing marker in the prefix.
    is_group = False
    if channel_name == "whatsapp":
        if prefix_tokens[-2:] == ["g", "us"]:
            is_group = True
            inner = "_".join(prefix_tokens[1:-2])
        elif prefix_tokens[-1] == "lid":
            inner = "_".join(prefix_tokens[1:-1])
        else:
            # Unknown marker; treat the whole tail as identifier so we
            # still ingest, just without group/DM disambiguation.
            inner = "_".join(prefix_tokens[1:])
        conversation_key = inner or stem
    else:
        # iMessage and other channels: prefix is just the channel name.
        # Conversation key is the sorted suffix tuple so DMs collapse
        # regardless of who's listed first.
        sorted_suffixes = sorted(s for s in suffixes if s)
        conversation_key = "::".join(sorted_suffixes) or stem
    return _ParsedFilename(
        channel_name=channel_name,
        conversation_key=conversation_key,
        participants=[s for s in suffixes if s],
        is_group=is_group,
    )


def _conversation_id(channel_name: str, conversation_key: str) -> str:
    payload = f"channel:{channel_name}:{conversation_key}".encode()
    return f"ch-{hashlib.sha1(payload).hexdigest()[:16]}"


def _read_jsonl(path: Path) -> list[Message]:
    """Read JSONL lines; tolerate blank lines and malformed JSON.

    Malformed lines are skipped, not fatal – a single bad line should
    not knock out an entire conversation thread. Production JSONL
    writers have written occasional partial lines on process kill.
    """
    messages: list[Message] = []
    line_index = 0
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            role = obj.get("role")
            content = obj.get("content")
            if role not in ("user", "assistant", "system", "tool"):
                continue
            if not isinstance(content, str):
                continue
            messages.append(
                Message(
                    role=role,
                    content=content,
                    timestamp=None,
                    line_index=line_index,
                )
            )
            line_index += 1
    return messages


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _iter_jsonl_files(root: Path) -> Iterable[Path]:
    if not root.exists():
        return
    for entry in sorted(root.iterdir()):
        if entry.is_file() and entry.suffix == ".jsonl":
            yield entry
    archive = root / "archive"
    if archive.exists() and archive.is_dir():
        for entry in sorted(archive.iterdir()):
            if entry.is_file() and entry.suffix == ".jsonl":
                yield entry


def read(sessions_dir: Path) -> Iterable[Conversation]:
    """Yield one ``Conversation`` per JSONL file under ``sessions_dir``
    and its ``archive/`` subdirectory.

    Conversations split across live + archive (e.g. a long-running
    iMessage thread that's been rolled over) currently produce two
    Conversation objects with the same ``conversation_id`` – the
    unifier or the CM048 wire is responsible for collapsing them. Done
    here, it would couple the adapter to merge logic; deferred to
    keep the adapter narrow.
    """
    for path in _iter_jsonl_files(sessions_dir):
        stem = path.stem
        parsed = _parse_filename(stem)
        if parsed is None:
            continue
        messages = _read_jsonl(path)
        if not messages:
            continue
        stat = path.stat()
        last_activity = _iso(stat.st_mtime)
        # ``st_birthtime`` is darwin-only; fall back to mtime elsewhere
        # rather than fail or guess.
        created_at = _iso(getattr(stat, "st_birthtime", stat.st_mtime))
        channel_discriminator = _CHANNEL_MAP.get(parsed.channel_name, "manual")
        yield Conversation(
            conversation_id=_conversation_id(
                parsed.channel_name, parsed.conversation_key
            ),
            provenance=ConversationProvenance(
                source_kind="channel",
                source_subtype=parsed.channel_name,
                original_session_id=parsed.conversation_key,
            ),
            channel=channel_discriminator,
            participants=parsed.participants,
            messages=messages,
            last_activity=last_activity,
            created_at=created_at,
            name=None,
            metadata={
                "is_group": parsed.is_group,
                "source_path": str(path),
            },
        )
