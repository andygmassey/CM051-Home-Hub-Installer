"""VENDOR COPY (CM051 graft of CM041 #216 at 8aca5ccc, v1.0.108), run against
vendor/cm041/assistant_api/ical-server.py, the file that ships. Ported from
CM041 assistant_api/tests/test_deceased_excluded_from_proactive_surfaces.py
with every phone number moved to an Ofcom drama range and every address
composed at runtime (the public repo's PII shape scan).

A do-not-suggest person (e.g. deceased) must appear in NO proactive surface,
must STAY excluded across re-sync (a new node) and a merge, and must NEVER hide
a LIVING relative who shares a family line or household email.

Live dignity bug: Ostler surfaced a "Reconnect, 73 months since last contact"
card for an owner's late parent, and their birthday would have surfaced on the
Birthdays strip. Suggesting someone reconnect with, or wish a happy birthday
to, a person who has died is a harm. But so is silencing a LIVING person: if
the deceased's record keyed on a shared family landline or email, marking them
deceased would hide a living relative.

The fix is a DURABLE, IDENTITY-KEYED suppression record
(``pwg:SuggestionSuppression`` keyed on the display-name slug and the person's
PERSONAL identifiers only) written by the endpoint and resolved at READ time by
``_suppressed_identity_index``, which every proactive producer honours.

Design, per Archie review #216 (both rounds):
  * record, not node flag  -> survives merge + re-sync (new-node / merge tests)
  * personal identifiers only (card UID; non-shared phones/emails; never a
    fixed landline) at WRITE time, AND a sharing re-check at READ time
    -> a living relative on the family line/email stays visible.

Synthetic fixtures only -- no real name, slug, phone or email.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import time
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py"


def _install_ostler_security_stub() -> None:
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    database = types.ModuleType("ostler_security.database")
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()

NS = "https://schema.ostler.ai/ontology#"
SUP_URI = NS + "person_fixturesuppressed01"
SUP_URI_2 = NS + "person_fixturesuppressed02"
SUP_NAME = "Margaret Jones"          # the deceased (approved synthetic cast)
SUP_SLUG = server._wiki_slug(SUP_NAME)
SUP_EMAIL = "fixture.suppressed" + "@" + "example.test"
CARD_UID = "FIXTURE-CARD-UID-01"
LANDLINE = "+441134960456"       # Ofcom drama range, fixed line (Leeds)
LANDLINE2 = "+442079460123"      # Ofcom drama range, fixed line (London)
MOBILE = "+447700900789"         # Ofcom drama range, mobile (not fixed)
FAMILY_EMAIL = "family.home" + "@" + "example.test"
CTRL_URI = NS + "person_fixturecontrol01"
CTRL_NAME = "Ben Patel"              # never suppressed
LIVING_URI = NS + "person_livingrelative01"
LIVING_NAME = "Thomas Jones"         # living relative on the family line
LIVING_SLUG = server._wiki_slug(LIVING_NAME)


def _days_ago(n: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%d")


def _near_birthday(days_ahead: int) -> str:
    return (datetime.now() + timedelta(days=days_ahead)).strftime("%Y-%m-%d")


class _FakeResp:
    def __init__(self, payload: dict) -> None:
        self._body = json.dumps(payload).encode()

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# ==========================================================================
# The identity index: new-node, merge survival, and -- critically -- a shared
# identifier must hide NOBODY.
# ==========================================================================
class TestSuppressionIdentityIndex(unittest.TestCase):
    def _fake(self, record_ids, holder_rows):
        """record_ids -> the record's suppressedIdentifier values;
        holder_rows -> rows the identifier-holder query returns
        (list of {person, idv, name})."""
        def fake_sparql_select(sparql):
            if "pwg:SuggestionSuppression" in sparql:
                return [{"slug": SUP_SLUG, "idv": v} for v in record_ids] \
                    or [{"slug": SUP_SLUG}]
            if "VALUES ?idv" in sparql:
                return holder_rows
            return []
        return fake_sparql_select

    def test_a_freshly_resynced_node_for_the_identity_is_suppressed(self):
        """New-node: a fresh person_uri (never flagged) carrying the person's
        own personal identifier, under the same display name, is excluded."""
        fresh = NS + "person_resynced_tonight_99"
        with patch.object(server, "_sparql_select", self._fake(
                [SUP_EMAIL], [{"person": fresh, "idv": SUP_EMAIL, "name": SUP_NAME}])):
            slugs, uris = server._suppressed_identity_index()
        self.assertIn(SUP_SLUG, slugs)
        self.assertIn(fresh, uris, "a re-derived node for a suppressed identity leaked")

    def test_merge_survivor_inheriting_the_identifier_is_suppressed(self):
        """Merge: _merge_oxigraph moves the discard's identifiers onto the
        survivor and canonicalises its name, so the survivor holds the
        personal identifier under the person's name and is excluded."""
        survivor = NS + "person_merge_survivor_keep"
        with patch.object(server, "_sparql_select", self._fake(
                [SUP_EMAIL], [{"person": survivor, "idv": SUP_EMAIL, "name": SUP_NAME}])):
            _slugs, uris = server._suppressed_identity_index()
        self.assertIn(survivor, uris, "suppression did not survive a merge")

    def test_a_shared_identifier_hides_nobody(self):
        """A record identifier also held by a DIFFERENTLY named person (a
        family line / household email) must suppress neither of them via that
        identifier -- the living relative stays out of suppressed_uris."""
        holders = [
            {"person": SUP_URI, "idv": FAMILY_EMAIL, "name": SUP_NAME},
            {"person": LIVING_URI, "idv": FAMILY_EMAIL, "name": LIVING_NAME},
        ]
        with patch.object(server, "_sparql_select", self._fake([FAMILY_EMAIL], holders)):
            slugs, uris = server._suppressed_identity_index()
        self.assertNotIn(LIVING_URI, uris, "a living relative on a shared id was suppressed")
        self.assertNotIn(SUP_URI, uris, "a shared id must contribute nobody")
        self.assertIn(SUP_SLUG, slugs)  # the deceased is still caught by slug

    def test_a_personal_identifier_still_catches_every_node(self):
        holders = [
            {"person": SUP_URI, "idv": SUP_EMAIL, "name": SUP_NAME},
            {"person": SUP_URI_2, "idv": SUP_EMAIL, "name": SUP_NAME},
        ]
        with patch.object(server, "_sparql_select", self._fake([SUP_EMAIL], holders)):
            _slugs, uris = server._suppressed_identity_index()
        self.assertEqual({SUP_URI, SUP_URI_2}, uris)

    def test_index_raises_so_readers_can_fail_closed(self):
        def boom(_sparql):
            raise RuntimeError("oxigraph down (fixture)")
        with patch.object(server, "_sparql_select", boom):
            with self.assertRaises(Exception):
                server._suppressed_identity_index()


