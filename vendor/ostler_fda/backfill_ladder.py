#!/usr/bin/env python3
"""Widen a source's backfill window a rung at a time, across runs.

WHY (2026-08-08, Andy's call)
============================
iMessage first ingest used a 5-year window. On a real box that is 28,405
conversations, and every one is dispatched to CM048 which makes ten chained
Ollama calls -- ~1.2 minutes each. Twenty-four days of continuous local
inference, while the installer says the customer can walk away.

Shrinking the window to 45 days fixes onboarding and loses the history. Andy's
answer is neither: *"45 days to start with. But need to pull the longer tail
over the longer settle in period."*

So the window is not a constant, it is a LADDER. Run one takes 45 days. Each
later run takes the next rung, up to the full five years. Onboarding stays an
evening; the tail arrives while the box settles in.

    run 1:   45d     run 2:   90d     run 3:  180d
    run 4:  365d     run 5:  730d     run 6+: 1825d  (terminal)

WHY A STATE FILE AND NOT A COUNTER IN THE CALLER
================================================
The extractor is invoked from several places -- install.sh, the launchd tick,
`ostler-assistant run-source`, a human running it by hand. A counter held by
any one caller is wrong for all the others. The horizon belongs to the DATA,
so it lives next to the data and every caller converges on it.

THE OVERRIDE STILL WINS, AND DISABLES THE LADDER
================================================
An operator who sets OSTLER_IMESSAGE_BACKFILL_DAYS=1825 has asked for five
years and accepted the runtime. Honouring that and then quietly overriding it
with a 45-day rung would be worse than having no ladder. An explicit value
pins the window and the ladder does not run.

FAIL-SAFE, NOT FAIL-WIDE
========================
Every failure mode here (missing file, unreadable JSON, garbage value, a
horizon someone hand-edited to 99999) resolves to a rung ON the ladder. It can
never widen beyond the terminal rung, because widening unexpectedly is the
failure that costs a customer their afternoon.
"""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

# The rungs, in days. Terminal rung is the historical 5-year window, so the
# ladder converges on exactly the behaviour we had before -- just later.
# 36500 days is a hundred years: the terminal rung means EVERYTHING, not
# "five years". Andy, 2026-08-16: the backlog should eventually be ALL of
# iMessage. 1825 truncates anyone who has been messaging for longer, and
# next_rung() scans ascending and returns rungs[-1] as terminal, so the
# sentinel has to be the LARGEST value rather than a falsy 0.
# extract_conversations() computes `now - since_days*86400` and keeps
# everything after it, so a hundred-year window filters nothing.
DEFAULT_LADDER: List[int] = [45, 90, 180, 365, 730, 1825, 36500]

# How long a rung must be held before the ladder widens again.
#
# WHY THIS EXISTS. The ladder advances once per CALL, and extract_all is driven
# by com.ostler.export-scan with StartInterval=14400 -- every four hours,
# MEASURED on the box. Simply un-pinning the window would therefore walk
# 45 -> 36500 in under a day, and the comment in install.sh gives the cost of
# arriving at the top: ~28,405 conversations at ~1.20 min of chained local
# inference each. That is the runtime the 45-day default was protecting
# against, so turning the ladder on WITHOUT a pace would have been worse than
# leaving it pinned.
#
# One rung per day makes the progression 45 -> 90 -> 180 -> 365 -> 730 -> 1825
# -> all over about six days, which is what "the tail arrives across the
# settle-in period" already promised in this file's own docstring.
DEFAULT_DWELL_SECONDS: int = 86400

def _state_dir() -> Path:
    """Where the horizon lives -- resolved on EVERY call, never at import.

    Horizon state sits beside the other pipeline state, not in the output dir:
    output dirs get wiped by a re-extract, and losing the horizon would
    silently restart the ladder at rung 1 and redo work forever.

    Resolved lazily on purpose. A module-level constant captures the
    environment as it was at IMPORT, so anything that sets OSTLER_STATE_DIR
    afterwards -- a test, a wrapper, a launchd job that exports it late -- is
    silently ignored while appearing to work. Caught by this module's own
    tests, which set the var after import and got the real ~/.ostler back.
    """
    return Path(os.environ.get("OSTLER_STATE_DIR", str(Path.home() / ".ostler" / "state")))


def _state_path(source: str) -> Path:
    return _state_dir() / f"backfill_horizon_{source}.json"


