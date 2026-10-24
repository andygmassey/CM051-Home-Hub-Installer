"""walk #31 (v1.0.108): on a synthetic box the owner digest said "People you
interact with most: nothing stored" and "Key organisations: nothing stored",
and owner_digest_knows_the_owner could never go green, because the grounding
seed's person carried no interaction and no organisation: only asserted facts.

lib/owner_employer_seed.sh now gives that person what a contact the owner
texts carries, in the writers' own shapes (an iMessage last-contact date, a
Contacts organisation), each paired with a walkSeed marker the forget removes.
Also pinned: the importer log is per-user, never the fixed /tmp path that one
macOS account left unwritable for the next (walk #31: "permission denied", the
import never ran, and another account's stale log was printed as this one's).

REAL SPARQL engine (pyoxigraph behind /query + /update), REAL /usr/bin/curl,
the seed lib sourced and run as the walk runs it, then the shipped generator.
  RED   the v1.0.108 seed lib (pinned) leaves the person with no interaction:
        People and Key organisations read "nothing stored".
  GREEN this lib: the person and its organisation reach both sections; the
        forget removes exactly what was added; no write when the person is not
        declared synthetic. Synthetic cast only. macOS (BSD stat, as on the Hub).
"""
import importlib.util
import json
import os
import platform
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyoxigraph as ox

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
REL = "scripts/box_walk_probes/lib/owner_employer_seed.sh"
GEN = os.path.join(REPO, "context-refresh", "bin", "generate_pwg_context.py")
V1_0_108 = "56a5ed21f708e517bc812fa03b6ff49b01bc2fc8"
PWG = "https://schema.ostler.ai/ontology#"
SEED = "Jane Doe"
# The seed person's organisation must be the employer the grounding seed gives
# her (OS003 gates/seed/seed_fixture.json: "at example.com"). Walk #32: a
# different one here made the opening-turn probe 1/10, because the reply named
# the Organisation line and dropped the grounding fact.
SEED_ORG = "example.com"
OWNER = "Sam Patel"


def _serve(store):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _json(self, payload, code=200):
            b = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):  # the ical-server stand-in for the generator
            self._json({"items": [], "observations": [], "found": False})

        def do_POST(self):
            q = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            try:
                if self.path.startswith("/update"):
                    store.update(q)
                    self.send_response(204)
                    self.end_headers()
                    return
                res = store.query(q)
                vars_ = [v.value for v in res.variables]
                rows = [{v: {"type": "uri" if isinstance(s[v], ox.NamedNode) else "literal", "value": s[v].value}
                         for v in vars_ if s[v] is not None} for s in res]
                self._json({"head": {"vars": vars_}, "results": {"bindings": rows}})
            except Exception as exc:
                self._json({"error": str(exc)}, 400)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _store():
    st = ox.Store()
    t = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    p = ox.NamedNode(PWG + "person_walkfixture_seed")   # as /api/v1/memory/assert creates it
    for pr, o in ((t, ox.NamedNode(PWG + "Person")), (ox.NamedNode(PWG + "displayName"), ox.Literal(SEED))):
        st.add(ox.Quad(p, pr, o, ox.DefaultGraph()))
    return st


def _count(st, where):
    return int(next(iter(st.query("PREFIX pwg: <%s> SELECT (COUNT(*) AS ?n) WHERE { %s }" % (PWG, where))))["n"].value)


