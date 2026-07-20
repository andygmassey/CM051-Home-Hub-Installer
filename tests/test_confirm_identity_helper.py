#!/usr/bin/env python3
"""Tests for lib/ostler-confirm-identity.py (propose-and-confirm identity).

Verifies: name matching, the self-vs-namesake scoring (design §2), and that a
recorded decision is written in the EXACT schema the CM041 resolver consumer
(identity_resolver/decisions.py) parses back.

All fixtures are SYNTHETIC. No real personal data. See
PRODUCTISATION_CHECKLIST.md Rule 0.
"""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "confirm_identity", str(REPO / "lib" / "ostler-confirm-identity.py")
)
ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci)

NS = ci.PWG_NS


def _cand(uri, name, domains=(), linkedin=(), orgs=(), is_owner=False):
    return {
        "uri": uri,
        "sid": ci.short_id(uri),
        "name": name,
        "email_domains": set(domains),
        "linkedin": set(linkedin),
        "orgs": set(orgs),
        "is_owner": is_owner,
    }


def test_short_id_matches_consumer():
    assert ci.short_id(f"{NS}person_7d33241d6e9e") == "7d33241d6e9e"
    # owner node round-trips consistently (same fn both sides)
    assert ci.short_id(f"{NS}user_5") == ci.short_id(ci.owner_uri("5"))


def test_names_match():
    assert ci.names_match("Jane Doe", "Jane Doe")
    assert ci.names_match("Jane Doe", "Jane A Doe")
    assert not ci.names_match("Jane Doe", "John Smith")
    assert not ci.names_match("Jane Doe", "")


def test_collapse_on_shared_hardid():
    owner = _cand(ci.owner_uri("5"), "Jane Doe", domains={"own.com"},
                  linkedin={"linkedin.com/in/janedoe"}, is_owner=True)
    frag = _cand(f"{NS}person_bbbb", "Jane Doe", domains={"own.com"})
    scored = ci.score_candidates(owner, [owner, frag])
    assert [c["sid"] for c in scored["collapse"]] == ["bbbb"]
    assert scored["namesakes"] == []


def test_namesake_on_diverging_hardid():
    owner = _cand(ci.owner_uri("5"), "Jane Doe",
                  linkedin={"linkedin.com/in/janedoe"}, orgs={"acme"}, is_owner=True)
    # A pilot who shares the name: different LinkedIn, disjoint employer.
    pilot = _cand(f"{NS}person_cccc", "Jane Doe",
                  linkedin={"linkedin.com/in/jane-pilot"}, orgs={"skyair"})
    scored = ci.score_candidates(owner, [owner, pilot])
    assert scored["collapse"] == []
    assert [c["sid"] for c in scored["namesakes"]] == ["cccc"]
    assert any("different LinkedIn" in e for e in scored["namesakes"][0]["evidence"])


def test_name_only_match_proposes_nothing():
    owner = _cand(ci.owner_uri("5"), "Jane Doe", is_owner=True)
    ghost = _cand(f"{NS}person_dddd", "Jane Doe")  # no hard signals either way
    scored = ci.score_candidates(owner, [owner, ghost])
    assert scored["collapse"] == [] and scored["namesakes"] == []


def test_build_candidates_from_rows():
    rows = [
        {"person": ci.owner_uri("5"), "name": "Jane Doe", "isOwner": "true",
         "idType": "email", "idValue": "jane@own.com"},
        {"person": ci.owner_uri("5"), "name": "Jane Doe",
         "idType": "linkedin_url", "idValue": "https://linkedin.com/in/janedoe"},
        {"person": f"{NS}person_bbbb", "name": "Jane Doe",
         "idType": "email", "idValue": "j.doe@own.com"},
    ]
    by_uri = ci.build_candidates(rows, ci.owner_uri("5"))
    owner = by_uri[ci.owner_uri("5")]
    assert owner["is_owner"] is True
    assert "own.com" in owner["email_domains"]
    assert any("janedoe" in li for li in owner["linkedin"])


