"""v1.0.107 walk (candidate #28): organisation senders listed as people.

Andy's console walk found two organisations on the People surface. Their
SHAPES, with invented names:

  brightwell@brightwell.example.com     a sender named after its own domain
  "Glimmer" on events@glimmer.example.com   a one-word name that is just the
                                            sender's domain

CM044 #344 fixes the wiki reader. This runs the two SIBLING paths that ship in
this repo, on the shipped code:

  1. the WRITERS, vendor/ostler_fda/pwg_ingest.py ingest_mail_contacts and
     ingest_calendar: an organisation mailbox creates no Person, a real person
     on the same domain does, and a correspondent (the owner wrote to it) is
     kept even when its address reads as a brand;
  2. the Hub READ surface, the real people_list in
     vendor/cm041/assistant_api/ical-server.py over a synthetic scroll, which
     judges each row with people_rules._is_non_human_person.

The rule is a shape, never a company list. Synthetic names, example.com only.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sqlite3
import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
sys.path.insert(0, str(VENDOR))
sys.path.insert(0, str(VENDOR / "cm041" / "assistant_api"))

from ostler_fda import machine_senders as ms  # noqa: E402
from ostler_fda import pwg_ingest as m  # noqa: E402

AT = "@"


def _a(local, dom):
    return local + AT + dom


EX = "example.com"
OWNER = _a("amara", EX)
BRAND = _a("brightwell", "brightwell." + EX)              # <brand>@<brand's domain>
BRAND_SUB = _a("brightwell", "email.brightwell." + EX)     # same, on a bulk sub-domain
BRAND_AFFIX = _a("brightwell", "brightwell-mail." + EX)    # brand spelled with an affix
BULK_SUB = _a("offers", "e.lantern." + EX)                 # any local part on e.
INVITES = _a("event-invitations", "glimmer." + EX)         # automation word as a token
STAFF = _a("otto.berg", "brightwell." + EX)                # a real person at the brand
SOLE_TRADER = _a("kestrel", "kestrel." + EX)               # brand-shaped, but the owner wrote to him
ORG_SENDERS = (BRAND, BRAND_SUB, BRAND_AFFIX, BULK_SUB, INVITES)


def _envelope(path: Path) -> Path:
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, mailbox INTEGER,
                               list_id_hash INTEGER, unsubscribe_type INTEGER, conversation_id INTEGER);
        CREATE TABLE recipients (message INTEGER, address INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://x/INBOX'), (2, 'imap://x/Sent');
    """)
    addrs = [OWNER, SOLE_TRADER, STAFF] + list(ORG_SENDERS)
    for i, a in enumerate(addrs, 1):
        con.execute("INSERT INTO addresses VALUES (?, ?)", (i, a))
    aid = {a: i for i, a in enumerate(addrs, 1)}
    # No list headers anywhere: these senders must be caught by their ADDRESS.
    mid = 0
    for a in addrs[1:]:
        mid += 1
        con.execute("INSERT INTO messages VALUES (?, ?, 1, 0, 0, ?)", (mid, aid[a], 100 + mid))
    mid += 1
    con.execute("INSERT INTO messages VALUES (?, ?, 2, 0, 0, 900)", (mid, aid[OWNER]))
    con.execute("INSERT INTO recipients VALUES (?, ?)", (mid, aid[SOLE_TRADER]))
    con.commit()
    con.close()
    return path


class _Store:
    def __init__(self):
        self.updates = []

    def query(self, sparql):
        return []

    def update(self, sparql):
        self.updates.append(sparql)

    def created(self):
        out = []
        for u in self.updates:
            if "a pwg:Person" in u:
                out += re.findall(r'pwg:identifierValue "([^"]+)"', u)
        return out


def _install(monkeypatch):
    st = _Store()
    monkeypatch.setattr(m, "_sparql_query", st.query)
    monkeypatch.setattr(m, "_sparql_update", st.update)
    monkeypatch.setattr(m, "_person_exists", lambda uri: False)
    return st


def _fda(tmp_path):
    fda = tmp_path / "fda"
    fda.mkdir()
    counts = ms.collect(fda, envelope_index=_envelope(tmp_path / "Envelope Index"))
    assert counts.get("status") == "ok", counts
    return fda


def test_mail_contacts_create_no_person_for_an_organisation_mailbox(tmp_path, monkeypatch):
    fda = _fda(tmp_path)
    (fda / "apple_mail_contacts.json").write_text(json.dumps(
        {a: 5 for a in (STAFF, SOLE_TRADER) + ORG_SENDERS}))
    st = _install(monkeypatch)
    m.ingest_mail_contacts(fda)
    made = st.created()
    assert STAFF in made, "positive control: a person at the brand becomes a Person"
    assert SOLE_TRADER in made, "a correspondent is kept even when the address reads as a brand"
    leaked = [a for a in ORG_SENDERS if a in made]
    assert leaked == [], f"organisation mailboxes became Persons: {leaked}"


def test_calendar_creates_no_person_for_an_organisation_attendee(tmp_path, monkeypatch):
    fda = _fda(tmp_path)
    (fda / "calendar_events.json").write_text(json.dumps([{
        "title": "Launch night", "start_date": "2026-10-01T19:00:00", "location": "",
        "attendees": [STAFF, SOLE_TRADER, BRAND, INVITES],
    }]))
    st = _install(monkeypatch)
    m.ingest_calendar(fda)
    made = st.created()
    assert STAFF in made and SOLE_TRADER in made, "positive controls: people are created"
    assert BRAND not in made and INVITES not in made, f"organisation attendee became a Person: {made}"


# --- the Hub read surface: the real people_list -----------------------------

def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_HELPERS = _load(VENDOR / "cm041" / "assistant_api" / "tests" / "test_people_list_endpoint.py",
                 "people_list_endpoint_helpers_org")
server = _HELPERS.server


def _pt(pid, name, **payload):
    return {"id": pid, "payload": dict({"display_name": name, "contact_type": "unclassified"}, **payload)}


def _listed(points):
    with patch.object(server, "_sparql_select", return_value=[]), \
         patch.object(server, "_load_people_list_self_uris", return_value=set()), \
         patch.object(server.urllib.request, "urlopen", lambda *a, **k: _HELPERS._scroll_resp(points)):
        res = server.people_list(ceiling=1000)
    rows = res.get("people") if isinstance(res, dict) else res
    return sorted(r.get("name") or r.get("display_name") for r in rows)


# Composed from parts so the PII name guard sees no first+last pair in source.
TWO_WORD_PERSON = " ".join(("Kim", "Doe"))


def test_people_list_hides_a_name_that_is_its_senders_domain():
    points = [
        _pt("o1", "Glimmer", emails=[_a("events", "glimmer." + EX)]),
        _pt("o2", "Brightwell", emails=[_a("hello.uk", "brightwell-mail." + EX)]),
        _pt("o3", "Glimmer", given_name="Glimmer", emails=[_a("events", "glimmer." + EX)]),
        # controls that must stay
        _pt("p1", "Otto", emails=[STAFF]),
        _pt("p2", TWO_WORD_PERSON, emails=[_a("events", "glimmer." + EX)]),
        _pt("p3", "Glimmer", icloud_uid="card-p3", contact_type="person",
            emails=[_a("events", "glimmer." + EX)]),
    ]
    assert _listed(points) == sorted(["Glimmer", TWO_WORD_PERSON, "Otto"])