def _run(lib, home, port, fn, synthetic=True):
    os.makedirs(os.path.join(home, ".ostler", "bin"), exist_ok=True)
    os.makedirs(os.path.join(home, ".ostler", "assistant-config", "workspace"), exist_ok=True)
    os.makedirs(os.path.join(home, "stub"), exist_ok=True)
    imp = os.path.join(home, ".ostler", "bin", "ostler-import")
    open(imp, "w").write("#!/bin/sh\necho IMPORTER-RAN-FOR-THIS-ACCOUNT\nexit 0\n")
    for name in ("launchctl", "sleep"):
        open(os.path.join(home, "stub", name), "w").write("#!/bin/sh\nexit 0\n")
    for f in (imp, os.path.join(home, "stub", "launchctl"), os.path.join(home, "stub", "sleep")):
        os.chmod(f, 0o755)
    conf = os.path.join(home, "store-curl.conf")
    open(conf, "w").write("")
    env = dict(os.environ, HOME=home, PATH=os.path.join(home, "stub") + ":" + os.environ["PATH"],
               OSTLER_OES_CURL="/usr/bin/curl", OSTLER_OES_PY="/usr/bin/python3",
               OSTLER_OXIGRAPH_URL="http://127.0.0.1:%d/query" % port,
               OSTLER_PROBE_STORE_CURL_CONF=conf, OSTLER_GATE_KNOWN_PERSON=SEED,
               OSTLER_SEED_PERSON_IS_SYNTHETIC="1" if synthetic else "0")
    env.pop("OSTLER_BOX_HOST", None)
    script = '. "%s"; _oes_box() { bash -c "$1"; }; %s; echo "STATE=$OSTLER_OWNER_SEED_STATE"' % (lib, fn)
    return subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True, timeout=120).stdout


def _digest(port, home):
    os.makedirs(os.path.join(home, "o", "config"), exist_ok=True)
    open(os.path.join(home, "o", "config", ".env"), "w").write('USER_ID="walkowner"\nUSER_NAME="%s"\n' % OWNER)
    os.environ.update(OSTLER_DIR=os.path.join(home, "o"), OXIGRAPH_URL="http://127.0.0.1:%d" % port,
                      OSTLER_ICAL_BASE_URL="http://127.0.0.1:%d" % port, OSTLER_SERVICE_TOKEN="t",
                      OSTLER_OXIGRAPH_TOKEN="t", ZEROCLAW_WORKSPACE_DIR=os.path.join(home, "ws"),
                      no_proxy="127.0.0.1,localhost", NO_PROXY="127.0.0.1,localhost")
    spec = importlib.util.spec_from_file_location("gen_%d" % port, GEN)
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    d = g.build_digest() or ""

    def section(h):
        if "## " + h not in d:
            return ""
        return d.split("## " + h, 1)[1].split("\n## ", 1)[0]
    return section("People you interact with most"), section("Key organisations")


