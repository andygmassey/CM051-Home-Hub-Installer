"""Timeline rows: ISO 8601 with an offset, event dates only, unreadable rows dropped.

Andy's CM031 device walk, 2026-10-10: "Timeline is showing loads of stuff for
today that was around a month ago." The app read only full ISO 8601 with an
offset and dated every other row "now". The Hub sent bare dates and
offset-less date-times, and dated conversations by created_at/ingested_at
(the import day) when the event date was missing.

Graft on vendor/cm041/assistant_api/ical-server.py: _to_iso8601 /
_timeline_timestamp, _timeline_conversations' date keys, and api_timeline's
entries (all_day; unreadable rows and conversation_error dropped).
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
sys.path.insert(0, str(VENDOR))


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_HELPERS = _load(VENDOR / "cm041" / "assistant_api" / "tests" / "test_people_list_endpoint.py",
                 "timeline_dates_helpers")
server = _HELPERS.server
HK = timezone(timedelta(hours=8))
OFFSET = r"([+-]\d\d:\d\d|Z)$"


def ts(raw):
    return server._timeline_timestamp(raw, tz=HK)


def test_local_datetimes_carry_the_offset():
    assert ts("20260428T093000") == "2026-04-28T09:30:00+08:00"
    assert ts("2026-04-28T09:30:00") == "2026-04-28T09:30:00+08:00"


def test_a_bare_date_is_local_noon_with_the_offset():
    assert ts("20260428") == "2026-04-28T12:00:00+08:00"
    assert ts("2026-04-28") == "2026-04-28T12:00:00+08:00"


def test_an_existing_offset_is_kept_and_garbage_is_empty():
    assert ts("2026-04-28T01:30:00Z") == "2026-04-28T01:30:00+00:00"
    assert ts("not-a-date") == ""
    assert server._to_iso8601("") == ""


def _conversations(payloads):
    body = json.dumps({"result": {"points": [{"payload": p} for p in payloads],
                                  "next_page_offset": None}}).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = lambda s: s
    resp.__exit__ = lambda *a: False
    with patch.object(server.urllib.request, "urlopen", return_value=resp):
        return server._timeline_conversations(past_days=3650, limit=50)


def test_the_ingest_time_is_never_the_event_date():
    rows, err = _conversations([
        {"created_at": "2026-10-10T08:00:00Z", "ingested_at": "2026-10-10T08:00:00Z", "channel": "whatsapp"},
        {"occurred_at": "2026-09-01T10:00:00Z", "created_at": "2026-10-10T08:00:00Z", "channel": "imessage"},
    ])
    assert err is None
    assert [r["date"] for r in rows] == ["2026-09-01"], "import-dated row dropped; event date kept"


def _timeline(items_from_conversations, conv_err=None):
    with patch.object(server, "parse_ical_output", return_value=[]), \
         patch.object(server, "query_google_calendar", return_value=[]), \
         patch.object(server, "_sparql_select", return_value=[]), \
         patch.object(server, "_timeline_conversations", return_value=(items_from_conversations, conv_err)), \
         patch.object(server.subprocess, "run", return_value=MagicMock(stdout="", stderr="", returncode=0)):
        return server.api_timeline(days=7)


def test_entries_have_offsets_all_day_and_no_undated_rows():
    body = _timeline([
        {"kind": "conversation", "date": "2026-09-01", "summary": "whatsapp", "participants": []},
        {"kind": "conversation", "date": "garbage", "summary": "x", "participants": []},
    ])
    entries = body["entries"]
    assert len(entries) == 1, "the undated row is dropped, not shown as today"
    e = entries[0]
    assert e["type"] == "message"
    import re
    assert re.search(r"^2026-09-01T12:00:00" + OFFSET, e["timestamp"])
    assert e["all_day"] is True


def test_a_conversation_error_is_not_an_entry():
    assert _timeline([], conv_err="qdrant down")["entries"] == []


def test_the_offset_is_the_one_in_force_on_that_date():
    """Europe/London: GMT in January, BST in July. A fixed current offset
    stamped both with the same one (Archie, CM051 #2774)."""
    import os, time
    old = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/London"
    time.tzset()
    try:
        assert server._timeline_timestamp("2026-01-15T09:30:00") == "2026-01-15T09:30:00+00:00"
        assert server._timeline_timestamp("2026-07-15T09:30:00") == "2026-07-15T09:30:00+01:00"
        assert server._timeline_timestamp("2026-01-15") == "2026-01-15T12:00:00+00:00"
    finally:
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()
