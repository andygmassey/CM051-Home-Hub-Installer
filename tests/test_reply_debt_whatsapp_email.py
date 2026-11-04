"""Reply debt covers WhatsApp and email, producer to brief payload.

Before: /api/v1/reply-debt read iMessage only, so "waiting on a reply from
you" could never name a WhatsApp or email thread, and the brief heading had to
say "on iMessage". Now each feed tick writes a reply-debt snapshot beside the
iMessage one, and the CM048 service reads all three.

This test crosses every boundary for real, with synthetic data only:
  * the VENDORED whatsapp_source tick reads a synthetic ChatStorage.sqlite
    and the VENDORED email_source tick reads a synthetic Apple Mail .emlx tree
    (their own process_* entry points, with a no-op pwg-convo), and each
    writes its snapshot;
  * the REAL vendored ical-server ``api_reply_debt`` runs in a child process
    under the CPython audit hook (the harness of
    test_reply_debt_never_opens_protected_data.py), with the People graph
    served by a stub SPARQL endpoint, so names come from Contacts cards.

Cast: Jane Doe (owner), Sam Smith, Raj Patel, Mary Jones. Reserved numbers
(+44 7700 900xxx) and example.* addresses.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sqlite3
import sys
import threading
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))

_spec = importlib.util.spec_from_file_location(
    "_rd_harness_wa_email", ROOT / "tests" / "test_reply_debt_never_opens_protected_data.py"
)
H = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H)

from email_source.pipeline import process_email  # noqa: E402
from ostler_fda import whatsapp_history as wh  # noqa: E402
from whatsapp_source.pipeline import process_whatsapp  # noqa: E402

def _at(local: str, domain: str) -> str:
    """Addresses are composed at runtime (the PII shape scan reads literals)."""
    return local + "@" + domain


OWNER_PHONE = "+447700900100"
OWNER_EMAIL = _at("jane.doe", "example.com")
SAM_PHONE = "+447700900201"
RAJ_PHONE = "+447700900202"
UNSAVED_PHONE = "+447700900299"
SAM_EMAIL = _at("sam.smith", "example.org")
MARY_EMAIL = _at("mary.jones", "example.org")
PUSH_NAME = "Bob Brown"          # a WhatsApp push name: must never surface
GROUP_SUBJECT = "Riverside Five"  # a group subject: must never surface
FROM_DISPLAY = "Ben Coe"          # an email From display name: must never surface

GRAPH_ROWS = [
    {"p": "urn:test:owner", "is_owner": "true", "name": "Jane Doe", "type": "phone", "val": OWNER_PHONE},
    {"p": "urn:test:owner", "is_owner": "true", "name": "Jane Doe", "type": "email", "val": OWNER_EMAIL},
    {"p": "urn:test:sam", "name": "Sam Smith", "type": "phone", "val": SAM_PHONE},
    {"p": "urn:test:sam", "name": "Sam Smith", "type": "email", "val": SAM_EMAIL},
    {"p": "urn:test:raj", "name": "Raj Patel", "type": "phone", "val": RAJ_PHONE},
    {"p": "urn:test:mary", "name": "Mary Jones", "type": "email", "val": MARY_EMAIL},
]
OWNER_ENV = {"USER_PHONE": OWNER_PHONE, "USER_EMAIL": OWNER_EMAIL, "USER_NAME": "Jane Doe"}


class _Sparql(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        out = {"results": {"bindings": [
            {k: {"type": "literal", "value": v} for k, v in r.items()} for r in GRAPH_ROWS
        ]}}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


@pytest.fixture()
def store():
    srv = HTTPServer(("127.0.0.1", 0), _Sparql)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


@pytest.fixture()
def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    h = tmp_path / "home"
    h.mkdir()
    return h


def _jid(phone: str) -> str:
    return _at(phone.lstrip("+"), "s.whatsapp.net")


def _mac(dt: datetime) -> float:
    return dt.timestamp() - wh.MAC_EPOCH_OFFSET


def make_chatstorage(path: Path, now: datetime) -> None:
    """chat 1 DM Sam: inbound ask, 2 days old (owed).
    chat 2 DM unsaved: inbound ask (owed, not in contacts).
    chat 3 DM Raj: owner replied last (not owed).
    chat 4 group: Raj @mentions the owner with an ask (owed, from Raj).
    chat 5 group: Sam asks the room, no mention (not owed).
    A push-name table and a group subject exist and must never surface."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.executescript(
        """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZGROUPINFO INTEGER,
            ZCONTACTJID TEXT, ZLASTMESSAGEDATE REAL, ZPARTNERNAME TEXT);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER,
            ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZFROMJID TEXT, ZTEXT TEXT,
            ZMESSAGETYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER,
            ZMEMBERJID TEXT, ZISACTIVE INTEGER);
        CREATE TABLE ZWAGROUPINFO (Z_PK INTEGER PRIMARY KEY, ZSUBJECT TEXT);
        CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID TEXT, ZPUSHNAME TEXT);
        """
    )
    t = now - timedelta(days=2)
    sessions = [
        (1, None, _jid(SAM_PHONE)), (2, None, _jid(UNSAVED_PHONE)), (3, None, _jid(RAJ_PHONE)),
        (4, 10, _at("4001", "g.us")), (5, 11, _at("4002", "g.us")),
    ]
    for pk, gi, jid in sessions:
        conn.execute("INSERT INTO ZWACHATSESSION VALUES (?,?,?,?,?)",
                     (pk, gi, jid, _mac(t), PUSH_NAME))
    conn.executemany("INSERT INTO ZWAGROUPINFO VALUES (?,?)", [(10, GROUP_SUBJECT), (11, GROUP_SUBJECT)])
    members = [(1, 4, _jid(RAJ_PHONE), 1), (2, 4, _jid(SAM_PHONE), 1),
               (3, 5, _jid(RAJ_PHONE), 1), (4, 5, _jid(SAM_PHONE), 1)]
    conn.executemany("INSERT INTO ZWAGROUPMEMBER VALUES (?,?,?,?)", members)
    conn.executemany("INSERT INTO ZWAPROFILEPUSHNAME VALUES (?,?,?)",
                     [(1, _jid(UNSAVED_PHONE), PUSH_NAME)])
    mention = "@" + OWNER_PHONE.lstrip("+")
    msgs = [
        (1, 1, 1, t - timedelta(hours=3), None, "Morning"),
        (2, 1, 0, t, _jid(SAM_PHONE), "Can you do Thursday's call?"),
        (3, 2, 0, t, _jid(UNSAVED_PHONE), "Are you around this week?"),
        (4, 3, 0, t - timedelta(hours=1), _jid(RAJ_PHONE), "Can you send the photos?"),
        (5, 3, 1, t, None, "Sent them just now."),
        (6, 4, 1, t - timedelta(hours=2), None, "Morning all"),
        (7, 4, 0, t, _jid(RAJ_PHONE), f"{mention} can you bring the speaker on Saturday?"),
        (8, 5, 1, t - timedelta(hours=2), None, "Morning all"),
        (9, 5, 0, t, _jid(SAM_PHONE), "Who is coming on Saturday?"),
    ]
    for pk, chat, mine, when, frm, text in msgs:
        conn.execute("INSERT INTO ZWAMESSAGE VALUES (?,?,?,?,?,?,0)",
                     (pk, chat, mine, _mac(when), frm, text))
    conn.commit()
    conn.close()


