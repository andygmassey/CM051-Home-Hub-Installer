"""Call history catch-up: the walk back past the forward window.

Drives the SHIPPED adapter (vendor/ostler_fda/catchup_calls.py) through the
SHIPPED core (lib/ostler_catchup.py), the SHIPPED reader and the SHIPPED sink
(pwg_ingest.ingest_calls) over a synthetic CallHistory.storedata holding six
years of calls, with a real SPARQL engine (rdflib) as the only fake.

Synthetic only: Ofcom drama-range numbers composed from fragments, invented
names, example.com addresses.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

REPO = Path(__file__).resolve().parent.parent
for p in (str(REPO / "vendor"), str(REPO / "lib"), str(REPO / "tests")):
    if p not in sys.path:
        sys.path.insert(0, p)

import ostler_catchup as oc  # noqa: E402
from ostler_fda import call_history as ch  # noqa: E402
from ostler_fda import catchup_calls as cc  # noqa: E402
from ostler_fda import pwg_ingest as pi  # noqa: E402
from test_call_history_vendored import (  # noqa: E402
    NUM_A, NUM_E, FakeStore, make_call_db,
)

NOW = datetime.now(timezone.utc).replace(microsecond=0)
YEARS = 6
N = 240          # a call every ~9 days, newest first


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    monkeypatch.delenv("OSTLER_HOME", raising=False)
    monkeypatch.delenv("OSTLER_CATCHUP_STATE_DIR", raising=False)
    monkeypatch.setenv("OSTLER_CALL_BACKFILL_DAYS", "365")
    st = FakeStore()
    st.add_person("a", "Alex Example", [("phone", NUM_A)])
    rows = []
    for i in range(N):
        when = NOW - timedelta(days=1 + i * (YEARS * 365) / N)
        rows.append({"address": NUM_A if i % 10 else NUM_E, "when": when,
                     "uid": f"cu{i}", "duration": 30.0 + i})
    db = make_call_db(tmp_path / "CallHistory.storedata", rows)
    with patch.object(pi, "_sparql_query", st.query), \
            patch.object(pi, "_sparql_update", st.update):
        yield st, db, rows


def _walk(db, ticks=8):
    s = {}
    for _ in range(ticks):
        s = oc.run([cc.CallsAdapter(db_path=db)], budget_seconds=1e9, busy=lambda: None)
        if s["sources"]["calls"]["reason"] == "complete" or \
                json.loads((oc.state_dir() / "calls.json").read_text())["complete"]:
            break
    return s


def test_walk_reaches_the_oldest_call_and_each_matched_call_lands_once(world):
    st, db, rows = world
    _walk(db)
    wm = json.loads((oc.state_dir() / "calls.json").read_text())
    assert wm["complete"] and wm["doctor_row"] == "calls"
    oldest = min(r["when"] for r in rows)
    got = datetime.fromisoformat(wm["oldest_at"].replace("Z", "+00:00"))
    assert abs((got - oldest).total_seconds()) < 31 * 86400
    expect_matched = [r for r in rows if r["address"] == NUM_A]
    # the forward 365-day tick owns the newest year; catch-up owns the rest
    older = [r for r in expect_matched if r["when"] < NOW - timedelta(days=365)]
    assert len(older) > 100
    assert len(st.calls()) == len(older), "a matched older call is missing or doubled"
    assert len({str(c) for c in st.calls()}) == len(older)


def test_rerun_after_complete_writes_nothing_new(world):
    st, db, _ = world
    _walk(db)
    before = len(st.g)
    oc.run([cc.CallsAdapter(db_path=db)], budget_seconds=1e9, busy=lambda: None)
    assert len(st.g) == before


def test_a_graph_outage_counts_nothing_and_the_window_is_retried(world):
    st, db, _ = world
    st.fail_query = True
    s = oc.run([cc.CallsAdapter(db_path=db)], budget_seconds=1e9, busy=lambda: None)
    assert st.calls() == []
    wm = json.loads((oc.state_dir() / "calls.json").read_text())
    assert not wm["complete"] and wm["items_quarantined"] == 0
    st.fail_query = False
    _walk(db)
    assert json.loads((oc.state_dir() / "calls.json").read_text())["complete"]
    assert st.calls()


def test_an_unreadable_database_is_cannot_run_never_complete(world):
    st, db, _ = world
    with patch.object(ch.shutil, "copy2", side_effect=PermissionError("EPERM")):
        s = oc.run([cc.CallsAdapter(db_path=db)], budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["calls"]["reason"] == "cannot_run:read_denied"
    wm = json.loads((oc.state_dir() / "calls.json").read_text())
    assert not wm["complete"] and wm["cannot_run"] == "read_denied"


def test_an_unknown_schema_is_cannot_run_never_an_empty_walk(world, tmp_path):
    bad = tmp_path / "bad.storedata"
    conn = sqlite3.connect(str(bad))
    conn.execute("CREATE TABLE ZCALLRECORD (Z_PK INTEGER)")
    conn.commit(); conn.close()
    s = oc.run([cc.CallsAdapter(db_path=bad)], budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["calls"]["reason"] == "cannot_run:schema_unknown"
    wm = json.loads((oc.state_dir() / "calls.json").read_text())
    assert not wm["complete"]


def test_consent_is_honoured(world, monkeypatch):
    monkeypatch.setenv("OSTLER_FDA_SOURCES", "safari_history,imessage")
    assert cc.adapters() == []
    monkeypatch.setenv("OSTLER_FDA_SOURCES", "call_history")
    monkeypatch.setattr(ch, "DEFAULT_CALL_DB", Path("/nonexistent/CallHistory.storedata"))
    assert cc.adapters() == []                       # no call history on this Mac
    _, db, _ = world
    monkeypatch.setattr(ch, "DEFAULT_CALL_DB", db)
    assert [a.source for a in cc.adapters()] == ["calls"]


def test_the_runner_is_registered_by_install_sh_and_names_a_real_factory():
    text = (REPO / "install.sh").read_text(encoding="utf-8", errors="replace")
    assert "_ostler_catchup_register 25-calls" in text
    assert '"ostler_fda.catchup_calls:adapters"' in text
    assert callable(cc.adapters)
