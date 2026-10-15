"""The CM059 preference projection never writes a second copy of a preference
the CM019 pipeline already wrote, and existing duplicates are cleaned up.

THE DEFECT (walk #29, v1.0.107): CM019's ingest pipeline writes every
preference as ``pwg:pref_<id>`` (parsers/base.py to_turtle, pipeline.py
insert_triples). vendor/cm059_editor/compiler/project_preferences.py, run by
bin/editor-frontpage-tick.sh Step 0 every tick, then copied every Qdrant
point AGAIN as ``urn:ostler:preference:<sha256(id)[:32]>``. The graph held
138,999 music preference subjects for 70,667 Qdrant music points; the wiki
Topics count and interest_profile's raw_rows both read about double.

Both stores are real engines behind real sockets: pyoxigraph (the Hub's graph
engine) via tests/_fake_oxigraph.py, and a minimal Qdrant scroll endpoint.
Pipeline nodes are written by CM019's OWN ParsedPreference.to_turtle, so the
twin IRI the projector computes is checked against the writer that produces
it, not a hand-copied string. Synthetic preferences only.
"""
from __future__ import annotations

import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

pyoxigraph = pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from services.ingest.src.parsers.base import ParsedPreference  # noqa: E402
from compiler import interest_profile as ip  # noqa: E402
from compiler import project_preferences as pp  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
USER = "synthetic-user"