def _emlx(mail_dir: Path, mailbox: str, name: str, *, frm: str, to: str, subject: str,
          dt: datetime, body: str, cc: str = "", extra: tuple = ()) -> None:
    headers = [f"From: {FROM_DISPLAY} <{frm}>", f"To: <{to}>", f"Subject: {subject}",
               f"Date: {format_datetime(dt)}", f"Message-Id: <{_at(name, 'example.org')}>",
               "Content-Type: text/plain; charset=utf-8", *extra]
    if cc:
        headers.append(f"Cc: <{cc}>")
    rfc = ("\r\n".join(headers) + "\r\n\r\n" + body + "\r\n").encode()
    d = mail_dir / "V10" / "account.mbox" / f"{mailbox}.mbox" / "UUID" / "Data" / "1" / "Messages"
    d.mkdir(parents=True, exist_ok=True)
    plist = b'<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>\n'
    (d / f"{name}.emlx").write_bytes(f"{len(rfc)}\n".encode() + rfc + plist)


def make_mail(mail_dir: Path, now: datetime) -> None:
    t = now - timedelta(days=2)
    _emlx(mail_dir, "INBOX", "m1", frm=SAM_EMAIL, to=OWNER_EMAIL, subject="Slides",
          dt=t, body="Could you send the slides by Friday?\n\n--\nSam")
    _emlx(mail_dir, "INBOX", "m2", frm=MARY_EMAIL, to=SAM_EMAIL, cc=OWNER_EMAIL,
          subject="Minutes", dt=t, body="Can you check the minutes?")
    _emlx(mail_dir, "INBOX", "m3", frm=_at("team", "example.org"), to=OWNER_EMAIL, subject="Weekly",
          dt=t, body="What do you think of this week's issue?",
          extra=("List-Id: <weekly.example.org>",))
    _emlx(mail_dir, "Junk", "m4", frm=_at("agent", "example.net"), to=OWNER_EMAIL, subject="Hello",
          dt=t, body="Can you reply to arrange the delivery?")
    _emlx(mail_dir, "INBOX", "m5", frm=_at("someone", "example.net"), to=OWNER_EMAIL, subject="Hi",
          dt=t, body="Are you free for a quick call next week?")


