"""Doctor never opens chat.db; its iMessage FDA cards follow the signed side.

CM051 #30, studio29 follow-on. com.ostler.doctor is launched by launchd as a
bare venv python (install.sh, ProgramArguments[0] ${DOCTOR_DIR}/.venv/bin/python3).
vendor/doctor/agent/diagnostic_rules.py used `sqlite3.connect` on
~/Library/Messages/chat.db as its "is Full Disk Access granted" probe, reached
from check_imessage_fda and check_imessage_capture_stalled. TCC attributed
that open to python3.11: a second "python3.11" FDA request, never granted in a
way a customer would recognise, so the card that probe was meant to dismiss
could never clear.

Fix: both rules read what the SIGNED assistant's ticks already record (the
reply-debt snapshot status written by run-source imessage, and
imports/fda/extraction_summary.json written by run-source fda-rerun). The most
recent record wins.

Instrument: a CPython audit hook in a child process (every `open`,
`sqlite3.connect`, `os.listdir`, `os.scandir`), with a positive control that
it fires on a deliberate chat.db open. Synthetic data only.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import textwrap
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
AGENT = ROOT / "vendor" / "doctor" / "agent"

PROTECTED = (
    "/Library/Messages/", "/Library/Mail/", "Envelope Index", "/Library/Calendars/",
    "Calendar.sqlitedb", "NoteStore.sqlite", "group.com.apple.notes",
    "/Library/Application Support/AddressBook", "Photos.sqlite", "Photos Library",
    "/Library/Safari/", "/Library/Reminders/",
)

CRASH_LOG = ("Traceback (most recent call last):\n"
             "sqlite3.OperationalError: unable to open database file\n")

# Child: audit hook first, then load the real rules module (httpx stubbed, as
# tests/test_imessage_fda_probe.sh does) and run both rules.
_CHILD = textwrap.dedent(
    r"""
    import json, sys, types
    PROTECTED = tuple(json.loads(sys.argv[2]))
    seen = []
    def hook(event, args):
        if event in ("open", "sqlite3.connect", "os.listdir", "os.scandir"):
            t = args[0] if args else None
            if isinstance(t, bytes):
                t = t.decode("utf-8", "replace")
            t = str(t)
            if any(p in t for p in PROTECTED):
                seen.append([event, t])
    sys.addaudithook(hook)
    if sys.argv[3] == "control":
        import sqlite3
        sqlite3.connect(sys.argv[4]).close()
        print(json.dumps({"opened": seen}))
        raise SystemExit(0)
    httpx = types.ModuleType("httpx")
    class _Err(Exception): pass
    class _C:
        def __init__(self, *a, **k): pass
        def get(self, url): raise _Err("stub")
    httpx.Client = _C
    httpx.RequestError = _Err
    sys.modules["httpx"] = httpx
    sys.path.insert(0, sys.argv[1])
    import diagnostic_rules as dr
    class Signals:
        imessage_chat_db_fda_needed = True
    class Snap:
        pipeline_signals = Signals()
    fda = dr.check_imessage_fda(Snap())
    stalled = dr.check_imessage_capture_stalled(Snap())
    print(json.dumps({"fda": [f["title"] for f in fda],
                      "stalled": [f["title"] for f in stalled],
                      "opened": seen}))
    """
)

_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def make_chat_db(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT)")
    conn.execute("INSERT INTO message (text) VALUES ('hello')")
    conn.commit()
    conn.close()


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    h = tmp_path / "home"
    # A READABLE chat.db is the tempting case: main's probe opens it and
    # dismisses the card on the strength of the Doctor's own read.
    make_chat_db(h / "Library" / "Messages" / "chat.db")
    logs = h / ".ostler" / "logs"
    logs.mkdir(parents=True)
    (logs / "imessage-bundle.err").write_text(CRASH_LOG, encoding="utf-8")
    return h


def write_snapshot(home: Path, status: str, when: datetime) -> None:
    p = home / ".ostler" / "state" / "reply_debt" / "imessage_threads.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"schema": 1, "status": status,
                             "generated_at": when.isoformat(), "threads": []}))


def write_summary(home: Path, status: str, when: datetime) -> None:
    p = home / ".ostler" / "imports" / "fda" / "extraction_summary.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"extracted_at": when.isoformat(),
                             "sources": {"imessage": {"status": status}}}))


def run_rules(home: Path, mode: str = "rules", extra=None) -> dict:
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", ""),
           "PYTHONDONTWRITEBYTECODE": "1"}
    proc = subprocess.run(
        [sys.executable, "-c", _CHILD, str(AGENT), json.dumps(PROTECTED), mode,
         *(extra or [])],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stderr[-3000:]
    return json.loads(proc.stdout.strip().splitlines()[-1])


NOW = datetime.now(timezone.utc).replace(microsecond=0)


def test_control_the_audit_hook_sees_a_chat_db_open(home):
    db = home / "Library" / "Messages" / "chat.db"
    out = run_rules(home, mode="control", extra=[str(db)])
    assert any("/Library/Messages/chat.db" in t for _, t in out["opened"]), out


def test_doctor_never_opens_a_protected_path(home):
    out = run_rules(home)
    assert out["opened"] == [], f"Doctor opened protected paths: {out['opened']}"


def test_denied_read_shows_both_cards(home):
    """The assistant's own tick could not read chat.db."""
    write_snapshot(home, "unreadable", NOW)
    out = run_rules(home)
    assert out["opened"] == [], out["opened"]
    assert out["fda"] and out["stalled"], out


def test_extraction_summary_no_fda_shows_the_cards(home):
    write_summary(home, "no_fda", NOW)
    out = run_rules(home)
    assert out["fda"] and out["stalled"], out


def test_granted_read_clears_both_cards(home):
    """The signed side read chat.db: the cards dismiss, with no Doctor open."""
    write_snapshot(home, "ok", NOW)
    out = run_rules(home)
    assert out["opened"] == [], out["opened"]
    assert out["fda"] == [] and out["stalled"] == [], out


def test_extraction_summary_ok_clears_the_cards(home):
    write_summary(home, "ok", NOW)
    out = run_rules(home)
    assert out["fda"] == [] and out["stalled"] == [], out


def test_most_recent_record_wins(home):
    # Granted earlier, revoked since: the card comes back.
    write_summary(home, "ok", NOW - timedelta(hours=3))
    write_snapshot(home, "unreadable", NOW)
    assert run_rules(home)["fda"], "a later denial must bring the card back"
    # Denied earlier, granted since: the card clears.
    write_summary(home, "no_fda", NOW - timedelta(hours=3))
    write_snapshot(home, "ok", NOW)
    assert run_rules(home)["fda"] == [], "a later grant must clear the card"


def test_no_evidence_keeps_the_card(home):
    """Nothing recorded yet: keep the card rather than wrongly dismiss it."""
    out = run_rules(home)
    assert out["fda"] and out["stalled"], out
