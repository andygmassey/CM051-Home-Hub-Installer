"""Vendored log sites carry ids, counts and statuses, never personal values (S8, 118).

CM051 copy of two upstream tests, run against the VENDORED trees:
  CM041 meeting_syncer/tests/test_no_pii_in_logs.py          (CM041 #237)
  personal-world-graph services/enrich/tests/test_geocoder_no_address_logs.py (#442)

Logs leave the box in diagnostics bundles. Every test drives the real
vendored code with a synthetic record (approved cast, reserved addresses) and
asserts no value from it reaches the log, while the line itself (the id, the
count, the status) is still there, so a silenced logger cannot pass. The
compile-output half of S8 is wiki-recompile/tests/test_wiki_recompile_tick.py.
"""
from __future__ import annotations

import asyncio
import logging
import sys
import types
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor" / "cm041"))
sys.path.insert(0, str(REPO / "vendor" / "cm019_preferences" / "services" / "enrich"))

# src/geo imports aiohttp. The tests never reach the network (the session is
# a fake), so a stub is enough when the dependency is absent.
try:
    import aiohttp  # noqa: F401
except ImportError:
    _stub = types.ModuleType("aiohttp")
    _stub.ClientSession = object
    sys.modules["aiohttp"] = _stub

from identity_resolver.models import MatchResult  # noqa: E402
from meeting_syncer import syncer as syncer_mod  # noqa: E402
from meeting_syncer.syncer import MeetingSyncer  # noqa: E402
from src.clients.geocoder import GeocoderClient  # noqa: E402
from src.geo.geocoder import Geocoder  # noqa: E402

for _m, _sub in ((syncer_mod, "vendor/cm041/meeting_syncer"),
                 (sys.modules["src.geo.geocoder"], "vendor/cm019_preferences")):
    assert _sub in Path(_m.__file__).as_posix(), "imported a non-vendored copy"


# ===================== meeting_syncer (vendor/cm041) ========================
NAME = "Margaret Andersen"
EMAIL = "margaret.andersen@example.com"
TITLE = "Lunch with Margaret Andersen"
PERSON_URI = "https://schema.ostler.ai/ontology#person_0a1b2c3d4e5f"
MS_VALUES = (NAME, "Margaret", "Andersen", EMAIL, "margaret.andersen", TITLE)


def _ms_assert_no_values(text):
    leaked = [v for v in MS_VALUES if v.lower() in text.lower()]
    assert not leaked, f"{len(leaked)} synthetic value(s) reached the log"


def _syncer():
    s = MeetingSyncer.__new__(MeetingSyncer)
    r = MagicMock()
    r.resolve.return_value = MatchResult(person_uri=None, match_type="new", confidence=0.0, details="")
    r.create_person.return_value = PERSON_URI
    s.resolver = r
    s.owner_emails = {"owner@example.com"}
    s._load_state = lambda: {}
    s._save_state = lambda state: None
    s._create_meeting = lambda event: syncer_mod._meeting_uri(event["uid"])
    s._link_attendee = lambda m, p: None
    s._update_last_calendar_contact = lambda p, d: None
    return s


def _events():
    return [{
        "uid": "evt-synthetic-1",
        "summary": TITLE,
        "start": "20990101T120000Z",
        "attendees": [
            {"name": "Owner", "email": "owner@example.com"},
            {"name": NAME, "email": EMAIL},
        ],
    }]


def test_meeting_syncer_created_person_logs_the_id_not_the_name_or_email(caplog):
    with caplog.at_level(logging.DEBUG, logger="meeting_syncer"):
        assert _syncer()._resolve_attendee({"name": NAME, "email": EMAIL}) == PERSON_URI
    assert PERSON_URI in caplog.text
    _ms_assert_no_values(caplog.text)


def test_meeting_syncer_created_person_with_only_an_email_logs_no_email(caplog):
    with caplog.at_level(logging.DEBUG, logger="meeting_syncer"):
        _syncer()._resolve_attendee({"name": "", "email": EMAIL})
    assert PERSON_URI in caplog.text
    _ms_assert_no_values(caplog.text)


def test_meeting_syncer_skipped_non_human_attendee_logs_no_name_or_address(caplog):
    with caplog.at_level(logging.DEBUG, logger="meeting_syncer"):
        assert _syncer()._resolve_attendee({"name": NAME + " Team", "email": "noreply@example.com"}) is None
    assert "non-human attendee" in caplog.text
    _ms_assert_no_values(caplog.text)
    assert "noreply@example.com" not in caplog.text


def test_meeting_syncer_sync_logs_the_meeting_id_not_its_title(caplog):
    with patch.object(syncer_mod, "fetch_events", return_value=_events()), \
            caplog.at_level(logging.DEBUG, logger="meeting_syncer"):
        res = _syncer().sync(days=7, dry_run=False)
    assert res["attendees_linked"] == 1
    assert syncer_mod._meeting_uri("evt-synthetic-1") in caplog.text
    assert PERSON_URI in caplog.text
    _ms_assert_no_values(caplog.text)


