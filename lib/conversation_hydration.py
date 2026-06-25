#!/usr/bin/env python3
"""Per-channel conversation-hydration progress signal (BUG-037 / BUG-039).

Writes ``~/.ostler/state/conversation_hydration.json`` -- the small,
atomic "queued + done per channel" signal that the CM044 "still settling
in" panel (BUG-039) reads to show the customer real progress while the
background conversation-bundle feeds drain the backlog over hours.

It is the sibling of ``wiki_hydration.json`` and uses the same
atomic-write contract as ``write_pipeline_signals.py``.

Why this exists
---------------
On a fresh install the four conversation-bundle LaunchAgents
(iMessage / WhatsApp / email / meeting-voice) each run ~6 LLM calls per
conversation across the whole 30-day backlog. That is a multi-hour grind.
The agreed fix (BUG-037, Andy 2026-06-25) is NOT to run it synchronously
in the installer: the installer *seeds* this signal (queued counts, done
= 0) in seconds, then the already-installed background feeds drain the
backlog post-install, bumping ``done`` as each conversation is processed.
The panel turns that into a plain-English, climbing progress surface.

Schema (additive; unknown channels preserved across writes)::

    {
      "schema": 1,
      "install_ts": 1719272400,          # epoch seconds, set on first seed
      "updated_ts": 1719272700,          # epoch seconds, set on every write
      "channels": {
        "imessage": {"queued": 120, "done": 7,  "status": "draining"},
        "email":    {"queued": 40,  "done": 40, "status": "ready"},
        "whatsapp": {"queued": 0,   "done": 0,  "status": "none"},
        "spoken":   {"queued": 3,   "done": 1,  "status": "draining"}
      }
    }

``status`` is derived, never authoritative -- the panel may recompute it
from queued/done -- but it is convenient for a quick read:
``none`` (queued 0), ``draining`` (done < queued), ``ready`` (done >= queued
and queued > 0).

CLI forms (so install.sh -- a bash script -- can drive it)::

    # Seed a channel's queued backlog (done left at its current value,
    # default 0). Idempotent: re-seeding updates queued, never lowers done.
    python3 conversation_hydration.py seed --channel imessage --queued 120

    # Atomically add to a channel's done counter (the per-conversation
    # heartbeat the feeds emit as they drain). Never exceeds queued.
    python3 conversation_hydration.py bump --channel imessage --done 1

Atomic-write contract (same as write_pipeline_signals.py):
    - write to ``<output>.tmp.<pid>`` first, chmod 0600, ``os.replace``.

Exit codes:
    0  success
    2  unusable inputs (bad int, unknown channel, bad sub-command)
    3  unwritable output path

British English throughout. No personal data ever lands here -- counts
only, never names or message content.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

SCHEMA_VERSION = 1

# The four wired human channels. Keeping this closed-set means a typo in a
# wrapper cannot silently invent a phantom channel the panel never expects.
KNOWN_CHANNELS = ("imessage", "whatsapp", "email", "spoken")


def default_output_path() -> str:
    """Resolve the signal path, honouring OSTLER_STATE_DIR (engine zone)."""
    state_dir = os.getenv("OSTLER_STATE_DIR")
    if state_dir:
        base = os.path.expanduser(state_dir)
    else:
        base = os.path.join(os.path.expanduser("~"), ".ostler", "state")
    return os.path.join(base, "conversation_hydration.json")


def _load_existing(path: str) -> dict[str, Any]:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def _coerce_channels(existing: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = existing.get("channels")
    out: dict[str, dict[str, Any]] = {}
    if isinstance(raw, dict):
        for name, entry in raw.items():
            if not isinstance(entry, dict):
                continue
            queued = entry.get("queued")
            done = entry.get("done")
            out[name] = {
                "queued": queued if isinstance(queued, int) and queued >= 0 else 0,
                "done": done if isinstance(done, int) and done >= 0 else 0,
            }
    return out


def _status_for(queued: int, done: int) -> str:
    if queued <= 0:
        return "none"
    if done >= queued:
        return "ready"
    return "draining"


def _normalise(channel: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Clamp done to [0, queued] and (re)derive status for every channel."""
    out: dict[str, dict[str, Any]] = {}
    for name, entry in channel.items():
        queued = max(0, int(entry.get("queued", 0)))
        done = max(0, int(entry.get("done", 0)))
        if done > queued:
            done = queued
        out[name] = {
            "queued": queued,
            "done": done,
            "status": _status_for(queued, done),
        }
    return out


