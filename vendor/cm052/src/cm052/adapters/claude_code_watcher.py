"""Adapter for Claude Code session JSONLs.

Source: ``~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl``.
One JSONL per Claude Code session. Each line is a JSON object with a
``type`` discriminator; the conversational lines are
``type='user'`` and ``type='assistant'``. Other types
(``system``, ``attachment``, ``file-history-snapshot``,
``queue-operation``, ``permission-mode``, ``pr-link``,
``last-prompt``) are metadata and are skipped here -- the unifier
contract expects only conversational turns.

Line shapes (verified empirically, not committed):

::

    user:
      type='user'
      timestamp=ISO8601
      sessionId=UUID
      message={role: 'user', content: <string OR list-of-blocks>}

    assistant:
      type='assistant'
      timestamp=ISO8601
      sessionId=UUID
      message={role: 'assistant',
               content: [{type: 'thinking'|'text'|'tool_use'|...}],
               model: 'claude-...',
               usage: {...}}

User content can be a plain string (typed prompt) or a list of
content blocks; in particular slash-command invocations produce a
list shape with ``<command-name>`` artefacts. Assistant content is
always a list of typed blocks.

Cleaning rules (intentionally conservative -- the goal is a
readable transcript, not a perfect replay):

- ``thinking`` blocks are dropped (private reasoning, noise).
- ``text`` blocks are concatenated into the message body.
- ``tool_use`` blocks are rendered as ``[tool: <name>]`` placeholders
  so the dialogue still reads coherently when tool calls happened.
- ``tool_result`` blocks (which appear in user turns after a tool
  call) are rendered as ``[tool_result]`` followed by the textual
  result, truncated to keep the transcript readable.
- Slash-command shells (``<command-message>`` /
  ``<command-name>``) are stripped from user content.

Active-session safety: the running Claude Code daemon writes its
JSONL incrementally. Reading and emitting an in-flight session
would persist a half-finished conversation. The adapter skips a file
if either:

- its mtime is within ``CM052_CLAUDE_CODE_DEBOUNCE_SECS`` seconds
  (default 300 / 5 min), or
- ``lsof`` (where available) reports the file as held open by a
  live process.

The ``lsof`` check is opportunistic; if the binary isn't on PATH the
adapter falls back to mtime alone, which is the documented
behaviour the brief allows.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import time
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..provenance import ConversationProvenance
from ..schemas import Conversation, Message


log = logging.getLogger(__name__)


_DEFAULT_DEBOUNCE_SECS = 300


def _projects_dir() -> Path:
    raw = os.environ.get("CM052_CLAUDE_CODE_PROJECTS_DIR") or "~/.claude/projects"
    return Path(raw).expanduser()


def _debounce_secs() -> int:
    raw = os.environ.get("CM052_CLAUDE_CODE_DEBOUNCE_SECS")
    if not raw:
        return _DEFAULT_DEBOUNCE_SECS
    try:
        return max(0, int(raw))
    except ValueError:
        log.warning(
            "Ignoring non-integer CM052_CLAUDE_CODE_DEBOUNCE_SECS=%r; "
            "using default %d",
            raw,
            _DEFAULT_DEBOUNCE_SECS,
        )
        return _DEFAULT_DEBOUNCE_SECS


def _is_finalised(path: Path, *, now: float | None = None) -> bool:
    """Return True if ``path`` looks like a session that's done writing.

    Two checks compose: idle-since-mtime, and lsof-not-held. Either
    failing means we treat the session as live and skip.
    """
    debounce = _debounce_secs()
    try:
        stat = path.stat()
    except FileNotFoundError:
        return False
    cutoff = (now or time.time()) - debounce
    if stat.st_mtime > cutoff:
        return False
    if shutil.which("lsof"):
        try:
            result = subprocess.run(
                ["lsof", "--", str(path)],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            # lsof exits 1 with empty stdout when no process holds the
            # file -- that is the "finalised" branch we want.
            if result.returncode == 0 and result.stdout.strip():
                return False
        except (subprocess.TimeoutExpired, OSError) as exc:
            log.debug("lsof check failed for %s: %s", path, exc)
    return True


def _conversation_id(session_uuid: str) -> str:
    payload = f"external_llm:claude_code:{session_uuid}".encode()
    return f"cc-{hashlib.sha1(payload).hexdigest()[:16]}"


_COMMAND_SHELL_TAGS = (
    "command-message",
    "command-name",
    "local-command-stdout",
    "local-command-stderr",
)

# Match either ``<tag>...</tag>`` (single-line) or ``<tag>...</tag>``
# spanning multiple lines (DOTALL). Both shapes appear in real
# Claude Code transcripts.
_COMMAND_SHELL_RE = re.compile(
    r"<(" + "|".join(_COMMAND_SHELL_TAGS) + r")\b[^>]*>.*?</\1>",
    flags=re.DOTALL,
)


def _strip_command_shell(text: str) -> str:
    """Drop Claude Code slash-command preamble tags from a user
    message. They're injection artefacts, not user-typed content.

    Tags can appear inline (open + content + close on one line) or
    span multiple lines, and a single user message can contain
    several. Regex DOTALL handles both shapes.
    """
    if not any(f"<{tag}" in text for tag in _COMMAND_SHELL_TAGS):
        return text
    cleaned = _COMMAND_SHELL_RE.sub("", text)
    # Collapse blank lines left behind so consecutive tags don't
    # leave a wall of whitespace ahead of the user's actual text.
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned.strip()


def _render_user_content(content: Any) -> str:
    """Flatten a user message's ``content`` (string or block list) into
    plain text, with the slash-command shell stripped.
    """
    if isinstance(content, str):
        return _strip_command_shell(content).strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            text = block.get("text") or ""
            parts.append(_strip_command_shell(text))
        elif btype == "tool_result":
            inner = block.get("content")
            if isinstance(inner, list):
                inner_text = " ".join(
                    str(c.get("text") or "")
                    for c in inner
                    if isinstance(c, dict) and c.get("type") == "text"
                )
            else:
                inner_text = str(inner or "")
            inner_text = inner_text.strip()
            if len(inner_text) > 500:
                inner_text = inner_text[:500] + "..."
            parts.append(f"[tool_result] {inner_text}".rstrip())
        # Other block types in user turns (image, etc.) are dropped.
    return "\n\n".join(p for p in parts if p).strip()


def _render_assistant_content(content: Any) -> tuple[str, bool]:
    """Flatten an assistant message's ``content`` block list.

    Returns the rendered body plus a flag indicating whether any
    ``tool_use`` blocks were observed -- callers may want to track
    that on Conversation.metadata for downstream classification.
    """
    used_tools = False
    if not isinstance(content, list):
        return (str(content or "").strip(), False)
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            text = (block.get("text") or "").strip()
            if text:
                parts.append(text)
        elif btype == "tool_use":
            used_tools = True
            name = block.get("name") or "unknown"
            parts.append(f"[tool: {name}]")
        # 'thinking' blocks dropped; other types ignored.
    return ("\n\n".join(parts).strip(), used_tools)


def _parse_jsonl(path: Path) -> tuple[list[Message], dict[str, Any]]:
    """Read a Claude Code JSONL into Messages plus a small metadata
    bag (model, tool usage, started/ended timestamps).

    Malformed lines are skipped, not fatal.
    """
    messages: list[Message] = []
    line_index = 0
    model: str | None = None
    tool_use_seen = False
    first_ts: str | None = None
    last_ts: str | None = None
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            line_type = obj.get("type")
            if line_type not in ("user", "assistant"):
                continue
            msg = obj.get("message")
            if not isinstance(msg, dict):
                continue
            role = msg.get("role")
            if role not in ("user", "assistant"):
                continue
            timestamp = obj.get("timestamp")
            if isinstance(timestamp, str):
                if first_ts is None:
                    first_ts = timestamp
                last_ts = timestamp
            content_raw = msg.get("content")
            if role == "user":
                body = _render_user_content(content_raw)
            else:
                body, used = _render_assistant_content(content_raw)
                tool_use_seen = tool_use_seen or used
                m = msg.get("model")
                if isinstance(m, str) and m and model is None:
                    model = m
            if not body:
                continue
            messages.append(
                Message(
                    role=role,
                    content=body,
                    timestamp=timestamp if isinstance(timestamp, str) else None,
                    line_index=line_index,
                )
            )
            line_index += 1
    metadata: dict[str, Any] = {
        "source_path": str(path),
        "tool_use_seen": tool_use_seen,
    }
    if model:
        metadata["model"] = model
    if first_ts:
        metadata["started_at"] = first_ts
    if last_ts:
        metadata["ended_at"] = last_ts
    return messages, metadata


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _iter_session_files(projects_dir: Path) -> Iterable[Path]:
    if not projects_dir.exists():
        return
    for project_dir in sorted(projects_dir.iterdir()):
        if not project_dir.is_dir():
            continue
        for entry in sorted(project_dir.iterdir()):
            if entry.is_file() and entry.suffix == ".jsonl":
                yield entry


def read(projects_dir: Path | None = None) -> Iterable[Conversation]:
    """Yield one ``Conversation`` per finalised Claude Code session JSONL
    under ``projects_dir`` (default ``~/.claude/projects``).

    Active sessions (mtime within debounce window or held open by a
    live process per ``lsof``) are skipped -- they'll appear on the
    next read once the daemon has finished writing them.
    """
    root = projects_dir or _projects_dir()
    for path in _iter_session_files(root):
        if not _is_finalised(path):
            log.debug("Skipping active Claude Code session: %s", path)
            continue
        messages, meta = _parse_jsonl(path)
        if not messages:
            continue
        session_uuid = path.stem
        stat = path.stat()
        last_activity = meta.get("ended_at") or _iso(stat.st_mtime)
        created_at = meta.get("started_at") or _iso(
            getattr(stat, "st_birthtime", stat.st_mtime)
        )
        provenance = ConversationProvenance(
            source_kind="external_llm",
            source_subtype="claude_code",
            external_provider="anthropic",
            external_model=meta.get("model"),
            original_session_id=session_uuid,
            # v0.2 still emits False; the BYOM-keys lookup that
            # would flip this to True hasn't shipped (PLAN.md v0.2
            # routing milestone).
            can_continue_at_origin=False,
        )
        yield Conversation(
            conversation_id=_conversation_id(session_uuid),
            provenance=provenance,
            channel="manual",
            participants=["user", "assistant"],
            messages=messages,
            last_activity=last_activity,
            created_at=created_at,
            name=None,
            metadata={
                "source_path": meta["source_path"],
                "tool_use_seen": meta["tool_use_seen"],
                "project_dir": path.parent.name,
            },
        )
