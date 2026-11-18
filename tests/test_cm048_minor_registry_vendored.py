"""The owner's under-18 registry reaches the vendored CM048 pipeline.

CM051 ADAPTATION of CM048 #98 (05affaf1). #98 reads a pwg:MinorFlag record that
only the still-open CM041 #226 writes; the setter that SHIPS here
(vendor/cm041 ical-server api_people_set_minor) writes ~/.ostler/minors.json.
So these tests drive the REAL setter, then the vendored CM048 gate:

  * no fact about the flagged person reaches Qdrant or Oxigraph (step 07)
  * no todo of a conversation with the flagged person is pushed to Reminders
  * the participant is identified by his HANDLE (phone via WhatsApp jid, and
    email), the way a channel adapter supplies it, not by a pre-resolved name
  * a registry that exists but cannot be read stops the WHOLE run: no facts,
    no pushes, one loud log line. An absent registry flags nobody.
  * controls: an adult in the same chat still gets facts and pushes.

Synthetic cast only (Sam Doe the minor, Jane Smith the adult), reserved
example.test addresses and +44 7700 900xxx numbers.
"""
from __future__ import annotations

import importlib.util
import json
import logging
import os
import re
import sqlite3
import sys
import types
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))

def _security_stub():
    """Prefer the real vendored ostler_security; stub only if it cannot import."""
    sys.path.insert(0, str(ROOT / "vendor"))
    try:
        import ostler_security.database, ostler_security.posture, ostler_security.db_key  # noqa
        return
    except Exception:
        for n in [m for m in sys.modules if m.startswith("ostler_security")]:
            del sys.modules[n]
    import sqlite3 as _sq
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    for name, attrs in (
            ("database", {"get_db_connection": lambda path, _k, *a, **k: _sq.connect(path)}),
            ("posture", {"record_posture": lambda *a, **k: None}),
            ("db_key", {"resolve_db_key": lambda *a, **k: types.SimpleNamespace(
                key=None, reason="stub", detail="")})):
        m = types.ModuleType("ostler_security." + name)
        for k, v in attrs.items():
            setattr(m, k, v)
        sys.modules["ostler_security." + name] = m


_security_stub()
from src import ingest, minors, reminders_push  # noqa: E402
from src.conversation_writer import (  # noqa: E402
    ConversationBundle, ConversationSummary, Todo, write_conversation)
from src.schemas import Classification, Sensitivity  # noqa: E402
from src.settings import Settings, ensure_directories  # noqa: E402

REAL_LOAD = minors.load
NS = "https://schema.ostler.ai/ontology#"
SAM, SAM_URI = "Sam Doe", NS + "person_samexample01"
SAM_PHONE = "+44" + "7700" + "900123"  # reserved range, composed
SAM_EMAIL = "sam.example" + "@" + "example.test"
JANE = "Jane Smith"
JANE_EMAIL = "jane.smith" + "@" + "example.test"


def _load_server():
    f = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
    spec = importlib.util.spec_from_file_location("ical_server_for_cm048_minors", f)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


server = _load_server()
SAM_SLUG = server._wiki_slug(SAM)


class _GraphStub:
    """The slice of the graph api_people_set_minor reads and writes."""

    def __init__(self):
        self.ids = [("phone", SAM_PHONE), ("email", SAM_EMAIL)]
        self.suppressions = {}

    def select(self, q):
        if "SELECT ?reason" in q:
            m = re.search(r"<[^>]*suppression_([a-z0-9-]+)>", q)
            s = m.group(1)
            return [{"reason": self.suppressions[s]}] if s in self.suppressions else []
        if "SELECT DISTINCT ?t ?v" in q:
            return [{"t": t, "v": v} for (t, v) in self.ids if "<%s>" % SAM_URI in q]
        if "SELECT ?person ?name" in q:
            return [{"person": SAM_URI, "name": SAM}]
        return []

    def update(self, q):
        if "INSERT DATA" in q:
            slug = re.search(r"suppression_([a-z0-9-]+)>", q).group(1)
            reason = re.search(r'pwg:suppressReason "([^"]*)"', q).group(1)
            self.suppressions[slug] = reason
        m = re.search(r"DELETE WHERE \{ <[^>]*suppression_([a-z0-9-]+)>", q)
        if m:
            self.suppressions.pop(m.group(1), None)