# ==========================================================================
# Producers honour the index (patched directly here).
# ==========================================================================
def _fake_qdrant_two_stale():
    lc_ts = int(time.time()) - (148 * 86400)

    def pt(uri, name):
        return {"id": uri, "payload": {
            "display_name": name, "contact_type": "person",
            "last_contact_ts": lc_ts, "last_contact": _days_ago(148),
            "organization": "", "person_uri": uri, "icloud_uid": "CARD-" + name,
        }}

    payload = {"result": {"points": [pt(SUP_URI, SUP_NAME), pt(CTRL_URI, CTRL_NAME)]}}

    def fake_urlopen(req, *a, **k):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "/collections/people/points/scroll" in url:
            return _FakeResp(payload)
        raise AssertionError("unexpected URL: " + url)

    return fake_urlopen


def _stale_recheck_rows(sparql):
    if "lastContact" in sparql:
        return [{"person": SUP_URI}, {"person": CTRL_URI}]
    return []


def _birthday_rows(sparql):
    if "pwg:birthday" in sparql:
        b = _near_birthday(3)
        return [{"p": SUP_URI, "name": SUP_NAME, "bday": b},
                {"p": CTRL_URI, "name": CTRL_NAME, "bday": b}]
    return []


def _meeting_rows(sparql):
    if "pwg:Meeting" in sparql:
        d = _days_ago(3)
        return [{"p": SUP_URI, "name": SUP_NAME, "summary": "Coffee", "date": d},
                {"p": CTRL_URI, "name": CTRL_NAME, "summary": "Lunch", "date": d}]
    return []


