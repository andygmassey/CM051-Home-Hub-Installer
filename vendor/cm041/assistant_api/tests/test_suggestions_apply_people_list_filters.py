"""Regression test (vendor graft): the suggestion producers never applied
the People-list filters (walk #6 candidate #10, Archie).

Live bug: the phone's People tab reads /api/v1/suggestions, which composites
people_birthdays() + people_stale() + people_recent() (api_suggestions's own
"reconnect"/"follow_up" aliases).

This vendor tree is AHEAD of CM041 source on part of this already:
people_stale and people_birthdays already call this vendor's OWN
_is_not_a_person_to_suggest (exact USER_NAME string match + "#..."/address
shapes) and _is_service_sender (a fixed brand denylist + all-role-mailbox
address lists). people_recent had NEITHER mechanism at all. Neither
existing check is card-gated, and neither reaches an owner identified by
email/phone rather than an exact USER_NAME string match, or a shape
(notification phrasing, marketplace brand, ebill-style mailbox) outside
the fixed denylist -- which is what this graft adds, as a SECOND,
additive layer, not a replacement.

USER_NAME (the module-level global _is_not_a_person_to_suggest reads) is
captured once at import time from the environment this test process
actually has, which is empty -- so in this suite that arm is naturally
inert, and the owner-dropped tests below isolate the NEW
_load_people_list_self_uris contribution specifically (an owner node
identified by email, shown under a DIFFERENT display name). The
service-mailbox tests use a shape _is_service_sender's denylist does NOT
cover (an ebill-style local part, no brand) rather than a bare email --
EVERY bare email is already caught by _is_not_a_person_to_suggest's own
address rule in this vendor tree, so a bare no-reply@ fixture would pass
whether or not this graft's own service-mailbox check ever ran.

Synthetic names only (Jane Doe / Acme Corp / John Smith -- already in the
approved synthetic cast used elsewhere in this test suite); no real
company, no box.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types
import typing
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    """Ported from the sibling test_people_list_endpoint.py's stub: this
    vendor tree's ical-server.py also hard-imports ostler_security.db_key,
    not just .database/.posture."""
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg

    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod

    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod

    db_key_mod = types.ModuleType("ostler_security.db_key")
    db_key_mod.SOURCE_ENV = "OSTLER_DB_KEY"
    db_key_mod.SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
    db_key_mod.REASON_NO_KEY = "no_key"

    class _DbKey(typing.NamedTuple):
        key: typing.Optional[str]
        source: typing.Optional[str]
        reason: typing.Optional[str]
        detail: typing.Optional[str]

    db_key_mod.DbKey = _DbKey
    db_key_mod.resolve_db_key = lambda: _DbKey(None, None, "no_key", None)
    sys.modules["ostler_security.db_key"] = db_key_mod


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server_suggestions_vendored", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()

_OWNER_URI = "https://schema.ostler.ai/ontology#person_fixtureowner01"
# Deliberately NOT the string this vendor's _is_not_a_person_to_suggest
# would match against USER_NAME (that global is frozen empty at import
# time in this test process anyway) -- shown under an ordinary-looking
# display name so the owner-dropped tests below prove the NEW
# _load_people_list_self_uris (email-identified) contribution, not the
# pre-existing exact-name check.
_OWNER_NAME = "Alice Example"
_OWNER_EMAIL = "owner" + "@example.com"
_ORG_URI = "https://schema.ostler.ai/ontology#person_fixtureorg01"
_ORG_NAME = "Acme Corp Notifications"
# NOT a bare email: this vendor's own _is_not_a_person_to_suggest already
# drops ANY "contains @, no space" name unconditionally, so a bare
# no-reply@ fixture would pass whether or not this graft's own
# _is_service_mailbox_name ever ran. An ebill-style local part with a
# SPACE-FREE but non-"@"-shaped... no such shape exists for an email; this
# vendor's blanket address rule genuinely subsumes _is_service_mailbox_name
# for every email-shaped case. Recorded here and in the PR, not hidden:
# this one still proves the END STATE (dropped), just not in isolation
# from the pre-existing check.
_MAILBOX_URI = "https://schema.ostler.ai/ontology#person_fixturemailbox01"
_MAILBOX_NAME = "ebillnotice" + "@example.com"
_HUMAN_URI = "https://schema.ostler.ai/ontology#person_fixturehuman01"
_HUMAN_NAME = "John Smith"


def _in_n_days(n: int) -> str:
    return (datetime.now() + timedelta(days=n)).strftime("%m-%d")


def _today_minus(n: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%d")


def _sparql_dispatch(*, self_email_rows=None, carded_rows=None, extra=None):
    """One dispatcher reused across all three producers: routes on query
    SHAPE, same style as this suite's existing stale-recheck fixtures.
    `extra` handles the producer's OWN query (birthday / meeting), keyed
    by a substring unique to that producer's SPARQL text."""
    def fake(query):
        if "icloud_contact_uid" in query:
            return carded_rows or []
        if "pwg:birthday" in query:
            return (extra or {}).get("birthday", [])
        if "pwg:meetingAttendee" in query:
            return (extra or {}).get("meeting", [])
        if 'identifierType "email"' in query:
            return self_email_rows or []
        return []
    return fake


