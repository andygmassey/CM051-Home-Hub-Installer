#!/usr/bin/env python3
"""contact_cards_fixture.py -- synthetic Contacts for a COLD walk box, through the SHIPPED paths.

WHY. no_person_holds_two_contact_cards is BLOCKING and refuses to read a zero over
a graph with no icloud_contact_uid identifiers. A cold walk account has no Contacts
and no TCC grant to read any, so on v1.0.115 (walk34) it was CANNOT-RUN. The walk
has to supply cards. #3072 as first built wrote them straight into the graph:
no syncer, no resolver, no vector, every number unique. That turned CANNOT-RUN
into a VACUOUS PASS (zero collision opportunities, "GUARD IS UNEXERCISED") and
left six Persons with no Qdrant point, which fails people_stores_reconcile and
pushes people_count_agreement past its cap.

WHAT, NOW. Nothing here writes a triple or a vector itself. This file only builds
INPUT and names what to delete:

  cards_vcf()           a multi-vCard file, handed to the installed command
                        `python -m contact_syncer.syncer --vcf <file>`, the exact
                        line install.sh's hydrate_graph runs. The syncer's own
                        resolver writes the Persons, and its own embed + upsert
                        writes the Qdrant points.
  conversations_json()  one iMessage conversation for the nameless number, handed
                        to ostler_fda.pwg_ingest.ingest_imessage, then
                        ostler_fda.dedupe_merge.run(), the order install.sh runs.
  forget                deletes what those paths wrote for THIS cast, through the
                        syncer's own _delete_node_full (graph + Qdrant point).

THE CAST (reserved: registry cast tokens, example.com, Ofcom drama range):
  1-6  six distinct people, nothing shared.
  7    a household pair: card 2 and card 7 share a landline, different people,
       different icloud_contact_uid. The resolver and the sweep must keep them two
       (RULE 2). That is a REAL collision opportunity: two Person nodes share a
       phone, so the probe's opportunity count is non-zero and the guard is asked.
  8    a NAMELESS card on +447700900107, and the same number arriving as a bare
       handle through ingest. Exactly one Person must hold it afterwards.

SAFETY. seed runs only when the graph holds no icloud_contact_uid outside this
cast (a box with real contacts is measured as it is). forget touches only nodes
holding a cast uid, a cast phone or a cast email, plus the merge tombstones that
point at them.

State words, last line: seeded | skipped-real-contacts | failed-<reason>.
forget: removed | nothing-to-remove | failed-<reason>.
"""
import json
import os
import re
import sys

PWG = "https://schema.ostler.ai/ontology#"
UID_PREFIX = "WALKFIXTURE-CARD-"
NAMELESS_PHONE = "+447700900107"
HOUSEHOLD_PHONE = "+447700900102"

# (n, given, family, phones, emails, title)
CARDS = [
    (1, "Jonathan", "Min", ["+447700900101"], ["jonathan.min@example.com"], ""),
    (2, "John", "Smith", [HOUSEHOLD_PHONE], ["john.smith@example.com"], ""),
    (3, "Mary", "Jones", ["+447700900103"], ["mary.jones@example.com"], ""),
    (4, "Ben", "Wei", ["+447700900104"], ["ben.wei@example.com"], ""),
    (5, "Liz", "Brown", ["+447700900105"], ["liz.brown@example.com"], ""),
    (6, "Alex", "Ross", ["+447700900106"], ["alex.ross@example.com"], ""),
    (7, "Bob", "Smith", [HOUSEHOLD_PHONE], ["bob.smith@example.com"], ""),
    (8, "", "", [NAMELESS_PHONE], [], "Plumber"),
]


def card_uid(n):
    return "%s%d:ABPerson" % (UID_PREFIX, n)


def cast_uids():
    return [card_uid(c[0]) for c in CARDS]


def cast_values():
    """Every phone and email in the cast, the keys forget finds nodes by."""
    out = []
    for _n, _g, _f, phones, emails, _t in CARDS:
        out += list(phones) + list(emails)
    return sorted(set(out))


