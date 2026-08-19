"""Settling-progress writer for the "Ostler is still getting to know you" panel.

The wiki compiler (CM044) renders a per-channel settling-progress panel on the
homepage during the first few days after install. It reads per-channel shard
files from ``~/.ostler/state/settling_progress.d/`` and merges them into the
aggregate JSON that ``CM044/compiler/hydration.py::settling_progress()``
consumes. The reader is deliberately fail-soft: a missing directory, an
unreadable shard, or a partial JSON degrades silently to the calendar-based
fallback. **A half-built writer is invisible in production.**

This module is the shared writer helper. All five channel producers
(``contacts``, ``calendar``, ``messages``, ``emails``, ``notes``) call
:func:`report_settling_progress` -- one implementation, not five copies.

Design:
 * One file per channel (or per shard); the reader on the CM044 side merges
   them. No shared lock is needed because each producer owns its own file.
 * Atomic ``write + os.replace()`` so a crash mid-write never leaves the
   reader looking at partial JSON (the reader treats a parse error as "no
   progress at all" and degrades).
 * ``started_at`` is written once and preserved on subsequent updates so the
   rate-based ETA in CM044 falls as work completes rather than resetting.
 * ``updated_at`` is stamped every write so the A9 acceptance gate can detect
   a launchd penalty-box producer (fired once, then never again).

Invariants enforced here:
 * An unknown channel name is a **programming error** and raises
   ``ValueError`` loudly -- ``email`` (singular) and ``meetings`` are the
   two obvious traps and the reader would silently drop or generic-render
   them.
 * An I/O failure is an **environment problem** and is swallowed with a
   ``logger.warning``. A full disk or a locked directory must never abort
   the caller's ingest loop.

No PII is written -- counts only. See :data:`SETTLING_CHANNELS` for the
exact keys, sourced from ``CM044/compiler/hydration.py::
SETTLING_CHANNEL_ORDER`` (line 454, as of 2026-08-06).
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ── The five valid channel keys ───────────────────────────────────────────────
#
# Exact match required by CM044's `_coerce_channel`. Any other key renders
# via the fallback "Another part of your history" generic copy; `email`
# (singular) and `meetings` are the near-misses this frozenset exists to catch.
SETTLING_CHANNELS = frozenset({
    "contacts",
    "calendar",
    "messages",
    "emails",
    "notes",
})

# Default state directory. The compiler runs containerised and reaches this
# through the existing host bind-mount on ~/.ostler/state (a sibling of
# wiki_hydration.json and pipeline_signals.json). Override via `state_dir=` in
# tests -- never invent a new path in production.
def _default_state_dir() -> Path:
    """Resolve the state directory, honouring ``OSTLER_STATE_DIR``.

    Resolved per call, not at import: the A9 acceptance gate
    (scripts/a9_settling_progress.sh) reads the SAME env var to decide where
    to look. With the path baked in at import, any box that sets
    OSTLER_STATE_DIR would have A9 inspecting a directory nothing writes to
    -- reporting a failure identical to an unwired producer. Writer and gate
    must agree or the gate is measuring the wrong thing.
    """
    override = os.environ.get("OSTLER_STATE_DIR", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".ostler" / "state"

_SETTLING_SUBDIR = "settling_progress.d"


def _now_iso_utc() -> str:
    """UTC ISO8601 timestamp with `+00:00` offset (never trailing 'Z')."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _shard_filename(channel: str, shard: Optional[str]) -> str:
    """Return ``<channel>.json`` or ``<channel>.<shard>.json`` if sharded.

    ``messages`` is the one channel with two producers (iMessage + WhatsApp);
    CM044's reader sums any ``messages.*`` shards into the single ``messages``
    channel. Do not have two processes share one shard file.
    """
    if shard:
        return f"{channel}.{shard}.json"
    return f"{channel}.json"


def _read_existing_started_at(path: Path) -> Optional[str]:
    """Return the existing ``started_at`` on this shard, or ``None``.

    The rate-based ETA in CM044 is anchored on ``started_at`` -- we must not
    rewrite it on every tick, or the ETA resets forever and the progress bar
    stops falling.

    Any read error (missing file, bad JSON, wrong shape) returns ``None`` and
    the caller falls back to the freshly-supplied or newly-stamped value.
    """
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning(
            "settling-progress: could not read existing shard at %s (%s: %s)",
            path, type(exc).__name__, exc,
        )
        return None
    if not isinstance(data, dict):
        return None
    started = data.get("started_at")
    return started if isinstance(started, str) and started.strip() else None