def test_propose_cli_from_json(capsys=None):
    import io
    from contextlib import redirect_stdout
    fixture = {
        "rows": [
            {"person": ci.owner_uri("5"), "name": "Jane Doe", "isOwner": "true",
             "idType": "linkedin_url", "idValue": "https://linkedin.com/in/janedoe"},
            {"person": ci.owner_uri("5"), "name": "Jane Doe",
             "idType": "email", "idValue": "jane@own.com"},
            # two self-fragments sharing the operator's domain -> COLLAPSE group
            {"person": f"{NS}person_bbbb", "name": "Jane Doe",
             "idType": "email", "idValue": "j@own.com"},
            {"person": f"{NS}person_bbb2", "name": "Jane Doe",
             "idType": "email", "idValue": "jane.doe@own.com"},
            # a namesake with a diverging LinkedIn -> NAMESAKE veto
            {"person": f"{NS}person_cccc", "name": "Jane Doe",
             "idType": "linkedin_url", "idValue": "https://linkedin.com/in/jane-pilot"},
        ]
    }
    with tempfile.TemporaryDirectory() as d:
        fp = os.path.join(d, "fx.json")
        import json
        with open(fp, "w") as f:
            json.dump(fixture, f)
        buf = io.StringIO()
        with redirect_stdout(buf):
            ci.main(["propose", "--user-id", "5", "--from-json", fp])
        out = buf.getvalue().strip().splitlines()
    kinds = {line.split("\t")[0] for line in out}
    assert "COLLAPSE" in kinds  # bbbb + bbb2 share domain (>=2 fragments)
    assert "NAMESAKE" in kinds  # cccc diverging linkedin
    collapse_line = [l for l in out if l.startswith("COLLAPSE")][0]
    ids = collapse_line.split("\t")[1].split(",")
    # SAFETY: fragments only; the owner user_<id> node is NEVER in the group.
    assert "bbbb" in ids and "bbb2" in ids
    assert ci.short_id(ci.owner_uri("5")) not in ids


def test_single_fragment_never_collapses_owner(tmp_path=None):
    """SAFETY: a lone self-fragment must NOT produce a COLLAPSE proposal, so
    the owner user_<id> node can never be tombstoned by pick_canonical."""
    import io
    import json
    from contextlib import redirect_stdout
    fixture = {"rows": [
        {"person": ci.owner_uri("5"), "name": "Jane Doe", "isOwner": "true",
         "idType": "email", "idValue": "jane@own.com"},
        {"person": f"{NS}person_bbbb", "name": "Jane Doe",
         "idType": "email", "idValue": "j@own.com"},
    ]}
    with tempfile.TemporaryDirectory() as d:
        fp = os.path.join(d, "fx.json")
        with open(fp, "w") as f:
            json.dump(fixture, f)
        buf = io.StringIO()
        with redirect_stdout(buf):
            ci.main(["propose", "--user-id", "5", "--from-json", fp])
        out = buf.getvalue()
    assert "COLLAPSE" not in out


def test_record_writes_consumer_schema():
    """write_decisions output must be parseable by the real consumer.

    NOTE: the merge group is fragment-only (``bbbb`` + ``bbb2``); the owner
    ``user_5`` is a legitimate half of the *distinct* (namesake) pair but must
    never appear in a merge -- see test_record_rejects_owner_sid_merge.
    """
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "corrections", "duplicates.yaml")
        ci.write_decisions(path, merges=[["bbbb", "bbb2"]],
                           distinct_pairs=[["user_5", "cccc"]])
        # idempotent second write adds nothing
        r2 = ci.write_decisions(path, merges=[["bbbb", "bbb2"]],
                                distinct_pairs=[["user_5", "cccc"]])
        assert r2["added"] == []

        # Parse it exactly the way decisions.load_duplicate_decisions does.
        import yaml
        from itertools import combinations
        data = yaml.safe_load(open(path).read())
        merge_groups, distinct_pairs = [], set()
        for entry in data.get("decisions") or []:
            m = entry.get("merge")
            if isinstance(m, list) and len(m) >= 2:
                merge_groups.append({str(x).strip() for x in m})
            di = entry.get("distinct")
            if isinstance(di, list) and len(di) >= 2:
                ids = [str(x).strip() for x in di]
                for a, b in combinations(ids, 2):
                    distinct_pairs.add(frozenset((a, b)))
        assert {"bbbb", "bbb2"} in merge_groups
        assert frozenset(("user_5", "cccc")) in distinct_pairs


def test_bug_shared_domain_different_linkedin_is_namesake():
    """BUG (Archie #5 F2): a same-domain colleague with a DIFFERENT LinkedIn is
    a namesake SPLIT, never a COLLAPSE. Divergent LinkedIn is decisive and must
    override the shared email domain."""
    owner = _cand(ci.owner_uri("5"), "Jane Doe", domains={"acme.com"},
                  linkedin={"linkedin.com/in/janedoe"}, is_owner=True)
    # Colleague at the SAME company (shared domain) but a DIFFERENT LinkedIn.
    colleague = _cand(f"{NS}person_eeee", "Jane Doe", domains={"acme.com"},
                      linkedin={"linkedin.com/in/jane-colleague"})
    scored = ci.score_candidates(owner, [owner, colleague])
    assert scored["collapse"] == []  # must NOT propose a merge against the operator
    assert [c["sid"] for c in scored["namesakes"]] == ["eeee"]
    assert any("different LinkedIn" in e for e in scored["namesakes"][0]["evidence"])