@pytest.fixture
def registry(tmp_path, monkeypatch):
    """Throwaway HOME + registry path; the REAL setter marks Sam Doe."""
    home = tmp_path / "home"
    home.mkdir()
    reg = home / ".ostler" / "minors.json"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("OSTLER_MINORS_FILE", str(reg))
    monkeypatch.setenv("OSTLER_MINORS_DISMISSED_FILE", str(home / "dismissed.json"))
    g = _GraphStub()
    with patch.object(server, "_sparql_select", g.select), \
            patch.object(server, "_sparql_update", g.update), \
            patch.object(server, "_load_people_list_self_uris", lambda: set()), \
            patch.object(server, "_load_carded_uris", lambda u: set(u)):
        body, status = server.api_people_set_minor(SAM_SLUG, {"minor": True})
        assert status == 200, body
        yield reg


@pytest.fixture
def settings(tmp_path):
    s = Settings(user_id="test-user", user_display_name="Test User",
                 processing_state_dir=tmp_path / "p",
                 output_conversations_dir=tmp_path / "c",
                 coach_db_path=tmp_path / "coach" / "o.db")
    ensure_directories(s)
    return s


# Participants as a channel adapter supplies them: a HANDLE, no resolved name.
META = {"channel": "whatsapp", "participants": [
    {"role": "user", "display": "Test User"},
    {"role": "other", "handle": SAM_PHONE.lstrip("+") + "@s.whatsapp.net"},
    {"role": "other", "display": "Jane", "handle": JANE_EMAIL},
]}
ADULT_ONLY = {"channel": "im", "participants": [
    {"role": "user", "display": "Test User"},
    {"role": "other", "display": "Jane", "handle": JANE_EMAIL}]}

FACTS = [
    {"text": "Test User is planning a trip", "subject": "user", "privacy_level": "L1"},
    {"text": "Sam plays football on Saturdays", "subject": "other:" + SAM_SLUG,
     "privacy_level": "L1"},
    {"text": "Sam goes to Riverside school", "subject": SAM_PHONE.lstrip("+") + "@s.whatsapp.net",
     "privacy_level": "L1"},
    {"text": "Sam Doe likes drawing", "subject": "other:Sam Doe", "privacy_level": "L1"},
    {"text": "Jane Smith works at Acme Corp", "subject": "other:jane_smith",
     "privacy_level": "L1"},
]
MINOR_TEXTS = [f["text"] for f in FACTS[1:4]]


class _Resp:
    status_code = 200
    text = ""

    def raise_for_status(self):
        return None

    def json(self):
        return {"result": {"status": "ok"}}


def _capture_sinks(monkeypatch):
    posts = []

    class _Client:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def post(self, url, content=b"", headers=None, params=None, json=None):
            posts.append((url, content if content else json))
            return _Resp()

        def put(self, url, json=None, content=b"", headers=None, params=None):
            posts.append((url, json if json is not None else content))
            return _Resp()

    monkeypatch.setattr(ingest.httpx, "Client", _Client)
    monkeypatch.setattr(ingest, "_embed", lambda *a, **k: [0.1] * 8, raising=False)
    return posts


def _text(posts):
    out = []
    for _u, b in posts:
        out.append(b.decode() if isinstance(b, bytes) else
                   b if isinstance(b, str) else json.dumps(b, default=str))
    return "\n".join(out)


def _classification():
    return Classification(
        setting="correspondence", shape="one-on-one", stakes="medium",
        confidence=0.9, reasoning="synthetic fixture",
        sensitivity=Sensitivity(level="normal", categories=[], reasoning=""),
        suggested_type_slug="correspondence_one-on-one_medium")


