"""Stub for the Claude Desktop LevelDB adapter (post-launch v0.2,
best-effort).

Claude Desktop stores conversations in Chromium IndexedDB-on-LevelDB
under ``~/Library/Application Support/Claude/Local Storage/``. Reads
are fragile (Chromium safe-storage encryption, lock contention while
the app is running) so this is the lowest-priority adapter and the
recommended user path remains the claude.ai web export consumed via
the ``chatgpt_export``-style drop-folder pattern.

Locked at v0.1 to keep the unifier's adapter registry stable.
"""
from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from ..schemas import Conversation


def read(_leveldb_dir: Path) -> Iterable[Conversation]:
    raise NotImplementedError(
        "Claude Desktop LevelDB adapter is best-effort v0.2 work; "
        "the supported path is the web export adapter."
    )
