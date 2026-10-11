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
  forget --token T --text TEXT           delete the reminder by id, verify, then the map row
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


# The Reminders (EventKit) grant the DAEMON needs, read from the per-user
# TCC.db. Three states that mean three different things, and walk #11 showed
# why they must not be collapsed:
#   absent  -- no kTCCServiceReminders row for the assistant: the permission
#              prompt has never been answered (undecided). Only a human at
#              the console can answer it, so the claim arm is CANNOT-RUN.
#   denied  -- a row with auth_value 0: someone said no. A real FAIL.
#   allowed -- auth_value 2 (or 3, limited): granted.
# Plus "unreadable" (TCC.db could not be opened from this session), which is
# neither of the above and is reported as such, never as absent.
TCC_CLIENTS = ("ai.ostler.assistant",)
_TCC_USER_DB = os.path.expanduser("~/Library/Application Support/com.apple.TCC/TCC.db")


def tcc_reminders_state(db_path=None, clients=TCC_CLIENTS):
    db_path = db_path or os.environ.get("OSTLER_TCC_DB") or _TCC_USER_DB
    q = "SELECT auth_value FROM access WHERE service='kTCCServiceReminders' AND client IN ({})".format(
        ",".join("?" * len(clients)))
    try:
        conn = sqlite3.connect("file:{}?mode=ro".format(db_path), uri=True, timeout=5.0)
        rows = conn.execute(q, tuple(clients)).fetchall()
        conn.close()
    except sqlite3.Error as exc:
        return {"state": "unreadable", "error": str(exc)[:160]}
    if not rows:
        return {"state": "absent"}
    vals = [r[0] for r in rows]
    if any(v in (2, 3) for v in vals):
        return {"state": "allowed", "auth_value": vals}
    if any(v == 0 for v in vals):
        return {"state": "denied", "auth_value": vals}
    return {"state": "other", "auth_value": vals}


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
        facts["tcc_reminders"] = tcc_reminders_state()
        if facts["push"].get("status") == "pushed":
            facts["readback"] = _readback(text)
    print(json.dumps(facts))
    return 0


def _as_quote(v):
    return v.replace('\\', '\\\\').replace('"', '\\"')


def _osa(script, runner=None):
    """Run one AppleScript. Returns (rc, stdout, stderr); never raises."""
    runner = runner or subprocess.run
    try:
        p = runner(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except Exception as exc:
        return 1, "", "osascript could not run: {}".format(exc)


def delete_reminder(ident, runner=None):
    """Delete the reminder the daemon created, by the identifier the daemon
    recorded in reminders_map.db, then COUNT to prove it is gone.

    The old code matched `name is <the todo text>`. The daemon never titles a
    reminder with the todo text (reminders_push._format_push_title builds
    "Follow up on conversation"), so that match found nothing, and an ssh
    session without the Automation grant failed outright; both read as
    reminder_deleted=false and the reminder synced back via iCloud into the
    next walk (walk #19).

    State is one of: deleted (verified count 0), none_to_delete (the daemon
    never created one), blocked_tcc, failed. Never a bare bool.
    """
    if not ident:
        return {"state": "none_to_delete"}
    q = _as_quote(ident)
    sel = 'every reminder whose id contains "%s"' % q
    rc, out, err = _osa('tell application "Reminders" to delete (%s)' % sel, runner)
    if rc != 0:
        blocked = any(m in err.lower() for m in _TCC_MARKERS)
        return {"state": "blocked_tcc" if blocked else "failed", "error": err.strip()[:200]}
    rc, out, err = _osa('tell application "Reminders" to count (%s)' % sel, runner)
    if rc != 0:
        return {"state": "failed", "error": "delete ran but the verifying count failed: " + err.strip()[:160]}
    try:
        left = int(out.strip())
    except ValueError:
        return {"state": "failed", "error": "verifying count unreadable: " + out.strip()[:80]}
    if left > 0:
        return {"state": "failed", "error": "{} reminder(s) still present after delete".format(left)}
    return {"state": "deleted"}


def cmd_forget(argv, runner=None):
    a = dict(zip(argv[0::2], argv[1::2]))
    token = a.get("--token")
    text = a.get("--text")
    uid = _user_id() or "walk-probe"
    result = {"db_deleted": False, "reminder": {"state": "failed", "error": "not attempted"}}
    ident = None
    try:
        from src.conversation_writer import make_todo_id
        todo_id = make_todo_id(token, "user", text)
        db_path = _default_db_path()
        conn = sqlite3.connect(str(db_path), timeout=5.0)
        # Read the daemon's identifier BEFORE the row is deleted: it is the
        # only handle on the reminder.
        row = conn.execute(
            "SELECT calendar_item_identifier FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
            (uid, token, todo_id),
        ).fetchone()
        ident = row[0] if row else None
        result["calendar_item_identifier"] = ident
        # Delete the reminder first; the row is dropped only if that worked or
        # there was nothing to delete, so a retry still has its handle.
        result["reminder"] = delete_reminder(ident, runner)
        if result["reminder"]["state"] in ("deleted", "none_to_delete"):
            conn.execute(
                "DELETE FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
                (uid, token, todo_id),
            )
            conn.commit()
            result["db_deleted"] = True
        conn.close()
    except Exception as exc:
        result["db_error"] = str(exc)[:160]
        if ident is None:
            result["reminder"] = {"state": "failed", "error": "could not read the map row: " + str(exc)[:120]}
    result["expected_title"] = "Follow up on conversation"
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
