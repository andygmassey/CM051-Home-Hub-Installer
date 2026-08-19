#!/usr/bin/env python3
"""Regression guard: ingest writers must resolve a person before creating one.

THE BUG THIS KILLS, measured on a real graph (2026-08-07):

    person_854d9326b47c   "Marlow Bexley"            (LinkedIn)
    person_0d3b1069e8e5   "Mum Bexley"               (Contacts, holds
                                                      marlow.bexley@example.com
                                                      as an identifier)
    person_f17229f7-...   "marlow.bexley@example.com" (calendar, 0 identifiers)

One human, three records, and the third was created by ``ingest_calendar``
*while a person holding that exact address already existed*.

Two independent defects produced it:

1. Every writer mints its person URI as ``uuid5(lowercased identifier)`` and
   then asks only ``_person_exists(uri)`` -- "did I already create this?",
   never "does this human already exist?". Contacts, LinkedIn and the CM041
   resolver mint URIs by other schemes, so that check can never see them.
   8 provable collisions were measured this way.

2. ``ingest_calendar`` wrote NO identifier at all, so its records carried
   nothing to match on and were unmergeable *forever*. 900 identifier-less
   people were measured; nothing downstream could ever fold them in.

Plus the cosmetic half Andy saw first: the raw address was used as the
displayName and was NOT marked provisional, so "marlow.bexley@example.com"
rendered as somebody's name and the resolver treated it as a real name it
must not overwrite -- even though ``_is_provisional_display_name`` has said
"a bare email used as a name is a placeholder" all along, and
iMessage/WhatsApp already honour it.

Network-free: the SPARQL transport is stubbed, but the REAL query text the
resolver builds is parsed by the stub, so a broken query or broken escaping
fails here rather than silently matching nothing.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import pwg_ingest as m  # noqa: E402

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        FAILURES.append(msg)


class FakeStore:
    """Minimal Oxigraph stand-in: identifier value -> owning person URI."""

    # Matches the FILTER the resolver builds. If the query shape changes,
    # this stops matching and every "matched an existing person" assertion
    # below fails loudly -- which is the point.
    _FILTER = re.compile(r'FILTER\(LCASE\(STR\(\?iv\)\) = "(.*)"\)')

    def __init__(self, identifiers: dict[str, str]):
        self.identifiers = {k.lower(): v for k, v in identifiers.items()}
        self.updates: list[str] = []
        self.queries: list[str] = []

    def query(self, sparql: str) -> list:
        self.queries.append(sparql)
        mo = self._FILTER.search(sparql)
        if not mo:
            return []
        uri = self.identifiers.get(mo.group(1))
        return [{"p": {"value": uri}}] if uri else []

    def update(self, sparql: str) -> None:
        self.updates.append(sparql)

    # -- assertions helpers ------------------------------------------------
    def created_person_uris(self) -> list[str]:
        out = []
        for u in self.updates:
            for mo in re.finditer(r"<([^>]+)> a pwg:Person", u):
                out.append(mo.group(1))
        return out

    def insert_mentioning(self, needle: str) -> str:
        return "\n".join(u for u in self.updates if needle in u)


def install(store: FakeStore) -> None:
    m._sparql_query = store.query          # type: ignore[assignment]
    m._sparql_update = store.update        # type: ignore[assignment]
    m._person_exists = lambda uri: False   # type: ignore[assignment]


def write_calendar(tmp: Path, attendees: list[str]) -> Path:
    (tmp / "calendar_events.json").write_text(json.dumps([{
        "title": "Family lunch",
        "start_date": "2026-08-01T12:00:00",
        "location": "Home",
        "attendees": attendees,
    }]))
    return tmp


MUM = "https://pwg.dev/ontology#person_0d3b1069e8e5"
ADDR = "marlow.bexley@example.com"


# ── 1. The real case: the attendee is somebody we already know ────────
tmp = Path(tempfile.mkdtemp())
write_calendar(tmp, [ADDR])
store = FakeStore({ADDR: MUM})
install(store)
res = m.ingest_calendar(tmp)

check(res.get("people_matched") == 1,
      "calendar matched the attendee to the existing person")
check(res.get("people_created") == 0,
      "calendar created NO duplicate for a known attendee")
check(ADDR not in store.insert_mentioning("a pwg:Person"),
      "no Person node was created named by the raw email address")
check(MUM in store.insert_mentioning("pwg:meetingAttendee"),
      "the Meeting links to the EXISTING person, not to an orphan URI")
check(store.queries and "identifierValue" in store.queries[0],
      "the resolver actually queried by identifier value")

# ── 1b. Positive control: same input, nobody known => it DOES create ──
# Without this, assertion 1 would also pass if the writer had simply
# stopped creating people at all.
tmp2 = Path(tempfile.mkdtemp())
write_calendar(tmp2, [ADDR])
empty = FakeStore({})
install(empty)
res2 = m.ingest_calendar(tmp2)
check(res2.get("people_created") == 1 and res2.get("people_matched") == 0,
      "positive control: with an empty store the same attendee IS created")

# ── 2. A newly created attendee must be mergeable and marked provisional ──
created = empty.insert_mentioning("a pwg:Person")
check("pwg:hasIdentifier" in created and "pwg:PersonIdentifier" in created,
      "a new calendar person carries a PersonIdentifier (mergeable later)")
check(f'pwg:identifierValue "{ADDR}"' in created,
      "the identifier records the address the person was keyed on")
check('pwg:identifierType "email"' in created,
      "an email attendee is typed as an email identifier")
check('pwg:displayNameProvisional "true"' in created,
      "an email used as a name is marked provisional, not treated as a name")

# ── 3. Phone-shaped attendees are typed as phones ─────────────────────
tmp3 = Path(tempfile.mkdtemp())
write_calendar(tmp3, ["+447700900123"])
phones = FakeStore({})
install(phones)
m.ingest_calendar(tmp3)
check('pwg:identifierType "phone"' in phones.insert_mentioning("a pwg:Person"),
      "a phone-shaped attendee is typed as a phone identifier")

# ── 4. Apple Mail contacts resolve before creating too ────────────────
tmp4 = Path(tempfile.mkdtemp())
(tmp4 / "apple_mail_contacts.json").write_text(json.dumps({ADDR: 12}))
mail_known = FakeStore({ADDR: MUM})
install(mail_known)
res4 = m.ingest_mail_contacts(tmp4)
check(res4.get("people_matched") == 1 and res4.get("people_created") == 0,
      "mail contacts matched a known sender instead of duplicating them")

tmp5 = Path(tempfile.mkdtemp())
(tmp5 / "apple_mail_contacts.json").write_text(json.dumps({ADDR: 12}))
mail_new = FakeStore({})
install(mail_new)
res5 = m.ingest_mail_contacts(tmp5)
check(res5.get("people_created") == 1,
      "positive control: an unknown sender is still created")
check('pwg:displayNameProvisional "true"' in mail_new.insert_mentioning("a pwg:Person"),
      "a mail-created person's email name is marked provisional")

# ── 5. A quote-bearing address cannot break out of the query ──────────
# _escape is applied to the lowercased value; if it ever stops being, the
# FILTER terminates early and this address would match the WRONG person.
evil = 'we"ird@example.com'
esc = FakeStore({})
install(esc)
m._person_uri_by_identifier_value(evil)
check(esc.queries and '\\"' in esc.queries[-1],
      "the resolver escapes a quote in the identifier value")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} check(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: ingest writers resolve before creating")
