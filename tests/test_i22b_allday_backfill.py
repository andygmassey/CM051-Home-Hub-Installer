"""I22b: Meeting nodes written before I22 gain pwg:meetingAllDay, once.

Old rows are written by the REAL ``ingest_calendar`` from an extract that
lacks ``is_all_day`` (the pre-I22 shape), into a REAL SPARQL engine. The
backfill is then run through ``run_once`` with the REAL ``CalendarEvent``
extract shape, and the REAL ``api_timeline`` reads the result (consumer side).
Synthetic data only (example.com, invented titles).
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

from test_i22_timeline_keeps_meeting_time import _stub_security  # noqa: E402

_stub_security()

from _fake_oxigraph import FakeOxigraph  # noqa: E402

TIMED = "Design review"
ALLDAY = "Company offsite"
PWGQ = "PREFIX pwg: <https://schema.ostler.ai/ontology#> "


def _events():
    from ostler_fda.calendar import CalendarEvent
    return [
        CalendarEvent(title=TIMED,
                      start_date=datetime(2026, 5, 4, 9, 30, tzinfo=timezone.utc),
                      end_date=datetime(2026, 5, 4, 10, 30, tzinfo=timezone.utc),
                      location="Room 2", attendees=["sam.doe@example.com"],
                      calendar_name="Work", is_all_day=False, notes=None, recurrence=None),
        CalendarEvent(title=ALLDAY,
                      start_date=datetime(2026, 5, 3, 0, 0, tzinfo=timezone.utc),
                      end_date=datetime(2026, 5, 4, 0, 0, tzinfo=timezone.utc),
                      location=None, attendees=["sam.doe@example.com"],
                      calendar_name="Work", is_all_day=True, notes=None, recurrence=None),
    ]


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    from ostler_fda import pwg_ingest, allday_backfill
    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", store.url)
    spec = importlib.util.spec_from_file_location(
        "ical_server_i22b", ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(server, "query_google_calendar", lambda *a, **k: [])
    monkeypatch.setattr(server, "ICAL_SCRIPT", str(tmp_path / "no-ical-script"))
    monkeypatch.setattr(server, "_timeline_conversations", lambda *a, **k: ([], None))
    fda = tmp_path / "fda"
    fda.mkdir()
    # The PRE-I22 extract shape: no is_all_day key, so no flag is written.
    old = [{k: v for k, v in asdict(e).items() if k != "is_all_day"} for e in _events()]
    (fda / "calendar_events.json").write_text(json.dumps(old, default=str))
    assert pwg_ingest.ingest_calendar(fda)["meetings_created"] == 2
    state = tmp_path / "state"
    yield types.SimpleNamespace(store=store, state=state, ab=allday_backfill,
                                server=server, ing=pwg_ingest)
    store.close()


def _flags(w):
    rows = w.store.ds.query(
        PWGQ + "SELECT ?s ?f WHERE { ?m pwg:meetingSummary ?s . "
        "OPTIONAL { ?m pwg:meetingAllDay ?f } }")
    return {r["s"].value: (r["f"].value if r["f"] is not None else None) for r in rows}


def _quads(w):
    return {str(q) for q in w.store.ds}


def _run(w, **kw):
    return w.ab.run_once(w.state, extract=lambda **_: _events(), **kw)


def test_old_rows_have_no_flag_before_the_backfill(world):
    assert _flags(world) == {TIMED: None, ALLDAY: None}


def test_old_all_day_gains_true_and_timed_stays_false(world):
    res = _run(world)
    assert res["status"] == "ok", res
    assert _flags(world) == {TIMED: "false", ALLDAY: "true"}
    assert (res["set_all_day"], res["set_timed"], res["unmatched"]) == (1, 1, 0)


def test_second_run_changes_nothing(world):
    _run(world)
    before, n_updates = _quads(world), len(world.store.updates)
    assert _run(world)["status"] == "already_done"
    # And with the marker gone, the pass itself is a no-op: nothing unflagged.
    (world.state / world.ab.MARKER_NAME).unlink()
    res = _run(world)
    assert res["status"] == "ok" and res["unflagged_before"] == 0, res
    assert _quads(world) == before
    assert len(world.store.updates) == n_updates


def test_adds_only_never_deletes(world):
    before = _quads(world)
    _run(world)
    after = _quads(world)
    assert before <= after
    assert len(after - before) == 2


def test_an_existing_flag_is_not_rewritten(world):
    world.store.ds  # flag the all-day row 'false' by hand, calendar says true
    uri = world.ab.meeting_uri(ALLDAY, "2026-05-03 00:00:00+00:00")
    world.ing._sparql_update(
        PWGQ + 'PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> '
        f'INSERT DATA {{ <{uri}> pwg:meetingAllDay "false"^^xsd:boolean }}')
    _run(world)
    assert _flags(world)[ALLDAY] == "false"


def test_unmatched_rows_are_left_alone_and_counted(world):
    res = world.ab.run_once(world.state, extract=lambda **_: _events()[:1])
    assert res["status"] == "ok" and res["unmatched"] == 1, res
    assert _flags(world) == {TIMED: "false", ALLDAY: None}


def test_result_is_counts_only(world):
    res = _run(world)
    blob = json.dumps(res) + (world.state / world.ab.MARKER_NAME).read_text()
    assert TIMED not in blob and ALLDAY not in blob and "example.com" not in blob
    assert all(isinstance(v, (int, str)) for v in res.values())


@pytest.mark.parametrize("exc,reason", [(PermissionError, "no_fda"),
                                        (FileNotFoundError, "calendar_not_found")])
def test_unreadable_calendar_is_cannot_run_and_retries(world, exc, reason):
    def boom(**_):
        raise exc("x")
    res = world.ab.run_once(world.state, extract=boom)
    assert res == {"status": "cannot_run", "reason": reason}
    assert not (world.state / world.ab.MARKER_NAME).exists()
    assert _flags(world) == {TIMED: None, ALLDAY: None}


def test_empty_extract_with_unflagged_rows_is_not_done(world):
    res = world.ab.run_once(world.state, extract=lambda **_: [])
    assert res["status"] == "cannot_run" and res["reason"] == "empty_extract", res
    assert not (world.state / world.ab.MARKER_NAME).exists()


def test_store_failure_is_fail_soft_and_writes_no_marker(world):
    def bad_update(_sparql):
        raise RuntimeError("store down")
    res = world.ab.run_once(world.state, extract=lambda **_: _events(),
                            query=world.ing._sparql_query, update=bad_update)
    assert res == {"status": "error", "error": "RuntimeError"}
    assert not (world.state / world.ab.MARKER_NAME).exists()


def test_consumer_timeline_shows_old_all_day_as_all_day(world):
    def entries():
        out = world.server.api_timeline(days=7, past_days=3650, limit=200)
        return {e["title"]: e for e in out["entries"]}
    assert entries()[ALLDAY]["all_day"] is False  # the reported bug
    _run(world)
    got = entries()
    assert got[ALLDAY]["all_day"] is True
    assert got[ALLDAY]["timestamp"].startswith("2026-05-03")
    assert got[TIMED]["all_day"] is False


def test_the_hourly_tick_runs_the_backfill():
    src = (ROOT / "install.sh").read_text()
    i = src.index("from ostler_fda.allday_backfill import run_once")
    tick = src.rfind("from ostler_fda.extract_all import run_all", 0, i)
    assert tick != -1 and i - tick < 12000
    block = src[i - 200:i + 400]
    assert "_xstatus('calendar') == 'ok'" in block
    assert '"' not in src[i - 200:i + 500].split("[allday-backfill]")[0].split("try:")[-1], \
        "a double quote would end the tick's python -c string"