class _FakeQdrant:
    def __init__(self, points):
        outer = self
        self.points = points

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):  # noqa: N802
                n = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(n)
                body = json.dumps({"result": {"points": outer.points,
                                              "next_page_offset": None}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def _pref(subject, ptype="Like", category="music", source="spotify"):
    return ParsedPreference(subject=subject, preference_type=ptype, strength=0.6,
                            source=source, category=category)


# A and B went through the CM019 pipeline (both stores). C is Qdrant-only, the
# shape CM041 places_ingest / ostler_fda write.
A = _pref("Synthetic Track A")
B = _pref("Synthetic Dish B", ptype="Dislike", category="food", source="uber")
C = _pref("Synthetic Room C", ptype="Neutral", category="place", source="meeting_locations")


def _qdrant_points():
    return [{"id": p.id, "payload": p.to_payload(USER)} for p in (A, B, C)]


def _twin(preference_id):
    """The projection IRI of a pipeline preference, computed HERE (sha256 of
    the id, 32 hex chars), not borrowed from the module under test."""
    return "urn:ostler:preference:" + hashlib.sha256(preference_id.encode("utf-8")).hexdigest()[:32]


def _write_pipeline(fake, prefs):
    ttl = "\n".join(p.to_turtle(USER) for p in prefs)
    fake.ds.load(("@prefix pwg: <%s> .\n@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n%s"
                  % (PWG, ttl)).encode("utf-8"), pyoxigraph.RdfFormat.TURTLE)


def _marked(fake):
    rows = fake.ds.query(
        f'SELECT ?s WHERE {{ ?s <{PWG}projectedBy> "{pp.PROJECTOR_ID}" }}')
    return sorted(r["s"].value for r in rows)


def _reader_rows(fake):
    """interest_profile's OWN query, per node type: what the front page reads."""
    n = 0
    for t in ("LikePreference", "DislikePreference", "NeutralPreference"):
        n += len(list(fake.ds.query(ip._pref_query(t))))
    return n


@pytest.fixture
def stores(tmp_path, monkeypatch):
    # urllib honours *_proxy; a developer-box proxy would answer for the
    # loopback fakes (measured: Privoxy 503). Loopback never goes via a proxy.
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    monkeypatch.setenv("no_proxy", "127.0.0.1,localhost")
    monkeypatch.setenv("OSTLER_SECRETS_DIR", str(tmp_path / "no-secrets"))
    monkeypatch.delenv("QDRANT_API_KEY", raising=False)
    monkeypatch.delenv("OXIGRAPH_TOKEN", raising=False)
    monkeypatch.setenv("OSTLER_PREFERENCE_PROJECTION_BACKUP_DIR", str(tmp_path / "backup"))
    oxi = FakeOxigraph()
    q = _FakeQdrant(_qdrant_points())
    yield oxi, q, tmp_path
    oxi.close()
    q.close()


def test_projection_iri_is_the_twin_of_the_pipeline_iri():
    pt = {"id": A.id, "payload": A.to_payload(USER)}
    assert pp._iri(pt) == _twin(A.id)
    assert pp._iri_for_id(A.id) == _twin(A.id)


def test_projection_writes_only_rows_the_pipeline_did_not(stores):
    oxi, q, _ = stores
    _write_pipeline(oxi, [A, B])
    r = pp.project(qdrant_url=q.url, oxigraph_url=oxi.url)
    assert _marked(oxi) == [_twin(C.id)], (
        "projected a preference the pipeline already wrote")
    assert r["in_pipeline"] == 2
    # Consumer side: the profile reader sees each preference ONCE.
    assert _reader_rows(oxi) == 3


def test_cleanup_removes_only_twins_and_backs_them_up_first(stores):
    oxi, q, tmp = stores
    _write_pipeline(oxi, [A, B])
    # An install that ran the OLD projector: every point copied.
    lines, _ = pp.to_triples(_qdrant_points())
    oxi.ds.update("INSERT DATA {\n" + "\n".join(lines) + "\n}")
    # The CM019 enrich service's own node shares the urn prefix but is keyed by
    # the raw id and carries no projection marker. It must survive.
    oxi.ds.update(f'INSERT DATA {{ <urn:ostler:preference:{A.id}> '
                  f'<https://schema.ostler.ai/enrichment/ontology#enrichedAt> "2026-10-01" }}')
    assert _reader_rows(oxi) == 5          # control: the duplicates are really there
    before = _marked(oxi)
    assert len(before) == 3

    d = pp.dedupe_projected_twins(oxigraph_url=oxi.url)

    assert d["removed"] == 2
    assert _marked(oxi) == [_twin(C.id)], "a node without a twin was deleted"
    assert oxi.ask(f"ASK {{ <urn:ostler:preference:{A.id}> ?p ?o }}"), "enrichment node deleted"
    assert oxi.ask(f"ASK {{ <{PWG}pref_{A.id}> ?p ?o }}"), "pipeline node deleted"
    assert _reader_rows(oxi) == 3
    backup = Path(d["backup"]).read_text(encoding="utf-8")
    subjects = {l.split(" ", 1)[0].strip("<>") for l in backup.splitlines() if l.strip()}
    assert subjects == {_twin(A.id), _twin(B.id)}
    # The backup restores what was removed.
    oxi.ds.update("INSERT DATA {\n" + backup + "\n}")
    assert len(_marked(oxi)) == 3

    # Idempotent once clean: nothing to do, no new backup.
    pp.dedupe_projected_twins(oxigraph_url=oxi.url)  # removes the restored twins
    again = pp.dedupe_projected_twins(oxigraph_url=oxi.url)
    assert again["removed"] == 0 and again["backup"] is None


def test_cleanup_deletes_nothing_when_the_backup_is_incomplete(stores, monkeypatch):
    oxi, q, _ = stores
    _write_pipeline(oxi, [A, B])
    lines, _ = pp.to_triples(_qdrant_points())
    oxi.ds.update("INSERT DATA {\n" + "\n".join(lines) + "\n}")
    real_post = pp._post

    def lossy_post(url, body, headers, timeout=60.0):
        out = real_post(url, body, headers, timeout)
        if b"CONSTRUCT" in body:
            return b""          # a backup that silently came back empty
        return out

    monkeypatch.setattr(pp, "_post", lossy_post)
    with pytest.raises(RuntimeError, match="refusing to delete"):
        pp.dedupe_projected_twins(oxigraph_url=oxi.url)
    assert len(_marked(oxi)) == 3, "deleted without a backup"


def test_tick_order_cleanup_then_projection(stores):
    """The tick runs ``python -m compiler.project_preferences``: the cleanup
    must run before project(), whose ratio guard would otherwise refuse."""
    oxi, q, _ = stores
    _write_pipeline(oxi, [A, B])
    lines, _ = pp.to_triples(_qdrant_points())
    oxi.ds.update("INSERT DATA {\n" + "\n".join(lines) + "\n}")
    src = Path(pp.__file__).read_text(encoding="utf-8")
    main = src[src.index('if __name__ == "__main__":'):]
    assert main.index("d = dedupe_projected_twins()") < main.index("r = project()")
    pp.dedupe_projected_twins(oxigraph_url=oxi.url)
    pp.project(qdrant_url=q.url, oxigraph_url=oxi.url)
    assert _marked(oxi) == [_twin(C.id)]
    assert _reader_rows(oxi) == 3
