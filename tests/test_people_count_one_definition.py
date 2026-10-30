"""One definition of a person for counting, applied by each store's own reader (v1.0.121).

people_rules.is_countable_person: CUSTOMER-VISIBLE, i.e. named and not merged
away. The walk probe people_count_agreement counts GRAPH Person nodes with it;
the Doctor (ical-server _wiki_people_count) counts QDRANT people points with it.
Neither reads the other's store, so they stay independent and must agree.

Before: the Doctor reported the raw Qdrant points_count, so a point for an
unnamed or nameless record counted there and nowhere else; the probe graded a
designed difference as a disagreement. The cap is NOT changed; the difference
is defined away in the predicate.

Real components: the shipped probe script (run locally, no box), the shipped
people_rules.py, and the shipped _wiki_people_count loaded from ical-server.py.
Stood in for: Oxigraph (pyoxigraph behind loopback HTTP), Qdrant (a REST subset
over a dict), and the Doctor's hydration route (it returns the real
_wiki_people_count, exactly what api_hydration_status puts in phases.contacts).
Synthetic data only.
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import os
import subprocess
import sys
import threading
import urllib.parse
import uuid
from pathlib import Path

import pytest

pyoxigraph = pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "vendor" / "cm041" / "assistant_api"
PROBE = ROOT / "scripts" / "box_walk_probes" / "probes" / "people_count_agreement.sh"
PWG = "https://schema.ostler.ai/ontology#"
sys.path.insert(0, str(API))

import people_rules  # noqa: E402


# The shipped package, vendored beside the tree (CI also pip-installs it).
sys.path.insert(0, str(ROOT / "vendor"))
_spec = importlib.util.spec_from_file_location("ical_server_pcount", API / "ical-server.py")
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)


def _main_doctor_count(qdrant_url):
    """The Doctor's count AS IT WAS ON MAIN: raw points_count."""
    import urllib.request
    with urllib.request.urlopen(qdrant_url + "/collections/people", timeout=3) as r:
        return int(json.loads(r.read())["result"]["points_count"])


# --------------------------------------------------------------------- stores
def _serve(handler):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


