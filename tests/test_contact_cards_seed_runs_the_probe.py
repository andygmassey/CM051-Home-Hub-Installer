"""no_person_holds_two_contact_cards must RUN, not pass vacuously, on a cold walk box (CM051 #2545 gate).

v1.0.115 (walk34) graded the BLOCKING probe CANNOT-RUN on a cold account (no Contacts).
#3072 r1 wrote six cards straight into the graph: no syncer, no resolver, no vector,
every number unique. The probe then hit its own "GUARD IS UNEXERCISED" pass, and the
six Persons had no Qdrant point (people_stores_reconcile red, people_count_agreement
over its cap). This is the redesign: the walk seeds through the SHIPPED paths.

WHAT RUNS FOR REAL (nothing below is a mock of the code under test):
  * the box-side seed script itself (lib/contact_cards_seed.sh), under bash, in a fake
    $HOME whose two venv pythons are wrappers onto this repo's vendored trees;
  * the vendored contact_syncer (`--vcf`, the installed command line), ostler_fda
    pwg_ingest.ingest_imessage and dedupe_merge.run;
  * the shipping probes (no_person_holds_two_contact_cards, people_stores_reconcile,
    people_count_agreement) against the result.
WHAT IS STOOD IN FOR: the three servers. Oxigraph is an rdflib graph over loopback HTTP,
the embedder is a deterministic /api/embed, Qdrant is a REST subset (collections, upsert,
retrieve, scroll, delete, count) over a dict. The Doctor's hydration status is derived
the way ical-server derives it (contacts count = Qdrant people points).

Every name, number and address is synthetic (registry cast tokens, example.com, the
Ofcom drama range).
"""
from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import site
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib", reason="rdflib backs the in-memory graph")
for _m in ("httpx", "vobject", "qdrant_client", "rapidfuzz", "phonenumbers"):
    pytest.importorskip(_m)

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts" / "box_walk_probes" / "lib"
PROBES = ROOT / "scripts" / "box_walk_probes" / "probes"
SEED_SH = LIB / "contact_cards_seed.sh"
sys.path.insert(0, str(LIB))
import contact_cards_fixture as fx  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
CUSTOMER = PWG + "person_customer_synthetic_1"
DIM = 8


# --------------------------------------------------------------------- servers
def _serve(handler):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


