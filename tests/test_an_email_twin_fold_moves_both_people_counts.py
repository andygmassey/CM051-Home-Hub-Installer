"""Folding an email twin moves the graph people count and the Doctor's count together.

people_rules.is_countable_person (#3245) is the ONE definition of a person for
counting: named and not merged away. The walk probe people_count_agreement
counts GRAPH Person nodes with it (a merged-away node is excluded); the Doctor
(ical-server _wiki_people_count) counts QDRANT people points with it (a point
carries no merge state, so it relies on a merge DELETING the loser's point).

The email-twin fold (dedupe_merge.merge_email_twins) leaves a mergedInto
tombstone and deletes the twin's people point, so a fold must take ONE off
both counts. Asserted through the shipped probe and the shipped Doctor count,
before and after a real fold.

Stood in for: Oxigraph (pyoxigraph behind loopback HTTP), Qdrant
(qdrant-client's in-memory engine, served over a small REST shim for the two
HTTP readers), and the Doctor route (returns the real _wiki_people_count).
Synthetic data only (approved cast, example.com).
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import os
import subprocess
import sys
import threading
import types
import uuid
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")
qdrant_client = pytest.importorskip("qdrant_client")
from qdrant_client import models  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "vendor" / "cm041" / "assistant_api"
PROBE = ROOT / "scripts" / "box_walk_probes" / "probes" / "people_count_agreement.sh"
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(API))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

_spec = importlib.util.spec_from_file_location("ical_server_twin_counts", API / "ical-server.py")
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)

PWG = "https://schema.ostler.ai/ontology#"
JANE = PWG + "person_card_jane"
TOM = PWG + "person_card_tom"
JANE_MAIL = "jane.stewart@example.com"
TOM_MAIL = "tom.jones@example.com"


def _load_cm021():
    saved = {k: sys.modules.get(k) for k in
             ("src", "src.filters", "src.parsers", "src.parsers.fast_mbox_parser")}
    src = types.ModuleType("src"); src.__path__ = []
    flt = types.ModuleType("src.filters"); flt.EmailFilter = object
    par = types.ModuleType("src.parsers"); par.__path__ = []
    fmp = types.ModuleType("src.parsers.fast_mbox_parser")
    fmp.FastEmail = object; fmp.FastMboxParser = object
    sys.modules.update({"src": src, "src.filters": flt, "src.parsers": par,
                        "src.parsers.fast_mbox_parser": fmp})
    try:
        spec = importlib.util.spec_from_file_location(
            "cm021_cli_twin_counts", ROOT / "vendor" / "cm021" / "src" / "cli.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


CLI = _load_cm021()


def _serve(handler):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    mem = qdrant_client.QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(
        size=4, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)

    class Qdrant(http.server.BaseHTTPRequestHandler):
        """The REST subset the probe and the Doctor read, over the same engine
        the fold deletes from."""
        def log_message(self, *a):
            pass

        def _j(self, result):
            out = json.dumps({"result": result, "status": "ok"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            self._j({"status": "green", "points_count": mem.count("people").count})

        def do_POST(self):
            b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            if self.path.endswith("/count"):
                return self._j({"count": mem.count("people").count})
            pts, nxt = mem.scroll("people", limit=int(b.get("limit") or 10),
                                  offset=b.get("offset"), with_payload=True)
            self._j({"points": [{"id": str(p.id), "payload": p.payload} for p in pts],
                     "next_page_offset": str(nxt) if nxt is not None else None})

    class Doctor(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            out = json.dumps({"phases": [{"key": "contacts", "state": "done",
                                          "count": server._wiki_people_count()}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

    qsrv, qurl = _serve(Qdrant)
    dsrv, durl = _serve(Doctor)
    monkeypatch.setattr(server, "QDRANT_URL", qurl)
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", str(tmp_path / "journal"))
    monkeypatch.setenv("QDRANT_URL", "http://qdrant.invalid:6333")   # the fold's client is `mem`
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "del.jsonl"))
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "tomb.json"))
    monkeypatch.setenv("DEFAULT_COUNTRY_CODE", "44")
    from ostler_fda import dedupe_merge
    monkeypatch.setattr(dedupe_merge, "OXIGRAPH_URL", store.url)
    yield types.SimpleNamespace(store=store, mem=mem, qurl=qurl, durl=durl, dm=dedupe_merge,
                                tmp=tmp_path)
    qsrv.shutdown()
    dsrv.shutdown()
    store.close()


def _point(w, uri, name, mail, uid=""):
    w.mem.upsert("people", points=[models.PointStruct(
        id=str(uuid.uuid5(uuid.NAMESPACE_URL, uri)), vector=[1.0, 0.0, 0.0, 0.0],
        payload={"person_uri": uri, "display_name": name, "emails": [mail],
                 "icloud_uid": uid})])


def _card(w, uri, name, uid, mail):
    w.store.update(
        f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" ; '
        f'pwg:hasIdentifier <{uri}_u>, <{uri}_e> . '
        f'<{uri}_u> a pwg:PersonIdentifier ; pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "{uid}" . '
        f'<{uri}_e> a pwg:PersonIdentifier ; pwg:identifierType "email" ; pwg:identifierValue "{mail}" . }}')
    _point(w, uri, name, mail, uid)


def _email_ingest(w, address, from_name):
    iri = CLI._live_person_iri(w.store.url, CLI._safe_person_iri(address))
    w.store.ds.update(CLI._build_upsert(iri, address, from_name, "2026-10-30T09:30:00Z"))
    _point(w, iri, from_name or address, address)
    return iri


def _probe(w):
    home = w.tmp / "acct"
    (home / ".ostler" / "secrets").mkdir(parents=True, exist_ok=True)
    (home / ".ostler" / "secrets" / "store-curl.conf").write_text('header = "Authorization: Bearer t"\n')
    env = dict(os.environ, HOME=str(home), OSTLER_BOX_HOST="",
               OSTLER_OXIGRAPH_URL=w.store.url + "/query", OSTLER_QDRANT_URL=w.qurl,
               OSTLER_DOCTOR_PEOPLE_URL=w.durl + "/api/v1/hydration/status",
               OSTLER_PEOPLE_RULES_DIR=str(API), NO_PROXY="127.0.0.1,localhost",
               OSTLER_PEOPLE_STABILITY_STEP_S="1", OSTLER_PEOPLE_STABILITY_WAIT_S="10",
               OSTLER_PEOPLE_CONVERGE_WAIT_S="0", OSTLER_PROBE_STATE_DIR=str(w.tmp / "pstate"),
               OSTLER_PEOPLE_TOLERANCE_PCT="100", OSTLER_PEOPLE_TOLERANCE_CAP="0")
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        env.pop(k, None)
    r = subprocess.run(["bash", str(PROBE)], env=env, capture_output=True, text=True, timeout=300)
    return r.stdout + r.stderr


def test_one_fold_takes_one_off_both_counts(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _card(world, TOM, "Tom Jones", "SYNTHETIC-CARD-UID-0002", TOM_MAIL)
    twin = _email_ingest(world, JANE_MAIL, "Jane Stewart")   # a counted, named twin

    before = _probe(world)
    assert "oxigraph=3 doctor=3" in before, before
    assert server._wiki_people_count() == 3

    stats = world.dm.run()
    assert stats.get("email_twins_merged") == 1, stats
    assert world.store.ask(f"ASK {{ <{twin}> pwg:mergedInto <{JANE}> }}")

    after = _probe(world)
    assert "oxigraph=2 doctor=2" in after, after
    assert server._wiki_people_count() == 2


def test_control_a_fold_that_kept_the_vector_would_split_the_counts(world, monkeypatch):
    """Negative control: with the vector delete broken, the graph drops the twin
    and the Doctor does not, and the probe sees the disagreement."""
    from identity_resolver import merge_journal

    def _boom(*a, **k):
        raise RuntimeError("qdrant went away")
    monkeypatch.setattr(merge_journal, "delete_person_points", _boom)
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_ingest(world, JANE_MAIL, "Jane Stewart")
    world.dm.run()
    after = _probe(world)
    assert "oxigraph=1 doctor=2" in after, after