class World:
    def __init__(self):
        self.g = pyoxigraph.Store()
        self.points = {}
        self.doctor_impl = "shipped"
        outer = self

        class Oxi(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _answer(self, q):
                out = outer.g.query(q).serialize(format=pyoxigraph.QueryResultsFormat.JSON)
                self.send_response(200)
                self.send_header("Content-Type", "application/sparql-results+json")
                self.end_headers()
                self.wfile.write(out)

            def do_GET(self):
                self._answer(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)["query"][0])

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
                if "x-www-form-urlencoded" in (self.headers.get("Content-Type") or ""):
                    body = urllib.parse.parse_qs(body)["query"][0]
                self._answer(body)

        class Qdrant(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _j(self, result):
                out = json.dumps({"result": result, "status": "ok"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

            def do_GET(self):
                self._j({"status": "green", "points_count": len(outer.points)})

            def do_POST(self):
                b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                ids = sorted(outer.points)
                start = int(b.get("offset") or 0)
                page = ids[start:start + int(b.get("limit") or 10)]
                nxt = start + len(page) if start + len(page) < len(ids) else None
                self._j({"points": [{"id": i, "payload": outer.points[i]} for i in page],
                         "next_page_offset": nxt})

        class Doctor(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                n = (_main_doctor_count(outer.qdrant) if outer.doctor_impl == "main"
                     else server._wiki_people_count())
                out = json.dumps({"phases": [{"key": "contacts", "state": "done", "count": n}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

        self.srvs = []
        for name, h in (("oxi", Oxi), ("qdrant", Qdrant), ("doctor", Doctor)):
            s, url = _serve(h)
            self.srvs.append(s)
            setattr(self, name, url)

    def close(self):
        for s in self.srvs:
            s.shutdown()

    def node(self, slug, name=None, *, provisional=False, lid=None, merged_into=None):
        uri = f"{PWG}person_{slug}"
        t = [f"<{uri}> a <{PWG}Person>"]
        if name:
            t.append(f'<{uri}> <{PWG}displayName> "{name}"')
        if provisional:
            t.append(f'<{uri}> <{PWG}displayNameProvisional> "true"^^<http://www.w3.org/2001/XMLSchema#boolean>')
        if lid:
            t += [f"<{uri}> <{PWG}hasIdentifier> <{uri}_id>",
                  f'<{uri}_id> <{PWG}identifierType> "whatsapp_lid"',
                  f'<{uri}_id> <{PWG}identifierValue> "{lid}"']
        if merged_into:
            t.append(f"<{uri}> <{PWG}mergedInto> <{PWG}person_{merged_into}>")
        self.g.update("INSERT DATA { " + " . ".join(t) + " . }")
        return uri

    def point(self, slug, name, **extra):
        uri = f"{PWG}person_{slug}"
        self.points[str(uuid.uuid5(uuid.NAMESPACE_URL, uri))] = dict(
            {"person_uri": uri, "display_name": name}, **extra)


NAMED = [("a", "Jane Doe"), ("b", "John Smith"), ("c", "Mary Jones")]


def seed_graph(w):
    for slug, name in NAMED:
        w.node(slug, name)
    # Two nameless WhatsApp provisionals: the name was refused at creation,
    # only the provisional flag and a LID remain (the v1.0.120 box has 13).
    w.node("p1", provisional=True, lid="lid-0001")
    w.node("p2", provisional=True, lid="lid-0002")
    # One merged-away node an old ingest re-typed Person.
    w.node("m1", "Jane Doe", merged_into="a")


def seed_qdrant_named(w):
    for slug, name in NAMED:
        w.point(slug, name)


def seed_qdrant_hidden(w):
    """Points the definition hides: no name, a WhatsApp JID, a short code."""
    w.point("h1", "")
    w.point("h2", "4477009" + "00123" + "@" + "s.whatsapp.net")
    w.point("h3", "87" + "099")


@pytest.fixture()
def world():
    w = World()
    server.QDRANT_URL = w.qdrant
    yield w
    w.close()


def run_probe(w, tmp_path, cap):
    home = tmp_path / "acct"
    (home / ".ostler" / "secrets").mkdir(parents=True, exist_ok=True)
    (home / ".ostler" / "secrets" / "store-curl.conf").write_text('header = "Authorization: Bearer t"\n')
    env = dict(os.environ, HOME=str(home), OSTLER_BOX_HOST="",
               OSTLER_OXIGRAPH_URL=w.oxi + "/query", OSTLER_QDRANT_URL=w.qdrant,
               OSTLER_DOCTOR_PEOPLE_URL=w.doctor + "/api/v1/hydration/status",
               OSTLER_PEOPLE_RULES_DIR=str(API), NO_PROXY="127.0.0.1,localhost",
               OSTLER_PEOPLE_STABILITY_STEP_S="1", OSTLER_PEOPLE_STABILITY_WAIT_S="10",
               OSTLER_PEOPLE_CONVERGE_WAIT_S="0", OSTLER_PROBE_STATE_DIR=str(tmp_path / "pstate"),
               # The fixture's cap governs: 100% of the larger count never
               # binds below it. The shipped cap (5) is not touched.
               OSTLER_PEOPLE_TOLERANCE_PCT="100", OSTLER_PEOPLE_TOLERANCE_CAP=str(cap))
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        env.pop(k, None)
    r = subprocess.run(["bash", str(PROBE)], env=env, capture_output=True, text=True, timeout=300)
    text = r.stdout + r.stderr
    v = next((ln.split("VERDICT:")[1].strip() for ln in text.splitlines() if "VERDICT:" in ln), "NONE")
    return v, text


# ------------------------------------------------------------------ the tests
def test_the_definition_is_named_and_not_merged_away():
    f = people_rules.is_countable_person
    assert f("Jane Doe")
    assert not f("Jane Doe", merged=True)
    assert not f("") and not f(None)
    assert not f("4477009" + "00123" + "@" + "s.whatsapp.net")
    assert f("+44" + "7700900123")              # a phone-only person is shown


def test_graph_count_is_3_with_2_nameless_and_1_merged_away(world, tmp_path):
    seed_graph(world)
    seed_qdrant_named(world)
    v, text = run_probe(world, tmp_path, cap=2)
    assert "oxigraph 3 of 5 unmerged nodes (1 merged-away Person nodes excluded)" in text, text
    assert "stubs=2" in text, text


def test_doctor_counts_qdrant_with_the_same_definition(world):
    seed_qdrant_named(world)
    seed_qdrant_hidden(world)
    assert _main_doctor_count(world.qdrant) == 6        # main: raw points_count
    assert server._wiki_people_count() == 3              # shipped: the definition


def test_doctor_count_pages_through_the_whole_collection(world):
    for i in range(2500):
        world.point(f"bulk{i}", f"Tom Brown{i}")
    world.point("h1", "")
    assert server._wiki_people_count() == 2500


def test_doctor_count_is_none_not_zero_when_qdrant_is_unreachable(world):
    server.QDRANT_URL = "http://127.0.0.1:9"
    assert server._wiki_people_count() is None


def test_agreement_passes_when_both_stores_hold_the_same_3(world, tmp_path):
    seed_graph(world)
    seed_qdrant_named(world)
    seed_qdrant_hidden(world)
    v, text = run_probe(world, tmp_path, cap=2)
    assert v.startswith("PASS"), text
    assert "oxigraph=3 doctor=3" in text, text


def test_red_with_the_main_doctor_count(world, tmp_path):
    """The pairing at main: the Doctor's raw points_count (6) against the
    defined graph count (3) disagrees by 3, above a cap of 2."""
    seed_graph(world)
    seed_qdrant_named(world)
    seed_qdrant_hidden(world)
    world.doctor_impl = "main"
    v, text = run_probe(world, tmp_path, cap=2)
    assert v.startswith("FAIL"), text
    assert "oxigraph=3 doctor=6 differ by 3" in text, text
    assert "cap 2) = 2" in text, text


def test_a_real_extra_named_person_in_one_store_still_fails(world, tmp_path):
    seed_graph(world)
    seed_qdrant_named(world)
    world.point("x1", "Sam Patel")                   # only in Qdrant
    v, text = run_probe(world, tmp_path, cap=0)
    assert v.startswith("FAIL"), text
    assert "oxigraph=3 doctor=4 differ by 1" in text, text
    # and in the graph only, against the fixture cap of 2
    for slug in ("y1", "y2", "y3"):
        world.node(slug, "Ben Ross " + slug)
    world.points.pop(next(k for k, p in world.points.items() if p["person_uri"].endswith("_x1")))
    v, text = run_probe(world, tmp_path, cap=2)
    assert v.startswith("FAIL"), text
    assert "oxigraph=6 doctor=3 differ by 3" in text, text
