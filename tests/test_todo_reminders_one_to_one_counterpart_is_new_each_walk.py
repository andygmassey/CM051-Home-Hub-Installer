#!/usr/bin/env python3
"""todos_reach_reminders: the seeded 1:1 counterpart must be new every walk.

A previous walk's reminder for the fixed counterpart is left behind (TCC blocks
deletion over ssh) and the product's correct one-open-reminder-per-thread rule
then skips the new row as duplicate_thread, so the probe FAILed. Real product
code (vendor/cm048_pipeline), synthetic data, tmp OSTLER_DIR.
"""
import os
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
sys.path.insert(0, str(ROOT / "scripts" / "box_walk_probes" / "lib"))
os.environ["OSTLER_DIR"] = tempfile.mkdtemp()
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

import todo_reminders_box as box  # noqa: E402
from src import reminders_push  # noqa: E402
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo  # noqa: E402

reminders_push._people_store_record = lambda h: None
fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


def reason_for(db, session):
    c = sqlite3.connect(db)
    r = c.execute("SELECT status, skip_reason FROM reminders_map WHERE source_session_id=?", (session,)).fetchone()
    c.close()
    return r


# the leftover: an open reminder for the OLD fixed counterpart, as walk N-1 left it
old = box.ONE_TO_ONE_COUNTERPART
b = ConversationBundle(
    conversation_id="c-old", source_kind="channel", source_subtype="imessage",
    source_session_id="old-walk-1to1", channel="im", participants=("user", old),
    started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
    summary=ConversationSummary(overall="Synthetic.", topics=()), transcript="synthetic", privacy_level="L2")
t = Todo(id="old-t", text="SYNTHETIC WALK PROBE old leftover", owner="user", deadline=None)
reminders_push.apply_push_status_to_todos((t,), b, summary_path=Path("/tmp/x.md"), demo_mode=False, user_id="walk-probe", db_path=None)
db = str(reminders_push.default_db_path())
check("fixture: the leftover row exists and is open", (reason_for(db, "old-walk-1to1") or ("",))[0] in ("pending", "pushed"))

box._user_id = lambda: "walk-probe"
out, ids = box._write_one_to_one("ostler-walk-todo-111-1")
st = reason_for(db, "ostler-walk-todo-111-1-1to1")
check("new walk's 1:1 row exists", st is not None)
check("new walk's 1:1 row is not skipped as duplicate_thread", st is not None and st[1] != "duplicate_thread")
check("new walk's 1:1 row is pending or pushed", st is not None and st[0] in ("pending", "pushed"))
a, c2 = box.one_to_one_counterpart("w1"), box.one_to_one_counterpart("w2")
check("counterpart differs per walk and is stable within one", a != c2 and a == box.one_to_one_counterpart("w1"))
check("counterpart is letters-only, three capitalised words", all(re.fullmatch(r"[A-Z][a-z]+( [A-Z][a-z]+){2}", x) for x in (a, c2)))
check("counterpart is not the old fixed one", a != old)
print("FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
