#!/usr/bin/env python3
"""contact_cards_fixture.py -- put synthetic Contacts cards into a COLD box's graph.

WHY. no_person_holds_two_contact_cards is BLOCKING and refuses to read a zero
over a graph with no icloud_contact_uid identifiers (its anti-vacuity control).
A cold walk account has no Contacts and no TCC grant to read any, so on v1.0.115
(walk34) the control read 0 and the probe was CANNOT-RUN: "ZERO icloud_contact_uid
identifiers in the graph". CANNOT-RUN is not PASS, so the walk has to supply the
cards. The probe's predicate is NOT touched: this file only gives it something
to measure.

WHAT. Six synthetic people, one card each, written in the shape contact_syncer's
_create_person_oxigraph writes (pwg:Person, displayName, one icloud_contact_uid
identifier plus phone and email identifiers). Every phone and email is unique
across the six, so a correct graph has no collision and the probe passes. The
cast is synthetic: example.com addresses and the Ofcom drama range
(+44 7700 900xxx). Nothing here is a real person.

SAFETY. seed writes ONLY when the graph holds ZERO icloud_contact_uid
identifiers (a box with real contacts is measured as it is). Every node it
writes carries a URI under FIXTURE_PREFIX, and forget deletes exactly those
URIs, so no customer triple can be touched.

State words printed on the last line: seeded | skipped-real-contacts |
failed-<reason>. forget prints removed | nothing-to-remove | failed-<reason>.
"""
import json
import os
import re
import sys
import urllib.request

PWG = "https://schema.ostler.ai/ontology#"
FIXTURE_PREFIX = "https://schema.ostler.ai/person/walkfixture-card-"
ID_PREFIX = "https://schema.ostler.ai/ontology#id_walkfixture_card_"

CARDS = [
    ("Alice Example", "+447700900101", "alice.example@example.com"),
    ("Bob Example", "+447700900102", "bob.example@example.com"),
    ("Carol Example", "+447700900103", "carol.example@example.com"),
    ("Dan Example", "+447700900104", "dan.example@example.com"),
    ("Erin Example", "+447700900105", "erin.example@example.com"),
    ("Frank Example", "+447700900106", "frank.example@example.com"),
]


def card_uid(n):
    return "WALKFIXTURE-CARD-%d:ABPerson" % n


def build_seed_update(cards=CARDS):
    """INSERT DATA for the cards. Pure, so a test can read it."""
    t = []
    for n, (name, phone, email) in enumerate(cards, 1):
        p = "<%s%d>" % (FIXTURE_PREFIX, n)
        t.append("%s a pwg:Person" % p)
        t.append('%s pwg:displayName "%s"' % (p, name))
        t.append('%s pwg:contactType "person"' % p)
        for kind, value in (("icloud_contact_uid", card_uid(n)), ("phone", phone), ("email", email)):
            i = "<%s%d_%s>" % (ID_PREFIX, n, kind)
            t.append("%s pwg:hasIdentifier %s" % (p, i))
            t.append("%s a pwg:PersonIdentifier" % i)
            t.append('%s pwg:identifierType "%s"' % (i, kind))
            t.append('%s pwg:identifierValue "%s"' % (i, value))
    return "PREFIX pwg: <%s>\nINSERT DATA {\n  %s .\n}" % (PWG, " .\n  ".join(t))


def build_forget_update():
    """Delete every fixture node and identifier, and nothing else."""
    return (
        "PREFIX pwg: <%s>\n"
        "DELETE { ?s ?p ?o } WHERE { ?s ?p ?o . "
        "FILTER(STRSTARTS(STR(?s), \"%s\") || STRSTARTS(STR(?s), \"%s\")) }"
        % (PWG, FIXTURE_PREFIX, ID_PREFIX)
    )


COUNT_Q = ("PREFIX pwg: <%s>\nSELECT (COUNT(DISTINCT ?i) AS ?n) WHERE "
           "{ ?i pwg:identifierType \"icloud_contact_uid\" }" % PWG)
FIXTURE_COUNT_Q = ("PREFIX pwg: <%s>\nSELECT (COUNT(DISTINCT ?s) AS ?n) WHERE "
                   "{ ?s a pwg:Person FILTER(STRSTARTS(STR(?s), \"%s\")) }" % (PWG, FIXTURE_PREFIX))


def store_headers(home):
    """The install's own store credential: store-curl.conf header lines, else the token file."""
    hdrs = {}
    try:
        for line in open(os.path.join(home, ".ostler", "secrets", "store-curl.conf")):
            m = re.match(r'\s*header\s*=\s*"?([^:"]+):\s*([^"]*)"?\s*$', line)
            if m:
                hdrs[m.group(1).strip()] = m.group(2).strip()
    except OSError:
        pass
    if not hdrs:
        tok = os.environ.get("OXIGRAPH_TOKEN") or ""
        if not tok:
            try:
                tok = open(os.path.join(home, ".ostler", "secrets", "oxigraph_token")).read().strip()
            except OSError:
                tok = ""
        if tok:
            hdrs["Authorization"] = "Bearer " + tok
    return hdrs


def _opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _query(store, headers, q, opener=None):
    h = {"Content-Type": "application/sparql-query", "Accept": "application/sparql-results+json"}
    h.update(headers)
    r = (opener or _opener()).open(urllib.request.Request(store + "/query", data=q.encode(), headers=h), timeout=30)
    b = json.loads(r.read().decode())["results"]["bindings"]
    return int(b[0]["n"]["value"]) if b else 0


def _update(store, headers, u, opener=None):
    h = {"Content-Type": "application/sparql-update"}
    h.update(headers)
    (opener or _opener()).open(urllib.request.Request(store + "/update", data=u.encode(), headers=h, method="POST"), timeout=30).read()


def seed(home, store="http://127.0.0.1:7878", opener=None):
    hdrs = store_headers(home)
    try:
        existing = _query(store, hdrs, COUNT_Q, opener)
    except Exception as e:
        return "failed-count-%s" % type(e).__name__
    if existing > 0:
        return "skipped-real-contacts"
    try:
        _update(store, hdrs, build_seed_update(), opener)
        # Read it back: a write the store acknowledged but did not keep must not
        # read as seeded.
        if _query(store, hdrs, FIXTURE_COUNT_Q, opener) != len(CARDS):
            return "failed-readback"
    except Exception as e:
        return "failed-write-%s" % type(e).__name__
    return "seeded"


def forget(home, store="http://127.0.0.1:7878", opener=None):
    hdrs = store_headers(home)
    try:
        if _query(store, hdrs, FIXTURE_COUNT_Q, opener) == 0:
            return "nothing-to-remove"
        _update(store, hdrs, build_forget_update(), opener)
        return "removed" if _query(store, hdrs, FIXTURE_COUNT_Q, opener) == 0 else "failed-still-present"
    except Exception as e:
        return "failed-%s" % type(e).__name__


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else ""
    home = os.path.expanduser("~")
    store = os.environ.get("OSTLER_OXIGRAPH_STORE", "http://127.0.0.1:7878")
    if cmd == "seed":
        print(seed(home, store))
    elif cmd == "forget":
        print(forget(home, store))
    else:
        print("usage: contact_cards_fixture.py seed|forget", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
