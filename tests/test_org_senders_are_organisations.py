#!/usr/bin/env python3
"""Ostler #30: a platform or firm that writes to the owner is an ORGANISATION.

The console walk's wiki listed "Luma" (an events platform) and "Mckinsey" (a
calendar address whose local part is a firm) as people. ingest_calendar and
ingest_mail_contacts wrote every sender with contactType "person". Now a known
organisation or service is written contactType "organisation" (kept, not
dropped), and a person who merely works AT a known firm stays a person.

Executes the shipped vendor/ostler_fda on synthetic input, transport stubbed.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))

from ostler_fda import machine_senders as ms  # noqa: E402
from ostler_fda import pwg_ingest as m  # noqa: E402

FAIL: list = []


def check(cond, msg):
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        FAIL.append(msg)


AT = "@"
LUMA = "calendar-invite" + AT + "lu.ma"
LUMA2 = "hello" + AT + "luma.com"
MCK = "mckinsey" + AT + "fixture-owner.example"
PERSON = "marta.kowalczyk" + AT + "fixture.example"
PERSON_AT_FIRM = "jan.nowak" + AT + "microsoft.com"

check(ms.organisation_reason(MCK) == "known-organisation", "a firm-named local part is an organisation")
check(ms.organisation_reason(LUMA2) == "service-domain", "a generic mailbox on a service domain is an organisation")
check(ms.organisation_reason(PERSON) is None, "control: a person is not")
check(ms.organisation_reason(PERSON_AT_FIRM) is None, "control: a person at a known firm is not")


class Store:
    def __init__(self):
        self.updates = []

    def query(self, sparql):
        return []

    def update(self, sparql):
        self.updates.append(sparql)

    def types(self):
        """identifier value -> contactType of the node it was written on."""
        out = {}
        for u in self.updates:


            t = re.search(r'pwg:contactType "([^"]+)"', u)
            v = re.search(r'pwg:identifierValue "([^"]+)"', u)
            if t and v:
                out[v.group(1)] = t.group(1)
        return out


def install():
    st = Store()
    m._sparql_query = st.query
    m._sparql_update = st.update
    m._person_exists = lambda uri: False
    return st


fda = Path(tempfile.mkdtemp())
(fda / "apple_mail_contacts.json").write_text(json.dumps({a: 5 for a in (MCK, LUMA2, PERSON, PERSON_AT_FIRM)}))
st = install()
m.ingest_mail_contacts(fda)
t = st.types()
print(t)
check(t.get(PERSON) == "person", "mail: positive control, a person is written as a person")
check(t.get(PERSON_AT_FIRM) == "person", "mail: a person at a known firm is a person")
check(t.get(MCK) == "organisation", "mail: the firm-named sender is written as an organisation")
check(t.get(LUMA2) != "person", "mail: the platform sender is never written as a person")

(fda / "calendar_events.json").write_text(json.dumps([{
    "title": "Fixture event", "start_date": "2026-08-01T12:00:00", "location": "",
    "attendees": [MCK, LUMA, PERSON],
}]))
st = install()
m.ingest_calendar(fda)
t = st.types()
check(t.get(PERSON) == "person", "calendar: positive control, a person is written as a person")
check(t.get(MCK) == "organisation", "calendar: the firm-named attendee is written as an organisation")
check(ms.organisation_reason(LUMA) == "service-domain", "the events platform's invite address is an organisation")
check(t.get(LUMA) != "person", "calendar: the events platform is never written as a person")

print(f"\n{len(FAIL)} failed")
sys.exit(1 if FAIL else 0)
