"""Reply debt never opens chat.db from ical-server, and never fakes an all-clear.

CM051 #30, studio29 (~/walkdriver/evidence/studio29_exportscan.md, "python3.11
FDA caller"), PROVEN by reproduction on a walked box:

1. com.ostler.ical-server is launched by launchd as a bare python3.11. Its
   /api/v1/reply-debt endpoint called CM048's reply_debt_adapters, which
   opened ~/Library/Messages/chat.db in that process. TCC attributed the read
   to python3.11 and the customer was shown a Full Disk Access entry for an
   unsigned-looking "python3.11", denied by default.
2. While chat.db could not be opened, the endpoint answered HTTP 200
   "No replies owed - you're all caught up." with degraded:false.

The fix moves the chat.db read into the iMessage feed, which already runs
under the signed assistant (`ostler-assistant run-source imessage`) and now
writes a reply-debt snapshot into the engine room. The endpoint reads only
that snapshot, and a missing / stale / unreadable source is degraded:true.

THE INSTRUMENT is a CPython audit hook (sys.addaudithook) in a child process:
it sees every `open` and `sqlite3.connect` event however the code reaches
them (builtins.open, io.open, os.open, pathlib, sqlite3). The positive control
proves it fires on a deliberate open of the synthetic chat.db, so a quiet
hook cannot pass the suite.

THREE STATES (review of the first cut): a Mac where install.sh never set the
iMessage feed up (third-party consent not accepted, or no chat.db, so no feed
LaunchAgent) never gets a snapshot, and must say "Messages isn't connected",
never "couldn't check, will check again shortly". The decision is read from
what the install wrote (the consent registry and the feed's LaunchAgent).

Synthetic data only: every handle is an example.invalid address or a
reserved 555 number, every name a cast placeholder.
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
SERVER = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
CM048 = ROOT / "vendor" / "cm048_pipeline"
EDITOR = ROOT / "vendor" / "cm059_editor"
VENDOR = ROOT / "vendor"

ALL_CLEAR = "caught up"

# Path fragments macOS TCC protects. Any open of one of these from the
# ical-server process is the defect.
PROTECTED = (
    "/Library/Messages/",
    "/Library/Mail/",
    "Envelope Index",
    "/Library/Calendars/",
    "Calendar.sqlitedb",
    "NoteStore.sqlite",
    "group.com.apple.notes",
    "/Library/Application Support/AddressBook",
    "Photos.sqlite",
    "Photos Library",
    "/Library/Safari/",
    "/Library/Reminders/",
)

_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def _apple_ns(dt: datetime) -> int:
    return int((dt - _APPLE_EPOCH).total_seconds() * 1_000_000_000)


def make_chat_db(path: Path, now: datetime) -> None:
    """A synthetic chat.db with the columns both readers query.

    chat 1 (1:1, Pat):   last message INBOUND, 2 days old, a question -> owed.
    chat 2 (1:1, Sam):   last message from the owner -> not owed.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT,
            chat_identifier TEXT, display_name TEXT, style INTEGER,
            account_login TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT,
            is_from_me INTEGER, date INTEGER, handle_id INTEGER,
            cache_has_attachments INTEGER DEFAULT 0, service TEXT);
        """
    )
    conn.executemany("INSERT INTO handle VALUES (?, ?)",
                     [(1, "pat@example.invalid"), (2, "+15555550123")])
    conn.executemany(
        "INSERT INTO chat VALUES (?, ?, ?, ?, ?, ?)",
        [(1, "iMessage;-;pat@example.invalid", "pat@example.invalid", "Jane Doe", 45,
          "E:owner@example.invalid"),
         (2, "iMessage;-;+15555550123", "+15555550123", "John Smith", 45,
          "E:owner@example.invalid")])
    conn.executemany("INSERT INTO chat_handle_join VALUES (?, ?)", [(1, 1), (2, 2)])
    msgs = [
        (1, "Hello there", 1, now - timedelta(days=3), 0, 1),
        (2, "Are you free for lunch on Thursday?", 0, now - timedelta(days=2), 1, 1),
        (3, "See you at the station", 0, now - timedelta(days=2), 2, 2),
        (4, "Great, see you then", 1, now - timedelta(days=1), 0, 2),
    ]
    for rowid, text, mine, when, hid, chat in msgs:
        conn.execute(
            "INSERT INTO message (ROWID, text, is_from_me, date, handle_id, service)"
            " VALUES (?, ?, ?, ?, ?, 'iMessage')",
            (rowid, text, mine, _apple_ns(when), hid))
        conn.execute("INSERT INTO chat_message_join VALUES (?, ?)", (chat, rowid))
    conn.commit()
    conn.close()


FEED_PLIST = "com.creativemachines.ostler.imessage-bundle.plist"

_RECORD_CONSENT = textwrap.dedent(
    r"""
    import sys
    from ostler_security import consent
    consent.record_consent("third_party_data_personal_records", "synthetic wording",
                           "test-1", sys.argv[1], "uk", wording_hash="0" * 64)
    """
)


def record_consent(home: Path, decision: str) -> None:
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", ""),
           "PYTHONDONTWRITEBYTECODE": "1"}
    proc = subprocess.run([sys.executable, "-c", _RECORD_CONSENT, decision],
                          env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr[-2000:]


def install_feed_plist(home: Path) -> None:
    la = home / "Library" / "LaunchAgents"
    la.mkdir(parents=True, exist_ok=True)
    (la / FEED_PLIST).write_text("<plist/>", encoding="utf-8")


def connect(home: Path) -> None:
    """What install.sh leaves when it installs the iMessage feed."""
    record_consent(home, "accepted")
    install_feed_plist(home)


def snapshot_path(home: Path) -> Path:
    return home / ".ostler" / "state" / "reply_debt" / "imessage_threads.json"


def write_snapshot(home: Path, payload: dict) -> None:
    p = snapshot_path(home)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload), encoding="utf-8")


def ok_snapshot(now: datetime, *, generated: datetime | None = None) -> dict:
    return {
        "schema": 1,
        "status": "ok",
        "generated_at": (generated or now).isoformat(),
        "lookback_days": 90,
        "threads": [
            {"chat_id": "iMessage;-;pat@example.invalid", "display_name": "Jane Doe",
             "participants": ["pat@example.invalid"], "is_group": False,
             "last": {"text": "Are you free for lunch on Thursday?", "is_from_me": False,
                      "sender": "pat@example.invalid",
                      "timestamp": (now - timedelta(days=2)).isoformat()}},
            {"chat_id": "iMessage;-;+15555550123", "display_name": "John Smith",
             "participants": ["+15555550123"], "is_group": False,
             "last": {"text": "Great, see you then", "is_from_me": True, "sender": "me",
                      "timestamp": (now - timedelta(days=1)).isoformat()}},
        ],
    }


# The child: install the audit hook FIRST, then import and call the real
# ical-server reply-debt function exactly as its HTTP handler does.
_CHILD = textwrap.dedent(
    r"""
    import importlib.util, json, sys
    PROTECTED = tuple(json.loads(sys.argv[2]))
    seen = []
    def hook(event, args):
        if event in ("open", "sqlite3.connect", "os.listdir", "os.scandir"):
            target = args[0] if args else None
            if isinstance(target, bytes):
                target = target.decode("utf-8", "replace")
            target = str(target)
            if any(p in target for p in PROTECTED):
                seen.append([event, target])
    sys.addaudithook(hook)
    mode = sys.argv[3]
    if mode == "control":
        import sqlite3
        sqlite3.connect(sys.argv[4]).close()
        print(json.dumps({"opened": seen}))
        raise SystemExit(0)
    server = sys.argv[1]
    spec = importlib.util.spec_from_file_location("_rd_ical_server", server)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, server.rsplit("/", 1)[0])
    spec.loader.exec_module(mod)
    payload, status = mod.api_reply_debt(lookback_days=90, limit=50)
    print(json.dumps({"payload": payload, "status": status, "opened": seen}))
    """
)


def run_endpoint(home: Path, *, mode: str = "endpoint", extra: list[str] | None = None) -> dict:
    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
        "USER_ID": "operator",
        "USER_DISPLAY_NAME": "Alex Jones",
        "REPLY_DEBT_PROJECT_DIR": str(CM048),
    }
    proc = subprocess.run(
        [sys.executable, "-c", _CHILD, str(SERVER), json.dumps(PROTECTED), mode,
         *(extra or [])],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, f"child failed rc={proc.returncode}\n{proc.stderr[-3000:]}"
    return json.loads(proc.stdout.strip().splitlines()[-1])


@pytest.fixture()
def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    h = tmp_path / "home"
    h.mkdir()
    return h


# ---------------------------------------------------------------------------
# The instrument can fire (positive control)
# ---------------------------------------------------------------------------


def test_control_the_audit_hook_sees_a_chat_db_open(home, now):
    db = home / "Library" / "Messages" / "chat.db"
    make_chat_db(db, now)
    out = run_endpoint(home, mode="control", extra=[str(db)])
    assert out["opened"], "the audit hook saw nothing: the instrument is blind"
    assert any("/Library/Messages/chat.db" in t for _, t in out["opened"])


# ---------------------------------------------------------------------------
# 1. ical-server never opens a protected path
# ---------------------------------------------------------------------------


def test_reply_debt_never_opens_chat_db_even_when_it_is_readable(home, now):
    """A readable chat.db is the most tempting case: main reads it."""
    connect(home)
    make_chat_db(home / "Library" / "Messages" / "chat.db", now)
    write_snapshot(home, ok_snapshot(now))
    out = run_endpoint(home)
    assert out["opened"] == [], f"ical-server opened protected paths: {out['opened']}"
    p = out["payload"]
    assert p["degraded"] is False, p
    assert p["count"] == 1, p
    assert [d["person_name"] for d in p["debts"]] == ["Jane Doe"], p


def test_reply_debt_never_opens_chat_db_when_no_snapshot(home, now):
    connect(home)
    make_chat_db(home / "Library" / "Messages" / "chat.db", now)
    out = run_endpoint(home)
    assert out["opened"] == [], f"ical-server opened protected paths: {out['opened']}"


# ---------------------------------------------------------------------------
# 2. An unreadable source is degraded, never the all-clear
# ---------------------------------------------------------------------------


def _assert_degraded(p: dict, reason: str) -> None:
    assert p["degraded"] is True, p
    assert p["reason"] == reason, p
    assert p["count"] == 0 and p["debts"] == [], p
    assert ALL_CLEAR not in json.dumps(p).lower(), p
    assert p["brief_line"] == "", p


def test_unreadable_messages_is_degraded_not_all_clear(home, now):
    """The studio29 box exactly: chat.db present, this process cannot open
    it (chmod 000 stands in for the TCC denial), and no snapshot yet."""
    if os.geteuid() == 0:
        pytest.skip("root ignores chmod 000; the denial cannot be staged")
    connect(home)
    db = home / "Library" / "Messages" / "chat.db"
    make_chat_db(db, now)
    db.chmod(0)
    try:
        out = run_endpoint(home)
    finally:
        db.chmod(0o600)
    _assert_degraded(out["payload"], "imessage_snapshot_missing")


def test_feed_that_could_not_read_messages_is_degraded(home, now):
    connect(home)
    write_snapshot(home, {"schema": 1, "status": "unreadable",
                          "generated_at": now.isoformat(),
                          "reason": "Cannot read iMessage history."})
    _assert_degraded(run_endpoint(home)["payload"], "messages_not_readable")


def test_stale_snapshot_is_degraded(home, now):
    connect(home)
    write_snapshot(home, ok_snapshot(now, generated=now - timedelta(hours=30)))
    _assert_degraded(run_endpoint(home)["payload"], "imessage_snapshot_stale")


def test_malformed_snapshot_is_degraded(home, now):
    connect(home)
    p = snapshot_path(home)
    p.parent.mkdir(parents=True)
    p.write_text("{not json", encoding="utf-8")
    _assert_degraded(run_endpoint(home)["payload"], "imessage_snapshot_malformed")


def test_genuinely_nothing_owed_is_still_the_all_clear(home, now):
    """The control for the degraded arm: a readable source with no debt
    still says caught up, so the tests above discriminate."""
    connect(home)
    snap = ok_snapshot(now)
    snap["threads"] = snap["threads"][1:]  # only the owner-last thread
    write_snapshot(home, snap)
    p = run_endpoint(home)["payload"]
    assert p["degraded"] is False and p["count"] == 0, p
    assert ALL_CLEAR in p["brief_line"].lower(), p


def test_no_consent_is_not_connected_not_couldnt_check(home, now):
    """Third-party consent never accepted: install.sh skipped the feed, so
    there will never be a snapshot. Not "couldn't check"."""
    make_chat_db(home / "Library" / "Messages" / "chat.db", now)
    out = run_endpoint(home)
    assert out["opened"] == [], out["opened"]
    _assert_degraded(out["payload"], "imessage_not_connected")


def test_declined_consent_is_not_connected(home, now):
    record_consent(home, "declined")
    install_feed_plist(home)  # a leftover agent does not override a decline
    _assert_degraded(run_endpoint(home)["payload"], "imessage_not_connected")


def test_consent_without_the_feed_is_not_connected(home, now):
    """Consent accepted but no chat.db at install: no feed LaunchAgent."""
    record_consent(home, "accepted")
    _assert_degraded(run_endpoint(home)["payload"], "imessage_not_connected")


# ---------------------------------------------------------------------------
# The producer: the signed iMessage feed writes what the endpoint reads
# ---------------------------------------------------------------------------


def _pipeline():
    sys.path.insert(0, str(VENDOR))
    try:
        from imessage_source import pipeline
    finally:
        sys.path.remove(str(VENDOR))
    return pipeline


def _adapters():
    sys.path.insert(0, str(CM048))
    try:
        from src import reply_debt_adapters, reply_debt_service
    finally:
        sys.path.remove(str(CM048))
    return reply_debt_adapters, reply_debt_service


def test_feed_writes_a_snapshot_the_endpoint_can_score(tmp_path, now, monkeypatch):
    pipeline = _pipeline()
    adapters, service = _adapters()
    monkeypatch.setattr(adapters, "imessage_connection_state", lambda: ("connected", ""))
    db = tmp_path / "chat.db"
    make_chat_db(db, now)
    out = tmp_path / "state" / "imessage_threads.json"
    assert pipeline.write_reply_debt_snapshot(db_path=db, out_path=out) == "ok"
    assert (out.stat().st_mode & 0o777) == 0o600
    threads = adapters.load_imessage_threads(snapshot_path=out, now=now)
    debts = service.compute_reply_debts(thread_sources=[threads])
    assert [d.person_name for d in debts] == ["Jane Doe"]


def test_feed_records_an_unreadable_chat_db_rather_than_an_empty_list(tmp_path, now, monkeypatch):
    if os.geteuid() == 0:
        pytest.skip("root ignores chmod 000; the denial cannot be staged")
    pipeline = _pipeline()
    adapters, _ = _adapters()
    monkeypatch.setattr(adapters, "imessage_connection_state", lambda: ("connected", ""))
    db = tmp_path / "chat.db"
    make_chat_db(db, now)
    db.chmod(0)
    out = tmp_path / "imessage_threads.json"
    try:
        assert pipeline.write_reply_debt_snapshot(db_path=db, out_path=out) == "unreadable"
    finally:
        db.chmod(0o600)
    with pytest.raises(adapters.ReplyDebtSourceUnavailable) as e:
        adapters.load_imessage_threads(snapshot_path=out, now=now)
    assert e.value.reason == "messages_not_readable"


def test_service_shim_degrades_too(tmp_path, monkeypatch):
    """CM048's own BaseHTTPRequestHandler shim had the same all-clear."""
    import io

    monkeypatch.setenv("OSTLER_REPLY_DEBT_SNAPSHOT", str(tmp_path / "absent.json"))
    adapters, service = _adapters()
    monkeypatch.setattr(adapters, "imessage_connection_state", lambda: ("connected", ""))

    class H:
        def __init__(self):
            self.wfile = io.BytesIO()
            self.code = None

        def send_response(self, c):
            self.code = c

        def send_header(self, *a):
            pass

        def end_headers(self):
            pass

    h = H()
    service.handle_reply_debt(h)
    body = json.loads(h.wfile.getvalue())
    assert body["degraded"] is True and body["reason"] == "imessage_snapshot_missing", body
    assert ALL_CLEAR not in json.dumps(body).lower()


