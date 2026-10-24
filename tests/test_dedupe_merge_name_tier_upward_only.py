"""DMG #27 KNOWN-ISSUE 1: the exact-identifier sweep (ostler_fda.dedupe_merge)
must obey the name-tier rule too. phone < email < human, and a name only moves UP.

Why this file exists. #2857 (landed via #2858) put the tier rule into
resolver.merge_persons and batch_resolver._merge_oxigraph, and taught the
install-time repair to fix survivors that already existed. The walk still ended
with 158 of 898 merge survivors carrying a phone/email displayName next to a
human-named merged-in node. Measured on the walk box, read-only: every one of
the 257 survivors holding a mixed set of displayName values (human AND
phone/email) has a merged-in node with NO pwg:mergedAt, which is the signature
of dedupe_merge (the other two writers always stamp mergedAt). dedupe_merge
moves EVERY triple of the duplicate onto the survivor, displayName included,
and never chose between them. It also runs AFTER the repair step in install.sh,
so the repair saw a clean graph and dedupe_merge then undid it.

Real SPARQL (pyoxigraph) over a synthetic graph, cast names only.
"""
import os
import sys
import tempfile
from pathlib import Path

import pyoxigraph as ox

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "vendor" / "cm041"))
os.environ["OSTLER_PERSON_DELETION_LOG"] = os.path.join(tempfile.mkdtemp(), "removals.jsonl")

from ostler_fda import dedupe_merge as dm  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

PWG = dm.PWG
RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
PHONE = "+1 555 0100 01"
EMAIL = "jane.d@example.com"
HUMAN = "Jane Doe"

FAILS = []


def check(cond, msg):
    print(("  [PASS] " if cond else "  [FAIL] ") + msg)
    if not cond:
        FAILS.append(msg)


def _lit(v):
    return ox.Literal(v)


def build(people):
    """people: {uri: {"names": [...], "phone": [...], "email": [...], "provisional": bool}}"""
    st = ox.Store()
    g = ox.DefaultGraph()
    for i, (uri, d) in enumerate(people.items()):
        s = ox.NamedNode(uri)
        st.add(ox.Quad(s, ox.NamedNode(RDF_TYPE), ox.NamedNode(PWG + "Person"), g))
        for n in d.get("names", []):
            st.add(ox.Quad(s, ox.NamedNode(PWG + "displayName"), _lit(n), g))
        if d.get("provisional"):
            st.add(ox.Quad(s, ox.NamedNode(PWG + "displayNameProvisional"),
                           ox.Literal("true", datatype=ox.NamedNode("http://www.w3.org/2001/XMLSchema#boolean")), g))
        for j, (typ, vals) in enumerate((("phone", d.get("phone", [])), ("email", d.get("email", [])))):
            for k, v in enumerate(vals):
                idn = ox.NamedNode(f"{uri}#id_{typ}_{k}")
                st.add(ox.Quad(s, ox.NamedNode(PWG + "hasIdentifier"), idn, g))
                st.add(ox.Quad(idn, ox.NamedNode(PWG + "identifierType"), _lit(typ), g))
                st.add(ox.Quad(idn, ox.NamedNode(PWG + "identifierValue"), _lit(v), g))
    return st


def wire(st):
    def q(sparql):
        res = st.query(sparql)
        vars_ = [v.value for v in res.variables]
        return [{v: {"value": row[v].value} for v in vars_ if row[v] is not None} for row in res]

    def u(sparql):
        st.update(sparql)
    dm._sparql_query, dm._sparql_update = q, u


def names(st, uri, pred="displayName"):
    return sorted(b["n"].value for b in st.query(f"SELECT ?n WHERE {{ <{uri}> <{PWG}{pred}> ?n }}"))


def provisional(st, uri):
    return bool(list(st.query(f"SELECT ?v WHERE {{ <{uri}> <{PWG}displayNameProvisional> ?v }}")))


def sweep(people):
    st = build(people)
    wire(st)
    dm.run()
    return st


# URIs sort so the FIRST one is the canonical (dedupe picks the smallest URI).
A, B, C = ("https://example.invalid/person/a", "https://example.invalid/person/b",
           "https://example.invalid/person/c")