def _read_existing_done(path: Path) -> Optional[int]:
    """Return the existing ``done`` on this shard, or ``None``.

    Used to keep ``done`` monotonic. These producers run hourly against their
    own filtered window; without this, a narrower later run walks the bar
    backwards and the customer watches their progress un-happen.

    Any read error returns ``None`` -- the caller then trusts the value it was
    given, which is the same behaviour as a first run.
    """
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning(
            "settling-progress: could not read existing shard at %s (%s: %s)",
            path, type(exc).__name__, exc,
        )
        return None
    if not isinstance(data, dict):
        return None
    try:
        return max(0, int(data.get("done")))
    except (TypeError, ValueError):
        return None


def report_settling_progress(
    channel: str,
    *,
    done: int,
    total: int,
    needs_source: bool = False,
    started_at: Optional[str] = None,
    shard: Optional[str] = None,
    state_dir: Optional[Path] = None,
) -> None:
    """Write a per-channel settling-progress shard atomically.

    Producers call this on a count change or every ~30s, whichever is sooner
    -- NOT on every processed item (thousands of tiny writes during the
    heaviest phase of install).

    Args:
        channel: One of :data:`SETTLING_CHANNELS`. Raises ``ValueError`` on
            anything else -- a typo'd key is invisible in production so it
            must be impossible to commit.
        done: Items fully processed (summarised and written). Non-negative.
        total: Backfill queue size as first measured. Must be set **once, up
            front** by the producer; do NOT recompute per tick or the bar
            moves backwards when new items arrive.
        needs_source: True when the source is not connected and the panel
            should invite the customer to add an export (e.g. Evernote).
            Getting this backwards makes a finished install look broken.
        started_at: ISO8601 timestamp of when the backfill began. Preserved
            across updates -- passed value is only used if no existing shard
            exists.
        shard: Optional shard tag, e.g. ``"imessage"`` -> ``messages.imessage.json``.
            Only ``messages`` has two producers today; other channels leave
            this ``None``.
        state_dir: Override the state directory. Default:
            ``~/.ostler/state``. Test seam; never override in production.

    Raises:
        ValueError: The channel is not in :data:`SETTLING_CHANNELS`.

    I/O errors (unwritable dir, full disk, permission denied) are logged
    and swallowed so a failing writer never aborts the caller's ingest
    loop.
    """
    if channel not in SETTLING_CHANNELS:
        raise ValueError(
            f"unknown settling-progress channel {channel!r}; "
            f"must be one of {sorted(SETTLING_CHANNELS)!r}"
        )

    # Non-negative int clamping is the reader's job, but we normalise here so
    # a producer bug (negative counter) does not confuse observers of the
    # shard file directly.
    try:
        done_int = max(0, int(done))
    except (TypeError, ValueError):
        done_int = 0
    try:
        total_int = max(0, int(total))
    except (TypeError, ValueError):
        total_int = 0

    root = Path(state_dir) if state_dir is not None else _default_state_dir()
    target_dir = root / _SETTLING_SUBDIR
    filename = _shard_filename(channel, shard)
    target_path = target_dir / filename

    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning(
            "settling-progress: could not create %s (%s: %s); dropping update "
            "for channel=%s",
            target_dir, type(exc).__name__, exc, channel,
        )
        return

    # `done` is MONOTONIC across runs.
    #
    # WHY (2026-08-08). These producers run hourly and each run measures its
    # own filtered window (since_days, min_messages), then finishes with
    # done == total. Per run that is true; as a statement about the customer's
    # history it is false, and it is what pinned the panel at 100% on a box
    # that had ingested 167 of 28,405 messages and 1,860 of 163,651 WhatsApp
    # messages. Taking the max against the previous shard means a later,
    # narrower window cannot walk the bar backwards, and a widening backfill
    # moves it forward -- which is the only behaviour that lets the panel keep
    # its promise that this takes days.
    #
    # An explicit reset (a new install, a wiped state dir) removes the shard,
    # so there is nothing to be monotonic against and the count starts clean.
    prev_done = _read_existing_done(target_path)
    if prev_done is not None and prev_done > done_int:
        done_int = prev_done

    # A denominator below the numerator renders as over 100%. Producers that
    # cannot measure the full corpus pass total == done; clamping here means
    # no call site can publish an impossible bar.
    if total_int < done_int:
        total_int = done_int

    # Preserve started_at across updates: read existing shard, keep original.
    preserved_started = _read_existing_started_at(target_path)
    if preserved_started is not None:
        effective_started = preserved_started
    elif started_at and isinstance(started_at, str) and started_at.strip():
        effective_started = started_at
    else:
        effective_started = _now_iso_utc()

    payload = {
        "key": channel,
        "done": done_int,
        "total": total_int,
        "needs_source": bool(needs_source),
        "started_at": effective_started,
        "updated_at": _now_iso_utc(),
    }
    if shard:
        # Include the shard tag in the payload so the CM044-side merger can
        # tell (e.g.) messages.imessage from messages.whatsapp without
        # re-parsing the filename. Not required by the current reader; safe
        # extra field.
        payload["shard"] = shard

    # Atomic write: NamedTemporaryFile in the SAME dir (os.replace only
    # atomic across identical filesystems), fsync, then os.replace().
    tmp_fd = None
    tmp_path: Optional[str] = None
    try:
        # delete=False so we own the rename; delete on any error branch.
        tmp = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(target_dir),
            prefix=f".{filename}.",
            suffix=".tmp",
            delete=False,
        )
        tmp_path = tmp.name
        try:
            json.dump(payload, tmp, ensure_ascii=False, sort_keys=True)
            tmp.write("\n")
            tmp.flush()
            try:
                os.fsync(tmp.fileno())
            except OSError:
                # fsync unsupported (e.g. some tmpfs) -- proceed without it,
                # os.replace is still atomic at the VFS layer.
                pass
        finally:
            tmp.close()
        os.replace(tmp_path, target_path)
        tmp_path = None  # ownership transferred
    except OSError as exc:
        logger.warning(
            "settling-progress: atomic write failed for channel=%s at %s "
            "(%s: %s); shard unchanged",
            channel, target_path, type(exc).__name__, exc,
        )
    finally:
        # If the replace failed, clean up the orphan tempfile so a full disk
        # does not accumulate detritus across retries.
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