def test_meeting_syncer_dry_run_logs_a_count_not_each_attendee(caplog):
    with patch.object(syncer_mod, "fetch_events", return_value=_events()), \
            caplog.at_level(logging.DEBUG, logger="meeting_syncer"):
        _syncer().sync(days=7, dry_run=True)
    assert "would link 1 attendees" in caplog.text
    _ms_assert_no_values(caplog.text)


# ===================== geocoders (vendor/cm019_preferences) ==================

ADDRESS = "221 Riverside Walk, Acmeton"
VALUE_PARTS = ("221", "Riverside", "Acmeton")
VENUE = "Margaret's Riverside Kitchen"
LAT, LON = "51.123456", "-0.654321"


def _assert_no_values(text, extra=()):
    leaked = [v for v in (*VALUE_PARTS, *extra) if v in text]
    assert not leaked, f"{len(leaked)} synthetic value(s) reached the log"


class _Resp:
    def __init__(self, status, data):
        self.status, self._data = status, data

    async def json(self):
        return self._data

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


class _Session:
    closed = False

    def __init__(self, status=200, data=None, exc=None):
        self.status, self.data, self.exc = status, data, exc

    def get(self, url, params=None):
        if self.exc:
            raise self.exc
        return _Resp(self.status, self.data)


def _geo(session):
    g = Geocoder()
    g.MIN_REQUEST_INTERVAL = 0
    g._session = session
    return g


# --- src/geo/geocoder.py ---------------------------------------------------

def test_geocoder_geo_http_failure_logs_the_status_not_the_address(caplog):
    with caplog.at_level(logging.DEBUG):
        assert asyncio.run(_geo(_Session(status=503)).geocode(ADDRESS)) is None
    assert "HTTP 503" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_geo_no_results_logs_no_address(caplog):
    with caplog.at_level(logging.DEBUG):
        assert asyncio.run(_geo(_Session(data=[])).geocode(ADDRESS)) is None
    assert "no results" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_geo_exception_logs_the_type_not_its_text(caplog):
    exc = ConnectionError("GET https://nominatim.example/search?q=" + ADDRESS)
    with caplog.at_level(logging.DEBUG):
        assert asyncio.run(_geo(_Session(exc=exc)).geocode(ADDRESS)) is None
    assert "ConnectionError" in caplog.text
    _assert_no_values(caplog.text)


# --- src/clients/geocoder.py -----------------------------------------------

def _client(get):
    c = GeocoderClient()
    c._get = get
    return c


def test_geocoder_client_success_logs_neither_the_query_nor_the_coordinates(caplog):
    top = {"lat": LAT, "lon": LON, "display_name": ADDRESS, "type": "house",
           "class": "building", "importance": 0.5, "address": {"road": "Riverside Walk"}}
    with caplog.at_level(logging.DEBUG):
        r = asyncio.run(_client(AsyncMock(return_value=[top])).geocode(ADDRESS, use_bias=False))
    assert r.has_coordinates()
    assert "Geocoded a location: coords=yes" in caplog.text
    _assert_no_values(caplog.text, extra=(LAT, LON, "51.12", "0.65"))


def test_geocoder_client_retry_without_bias_logs_no_query(caplog):
    c = _client(AsyncMock(return_value=[]))
    with caplog.at_level(logging.DEBUG):
        asyncio.run(c.geocode(ADDRESS, use_bias=True))
    assert "retrying without" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_client_cache_hit_logs_no_query(caplog):
    top = {"lat": LAT, "lon": LON, "display_name": ADDRESS, "type": "house",
           "class": "building", "importance": 0.5, "address": {}}
    c = _client(AsyncMock(return_value=[top]))
    asyncio.run(c.geocode(ADDRESS, use_bias=False))
    with caplog.at_level(logging.DEBUG):
        asyncio.run(c.geocode(ADDRESS, use_bias=False))
    assert "Cache hit for geocode" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_client_exception_logs_the_type_not_its_text(caplog):
    exc = RuntimeError("500 for url https://nominatim.example/search?q=" + ADDRESS)
    with caplog.at_level(logging.DEBUG):
        r = asyncio.run(_client(AsyncMock(side_effect=exc)).geocode(ADDRESS, use_bias=False))
    assert r.error
    assert "Error geocoding a location: RuntimeError" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_client_batch_error_logs_no_location(caplog):
    c = GeocoderClient()
    c.geocode = AsyncMock(side_effect=RuntimeError("q=" + ADDRESS))
    with caplog.at_level(logging.DEBUG):
        asyncio.run(c.batch_geocode([ADDRESS]))
    assert "in a batch: RuntimeError" in caplog.text
    _assert_no_values(caplog.text)


def test_geocoder_client_enrich_venue_logs_the_preference_id_not_the_venue(caplog):
    c = GeocoderClient()
    c.geocode = AsyncMock(side_effect=RuntimeError("q=" + VENUE))
    with caplog.at_level(logging.DEBUG):
        asyncio.run(c.enrich_venue("pref-0001", VENUE))
    assert "pref-0001" in caplog.text
    _assert_no_values(caplog.text, extra=(VENUE, "Kitchen"))
