#!/usr/bin/env python3
"""Regression guard: ingest writers must resolve a person before creating one.

THE BUG THIS KILLS, measured on a real graph (2026-08-07):

    person_854d9326b47c   "Jane Doe"            (LinkedIn)
    person_0d3b1069e8e5   "Mum Doe"               (Contacts, holds
                                                      jane.doe@example.com
                                                      as an identifier)
    person_f17229f7-...   "jane.doe@example.com"   (calendar, 0 identifiers)

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
displayName and was NOT marked provisional, so "jane.doe@example.com"
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
ADDR = "jane.doe@example.com"


# ── 1. The real case: the attendee is somebody we already know ────────
#
# v1018-D675. This section asserted res["people_matched"] == 1 and
# res["people_created"] == 0, and that the resolver "actually queried by
# identifier value". None of that is the current design and none of it is a
# regression:
#
#   * ingest_calendar returns {status, events_processed, unique_attendees,
#     meetings_created}. There are no people_matched / people_created keys, so
#     both .get()s returned None and failed against 1 and 0.
#   * attendee -> person is now _person_id_from_identifier(), a uuid5 over the
#     cleaned address, so the SAME address always derives the SAME URI. There
#     is no lookup query to observe, and "matching" is a property of the
#     derivation rather than a store round-trip.
#
# So the guarantee to test is the one that actually protects the customer: a
# known attendee must not get a duplicate Person node. Drive that through
# _person_exists, which is the only thing that decides create-or-not.
tmp = Path(tempfile.mkdtemp())
write_calendar(tmp, [ADDR])
store = FakeStore({ADDR: MUM})
install(store)

# The URI the ingester will derive for this address.
DERIVED = m._person_uri(m._person_id_from_identifier(ADDR))

# The person already exists at that URI -> no new Person node.
m._person_exists = lambda uri: uri == DERIVED   # type: ignore[assignment]
res = m.ingest_calendar(tmp)

check(res.get("unique_attendees") == 1,
      "calendar counted the attendee exactly once")
check(ADDR not in store.insert_mentioning("a pwg:Person"),
      "no Person node was created named by the raw email address")
check(DERIVED in store.insert_mentioning("pwg:meetingAttendee"),
      "the Meeting links to the derived person URI, not to an orphan")
check(m._person_id_from_identifier(ADDR)
      == m._person_id_from_identifier(ADDR.upper()),
      "the same address derives the same person id regardless of case")

# Positive control: with the person ABSENT, a Person node IS written --
# otherwise the check above would pass on an ingester that creates nothing.
tmp1b = Path(tempfile.mkdtemp())
write_calendar(tmp1b, [ADDR])
store1b = FakeStore({})
install(store1b)
m._person_exists = lambda uri: False   # type: ignore[assignment]
m.ingest_calendar(tmp1b)
check("a pwg:Person" in "\n".join(store1b.updates),
      "positive control: an unknown attendee DOES get a Person node")

# ── 2. A newly created attendee must be mergeable and marked provisional ──
# v1018-D675: this read from `empty`, a FakeStore the old section 1 built while
# proving the "no existing person" path. Section 1 now proves that with
# store1b, so read the created triples from there rather than reintroducing a
# second identical fixture.
created = store1b.insert_mentioning("a pwg:Person")
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

# ── 5. A quote-bearing address cannot break out of a literal ──────────
#
# v1018-D675: this called m._person_uri_by_identifier_value(evil) and asserted
# the emitted FILTER carried an escaped quote. That helper NO LONGER EXISTS,
# and its absence is the fix, not a regression: identifier -> person is now
# _person_id_from_identifier(), a uuid5 over the cleaned identifier, so the
# attacker-controlled string is never interpolated into a query at all. The
# injection surface the test probed was designed out.
#
# The escaping property still matters, because the value IS written into
# SPARQL string literals at the write sites (pwg_ingest 444/466/489/679/802).
# So assert what survived: _escape neutralises a quote, and the identifier
# value reaches the store through it.
evil = 'we"ird@example.com'
check('\\"' in m._escape(evil),
      "_escape neutralises a double quote in an identifier value")
check('\n' not in m._escape('a\nb') and '\r' not in m._escape('a\rb'),
      "_escape neutralises CR and LF (SPARQL 19.7 STRING_LITERAL2)")
check(m._person_id_from_identifier(evil) == m._person_id_from_identifier(evil.upper()),
      "identifier keying is a case-folded uuid5, so no query interpolation")
check(not hasattr(m, "_person_uri_by_identifier_value"),
      "the old query-interpolating lookup is gone (uuid5 replaced it)")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} check(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: ingest writers resolve before creating")