def _state(tmp_path, meta=META, facts=FACTS):
    sd = tmp_path / "state"
    sd.mkdir()
    (sd / "05_facts.json").write_text(json.dumps(facts))
    (sd / "00_metadata.json").write_text(json.dumps(dict(meta, conversation_id="wa-1")))
    return sd


def _write_all(tmp_path, settings, meta=META):
    return ingest.write_all(state_dir=_state(tmp_path, meta), conversation_id="wa-1",
                            classification=_classification(), settings=settings,
                            dry_run=False, metadata=meta)


# -- the registry the real setter wrote is what the gate reads -------------

def test_the_real_setter_wrote_a_registry_the_gate_reads(registry):
    data = json.loads(registry.read_text())
    assert [e["slug"] for e in data["minors"]] == [SAM_SLUG]
    idx = minors.load()
    assert idx.matches_value(SAM_PHONE) and idx.matches_value(SAM_EMAIL)
    assert idx.matches_name("sam  doe")
    assert not idx.matches_value(JANE_EMAIL), "control: an adult is not flagged"


@pytest.mark.parametrize("entry", [
    {"role": "other", "handle": SAM_PHONE.lstrip("+") + "@s.whatsapp.net"},
    {"role": "other", "handle": "+44 " + "7700 900123"},
    {"role": "other", "email": SAM_EMAIL.upper()},
    {"role": "other", "display": "Sam Doe"},
])
def test_every_handle_shape_of_the_minor_is_seen(registry, entry):
    assert minors.participant_is_minor(entry, minors.load())


def test_adults_and_the_owner_are_not_minors(registry):
    idx = minors.load()
    assert not minors.participant_is_minor(
        {"role": "other", "display": "Jane", "handle": JANE_EMAIL}, idx)
    assert not minors.participant_is_minor({"role": "user", "display": "Sam Doe"}, idx)
    assert not minors.participant_is_minor({"role": "other", "display": "Sam"}, idx)


# -- step 07 ---------------------------------------------------------------

def test_step07_no_fact_about_the_minor_is_written_anywhere(registry, settings, monkeypatch, tmp_path):
    posts = _capture_sinks(monkeypatch)
    summary = _write_all(tmp_path, settings)
    everything = _text(posts)
    assert "Jane Smith works at Acme Corp" in everything, "control: the adult's fact lands"
    assert "Test User is planning a trip" in everything, "control: the owner's fact lands"
    for t in MINOR_TEXTS:
        assert t not in everything, t
    assert summary["minor_facts_skipped"] == 3


def test_step07_control_with_no_registry_every_fact_is_written(settings, monkeypatch, tmp_path):
    monkeypatch.setenv("OSTLER_MINORS_FILE", str(tmp_path / "absent" / "minors.json"))
    posts = _capture_sinks(monkeypatch)
    _write_all(tmp_path, settings)
    everything = _text(posts)
    for f in FACTS:
        assert f["text"] in everything, f["text"]


@pytest.mark.parametrize("content", ["{not json", '{"minors": "x"}', '{"minors": [1]}', "[]"])
def test_unreadable_registry_stops_the_whole_run_loudly(registry, settings, monkeypatch,
                                                         tmp_path, caplog, content):
    registry.write_text(content)
    posts = _capture_sinks(monkeypatch)
    with caplog.at_level(logging.ERROR):
        with pytest.raises(minors.MinorCheckUnavailable):
            _write_all(tmp_path, settings)
    assert posts == [], "no fact may be written when the registry cannot be read"
    loud = [r for r in caplog.records if "NO facts written" in r.getMessage()]
    assert len(loud) == 1
    assert SAM not in caplog.text and SAM_PHONE not in caplog.text


# -- Reminders ---------------------------------------------------------------

# A bundle dated now sits inside the Reminders push window whatever the date.
_NOW = datetime.now(timezone.utc).isoformat()