def _read_days(source: str) -> Optional[int]:
    p = _state_path(source)
    try:
        raw = json.loads(p.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        # Corrupt state is not a reason to jump to five years.
        logger.warning("[backfill-ladder] unreadable horizon for %s (%s); restarting ladder", source, exc)
        return None
    days = raw.get("days") if isinstance(raw, dict) else None
    return days if isinstance(days, int) else None


def _write_days(source: str, days: int) -> None:
    p = _state_path(source)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        # Atomic: a half-written horizon read by the next tick is a horizon
        # nobody can trust.
        tmp = p.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(
            {"source": source, "days": days, "advanced_at": int(time.time())},
            indent=2))
        tmp.replace(p)
    except OSError as exc:
        # Not fatal. Worst case the next run repeats this rung, which costs
        # time and loses nothing.
        logger.warning("[backfill-ladder] could not persist horizon for %s: %s", source, exc)


def next_rung(current: Optional[int], ladder: Optional[List[int]] = None) -> int:
    """The rung to use now, given the rung used last time.

    `None` (first ever run) -> the first rung. Anything at or past the terminal
    rung stays there. A value BETWEEN rungs advances to the next rung above it,
    so a hand-edited or historical horizon still converges onto the ladder
    rather than being treated as unknown.
    """
    rungs = ladder or DEFAULT_LADDER
    if current is None:
        return rungs[0]
    for rung in rungs:
        if rung > current:
            return rung
    return rungs[-1]


def _dwell_seconds() -> int:
    """Seconds a rung is held before the ladder widens. Operator-overridable
    so a support case can be told to widen faster without a new build."""
    raw = os.environ.get("OSTLER_BACKFILL_DWELL_SECONDS", "").strip()
    if raw:
        try:
            return max(0, int(raw))
        except ValueError:
            logger.warning("[backfill-ladder] OSTLER_BACKFILL_DWELL_SECONDS=%r is not an integer", raw)
    return DEFAULT_DWELL_SECONDS


def _seconds_since_advance(source: str) -> Optional[int]:
    """Seconds since this source last widened, or None if never recorded."""
    p = _state_path(source)
    try:
        raw = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    ts = raw.get("advanced_at")
    if not isinstance(ts, int):
        return None
    return max(0, int(time.time()) - ts)


def resolve_backfill_days(
    source: str,
    env_var: str,
    ladder: Optional[List[int]] = None,
    advance: bool = True,
) -> int:
    """Days of history to extract for `source` on THIS run.

    An explicit env value pins the window and disables the ladder. Otherwise
    advance one rung and persist, so the tail arrives across the settle-in
    period instead of all at once during onboarding.
    """
    rungs = ladder or DEFAULT_LADDER

    explicit = os.environ.get(env_var, "").strip()
    if explicit:
        try:
            pinned = int(explicit)
            logger.info("[backfill-ladder] %s pinned to %sd by %s; ladder disabled",
                        source, pinned, env_var)
            return pinned
        except ValueError:
            logger.warning("[backfill-ladder] %s=%r is not an integer; using the ladder",
                           env_var, explicit)

    current = _read_days(source)
    chosen = next_rung(current, rungs)

    # DWELL. Hold a rung for DEFAULT_DWELL_SECONDS before widening again. The
    # extractor is driven every four hours, so without this the ladder reaches
    # the terminal rung in under a day and dispatches the whole backlog at
    # once -- the exact runtime the first rung exists to avoid.
    #
    # A horizon written before this field existed has no advanced_at, which
    # reads as 0 and therefore advances immediately. That is the right
    # behaviour for an upgraded box: it is already overdue.
    if current is not None and chosen != current:
        held = _seconds_since_advance(source)
        if held is not None and held < _dwell_seconds():
            logger.info(
                "[backfill-ladder] %s holding %sd for another %ss before widening",
                source, current, int(_dwell_seconds() - held))
            return current

    if advance and chosen != current:
        _write_days(source, chosen)
    if current is None:
        logger.info("[backfill-ladder] %s first run: %sd (ladder %s)", source, chosen, rungs)
    elif chosen == current:
        logger.info("[backfill-ladder] %s at terminal rung %sd; full history reached", source, chosen)
    else:
        logger.info("[backfill-ladder] %s widening %sd -> %sd", source, current, chosen)
    return chosen
