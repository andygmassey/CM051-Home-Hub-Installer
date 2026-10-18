"""DMG #27: 150 of 787 merges on a candidate box put a NAMED person into a
survivor whose displayName was a phone (145) or an email (5): the merge lost the
human name. The survivor now takes the highest-tier name among the merged nodes
(human > email > phone); two human names keep the existing rule. Real SPARQL
(pyoxigraph) over a synthetic graph, cast names only, on all three paths:
resolver.merge_persons, batch_resolver._merge_oxigraph, and the repair pass for
merges that already happened."""
import os
import sys
import tempfile
from pathlib import Path

import pyoxigraph as ox

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041"))
os.environ["OSTLER_PERSON_DELETION_LOG"] = os.path.join(tempfile.mkdtemp(), "removals.jsonl")

from identity_resolver import batch_resolver as br  # noqa: E402
from identity_resolver import repair_merge_consistency as rmc  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

PWG = br.PWG
PHONE = "+1 555 0100 01"
EMAIL = "jane.d@example.com"
KEEP = "https://example.invalid/person/keep"
DISC = "https://example.invalid/person/discard"


QDRANT_SYNCS = []


def _store(keep_names, disc_names, keep_live=True):
    st = ox.Store()
    rdf = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    for uri, names in ((KEEP, keep_names), (DISC, disc_names)):
        st.add(ox.Quad(ox.NamedNode(uri), rdf, ox.NamedNode(PWG + "Person"), ox.DefaultGraph()))
        for n in names:
            st.add(ox.Quad(ox.NamedNode(uri), ox.NamedNode(PWG + "displayName"), ox.Literal(n), ox.DefaultGraph()))
    return st


def _names(st, uri):
    r = st.query(f"SELECT ?n WHERE {{ <{uri}> <{PWG}displayName> ?n }}")
    return sorted(b["n"].value for b in r)


class _Resolver(IdentityResolver):
    def __init__(self, st):
        self.st, self.synced = st, []

    def _sparql_query(self, q):
        res = self.st.query(q)
        vars_ = [v.value for v in res.variables]
        return {"results": {"bindings": [{v: {"value": row[v].value} for v in vars_ if row[v] is not None}
                                         for row in res]}}

    def _sparql_update(self, q):
        self.st.update(q)

    def _sync_qdrant_display_name(self, uri, name):
        self.synced.append((uri, name))


def _patch_batch(st):
    def q(url, client, sparql):
        res = st.query(sparql)
        vars_ = [v.value for v in res.variables]
        return [{v: row[v].value for v in vars_ if row[v] is not None} for row in res]

    def u(url, client, sparql):
        st.update(sparql)
    for mod in (br, rmc):
        mod._sparql_query, mod._sparql_update = q, u
    QDRANT_SYNCS.clear()
    rmc._set_qdrant_display_name = lambda url, coll, uri, name: QDRANT_SYNCS.append((uri, name)) or True


def _via_resolver(keep, disc):
    st = _store(keep, disc)
    r = _Resolver(st)
    r.merge_persons(KEEP, DISC)
    return _names(st, KEEP), r.synced


def _via_batch(keep, disc):
    st = _store(keep, disc)
    _patch_batch(st)
    renamed = br._merge_oxigraph("u", None, KEEP, DISC)
    return _names(st, KEEP), renamed


CASES = (
    ("human beats phone", [PHONE], ["Jane Doe"], "Jane Doe"),
    ("email beats phone", [PHONE], [EMAIL], EMAIL),
    ("human beats email", [EMAIL], ["Jane Doe"], "Jane Doe"),
    ("two humans: the survivor keeps its own name (existing rule)", ["Jane Doe"], ["Sam Patel"], "Jane Doe"),
    ("a human survivor is never replaced by a phone", ["Jane Doe"], [PHONE], "Jane Doe"),
    ("phone vs phone: unchanged", [PHONE], ["+1 555 0100 02"], PHONE),
)


def test_resolver_path_survivor_takes_the_highest_tier():
    for label, keep, disc, want in CASES:
        got, _ = _via_resolver(keep, disc)
        assert got == [want], (label, got)


def test_resolver_path_syncs_the_renamed_survivor_to_the_hub_store():
    _, synced = _via_resolver([PHONE], ["Jane Doe"])
    assert synced == [(KEEP, "Jane Doe")]
    assert _via_resolver(["Jane Doe"], ["Sam Patel"])[1] == []      # existing rule: no rename, no sync


