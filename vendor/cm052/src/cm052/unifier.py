"""Unifier: merge adapter outputs into one chronologically-ordered
chat list.

Source-agnostic: the unifier doesn't know whether a Conversation came
from the gateway DB, a channel JSONL, or (post-launch) a Claude Code
session. It just registers callables that yield Conversations and
merges their output, preferring the source with the most informative
provenance when two adapters report the same ``conversation_id``.

This is the launch boundary between "raw source-of-truth" and "the
chat history surface". Its output is consumed by:

- The CM048 wire (``wire.py``) – POSTs each Conversation to
  ``/api/v1/conversation/process`` for fact extraction.
- The Companion + desktop chat UIs (CM031, ZeroClaw re-skin) – list
  and display.
"""
from __future__ import annotations

import os
from collections.abc import Callable, Iterable
from pathlib import Path

from .adapters import (
    channel_jsonl,
    chatgpt_export,
    claude_code_watcher,
    zeroclaw_sessions,
)
from .schemas import Conversation


AdapterCallable = Callable[[Path], Iterable[Conversation]]


def _hub_dir() -> Path:
    raw = os.environ.get("CM052_USER_HUB_DIR") or "~/.zeroclaw/workspace/sessions/"
    return Path(raw).expanduser()


def _claude_code_projects_dir() -> Path:
    raw = (
        os.environ.get("CM052_CLAUDE_CODE_PROJECTS_DIR")
        or "~/.claude/projects"
    )
    return Path(raw).expanduser()


def _chatgpt_export_dir() -> Path:
    raw = (
        os.environ.get("OSTLER_CHATGPT_IMPORT_DIR")
        or "~/Documents/Ostler/imports/chatgpt"
    )
    return Path(raw).expanduser()


def _registry() -> list[tuple[AdapterCallable, Path]]:
    """Return the (adapter, source_path) pairs active in v0.2.

    Hub-channel adapters (zeroclaw_sessions + channel_jsonl) ship the
    launch sources; the Claude Code watcher and ChatGPT export
    adapter graduated from stubs to real adapters as part of the
    dual-storage milestone. Only the Claude Desktop LevelDB adapter
    remains a stub at this revision and is intentionally NOT
    registered -- registering would surface a NotImplementedError to
    every caller of ``unify()``. It will land once a real LevelDB
    reader implementation is in.
    """
    hub = _hub_dir()
    return [
        (zeroclaw_sessions.read, hub / "sessions.db"),
        (channel_jsonl.read, hub),
        (claude_code_watcher.read, _claude_code_projects_dir()),
        (chatgpt_export.read, _chatgpt_export_dir()),
    ]


def _provenance_priority(conv: Conversation) -> int:
    """Higher means richer provenance – used to break ties when two
    adapters report the same conversation_id.

    Gateway DB rows carry per-message timestamps, so they win over
    file-mtime-only JSONL reads. External-LLM sources outrank both
    because they carry routing-relevant fields (``external_provider``,
    ``original_session_id``).
    """
    kind_rank = {
        "external_llm": 3,
        "zeroclaw_gateway": 2,
        "channel": 1,
    }
    return kind_rank.get(conv.provenance.source_kind, 0)


def unify(
    adapters: list[tuple[AdapterCallable, Path]] | None = None,
) -> list[Conversation]:
    """Read every registered adapter, deduplicate by ``conversation_id``
    keeping the highest-provenance source, and return the merged list
    sorted by ``last_activity`` descending (most-recent first).

    ``adapters`` defaults to the launch registry. Tests override it to
    inject synthetic adapter callables.
    """
    if adapters is None:
        adapters = _registry()

    by_id: dict[str, Conversation] = {}
    for adapter, source in adapters:
        for conv in adapter(source):
            existing = by_id.get(conv.conversation_id)
            if existing is None or _provenance_priority(
                conv
            ) > _provenance_priority(existing):
                by_id[conv.conversation_id] = conv

    return sorted(
        by_id.values(),
        key=lambda c: c.last_activity,
        reverse=True,
    )
