"""Vendored copy of CM041 assistant_api/tests/test_deceased_person_surfaces.py
(CM041 #222), pointed at the SHIPPED vendor/cm041/assistant_api/ical-server.py.

A person the owner marked DECEASED keeps their page, but no output reads as
an ongoing relationship or a prompt to act.

The proactive producers already drop a suppressed person (CM041 #216 and the
identity-keyed rework; see test_deceased_excluded_from_proactive_surfaces.py).
This file covers the outputs #216 left alone:

  * owner's own views (People list, search, person context, person card
    enrichment, person timeline): the person STAYS, marked
    ``deceased: true`` + ``suggestions_suppressed: true``, with every
    last-contact / recency / birthday / warmth key removed and the
    per-channel "Last email contact" timeline markers gone. Meetings and
    conversations stay: history is readable.
  * act-prompt outputs #216 did not reach: reply debt ("X is waiting on
    you") and open commitments shown as due.
  * the suggestions composite: a fail-closed producer surfaces as
    ``degraded``, never as an empty "nothing to do" list.

A DO-NOT-SUGGEST person (any other reason) is marked
``suggestions_suppressed`` but keeps their factual fields.

Every surface also fails CLOSED: an unreadable suppression record withholds
the act-prompt keys and says ``suppression_check: unavailable``.

The contract fixture tests/fixtures/deceased_person_contract.json is the
shape CM031 iOS and the ostler-assistant chat context decode; it is checked
against the real handler output here.

Synthetic cast only: Margaret Jones (deceased), Jane Doe (do-not-suggest),
John Smith (living control). Reserved example.test / Ofcom drama numbers.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = Path(os.environ.get("DECEASED_SURFACES_SERVER_FILE")
                   or HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
CONTRACT = HERE.parent / "vendor" / "cm041" / "assistant_api" / "tests" / "fixtures" / "deceased_person_contract.json"


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
    spec = importlib.util.spec_from_file_location("ical_server_deceased", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()

NS = "https://schema.ostler.ai/ontology#"
DEAD_NAME = "Margaret Jones"
DEAD_URI = NS + "person_fixturedeceased01"
DNS_NAME = "Jane Doe"
DNS_URI = NS + "person_fixturedonotsuggest01"
LIVE_NAME = "John Smith"
LIVE_URI = NS + "person_fixtureliving01"
DEAD_EMAIL = "margaret.fixture" + "@" + "example.test"

ACT_KEYS = (
    "last_contact", "last_contact_by_source", "recency", "birthday",
    "relationship_signal", "months_since_contact",
)


def _days_ago(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%d")


def _bday_soon():
    return "1941-" + (datetime.now() + timedelta(days=3)).strftime("%m-%d")


PEOPLE = {
    DEAD_URI: DEAD_NAME,
    DNS_URI: DNS_NAME,
    LIVE_URI: LIVE_NAME,
}
SUPPRESSIONS = [  # (slug, reason, identifier)
    (server._wiki_slug(DEAD_NAME), "Deceased", DEAD_EMAIL),
    (server._wiki_slug(DNS_NAME), "user_request", None),
]


def _person_row(uri, name):
    return {
        "person": uri, "name": name, "rel": "Mother" if uri == DEAD_URI else "Friend",
        "bday": _bday_soon(), "lcEmail": _days_ago(400), "lcIMessage": _days_ago(420),
    }


class Store:
    """A fake Oxigraph that answers each handler's query shape, and a switch
    to make the suppression record unreadable."""

    def __init__(self, suppression_down=False, with_records=True):
        self.suppression_down = suppression_down
        self.with_records = with_records

    def __call__(self, q):
        if "SuggestionSuppression" in q:
            if self.suppression_down:
                raise RuntimeError("oxigraph unreachable (fixture)")
            if not self.with_records:
                return []
            if "?reason" in q:
                return [{"slug": s, "reason": r} for (s, r, _i) in SUPPRESSIONS]
            return [dict({"slug": s}, **({"idv": i} if i else {}))
                    for (s, _r, i) in SUPPRESSIONS]
        if "VALUES ?idv" in q:
            return [{"person": DEAD_URI, "idv": DEAD_EMAIL, "name": DEAD_NAME}]
        if "VALUES ?p " in q or "VALUES ?p{" in q:
            return [{"p": u, "name": n} for u, n in PEOPLE.items() if "<%s>" % u in q]
        if "VALUES ?todo" in q:
            return [
                {"todo": "urn:ostler:todo/t-dead", "about": "urn:ostler:other/margaret-jones"},
                {"todo": "urn:ostler:todo/t-mixed", "about": "urn:ostler:other/margaret-jones"},
                {"todo": "urn:ostler:todo/t-mixed", "about": "urn:ostler:other/john-smith"},
                {"todo": "urn:ostler:todo/t-live", "about": "urn:ostler:other/john-smith"},
            ]
        if "OutstandingTodo" in q:
            return [
                {"todo": "urn:ostler:todo/t-dead", "action": "share the photo album",
                 "owner": "user", "status": "open", "deadline": _days_ago(-2)},
                {"todo": "urn:ostler:todo/t-mixed", "action": "book the family lunch",
                 "owner": "user", "status": "open", "deadline": _days_ago(-3)},
                {"todo": "urn:ostler:todo/t-live", "action": "return the borrowed drill",
                 "owner": "user", "status": "open", "deadline": _days_ago(-4)},
            ]
        if "FILTER(CONTAINS(LCASE(?name)" in q or "FILTER(CONTAINS(LCASE(?matched)" in q:
            for uri, name in PEOPLE.items():
                if name.lower().split()[0] in q.lower():
                    return [dict(_person_row(uri, name), matched=name)]
            return []
        if "SELECT ?person ?name WHERE" in q:
            return [{"person": u, "name": n} for u, n in PEOPLE.items()]
        if "pwg:birthday ?bday" in q:
            for uri, name in PEOPLE.items():
                if "<%s>" % uri in q:
                    r = _person_row(uri, name)
                    r.pop("person")
                    return [r]
            return []
        if "SELECT ?lcEmail ?lcWhatsApp ?lcIMessage" in q:
            return [{"lcEmail": _days_ago(400), "lcIMessage": _days_ago(420)}]
        if "urn:ostler:warmth" in q:
            return [{"warmth": "0.2", "trust": "0.9", "observedAt": _days_ago(400),
                     "spriv": "L1"}]
        if "pwg:Meeting" in q and "meetingAttendee" in q:
            return [{"summary": "Sunday lunch", "date": _days_ago(500),
                     "location": "Home", "m": NS + "meeting_fixture01"}]
        return []


def _qdrant_points():
    out = []
    for i, (uri, name) in enumerate(PEOPLE.items()):
        out.append({"id": i + 1, "score": 0.9, "payload": {
            "display_name": name, "person_uri": uri, "contact_type": "person",
            "relationship": "Mother" if uri == DEAD_URI else "Friend",
            "last_contact": _days_ago(400), "privacy_level": "L1",
            "last_contact_ts": int((datetime.now(timezone.utc) - timedelta(days=30)).timestamp()),
            "emails": [DEAD_EMAIL] if uri == DEAD_URI else [],
            "phones": [],
        }})
    return out


class _Resp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _fake_urlopen(req, timeout=None):
    url = req.full_url if hasattr(req, "full_url") else str(req)
    if url.endswith("/points/search"):
        return _Resp({"result": _qdrant_points()})
    if url.endswith("/points/scroll"):
        return _Resp({"result": {"points": _qdrant_points(), "next_page_offset": None}})
    raise RuntimeError("unexpected url in fixture: " + url)


class _Debt:
    def __init__(self, name, uri):
        self.person_name = name
        self.person_uri = uri

    def to_dict(self):
        return {"person_name": self.person_name, "person_uri": self.person_uri,
                "waiting_human": "3 days"}


class _DebtService:
    @staticmethod
    def compute_reply_debts(**_kw):
        return [_Debt(DEAD_NAME, DEAD_URI), _Debt(DNS_NAME, None),
                _Debt(LIVE_NAME, LIVE_URI)]

    @staticmethod
    def reply_debt_payload(debts):
        return {"count": len(debts),
                "brief_line": "; ".join(d.person_name + " is waiting on you" for d in debts),
                "debts": [d.to_dict() for d in debts], "degraded": False}


def _resolve_by_slug(slug):
    """The vendored tree resolves a slug merge-aware through this helper;
    the upstream tree recomputes it inline from the SELECT the Store answers.
    Either way a slug maps to the same synthetic person."""
    for uri, name in PEOPLE.items():
        if server._wiki_slug(name) == slug:
            return uri, name
    return None, ""


def run_surfaces(store):
    """Call every real handler against ``store``. Returns {surface: output}."""
    out = {}
    with patch.object(server, "_sparql_select", store), \
            patch.object(server, "_embed_text", lambda *a, **k: [0.0] * 8), \
            patch.object(server.urllib.request, "urlopen", _fake_urlopen), \
            patch.object(server, "_load_people_list_self_uris", lambda: set()), \
            patch.object(server, "_load_reply_debt_service", lambda: _DebtService), \
            patch.object(server, "_resolve_person_by_slug", _resolve_by_slug, create=True):
        def call(name, fn):
            try:
                r = fn()
                out[name] = r[0] if isinstance(r, tuple) else r
            except Exception as exc:  # recorded, never swallowed silently
                out[name] = {"_raised": f"{type(exc).__name__}: {exc}"}
        call("people_list", lambda: server.people_list(sort="recency"))
        call("people_search", lambda: server.people_search("margaret", limit=5))
        call("person_context", lambda: server.person_context("Margaret"))
        call("person_enrichment", lambda: server.person_enrichment("margaret-jones"))
        call("person_timeline", lambda: server.person_timeline("margaret-jones"))
        call("reply_debt", lambda: server.api_reply_debt())
        call("commitments", lambda: server.commitments_list(owner="user", status="open"))
        call("suggestions", lambda: server.api_suggestions())
    return out


def _row(rows, name):
    for r in rows:
        if r.get("name") == name:
            return r
    return None


def _assert_softened(tc, entry, where):
    tc.assertIsNotNone(entry, f"{where}: the deceased person must stay visible")
    tc.assertIs(entry.get("deceased"), True, f"{where}: no deceased marker")
    tc.assertIs(entry.get("suggestions_suppressed"), True, where)
    for k in ACT_KEYS:
        tc.assertNotIn(k, entry, f"{where}: {k} still shown for a deceased person")


class TestDeceasedOnOwnerViews(unittest.TestCase):
    def setUp(self):
        self.o = run_surfaces(Store())

    def test_people_list(self):
        rows = self.o["people_list"]["people"]
        _assert_softened(self, _row(rows, DEAD_NAME), "people_list")
        live = _row(rows, LIVE_NAME)
        self.assertIn("recency", live, "control: a living person keeps recency")
        self.assertNotIn("deceased", live)
        dns = _row(rows, DNS_NAME)
        self.assertIs(dns.get("suggestions_suppressed"), True)
        self.assertNotIn("deceased", dns)
        self.assertIn("recency", dns, "do-not-suggest keeps factual fields")

    def test_people_search(self):
        rows = self.o["people_search"]["results"]
        _assert_softened(self, _row(rows, DEAD_NAME), "people_search")
        self.assertIn("relationship", _row(rows, DEAD_NAME), "how they are related stays")
        self.assertIn("last_contact", _row(rows, LIVE_NAME), "control")

    def test_person_context(self):
        ctx = self.o["person_context"]
        _assert_softened(self, ctx.get("person"), "person_context.person")
        _assert_softened(self, ctx, "person_context flat")
        self.assertEqual(ctx.get("relationship"), "Mother")

    def test_person_enrichment(self):
        en = self.o["person_enrichment"]
        _assert_softened(self, en.get("person"), "person_enrichment.person")
        _assert_softened(self, en, "person_enrichment flat")

    def test_person_timeline(self):
        tl = self.o["person_timeline"]
        self.assertIs(tl["person"].get("deceased"), True)
        self.assertFalse([e for e in tl["events"] if e.get("marker")],
                         "a 'Last email contact' marker is still shown")
        self.assertTrue([e for e in tl["events"] if not e.get("marker")],
                        "history (meetings) must stay readable")

    def test_contract_fixture_matches_the_real_handler(self):
        contract = json.loads(CONTRACT.read_text())
        en = self.o["person_enrichment"]["person"]
        for k, v in contract["deceased_person"]["must_have"].items():
            self.assertEqual(en.get(k), v, k)
        for k in contract["deceased_person"]["must_not_have"]:
            self.assertNotIn(k, en, k)
        self.assertEqual(set(contract["deceased_person"]["must_not_have"]),
                         set(server._DECEASED_OMIT_KEYS))


class TestDeceasedOnActPrompts(unittest.TestCase):
    def setUp(self):
        self.o = run_surfaces(Store())

    def test_reply_debt(self):
        rd = self.o["reply_debt"]
        names = [d["person_name"] for d in rd["debts"]]
        self.assertNotIn(DEAD_NAME, names)
        self.assertNotIn(DNS_NAME, names)
        self.assertIn(LIVE_NAME, names, "control")
        self.assertEqual(rd["count"], 1)
        self.assertNotIn(DEAD_NAME, rd["brief_line"])

    def test_commitments(self):
        cm = self.o["commitments"]
        actions = [c["action"] for c in cm["commitments"]]
        self.assertNotIn("share the photo album", actions)
        self.assertIn("book the family lunch", actions, "a todo with a living person stays")
        self.assertIn("return the borrowed drill", actions, "control")


class TestFailClosed(unittest.TestCase):
    def setUp(self):
        self.o = run_surfaces(Store(suppression_down=True))

    def test_owner_views_withhold_act_keys(self):
        for r in self.o["people_list"]["people"]:
            self.assertNotIn("recency", r)
        self.assertTrue(self.o["people_list"].get("degraded"))
        for r in self.o["people_search"]["results"]:
            self.assertNotIn("last_contact", r)
            self.assertEqual(r.get("suppression_check"), "unavailable")
        self.assertNotIn("birthday", self.o["person_context"].get("person", {}))
        self.assertNotIn("last_contact", self.o["person_enrichment"].get("person", {}))
        self.assertFalse([e for e in self.o["person_timeline"]["events"] if e.get("marker")])

    def test_act_prompts_degrade(self):
        self.assertEqual(self.o["reply_debt"]["debts"], [])
        self.assertTrue(self.o["reply_debt"]["degraded"])
        self.assertEqual(self.o["commitments"]["commitments"], [])
        self.assertTrue(self.o["commitments"]["degraded"])
        self.assertTrue(self.o["suggestions"].get("degraded"),
                        "a fail-closed producer read as 'nothing to suggest'")


class TestNoRecordsChangesNothing(unittest.TestCase):
    """Negative control: with no suppression record, every person keeps
    every field, so the marker is caused by the record and nothing else."""

    def test_no_marker_without_a_record(self):
        o = run_surfaces(Store(with_records=False))
        dead = _row(o["people_search"]["results"], DEAD_NAME)
        self.assertNotIn("deceased", dead)
        self.assertIn("last_contact", dead)
        self.assertIn("recency", _row(o["people_list"]["people"], DEAD_NAME))
        self.assertIn(DEAD_NAME, [d["person_name"] for d in o["reply_debt"]["debts"]])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--dump":
        print(json.dumps(run_surfaces(Store()), indent=2, sort_keys=True, default=str))
    else:
        unittest.main()