def test_bug_shared_domain_disjoint_jobhistory_is_namesake():
    """BUG (Archie #5 F2): distinct job history is also a decisive divergence --
    shared domain alone must not merge."""
    owner = _cand(ci.owner_uri("5"), "Jane Doe", domains={"acme.com"},
                  orgs={"acme corp"}, is_owner=True)
    colleague = _cand(f"{NS}person_ffff", "Jane Doe", domains={"acme.com"},
                      orgs={"skyair aviation"})
    scored = ci.score_candidates(owner, [owner, colleague])
    assert scored["collapse"] == []
    assert [c["sid"] for c in scored["namesakes"]] == ["ffff"]


def test_shared_linkedin_still_collapses_despite_disjoint_orgs():
    """Guard the precedence: a SHARED LinkedIn is decisive same-person and must
    still COLLAPSE even if job history (orgs) diverges over time."""
    owner = _cand(ci.owner_uri("5"), "Jane Doe",
                  linkedin={"linkedin.com/in/janedoe"}, orgs={"oldco"}, is_owner=True)
    frag = _cand(f"{NS}person_aaaa", "Jane Doe",
                 linkedin={"linkedin.com/in/janedoe"}, orgs={"newco"})
    scored = ci.score_candidates(owner, [owner, frag])
    assert [c["sid"] for c in scored["collapse"]] == ["aaaa"]
    assert scored["namesakes"] == []


def test_record_rejects_owner_sid_merge():
    """CRITICAL (Archie #5 F1): the RECORDER independently rejects any merge
    naming the operator's own owner sid, even bypassing the proposer."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "corrections", "duplicates.yaml")
        # Direct write_decisions call with an owner-shaped sid in the merge.
        for owner_sid in ("user_5", "ontology#user_5"):
            res = ci.write_decisions(path, merges=[[owner_sid, "bbbb"]], distinct_pairs=[])
            assert res["added"] == []
            assert any(r.get("reason") == "owner-sid" for r in res["rejected"])
        # Nothing owner-shaped was ever persisted.
        import yaml
        data = yaml.safe_load(open(path).read()) if os.path.exists(path) else {"decisions": []}
        for entry in data.get("decisions") or []:
            m = entry.get("merge") or []
            assert not any(ci._is_owner_sid(str(x)) for x in m)


def test_record_cli_rejects_owner_sid_merge():
    """The --record CLI path (what install.sh drives) also rejects an owner
    merge but still honours a legitimate namesake distinct pair carrying it."""
    import io
    import json as _json
    from contextlib import redirect_stdout
    with tempfile.TemporaryDirectory() as d:
        buf = io.StringIO()
        with redirect_stdout(buf):
            ci.main(["record", "--corrections-dir", d,
                     "--merge", "ontology#user_5,bbbb",
                     "--distinct", "ontology#user_5,cccc"])
        result = _json.loads(buf.getvalue().strip())
        # merge rejected, distinct (namesake veto with owner sid) recorded
        assert not any("merge" in a for a in result["added"])
        assert any("distinct" in a for a in result["added"])
        import yaml
        path = os.path.join(d, "duplicates.yaml")
        data = yaml.safe_load(open(path).read())
        assert not any(e.get("merge") for e in data["decisions"])
        assert {"ontology#user_5", "cccc"} in [
            set(e["distinct"]) for e in data["decisions"] if e.get("distinct")
        ]


def test_record_scrubs_injected_owner_merge_from_file():
    """Defence in depth: a hand-edited / injected duplicates.yaml carrying an
    owner-sid merge is scrubbed on the next record, not preserved."""
    import yaml
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "duplicates.yaml")
        with open(path, "w") as f:
            yaml.safe_dump({"decisions": [{"merge": ["user_5", "bbbb"]}]}, f)
        res = ci.write_decisions(path, merges=[["cccc", "dddd"]], distinct_pairs=[])
        assert any(r.get("reason") == "owner-sid" for r in res["rejected"])
        data = yaml.safe_load(open(path).read())
        merges = [e["merge"] for e in data["decisions"] if e.get("merge")]
        # injected owner merge gone; the legitimate fragment merge remains
        assert ["cccc", "dddd"] in merges
        assert not any(ci._is_owner_sid(str(x)) for m in merges for x in m)


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\nPASS: {len(fns)} identity-confirm tests")
