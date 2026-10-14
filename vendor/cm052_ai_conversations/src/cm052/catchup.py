"""AI chats: walk back past the 365-day clamp (v1.0.108 catch-up).

WHY. Both production invocations of ``pwg-ai-convo`` (the install-time
drain and the hourly aiconv tick) clamp discovery with ``--since-days 365``
(``cli._DEFAULT_SINCE_DAYS``), so a ChatGPT export or Claude Code history
older than a year was discovered and dropped on every run, for ever. This is
the AI-chats adapter for the shared full-history catch-up
(lib/ostler_catchup.py), driven by com.ostler.export-scan.

HOW. Discovery runs once per tick with NO clamp, through the same adapter
set the CLI uses (``cli._discover``). The conversations the clamp excluded
are walked newest first, a few per batch, each handed to
``cli.process_one``, the exact per-conversation step ``cli.run`` uses.

DEDUPE. Key = ``conversation_id``. The forward CLI's own watermark
(``cli_state.json``, ``processed``) is read READ-ONLY: anything the forward
feed already handled is skipped, and this module never writes that file
(the aiconv tick owns it; two writers would lose updates). The sink is keyed
too: the wire stages ``outbox/<conversation_id>/`` and the episodic file at
a deterministic path, both overwritten in place.

A paused subscription is not progress: ``process_one`` returning ``paused``
fails the item, so the cursor holds and the walk resumes on reactivation.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, List, Optional

import ostler_catchup as oc

from . import cli
from .schemas import Conversation

log = logging.getLogger("cm052.catchup")

INSTALL_WINDOW_DAYS = cli._DEFAULT_SINCE_DAYS


def _sort_key(conv: Conversation):
    return (conv.last_activity or "", conv.conversation_id)


class AIConversationsAdapter(oc.Adapter):
    source = "ai_conversations"
    doctor_row = "ai_conversations"
    batch_size = 5   # each item queues one model job on the Hub; keep it small

    def __init__(self, *, discover: Optional[Callable[[], List[Conversation]]] = None,
                 process: Optional[Callable[[Conversation], str]] = None,
                 state_path: Optional[Path] = None, now: Optional[datetime] = None):
        self._discover = discover or (lambda: cli._discover(0, "all"))
        self._process = process or cli.process_one
        self._state_path = state_path
        self._now = now
        self._older: Optional[List[Conversation]] = None

    def _pending(self) -> List[Conversation]:
        """Conversations older than the clamp the forward feed has not handled,
        newest first. Discovered once per tick."""
        if self._older is None:
            now = self._now or datetime.now(timezone.utc)
            cutoff = now - timedelta(days=INSTALL_WINDOW_DAYS)
            processed = cli._load_state(self._state_path or cli._state_path())["processed"]
            older = [c for c in self._discover()
                     if not cli._within_since(c, cutoff) and c.conversation_id not in processed]
            older.sort(key=_sort_key, reverse=True)
            self._older = older
        return self._older

    def start_cursor(self):
        return None   # nothing walked yet: begin at the newest excluded conversation

    def next_batch(self, cursor, limit):
        pending = self._pending()
        if cursor is not None:
            before = tuple(cursor)
            pending = [c for c in pending if _sort_key(c) < before]
        batch = pending[:max(1, limit)]
        if not batch:
            return oc.Batch(items=[], next_cursor=cursor, oldest_at=None, exhausted=True)
        last = batch[-1]
        dt = cli._parse_iso(last.last_activity)
        return oc.Batch(items=batch, next_cursor=list(_sort_key(last)),
                        oldest_at=oc.to_iso(dt) if dt else None,
                        exhausted=len(pending) <= len(batch))

    def key(self, item):
        return item.conversation_id

    def process(self, item):
        outcome = self._process(item)
        if outcome == "paused":
            log.info("catch-up ai_conversations: subscription paused; holding the walk")
            return False
        return outcome in ("posted", "l3_skipped")


def adapters():
    return [AIConversationsAdapter()]