# ---------------------------------------------------------------------------
# 3. Consumers render "couldn't check"
# ---------------------------------------------------------------------------


def _editor():
    sys.path.insert(0, str(EDITOR))
    try:
        from compiler import frontpage, render_frontpage, signals
    finally:
        sys.path.remove(str(EDITOR))
    return frontpage, render_frontpage, signals


DEGRADED = {"count": 0, "brief_line": "", "debts": [], "degraded": True,
            "reason": "imessage_snapshot_stale", "privacy_level": "L2"}
NOT_CONNECTED = {"count": 0, "brief_line": "", "debts": [], "degraded": True,
                 "reason": "imessage_not_connected", "privacy_level": "L2"}
OWED = {"count": 1, "brief_line": "You owe a reply to 1 person:", "degraded": False,
        "debts": [{"person_name": "Jane Doe"}], "privacy_level": "L2"}
CAUGHT_UP = {"count": 0, "brief_line": "No replies owed  -  you're all caught up.",
             "debts": [], "degraded": False, "privacy_level": "L2"}


def test_editor_signal_cards_say_couldnt_check(now):
    _, _, signals = _editor()
    cards = signals.build_signal_cards({"reply_debt": DEGRADED}, now)
    titles = [c["title"] for c in cards]
    assert any("couldn't check" in t.lower() for t in titles), titles
    # The control: a real zero yields no card at all, as before.
    assert signals.build_signal_cards({"reply_debt": CAUGHT_UP}, now) == []