def test_batch_path_survivor_takes_the_highest_tier():
    for label, keep, disc, want in CASES:
        got, renamed = _via_batch(keep, disc)
        assert got == [want], (label, got)
    assert _via_batch([PHONE], ["Jane Doe"])[1] == "Jane Doe"
    assert _via_batch(["Jane Doe"], ["Sam Patel"])[1] is None


def _already_merged(survivor_name, source_name):
    """An EXISTING merge: live survivor, retired source carrying mergedInto."""
    st = _store([survivor_name], [source_name])
    st.update(f"INSERT DATA {{ <{DISC}> <{PWG}mergedInto> <{KEEP}> }} ; "
              f"DELETE DATA {{ <{DISC}> a <{PWG}Person> }} ; "
              f"INSERT DATA {{ <{DISC}> a <{PWG}RetiredPerson> }}")
    return st


def test_repair_renames_existing_merges_and_is_idempotent():
    st = _already_merged(PHONE, "Jane Doe")
    _patch_batch(st)
    examined, bad, left = rmc.rename_survivors_upward("o", "q", "people", apply=True)
    assert (examined, bad, left) == (1, 1, 0) and _names(st, KEEP) == ["Jane Doe"]
    assert QDRANT_SYNCS == [(KEEP, "Jane Doe")]                  # the Hub's People list reads Qdrant
    assert rmc.rename_survivors_upward("o", "q", "people", apply=True) == (1, 0, 0)     # second run finds zero


def test_repair_dry_run_changes_nothing_and_reports_the_count():
    st = _already_merged(PHONE, "Jane Doe")
    _patch_batch(st)
    assert rmc.rename_survivors_upward("o", "q", "people", apply=False) == (1, 1, 1)
    assert _names(st, KEEP) == [PHONE]


def test_repair_leaves_two_human_names_and_healthy_survivors_alone():
    for keep, src in (("Jane Doe", "Sam Patel"), ("Jane Doe", PHONE)):
        st = _already_merged(keep, src)
        _patch_batch(st)
        assert rmc.rename_survivors_upward("o", "q", "people", apply=True)[1] == 0
        assert _names(st, KEEP) == [keep]


def test_a_nameless_survivor_is_left_to_the_existing_copy_step():
    from identity_resolver.canonical_name import upward_name
    assert upward_name([], ["Jane Doe"]) is None            # not this rule's job
    assert _via_resolver([], ["Jane Doe"])[0] == ["Jane Doe"]   # the existing copy step still names it
    assert _via_resolver([], ["Jane Doe"])[1] == []             # and no upward rename was claimed


# -- the walk assertion: the probe's own SPARQL, extracted and run on a real engine --

def _probe_queries():
    import re
    src = (Path(__file__).resolve().parent.parent / "scripts" / "box_walk_probes" / "probes"
           / "no_person_holds_two_contact_cards.sh").read_text()
    var = lambda n: re.search(r"^%s='(.*)'$" % n, src, re.M).group(1)
    ph, em = var("_NAME_PHONE"), var("_NAME_EMAIL")
    out = []
    for name in ("_Q_NAME_TIER_BAD", "_Q_NAME_TIER_DENOM"):
        q = re.search(r'^%s="(.*?)"$' % name, src, re.M | re.S).group(1)
        q = q.replace("${ONTO}", PWG).replace('\\"', '"').replace("${_NAME_PHONE}", ph).replace("${_NAME_EMAIL}", em)
        out.append(q)
    return out


def _count(st, q):
    return int(next(iter(st.query(q)))["n"].value)


def test_walk_assertion_counts_phone_and_email_named_survivors():
    bad_q, den_q = _probe_queries()
    for survivor, expect in ((PHONE, 1), (EMAIL, 1), ("Jane Doe", 0)):
        st = _already_merged(survivor, "Jane Doe" if survivor != "Jane Doe" else "Sam Patel")
        assert (_count(st, bad_q), _count(st, den_q)) == (expect, 1), survivor
    st = _already_merged(PHONE, EMAIL)                        # no human name merged in: not this defect
    assert _count(st, bad_q) == 0
    st = _already_merged(PHONE, "Jane Doe")
    _patch_batch(st)
    rmc.rename_survivors_upward("o", "q", "people", apply=True)
    assert (_count(st, bad_q), _count(st, den_q)) == (0, 1)   # after the repair pass the walk count is 0


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
