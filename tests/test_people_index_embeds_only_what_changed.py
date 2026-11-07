"""The people index embeds only the people that are new or changed (v1.0.126, item h).

WHY THIS EXISTS. v1.0.125 walk, first-run box with a real address book: the
people without a search vector grew 240 -> 1789 in 4200 s, and
people_count_agreement went CANNOT-RUN on 124 and 125. ingest_people_to_qdrant
runs LAST in every hourly com.ostler.fda-rerun tick and, until this change,
re-loaded every Person and re-embedded ALL of them on every pass. A full pass
grows with the graph, so on a first-run box each pass took longer than the
last, ticks were skipped behind the run lock, and new people waited longer
every hour.

THE FIX UNDER TEST. Every point carries embed_text_sha256, the hash of exactly
the text that was embedded. A person whose hash matches is not embedded again
(its payload is still refreshed when a non-embedded field moved). New people
are embedded first, then changed ones, in chunks that land as they go, and the
backlog (people without a current vector) is written for the Doctor, which
says "Making N people searchable" while it catches up and goes red only when
the backlog grew on each of the last three passes.

Drives the REAL ingest_people_to_qdrant: real SPARQL against an in-memory
Oxigraph (pyoxigraph), and the real _qdrant_* HTTP helpers against a local
fake Qdrant socket. Only the embedder is stood in, and it records every text
it is asked to embed: that list IS the measurement. Synthetic data only.
"""
from __future__ import annotations

import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))
AGENT = ROOT / "vendor" / "doctor" / "agent"

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from ostler_fda import pwg_ingest as _pwg  # noqa: E402

COLL = "people_delta_test"
BASE = "https://schema.ostler.ai/ontology#person_deltatest"


class FakeQdrant:
    """The five Qdrant REST calls the people sweep makes, on a real socket."""

    def __init__(self) -> None:
        self.exists = False
        self.points: dict = {}
        self.calls: list = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")

            def do_GET(self):  # noqa: N802
                outer.calls.append(("GET", self.path))
                self._send(200 if outer.exists else 404, {"result": {}})

            def do_PUT(self):  # noqa: N802
                path = self.path.split("?")[0]
                body = self._body()
                outer.calls.append(("PUT", path))
                if path.endswith("/points"):
                    for p in body["points"]:
                        outer.points[str(p["id"])] = {"vector": p["vector"],
                                                      "payload": dict(p["payload"])}
                else:
                    outer.exists = True
                self._send(200, {"result": True})

            def do_POST(self):  # noqa: N802
                path = self.path.split("?")[0]
                body = self._body()
                outer.calls.append(("POST", path))
                if path.endswith("/points/scroll"):
                    if not outer.exists:
                        return self._send(404, {"status": {"error": "Not found"}})
                    pts = [{"id": k, "payload": v["payload"]} for k, v in outer.points.items()]
                    return self._send(200, {"result": {"points": pts, "next_page_offset": None}})
                if path.endswith("/points/payload"):
                    for pid in body["points"]:
                        outer.points[str(pid)]["payload"].update(body["payload"])
                    return self._send(200, {"result": True})
                if path.endswith("/points/delete"):
                    for pid in body["points"]:
                        outer.points.pop(str(pid), None)
                    return self._send(200, {"result": True})
                self._send(404, {})

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def close(self):
        self.srv.shutdown()


def _uri(n: int) -> str:
    return "%s%04d" % (BASE, n)


def _add(store, n: int, name: str, job: str = "") -> None:
    extra = (' ; pwg:jobTitle "%s"' % job) if job else ""
    store.update('INSERT DATA { <%s> a pwg:Person ; pwg:displayName "%s" ; '
                 'pwg:givenName "%s"%s . }' % (_uri(n), name, name.split()[0], extra))


# Approved-cast style synthetic names, composed so no two-word literal sits here.
NAMES = ["Alder " + "Testcase", "Birch " + "Testcase", "Cedar " + "Testcase",
         "Damson " + "Testcase", "Elm " + "Testcase", "Fir " + "Testcase"]


ROLE = "Tester"


