"""Drift test: the vendored writer window rule against CM048 main's _in_push_window.

Same-shape sweep 2026-11-14, Archie's ruling (3): the hand-port of CM048 #120
is accepted, but only with a drift check on the one function that changed.
MAIN_TABLE below is the output of CM048 main's _in_push_window (commit
6889740, reminders: push only the last 7 days, #120) over the rows listed, run
with window_days=7 and today=2026-11-14. Re-record it if main changes.

The vendored rule under test: _has_future_deadline + _is_stale (limit_days=6,
which is window_days=7 minus one). Both sides see the same instants: the
vendored side gets timezone-aware local noon timestamps, so the day count does
not depend on the machine's zone.

Not compared: CM048's ended_at precedence (the vendored _source_datetime reads
started_at, then date). Recorded as a divergence in cm048_pipeline.UNRECORDED.md.
Synthetic data only. Run bare: python3 tests/test_cm048_window_drift.py
"""
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "cm048_pipeline"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

from src import reminders_push as rp  # noqa: E402

TODAY_DAYS = (2026, 11, 14)
MAIN_TABLE = [
    (None, 'undated', False),
    (None, 'started_0', True),
    (None, 'started_3', True),
    (None, 'started_6', True),
    (None, 'started_7', False),
    (None, 'started_30', False),
    (None, 'date_only_7', False),
    (-3, 'undated', False),
    (-3, 'started_0', True),
    (-3, 'started_3', True),
    (-3, 'started_6', True),
    (-3, 'started_7', False),
    (-3, 'started_30', False),
    (-3, 'date_only_7', False),
    (0, 'undated', True),
    (0, 'started_0', True),
    (0, 'started_3', True),
    (0, 'started_6', True),
    (0, 'started_7', True),
    (0, 'started_30', True),
    (0, 'date_only_7', True),
    (5, 'undated', True),
    (5, 'started_0', True),
    (5, 'started_3', True),
    (5, 'started_6', True),
    (5, 'started_7', True),
    (5, 'started_30', True),
    (5, 'date_only_7', True),
]
WINDOW_DAYS = 7
LIMIT_DAYS = WINDOW_DAYS - 1
BUNDLE_AGE = {"undated": None, "started_0": 0, "started_3": 3, "started_6": 6,
              "started_7": 7, "started_30": 30, "date_only_7": 7}
FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


now = datetime(*TODAY_DAYS, 12, 0).astimezone()          # local noon, aware
today_d = now.date()


def vendored_pushed(deadline_offset, bundle_name):
    dl = (today_d + timedelta(days=deadline_offset)).isoformat() if deadline_offset is not None else None
    todo = SimpleNamespace(deadline=dl)
    age = BUNDLE_AGE[bundle_name]
    stamp = None
    if age is not None:
        stamp = (now - timedelta(days=age)).isoformat()
    bundle = SimpleNamespace(started_at=stamp or "", date=stamp or "")
    return not rp._is_stale(bundle, now=now, limit_days=LIMIT_DAYS, todo=todo)


mismatch = []
for dl, name, expected in MAIN_TABLE:
    got = vendored_pushed(dl, name)
    if got != expected:
        mismatch.append((dl, name, expected, got))
check(not mismatch, f"1 all {len(MAIN_TABLE)} rows agree with CM048 main "
                    f"({len(mismatch)} mismatch: {mismatch[:3]})")
check(any(p for _, _, p in MAIN_TABLE) and not all(p for _, _, p in MAIN_TABLE),
      "2 the table is not degenerate (both pushed and not-pushed rows exist)")
check(vendored_pushed(None, "undated") is False, "3 undated, no deadline: not pushed")
check(vendored_pushed(5, "undated") is True, "4 undated with a future deadline: pushed")

if FAILS:
    print(f"\n{len(FAILS)} FAILED")
    sys.exit(1)
print("\nAll window-rule drift checks passed.")
