"""VENDOR COPY test, run against vendor/cm048_pipeline, the tree that ships.

A redacted (L2) reminder title must never carry a raw messaging handle.

Defect: "Follow up with @+15550100" reached the customer's Apple Reminders
(7 of 22 pushed reminders on a real-size walk), because reminders_push put
the bundle's participant id (a phone number / JID / email) straight into the
title. The title now names the person only when the handle resolves, through
the Qdrant `people` store the Hub People list reads, to a human display
name; otherwise it is the generic "Follow up on a conversation".
Synthetic data only.
"""
from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src.conversation_writer import ConversationBundle, ConversationSummary, Todo
from src.reminders_push import decide_push

GENERIC = "Follow up on a conversation"
PHONE = "+15550100"
JID = "15550100@s.whatsapp.net"
EMAIL = "partner_a@example.invalid"


@pytest.fixture(autouse=True)
def _dead_people_store(monkeypatch):
    # Nothing listens on port 9: the default resolver sees "store down",
    # so no test here depends on a Qdrant on the host running it.
    monkeypatch.setenv("OSTLER_QDRANT_URL", "http://127.0.0.1:9")


def _bundle(participants, level="L2"):
    return ConversationBundle(
        conversation_id="synthetic-1",
        source_kind="channel",
        source_subtype="imessage",
        source_session_id="s-1",
        channel="im",
        participants=tuple(participants),
        started_at="2026-10-01T09:00:00Z",
        ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic transcript",
        privacy_level=level,
    )


def _decide(participants, level="L2", **kw):
    todo = Todo(id="t1", text="send the synthetic draft", owner="user", deadline=None)
    return decide_push(
        todo, _bundle(participants, level), demo_mode=False, user_id="user",
        summary_path=Path("/tmp/synthetic/summary.md"), **kw,
    )


@pytest.mark.parametrize("handle", [PHONE, JID, EMAIL, "(555) 0100", "+15550100@lid"])
def test_unresolved_handle_gives_generic_title_and_no_handle(handle):
    d = _decide(("user", handle))
    assert d.eligible
    assert d.push_title == GENERIC
    assert handle not in d.push_title and handle not in d.push_notes
    assert "@" not in d.push_title


def test_phone_handle_never_appears_in_title():
    d = _decide(("user", PHONE))
    assert PHONE not in d.push_title
    assert "5550100" not in d.push_title


def test_email_handle_never_appears_in_title_or_notes():
    d = _decide(("user", EMAIL))
    assert EMAIL not in d.push_title
    assert EMAIL not in d.push_notes


def test_resolved_handle_gives_name_and_short_text():
    d = _decide(("user", PHONE), name_resolver=lambda h: "Jane Doe" if h == PHONE else None)
    assert d.push_title == "Jane Doe: send the synthetic draft"


def test_resolver_returning_a_handle_is_treated_as_unresolved():
    d = _decide(("user", PHONE), name_resolver=lambda h: "+15550199")
    assert d.push_title == GENERIC
    d = _decide(("user", PHONE), name_resolver=lambda h: EMAIL)
    assert d.push_title == GENERIC


def test_resolver_that_raises_gives_generic_title():
    def boom(_h):
        raise RuntimeError("store down")
    assert _decide(("user", PHONE), name_resolver=boom).push_title == GENERIC


def test_multi_party_is_generic_even_with_handles():
    d = _decide(("user", PHONE, EMAIL))
    assert d.push_title == GENERIC


def test_a_label_that_is_already_a_name_is_kept():
    assert _decide(("user", "Jane Doe")).push_title == "Jane Doe: send the synthetic draft"


def test_l0_notes_never_carry_a_handle():
    d = _decide(("user", PHONE), level="L0")
    assert PHONE not in d.push_notes
    d = _decide(("user", PHONE), level="L0", name_resolver=lambda h: "John Doe")
    assert "John Doe" in d.push_notes


class _People(BaseHTTPRequestHandler):
    seen: list = []

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _People.seen.append((self.path, body))
        hit = PHONE in json.dumps(body)
        pts = [{"payload": {"display_name": PHONE, "given_name": "Jane",
                            "family_name": "Doe", "phones": [PHONE]}}] if hit else []
        out = json.dumps({"result": {"points": pts}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def test_default_resolver_reads_the_people_collection(monkeypatch):
    """The real default path: handle -> Qdrant `people` -> given+family,
    upgrading a stored name that is itself just the identifier (the People
    list rule)."""
    srv = HTTPServer(("127.0.0.1", 0), _People)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        monkeypatch.setenv("OSTLER_QDRANT_URL", f"http://127.0.0.1:{srv.server_port}")
        assert _decide(("user", PHONE)).push_title == "Jane Doe: send the synthetic draft"
        assert _decide(("user", "+15550111")).push_title == GENERIC
    finally:
        srv.shutdown()
    assert _People.seen and _People.seen[0][0] == "/collections/people/points/scroll"