class _OwnerEnv:
    """Sets USER_EMAIL for the duration of a test (_load_people_list_self_
    uris's email-match arm reads it dynamically on every call, unlike the
    module-level USER_NAME global _is_not_a_person_to_suggest reads once
    at import time), and makes sure no OTHER test accidentally inherits
    it."""

    def __enter__(self):
        self._patcher = patch.dict(os.environ, {"USER_EMAIL": _OWNER_EMAIL}, clear=False)
        self._patcher.start()
        return self

    def __exit__(self, *exc):
        self._patcher.stop()
        return False


class TestBirthdaysAppliesPeopleListFilters(unittest.TestCase):
    def test_owner_birthday_is_dropped(self):
        rows = [{"p": _OWNER_URI, "name": _OWNER_NAME, "bday": _in_n_days(2)}]
        with _OwnerEnv(), patch.object(
            server, "_sparql_select",
            _sparql_dispatch(
                self_email_rows=[{"p": _OWNER_URI, "value": _OWNER_EMAIL}],
                extra={"birthday": rows},
            ),
        ):
            result = server.people_birthdays(days=7)
        names = [p["name"] for p in result.get("people", [])]
        self.assertNotIn(_OWNER_NAME, names)

    def test_org_named_uncarded_birthday_is_dropped(self):
        rows = [{"p": _ORG_URI, "name": _ORG_NAME, "bday": _in_n_days(2)}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[], extra={"birthday": rows}),
        ):
            result = server.people_birthdays(days=7)
        names = [p["name"] for p in result.get("people", [])]
        self.assertNotIn(_ORG_NAME, names)

    def test_service_mailbox_uncarded_birthday_is_dropped(self):
        """NOT an isolating test for this producer -- passes on unmodified
        code too, measured by this file's own RED check: this vendor's
        pre-existing _is_not_a_person_to_suggest already drops ANY
        '@'-shaped, no-space name unconditionally, which strictly subsumes
        _is_service_mailbox_name for every email-shaped case here. Kept as
        a CONTROL that the end state stays correct, not as proof this
        graft's own check did the work -- see the module docstring."""
        rows = [{"p": _MAILBOX_URI, "name": _MAILBOX_NAME, "bday": _in_n_days(2)}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[], extra={"birthday": rows}),
        ):
            result = server.people_birthdays(days=7)
        names = [p["name"] for p in result.get("people", [])]
        self.assertNotIn(_MAILBOX_NAME, names)

    def test_carded_human_birthday_stays(self):
        rows = [{"p": _HUMAN_URI, "name": _HUMAN_NAME, "bday": _in_n_days(2)}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[{"person": _HUMAN_URI}], extra={"birthday": rows}),
        ):
            result = server.people_birthdays(days=7)
        names = [p["name"] for p in result.get("people", [])]
        self.assertIn(_HUMAN_NAME, names)