def main():
    print("1. phone-named canonical + human-named duplicate (shared phone) -> human, one value")
    st = sweep({A: {"names": [PHONE], "phone": ["+1555010001"], "provisional": True},
                B: {"names": [HUMAN], "phone": ["+1555010001"]}})
    check(names(st, A) == [HUMAN], f"survivor displayName == [{HUMAN!r}] (got {names(st, A)})")
    check(PHONE in names(st, A, "alternateName"), "the phone label is demoted to alternateName, not lost")
    check(not provisional(st, A), "a human name clears displayNameProvisional")

    print("2. human-named canonical + phone-named duplicate -> stays human, one value")
    st = sweep({A: {"names": [HUMAN], "phone": ["+1555010002"]},
                B: {"names": [PHONE], "phone": ["+1555010002"], "provisional": True}})
    check(names(st, A) == [HUMAN], f"survivor displayName == [{HUMAN!r}] (got {names(st, A)})")
    check(not provisional(st, A), "the duplicate's provisional flag does not land on a human-named survivor")

    print("3. phone -> email -> human across one component (phone + email bridge)")
    st = sweep({A: {"names": [PHONE], "phone": ["+1555010003"], "provisional": True},
                B: {"names": [EMAIL], "phone": ["+1555010003"], "email": [EMAIL]},
                C: {"names": [HUMAN], "email": [EMAIL]}})
    check(names(st, A) == [HUMAN], f"survivor displayName == [{HUMAN!r}] (got {names(st, A)})")

    print("4. phone-named canonical + email-named duplicate -> email (one step up)")
    st = sweep({A: {"names": [PHONE], "phone": ["+1555010004"]},
                B: {"names": [EMAIL], "phone": ["+1555010004"]}})
    check(names(st, A) == [EMAIL], f"survivor displayName == [{EMAIL!r}] (got {names(st, A)})")

    # The shared key is an EMAIL: since P16 a shared PHONE alone never joins
    # two differently named people (a household landline), see
    # tests/test_dedupe_merge_shared_phone_needs_same_name.py.
    print("5. equal tiers: two human names -> the survivor keeps its own")
    st = sweep({A: {"names": ["Jane Doe"], "email": ["jane.d@example.invalid"]},
                B: {"names": ["Jane Smith"], "email": ["jane.d@example.invalid"]}})
    check(names(st, A) == ["Jane Doe"], f"survivor keeps its own human name (got {names(st, A)})")
    check("Jane Smith" in names(st, A, "alternateName"), "the other human name is kept as alternateName")

    print("6. never downward: email-named canonical + phone-named duplicate -> email")
    st = sweep({A: {"names": [EMAIL], "phone": ["+1555010006"]},
                B: {"names": [PHONE], "phone": ["+1555010006"]}})
    check(names(st, A) == [EMAIL], f"survivor displayName == [{EMAIL!r}] (got {names(st, A)})")

    print("7. SEQUENCE across writers: dedupe sweep, then a later resolver merge of a phone-named node")
    st = sweep({A: {"names": [PHONE], "phone": ["+1555010007"], "provisional": True},
                B: {"names": [HUMAN], "phone": ["+1555010007"]}})
    st.add(ox.Quad(ox.NamedNode(C), ox.NamedNode(RDF_TYPE), ox.NamedNode(PWG + "Person"), ox.DefaultGraph()))
    st.add(ox.Quad(ox.NamedNode(C), ox.NamedNode(PWG + "displayName"), _lit("+1 555 0100 99"), ox.DefaultGraph()))

    class R(IdentityResolver):
        def __init__(self, s):
            self.st = s

        def _sparql_query(self, sparql):
            res = self.st.query(sparql)
            vars_ = [v.value for v in res.variables]
            return {"results": {"bindings": [{v: {"value": row[v].value} for v in vars_ if row[v] is not None}
                                             for row in res]}}

        def _sparql_update(self, sparql):
            self.st.update(sparql)

        def _sync_qdrant_display_name(self, uri, name):
            pass
    R(st).merge_persons(A, C)
    check(names(st, A) == [HUMAN], f"after the full sequence the survivor is [{HUMAN!r}] (got {names(st, A)})")

    print("8. a kinship label is never the displayName, and never deleted: it becomes an alternateName")
    st = sweep({A: {"names": ["Mum"], "phone": ["+1555010008"], "provisional": True},
                B: {"names": [HUMAN], "phone": ["+1555010008"]}})
    check(names(st, A) == [HUMAN], f"survivor displayName == [{HUMAN!r}] (got {names(st, A)})")
    check("Mum" in names(st, A, "alternateName"),
          f"the kinship label survives as an alternateName (got {names(st, A, 'alternateName')})")
    st = sweep({A: {"names": [HUMAN], "phone": ["+1555010009"]},
                B: {"names": ["Dad"], "phone": ["+1555010009"]}})
    check(names(st, A) == [HUMAN] and "Dad" in names(st, A, "alternateName"),
          "a kinship label on the duplicate is kept too, and does not displace the human name")

    print(f"\n{len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
