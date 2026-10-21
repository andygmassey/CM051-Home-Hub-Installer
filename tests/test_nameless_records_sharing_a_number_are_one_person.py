"""CM051 #2545: two records with NO human name on one phone or email are one person.

THE DEFECT (v1.0.106 walk, "Unknown contact" rows): the shareable-identifier
guard (`_identifier_match_trustworthy`, BW-1) declined every phone/email match
unless both display names were present and equal. When both sides are blank, or
a phone / email stands in for a name, that rule can never be satisfied, so a
messaging handle was minted as a SECOND person beside the Contacts card holding
the same number. The People list then shows two rows on one number.

THE STORE IS REAL: the shipping IdentityResolver (and ContactSyncer, for the
write path) run their SPARQL against an rdflib graph over loopback HTTP.

Controls that must NOT change: two people with different human names sharing a
number stay two people (household / office line); a nameless handle beside a
NAMED card still declines (no name evidence either way); two Contacts cards
with different icloud_contact_uid never merge (RULE 2). Synthetic data only
(Ofcom drama range numbers that libphonenumber accepts, example.com).
"""
from __future__ import annotations

import http.server
import os
import sys
import threading
import types
import urllib.parse
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib", reason="rdflib backs the in-memory store")
pytest.importorskip("httpx")
pytest.importorskip("rapidfuzz")
pytest.importorskip("phonenumbers")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
PHONE = "+442079460555"      # Ofcom drama range, valid FIXED_LINE
EMAIL = "shared.line@example.com"


@pytest.fixture()
def store():
    g = rdflib.Graph()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "application/sparql-results+json")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            if self.path.startswith("/update"):
                g.update(body)
                self._send(204, b"")
                return
            if (self.headers.get("Content-Type") or "").startswith("application/x-www-form-urlencoded"):
                body = urllib.parse.parse_qs(body).get("query", [""])[0]
            self._send(200, g.query(body).serialize(format="json"))

        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
            self._send(200, g.query(q).serialize(format="json"))

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    g.url = "http://127.0.0.1:%d" % srv.server_address[1]
    yield g
    srv.shutdown()


def add_person(g, n, name, *, uid=None, phone=None, email=None):
    uri = "%sperson_fixture%d" % (PWG, n)
    t = ["<%s> a pwg:Person" % uri, '<%s> pwg:displayName "%s"' % (uri, name)]
    for kind, value in (("icloud_contact_uid", uid), ("phone", phone), ("email", email)):
        if value:
            i = "<%sid_fixture%d_%s>" % (PWG, n, kind)
            t += ["<%s> pwg:hasIdentifier %s" % (uri, i), "%s a pwg:PersonIdentifier" % i,
                  '%s pwg:identifierType "%s"' % (i, kind), '%s pwg:identifierValue "%s"' % (i, value)]
    g.update("PREFIX pwg: <%s> INSERT DATA { %s }" % (PWG, " . ".join(t)))
    return uri


def resolver(g):
    r = IdentityResolver(oxigraph_url=g.url, default_country_code=44)
    r._fuzzy_candidates = []
    return r


def resolve(g, **kw):
    return resolver(g).resolve(PersonIdentity(**kw), use_fuzzy=False)


def test_blank_handle_beside_blank_card_is_the_same_person(store):
    card = add_person(store, 1, "", uid="CARD-1:ABPerson", phone=PHONE)
    m = resolve(store, display_name="", phones=[PHONE])
    assert (m.person_uri, m.match_type) == (card, "exact_identifier")


def test_phone_named_handle_beside_blank_card_is_the_same_person(store):
    card = add_person(store, 1, "", uid="CARD-1:ABPerson", phone=PHONE)
    assert resolve(store, display_name=PHONE, phones=[PHONE]).person_uri == card


def test_email_named_pair_is_the_same_person(store):
    node = add_person(store, 1, EMAIL, email=EMAIL)
    assert resolve(store, display_name=EMAIL, emails=[EMAIL]).person_uri == node


def test_control_different_human_names_on_one_line_stay_two_people(store):
    add_person(store, 1, "Sam Carter", uid="CARD-1:ABPerson", phone=PHONE)
    m = resolve(store, display_name="Robin Rivera", phones=[PHONE])
    assert m.person_uri is None and m.match_type == "new"


def test_control_nameless_handle_beside_a_named_card_still_declines(store):
    add_person(store, 1, "Sam Carter", uid="CARD-1:ABPerson", phone=PHONE)
    assert resolve(store, display_name="", phones=[PHONE]).person_uri is None
    assert resolve(store, display_name=PHONE, phones=[PHONE]).person_uri is None


def test_control_same_human_name_still_merges(store):
    card = add_person(store, 1, "Sam Carter", uid="CARD-1:ABPerson", phone=PHONE)
    assert resolve(store, display_name="Sam Carter", phones=[PHONE]).person_uri == card


def test_control_rule_2_a_second_blank_card_never_merges_into_the_first(store):
    add_person(store, 1, "", uid="CARD-1:ABPerson", phone=PHONE)
    m = resolve(store, display_name="", icloud_uid="CARD-2:ABPerson", phones=[PHONE])
    assert m.person_uri is None, "two Contacts cards (different icloud_contact_uid) must stay two people"


def test_syncer_write_path_one_person_for_a_card_and_its_handle(store, monkeypatch):
    """Through the shipped ContactSyncer: a blank-named card is written, then the
    same number arrives as a handle; the resolver must hand back the card's node
    so no second person is created."""
    pytest.importorskip("vobject")
    pytest.importorskip("qdrant_client")
    monkeypatch.setenv("DEFAULT_COUNTRY_CODE", "44")
    from contact_syncer import syncer as S
    from contact_syncer.vcard_parser import parse_vcard

    cfg = types.SimpleNamespace(OXIGRAPH_URL=store.url, USER_ID="", DEFAULT_PRIVACY_LEVEL="L1",
                                DEFAULT_COUNTRY_CODE="44", QDRANT_URL="http://unused")
    s = object.__new__(S.ContactSyncer)
    s.cfg = cfg
    s.resolver = IdentityResolver(oxigraph_url=store.url, default_country_code=44)
    s._collection_ensured = True
    vcf = "\n".join(["BEGIN:VCARD", "VERSION:3.0", "UID:CARD-9:ABPerson", "FN:", "N:;;;;",
                     "TITLE:Plumber", "TEL;TYPE=CELL:+44 20 7946 0555", "END:VCARD"])
    _, card_uri = s._resolve_and_write_person(parse_vcard(vcf), "person")
    assert card_uri
    fresh = IdentityResolver(oxigraph_url=store.url, default_country_code=44)
    fresh._fuzzy_candidates = []
    m = fresh.resolve(PersonIdentity(display_name="", phones=["+442079460555"]), use_fuzzy=False)
    assert m.person_uri == card_uri
    n = len(list(store.query("PREFIX p:<%s> SELECT ?x WHERE { ?x a p:Person }" % PWG)))
    assert n == 1
