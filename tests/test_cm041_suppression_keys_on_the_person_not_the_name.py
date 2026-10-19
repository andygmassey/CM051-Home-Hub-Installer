"""Vendored copy of CM041 assistant_api/tests/test_suppression_keys_on_the_person_not_the_name.py
(CM041 #222), pointed at the SHIPPED vendor/cm041/assistant_api/ical-server.py.

Marking one person deceased must never silence a living NAMESAKE.

Red-team finding on CM041 #222: the do-not-suggest record was keyed on the
display-name slug, and the slug folds accents, so "Jane Döe" and
"Jane Doe" share ``jane-doe``. Marking the first deceased hid the
second from every proactive surface and marked her deceased on the People
views.

The record is now keyed on the PERSON (``pwg:suppressedPerson <uri>`` for that
person's own identity cluster, plus her exact name and personal identifiers).
A slug alone never suppresses when the record carries a URI, a slug-only
request that names two people is refused with 409, and a legacy slug-only
record is honoured only while its slug names one person.

Fictional cast only: Jane Döe (deceased), Jane Doe (living
namesake), John Smith (control). Reserved example.test addresses.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = Path(os.environ.get("DECEASED_SURFACES_SERVER_FILE")
                   or HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py")


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


def _load():
    spec = importlib.util.spec_from_file_location("ical_server_namesake", SERVER_FILE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


server = _load()

NS = "https://schema.ostler.ai/ontology#"
DEAD = NS + "person_fixture_jane_umlaut"
LIVE = NS + "person_fixture_jane_plain"
CTRL = NS + "person_fixture_control"
DEAD_NAME = "Jane Döe"
LIVE_NAME = "Jane Doe"
CTRL_NAME = "John Smith"
SLUG = server._wiki_slug(DEAD_NAME)
assert SLUG == server._wiki_slug(LIVE_NAME), "fixture premise: the slugs collide"
DEAD_EMAIL = "jane.umlaut" + "@" + "example.test"
LIVE_EMAIL = "jane.plain" + "@" + "example.test"
SHARED_EMAIL = "the.does" + "@" + "example.test"   # one household inbox
NAMES = {DEAD: DEAD_NAME, LIVE: LIVE_NAME, CTRL: CTRL_NAME}
IDS = {DEAD: [("email", DEAD_EMAIL), ("email", SHARED_EMAIL),
              ("icloud_contact_uid", "FIXTURE-UID-DEAD")],
       LIVE: [("email", LIVE_EMAIL), ("email", SHARED_EMAIL),
              ("icloud_contact_uid", "FIXTURE-UID-LIVE")],
       CTRL: []}


def _days_ago(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%d")


def _bday_soon():
    return (datetime.now() + timedelta(days=3)).strftime("%Y-%m-%d")


class Graph:
    """A fake store. ``record`` is the stored SuggestionSuppression (rows in
    the shape the reader selects), or None."""

    def __init__(self, record=None):
        self.record = record or []
        self.updates = []

    def update(self, q):
        self.updates.append(q)

    def __call__(self, q):
        if "SuggestionSuppression" in q:
            return list(self.record)
        if "VALUES ?idv" in q:
            out = []
            for u, ids in IDS.items():
                for _t, v in ids:
                    if '"%s"' % v in q:
                        out.append({"person": u, "idv": v, "name": NAMES[u]})
            return out
        if "VALUES ?v" in q and "identifierValue ?v" in q:  # sharing probe
            out = []
            for u, ids in IDS.items():
                for _t, v in ids:
                    if '"%s"' % v in q:
                        out.append({"v": v, "person": u, "name": NAMES[u]})
            return out
        if "identifierType ?t" in q and "VALUES ?person" in q:
            return [{"t": t, "v": v} for u, ids in IDS.items() if "<%s>" % u in q
                    for (t, v) in ids]
        if '"icloud_contact_uid"' in q and "VALUES ?person" in q:
            return [{"person": u, "v": v} for u, ids in IDS.items() if "<%s>" % u in q
                    for (t, v) in ids if t == "icloud_contact_uid"]
        if '"icloud_contact_uid"' in q:
            return [{"person": u} for u, ids in IDS.items()
                    for (t, v) in ids if t == "icloud_contact_uid" and '"%s"' % v in q]
        if "pwg:organization ?org" in q and "VALUES ?person" in q:
            return []
        if "pwg:birthday ?bday" in q and "?p a pwg:Person" in q:
            return [{"p": u, "name": n, "bday": _bday_soon()} for u, n in NAMES.items()]
        if "pwg:Meeting" in q and "meetingAttendee" in q and "?p pwg:displayName" in q:
            return [{"p": u, "name": n, "summary": "Coffee", "date": _days_ago(2)}
                    for u, n in NAMES.items()]
        if "lastContact" in q and "VALUES" in q:
            return [{"person": u} for u in NAMES]
        if "pwg:displayName ?name" in q and "a pwg:Person" in q and "VALUES" not in q:
            return [{"person": u, "name": n} for u, n in NAMES.items()]
        if "OutstandingTodo" in q and "VALUES ?todo" not in q:
            return [{"todo": "urn:ostler:todo/t1", "action": "post the parcel",
                     "owner": "user", "status": "open", "deadline": _days_ago(-2)}]
        if "VALUES ?todo" in q:
            return [{"todo": "urn:ostler:todo/t1", "about": "urn:ostler:other/" + SLUG}]
        return []


def record_for_dead():
    """The record the endpoint writes for person_uri=DEAD (shape as read)."""
    base = {"s": NS + "suppression_p_x", "slug": SLUG, "reason": "deceased"}
    return [dict(base, person=DEAD, name=DEAD_NAME, idv=DEAD_EMAIL),
            dict(base, person=DEAD, name=DEAD_NAME, idv="FIXTURE-UID-DEAD")]


def record_with_shared_identifier():
    """A record that (from an older write) carries the household email the
    living namesake also holds."""
    return record_for_dead() + [{"s": NS + "suppression_p_x", "slug": SLUG,
                                 "reason": "deceased", "person": DEAD,
                                 "name": DEAD_NAME, "idv": SHARED_EMAIL}]


def legacy_record():
    return [{"s": NS + "suppression_" + SLUG, "slug": SLUG, "reason": "deceased",
             "idv": DEAD_EMAIL}]


class _Resp:
    def __init__(self, p):
        self._b = json.dumps(p).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _qdrant(req, *a, **k):
    url = req.full_url if hasattr(req, "full_url") else str(req)
    lc_ts = int(time.time()) - 148 * 86400
    pts = [{"id": i, "score": 0.9, "payload": {
        "display_name": n, "contact_type": "person", "person_uri": u,
        "last_contact_ts": lc_ts, "last_contact": _days_ago(148), "organization": "",
        "privacy_level": "L1"}} for i, (u, n) in enumerate(NAMES.items())]
    if url.endswith("/points/scroll"):
        return _Resp({"result": {"points": pts, "next_page_offset": None}})
    if url.endswith("/points/search"):
        return _Resp({"result": pts})
    raise AssertionError("unexpected url " + url)


class _Debt:
    def __init__(self, name, uri):
        self.person_name, self.person_uri = name, uri

    def to_dict(self):
        return {"person_name": self.person_name, "person_uri": self.person_uri}


class _Svc:
    debts = []

    @classmethod
    def compute_reply_debts(cls, **_k):
        return list(cls.debts)

    @staticmethod
    def reply_debt_payload(debts):
        return {"count": len(debts), "brief_line": "", "degraded": False,
                "debts": [d.to_dict() for d in debts]}


def surfaces(graph):
    _Svc.debts = [_Debt(DEAD_NAME, DEAD), _Debt(LIVE_NAME, LIVE),
                  _Debt(LIVE_NAME, None)]
    with patch.object(server, "_sparql_select", graph), \
            patch.object(server, "_sparql_update", graph.update), \
            patch.object(server.urllib.request, "urlopen", _qdrant), \
            patch.object(server, "_embed_text", lambda *a, **k: [0.0] * 8), \
            patch.object(server, "_load_people_list_self_uris", lambda: set()), \
            patch.object(server, "_load_reply_debt_service", lambda: _Svc):
        return {
            "stale": [c["name"] for c in server.people_stale(months=3, limit=10)["contacts"]],
            "birthdays": [p["name"] for p in server.people_birthdays(days=14)["people"]],
            "recent": [c["name"] for c in server.people_recent(days=7, limit=10)["contacts"]],
            "suggestions": server.api_suggestions(),
            "reply_debt": server.api_reply_debt()[0],
            "commitments": server.commitments_list(owner="user", status="open")[0],
            "search": server.people_search("jane", limit=5)["results"],
        }


def _by_uri(rows, uri):
    return [r for r in rows if r.get("person_uri") == uri][0]


class TestWriteSide(unittest.TestCase):
    def test_slug_alone_for_two_people_is_409_and_writes_nothing(self):
        g = Graph()
        with patch.object(server, "_sparql_select", g), \
                patch.object(server, "_sparql_update", g.update):
            body, status = server.api_people_suppress_suggestions(
                SLUG, {"suppressed": True, "reason": "deceased"})
        self.assertEqual(status, 409, body)
        self.assertTrue(body["ambiguous"])
        self.assertEqual({c["uri"] for c in body["candidates"]}, {DEAD, LIVE})
        self.assertEqual(g.updates, [], "an ambiguous request wrote a record")

    def test_person_uri_marks_only_that_person(self):
        g = Graph()
        with patch.object(server, "_sparql_select", g), \
                patch.object(server, "_sparql_update", g.update):
            body, status = server.api_people_suppress_suggestions(
                SLUG, {"suppressed": True, "reason": "deceased", "person_uri": DEAD})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["person_uris"], [DEAD])
        ins = [q for q in g.updates if "INSERT DATA" in q]
        self.assertEqual(len(ins), 1)
        self.assertIn("pwg:suppressedPerson <%s>" % DEAD, ins[0])
        self.assertNotIn(LIVE, ins[0], "the living namesake was written into the record")
        self.assertNotIn(LIVE_EMAIL, ins[0])
        self.assertIn(DEAD_EMAIL, ins[0])
        self.assertNotIn(SHARED_EMAIL, ins[0],
                         "an inbox the living namesake also uses keyed the record")

    def test_contact_uid_marks_only_that_card(self):
        g = Graph()
        with patch.object(server, "_sparql_select", g), \
                patch.object(server, "_sparql_update", g.update):
            body, status = server.api_people_suppress_suggestions(
                SLUG, {"suppressed": True, "contact_uid": "FIXTURE-UID-DEAD"})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["person_uris"], [DEAD])

    def test_unknown_person_uri_is_404(self):
        g = Graph()
        with patch.object(server, "_sparql_select", g), \
                patch.object(server, "_sparql_update", g.update):
            _body, status = server.api_people_suppress_suggestions(
                SLUG, {"suppressed": True, "person_uri": NS + "person_nobody"})
        self.assertEqual(status, 404)


class TestReadSide(unittest.TestCase):
    def setUp(self):
        self.o = surfaces(Graph(record_for_dead()))

    def test_stale(self):
        self.assertNotIn(DEAD_NAME, self.o["stale"])
        self.assertIn(LIVE_NAME, self.o["stale"], "the living namesake lost her reconnect card")

    def test_birthdays(self):
        self.assertNotIn(DEAD_NAME, self.o["birthdays"])
        self.assertIn(LIVE_NAME, self.o["birthdays"])

    def test_recent(self):
        self.assertNotIn(DEAD_NAME, self.o["recent"])
        self.assertIn(LIVE_NAME, self.o["recent"])

    def test_suggestions(self):
        s = self.o["suggestions"]
        names = {x["name"] for k in ("birthdays", "reconnect", "follow_up") for x in s[k]}
        self.assertNotIn(DEAD_NAME, names)
        self.assertIn(LIVE_NAME, names)

    def test_reply_debt(self):
        debts = self.o["reply_debt"]["debts"]
        self.assertNotIn(DEAD, [d["person_uri"] for d in debts])
        self.assertIn(LIVE, [d["person_uri"] for d in debts])
        self.assertEqual(sum(1 for d in debts if d["person_name"] == LIVE_NAME), 2,
                         "a URI-less debt from the living namesake was hidden by name")

    def test_commitments(self):
        # A todo about "other:jane-doe" cannot be told apart, so it stays.
        actions = [c["action"] for c in self.o["commitments"]["commitments"]]
        self.assertIn("post the parcel", actions)

    def test_deceased_contract_field(self):
        res = self.o["search"]
        self.assertIs(_by_uri(res, DEAD).get("deceased"), True)
        self.assertNotIn("deceased", _by_uri(res, LIVE))
        self.assertNotIn("suggestions_suppressed", _by_uri(res, LIVE))
        self.assertIn("last_contact", _by_uri(res, LIVE))


class TestSharedIdentifierHidesNobody(unittest.TestCase):
    def test_a_recorded_identifier_the_namesake_also_holds_does_not_hide_her(self):
        o = surfaces(Graph(record_with_shared_identifier()))
        self.assertIn(LIVE_NAME, o["birthdays"])
        self.assertIn(LIVE_NAME, o["stale"])
        self.assertNotIn(DEAD_NAME, o["birthdays"])


class TestLegacyRecord(unittest.TestCase):
    def test_a_legacy_slug_record_for_an_ambiguous_name_hides_nobody_living(self):
        o = surfaces(Graph(legacy_record()))
        self.assertIn(LIVE_NAME, o["birthdays"])
        self.assertIn(LIVE_NAME, o["stale"])

    def test_a_legacy_slug_record_for_one_person_still_works(self):
        saved = dict(NAMES)
        try:
            NAMES.pop(LIVE)
            o = surfaces(Graph(legacy_record()))
            self.assertNotIn(DEAD_NAME, o["birthdays"])
            self.assertIn(CTRL_NAME, o["birthdays"])
        finally:
            NAMES.clear()
            NAMES.update(saved)


if __name__ == "__main__":
    unittest.main()
