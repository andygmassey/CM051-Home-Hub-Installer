#!/usr/bin/env python3
"""v1.0.108 Rule 0.8: the proactive Apple Reminders push pauses when Ostler
Pro is inactive, and keeps working when it is active.

Both directions, because a gate that always pauses is as wrong as one that
never fires. Real product code (vendor/cm048_pipeline + the shipped
subscription_gate.py), synthetic data, tmp OSTLER_DIR. No real receipts.
"""
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))

HUB = Path(tempfile.mkdtemp())
os.environ["OSTLER_DIR"] = str(HUB)
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")
GATE_DIR = HUB / "services" / "ical-server"
GATE_DIR.mkdir(parents=True, exist_ok=True)
GATE_SRC = ROOT / "vendor" / "cm041" / "assistant_api" / "subscription_gate.py"
shutil.copy(GATE_SRC, GATE_DIR / "subscription_gate.py")
STATE = HUB / "state" / "subscription_state.json"
STATE.parent.mkdir(parents=True, exist_ok=True)
os.environ["OSTLER_SUBSCRIPTION_STATE"] = str(STATE)

# The staged gate's writer -- used to produce state the SAME way install.sh
# does, never by hand-writing a status field.
sys.path.insert(0, str(GATE_DIR))
import subscription_gate as gate  # noqa: E402

from src import reminders_push  # noqa: E402
from src.conversation_writer import (  # noqa: E402
    ConversationBundle,
    ConversationSummary,
    Todo,
)

reminders_push._people_store_record = lambda h: None
fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


def _iso(dt):
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _set_active():
    STATE.unlink(missing_ok=True)
    gate.activate_first_month_free(_iso(datetime.now(timezone.utc)))


def _set_trial_ended():
    STATE.unlink(missing_ok=True)
    gate.activate_first_month_free(_iso(datetime.now(timezone.utc) - timedelta(days=31)))


def _bundle():
    return ConversationBundle(
        conversation_id="c1", source_kind="channel", source_subtype="imessage",
        source_session_id="im;-;+15551234567", channel="im",
        participants=("user", "Alex Example"),
        started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", privacy_level="L0")


def _todo():
    return Todo(id="t1", text="SYNTHETIC send Alex the report", owner="user", deadline=None)


# ── Direction 1: ACTIVE -> the helper allows + the push runs (DB created) ──
_set_active()
check("helper: active subscription is NOT paused", reminders_push._subscription_paused() is False)
db = HUB / "active_map.db"
reminders_push.apply_push_status_to_todos(
    (_todo(),), _bundle(), summary_path=Path("/tmp/s.md"), demo_mode=False,
    user_id="user", db_path=db)
check("active: the push ran (mapping DB was created)", db.exists())
if db.exists():
    n = sqlite3.connect(db).execute("SELECT COUNT(*) FROM reminders_map").fetchone()[0]
    check("active: at least one row was written", n >= 1)

# ── Direction 2: TRIAL ENDED -> helper pauses + NO new rows, todos unchanged ─
_set_trial_ended()
check("helper: lapsed subscription IS paused", reminders_push._subscription_paused() is True)
db2 = HUB / "paused_map.db"
todos_in = (_todo(),)
out = reminders_push.apply_push_status_to_todos(
    todos_in, _bundle(), summary_path=Path("/tmp/s.md"), demo_mode=False,
    user_id="user", db_path=db2)
check("paused: todos returned unchanged", out is todos_in)
check("paused: NO mapping DB was opened (no new pending rows)", not db2.exists())

# ── Direction 3: gate module MISSING -> fail OPEN (never pause on can't-ask) ─
hidden = GATE_DIR / "subscription_gate.py"
moved = GATE_DIR / "subscription_gate.py.hidden"
hidden.rename(moved)
try:
    check("missing module: fail OPEN (not paused)", reminders_push._subscription_paused() is False)
finally:
    moved.rename(hidden)

print("FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