class TestRecentMeetingsAppliesPeopleListFilters(unittest.TestCase):
    def test_owner_meeting_is_dropped(self):
        rows = [{"p": _OWNER_URI, "name": _OWNER_NAME, "summary": "Sync",
                 "date": _today_minus(1), "location": ""}]
        with _OwnerEnv(), patch.object(
            server, "_sparql_select",
            _sparql_dispatch(
                self_email_rows=[{"p": _OWNER_URI, "value": _OWNER_EMAIL}],
                extra={"meeting": rows},
            ),
        ):
            result = server.people_recent(days=7, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_OWNER_NAME, names)

    def test_org_named_uncarded_meeting_is_dropped(self):
        rows = [{"p": _ORG_URI, "name": _ORG_NAME, "summary": "Renewal call",
                 "date": _today_minus(1), "location": ""}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[], extra={"meeting": rows}),
        ):
            result = server.people_recent(days=7, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_ORG_NAME, names)

    def test_service_mailbox_uncarded_meeting_is_dropped(self):
        rows = [{"p": _MAILBOX_URI, "name": _MAILBOX_NAME, "summary": "",
                 "date": _today_minus(1), "location": ""}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[], extra={"meeting": rows}),
        ):
            result = server.people_recent(days=7, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_MAILBOX_NAME, names)

    def test_carded_human_meeting_stays(self):
        rows = [{"p": _HUMAN_URI, "name": _HUMAN_NAME, "summary": "Catch-up",
                 "date": _today_minus(1), "location": ""}]
        with patch.object(
            server, "_sparql_select",
            _sparql_dispatch(carded_rows=[{"person": _HUMAN_URI}], extra={"meeting": rows}),
        ):
            result = server.people_recent(days=7, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertIn(_HUMAN_NAME, names)


class _FakeResp:
    def __init__(self, payload: dict) -> None:
        self._body = json.dumps(payload).encode()

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_qdrant_scroll(name: str, uri: str, *, icloud_uid: str = "", stale_days: int = 148):
    lc_ts = int(datetime.now(timezone.utc).timestamp()) - (stale_days * 86400)
    payload = {
        "result": {
            "points": [{
                "id": "fixture-1",
                "payload": {
                    "display_name": name,
                    "contact_type": "person",
                    "last_contact_ts": lc_ts,
                    "last_contact": _today_minus(stale_days),
                    "organization": "",
                    "person_uri": uri,
                    "icloud_uid": icloud_uid,
                },
            }],
        }
    }

    def fake_urlopen(req, *args, **kwargs):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "/collections/people/points/scroll" in url:
            return _FakeResp(payload)
        raise AssertionError(f"unexpected URL in test: {url}")

    return fake_urlopen


def _sparql_no_recent_contact_in_graph(self_email_rows=None):
    """Graph recheck returns nothing recent for any URI, so Qdrant's own
    (stale) last_contact_ts stands -- isolates the People-list filters
    under test from people_stale's separate graph-recheck behaviour.
    people_stale's self_uris check reads person_uri straight off the
    Qdrant payload (unlike people_recent/people_birthdays), so the only
    _sparql_select shape it needs here is _load_people_list_self_uris's
    own email-identifier lookup."""
    def fake(query):
        if 'identifierType "email"' in query:
            return self_email_rows or []
        return []
    return fake


class TestStaleContactsAppliesPeopleListFilters(unittest.TestCase):
    def test_owner_stale_contact_is_dropped(self):
        with _OwnerEnv(), \
             patch.object(server.urllib.request, "urlopen",
                           _fake_qdrant_scroll(_OWNER_NAME, _OWNER_URI)), \
             patch.object(server, "_sparql_select",
                           _sparql_no_recent_contact_in_graph(
                               self_email_rows=[{"p": _OWNER_URI, "value": _OWNER_EMAIL}])):
            result = server.people_stale(months=3, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_OWNER_NAME, names)

    def test_org_named_uncarded_stale_contact_is_dropped(self):
        with patch.object(server.urllib.request, "urlopen",
                           _fake_qdrant_scroll(_ORG_NAME, _ORG_URI)), \
             patch.object(server, "_sparql_select",
                           _sparql_no_recent_contact_in_graph()):
            result = server.people_stale(months=3, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_ORG_NAME, names)

    def test_service_mailbox_uncarded_stale_contact_is_dropped(self):
        """NOT an isolating test -- see the identical note on
        test_service_mailbox_uncarded_birthday_is_dropped. people_stale
        also already calls _is_not_a_person_to_suggest, which subsumes
        this shape."""
        with patch.object(server.urllib.request, "urlopen",
                           _fake_qdrant_scroll(_MAILBOX_NAME, _MAILBOX_URI)), \
             patch.object(server, "_sparql_select",
                           _sparql_no_recent_contact_in_graph()):
            result = server.people_stale(months=3, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertNotIn(_MAILBOX_NAME, names)

    def test_carded_human_stale_contact_stays(self):
        with patch.object(server.urllib.request, "urlopen",
                           _fake_qdrant_scroll(_HUMAN_NAME, _HUMAN_URI,
                                                icloud_uid="00000000-0000-0000-0000-000000000005:ABPerson")), \
             patch.object(server, "_sparql_select",
                           _sparql_no_recent_contact_in_graph()):
            result = server.people_stale(months=3, limit=5)
        names = [c["name"] for c in result.get("contacts", [])]
        self.assertIn(_HUMAN_NAME, names)


if __name__ == "__main__":
    unittest.main()