_INDEX_HITS_SUP = (set(), {SUP_URI})
_INDEX_EMPTY = (set(), set())


class TestReconnectHonoursIndex(unittest.TestCase):
    def test_suppressed_dropped_control_kept(self):
        with patch.object(server.urllib.request, "urlopen", _fake_qdrant_two_stale()), \
             patch.object(server, "_sparql_select", _stale_recheck_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_HITS_SUP):
            names = [c["name"] for c in server.people_stale(months=3, limit=10)["contacts"]]
        self.assertNotIn(SUP_NAME, names)
        self.assertIn(CTRL_NAME, names)

    def test_no_record_reappears(self):
        with patch.object(server.urllib.request, "urlopen", _fake_qdrant_two_stale()), \
             patch.object(server, "_sparql_select", _stale_recheck_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_EMPTY):
            names = [c["name"] for c in server.people_stale(months=3, limit=10)["contacts"]]
        self.assertIn(SUP_NAME, names)

    def test_index_failure_fails_closed(self):
        def boom():
            raise RuntimeError("index down")
        with patch.object(server.urllib.request, "urlopen", _fake_qdrant_two_stale()), \
             patch.object(server, "_sparql_select", _stale_recheck_rows), \
             patch.object(server, "_suppressed_identity_index", boom):
            res = server.people_stale(months=3, limit=10)
        self.assertEqual(res["contacts"], [])
        self.assertTrue(res["degraded"])


class TestBirthdaysHonoursIndex(unittest.TestCase):
    def test_suppressed_dropped_control_kept(self):
        with patch.object(server, "_sparql_select", _birthday_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_HITS_SUP):
            names = [p["name"] for p in server.people_birthdays(days=14)["people"]]
        self.assertNotIn(SUP_NAME, names)
        self.assertIn(CTRL_NAME, names)

    def test_no_record_reappears(self):
        with patch.object(server, "_sparql_select", _birthday_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_EMPTY):
            names = [p["name"] for p in server.people_birthdays(days=14)["people"]]
        self.assertIn(SUP_NAME, names)


class TestFollowUpHonoursIndex(unittest.TestCase):
    def test_suppressed_dropped_control_kept(self):
        with patch.object(server, "_sparql_select", _meeting_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_HITS_SUP):
            names = [c["name"] for c in server.people_recent(days=14, limit=10)["contacts"]]
        self.assertNotIn(SUP_NAME, names)
        self.assertIn(CTRL_NAME, names)

    def test_no_record_reappears(self):
        with patch.object(server, "_sparql_select", _meeting_rows), \
             patch.object(server, "_suppressed_identity_index", lambda: _INDEX_EMPTY):
            names = [c["name"] for c in server.people_recent(days=14, limit=10)["contacts"]]
        self.assertIn(SUP_NAME, names)