def produce(home: Path, tmp: Path, now: datetime) -> None:
    """Run the two VENDORED feed ticks, exactly as their entry points do."""
    reply_dir = home / ".ostler" / "state" / "reply_debt"
    db = tmp / "fixtures" / "ChatStorage.sqlite"
    make_chatstorage(db, now)
    process_whatsapp(db_path=db, state_path=tmp / "state" / "wa.json",
                     snapshot_path=reply_dir / "whatsapp_threads.json",
                     pwg_convo_cmd=["/usr/bin/true"], now_utc=now)
    mail = tmp / "fixtures" / "mail"
    make_mail(mail, now)
    process_email(mail_dir=mail, user_address=OWNER_EMAIL, since_days=0,
                  state_path=tmp / "state" / "email.json",
                  snapshot_path=reply_dir / "email_threads.json",
                  pwg_convo_cmd=["/usr/bin/true"])


def connect_feeds(home: Path, *channels: str) -> None:
    la = home / "Library" / "LaunchAgents"
    la.mkdir(parents=True, exist_ok=True)
    for ch in channels:
        (la / f"com.creativemachines.ostler.{ch}-bundle.plist").write_text("<plist/>")


def run_endpoint(home: Path, store: str) -> dict:
    import subprocess

    env = {"HOME": str(home), "PATH": os.environ.get("PATH", ""),
           "PYTHONDONTWRITEBYTECODE": "1", "USER_ID": "operator",
           "REPLY_DEBT_PROJECT_DIR": str(H.CM048), "NO_PROXY": "*",
           "OXIGRAPH_URL": store, **OWNER_ENV}
    proc = subprocess.run(
        [sys.executable, "-c", H._CHILD, str(H.SERVER), json.dumps(H.PROTECTED), "endpoint"],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, f"child failed rc={proc.returncode}\n{proc.stderr[-3000:]}"
    return json.loads(proc.stdout.strip().splitlines()[-1])


def _imessage_ok(home: Path, now: datetime) -> None:
    H.connect(home)
    H.write_snapshot(home, H.ok_snapshot(now))


def test_snapshots_carry_no_push_name_subject_or_display_name(home, tmp_path, now):
    produce(home, tmp_path, now)
    reply_dir = home / ".ostler" / "state" / "reply_debt"
    for name in ("whatsapp_threads.json", "email_threads.json"):
        p = reply_dir / name
        raw = p.read_text()
        assert json.loads(raw)["status"] == "ok", raw[:400]
        for banned in (PUSH_NAME, GROUP_SUBJECT, FROM_DISPLAY):
            assert banned not in raw, (name, banned)
        assert oct(p.stat().st_mode & 0o777) == "0o600"


def test_three_channels_end_to_end_through_the_real_ical_server(home, tmp_path, now, store):
    produce(home, tmp_path, now)
    _imessage_ok(home, now)
    connect_feeds(home, "whatsapp", "email")
    out = run_endpoint(home, store)
    assert out["opened"] == [], out["opened"]
    p = out["payload"]
    assert p["degraded"] is False and p["partial"] is False, p
    assert p["sources"] == ["imessage", "whatsapp", "email"], p
    got = sorted((d["channel"], d["person_name"]) for d in p["debts"])
    assert got == [
        ("email", "Sam Smith"),
        ("email", "Unknown sender"),
        ("imessage", "Jane Doe"),
        ("whatsapp", "Raj Patel"),
        ("whatsapp", "Sam Smith"),
        ("whatsapp", "Unknown number"),
    ], p
    raj = next(d for d in p["debts"] if d["person_name"] == "Raj Patel")
    assert raj["addressed_in_group"] is True
    sam_mail = next(d for d in p["debts"] if d["channel"] == "email" and d["resolved"])
    assert sam_mail["snippet"] == "Could you send the slides by Friday?"
    ex = p["excluded"]
    assert ex["whatsapp_group_not_addressed_to_owner"] == 1, ex
    assert ex["email_not_to_owner"] == 1, ex
    assert ex["email_mailing_list"] == 1, ex
    assert ex["email_junk:junk_mailbox"] == 1, ex
    blob = json.dumps(p)
    for banned in (PUSH_NAME, GROUP_SUBJECT, FROM_DISPLAY):
        assert banned not in blob, banned
    assert not re.search(r"\d{7,}", p["brief_line"]), p["brief_line"]


def test_control_a_feed_not_installed_is_not_named(home, tmp_path, now, store):
    produce(home, tmp_path, now)
    _imessage_ok(home, now)
    connect_feeds(home, "email")  # WhatsApp opted out at install
    p = run_endpoint(home, store)["payload"]
    assert p["sources"] == ["imessage", "email"], p
    assert p["channels"]["whatsapp"] == {"status": "not_connected"}, p
    assert all(d["channel"] != "whatsapp" for d in p["debts"]), p


def test_a_stale_feed_is_partial_never_caught_up(home, tmp_path, now, store):
    produce(home, tmp_path, now)
    _imessage_ok(home, now)
    connect_feeds(home, "whatsapp", "email")
    p = home / ".ostler" / "state" / "reply_debt" / "email_threads.json"
    snap = json.loads(p.read_text())
    snap["generated_at"] = (now - timedelta(hours=30)).isoformat()
    p.write_text(json.dumps(snap))
    out = run_endpoint(home, store)["payload"]
    assert out["partial"] is True, out
    assert out["channels"]["email"] == {"status": "unavailable", "reason": "email_snapshot_stale"}, out
    assert out["sources"] == ["imessage", "whatsapp"], out


def test_an_unreadable_mail_store_is_recorded_not_empty(home, tmp_path, now):
    """The email tick that cannot read Mail writes status unreadable."""
    from email_source import pipeline as ep

    out = tmp_path / "email_threads.json"
    assert ep.write_reply_debt_snapshot(error=PermissionError("denied"), out_path=out) == "unreadable"
    assert json.loads(out.read_text())["status"] == "unreadable"
