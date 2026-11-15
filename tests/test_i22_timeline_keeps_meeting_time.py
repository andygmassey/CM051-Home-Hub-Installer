"""I22: a past meeting keeps its time on the Timeline; an all-day event stays all-day.

F&F walk (TestFlight, 2026-10-24): every past meeting on the iOS Timeline read
"All day". The app (CM031 TimelineDataService.serverEntries) takes the Hub's
``all_day`` flag when sent. The shipped ical-server derived that flag from
``pwg:meetingDate`` cut to its date, so it was true for every graph meeting,
and the graph never recorded which calendar items were really all-day.

END TO END through the shipped code, both sides of the store:

  1. the REAL calendar extract shape: ``CalendarEvent`` from
     vendor/ostler_fda/calendar.py, serialised exactly as extract_all.py does
     (``json.dumps(asdict(e), default=str)``);
  2. the REAL writer: vendor/ostler_fda/pwg_ingest.ingest_calendar, into a
     REAL SPARQL engine (pyoxigraph behind HTTP, tests/_fake_oxigraph.py);
  3. the REAL reader: vendor/cm041/assistant_api/ical-server.api_timeline,
     reading that same store.

Then the ``entries`` the app decodes are checked: a timed meeting keeps its
time with ``all_day`` false, an all-day event stays ``all_day`` true on its own
date. Synthetic data only (example.com, invented titles).
"""
from __future__ import annotations

import importlib.util
import json
import sys
import types
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))


def _stub_security() -> None:
    import sqlite3
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda path, _k, *a, **kw: sqlite3.connect(path)
    sys.modules["ostler_security.database"] = db
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **kw: None
    sys.modules["ostler_security.posture"] = posture
    db_key = types.ModuleType("ostler_security.db_key")
    db_key.resolve_db_key = lambda *a, **kw: types.SimpleNamespace(
        key=None, source=None, reason="no_key", detail=None)
    sys.modules["ostler_security.db_key"] = db_key


_stub_security()

from _fake_oxigraph import FakeOxigraph  # noqa: E402

TIMED = "Design review"
ALLDAY = "Company offsite"


def _events():
    from ostler_fda.calendar import CalendarEvent
    return [
        CalendarEvent(title=TIMED,
                      start_date=datetime(2026, 5, 4, 9, 30, tzinfo=timezone.utc),
                      end_date=datetime(2026, 5, 4, 10, 30, tzinfo=timezone.utc),
                      location="Room 2", attendees=["sam.doe@example.com"],
                      calendar_name="Work", is_all_day=False, notes=None, recurrence=None),
        # Apple stores an all-day item as its floating date at 00:00 UTC.
        CalendarEvent(title=ALLDAY,
                      start_date=datetime(2026, 5, 3, 0, 0, tzinfo=timezone.utc),
                      end_date=datetime(2026, 5, 4, 0, 0, tzinfo=timezone.utc),
                      location=None, attendees=["sam.doe@example.com"],
                      calendar_name="Work", is_all_day=True, notes=None, recurrence=None),
    ]


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    from ostler_fda import pwg_ingest
    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", store.url)
    spec = importlib.util.spec_from_file_location(
        "ical_server_i22", ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(server, "query_google_calendar", lambda *a, **k: [])
    monkeypatch.setattr(server, "ICAL_SCRIPT", str(tmp_path / "no-ical-script"))
    monkeypatch.setattr(server, "_timeline_conversations", lambda *a, **k: ([], None))
    fda = tmp_path / "fda"
    fda.mkdir()
    # Exactly extract_all.py's serialisation of the extract.
    (fda / "calendar_events.json").write_text(
        json.dumps([asdict(e) for e in _events()], indent=2, default=str))
    yield types.SimpleNamespace(store=store, fda=fda, ing=pwg_ingest, server=server)
    store.close()


def _entries(w):
    result = w.ing.ingest_calendar(w.fda)
    assert result["meetings_created"] == 2, result
    out = w.server.api_timeline(days=7, past_days=3650, limit=200)
    return {e["title"]: e for e in out["entries"]}


def test_the_ingest_writes_the_calendar_all_day_flag(world):
    world.ing.ingest_calendar(world.fda)
    rows = world.store.ds.query(
        'PREFIX pwg: <https://schema.ostler.ai/ontology#> '
        'SELECT ?s ?f WHERE { ?m pwg:meetingSummary ?s ; pwg:meetingAllDay ?f }')
    got = {r["s"].value: r["f"].value for r in rows}
    assert got == {TIMED: "false", ALLDAY: "true"}


def test_timed_past_meeting_keeps_its_time_end_to_end(world):
    row = _entries(world)[TIMED]
    assert row["all_day"] is False
    ts = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
    assert ts.tzinfo is not None, row["timestamp"]
    assert ts == datetime(2026, 5, 4, 9, 30, tzinfo=timezone.utc)


def test_all_day_event_stays_all_day_end_to_end(world):
    row = _entries(world)[ALLDAY]
    assert row["all_day"] is True
    assert row["timestamp"].startswith("2026-05-03"), row["timestamp"]


def test_the_app_contract_every_entry_has_a_bool_flag(world):
    # CM031 ServerTimelineEntry decodes `all_day` as Bool? and uses it when
    # present; a missing or non-bool value would fall back to the raw-date rule.
    for title, row in _entries(world).items():
        assert isinstance(row.get("all_day"), bool), title
        assert row["timestamp"], title