# ==========================================================================
# THE LIVE-HARM GUARANTEE, end to end through the real index: a living relative
# sharing the family landline AND the family email stays VISIBLE in reconnect
# and birthdays, while the deceased is suppressed.
# ==========================================================================
class TestLivingRelativeOnSharedLineStaysVisible(unittest.TestCase):
    def _graph(self, surface_rows_for):
        """One record for the deceased keyed on the shared landline + family
        email; both the deceased and a living relative hold both. Plus the
        surface's own rows."""
        def fake_sparql_select(sparql):
            if "pwg:SuggestionSuppression" in sparql:
                return [{"slug": SUP_SLUG, "idv": LANDLINE},
                        {"slug": SUP_SLUG, "idv": FAMILY_EMAIL}]
            if "VALUES ?idv" in sparql:
                return [
                    {"person": SUP_URI, "idv": LANDLINE, "name": SUP_NAME},
                    {"person": LIVING_URI, "idv": LANDLINE, "name": LIVING_NAME},
                    {"person": SUP_URI, "idv": FAMILY_EMAIL, "name": SUP_NAME},
                    {"person": LIVING_URI, "idv": FAMILY_EMAIL, "name": LIVING_NAME},
                ]
            return surface_rows_for(sparql)
        return fake_sparql_select

    def test_birthdays_keeps_the_living_relative_hides_the_deceased(self):
        b = _near_birthday(3)

        def surface(sparql):
            if "pwg:birthday" in sparql:
                return [{"p": SUP_URI, "name": SUP_NAME, "bday": b},
                        {"p": LIVING_URI, "name": LIVING_NAME, "bday": b}]
            return []

        with patch.object(server, "_sparql_select", self._graph(surface)):
            names = [p["name"] for p in server.people_birthdays(days=14)["people"]]
        self.assertIn(LIVING_NAME, names,
                      "a living relative on the shared family line/email was hidden")
        self.assertNotIn(SUP_NAME, names, "the deceased was not suppressed")

    def test_reconnect_keeps_the_living_relative_hides_the_deceased(self):
        lc_ts = int(time.time()) - (148 * 86400)

        def pt(uri, name):
            return {"id": uri, "payload": {
                "display_name": name, "contact_type": "person",
                "last_contact_ts": lc_ts, "last_contact": _days_ago(148),
                "organization": "", "person_uri": uri, "icloud_uid": "CARD-" + name}}

        qpayload = {"result": {"points": [pt(SUP_URI, SUP_NAME), pt(LIVING_URI, LIVING_NAME)]}}

        def fake_urlopen(req, *a, **k):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if "/collections/people/points/scroll" in url:
                return _FakeResp(qpayload)
            raise AssertionError("unexpected URL")

        def surface(sparql):
            if "lastContact" in sparql:
                return [{"person": SUP_URI}, {"person": LIVING_URI}]
            return []

        with patch.object(server.urllib.request, "urlopen", fake_urlopen), \
             patch.object(server, "_sparql_select", self._graph(surface)):
            names = [c["name"] for c in server.people_stale(months=3, limit=10)["contacts"]]
        self.assertIn(LIVING_NAME, names)
        self.assertNotIn(SUP_NAME, names)


