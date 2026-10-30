""""Not the same person? Split": the Hub's undo of an automatic merge.

Real BatchResolver (detect, execute, converge, undo) against the in-memory
rdflib store and in-memory Qdrant the exact-identifier suite already uses,
driven through the Doctor's REAL routes (FastAPI TestClient on web_ui.app).
SYNTHETIC DATA ONLY: invented names, example.com, Ofcom drama-range numbers.

What a customer must be able to do, and what each test pins:
  * see that a person was made by joining two cards, with both card names;
  * split them, after which there are two people again;
  * repeat the split safely (idempotent);
  * converge (twice) after the split and still have two people;
  * a split landing between a converge's plan and its execute must not be
    re-merged by the stale plan (the execute-time decision check).
"""
from __future__ import annotations

import json
import os
import sys

import pytest

pytest.importorskip("qdrant_client")
pytest.importorskip("yaml")
fastapi_testclient = pytest.importorskip("fastapi.testclient")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "vendor", "doctor", "agent"))

import test_exact_identifier_merge as tx  # noqa: E402  (store + fixtures)
from test_exact_identifier_merge import FakeStore, make, MOBILE_A, br  # noqa: E402

_no_qdrant = tx._no_qdrant  # autouse fixture, re-exported for this module

LOCAL = {"host": "127.0.0.1:8089"}


@pytest.fixture()
def box(tmp_path, monkeypatch):
    """A seeded synthetic box: two cards, same name, shared mobile and email,
    different card uids (the exact-identifier merge case), converged once."""
    corr = tmp_path / "corr"
    jdir = tmp_path / "bk" / "merge_journal"
    monkeypatch.setenv("WIKI_CORRECTIONS_DIR", str(corr))
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", str(jdir))
    s = FakeStore()
    a = s.person("aa11", "Jane Doe", phones=[MOBILE_A],
                 emails=["robin.vale@example.com"], uids=["uid-a"])
    b = s.person("bb22", "Jane Doe", phones=[MOBILE_A],
                 emails=["robin.vale@example.com"], uids=["uid-b"])
    s.g.update(f'INSERT DATA {{ <{b}> <{br.PWG}organization> "Acme Corp" }}')
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1, "precondition: the two cards were merged"

    import person_split

    def in_process_undo(merge_id):
        # The resolver's own undo, the same call --undo-merge makes, printing
        # the same JSON line the CLI prints (see test_cli_contract below).
        res = make(s, tmp_path).undo_merge(merge_id, backup_dir=str(tmp_path / "bk"))
        return 0, json.dumps(res) + "\n", ""

    monkeypatch.setattr(person_split, "_run_undo", in_process_undo)
    import web_ui
    client = fastapi_testclient.TestClient(web_ui.app)
    return {"store": s, "client": client, "tmp": tmp_path, "a": a, "b": b,
            "corr": corr, "jdir": jdir}


def _merges(box, person=""):
    q = f"?person={person}" if person else ""
    r = box["client"].get(f"/api/v1/merges{q}", headers=LOCAL)
    assert r.status_code == 200, r.text
    return r.json()


def _split(box, merge_id, headers=None):
    return box["client"].post("/api/v1/merges/split",
                              json={"merge_id": merge_id},
                              headers=headers if headers is not None else LOCAL)


def test_split_end_to_end_two_people_and_converge_twice_keeps_them(box):
    listed = _merges(box)
    assert listed["status"] == "ok" and len(listed["merges"]) == 1
    m = listed["merges"][0]
    names = sorted(c["name"] for c in m["cards"])
    assert names == ["Jane Doe", "Jane Doe"]            # names both cards
    assert "Acme Corp" in [c["detail"] for c in m["cards"]]
    assert set(m["shared"]) >= {"phone"} or set(m["shared"]) >= {"email"}

    r = _split(box, m["merge_id"])
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "split"
    assert len(box["store"].live()) == 2                     # two people again
    assert _merges(box)["merges"] == []                      # nothing left to split

    # The undo itself is journalled (by the resolver's own undo).
    lines = [json.loads(x) for x in
             (box["jdir"] / "merge_journal.jsonl").read_text().splitlines()]
    assert [e for e in lines if e["kind"] == "undo" and e["merge_id"] == m["merge_id"]]

    # Converge twice: still two people.
    for _ in range(2):
        make(box["store"], box["tmp"]).converge(backup_dir=str(box["tmp"] / "bk"))
        assert len(box["store"].live()) == 2


