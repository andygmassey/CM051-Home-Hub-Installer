"""Every writer that can remove a Person leaves a record (walk #15).

Walk #15 left one orphan vector whose node had no triples and no record of who
removed it. A prune that clears such a vector must not turn a person lost to an
unknown writer into silence, so each Person-removing writer appends to
~/.ostler/logs/person-deletions.jsonl BEFORE it removes, and
people_stores_reconcile joins each orphan to that record by URI digest.

All names and URIs are synthetic. The log is redirected to a temp file by an
autouse fixture; nothing here touches a real box or home directory.

RED/GREEN: run with OSTLER_TEST_VENDOR_ROOT pointing at a pristine export of
origin/main's vendor tree and every writer test fails; against this branch they
pass (see the PR body for the counts).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import types
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
VENDOR = Path(os.environ.get("OSTLER_TEST_VENDOR_ROOT") or (REPO / "vendor"))
sys.path.insert(0, str(VENDOR))
sys.path.insert(0, str(VENDOR / "cm041"))

DISCARD = "https://schema.ostler.ai/ontology#person_aaaa00000001"
KEEP = "https://schema.ostler.ai/ontology#person_bbbb00000002"


def _fp(u):
    return hashlib.sha256(u.encode()).hexdigest()[:12]


@pytest.fixture(autouse=True)
def log(tmp_path, monkeypatch):
    p = tmp_path / "logs" / "person-deletions.jsonl"
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(p))
    return p


def _records(p):
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def _has(p, uri, component):
    return [r for r in _records(p) if r["uri_fp"] == _fp(uri) and r["component"] == component]


# ---- the helper -----------------------------------------------------------
def test_helper_writes_digest_and_shape_never_the_uri(log):
    from ostler_fda import person_audit as pa
    assert pa.record_person_removal(DISCARD, "c", "r") is True
    raw = log.read_text()
    assert DISCARD not in raw and "aaaa00000001" not in raw
    rec = json.loads(raw)
    assert rec["uri_fp"] == _fp(DISCARD) and "<h>" in rec["uri_shape"]
    assert oct(os.stat(log).st_mode & 0o777) == "0o600"


def test_helper_never_raises_and_says_false(monkeypatch, tmp_path):
    from ostler_fda import person_audit as pa
    blocker = tmp_path / "afile"
    blocker.write_text("x")
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(blocker / "sub" / "l.jsonl"))
    assert pa.record_person_removal(DISCARD, "c", "r") is False
    assert pa.record_person_removal("", "c", "r") is False


def test_the_four_copies_are_byte_identical():
    paths = [VENDOR / "cm041" / d / "person_audit.py" for d in ("identity_resolver", "contact_syncer", "assistant_api")]
    paths.append(VENDOR / "ostler_fda" / "person_audit.py")
    digests = {hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    assert len(digests) == 1, "person_audit.py copies have drifted"


# ---- identity_resolver ----------------------------------------------------
def test_resolver_merge_persons_records_the_discard(log):
    from identity_resolver.resolver import IdentityResolver
    r = IdentityResolver.__new__(IdentityResolver)
    r._sparql_update = lambda q: None
    r.canonicalise_display_name = lambda uri: None
    r.merge_persons(KEEP, DISCARD)
    assert _has(log, DISCARD, "identity_resolver.merge_persons")


def test_batch_merge_records_the_discard(log, monkeypatch):
    from identity_resolver import batch_resolver as br
    monkeypatch.setattr(br, "_sparql_update", lambda *a, **k: None)
    monkeypatch.setattr(br, "_sparql_query", lambda *a, **k: [])
    br._merge_oxigraph("http://x", None, KEEP, DISCARD)
    assert _has(log, DISCARD, "identity_resolver.batch_merge")


def test_repair_merge_consistency_records_each_retired_subject(log, monkeypatch):
    from identity_resolver import repair_merge_consistency as rm
    monkeypatch.setattr(rm, "_sparql_query", lambda *a, **k: [])
    monkeypatch.setattr(rm, "_still_typed_subjects", lambda *a, **k: [DISCARD])
    monkeypatch.setattr(rm, "_retired_subjects", lambda *a, **k: [])
    monkeypatch.setattr(rm, "_resurrectable_subjects", lambda *a, **k: [])
    monkeypatch.setattr(rm, "_sparql_update", lambda *a, **k: None)
    try:
        rm.repair("http://x", "http://q", apply=True, backup_dir=str(log.parent))
    except Exception:
        pass  # the write phase is stubbed; only the pre-removal record matters
    assert _has(log, DISCARD, "identity_resolver.repair_merge_consistency")


# ---- contact_syncer -------------------------------------------------------
def test_contact_sync_blank_name_records_the_displayname_removal(log):
    from contact_syncer.syncer import ContactSyncer
    s = ContactSyncer.__new__(ContactSyncer)
    s._sparql_update = lambda q: None
    s._update_person_oxigraph(DISCARD, {"fn": ""}, "person")
    assert _has(log, DISCARD, "contact_syncer.syncer")


def test_contact_sync_with_a_name_records_nothing(log):
    """CONTROL: an ordinary rename replaces the name, it removes nobody."""
    from contact_syncer.syncer import ContactSyncer
    s = ContactSyncer.__new__(ContactSyncer)
    s._sparql_update = lambda q: None
    s._update_person_oxigraph(DISCARD, {"fn": "Jane Doe"}, "person")
    assert _records(log) == []


# ---- ostler_fda -----------------------------------------------------------
def test_dedupe_merge_records_the_duplicate(log, monkeypatch):
    from ostler_fda import dedupe_merge as dm
    monkeypatch.setattr(dm, "_sparql_update", lambda *a, **k: None)
    dm._merge_pair(KEEP, DISCARD)
    assert _has(log, DISCARD, "ostler_fda.dedupe_merge")


def test_role_address_repair_records_each_deleted_node(log, monkeypatch, tmp_path):
    from ostler_fda import repair_role_address_people as rr
    cand = {"uri": DISCARD, "email": "noreply@example.com", "names": 1, "namelist": "x"}
    monkeypatch.setattr(rr, "find_candidates", lambda: [cand])
    monkeypatch.setattr(rr, "_select", lambda q: [])
    monkeypatch.setattr(rr, "_update", lambda q: None)
    monkeypatch.setenv("OSTLER_REPAIR_BACKUP", str(tmp_path / "b.nt"))
    rr.main(["--apply"])
    assert _has(log, DISCARD, "ostler_fda.repair_role_address_people")


def test_placeholder_name_repair_records_a_deleted_kinship_name(log, monkeypatch, tmp_path):
    from ostler_fda import repair_placeholder_names as rp
    monkeypatch.setattr(rp, "_query", lambda q: [
        {"s": {"value": DISCARD}, "v": {"value": "Wife"}},
        {"s": {"value": DISCARD}, "v": {"value": "Jane Doe"}},
    ])
    monkeypatch.setattr(rp, "_construct", lambda q: "")
    monkeypatch.setattr(rp, "_update", lambda q: None)
    rp.main(["--apply", "--households-already-split",
             "--review-out", str(tmp_path / "r.tsv"), "--snapshot-out", str(tmp_path / "snap")])
    assert _has(log, DISCARD, "ostler_fda.repair_placeholder_names")


def test_people_sweep_prune_leaves_a_trace_before_the_vector_goes(log, monkeypatch):
    from ostler_fda import pwg_ingest as mod
    keep_uri = "https://schema.ostler.ai/person/kept0001"
    monkeypatch.setattr(mod, "_load_people_from_oxigraph", lambda: [{
        "uri": keep_uri, "display_name": "Alder", "contact_type": "person",
        "organization": "", "job_title": "", "given_name": "Alder",
        "family_name": "", "phones": [], "emails": [], "created_at": ""}])
    monkeypatch.setattr(mod, "_person_embed_doc", lambda p: "doc")
    monkeypatch.setattr(mod, "_ollama_embed_batch", lambda d: [[0.1, 0.2]] * len(d))
    monkeypatch.setattr(mod, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_qdrant_upsert_points", lambda c, pts: len(pts))
    monkeypatch.setattr(mod, "_current_person_uris", lambda: {keep_uri})
    monkeypatch.setattr(mod, "_qdrant_scroll_points", lambda c, limit=1000: [
        {"id": "p-gone", "payload": {"person_uri": DISCARD, "source": "fda_people_index"}}])
    deleted = []
    monkeypatch.setattr(mod, "_qdrant_delete_points", lambda c, ids: deleted.extend(ids) or len(ids))
    mod.ingest_people_to_qdrant()
    assert deleted == ["p-gone"]
    assert _has(log, DISCARD, "ostler_fda.pwg_ingest.people_sweep")


# ---- assistant_api forget -------------------------------------------------
def test_forget_records_the_person_before_the_erasure(log, monkeypatch):
    sys.path.insert(0, str(VENDOR / "cm041" / "assistant_api" / "tests"))
    import test_people_list_endpoint as t
    server = t.server
    server_dir_audit = VENDOR / "cm041" / "assistant_api" / "person_audit.py"
    assert server_dir_audit.exists()
    monkeypatch.setattr(server, "_sparql_select", lambda q: [
        {"person": DISCARD, "name": "Jane Doe"}])
    monkeypatch.setattr(server, "_sparql_update", lambda q: None)
    monkeypatch.setattr(server, "_queue_wiki_recompile", lambda s: True)
    monkeypatch.setattr(server.urllib.request, "urlopen", lambda *a, **k: None)
    body, status = server.api_people_forget("jane-doe")
    assert status == 200
    assert _has(log, DISCARD, "assistant_api.forget_person")


# ---- the probe joins an orphan to its record ------------------------------
def _removal_records():
    src = (REPO / "scripts/box_walk_probes/probes/people_stores_reconcile.sh").read_text()
    i = src.index("def removal_records(us):")
    j = src.index("# Bypass any operator proxy")
    ns = {"os": os, "json": json, "fp": _fp}
    exec(src[i:j], ns)
    return ns["removal_records"]


def test_probe_joins_orphan_to_record(log):
    from ostler_fda import person_audit as pa
    pa.record_person_removal(DISCARD, "ostler_fda.dedupe_merge", "exact_identifier_merge")
    out = _removal_records()([DISCARD])
    assert out.startswith(_fp(DISCARD) + ":ostler_fda.dedupe_merge;exact_identifier_merge;")


def test_probe_distinguishes_no_record_from_log_absent(log):
    rr = _removal_records()
    assert rr([DISCARD]) == _fp(DISCARD) + ":log-absent"
    from ostler_fda import person_audit as pa
    pa.record_person_removal(KEEP, "c", "r")
    assert rr([DISCARD]) == _fp(DISCARD) + ":no-record"
