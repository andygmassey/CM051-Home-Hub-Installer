"""The brief's meeting-history and last-conversation readers withhold L3.

Both feed the pre-meeting brief, which leaves the box. ``_get_person_facts``
already filtered L3 (fail closed, most-restrictive of the item and its
owner); these two did not. Runs the shipped functions against a real SPARQL
engine (rdflib Dataset), not canned bindings, so the query text is exercised.

Level rules asserted (same as ``_get_person_facts`` / ``pwg_privacy.is_l3``):
  * L3 item hidden; L1 control returned;
  * meeting with no level, attendee L2 -> kept (owner clears it);
  * meeting with no level, attendee untagged -> hidden (fail closed);
  * unparseable level -> hidden;
  * conversation id: the L3 fact must not mask a visible, older one (the
    filter runs BEFORE the "most recent" pick).

Synthetic data only.
"""
from __future__ import annotations

import unittest

import sys
from pathlib import Path

# VENDORED COPY of CM041 meeting_syncer/tests/test_brief_outbound_l3.py,
# pointed at vendor/cm041 (the tree that ships).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041"))

from meeting_syncer import brief  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
PERSON = "urn:ostler:person/synthetic-attendee"
BARE = "urn:ostler:person/synthetic-bare"


def _store(triples):
    from rdflib import Dataset, Literal, URIRef

    ds = Dataset(default_union=False)
    g = getattr(ds, "default_graph", None) or ds.default_context
    for s, p, o in triples:
        g.add((URIRef(s), URIRef(p), Literal(o) if not o.startswith("urn:") and not o.startswith("http") else URIRef(o)))

    def query(_url, sparql):
        rows = ds.query(sparql)
        out = []
        for row in rows:
            out.append({str(v): {"value": str(row[v])} for v in rows.vars if row[v] is not None})
        return {"results": {"bindings": out}}

    return query


RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"


def _meeting(mid, summary, level, attendee=PERSON, date="2026-01-01"):
    m = "urn:ostler:meeting/" + mid
    t = [(m, RDF_TYPE, PWG + "Meeting"), (m, PWG + "meetingAttendee", attendee),
         (m, PWG + "meetingSummary", summary), (m, PWG + "meetingDate", date)]
    if level is not None:
        t.append((m, PWG + "privacyLevel", level))
    return t


def _conv(fid, cid, date, level):
    f, c = "urn:ostler:fact/" + fid, "urn:ostler:conversation/" + cid
    t = [(f, "urn:ostler:about", PERSON), (f, "urn:ostler:fromConversation", c),
         (c, "urn:ostler:date", date)]
    if level is not None:
        t.append((f, "urn:ostler:privacyLevel", level))
    return t


def _meetings(triples, person=PERSON):
    q = _store(triples)
    orig, brief._sparql_query = brief._sparql_query, q
    try:
        return [m["summary"] for m in brief._get_meeting_history("x", person)]
    finally:
        brief._sparql_query = orig


def _conv_id(triples):
    q = _store(triples)
    orig, brief._sparql_query = brief._sparql_query, q
    try:
        return brief._get_last_conversation_id("x", PERSON)
    finally:
        brief._sparql_query = orig


class MeetingHistoryL3(unittest.TestCase):
    def test_l3_meeting_absent_l1_control_present(self):
        got = _meetings(_meeting("a", "SYNTH-L1", "L1") + _meeting("b", "SYNTH-L3", "L3"))
        self.assertEqual(got, ["SYNTH-L1"])

    def test_person_l3_hides_an_l1_meeting(self):
        t = _meeting("a", "SYNTH-L1", "L1") + [(PERSON, PWG + "privacyLevel", "L3")]
        self.assertEqual(_meetings(t), [])

    def test_untagged_meeting_on_l2_person_kept(self):
        t = _meeting("a", "SYNTH-UNTAGGED", None) + [(PERSON, PWG + "privacyLevel", "L2")]
        self.assertEqual(_meetings(t), ["SYNTH-UNTAGGED"])

    def test_untagged_meeting_on_untagged_person_hidden(self):
        self.assertEqual(_meetings(_meeting("a", "SYNTH-UNTAGGED", None)), [])

    def test_unparseable_level_hidden(self):
        self.assertEqual(_meetings(_meeting("a", "SYNTH-BAD", "banana")), [])


class LastConversationL3(unittest.TestCase):
    def test_l3_fact_conversation_absent_l1_control_returned(self):
        t = _conv("f1", "convL1", "2026-01-01", "L1") + _conv("f3", "convL3", "2026-02-01", "L3")
        self.assertEqual(_conv_id(t), "convL1")

    def test_only_l3_gives_empty(self):
        self.assertEqual(_conv_id(_conv("f3", "convL3", "2026-02-01", "L3")), "")

    def test_untagged_fact_hidden(self):
        self.assertEqual(_conv_id(_conv("f1", "convX", "2026-01-01", None)), "")

    def test_unparseable_level_hidden(self):
        self.assertEqual(_conv_id(_conv("f1", "convX", "2026-01-01", "banana")), "")


if __name__ == "__main__":
    unittest.main()