def test_front_page_feed_and_html_carry_couldnt_check(now):
    """The feed is what the Hub's Front Page renders (FrontPageCards reads
    frontpage.json); the HTML is the editor's own page. Both must say it."""
    frontpage, render_frontpage, _ = _editor()
    feed = frontpage.build_frontpage({"interests": []}, now=now,
                                     signals={"reply_debt": DEGRADED})
    texts = [(c.get("title") or "") + " " + (c.get("body") or "") for c in feed["cards"]]
    assert any("couldn't check" in t.lower() for t in texts), texts
    assert not any(ALL_CLEAR in t.lower() for t in texts), texts
    html = render_frontpage.render(feed)
    assert "Couldn&#x27;t check" in html or "Couldn't check" in html
    assert ALL_CLEAR not in html.lower()


def _card_text(cards) -> list[str]:
    return [((c.get("title") or "") + " " + (c.get("body") or "")).lower() for c in cards]


@pytest.mark.parametrize("state", ["connected", "stale", "not_connected"])
def test_editor_three_states(now, state):
    """connected: the normal card (or none at zero); stale: "couldn't check,
    will check again"; not connected: plainly not connected, no retry promise."""
    _, _, signals = _editor()
    raw = {"connected": OWED, "stale": DEGRADED, "not_connected": NOT_CONNECTED}[state]
    texts = _card_text(signals.build_signal_cards({"reply_debt": raw}, now))
    assert len(texts) == 1, texts
    t = texts[0]
    if state == "connected":
        assert "waiting on you" in t and "couldn't" not in t and "isn't connected" not in t, t
    elif state == "stale":
        assert "couldn't check" in t and "again shortly" in t, t
        assert "isn't connected" not in t, t
    else:
        assert "messages isn't connected" in t, t
        assert "again" not in t and "shortly" not in t and "couldn't" not in t, t
    assert ALL_CLEAR not in t, t


def test_front_page_html_says_not_connected(now):
    frontpage, render_frontpage, _ = _editor()
    feed = frontpage.build_frontpage({"interests": []}, now=now,
                                     signals={"reply_debt": NOT_CONNECTED})
    html = render_frontpage.render(feed)
    assert "Messages isn&#x27;t connected" in html or "Messages isn't connected" in html
    assert "again shortly" not in html and ALL_CLEAR not in html.lower()
