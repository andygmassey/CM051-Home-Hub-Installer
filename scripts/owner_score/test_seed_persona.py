"""Self-tests for seed_persona.py: seed the synthetic persona, prove the counts,
purge it, prove the rest of the store is exactly as it was.

The store is the REAL Oxigraph engine (pyoxigraph; default graph NOT unioned, as
the product runs it) behind a loopback HTTP server that enforces the bearer
token, so the SPARQL the tool writes is executed, not pattern-matched.
Needs pyoxigraph; without it this file exits 77 (CANNOT-RUN, never a pass).

Run: python3 -I scripts/owner_score/test_seed_persona.py
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import pyoxigraph
except ImportError:
    print("CANNOT-RUN: pyoxigraph is not installed (pip install pyoxigraph); the seed/purge proof did not run")
    sys.exit(77)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import seed_persona as sp  # noqa: E402

TOKEN = "oxi-test-token"
UID = "u-test-1"
PERSONA = sp.load_persona()
PLAN = sp.build_plan(PERSONA, UID)

# rows that are NOT ours and must survive everything: one in the default graph, one in the
# owner's named graph, one in the product's own namespace, one that merely MENTIONS our prefix
UNRELATED = """
INSERT DATA {
  <urn:test:unrelated-1> <urn:test:label> "unrelated fixture row" .
  <https://schema.ostler.ai/ontology#person_real_1> a <https://schema.ostler.ai/ontology#Person> ;
        <https://schema.ostler.ai/ontology#displayName> "product-owned row" .
  GRAPH <urn:ostler:user/%s> {
    <urn:test:unrelated-fact> a <urn:ostler:Fact> ; <urn:ostler:text> "unrelated named-graph row" .
    <urn:test:mentions-prefix> <urn:test:note> "%sperson_x as text only" .
  }
}""" % (UID, sp.PREFIX)


class StoreHandler(BaseHTTPRequestHandler):
    ds = None

    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_response(401)
            self.end_headers()
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/update":
            self.ds.update(body)
            self.send_response(204)
            self.end_headers()
        elif self.path == "/query":
            out = self.ds.query(body)
            buf = io.BytesIO()
            out.serialize(buf, format=pyoxigraph.QueryResultsFormat.JSON)
            out = buf.getvalue()
            self.send_response(200)
            self.send_header("Content-Type", "application/sparql-results+json")
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_response(404)
            self.end_headers()


class SeedAndPurge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.ds = pyoxigraph.Store()
        self.ds.update(UNRELATED)
        h = type("H", (StoreHandler,), {"ds": self.ds})
        self.srv = HTTPServer(("127.0.0.1", 0), h)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.addCleanup(self.srv.server_close)
        self.tok = os.path.join(self.tmp, "tok")
        open(self.tok, "w").write(TOKEN + "\n")
        self.ws = os.path.join(self.tmp, "ws")
        os.makedirs(self.ws)
        self.root = os.path.join(self.tmp, "Conversations")
        # an unrelated conversation that must survive, in a date folder that already exists
        self.keep = os.path.join(self.root, "2026-10-06", "someone-elses-0000beef")
        os.makedirs(self.keep)
        open(os.path.join(self.keep, "summary.md"), "w").write("---\nconversation_id: not-ours\n---\nkeep me\n")
        self.env = dict(os.environ, HOME=self.tmp, OSTLER_STATE_DIR=os.path.join(self.tmp, "state"))

    def run_cmd(self, cmd, token=None, workspace=True):
        if workspace:
            open(os.path.join(self.ws, "CONTEXT.md"), "w").write("# Personal Context\n\n" + sp.MARKER + ".\n")
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "seed_persona.py"), cmd,
                            "--store", "http://127.0.0.1:%d" % self.srv.server_port,
                            "--token-path", token or self.tok, "--user-id", UID,
                            "--conversations-root", self.root, "--workspace", self.ws],
                           capture_output=True, text=True, env=self.env)
        return r

    def n(self, q):
        return int(next(iter(self.ds.query(q)))[0].value)

    def total(self):
        return self.n("SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } }")

    def seeded(self):
        f = 'STRSTARTS(STR(?s), "%s")' % sp.PREFIX
        return (self.n("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o FILTER(%s) }" % f)
                + self.n("SELECT (COUNT(*) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o FILTER(%s) } }" % f))

    def folders(self):
        return sorted(os.path.join(d, s) for d in os.listdir(self.root) if os.path.isdir(os.path.join(self.root, d))
                      for s in os.listdir(os.path.join(self.root, d)))

    # ---------------------------------------------------------------------------------
    def test_seed_then_purge_is_proven_by_counts_on_a_fixture(self):
        t0, folders0 = self.total(), self.folders()
        self.assertEqual(self.seeded(), 0)
        self.assertEqual(t0, 6)   # 1 + 2 + 2 + 1 unrelated triples

        r = self.run_cmd("seed")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertGreater(PLAN["expected_triples"], 700)
        self.assertEqual(self.seeded(), PLAN["expected_triples"])
        self.assertEqual(self.total(), t0 + PLAN["expected_triples"])
        self.assertEqual(len(self.folders()), len(folders0) + 9)
        self.assertIn("SEEDED triples=%d expected=%d" % (PLAN["expected_triples"], PLAN["expected_triples"]), r.stdout)

        r = self.run_cmd("purge")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.seeded(), 0)
        self.assertEqual(self.total(), t0)                         # the rest of the store: exactly as it was
        self.assertEqual(self.folders(), folders0)                 # the unrelated conversation is untouched
        self.assertEqual(sorted(os.listdir(self.root)), ["2026-10-06"])   # date folders WE made are gone, theirs stays
        self.assertTrue(os.path.exists(os.path.join(self.keep, "summary.md")))
        self.assertFalse(os.path.exists(sp.manifest_path(self.root)))
        self.assertIn("PURGED triples=%d conversations=9 rest_of_store_unchanged=yes OK" % PLAN["expected_triples"], r.stdout)

    def test_purge_is_idempotent_and_safe_on_an_unseeded_store(self):
        t0 = self.total()
        r = self.run_cmd("purge")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PURGED triples=0 conversations=0", r.stdout)
        self.assertEqual(self.total(), t0)

    def test_what_was_seeded_is_the_shape_the_readers_look_for(self):
        self.assertEqual(self.run_cmd("seed").returncode, 0)
        q = ('SELECT (COUNT(*) AS ?n) WHERE { GRAPH <urn:ostler:user/%s> { ?f a <urn:ostler:Fact> ; '
             '<urn:ostler:text> ?t ; <urn:ostler:about> ?p } ?p a <%sPerson> ; <%sdisplayName> "Sam Ross" . '
             'FILTER(CONTAINS(?t, "best friend")) }' % (UID, sp.NS, sp.NS))
        self.assertEqual(self.n(q), 1)    # a lookup by NAME reaches the relation, via the person node
        qd = 'SELECT (COUNT(*) AS ?n) WHERE { ?p a <%sPerson> ; <%sdisplayName> "Jane Smith" }' % (sp.NS, sp.NS)
        self.assertEqual(self.n(qd), 1)
        for f in self.folders():
            if "someone-elses" in f:
                continue
            body = open(os.path.join(self.root, f, "summary.md")).read()
            self.assertIn("owner_score_seed: true", body)
        self.assertEqual(len([f for f in self.folders() if "someone-elses" not in f]), 9)

    def test_seed_refuses_a_box_that_is_not_declared_synthetic_and_writes_nothing(self):
        t0 = self.total()
        r = self.run_cmd("seed", workspace=False)
        self.assertEqual(r.returncode, 10, r.stdout)
        self.assertIn("REFUSED", r.stdout)
        self.assertEqual((self.total(), self.seeded()), (t0, 0))
        self.assertEqual(len(self.folders()), 1)

    def test_a_second_seed_is_refused_until_the_first_is_purged(self):
        self.assertEqual(self.run_cmd("seed").returncode, 0)
        n = self.total()
        r = self.run_cmd("seed")
        self.assertEqual(r.returncode, 10)
        self.assertEqual(self.total(), n)

    def test_a_wrong_token_is_cannot_run_and_changes_nothing(self):
        bad = os.path.join(self.tmp, "bad")
        open(bad, "w").write("nope")
        t0 = self.total()
        r = self.run_cmd("seed", token=bad)
        self.assertEqual(r.returncode, 78, r.stdout)
        self.assertIn("HTTP 401", r.stdout)
        self.assertEqual(self.total(), t0)

    def test_purge_never_deletes_a_folder_without_our_marker(self):
        self.assertEqual(self.run_cmd("seed").returncode, 0)
        # a stray in the manifest with no marker must be left alone
        m = json.load(open(sp.manifest_path(self.root)))
        m["folders"].append(os.path.join("2026-10-06", "someone-elses-0000beef"))
        json.dump(m, open(sp.manifest_path(self.root), "w"))
        self.assertEqual(self.run_cmd("purge").returncode, 0)
        self.assertTrue(os.path.exists(os.path.join(self.keep, "summary.md")))

    def test_NEGATIVE_CONTROL_a_too_wide_purge_is_caught_by_the_same_counts(self):
        """Prove the before/after counts CAN go red: widen the prefix to the whole product
        namespace and the unrelated product-owned row is deleted, so rest-of-store moves."""
        self.assertEqual(self.run_cmd("seed").returncode, 0)
        t_seeded = self.total()
        wide = sp.purge_update().replace(sp.PREFIX, sp.NS)
        self.ds.update(wide)
        removed = t_seeded - self.total()
        self.assertGreater(removed, PLAN["expected_triples"])      # it took more than we seeded
        self.assertNotEqual(self.total(), 6)                        # and the invariant the real test asserts fails

    def test_conversation_dates_come_from_the_persona_words_not_from_the_sentence_tail(self):
        got = {c["text"][:22]: c["date"] for c in PLAN["conversations"]}
        self.assertEqual(got["Last Friday Bob confir"], "2026-10-02")   # '... booked for 20 October' is the subject
        self.assertEqual(got["On Tuesday 6 October, "], "2026-10-06")
        self.assertEqual(got["Jane and Tom chose the"], "2026-10-07")   # 'yesterday' against as_of 2026-10-08

    def test_every_seeded_subject_is_inside_the_namespace(self):
        g = pyoxigraph.Store()
        g.update(PLAN["update"])
        subjects = {r[0].value for r in g.query("SELECT DISTINCT ?s WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } }")}
        self.assertTrue(subjects)
        self.assertTrue(all(s.startswith(sp.PREFIX) for s in subjects), [s for s in subjects if not s.startswith(sp.PREFIX)])


if __name__ == "__main__":
    unittest.main(verbosity=1)