class Stores:
    def __init__(self):
        self.g = rdflib.Graph()
        self.points = {}          # qdrant id -> {"vector": [...], "payload": {...}}
        self.collections = set()
        self.embed_fails = False
        outer = self

        class Oxi(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body):
                self.send_response(code)
                self.send_header("Content-Type", "application/sparql-results+json")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
                self._send(200, outer.g.query(q).serialize(format="json"))

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
                if self.path.startswith("/update"):
                    outer.g.update(body)
                    self._send(204, b"")
                    return
                if (self.headers.get("Content-Type") or "").startswith("application/x-www-form-urlencoded"):
                    body = urllib.parse.parse_qs(body).get("query", [""])[0]
                self._send(200, outer.g.query(body).serialize(format="json"))

        class Embed(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                if outer.embed_fails:
                    self.send_response(500)
                    self.end_headers()
                    return
                texts = body.get("input") or []
                vecs = [[(hash((t, i)) % 1000) / 1000.0 for i in range(DIM)] for t in texts]
                out = json.dumps({"embeddings": vecs}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

        class Qdrant(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _j(self, result, code=200):
                out = json.dumps({"result": result, "status": "ok", "time": 0.0}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

            def _body(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                return json.loads(raw) if raw else {}

            @staticmethod
            def _match(pt, flt):
                for cond in (flt or {}).get("must", []):
                    if pt["payload"].get(cond["key"]) != cond["match"]["value"]:
                        return False
                return True

            def do_GET(self):
                p = urllib.parse.urlparse(self.path).path
                if p == "/":
                    return self._j({"title": "fake", "version": "1.9.0"})
                m = re.match(r"^/collections/([^/]+)(/exists)?$", p)
                if m and m.group(2):
                    return self._j({"exists": m.group(1) in outer.collections})
                if m:
                    if m.group(1) not in outer.collections:
                        return self._j({"error": "not found"}, 404)
                    return self._j({"status": "green", "points_count": len(outer.points),
                                    "vectors_count": len(outer.points),
                                    "config": {"params": {"vectors": {"size": DIM, "distance": "Cosine"}}}})
                self._j({"collections": [{"name": c} for c in sorted(outer.collections)]})

            def do_PUT(self):
                p = urllib.parse.urlparse(self.path).path
                b = self._body()
                m = re.match(r"^/collections/([^/]+)$", p)
                if m:
                    outer.collections.add(m.group(1))
                    return self._j(True)
                if re.match(r"^/collections/[^/]+/points$", p):
                    for pt in b.get("points", []):
                        outer.points[pt["id"]] = {"vector": pt.get("vector"), "payload": pt.get("payload") or {}}
                    return self._j({"operation_id": 0, "status": "completed"})
                if re.match(r"^/collections/[^/]+/index$", p):
                    return self._j({"operation_id": 0, "status": "completed"})
                self._j(True)

            def do_POST(self):
                p = urllib.parse.urlparse(self.path).path
                b = self._body()
                if p.endswith("/points/scroll"):
                    pts = [{"id": i, "payload": v["payload"]} for i, v in outer.points.items()
                           if self._match(v, b.get("filter"))]
                    return self._j({"points": pts[: int(b.get("limit") or 10)], "next_page_offset": None})
                if p.endswith("/points/delete"):
                    gone = [i for i, v in outer.points.items()
                            if (b.get("points") and i in b["points"]) or
                            (b.get("filter") and self._match(v, b["filter"]))]
                    for i in gone:
                        del outer.points[i]
                    return self._j({"operation_id": 0, "status": "completed"})
                if p.endswith("/points/count"):
                    return self._j({"count": sum(1 for v in outer.points.values() if self._match(v, b.get("filter")))})
                if p.endswith("/points"):
                    ids = b.get("ids") or []
                    return self._j([{"id": i, "payload": outer.points[i]["payload"], "vector": outer.points[i]["vector"]}
                                    for i in ids if i in outer.points])
                self._j(True)

        class Doctor(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                # ical-server api_hydration_status: contacts phase count = Qdrant people points.
                n = len(outer.points)
                out = json.dumps({"phases": [{"key": "contacts", "state": "done" if n else "pending",
                                              "count": n}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

        self.srvs = []
        for name, h in (("oxi", Oxi), ("embed", Embed), ("qdrant", Qdrant), ("doctor", Doctor)):
            s, url = _serve(h)
            self.srvs.append(s)
            setattr(self, name, url)

    def close(self):
        for s in self.srvs:
            s.shutdown()

    def person_count(self):
        return len(list(self.g.query(
            "PREFIX p:<%s> SELECT DISTINCT ?x WHERE { ?x a p:Person }" % PWG)))


# TEST-HARNESS RNG CONTROL, nothing shipped is touched. contact_syncer mints a card's Person id
# from uuid4; dedupe_merge keeps the lexicographically first URI as survivor, and the iMessage
# node's URI is a fixed uuid5 ("person_c525..."). So which node survives is a coin flip per run
# (~23% the iMessage node). With CCS_CARD_ID=high the card id sorts after it, with =low before it.
CARD_ID_SHIM = """import importlib.machinery, importlib.util, os, sys, uuid
# chain to the NEXT sitecustomize first: Homebrew's own one is what puts its site-packages on the path
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.machinery.PathFinder.find_spec(
    "sitecustomize", [p for p in sys.path if os.path.abspath(p or ".") != _here])
if _spec and _spec.loader:
    _spec.loader.exec_module(importlib.util.module_from_spec(_spec))
_mode = os.environ.get("CCS_CARD_ID")
if _mode:
    _n = [0]
    def _fake():
        _n[0] += 1
        return uuid.UUID(("f" if _mode == "high" else "0") + "%03x" % _n[0] + "0" * 28)
    uuid.uuid4 = _fake
"""


@pytest.fixture(autouse=True)
def _pin_survivor_order(monkeypatch):
    """With no repair step in the seed (r3), the iMessage-survivor order is the [116]-dependent
    RED shape. Pin the order every test runs in (low = card node survives); the high-order tests
    set it explicitly, so nothing here is a coin flip."""
    monkeypatch.setenv("CCS_CARD_ID", "low")


@pytest.fixture()
def stores():
    s = Stores()
    yield s
    s.close()


@pytest.fixture()
def home(tmp_path, stores):
    """A fake box account: the two installed venv pythons are wrappers that run this
    repo's vendored trees, pointed at the stand-in servers."""
    h = tmp_path / "acct"
    secrets = h / ".ostler" / "secrets"
    secrets.mkdir(parents=True)
    (secrets / "store-curl.conf").write_text('header = "Authorization: Bearer testtoken"\n')
    env = ("export OXIGRAPH_URL=%s QDRANT_URL=%s EMBED_OLLAMA_URL=%s DEFAULT_COUNTRY_CODE=44 "
           "USER_ID=walkowner STATE_FILE=%s NO_PROXY=127.0.0.1,localhost PYTHONDONTWRITEBYTECODE=1 "
           "PYTHONUSERBASE=%s\n"
           % (stores.oxi, stores.qdrant, stores.embed, h / "state.json", site.getuserbase()))
    shim = h / "pyshim"
    shim.mkdir()
    (shim / "sitecustomize.py").write_text(CARD_ID_SHIM)
    for rel, pp in ((".ostler/import-pipeline/.venv/bin/python", "vendor/cm041"),
                    (".ostler/services/email-ingest/.venv/bin/python", "vendor")):
        w = h / rel
        w.parent.mkdir(parents=True)
        pyp = ":".join([str(shim)] + [str(ROOT / x) for x in (pp, "vendor/cm041")])
        w.write_text("#!/bin/bash\n%sexport PYTHONPATH=%s\nexec %s \"$@\"\n" % (env, pyp, sys.executable))
        w.chmod(0o755)
    # the ingest module reads OXIGRAPH_URL at import; dedupe_merge too (os.getenv). Both come from env.
    return h


def _box_env(home, stores):
    return dict(os.environ, HOME=str(home), OSTLER_OXIGRAPH_URL=stores.oxi + "/query",
                OSTLER_QDRANT_URL=stores.qdrant, OSTLER_DOCTOR_PEOPLE_URL=stores.doctor + "/api/v1/hydration/status",
                OXIGRAPH_URL=stores.oxi, QDRANT_URL=stores.qdrant, OSTLER_BOX_HOST="", NO_PROXY="127.0.0.1,localhost",
                PYTHONDONTWRITEBYTECODE="1")


def seed_script(home, mutate=None):
    """The shipping box-side script, as _ccs_apply_script prints it, run under bash."""
    out = subprocess.run(["bash", "-c", 'source "%s"; _ccs_apply_script' % SEED_SH],
                         env=dict(os.environ, HOME=str(home)), capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    script = out.stdout
    if mutate:
        before = script
        script = mutate(script)
        assert script != before, "mutant did not change the script"
    return script


def run_seed(home, stores, mutate=None):
    r = subprocess.run(["bash", "-c", seed_script(home, mutate)], env=_box_env(home, stores),
                       capture_output=True, text=True, timeout=180)
    state = (r.stdout.strip().splitlines() or ["<no output>"])[-1]
    return state, r.stdout + r.stderr


def forget_script(home, mutate=None):
    out = subprocess.run(["bash", "-c", 'source "%s"; _ccs_forget_script' % SEED_SH],
                         env=dict(os.environ, HOME=str(home)), capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    script = out.stdout
    if mutate:
        before = script
        script = mutate(script)
        assert script != before, "mutant did not change the script"
    return script


def run_forget(home, stores, mutate=None):
    r = subprocess.run(["bash", "-c", forget_script(home, mutate)], env=_box_env(home, stores),
                       capture_output=True, text=True, timeout=120)
    return (r.stdout.strip().splitlines() or ["<no output>"])[-1]


def probe(name, home, stores, extra=None):
    env = _box_env(home, stores)
    env.update(extra or {})
    r = subprocess.run(["bash", str(PROBES / (name + ".sh"))], env=env, capture_output=True, text=True, timeout=300)
    text = r.stdout + r.stderr
    v = next((ln.split("VERDICT:")[1].strip() for ln in text.splitlines() if "VERDICT:" in ln), "NONE")
    return v, text


def live_persons(stores, phone):
    return len(list(stores.g.query(
        'PREFIX p:<%s> SELECT DISTINCT ?x WHERE { ?x a p:Person ; p:hasIdentifier ?i . '
        '?i p:identifierValue "%s" . FILTER NOT EXISTS { ?x p:mergedInto ?m } }' % (PWG, phone))))


# ------------------------------------------------------------------ the tests
def test_cold_graph_is_cannot_run_the_v1_0_115_shape(stores, home):
    v, text = probe("no_person_holds_two_contact_cards", home, stores)
    assert v.startswith("CANNOT-RUN"), text
    assert "ZERO icloud_contact_uid identifiers" in text


def test_the_seed_goes_through_the_shipped_paths_and_lands_every_property(stores, home):
    state, log = run_seed(home, stores)
    assert state == "seeded", log
    # vectors from the syncer's own embed + upsert, one per live card Person
    assert stores.person_count() == len(fx.CARDS)
    assert len(stores.points) == len(fx.CARDS)
    # the nameless number: exactly one live holder (card + handle folded)
    assert live_persons(stores, fx.NAMELESS_PHONE) == 1
    # the household landline: two people, kept apart (RULE 2) = a real opportunity
    assert live_persons(stores, fx.HOUSEHOLD_PHONE) == 2
    # the handle really arrived through ingest: an imessage-labelled identifier exists
    assert bool(stores.g.query('PREFIX p:<%s> ASK { ?i p:identifierLabel "IMESSAGE" ; p:identifierValue "%s" }'
                               % (PWG, fx.NAMELESS_PHONE)).askAnswer)


def test_seeded_run_exercises_the_guard_and_passes(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    v, text = probe("no_person_holds_two_contact_cards", home, stores)
    assert v.startswith("PASS"), text
    assert "GUARD IS UNEXERCISED" not in text, text
    assert "so the zero was earned, not vacuous" in text, text
    m = re.search(r"collision opportunities: (\d+) Person node", text)
    assert m and int(m.group(1)) >= 1, text
    assert "EXAMINED: %d icloud_contact_uid" % len(fx.CARDS) in text, text


def test_the_r1_direct_insert_was_a_vacuous_pass(stores, home):
    """The control for the finding: six cards written straight into the graph, unique
    numbers. The probe passes, and says the guard was never asked."""
    t = []
    for n in range(1, 7):
        p = "<%sperson_direct%d>" % (PWG, n)
        i = "<%sid_direct%d>" % (PWG, n)
        t += ["%s a pwg:Person" % p, "%s pwg:hasIdentifier %s" % (p, i), "%s a pwg:PersonIdentifier" % i,
              '%s pwg:identifierType "icloud_contact_uid"' % i, '%s pwg:identifierValue "DIRECT-%d"' % (i, n)]
        j = "<%sid_directp%d>" % (PWG, n)
        t += ["%s pwg:hasIdentifier %s" % (p, j), '%s pwg:identifierType "phone"' % j,
              '%s pwg:identifierValue "+4477009002%02d"' % (j, n)]
    stores.g.update("PREFIX pwg: <%s> INSERT DATA { %s }" % (PWG, " . ".join(t)))
    v, text = probe("no_person_holds_two_contact_cards", home, stores)
    assert v.startswith("PASS") and "GUARD IS UNEXERCISED" in text, text
    assert len(stores.points) == 0, "and not one of those Persons has a vector"


def test_probe_still_fails_when_a_duplicate_card_is_forced(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    # force the defect: card 1's Person also holds card 2's uid
    stores.g.update(
        'PREFIX pwg: <%s> INSERT { ?p pwg:hasIdentifier <urn:x:dupuid> . <urn:x:dupuid> pwg:identifierType '
        '"icloud_contact_uid" ; pwg:identifierValue "%s" } WHERE { ?p pwg:hasIdentifier ?i . '
        '?i pwg:identifierValue "%s" }' % (PWG, fx.card_uid(2), fx.card_uid(1)))
    v, text = probe("no_person_holds_two_contact_cards", home, stores)
    assert v.startswith("FAIL"), text
    assert "1 Person node(s) each carry 2+ distinct icloud_contact_uid" in text


def test_people_stores_reconcile_passes_with_the_seed(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    v, text = probe("people_stores_reconcile", home, stores,
                    {"OSTLER_PROBE_RECONCILE_GAP_S": "0", "OSTLER_PROBE_TILE_GAP_S": "0"})
    assert v.startswith("PASS"), text


def test_people_stores_reconcile_is_red_for_the_r1_shape(stores, home):
    """Control: Persons in the graph with no vector read red on the SAME probe."""
    assert run_seed(home, stores)[0] == "seeded"
    stores.points.clear()
    v, text = probe("people_stores_reconcile", home, stores,
                    {"OSTLER_PROBE_RECONCILE_GAP_S": "0", "OSTLER_PROBE_TILE_GAP_S": "0"})
    assert not v.startswith("PASS"), text


def test_people_count_agreement_passes_with_the_seed_and_the_cap_is_a_probe_tolerance(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    knobs = {"OSTLER_PEOPLE_STABILITY_STEP_S": "1", "OSTLER_PEOPLE_STABILITY_WAIT_S": "10",
             "OSTLER_PEOPLE_CONVERGE_WAIT_S": "0", "OSTLER_PROBE_STATE_DIR": str(home / "pstate")}
    v, text = probe("people_count_agreement", home, stores, knobs)
    assert v.startswith("PASS"), text
    assert "oxigraph SPARQL count : %d" % len(fx.CARDS) in text, text
    assert "doctor api count      : %d" % len(fx.CARDS) in text, text
    # control: without vectors the Doctor count is 0 and the same probe is not a pass
    stores.points.clear()
    v2, text2 = probe("people_count_agreement", home, stores, knobs)
    assert not v2.startswith("PASS"), text2


def test_seed_skips_when_the_box_has_real_contacts_and_writes_nothing(stores, home):
    stores.g.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> a pwg:Person ; pwg:hasIdentifier <urn:x:c> . '
        '<urn:x:c> pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "SYNTH-REAL" }' % (PWG, CUSTOMER))
    before = len(stores.g)
    state, log = run_seed(home, stores)
    assert state == "skipped-real-contacts", log
    assert len(stores.g) == before and not stores.points


def test_a_second_seed_is_idempotent(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    n_g, n_p = len(stores.g), len(stores.points)
    assert run_seed(home, stores)[0] == "seeded"
    assert stores.person_count() == len(fx.CARDS) and len(stores.points) == n_p


def test_forget_removes_the_cast_graph_and_vectors_and_spares_the_customer(stores, home):
    stores.g.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> a pwg:Person ; pwg:displayName "Bob Jones" }' % (PWG, CUSTOMER))
    cust_triples = len(stores.g)
    assert run_seed(home, stores)[0] == "seeded"
    # a customer point must survive too
    stores.points["cust-point"] = {"vector": [0.0] * DIM, "payload": {"person_uri": CUSTOMER}}
    seed_dir = home / ".ostler" / "walk-seed" / "contact-cards"
    assert seed_dir.is_dir() and (seed_dir / "cards.vcf").exists()
    assert run_forget(home, stores) == "removed"
    assert not seed_dir.exists(), "forget left ~/.ostler/walk-seed/contact-cards behind"
    assert len(stores.g) == cust_triples, "forget left or took triples that were not the cast's"
    # the shipped reconcile also embedded the customer's own Person; both customer points stay
    assert {v["payload"]["person_uri"] for v in stores.points.values()} == {CUSTOMER}
    assert "cust-point" in stores.points
    assert run_forget(home, stores) == "nothing-to-remove"


# ----------------------------------------------------------------- mutants
def test_mutant_without_the_merge_sweep_the_nameless_number_has_two_holders_and_the_seed_refuses(stores, home):
    state, log = run_seed(home, stores, mutate=lambda s: s.replace("m = dedupe_merge.run()", "m = {}"))
    assert state == "failed-nameless-number-held-by-2", log


def test_mutant_without_the_ingest_the_nameless_case_is_not_exercised_and_the_seed_refuses(stores, home):
    """Dropping the ingest leaves one holder trivially; the seed must still not claim the
    handle arrived. The read-back counts the IMESSAGE identifier, not just the holders."""
    state, log = run_seed(home, stores, mutate=lambda s: s.replace("r = pwg_ingest.ingest_imessage(Path(sys.argv[1]));", "r = {};"))
    assert state == "failed-handle-never-ingested", log


# CCS_CARD_ID=high makes dedupe_merge keep the iMessage-minted node as the survivor, so the
# contact_syncer vector on the merged-away card node is left behind (the macOS CI runner hit
# this shape unprompted: 9 vectors for 8 people).


def test_seed_runs_no_repair_step_it_follows_the_shipped_install_order():
    """r3: the seed must not paper over the install order with its own repair."""
    assert "repair_merge_consistency" not in seed_script(Path("/nonexistent-home"))


def test_shipped_order_with_the_iMessage_survivor_refuses_a_stale_vector(stores, home, monkeypatch):
    """The honest state today: without [116] (repair after dedupe in install.sh) the seed
    refuses, and says why. 9 vectors for 8 people."""
    monkeypatch.setenv("CCS_CARD_ID", "high")
    state, log = run_seed(home, stores)
    assert state == "failed-stale-vector-1", log
    assert len(stores.points) == len(fx.CARDS) + 1, "9 vectors for 8 people"


def test_DEPENDS_ON_116_shipped_order_seeds_clean_and_the_reconcile_probe_passes(stores, home, monkeypatch):
    monkeypatch.setenv("CCS_CARD_ID", "high")
    assert run_seed(home, stores)[0] == "seeded"
    assert len(stores.points) == len(fx.CARDS)
    v, text = probe("people_stores_reconcile", home, stores,
                    {"OSTLER_PROBE_RECONCILE_GAP_S": "0", "OSTLER_PROBE_TILE_GAP_S": "0"})
    assert v.startswith("PASS"), text


def test_the_survivor_order_the_probes_pass_on_today_all_three_probes_pass(stores, home, monkeypatch):
    monkeypatch.setenv("CCS_CARD_ID", "low")
    assert run_seed(home, stores)[0] == "seeded"
    v, text = probe("people_stores_reconcile", home, stores,
                    {"OSTLER_PROBE_RECONCILE_GAP_S": "0", "OSTLER_PROBE_TILE_GAP_S": "0"})
    assert v.startswith("PASS"), text
    knobs = {"OSTLER_PEOPLE_STABILITY_STEP_S": "1", "OSTLER_PEOPLE_STABILITY_WAIT_S": "10",
             "OSTLER_PEOPLE_CONVERGE_WAIT_S": "0", "OSTLER_PROBE_STATE_DIR": str(home / "pstate")}
    v, text = probe("people_count_agreement", home, stores, knobs)
    assert v.startswith("PASS"), text
    v, text = probe("no_person_holds_two_contact_cards", home, stores)
    assert v.startswith("PASS") and "so the zero was earned, not vacuous" in text, text


def test_stderr_is_surfaced_not_discarded():
    """r3: stage, parse, forget and both ssh transports must not throw stderr away."""
    sh = SEED_SH.read_text() if hasattr(SEED_SH, "read_text") else open(SEED_SH).read()
    code = [ln for ln in sh.splitlines() if not ln.lstrip().startswith("#")]
    for ln in code:
        if "contact_cards_fixture.py stage" in ln or "/usr/bin/python3 -c" in ln:
            assert "2>/dev/null" not in ln and "2>&1" not in ln, ln
        if ln.lstrip().startswith("_ccs_box") or "_ccs_box \"" in ln:
            assert "2>/dev/null" not in ln, ln


def test_forget_mutant_without_the_rm_leaves_the_dir(stores, home):
    assert run_seed(home, stores)[0] == "seeded"
    run_forget(home, stores, mutate=lambda s: s.replace('rm -rf "$D"; ', ""))
    assert (home / ".ostler" / "walk-seed" / "contact-cards").exists()


def test_stage_failure_shows_its_stderr(stores, home):
    r = subprocess.run(["bash", "-c", seed_script(home, lambda s: s.replace(
        "contact_cards_fixture.py stage", "contact_cards_fixture.py stage-NOPE"))],
        env=_box_env(home, stores), capture_output=True, text=True, timeout=120)
    assert r.stdout.strip().splitlines()[-1] == "failed-stage-cards"
    assert r.stderr.strip(), "stage stderr was swallowed"


def test_the_other_survivor_order_seeds_clean_too(stores, home, monkeypatch):
    monkeypatch.setenv("CCS_CARD_ID", "low")
    assert run_seed(home, stores)[0] == "seeded"
    assert len(stores.points) == len(fx.CARDS)


def test_mutant_with_a_dead_embedder_the_seed_refuses_for_want_of_vectors(stores, home):
    stores.embed_fails = True
    state, log = run_seed(home, stores)
    assert state != "seeded", log
    assert state.startswith("failed-"), log


def test_verdict_names_every_arm():
    ok = {"cast_persons": len(fx.CARDS), "cast_without_vector": 0, "stale_vectors": 0, "nameless_holders": 1,
          "shared_holders": 2, "handle_ingested": 1}
    assert fx.verdict(ok) == "seeded"
    assert fx.verdict(dict(ok, cast_without_vector=3)) == "failed-no-vector-3"
    assert fx.verdict(dict(ok, nameless_holders=2)) == "failed-nameless-number-held-by-2"
    assert fx.verdict(dict(ok, nameless_holders=0)) == "failed-nameless-number-held-by-0"
    assert fx.verdict(dict(ok, stale_vectors=1)) == "failed-stale-vector-1"
    assert fx.verdict(dict(ok, handle_ingested=0)) == "failed-handle-never-ingested"
    assert fx.verdict(dict(ok, shared_holders=1)) == "failed-household-line-held-by-1"
    assert fx.verdict(dict(ok, cast_persons=2)).startswith("failed-cast-persons-2")


# ---------------------------------------------------------------- the cast
def test_cast_is_synthetic_and_has_a_real_collision_and_a_nameless_card():
    phones = [p for c in fx.CARDS for p in c[3]]
    assert all(p.startswith("+447700900") for p in phones)
    assert all(e.endswith("@example.com") for c in fx.CARDS for e in c[4])
    assert len(phones) - len(set(phones)) >= 1, "at least one number is on two cards"
    assert any(not c[1] and not c[2] for c in fx.CARDS), "a nameless card"
    assert fx.NAMELESS_PHONE == "+447700900107"
    assert len({fx.card_uid(c[0]) for c in fx.CARDS}) == len(fx.CARDS)


def test_the_runner_calls_the_seed_and_the_forget():
    """Unwired is the defect class: the walk must call both, flush left, as the
    sibling seed tests grep for."""
    runner = (ROOT / "scripts" / "box_walk_probes" / "run_box_walk.sh").read_text().splitlines()
    assert "contact_cards_apply || true" in runner
    assert "contact_cards_forget || true" in runner
    assert any(ln.strip().startswith("declare -F contact_cards_forget") for ln in runner)