def main():
    if platform.system() != "Darwin":
        print("CANNOT-RUN: needs macOS (the seed uses BSD stat, as on the Hub)")
        return 2
    try:
        old_src = subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (V1_0_108, REL)],
                                 capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, OSError) as exc:
        print("CANNOT-RUN: v1.0.108 seed lib not readable (needs full history): %s" % exc)
        return 2
    tmp = tempfile.mkdtemp()
    old_lib = os.path.join(tmp, "owner_employer_seed_v1_0_108.sh")
    open(old_lib, "w").write(old_src)
    new_lib = os.path.join(REPO, REL)
    fails = 0

    def arm(name, ok, got=""):
        nonlocal fails
        print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, got))
        fails += 0 if ok else 1

    print("0. the seed lib never names a shared /tmp path")
    arm("no '/tmp/' in the lib (one account's file blocks the next)", "/tmp/" not in open(new_lib).read())
    arm("the seed person's default organisation is the grounding seed's employer, not a second one (walk #32)",
        'OSTLER_OWNER_SEED_CONTACT_ORG:-%s}' % SEED_ORG in open(new_lib).read())

    print("1. RED: the v1.0.108 seed lib")
    st = _store(); srv = _serve(st); port = srv.server_address[1]
    _run(old_lib, os.path.join(tmp, "old"), port, "owner_employer_seed_apply")
    arm("the seed person has no interaction", _count(st, "?p pwg:lastContactIMessage ?d") == 0)
    people, orgs = _digest(port, os.path.join(tmp, "old"))
    arm("RED: People has no seed person", SEED not in people, repr(people[:80]))
    arm("RED: Key organisations is empty", SEED_ORG not in orgs, repr(orgs[:80]))
    srv.shutdown()

    print("2. GREEN: this seed lib")
    st = _store(); srv = _serve(st); port = srv.server_address[1]
    home = os.path.join(tmp, "new")
    out = _run(new_lib, home, port, "owner_employer_seed_apply")
    arm("the importer ran for THIS account, log under its own HOME",
        "IMPORTER-RAN-FOR-THIS-ACCOUNT" in open(os.path.join(home, ".ostler", "walk-seed", "owner-seed.log")).read())
    arm("the walk log names the per-user log path", "walk-seed/owner-seed.log" in out, "")
    arm("one marked interaction in the graph", "OES interaction marked=1" in out, "")
    arm("the seed person carries an iMessage last-contact typed xsd:date (the ingest's shape)",
        _count(st, '?p pwg:displayName "%s" ; pwg:lastContactIMessage ?d . FILTER(DATATYPE(?d) = <http://www.w3.org/2001/XMLSchema#date>)' % SEED) == 1)
    arm("and an organisation", _count(st, '?p pwg:displayName "%s" ; pwg:organization "%s"' % (SEED, SEED_ORG)) == 1)
    _run(new_lib, home, port, "owner_employer_seed_apply")
    arm("idempotent: a second apply adds nothing", _count(st, "?p pwg:lastContactIMessage ?d") == 1 and _count(st, "?p pwg:organization ?o") == 1)
    people, orgs = _digest(port, home)
    arm("GREEN: People lists the seed person", SEED in people, repr(people[:120]))
    arm("GREEN: Key organisations lists its organisation", SEED_ORG in orgs, repr(orgs[:80]))
    out = _run(new_lib, home, port, 'OSTLER_OWNER_SEED_STATE=failed; owner_employer_seed_forget')
    arm("forget removes the interaction, the organisation and both markers",
        _count(st, "?p pwg:lastContactIMessage ?d") == 0 and _count(st, "?p pwg:organization ?o") == 0
        and _count(st, "?p pwg:walkSeedLastContact ?d") == 0 and _count(st, "?p pwg:walkSeedOrg ?o") == 0)
    arm("CONTROL: forget leaves the seed person itself", _count(st, '?p pwg:displayName "%s"' % SEED) == 1)
    srv.shutdown()

    print("3. nothing that was already there is touched")
    st = _store()
    p = ox.NamedNode(PWG + "person_walkfixture_seed")
    st.add(ox.Quad(p, ox.NamedNode(PWG + "organization"), ox.Literal("Globex Corp"), ox.DefaultGraph()))
    srv = _serve(st); port = srv.server_address[1]
    home = os.path.join(tmp, "pre")
    _run(new_lib, home, port, "owner_employer_seed_apply")
    arm("an existing organisation is kept, none added", _count(st, "?p pwg:organization ?o") == 1
        and _count(st, '?p pwg:organization "Globex Corp"') == 1)
    _run(new_lib, home, port, 'OSTLER_OWNER_SEED_STATE=failed; owner_employer_seed_forget')
    arm("the forget leaves the existing organisation", _count(st, '?p pwg:organization "Globex Corp"') == 1)
    srv.shutdown()

    print("4. not a synthetic seed person: nothing written")
    st = _store(); srv = _serve(st); port = srv.server_address[1]
    out = _run(new_lib, os.path.join(tmp, "real"), port, "owner_employer_seed_apply", synthetic=False)
    arm("no last-contact, no organisation", _count(st, "?p pwg:lastContactIMessage ?d") == 0 and _count(st, "?p pwg:organization ?o") == 0)
    arm("and it says why", "OES interaction skipped" in out, "")
    srv.shutdown()

    print("%d failed" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