def build_seed(
    existing: dict[str, Any],
    channel: str,
    queued: int,
    now: int,
) -> dict[str, Any]:
    """Seed (or re-seed) a channel's queued backlog.

    Re-seeding updates ``queued`` but never lowers an existing ``done``
    (a re-run after the feeds have started must not erase real progress).
    ``install_ts`` is set once, on the first seed of any channel.
    """
    channels = _coerce_channels(existing)
    prev = channels.get(channel, {"queued": 0, "done": 0})
    channels[channel] = {"queued": max(0, queued), "done": prev.get("done", 0)}

    install_ts = existing.get("install_ts")
    if not isinstance(install_ts, int) or install_ts <= 0:
        install_ts = now

    return {
        "schema": SCHEMA_VERSION,
        "install_ts": install_ts,
        "updated_ts": now,
        "channels": _normalise(channels),
    }


def build_bump(
    existing: dict[str, Any],
    channel: str,
    delta: int,
    now: int,
) -> dict[str, Any]:
    """Add ``delta`` to a channel's ``done`` counter (the heartbeat)."""
    channels = _coerce_channels(existing)
    prev = channels.get(channel, {"queued": 0, "done": 0})
    new_done = max(0, prev.get("done", 0) + delta)
    channels[channel] = {"queued": prev.get("queued", 0), "done": new_done}

    install_ts = existing.get("install_ts")
    if not isinstance(install_ts, int) or install_ts <= 0:
        install_ts = now

    return {
        "schema": SCHEMA_VERSION,
        "install_ts": install_ts,
        "updated_ts": now,
        "channels": _normalise(channels),
    }


def atomic_write(path: str, payload: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, path)


# ---------------------------------------------------------------------------
# In-process API (used by the feed pipelines so they don't shell out per
# conversation). Best-effort: a signal-write failure must NEVER break a feed
# tick -- the conversation still got dispatched; only the progress dot is lost.
# ---------------------------------------------------------------------------
def seed(channel: str, queued: int, output: str | None = None) -> None:
    path = output or default_output_path()
    existing = _load_existing(path)
    atomic_write(path, build_seed(existing, channel, queued, int(time.time())))


def bump_done(channel: str, delta: int = 1, output: str | None = None) -> None:
    if delta == 0:
        return
    path = output or default_output_path()
    existing = _load_existing(path)
    atomic_write(path, build_bump(existing, channel, delta, int(time.time())))


def bump_done_safe(channel: str, delta: int = 1, output: str | None = None) -> None:
    """bump_done that swallows every error (for use on a feed's hot path)."""
    try:
        bump_done(channel, delta, output)
    except Exception:  # noqa: BLE001 -- progress signal is never load-bearing
        pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="conversation_hydration",
        description=(
            "Maintain the per-channel conversation-hydration progress signal "
            "(~/.ostler/state/conversation_hydration.json)."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Signal JSON path (default: $OSTLER_STATE_DIR or ~/.ostler/state).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_seed = sub.add_parser("seed", help="Seed a channel's queued backlog.")
    p_seed.add_argument("--channel", required=True)
    p_seed.add_argument("--queued", required=True)

    p_bump = sub.add_parser("bump", help="Add to a channel's done counter.")
    p_bump.add_argument("--channel", required=True)
    p_bump.add_argument("--done", required=True)

    args = parser.parse_args(argv)

    channel = args.channel.strip().lower()
    if channel not in KNOWN_CHANNELS:
        print(
            f"conversation_hydration: unknown channel {args.channel!r} "
            f"(known: {', '.join(KNOWN_CHANNELS)})",
            file=sys.stderr,
        )
        return 2

    if args.cmd == "seed":
        raw = args.queued
    else:
        raw = args.done
    try:
        value = int(raw)
    except (TypeError, ValueError):
        print(
            f"conversation_hydration: count must be an integer, got {raw!r}",
            file=sys.stderr,
        )
        return 2

    path = args.output or default_output_path()
    existing = _load_existing(path)
    now = int(time.time())
    if args.cmd == "seed":
        payload = build_seed(existing, channel, value, now)
    else:
        payload = build_bump(existing, channel, value, now)

    try:
        atomic_write(path, payload)
    except OSError as exc:
        print(f"conversation_hydration: cannot write {path}: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
