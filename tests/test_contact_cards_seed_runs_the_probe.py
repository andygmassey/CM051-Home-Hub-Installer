"""no_person_holds_two_contact_cards must RUN on a cold walk account (CM051 #2545 gate).

v1.0.115 (walk34) graded the BLOCKING probe CANNOT-RUN: "ZERO icloud_contact_uid
identifiers in the graph". A cold account has no Contacts, so the probe's
anti-vacuity control read 0 and refused to interpret the zero. CANNOT-RUN is not
PASS, so the walk now seeds six synthetic cards (lib/contact_cards_fixture.py)
before the probes read the box.

THE STORE IS REAL, NOT A MOCK: a loopback HTTP server over an rdflib graph runs
the SHIPPING probe's SPARQL (and the seed's INSERT/DELETE) for real, so a query
that stopped selecting the defect would fail here.

Arms: (1) cold graph -> CANNOT-RUN (the v1.0.115 shape, the control);
(2) seeded -> PASS and measured over 6 identifiers; (3) a card written onto a
second person -> FAIL (the predicate still goes red); (4) forget leaves nothing
and never touches a customer triple; (5) real contacts present -> seed skips.
Every name, number and address is synthetic (example.com, Ofcom drama range).
"""
from __future__ import annotations

import http.server
import os
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib", reason="rdflib backs the in-memory store")

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts" / "box_walk_probes" / "lib"
PROBE = ROOT / "scripts" / "box_walk_probes" / "probes" / "no_person_holds_two_contact_cards.sh"
sys.path.insert(0, str(LIB))

PWG = "https://schema.ostler.ai/ontology#"
CUSTOMER = "https://schema.ostler.ai/person/customer-synthetic-1"


class _Store:
    def __init__(self):
        self.g = rdflib.Graph()
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body, ctype="application/sparql-results+json"):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
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
                else:
                    self._send(200, outer.g.query(body).serialize(format="json"))

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


@pytest.fixture()
def store():
    s = _Store()
    yield s
    s.close()


@pytest.fixture()
def home(tmp_path):
    secrets = tmp_path / ".ostler" / "secrets"
    secrets.mkdir(parents=True)
    (secrets / "store-curl.conf").write_text('header = "Authorization: Bearer testtoken"\n')
    return tmp_path


def run_probe(store, home):
    env = dict(os.environ, HOME=str(home), OSTLER_OXIGRAPH_URL=store.base + "/query",
               OSTLER_BOX_HOST="", NO_PROXY="127.0.0.1,localhost")
    out = subprocess.run(["bash", str(PROBE)], env=env, capture_output=True, text=True, timeout=120)
    text = out.stdout + out.stderr
    verdict = next((ln.split("VERDICT:")[1].strip() for ln in text.splitlines() if "VERDICT:" in ln), "NONE")
    return verdict, text


def test_cold_graph_is_cannot_run_the_v1_0_115_shape(store, home):
    verdict, text = run_probe(store, home)
    assert verdict.startswith("CANNOT-RUN"), text
    assert "ZERO icloud_contact_uid identifiers" in text


def test_seeded_cold_graph_runs_and_passes(store, home):
    import contact_cards_fixture as fx
    assert fx.seed(str(home), store.base) == "seeded"
    verdict, text = run_probe(store, home)
    assert verdict.startswith("PASS"), text
    assert "EXAMINED: %d icloud_contact_uid" % len(fx.CARDS) in text


def test_probe_still_fails_when_a_person_holds_two_cards(store, home):
    import contact_cards_fixture as fx
    assert fx.seed(str(home), store.base) == "seeded"
    # Write card 2's uid onto person 1: the RULE 2 violation the probe exists for.
    store.g.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s1> pwg:hasIdentifier <urn:x:dup> . '
        '<urn:x:dup> pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "%s" }'
        % (PWG, fx.FIXTURE_PREFIX, fx.card_uid(2) + "-second"))
    verdict, text = run_probe(store, home)
    assert verdict.startswith("FAIL"), text
    assert "1 Person node(s) each carry 2+ distinct icloud_contact_uid" in text


def test_fixture_has_no_phone_or_email_on_two_people():
    import contact_cards_fixture as fx
    phones = [c[1] for c in fx.CARDS]
    emails = [c[2] for c in fx.CARDS]
    assert len(set(phones)) == len(phones) and len(set(emails)) == len(emails)
    assert all(p.startswith("+447700900") for p in phones)
    assert all(e.endswith("@example.com") for e in emails)


def test_seed_skips_when_the_box_has_real_contacts_and_forget_spares_them(store, home):
    import contact_cards_fixture as fx
    store.g.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> a pwg:Person ; pwg:hasIdentifier <urn:x:c> . '
        '<urn:x:c> pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "SYNTH-REAL" }'
        % (PWG, CUSTOMER))
    before = len(store.g)
    assert fx.seed(str(home), store.base) == "skipped-real-contacts"
    assert len(store.g) == before


def test_forget_removes_only_the_fixture(store, home):
    import contact_cards_fixture as fx
    assert fx.seed(str(home), store.base) == "seeded"
    store.g.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> a pwg:Person ; pwg:displayName "Synthetic Customer" }'
        % (PWG, CUSTOMER))
    assert fx.forget(str(home), store.base) == "removed"
    assert len(store.g) == 2
    assert fx.forget(str(home), store.base) == "nothing-to-remove"


def test_the_runner_calls_the_seed_and_the_forget():
    """Unwired is the defect class: the walk must call both, flush left, as the
    sibling seed tests grep for."""
    runner = (ROOT / "scripts" / "box_walk_probes" / "run_box_walk.sh").read_text().splitlines()
    assert "contact_cards_apply || true" in runner
    assert "contact_cards_forget || true" in runner
    assert any(ln.strip().startswith("declare -F contact_cards_forget") for ln in runner)