def _bundle():
    return ConversationBundle(
        conversation_id="wa-1", source_kind="channel", source_subtype="whatsapp",
        source_session_id="wa-1", channel="im", participants=("user", "Sam"),
        started_at=_NOW, ended_at=_NOW,
        summary=ConversationSummary(overall="Weekend plans", topics=()),
        transcript="synthetic", privacy_level="L1",
        todos=(Todo(id="t1", text="Book the football pitch", owner="user"),))


@pytest.mark.parametrize("flag,reason", [
    (True, reminders_push.SKIP_REASON_MINOR),
    (None, reminders_push.SKIP_REASON_MINOR_UNCHECKED),
])
def test_decide_push_never_pushes_a_minor_conversation(tmp_path, flag, reason):
    b = _bundle()
    d = reminders_push.decide_push(b.todos[0], b, demo_mode=False, user_id="user",
                                   summary_path=tmp_path / "s.md", minor_participant=flag)
    assert not d.eligible and d.skip_reason == reason
    ctl = reminders_push.decide_push(b.todos[0], b, demo_mode=False, user_id="user",
                                     summary_path=tmp_path / "s.md", minor_participant=False)
    assert ctl.eligible, "control: the same todo pushes without a minor"


def _rows(db):
    c = sqlite3.connect(db)
    try:
        return c.execute("SELECT status, skip_reason FROM reminders_map").fetchall()
    finally:
        c.close()


def _run_bundle_step(settings, meta, tmp_path, name):
    """The production caller: processor._step_bundle computes the flag from the
    participants, then the REAL write_conversation records push status."""
    from src import processor
    db = tmp_path / (name + ".db")
    real_write = processor._conversation_writer.write_conversation
    with patch.object(processor._conversation_writer, "write_conversation",
                      lambda bundle, **kw: real_write(
                          bundle, reminders_db_path=db,
                          **{k: v for k, v in kw.items() if k != "reminders_db_path"})), \
            patch.object(processor._channel_adapter, "make_bundle", lambda **kw: _bundle()):
        sd = tmp_path / name
        sd.mkdir()
        (sd / "00_raw_transcript.md").write_text("synthetic transcript")
        processor._step_bundle(None, sd, dict(meta, conversation_id="wa-1"),
                               _classification(), settings, "L1",
                               ingest_sinks=True, dry_run=True)
    return _rows(db)


def test_the_bundle_step_pushes_nothing_for_the_minor_and_control_still_pushes(
        registry, settings, tmp_path):
    rows = _run_bundle_step(settings, META, tmp_path, "minor")
    assert rows == [("skipped", reminders_push.SKIP_REASON_MINOR)]
    ctl = _run_bundle_step(settings, ADULT_ONLY, tmp_path, "adult")
    assert ctl and ctl[0][0] == "pending", "control: an adult-only chat still pushes"


def test_the_bundle_step_pushes_nothing_when_the_registry_is_unreadable(
        registry, settings, tmp_path, caplog):
    registry.write_text("{not json")
    with caplog.at_level(logging.ERROR):
        rows = _run_bundle_step(settings, ADULT_ONLY, tmp_path, "broken")
    assert rows == [("skipped", reminders_push.SKIP_REASON_MINOR_UNCHECKED)]
    assert any("NO facts written" in r.getMessage() for r in caplog.records)


# -- mutant guard: the check is what makes the tests red --------------------

def test_mutant_gate_off_is_caught(registry, settings, monkeypatch, tmp_path):
    """Replace the registry read with 'nobody is flagged': the minor's facts
    now land, so the assertions above would fail. Proves they can."""
    monkeypatch.setattr(minors, "load", lambda *_a, **_k: minors.MinorIndex())
    posts = _capture_sinks(monkeypatch)
    _write_all(tmp_path, settings)
    assert MINOR_TEXTS[0] in _text(posts), "mutant: the gate is off, the fact lands"
    assert _run_bundle_step(settings, META, tmp_path, "mut")[0][0] == "pending"