# ==========================================================================
# The owner-settable endpoint writes PERSONAL identifiers only.
# ==========================================================================
class TestSuppressEndpoint(unittest.TestCase):
    def _fake(self):
        def fake_sparql_select(sparql):
            if "pwg:displayName ?name" in sparql and "a pwg:Person" in sparql \
                    and "VALUES" not in sparql:
                return [
                    {"person": SUP_URI, "name": SUP_NAME},
                    {"person": SUP_URI_2, "name": SUP_NAME},
                    {"person": CTRL_URI, "name": CTRL_NAME},
                ]
            if "identifierType ?t" in sparql and "VALUES ?person" in sparql:
                return [
                    {"t": "icloud_contact_uid", "v": CARD_UID},
                    {"t": "phone", "v": LANDLINE},    # fixed -> dropped
                    {"t": "phone", "v": LANDLINE2},   # fixed + unshared -> dropped
                    {"t": "phone", "v": MOBILE},      # mobile, personal -> kept
                    {"t": "email", "v": FAMILY_EMAIL},   # shared -> dropped
                    {"t": "email", "v": SUP_EMAIL},      # personal -> kept
                ]
            if "VALUES ?v" in sparql and "identifierValue ?v" in sparql:
                # Sharing probe: the family line + email are also held by a
                # node outside her cluster (CM041 #222 judges sharing by node,
                # so a namesake counts as "someone else" too). Before: by name.
                # differently-named (living) person; the rest only by her.
                rows = [{"v": CARD_UID, "name": SUP_NAME, "person": SUP_URI},
                        {"v": LANDLINE, "name": SUP_NAME, "person": SUP_URI},
                        {"v": LANDLINE2, "name": SUP_NAME, "person": SUP_URI},
                        {"v": MOBILE, "name": SUP_NAME, "person": SUP_URI},
                        {"v": SUP_EMAIL, "name": SUP_NAME, "person": SUP_URI},
                        {"v": FAMILY_EMAIL, "name": SUP_NAME, "person": SUP_URI},
                        {"v": LANDLINE, "name": LIVING_NAME, "person": LIVING_URI},
                        {"v": FAMILY_EMAIL, "name": LIVING_NAME, "person": LIVING_URI}]
                return rows
            return []
        return fake_sparql_select

    def test_mark_deceased_stores_personal_identifiers_only(self):
        updates = []
        with patch.object(server, "_sparql_select", self._fake()), \
             patch.object(server, "_sparql_update", lambda q: updates.append(q)):
            body, status = server.api_people_suppress_suggestions(
                SUP_SLUG, {"suppressed": True, "reason": "deceased"})
        self.assertEqual(status, 200)
        self.assertTrue(body["record_written"])
        self.assertEqual(body["nodes_matched"], 2)
        inserts = [q for q in updates if "INSERT DATA" in q]
        self.assertEqual(len(inserts), 1)
        rec = inserts[0]
        self.assertIn("pwg:SuggestionSuppression", rec)
        self.assertIn('pwg:suppressedSlug "%s"' % SUP_SLUG, rec)
        # kept: card UID, personal mobile, personal email
        self.assertIn(CARD_UID, rec)
        self.assertIn(MOBILE, rec)
        self.assertIn(SUP_EMAIL, rec)
        # dropped: fixed landlines (both) and the shared family email
        self.assertNotIn(LANDLINE, rec)
        self.assertNotIn(LANDLINE2, rec)
        self.assertNotIn(FAMILY_EMAIL, rec)
        self.assertEqual(body["identifiers_recorded"], 3)

    def test_unsuppress_clears_record_without_insert(self):
        updates = []
        with patch.object(server, "_sparql_select", self._fake()), \
             patch.object(server, "_sparql_update", lambda q: updates.append(q)):
            body, status = server.api_people_suppress_suggestions(
                SUP_SLUG, {"suppressed": False})
        self.assertEqual(status, 200)
        self.assertTrue(body["record_cleared"])
        self.assertFalse(any("INSERT DATA" in q for q in updates))
        self.assertTrue(any("DELETE WHERE" in q for q in updates))

    def test_unknown_slug_records_the_slug_and_reports_zero_nodes(self):
        updates = []
        with patch.object(server, "_sparql_select", self._fake()), \
             patch.object(server, "_sparql_update", lambda q: updates.append(q)):
            body, status = server.api_people_suppress_suggestions(
                "nobody-here", {"suppressed": True})
        self.assertEqual(status, 200)
        self.assertEqual(body["nodes_matched"], 0)
        self.assertTrue(body["record_written"])
        self.assertTrue(any('pwg:suppressedSlug "nobody-here"' in q for q in updates))


class TestFixedLineGuard(unittest.TestCase):
    def test_geographic_numbers_are_fixed_mobile_is_not(self):
        try:
            import phonenumbers  # noqa: F401
        except Exception:
            self.skipTest("phonenumbers not installed")
        self.assertTrue(server._is_fixed_line(LANDLINE))
        self.assertTrue(server._is_fixed_line(LANDLINE2))
        self.assertFalse(server._is_fixed_line(MOBILE))


if __name__ == "__main__":
    unittest.main()