# ── Channel ownership registry ───────────────────────────────────────────────
#
# WHY THIS EXISTS
#
# This module first shipped with a complete writer, 17 tests and an
# acceptance gate -- and ZERO production callers. Everything was green. The
# customer-facing panel stayed exactly as dark as before, because a helper
# nobody calls is indistinguishable from one that was never written, and
# nothing in the repo noticed.
#
# So every channel names its producer HERE, and
# tests/test_settling_channel_coverage.py mechanises two rules:
#
#   1. every channel in SETTLING_CHANNELS is declared -- none can be silently
#      unowned;
#   2. every producer whose source we can reach really does call this module
#      for that channel, checked by reading the producer's SOURCE. Delete a
#      call site and the build goes red.
#
# ONE PRODUCER PER SHARD FILE. Two processes writing one shard overwrite each
# other and the panel jumps backwards when the second opens at zero. That is
# why `calendar` reports from the extractor (ostler_fda/calendar.py) and NOT
# from pwg_ingest -- every other channel reports at extraction, and mixing
# layers within a channel is the collision.
#
# Producers in other repos cannot be introspected. They are declared with no
# module/path and proven on a real box by scripts/a9_settling_progress.sh. A
# declaration is a claim; A9 is the evidence.

class ProducerRef:
    """Where a channel's numbers come from.

    Exactly one of ``module`` (importable) or ``path`` (repo-relative file)
    makes the producer checkable; ``external`` marks one in another repo.
    """

    __slots__ = ("name", "module", "path", "external", "shard", "note")

    def __init__(self, name: str, *, module: Optional[str] = None,
                 path: Optional[str] = None, external: bool = False,
                 shard: Optional[str] = None, note: str = "") -> None:
        self.name = name
        self.module = module
        self.path = path
        self.external = external
        self.shard = shard
        self.note = note

    @property
    def checkable(self) -> bool:
        return not self.external and (self.module is not None or self.path is not None)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<ProducerRef {self.name}{' (external)' if self.external else ''}>"


CHANNEL_PRODUCERS = {
    "messages": (
        ProducerRef("iMessage extract", module="ostler_fda.imessage",
                    shard="imessage", note="extract_conversations backfill loop"),
        ProducerRef("WhatsApp extract", module="ostler_fda.whatsapp_history",
                    shard="whatsapp", note="extract_conversations backfill loop"),
    ),
    "calendar": (
        ProducerRef("Calendar extract", module="ostler_fda.calendar",
                    note="extract_events row loop; single producer, no shard tag"),
    ),
    "notes": (
        ProducerRef("Evernote import", path="doctor/agent/import_evernote.py",
                    note="same repo, separate venv -- checked by reading the "
                         "file rather than importing it (doctor/agent is not "
                         "an importable package from here)"),
    ),
    "contacts": (
        ProducerRef("CM041 contact_syncer", external=True,
                    note="another repo. ostler_fda is NOT on the pipeline venv "
                         "path -- install.sh copies contact_syncer, "
                         "meeting_syncer and identity_resolver into "
                         "PIPELINE_DIR but never ostler_fda -- so it cannot "
                         "import this helper. Writes via the filesystem "
                         "contract from install.sh's hydrate_graph phase."),
    ),
    "emails": (
        ProducerRef("CM021 pwg-email-ingest", external=True,
                    note="another repo; writes via the filesystem contract "
                         "from install.sh's hydrate_email phase"),
    ),
}
