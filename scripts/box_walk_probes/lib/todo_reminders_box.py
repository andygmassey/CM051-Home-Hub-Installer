#!/usr/bin/env python3
"""Box half of todos_reach_reminders (v1.0.107, FLOW_CENSUS gap #6).

Runs under the SAME venv pwg-convo ships under, so `import src...` resolves
to the real installed CM048 package. Writes one synthetic commitment through
the shipped gate (reminders_push.apply_push_status_to_todos -- the exact
function the real pipeline calls), waits for the installed daemon to claim
the pending row, and tries to read the result back from Reminders.app
itself. Prints ONE JSON line of facts; never prints the reminder's own text
or notes (synthetic, but the pattern this suite uses throughout is to never
print personal-content-shaped strings from a box).

Subcommands:
  run --token T --text TEXT --wait-s N   write + poll + read back
  forget --token T --text TEXT           best-effort cleanup, prints before/after
"""
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path


def _user_id():
    try:
        for line in open(os.path.expanduser("~/.ostler/config/.env")):
            if line.startswith("USER_ID="):
                return line.split("=", 1)[1].strip().strip('"')
    except IOError:
        pass
    return ""


def _write(token, text):
    out = {"attempted": False}
    try:
        from src.conversation_writer import ConversationBundle, ConversationSummary, Todo, make_todo_id
        from src.reminders_push import apply_push_status_to_todos
    except ImportError as exc:
        out["error"] = "the shipped writer is not importable under this interpreter ({})".format(exc)
        return out, None

    uid = _user_id() or "walk-probe"
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    todo_id = make_todo_id(token, "user", text)
    todo = Todo(id=todo_id, text=text, owner="user", deadline=None, source_anchor="L1", status="extracted")
    bundle = ConversationBundle(
        conversation_id=token,
        source_kind="spoken",
        source_subtype="voice_note",
        source_session_id=token,
        channel="spoken",
        participants=("user",),
        started_at=now,
        ended_at=now,
        summary=ConversationSummary(overall="Synthetic walk-probe commitment, safe to delete.", topics=()),
        transcript="**You**: " + text,
        todos=(todo,),
        privacy_level="L1",
    )
    try:
        apply_push_status_to_todos(
            (todo,), bundle,
            summary_path=Path("/tmp/ostler-walk-probe-synthetic-summary.md"),
            demo_mode=False, user_id=uid, db_path=None,
        )
        out["attempted"] = True
        out["todo_id"] = todo_id
    except Exception as exc:
        out["error"] = "apply_push_status_to_todos raised: {}".format(exc)[:200]
        return out, None
    return out, (uid, todo_id)


def _default_db_path():
    try:
        from src.reminders_push import default_db_path
        return default_db_path()
    except Exception:
        return Path(os.path.expanduser("~/.ostler/reminders_map.db"))


def _poll(uid, token, todo_id, wait_s):
    db_path = _default_db_path()
    deadline = time.time() + wait_s
    row = None
    while time.time() < deadline:
        try:
            conn = sqlite3.connect(str(db_path), timeout=5.0)
            cur = conn.execute(
                "SELECT status, calendar_item_identifier, skip_reason, failure_reason "
                "FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
                (uid, token, todo_id),
            )
            row = cur.fetchone()
            conn.close()
        except sqlite3.Error:
            row = None
        if row and row[0] != "pending":
            break
        time.sleep(3)
    waited = wait_s - max(0, int(deadline - time.time()))
    if not row:
        return {"status": None, "waited_s": waited}
    return {"status": row[0], "calendar_item_identifier": row[1], "skip_reason": row[2], "failure_reason": row[3], "waited_s": waited}


_TCC_MARKERS = ("-1743", "not authorized to send apple events", "not allowed to send apple events")


def _readback(text):
    script = 'tell application "Reminders" to count (every reminder whose name is "%s")' % text.replace('\\', '\\\\').replace('"', '\\"')
    try:
        proc = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
    except Exception as exc:
        return {"attempted": False, "error": str(exc)[:160]}
    if proc.returncode != 0:
        stderr_l = (proc.stderr or "").lower()
        blocked = any(m in stderr_l for m in _TCC_MARKERS)
        return {"attempted": True, "blocked_tcc": blocked, "error": None if blocked else (proc.stderr or "").strip()[:200]}
    try:
        n = int((proc.stdout or "").strip())
        return {"attempted": True, "blocked_tcc": False, "found": n > 0}
    except ValueError:
        return {"attempted": True, "blocked_tcc": False, "found": None, "error": (proc.stdout or "").strip()[:200]}


def cmd_run(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    token = a.get("--token")
    text = a.get("--text")
    wait_s = int(a.get("--wait-s", "90"))
    facts = {}
    write, ids = _write(token, text)
    facts["write"] = write
    if ids:
        uid, todo_id = ids
        facts["push"] = _poll(uid, token, todo_id, wait_s)
        if facts["push"].get("status") == "pushed":
            facts["readback"] = _readback(text)
    print(json.dumps(facts))
    return 0


def cmd_forget(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    token = a.get("--token")
    text = a.get("--text")
    uid = _user_id() or "walk-probe"
    result = {"db_deleted": False, "reminder_deleted": None}
    try:
        from src.conversation_writer import make_todo_id
        todo_id = make_todo_id(token, "user", text)
        db_path = _default_db_path()
        conn = sqlite3.connect(str(db_path), timeout=5.0)
        before = conn.execute(
            "SELECT COUNT(*) FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
            (uid, token, todo_id),
        ).fetchone()[0]
        conn.execute(
            "DELETE FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
            (uid, token, todo_id),
        )
        conn.commit()
        after = conn.execute(
            "SELECT COUNT(*) FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
            (uid, token, todo_id),
        ).fetchone()[0]
        conn.close()
        result["db_deleted"] = True
        result["db_before"] = before
        result["db_after"] = after
    except Exception as exc:
        result["db_error"] = str(exc)[:160]
    try:
        script = 'tell application "Reminders" to delete (every reminder whose name is "%s")' % text.replace('\\', '\\\\').replace('"', '\\"')
        proc = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
        result["reminder_deleted"] = (proc.returncode == 0)
    except Exception:
        result["reminder_deleted"] = False
    print(json.dumps(result))
    return 0


def main(argv):
    if argv[:1] == ["run"]:
        return cmd_run(argv[1:])
    if argv[:1] == ["forget"]:
        return cmd_forget(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