def cards_vcf(cards=CARDS):
    """One concatenated multi-vCard file, the shape an iCloud export has."""
    out = []
    for n, given, family, phones, emails, title in cards:
        out += ["BEGIN:VCARD", "VERSION:3.0", "UID:%s" % card_uid(n),
                "FN:%s" % ("%s %s" % (given, family)).strip(),
                "N:%s;%s;;;" % (family, given)]
        out += ["TEL;TYPE=CELL:%s" % p for p in phones]
        out += ["EMAIL;TYPE=HOME:%s" % e for e in emails]
        if title:
            out.append("TITLE:%s" % title)
        out.append("END:VCARD")
    return "\n".join(out) + "\n"


def conversations_json():
    """The nameless number as an iMessage handle (the iMessage stager's shape)."""
    return json.dumps([{"display_name": "", "participants": [NAMELESS_PHONE],
                        "message_count": 3, "last_message": "2026-10-01T10:00:00Z"}])


def _lit(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def real_contacts_q():
    """Count of icloud_contact_uid identifiers that are NOT this cast's."""
    return ("PREFIX pwg: <%s>\nSELECT (COUNT(DISTINCT ?i) AS ?n) WHERE {\n"
            '  ?i pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue ?v .\n'
            '  FILTER(!STRSTARTS(STR(?v), "%s")) }' % (PWG, UID_PREFIX))


def cast_nodes_q():
    """Every node holding a cast uid, phone or email."""
    vals = " ".join(_lit(v) for v in cast_uids() + cast_values())
    return ("PREFIX pwg: <%s>\nSELECT DISTINCT ?node WHERE {\n"
            "  ?node pwg:hasIdentifier ?id . ?id pwg:identifierValue ?v .\n"
            "  VALUES ?v { %s } }" % (PWG, vals))


def tombstones_q(nodes):
    """Untyped merge tombstones pointing at any of nodes."""
    vals = " ".join("<%s>" % n for n in nodes)
    return ("PREFIX pwg: <%s>\nSELECT DISTINCT ?node WHERE { ?node pwg:mergedInto ?t . VALUES ?t { %s } }"
            % (PWG, vals))


def _bindings(syncer, q, var="node"):
    data = syncer._sparql_query(q)
    return [b[var]["value"] for b in data.get("results", {}).get("bindings", [])]


def _scalar(syncer, q):
    b = syncer._sparql_query(q)["results"]["bindings"]
    return int(b[0]["n"]["value"]) if b else 0


def cast_present(syncer):
    return _bindings(syncer, cast_nodes_q())


def forget(syncer):
    """Delete the cast. Uses the shipped syncer's own full-node delete, so the
    graph triples AND the Qdrant point go together."""
    try:
        nodes = cast_present(syncer)
        if not nodes:
            return "nothing-to-remove"
        for t in _bindings(syncer, tombstones_q(nodes)):
            if t not in nodes:
                nodes.append(t)
        for n in nodes:
            syncer._delete_node_full(n)
        return "removed" if not cast_present(syncer) else "failed-still-present"
    except Exception as e:  # noqa: BLE001 -- the word is the report
        return "failed-%s" % type(e).__name__


def holders_q(value):
    """live persons holding exactly this identifier value."""
    return ("PREFIX pwg: <%s>\nSELECT (COUNT(DISTINCT ?p) AS ?n) WHERE {\n"
            "  ?p a pwg:Person ; pwg:hasIdentifier ?i . ?i pwg:identifierValue %s .\n"
            "  FILTER NOT EXISTS { ?p pwg:mergedInto ?x } }" % (PWG, _lit(value)))


def handle_ingested_q():
    """Identifiers on the nameless number that the iMessage ingest wrote (labelled
    IMESSAGE). Proves the handle ARRIVED through ingest, so one holder is a merge
    and not an absence."""
    return ("PREFIX pwg: <%s>\nSELECT (COUNT(DISTINCT ?i) AS ?n) WHERE {\n"
            '  ?i pwg:identifierLabel "IMESSAGE" ; pwg:identifierValue %s }' % (PWG, _lit(NAMELESS_PHONE)))


def merged_away_q():
    """Nodes merged INTO a cast node (the tombstoned side; a tombstone carries no
    identifiers of its own, so it is found by what it points at)."""
    vals = " ".join(_lit(v) for v in cast_uids() + cast_values())
    return ("PREFIX pwg: <%s>\nSELECT DISTINCT ?node WHERE {\n"
            "  ?node pwg:mergedInto ?t . ?t pwg:hasIdentifier ?i . ?i pwg:identifierValue ?v .\n"
            "  VALUES ?v { %s } }" % (PWG, vals))


def live_cast_persons_q():
    """live persons holding a cast icloud_contact_uid."""
    vals = " ".join(_lit(u) for u in cast_uids())
    return ("PREFIX pwg: <%s>\nSELECT DISTINCT ?node WHERE {\n"
            "  ?node a pwg:Person ; pwg:hasIdentifier ?i . ?i pwg:identifierValue ?v .\n"
            "  FILTER NOT EXISTS { ?node pwg:mergedInto ?x } VALUES ?v { %s } }" % (PWG, vals))


def verify(syncer):
    """What the shipped paths left, read back, fixture-scoped.

    nameless_holders      live Persons holding the nameless number. Must be 1.
    shared_holders        live Persons holding the household landline. Must be 2
                          (the guard kept them apart: a real collision opportunity).
    handle_ingested       IMESSAGE identifiers on the nameless number. Must be >= 1.
    cast_without_vector   live cast Persons with no Qdrant point. Must be 0.
    stale_vectors         Qdrant points still keyed on a merged-away cast node. Must be 0
                          (they would make the vector count exceed the graph's).
    """
    from qdrant_client.models import FieldCondition, Filter, MatchValue
    def has_point(u):
        pts, _ = syncer.qdrant.scroll(
            collection_name=syncer.cfg.QDRANT_COLLECTION, limit=1, with_payload=False,
            scroll_filter=Filter(must=[FieldCondition(key="person_uri", match=MatchValue(value=u))]))
        return bool(pts)

    persons = _bindings(syncer, live_cast_persons_q())
    missing = sum(1 for u in persons if not has_point(u))
    stale = sum(1 for u in _bindings(syncer, merged_away_q()) if has_point(u))
    return {"cast_persons": len(persons), "cast_without_vector": missing,
            "stale_vectors": stale,
            "nameless_holders": _scalar(syncer, holders_q(NAMELESS_PHONE)),
            "handle_ingested": _scalar(syncer, handle_ingested_q()),
            "shared_holders": _scalar(syncer, holders_q(HOUSEHOLD_PHONE))}


def verdict(v):
    """The state word for a verify() result. Pure, so a test can drive every arm."""
    if v["cast_persons"] != len(CARDS):
        return "failed-cast-persons-%d-of-%d" % (v["cast_persons"], len(CARDS))
    if v["cast_without_vector"]:
        return "failed-no-vector-%d" % v["cast_without_vector"]
    if v["stale_vectors"]:
        return "failed-stale-vector-%d" % v["stale_vectors"]
    if v["handle_ingested"] < 1:
        return "failed-handle-never-ingested"
    if v["nameless_holders"] != 1:
        return "failed-nameless-number-held-by-%d" % v["nameless_holders"]
    if v["shared_holders"] != 2:
        return "failed-household-line-held-by-%d" % v["shared_holders"]
    return "seeded"


def real_contacts_present(syncer):
    return _scalar(syncer, real_contacts_q())


def main(argv=None):
    """Box side, run from ~/.ostler/import-pipeline with its venv python.

    stage <dir>  write cards.vcf and imessage_conversations.json into <dir>
    forget       delete the cast (needs the pipeline venv: contact_syncer)
    guard        print the count of real (non-cast) Contacts cards
    verify       read back what the shipped paths left; last line is the state word
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else ""
    if cmd == "stage" and len(argv) == 2:
        os.makedirs(argv[1], exist_ok=True)
        with open(os.path.join(argv[1], "cards.vcf"), "w") as fh:
            fh.write(cards_vcf())
        with open(os.path.join(argv[1], "imessage_conversations.json"), "w") as fh:
            fh.write(conversations_json())
        print("staged")
        return 0
    if cmd in ("forget", "guard", "verify"):
        from contact_syncer.syncer import ContactSyncer
        s = ContactSyncer()
        if cmd == "forget":
            print(forget(s))
        elif cmd == "guard":
            print(real_contacts_present(s))
        else:
            v = verify(s)
            print(json.dumps(v, sort_keys=True))
            print(verdict(v))
        return 0
    print("usage: contact_cards_fixture.py stage <dir>|forget|guard|verify", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
