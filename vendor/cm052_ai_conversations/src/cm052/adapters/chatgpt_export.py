"""Adapter for ChatGPT user-initiated exports.

Source: a "drop folder" (default ``~/Documents/Ostler/imports/chatgpt/``,
override via ``OSTLER_CHATGPT_IMPORT_DIR``) into which the user drops
the contents of an export downloaded from chatgpt.com -> Settings ->
Data Controls -> Export Data.

The export is a zip; once unpacked it contains a top-level
``conversations.json`` plus ``chat.html`` and ``user.json``. We only
need ``conversations.json`` -- the JSON is the source of truth.

JSON shape (verified against current ChatGPT exports as of
2026-05-08):

::

    [
      {
        "id": "<conversation uuid>",
        "title": "<conversation title or null>",
        "create_time": <unix seconds, float>,
        "update_time": <unix seconds, float>,
        "default_model_slug": "gpt-5",
        "mapping": {
          "<node uuid>": {
            "id": "<node uuid>",
            "parent": "<parent uuid or null>",
            "children": ["<child uuid>", ...],
            "message": {
              "id": "<message uuid>",
              "author": {"role": "user"|"assistant"|"system"|"tool",
                          "metadata": {...}},
              "content": {"content_type": "text",
                           "parts": ["..."]},
              "create_time": <unix seconds>,
              "metadata": {"model_slug": "gpt-5", ...}
            } | null,
            "..."
          },
          ...
        }
      },
      ...
    ]

Reconstruction rule: walk ``mapping`` from the unique root node
(``parent is None``) down through ``children``; emit one
``Message`` per node whose ``message.author.role`` is ``user`` or
``assistant``. ``system`` and ``tool`` nodes are skipped at the
adapter layer (they're framework noise; the gist they reveal is
already captured in user/assistant text).

Drop-folder vs single file: the user may stage multiple exports
over time (one per quarter, say). The adapter scans the drop folder
recursively for any file named ``conversations.json`` so a user can
just drag-and-drop the unpacked export root into the folder and let
the adapter pick it up.

Idempotency: a given ``conversation_id`` always hashes to the same
deterministic id ("og-XXXXXXXXXXXXXXXX"), so re-importing the same
export overwrites at the wire layer without producing duplicates.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..provenance import ConversationProvenance
from ..schemas import Conversation, Message


log = logging.getLogger(__name__)


_DEFAULT_DROP_FOLDER = "~/Documents/Ostler/imports/chatgpt"


def _drop_folder() -> Path:
    raw = os.environ.get("OSTLER_CHATGPT_IMPORT_DIR") or _DEFAULT_DROP_FOLDER
    return Path(raw).expanduser()


def _conversation_id(original_id: str) -> str:
    """Deterministic CM052 id for a ChatGPT conversation.

    Prefix ``og-`` (OpenAI / GPT) so the namespace cannot collide
    with the Claude Code watcher's ``cc-`` or the channel adapter's
    ``ch-`` prefixes.
    """
    payload = f"external_llm:chatgpt:{original_id}".encode()
    return f"og-{hashlib.sha1(payload).hexdigest()[:16]}"


def _iso(unix: float | int | None) -> str | None:
    """Convert a unix-seconds timestamp into an ISO 8601 UTC string.

    ChatGPT exports use float seconds (with sub-second precision);
    the wire-side ``render_episodic`` and the unifier sort key both
    treat ``timestamp`` as opaque strings, so we just normalise to
    a stable RFC-3339 form.
    """
    if unix is None:
        return None
    try:
        return datetime.fromtimestamp(float(unix), tz=timezone.utc).isoformat()
    except (TypeError, ValueError, OSError) as exc:
        log.debug("chatgpt: invalid timestamp %r (%s)", unix, exc)
        return None


def _flatten_parts(content: Any) -> str:
    """Concatenate ChatGPT's ``content.parts`` list into a single
    string body. The export has multiple ``content_type`` shapes
    (text, multimodal_text, code, ...). We trust the parts as-is for
    text-bearing types and ignore non-text parts -- they don't fit
    the speaker-labelled transcript model the dual-storage rule
    expects.
    """
    if not isinstance(content, dict):
        return ""
    ctype = content.get("content_type")
    parts = content.get("parts")
    if isinstance(parts, list):
        text_parts: list[str] = []
        for p in parts:
            if isinstance(p, str):
                text_parts.append(p)
            elif isinstance(p, dict):
                # Some 'multimodal_text' parts are dicts with their own
                # text field; pull just the text and drop image refs.
                inner = p.get("text") if isinstance(p.get("text"), str) else None
                if inner:
                    text_parts.append(inner)
        return "\n\n".join(t for t in text_parts if t).strip()
    # ``code`` / ``tether_browsing_display`` / etc. typically have a
    # ``text`` field rather than ``parts``.
    text = content.get("text")
    if isinstance(text, str):
        return text.strip()
    log.debug("chatgpt: unknown content_type=%r dropped", ctype)
    return ""


def _walk_mapping(mapping: dict[str, dict]) -> list[dict]:
    """Walk the mapping tree from the single root downwards.

    Returns nodes in depth-first order along the canonical
    parent->children chain. Real exports occasionally have multiple
    "branches" (when the user used the regenerate-response feature);
    we follow the *first* child at each fork. That matches the order
    chatgpt.com displays as the "current" thread; the alternative
    branches are exposed in the export but not surfaced as separate
    Messages here -- they'd over-count an episodic transcript.
    """
    if not isinstance(mapping, dict):
        return []
    # The export format guarantees one root; defensive: pick the
    # first node with ``parent is None`` if multiple.
    roots = [
        node for node in mapping.values()
        if isinstance(node, dict) and node.get("parent") is None
    ]
    if not roots:
        return []
    ordered: list[dict] = []
    cursor = roots[0]
    seen_ids: set[str] = set()
    while cursor is not None:
        node_id = cursor.get("id")
        if not isinstance(node_id, str) or node_id in seen_ids:
            # Cycle defence; should never trip on real exports.
            break
        seen_ids.add(node_id)
        ordered.append(cursor)
        children = cursor.get("children")
        if not isinstance(children, list) or not children:
            break
        first_child_id = children[0]
        if not isinstance(first_child_id, str):
            break
        cursor = mapping.get(first_child_id)
    return ordered


def _node_to_message(node: dict, line_index: int) -> Message | None:
    """Convert one mapping node into a Message, or None if the node
    is metadata-only (system instruction, deleted message, etc.)."""
    msg = node.get("message")
    if not isinstance(msg, dict):
        return None
    author = msg.get("author")
    role = author.get("role") if isinstance(author, dict) else None
    if role not in ("user", "assistant"):
        return None
    body = _flatten_parts(msg.get("content"))
    if not body:
        return None
    return Message(
        role=role,
        content=body,
        timestamp=_iso(msg.get("create_time")),
        line_index=line_index,
    )


def _model_for_conversation(
    conversation: dict, ordered_nodes: list[dict]
) -> str | None:
    """Best-effort model identifier. Prefer the conversation-level
    ``default_model_slug``; fall back to the first assistant message's
    ``metadata.model_slug``.
    """
    candidate = conversation.get("default_model_slug")
    if isinstance(candidate, str) and candidate:
        return candidate
    for node in ordered_nodes:
        msg = node.get("message")
        if not isinstance(msg, dict):
            continue
        author = msg.get("author")
        if not isinstance(author, dict) or author.get("role") != "assistant":
            continue
        meta = msg.get("metadata") or {}
        slug = meta.get("model_slug") if isinstance(meta, dict) else None
        if isinstance(slug, str) and slug:
            return slug
    return None


def _iter_export_files(root: Path) -> Iterable[Path]:
    """Find ``conversations.json`` files anywhere under ``root``.

    Recursive so the user can dump unpacked export roots straight in;
    ``conversations.json`` is the canonical filename in every export
    we have seen.
    """
    if not root.exists() or not root.is_dir():
        return
    yield from sorted(root.rglob("conversations.json"))


def _conversations_from_export(
    payload: Any, source_path: Path
) -> Iterable[Conversation]:
    """Yield Conversations from a parsed ``conversations.json`` blob.

    The file is always a top-level list; defensive against
    single-conversation files that may wrap in ``{"conversations":
    [...]}``.
    """
    items: list[dict]
    if isinstance(payload, list):
        items = [p for p in payload if isinstance(p, dict)]
    elif isinstance(payload, dict):
        candidate = payload.get("conversations")
        if isinstance(candidate, list):
            items = [p for p in candidate if isinstance(p, dict)]
        else:
            items = [payload] if payload.get("mapping") else []
    else:
        items = []

    for conv in items:
        original_id = conv.get("id")
        if not isinstance(original_id, str) or not original_id:
            log.debug(
                "chatgpt: %s skipping conversation with no id", source_path
            )
            continue
        mapping = conv.get("mapping")
        ordered = _walk_mapping(mapping) if isinstance(mapping, dict) else []
        messages: list[Message] = []
        for node in ordered:
            line_index = len(messages)
            m = _node_to_message(node, line_index)
            if m is not None:
                messages.append(m)
        if not messages:
            continue

        first_ts = next((m.timestamp for m in messages if m.timestamp), None)
        last_ts = next(
            (m.timestamp for m in reversed(messages) if m.timestamp),
            None,
        )
        created_at = _iso(conv.get("create_time")) or first_ts
        last_activity = _iso(conv.get("update_time")) or last_ts or created_at
        if not last_activity:
            # Without any timestamps we can't position the conversation
            # in the unified inbox; skip rather than guess.
            log.debug(
                "chatgpt: %s skipping %s -- no usable timestamps",
                source_path, original_id,
            )
            continue

        model = _model_for_conversation(conv, ordered)
        provenance = ConversationProvenance(
            source_kind="external_llm",
            source_subtype="chatgpt",
            external_provider="openai",
            external_model=model,
            original_session_id=original_id,
            can_continue_at_origin=False,
        )
        title = conv.get("title")
        yield Conversation(
            conversation_id=_conversation_id(original_id),
            provenance=provenance,
            channel="manual",
            participants=["user", "assistant"],
            messages=messages,
            last_activity=last_activity,
            created_at=created_at,
            name=title if isinstance(title, str) and title else None,
            metadata={
                "source_path": str(source_path),
                "original_conversation_id": original_id,
            },
        )


def read(drop_folder: Path | None = None) -> Iterable[Conversation]:
    """Yield Conversations from every ``conversations.json`` under
    ``drop_folder`` (default ``~/Documents/Ostler/imports/chatgpt``).

    The adapter is read-only: it never deletes or moves the export
    files, so the user can safely re-run an import or compare it
    against a later export.
    """
    root = drop_folder or _drop_folder()
    for export_file in _iter_export_files(root):
        try:
            with export_file.open("r", encoding="utf-8") as fh:
                payload = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            log.warning(
                "chatgpt: cannot parse %s (%s); skipping",
                export_file, exc,
            )
            continue
        yield from _conversations_from_export(payload, export_file)
