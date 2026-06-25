"""Shared per-channel hydration progress signal.

The post-install settling experience has TWO sides that must agree on
"how far through the backlog are we, per source":

  * the background-feed LaunchAgents (iMessage / WhatsApp / email /
    spoken) DRAIN the historic conversation backlog over hours, one
    conversation at a time; and
  * the wiki "still settling in" panel (CM044 ``compiler/hydration.py``)
    READS that progress and renders it in plain English with a real,
    falling ETA.

They live in different repos and different venvs, so -- exactly like the
three identical frontmatter parsers in the AI-Chats pipeline -- this
module is COPIED verbatim into each ``*_source`` package rather than
shared via a cross-venv dependency. Keep the copies byte-identical; the
contract is the JSON file shape, not the import path.

File location
    ``~/.ostler/state/hydration_progress.json`` -- a sibling of
    ``wiki_hydration.json`` and ``pipeline_signals.json`` so the
    containerised wiki compiler reaches it over the same host bind-mount
    that already exposes ``~/.ostler/state``. Override with
    ``OSTLER_HYDRATION_PROGRESS_FILE`` (an absolute path) for tests or a
    bind-mounted compiler.

JSON shape (the contract both sides depend on)::

    {
      "version": 1,
      "updated_utc": "2026-06-26T09:04:12+00:00",   # ISO8601 UTC
      "channels": {
        "contacts":  {"queued": 1048, "done": 1048, "failed": 0, "state": "ready"},
        "calendar":  {"queued":  210, "done":  210, "failed": 0, "state": "ready"},
        "imessage":  {"queued":  250, "done":   70, "failed": 0, "state": "working"},
        "whatsapp":  {"queued":    0, "done":    0, "failed": 0, "state": "absent"},
        "email":     {"queued":    0, "done":    0, "failed": 0, "state": "absent"},
        "spoken":    {"queued":    0, "done":    0, "failed": 0, "state": "absent"},
        "notes":     {"queued":    0, "done":    0, "failed": 0, "state": "absent"}
      },
      "overall": {"done": 1328, "total": 1508, "failed": 0}
    }

``state`` is one of:
  * ``ready``   -- nothing queued or everything done (a tick),
  * ``working`` -- a backlog is still draining,
  * ``absent``  -- no source of that kind on this Mac.

Per-channel ``queued`` is the BACKLOG this channel will work through;
``done`` is how many of that backlog it has finished. ``failed`` is how
many of that backlog were PERMANENTLY failed (counted in ``queued`` but
that will never reach ``done``); the wiki settling panel treats
``done + failed`` as "settled" so one permanently-failed item does not
keep the panel up forever (S1). ``overall`` is the sum across channels so
the panel can show one headline figure and a rate-based ETA without
re-deriving it.

Two write semantics live behind this one ``update_channel`` contract (N3):
  * iMessage is CUMULATIVE-PERSISTENT -- it re-emits absolute
    ``queued`` / ``done`` running totals each tick, and a transiently
    failed session is retried next tick (it stays in ``queued`` and is
    NOT reported as ``failed``, so the bar simply has not reached it yet).
  * whatsapp / email / spoken are PER-TICK-OVERWRITE -- each tick reports
    that tick's ``queued = dispatched + skipped + failed`` and
    ``done = dispatched + skipped``, and a failed item that will not be
    retried is reported as ``failed`` so the panel can settle without it.
``failed`` defaults to 0 and is optional, so an older writer that never
sets it stays valid (overall.failed simply stays 0).

ONE channel key per FEED (``imessage`` / ``whatsapp`` / ``email`` /
``spoken``) so two feeds never clobber each other's slice. The wiki panel
groups these raw feeds into plain-English buckets for display (iMessage +
WhatsApp + spoken -> "your message history"); the signal stays granular.

The writer is forward-only and merge-aware: each feed updates only its
OWN channel key, reads-modifies-writes atomically (temp file +
``os.replace``) so a concurrent reader never sees a torn document and two
feeds ticking close together do not clobber each other's channel.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

log = logging.getLogger(__name__)

PROGRESS_FILENAME = "hydration_progress.json"
SCHEMA_VERSION = 1
PROGRESS_PATH_ENV = "OSTLER_HYDRATION_PROGRESS_FILE"
DEFAULT_STATE_DIR = Path.home() / ".ostler" / "state"

# The canonical channel keys. ``contacts`` and ``calendar`` are filled by
# the fast install-time hydrate (they are "ready now" almost immediately);
# each conversation feed writes its OWN key so feeds never clobber each
# other. ``notes`` is the Evernote/knowledge backlog.
CHANNELS = (
    "contacts", "calendar",
    "imessage", "whatsapp", "email", "spoken",
    "notes",
)

# Each conversation feed reports under its own key (1:1). The wiki panel
# does the feed -> display-bucket grouping, not the writer.
FEED_CHANNEL = {
    "imessage": "imessage",
    "whatsapp": "whatsapp",
    "email": "email",
    "spoken": "spoken",
}


def progress_path() -> Path:
    """Resolve the single shared progress-signal file location."""
    env = os.environ.get(PROGRESS_PATH_ENV)
    if env:
        return Path(env).expanduser()
    return DEFAULT_STATE_DIR / PROGRESS_FILENAME


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _empty_channel() -> Dict[str, Any]:
    return {"queued": 0, "done": 0, "failed": 0, "state": "absent"}


def _blank() -> Dict[str, Any]:
    return {
        "version": SCHEMA_VERSION,
        "updated_utc": _utcnow_iso(),
        "channels": {k: _empty_channel() for k in CHANNELS},
        "overall": {"done": 0, "total": 0, "failed": 0},
    }


def read_progress(target: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    """Read the progress signal, or ``None`` if absent/unreadable."""
    if target is None:
        path = progress_path()
    else:
        target = Path(target)
        path = target / PROGRESS_FILENAME if target.is_dir() else target
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception as exc:  # never raise into a reader
        log.warning("hydration progress read failed (%s: %s)",
                    type(exc).__name__, exc)
        return None


def _recompute_overall(doc: Dict[str, Any]) -> None:
    done = total = failed = 0
    for ch in doc.get("channels", {}).values():
        if not isinstance(ch, dict):
            continue
        total += int(ch.get("queued") or 0)
        done += int(ch.get("done") or 0)
        failed += int(ch.get("failed") or 0)
    doc["overall"] = {"done": done, "total": total, "failed": failed}


def _derive_state(queued: int, done: int, *, absent: bool,
                  failed: int = 0) -> str:
    if absent:
        return "absent"
    # done + failed settles the backlog: a channel whose remaining items
    # have all either finished or permanently failed is "ready", not stuck
    # "working" forever on the failed remainder (S1).
    if queued <= 0 or done + failed >= queued:
        return "ready"
    return "working"


def _atomic_write(path: Path, doc: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(doc, indent=2)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent),
                              prefix=".hydprog_", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def update_channel(
    channel: str,
    *,
    queued: Optional[int] = None,
    done: Optional[int] = None,
    failed: Optional[int] = None,
    state: Optional[str] = None,
    target: Optional[Path] = None,
) -> Optional[Dict[str, Any]]:
    """Merge an update for ONE channel into the shared progress file.

    Reads the current document (or starts a blank one), updates only the
    named channel's ``queued`` / ``done`` / ``failed`` (whichever are
    supplied), re-derives that channel's ``state`` (unless an explicit
    ``state`` is given), recomputes ``overall`` and writes atomically.

    ``failed`` is the count of PERMANENTLY-failed items in this channel's
    backlog -- counted in ``queued`` but that will never reach ``done``.
    The wiki settling panel treats ``done + failed`` as settled so a
    permanently-failed item cannot keep the panel up forever (S1). It is
    optional and defaults to 0, so an older writer stays valid.

    Best-effort: any failure is logged and swallowed (a progress-signal
    write must NEVER break a feed tick). Returns the written document on
    success, ``None`` on failure or an unknown channel.
    """
    if channel not in CHANNELS:
        log.warning("hydration progress: unknown channel %r", channel)
        return None
    path = progress_path() if target is None else (
        Path(target) / PROGRESS_FILENAME if Path(target).is_dir() else Path(target)
    )
    try:
        doc = read_progress(path) or _blank()
        chans = doc.setdefault("channels", {})
        cur = chans.get(channel)
        if not isinstance(cur, dict):
            cur = _empty_channel()
        if queued is not None:
            cur["queued"] = max(0, int(queued))
        if done is not None:
            cur["done"] = max(0, int(done))
        if failed is not None:
            cur["failed"] = max(0, int(failed))
        # done can never exceed queued in the signal (a late count revision
        # must not make the bar read >100%).
        if cur.get("done", 0) > cur.get("queued", 0):
            cur["done"] = cur["queued"]
        # failed is bounded by whatever room queued leaves above done, so
        # done + failed can never exceed queued (the settled count caps at
        # 100%).
        if cur.get("done", 0) + cur.get("failed", 0) > cur.get("queued", 0):
            cur["failed"] = max(0, cur.get("queued", 0) - cur.get("done", 0))
        absent = (cur.get("queued", 0) == 0 and cur.get("done", 0) == 0
                  and cur.get("failed", 0) == 0 and state is None)
        cur["state"] = state or _derive_state(
            cur.get("queued", 0), cur.get("done", 0), absent=absent,
            failed=cur.get("failed", 0),
        )
        chans[channel] = cur
        doc["version"] = SCHEMA_VERSION
        doc["updated_utc"] = _utcnow_iso()
        _recompute_overall(doc)
        _atomic_write(path, doc)
        return doc
    except Exception as exc:
        log.warning("hydration progress update failed (%s: %s)",
                    type(exc).__name__, exc)
        return None