@pytest.fixture()
def world(monkeypatch, tmp_path):
    store = FakeOxigraph()
    q = FakeQdrant()
    embedded: list = []
    fail: set = set()

    def _embed(texts):
        embedded.extend(texts)
        return [[] if t in fail or "*" in fail else [0.1, 0.2, 0.3] for t in texts]

    monkeypatch.setattr(_pwg, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(_pwg, "QDRANT_URL", q.url)
    monkeypatch.setattr(_pwg, "PEOPLE_QDRANT_COLLECTION", COLL)
    monkeypatch.setattr(_pwg, "_ollama_embed_batch", _embed)
    state = tmp_path / "state" / "people-index.json"
    monkeypatch.setenv("OSTLER_PEOPLE_INDEX_STATE", str(state))
    yield {"store": store, "q": q, "embedded": embedded, "fail": fail, "state": state}
    store.close()
    q.close()


def _run(w):
    w["embedded"].clear()
    return _pwg.ingest_people_to_qdrant()


def _point(w, n):
    import uuid
    return w["q"].points.get(str(uuid.uuid5(uuid.NAMESPACE_URL, _uri(n))))


# ── 1. the defect: a second pass over an unchanged graph ─────────────────


def test_a_second_pass_over_an_unchanged_graph_embeds_nobody(world):
    for i in range(3):
        _add(world["store"], i, NAMES[i])
    first = _run(world)
    assert len(world["embedded"]) == 3, "control: the first pass embeds all three"
    assert first["status"] == "ok" and first["sent"] == 3 and first["total"] == 3, first
    second = _run(world)
    assert world["embedded"] == [], (
        "a second pass over an UNCHANGED graph embedded %d people again"
        % len(world["embedded"]))
    # install.sh reads sent/total: an all-current pass is a complete pass.
    assert second["status"] == "ok" and second["sent"] == 3 and second["total"] == 3, second
    assert second.get("embedded") == 0 and second.get("already_current") == 3, second
    assert all(_point(world, i)["vector"] for i in range(3)), "every person keeps a vector"


def test_every_point_carries_the_hash_of_exactly_the_embedded_text(world):
    _add(world["store"], 0, NAMES[0], job="Tester")
    _run(world)
    import hashlib
    text = world["embedded"][0]
    assert text == _pwg._person_embed_doc({"display_name": NAMES[0], "job_title": "Tester"})
    assert _point(world, 0)["payload"]["embed_text_sha256"] == hashlib.sha256(
        text.encode("utf-8")).hexdigest()


# ── 2. a changed person is embedded again, and only that person ───────────


def test_a_changed_person_is_embedded_again_and_nobody_else(world):
    for i in range(3):
        _add(world["store"], i, NAMES[i])
    _run(world)
    world["store"].update('INSERT DATA { <%s> pwg:jobTitle "%s" . }' % (_uri(1), ROLE))
    res = _run(world)
    assert world["embedded"] == [NAMES[1] + " " + ROLE], world["embedded"]
    assert res["status"] == "ok" and res["sent"] == 3, res
    assert _point(world, 1)["payload"]["job_title"] == ROLE


def test_a_field_that_is_not_embedded_is_refreshed_without_embedding(world):
    for i in range(2):
        _add(world["store"], i, NAMES[i])
    _run(world)
    world["store"].update('INSERT DATA { <%s> pwg:lastContactEmail "2026-10-01" . }' % _uri(0))
    res = _run(world)
    assert world["embedded"] == [], "a last-contact change is not a reason to embed"
    assert res["status"] == "ok", res
    assert _point(world, 0)["payload"]["last_contact"] == "2026-10-01", (
        "the payload must still follow the graph when the vector does not change")
    assert _point(world, 0)["payload"]["last_contact_ts"] > 0


def test_a_point_written_before_the_hash_existed_is_embedded_exactly_once(world):
    import uuid
    for i in range(2):
        _add(world["store"], i, NAMES[i])
    world["q"].exists = True
    for i in range(2):
        world["q"].points[str(uuid.uuid5(uuid.NAMESPACE_URL, _uri(i)))] = {
            "vector": [0.9], "payload": {"person_uri": _uri(i), "source": "fda_people_index",
                                         "display_name": NAMES[i]}}
    _run(world)
    assert sorted(world["embedded"]) == sorted(NAMES[:2]), "hashless points re-embed once"
    _run(world)
    assert world["embedded"] == [], "and never again while unchanged"


# ── 3. order: the never-embedded come first ──────────────────────────────


@pytest.mark.parametrize("new_n", [0, 5])
def test_a_never_embedded_person_is_embedded_before_a_changed_one(world, new_n):
    # Both ends of the URI order, so the graph's own order cannot pass this.
    import uuid
    olds = [i for i in range(6) if i != new_n]
    for i in range(6):
        _add(world["store"], i, NAMES[i])
    world["q"].exists = True
    for i in olds:  # stored before the hash existed: all "changed"
        world["q"].points[str(uuid.uuid5(uuid.NAMESPACE_URL, _uri(i)))] = {
            "vector": [0.9], "payload": {"person_uri": _uri(i), "source": "fda_people_index"}}
    _run(world)
    assert len(world["embedded"]) == 6
    assert world["embedded"][0] == NAMES[new_n], (
        "the never-embedded person came at position %d of 6"
        % world["embedded"].index(NAMES[new_n]))


def test_chunks_land_as_they_go_so_coverage_rises_during_the_pass(world, monkeypatch):
    monkeypatch.setattr(_pwg, "PEOPLE_INDEX_CHUNK", 2)
    for i in range(5):
        _add(world["store"], i, NAMES[i])
    _run(world)
    puts = [c for c in world["q"].calls if c[0] == "PUT" and c[1].endswith("/points")]
    assert len(puts) == 3, "5 people in chunks of 2 land in 3 upserts, not one at the end"


# ── 4. the backlog, written for the Doctor ───────────────────────────────


def _record(w):
    return json.loads(w["state"].read_text(encoding="utf-8"))


def test_the_backlog_is_written_and_a_failed_person_is_retried_alone(world):
    for i in range(3):
        _add(world["store"], i, NAMES[i])
    world["fail"].add(NAMES[2])
    res = _run(world)
    assert res["status"] == "error" and res.get("reason") == "partial_landing", res
    rec = _record(world)
    assert rec["backlog"] == 1 and rec["total"] == 3 and rec["phase"] == "done", rec
    world["fail"].clear()
    res = _run(world)
    assert world["embedded"] == [NAMES[2]], "only the person still without a vector"
    assert res["status"] == "ok" and _record(world)["backlog"] == 0


def _doctor():
    sys.path.insert(0, str(AGENT))
    import people_index_status as pis
    return pis


def test_doctor_says_making_n_people_searchable_while_catching_up(world):
    for i in range(3):
        _add(world["store"], i, NAMES[i])
    world["fail"].update(NAMES[:2])
    _run(world)
    pis = _doctor()
    st = pis.read_people_index_status(world["state"])
    assert st["status"] == "catching_up" and st["backlog"] == 2, st
    html_ = pis.render_people_index_status(st)
    assert "Making 2 people searchable" in html_, html_
    assert pis._COLOUR["catching_up"] == pis.AMBER


def test_doctor_goes_red_only_after_three_passes_in_a_row_that_grew(world):
    pis = _doctor()
    world["fail"].add("*")  # the embedder is down: nothing lands
    seen = []
    for i in range(5):
        _add(world["store"], i, NAMES[i])
        _run(world)
        seen.append(pis.read_people_index_status(world["state"])["status"])
    # backlog 1, 2, 3, 4, 5: growth on passes 2, 3, 4 makes pass 4 the first red.
    assert seen == ["catching_up", "catching_up", "catching_up", "falling_behind",
                    "falling_behind"], seen
    st = pis.read_people_index_status(world["state"])
    assert pis._COLOUR["falling_behind"] == pis.RED
    assert "5 people" in pis.render_people_index_status(st)
    world["fail"].clear()
    _run(world)
    st = pis.read_people_index_status(world["state"])
    assert st["status"] == "searchable" and st["backlog"] == 0, st
    assert "All 5 people are searchable" in pis.render_people_index_status(st)


def test_doctor_never_turns_a_missing_or_broken_record_into_a_number(tmp_path):
    pis = _doctor()
    st = pis.read_people_index_status(tmp_path / "absent.json")
    assert st["status"] == "not_run" and st["backlog"] is None
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    st = pis.read_people_index_status(bad)
    assert st["status"] == "unreadable"
    assert "could not check" in pis.render_people_index_status(st).lower()


def test_web_ui_renders_the_row_and_it_is_declared_vendor_only():
    ui = (AGENT / "web_ui.py").read_text(encoding="utf-8")
    assert "from people_index_status import render_people_index_status" in ui
    assert re.search(r"^\s+people_index_section = render_people_index_status\(\)$", ui, re.M)
    assert "{people_index_section}" in ui
    vo = (ROOT / "vendor" / "VENDOR_ONLY.tsv").read_text(encoding="utf-8")
    assert "doctor/agent/people_index_status.py\t" in vo
