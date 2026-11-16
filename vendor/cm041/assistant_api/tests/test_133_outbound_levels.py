"""133 outbound privacy rule, at every outbound reader that carries an
explicit privacy level.

Rule (Archie, 2026-11-16): anything served to the assistant for channel
replies or briefs, or sent off the box, passes ONLY L1, L2 and untagged.
L0 (owner-private on the PWG scale), L3 and unparseable values are withheld.

Sites covered:
  - ical-server.py people_search (person-level privacy_level)
  - ical-server.py commitments_list (/api/v1/commitments, per-todo level)
  - ical-server.py api_reply_debt (/api/v1/reply-debt, per-thread level)
  - derived_preferences.py SERVED_PRIVACY_LEVELS (/api/v1/preferences/derived)

Every fixture is synthetic: reserved names, no real people, no real data.
Each site carries an explicit L0 item and an explicit L3 item, plus an L2
control that must still be served so the test cannot pass by serving nothing.
"""

import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"

import sys  # noqa: E402

if str(HERE.parent) not in sys.path:
    sys.path.insert(0, str(HERE.parent))

# ical-server.py has a dash in its name; load it the same way the sibling
# endpoint tests do. The stubs for ostler_security are installed by the
# sibling test modules, so guard the import the same way they do.
def _load_server():
    spec = importlib.util.spec_from_file_location("ical_server_133", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server()

from derived_preferences import (  # noqa: E402
    DerivedGraphReader,
    build_derived_preferences_response,
)


class _FakeResp:
    def __init__(self, payload):
        self._body = __import__("json").dumps(payload).encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_urlopen(search_payload):
    def fake(req, *args, **kwargs):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "/api/embed" in url:
            return _FakeResp({"embeddings": [[0.0, 0.0, 0.0]]})
        if "/points/search" in url:
            return _FakeResp(search_payload)
        raise AssertionError("unexpected URL in test: " + url)
    return fake


def _person_hit(i, name, privacy_level=None):
    payload = {
        "display_name": name,
        "contact_type": "person",
        "person_uri": "urn:ostler:person/synthetic-%d" % i,
        "facts": [],
    }
    if privacy_level is not None:
        payload["privacy_level"] = privacy_level
    return {"id": "p%d" % i, "score": 0.9 - i * 0.01, "payload": payload}


class TestPeopleSearchOutbound(unittest.TestCase):
    NAMES = {
        "L0": "Jane Doe",
        "L3": "Bob Smith",
        "L2": "Ana Jones",
        "untagged": "Ben Ross",
        "unparseable": "Carl Coe",
    }

    def _names_served(self):
        hits = [
            _person_hit(0, self.NAMES["L0"], "L0"),
            _person_hit(1, self.NAMES["L3"], "L3"),
            _person_hit(2, self.NAMES["L2"], "L2"),
            _person_hit(3, self.NAMES["untagged"]),
            _person_hit(4, self.NAMES["unparseable"], "bogus"),
        ]
        with patch.object(server.urllib.request, "urlopen",
                          _fake_urlopen({"result": hits})):
            body = server.people_search("synthetic", limit=10)
        return [r["name"] for r in body["results"]]

    def test_l0_person_is_withheld(self):
        self.assertNotIn(self.NAMES["L0"], self._names_served())

    def test_l3_person_is_withheld(self):
        self.assertNotIn(self.NAMES["L3"], self._names_served())

    def test_unparseable_person_is_withheld(self):
        self.assertNotIn(self.NAMES["unparseable"], self._names_served())

    def test_l2_and_untagged_controls_are_still_served(self):
        served = self._names_served()
        self.assertIn(self.NAMES["L2"], served)
        self.assertIn(self.NAMES["untagged"], served)


class TestPeopleSearchFactsOutbound(unittest.TestCase):
    """An explicit L0 fact on an otherwise-served (L2) person is withheld."""

    def _facts(self):
        facts = [
            {"text": "Synthetic L0 fact", "privacy_level": "L0"},
            {"text": "Synthetic L2 fact", "privacy_level": "L2"},
            {"text": "Synthetic L3 fact", "privacy_level": "L3"},
        ]
        hit = _person_hit(0, "Tom Patel", "L2")
        hit["payload"]["facts"] = facts
        with patch.object(server.urllib.request, "urlopen",
                          _fake_urlopen({"result": [hit]})):
            body = server.people_search("synthetic", limit=10)
        self.assertEqual(1, len(body["results"]))
        return [f["text"] for f in body["results"][0].get("facts", [])]

    def test_l0_fact_is_withheld_on_a_served_person(self):
        self.assertNotIn("Synthetic L0 fact", self._facts())

    def test_l3_fact_is_withheld(self):
        self.assertNotIn("Synthetic L3 fact", self._facts())

    def test_l2_fact_control_is_still_served(self):
        self.assertIn("Synthetic L2 fact", self._facts())


class TestCommitmentsOutbound(unittest.TestCase):
    def _row(self, action, plevel):
        return {
            "action": action, "owner": "user", "deadline": "2026-12-01",
            "status": "open", "source": "2026-11-01", "createdAt": "2026-11-01",
            "plevel": plevel,
        }

    def _actions(self):
        rows = [
            self._row("Synthetic L0 todo", "L0"),
            self._row("Synthetic L3 todo", "L3"),
            self._row("Synthetic L2 todo", "L2"),
            self._row("Synthetic untagged todo", None),
            self._row("Synthetic bogus todo", "not-a-level"),
        ]
        with patch.object(server, "_sparql_select", lambda q: rows):
            body, status = server.commitments_list(status="open")
        self.assertEqual(status, 200)
        return [c["action"] for c in body["commitments"]]

    def test_l0_todo_is_withheld(self):
        self.assertNotIn("Synthetic L0 todo", self._actions())

    def test_l3_todo_is_withheld(self):
        self.assertNotIn("Synthetic L3 todo", self._actions())

    def test_unparseable_todo_is_withheld(self):
        self.assertNotIn("Synthetic bogus todo", self._actions())

    def test_l2_and_untagged_controls_are_still_served(self):
        actions = self._actions()
        self.assertIn("Synthetic L2 todo", actions)
        self.assertIn("Synthetic untagged todo", actions)


class TestReplyDebtOutbound(unittest.TestCase):
    def _debts(self):
        debts = [
            SimpleNamespace(name="Synthetic L0 thread", privacy_level="L0"),
            SimpleNamespace(name="Synthetic L3 thread", privacy_level="L3"),
            SimpleNamespace(name="Synthetic L2 thread", privacy_level="L2"),
            SimpleNamespace(name="Synthetic bogus thread", privacy_level="x"),
        ]

        def compute_reply_debts(**kwargs):
            return list(debts)

        def reply_debt_payload(ds, **kwargs):
            return {
                "count": len(ds),
                "brief_line": "You owe a reply to %d people" % len(ds),
                "debts": [{"name": d.name} for d in ds],
            }

        return SimpleNamespace(
            compute_reply_debts=compute_reply_debts,
            reply_debt_payload=reply_debt_payload,
        )

    def _names(self):
        with patch.object(server, "_load_reply_debt_service",
                          lambda: self._debts()):
            body, status = server.api_reply_debt(limit=50)
        self.assertEqual(status, 200)
        self.assertFalse(body.get("degraded"))
        return [d["name"] for d in body["debts"]]

    def test_l0_thread_is_withheld(self):
        self.assertNotIn("Synthetic L0 thread", self._names())

    def test_l3_thread_is_withheld(self):
        self.assertNotIn("Synthetic L3 thread", self._names())

    def test_unparseable_thread_is_withheld(self):
        self.assertNotIn("Synthetic bogus thread", self._names())

    def test_l2_control_is_still_served(self):
        self.assertIn("Synthetic L2 thread", self._names())


class TestDerivedPreferencesOutbound(unittest.TestCase):
    def _labels(self):
        rows = [
            {"s": "urn:d:1", "dimension": "x", "subject": "Synthetic L0 pref",
             "strength": "0.5", "confidence": "0.9", "privacy": "L0"},
            {"s": "urn:d:2", "dimension": "x", "subject": "Synthetic L3 pref",
             "strength": "0.5", "confidence": "0.9", "privacy": "L3"},
            {"s": "urn:d:3", "dimension": "x", "subject": "Synthetic L2 pref",
             "strength": "0.5", "confidence": "0.9", "privacy": "L2"},
        ]
        reader = DerivedGraphReader(
            lambda q: rows if "DerivedPreference" in q else [])
        resp = build_derived_preferences_response(
            reader, "synthetic_owner_01", tier="all")
        return [i["label"] for i in resp["items"]]

    def test_l0_preference_is_withheld(self):
        self.assertNotIn("Synthetic L0 pref", self._labels())

    def test_l3_preference_is_withheld(self):
        self.assertNotIn("Synthetic L3 pref", self._labels())

    def test_l2_control_is_still_served(self):
        self.assertIn("Synthetic L2 pref", self._labels())


class TestTimelineEmitsLevel(unittest.TestCase):
    """The owner-local timeline EMITS the row's own privacy_level on every event
    that has one (Archie ruling, L3 window). L0 events are kept, not withheld."""

    def _events(self):
        conv = [
            {"conv": "urn:ostler:conversation/synthetic-1", "date": "2026-11-01",
             "fpriv": "L0"},
            {"conv": "urn:ostler:conversation/synthetic-2", "date": "2026-10-20",
             "fpriv": "L2"},
        ]
        meet = [{"m": "urn:synthetic:meeting/1", "summary": "Synthetic meeting",
                 "date": "2026-10-30", "location": "", "mpriv": "L1"}]
        lc = [{"lcEmail": "2026-10-10", "lcWhatsApp": "", "lcIMessage": ""}]

        def fake(query):
            if "pwg:Meeting" in query:
                return meet
            if "urn:ostler:about" in query:
                return conv
            if "lastContactEmail" in query:
                return lc
            return []

        with patch.object(server, "_sparql_select", fake):
            body, status = server._person_timeline_body(
                "urn:ostler:person/synthetic-p", "Jane Doe", "jane-doe")
        self.assertEqual(200, status)
        return body["events"]

    def test_every_event_with_a_row_level_carries_privacy_level(self):
        for e in self._events():
            if e["type"] in ("conversation", "meeting"):
                self.assertIn("privacy_level", e, e)

    def test_the_seeded_l0_conversation_is_kept_and_labelled_l0(self):
        convs = {e["conversation_id"]: e for e in self._events()
                 if e["type"] == "conversation"}
        self.assertIn("synthetic-1", convs)
        self.assertEqual("L0", convs["synthetic-1"]["privacy_level"])
        self.assertEqual("L2", convs["synthetic-2"]["privacy_level"])

    def test_the_meeting_keeps_its_level(self):
        meetings = [e for e in self._events() if e["type"] == "meeting"]
        self.assertEqual(1, len(meetings))
        self.assertEqual("L1", meetings[0]["privacy_level"])


if __name__ == "__main__":
    unittest.main()