def test_split_is_idempotent(box):
    mid = _merges(box)["merges"][0]["merge_id"]
    assert _split(box, mid).json()["status"] == "split"
    again = _split(box, mid)
    assert again.status_code == 200
    assert again.json()["status"] == "already_split"
    assert len(box["store"].live()) == 2
    undos = [x for x in (box["jdir"] / "merge_journal.jsonl").read_text().splitlines()
             if '"undo"' in x]
    assert len(undos) == 1                                   # one undo, not two


def test_list_by_person_matches_row_ids_and_short_id(box):
    m = _merges(box)["merges"][0]
    assert _merges(box, m["person"])["merges"]
    assert _merges(box, m["person_ids"][0])["merges"]
    assert _merges(box, "ffffffffffff")["merges"] == []


def test_unknown_and_malformed_ids_change_nothing(box):
    assert _split(box, "20990101T000000Z-deadbeef").status_code == 404
    assert _split(box, "../../etc").status_code == 400
    assert len(box["store"].live()) == 1


def test_write_refused_cross_site_and_off_box(box):
    mid = _merges(box)["merges"][0]["merge_id"]
    r = _split(box, mid, headers={**LOCAL, "origin": "https://evil.example"})
    assert r.status_code == 403
    r = _split(box, mid, headers={"host": "192.0.2.10:8089"})
    assert r.status_code == 403
    assert len(box["store"].live()) == 1                     # refused = unchanged


def test_unreadable_journal_is_an_outage_not_an_empty_list(box, monkeypatch):
    j = box["jdir"] / "merge_journal.jsonl"
    os.chmod(j, 0)
    try:
        if os.access(j, os.R_OK):
            pytest.skip("running as a user that can read a 000 file")
        r = box["client"].get("/api/v1/merges", headers=LOCAL)
        assert r.status_code == 503 and r.json()["status"] == "cannot_run"
    finally:
        os.chmod(j, 0o600)


def test_a_split_between_plan_and_execute_is_not_remerged(tmp_path, monkeypatch):
    """The window the execute-time check closes: converge planned the merge
    (detect), then the customer split them (the distinct decision landed),
    then execute ran the stale plan. Without the check it re-merges."""
    corr = tmp_path / "corr"
    s = FakeStore()
    a = s.person("cc33", "Jane Doe", phones=[MOBILE_A], uids=["uid-c"])
    b = s.person("dd44", "Jane Doe", phones=[MOBILE_A], uids=["uid-d"])
    r = make(s, tmp_path)
    report = r.detect()
    assert report.auto_merges, "precondition: the pair is planned"
    corr.mkdir(parents=True, exist_ok=True)
    (corr / "duplicates.yaml").write_text(
        "decisions:\n- distinct: [cc33, dd44]\n", encoding="utf-8")
    r.execute(report, backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 2


def test_cli_contract_undo_prints_the_json_line_the_route_parses(tmp_path, monkeypatch, capsys):
    """Both sides of the subprocess boundary: the real CLI main() prints one
    JSON line, and person_split parses exactly that line."""
    import person_split
    s = FakeStore()
    s.person("ee55", "Jane Doe", phones=[MOBILE_A], uids=["uid-e"])
    s.person("ff66", "Jane Doe", phones=[MOBILE_A], uids=["uid-f"])
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    mid = tx.merge_entries(tmp_path)[0]["id"]
    real_init = br.BatchResolver.__init__

    def init(self, *a, **k):
        real_init(self, *a, **k)
        self._client = s.client()
        self.config["corrections_dir"] = str(tmp_path / "corr")
    monkeypatch.setattr(br.BatchResolver, "__init__", init)
    monkeypatch.setattr(sys, "argv", ["batch_resolver", "--undo-merge", mid,
                                      "--backup-dir", str(tmp_path / "bk")])
    br.main()
    out = capsys.readouterr().out
    parsed = person_split._last_json_line(out)
    assert parsed.get("merge_id") == mid
    assert len(s.live()) == 2


def test_control_without_the_decision_converge_remerges(box, monkeypatch):
    """Negative control for the converge-twice assertion above: the same
    split with NO "different people" decision anywhere (the route's write and
    the undo's own pin both disabled) is re-merged by the very next converge.
    So 'still two people' is measuring the decision, not a dead converge."""
    import person_split
    from identity_resolver import merge_journal
    monkeypatch.setattr(person_split, "_record_distinct", lambda k, d: {})
    monkeypatch.setattr(merge_journal, "_pin_distinct", lambda *a, **k: False)
    mid = _merges(box)["merges"][0]["merge_id"]
    assert _split(box, mid).json()["status"] == "split"
    assert len(box["store"].live()) == 2
    make(box["store"], box["tmp"]).converge(backup_dir=str(box["tmp"] / "bk"))
    assert len(box["store"].live()) == 1                     # re-merged
