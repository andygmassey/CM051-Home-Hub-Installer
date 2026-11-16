#!/usr/bin/env python3
"""meeting_brief_text_is_grounded must REFUSE (CANNOT-RUN) before it seeds when a
NON-fixture pwg:Person already folds, under the box's own installed _wiki_slug,
to a fixture slug (philip-coe, catherine-stewart, alexandra-patel).

Why: the Hub resolves a person by slug, so a second fixture-named person (the old scale
fixture neighbour was exactly that) makes the fixture question be answered with
the wrong person, or 409s the slug timeline. A harness fault is CANNOT-RUN.

Real components, no mocks of the boundary under test: the vendored ical-server
_wiki_slug (pulled out by ast, as on the box), a real SPARQL engine (pyoxigraph)
behind a loopback HTTP store that demands the bearer credential like the :7878
proxy, and the real box() driver run with a sandboxed HOME.

Arms
  1 RED    a synthetic non-fixture node folding to philip-coe -> box() prints
           CANNOT, the store saw ZERO writes, the snapshot is printed
  2 RED    the old scale-fixture neighbour shape (its URI, same displayName as the fixture)
  3 GREEN  node removed -> the guard is silent and box() reaches the seed write
  4 control a fixture-URI node folding to the same slug is NOT a collision
  5 control the fold cannot be loaded / fails its control -> CANNOT, not "clean"
  6 control the store refuses the credential -> CANNOT, not "no collisions"
  7 privacy no literal (name included) and no non-fixture URI is printed raw
  8 judge   the judge prints the CANNOT line and the SNAPSHOT lines, exit 78

Exit 0 pass, 1 fail, 2 CANNOT-RUN (pyoxigraph missing).
"""
import contextlib
import io
import json
import os
import pathlib
import stat
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts/box_walk_probes/lib"
sys.path.insert(0, str(LIB))
try:
    import pyoxigraph as ox
except Exception as exc:  # pragma: no cover
    print("CANNOT-RUN pyoxigraph not installed: %s" % exc)
    sys.exit(2)
import meeting_brief_sent_text as mbt  # noqa: E402
import scale_fixture  # noqa: E402
import meeting_brief_seed as seed  # noqa: E402

_FIRST, _LAST = seed.NONE["name"].split()

for k in [k for k in os.environ if "proxy" in k.lower()]:
    os.environ.pop(k)

ICAL = str(ROOT / "vendor/cm041/assistant_api/ical-server.py")
TOKEN = "fixture-store-token"
PWG = "https://schema.ostler.ai/ontology#"
FAILS = []


def check(ok, label):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        FAILS.append(label)


class Store:
    def __init__(self):
        self.g = ox.Store()
        self.updates = 0
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                if (self.headers.get("Authorization") or "") != "Bearer " + TOKEN:
                    self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
                    return
                if self.path == "/update":
                    outer.updates += 1
                    outer.g.update(body.decode())
                    self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()
                    return
                q = urllib.parse.parse_qs(body.decode())["query"][0]
                res = outer.g.query(q, use_default_graph_as_union=True)
                vs = [v.value for v in res.variables]
                rows = [{v: ({"type": "uri" if t.__class__.__name__ == "NamedNode" else "literal", "value": t.value})
                         for v, t in zip(vs, sol) if t is not None} for sol in res]
                out = json.dumps({"head": {"vars": vs}, "results": {"bindings": rows}}).encode()
                self.send_response(200); self.send_header("Content-Type", "application/sparql-results+json")
                self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]


def hub_shim():
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            out = json.dumps({"found": False}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


def add_person(store, uri, name, graph=None):
    t = "<%s> a <%sPerson> ; <%sdisplayName> \"%s\" ; <%sprivacyLevel> \"L1\" ; <%smergedInto> <urn:example:other> ." % (uri, PWG, PWG, name, PWG, PWG)
    store.g.update("INSERT DATA { %s }" % (("GRAPH <%s> { %s }" % (graph, t)) if graph else t))


def run_box(home, store_url, hub_url, ical=ICAL, token=TOKEN):
    sec = pathlib.Path(home) / ".ostler/secrets"
    sec.mkdir(parents=True, exist_ok=True)
    if token:
        (sec / "oxigraph_token").write_text(token)
    (sec / "service_token").write_text("svc")
    sender = pathlib.Path(home) / ".ostler/bin/ostler-meeting-brief-sender"
    sender.parent.mkdir(parents=True, exist_ok=True)
    sender.write_text("#!/bin/sh\nexit 0\n")
    comp = pathlib.Path(home) / "composer"
    comp.write_text("#!/bin/sh\nexit 0\n")
    comp.chmod(comp.stat().st_mode | stat.S_IXUSR)
    env = {"HOME": home, "OSTLER_SECRETS_DIR": str(sec), "OSTLER_BRIEF_COMPOSER": str(comp),
           "OSTLER_HUB_HOST": hub_url, "OSTLER_OXIGRAPH_URL": store_url + "/query",
           "OSTLER_ICAL_SERVER": ical}
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    os.environ.pop("OXIGRAPH_TOKEN", None)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            mbt.box()
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return json.loads(buf.getvalue().strip().splitlines()[-1])


def main():
    os.environ["OSTLER_SECRETS_DIR"] = tempfile.mkdtemp()
    store = Store()
    hub, hub_url = hub_shim()
    home = tempfile.mkdtemp()

    # control: the fold is the product's and is live
    fold = mbt.load_box_wiki_slug(ICAL)
    check(fold(_FIRST + " " + _LAST[:-1] + "\u00e9") == "philip-coe" and fold(_FIRST + "a " + _LAST) != "philip-coe", "control: the installed fold folds an accented variant and not a different name")

    # 1 RED: synthetic non-fixture node
    add_person(store, "urn:example:synthetic-collider", _FIRST + "  " + _LAST[:-1] + "\u00e9")
    r = run_box(home, store.base, hub_url)
    msg = r.get("cannot", "")
    snap = r.get("slug_collision_snapshot") or []
    print("RED  (synthetic node) -> CANNOT: " + msg)
    check("fold to a fixture slug" in msg and store.updates == 0, "1 RED: a non-fixture node folding to philip-coe -> CANNOT-RUN and ZERO store writes (writes=%d)" % store.updates)
    check(len(snap) == 1 and snap[0]["rdf_types"] == ["Person"] and snap[0]["fold_of_each_displayName"] == ["philip-coe"], "1 RED: the snapshot names the node's rdf:type and its fold")
    check(snap and snap[0]["mergedInto"] and snap[0]["uri"].startswith("h:") and "default" in snap[0]["graphs"], "1 RED: snapshot carries mergedInto, graph, and a HASHED uri")
    raw = json.dumps(snap)
    check("Coé" not in raw and "synthetic-collider" not in raw and "urn:example" not in raw, "7 privacy: no raw name and no raw non-fixture URI in the snapshot")

    # 2 RED: the old neighbour shape (named graph, its URI, same displayName as the fixture)
    store.g.clear()
    add_person(store, scale_fixture.NEIGHBOUR_URI, seed.NONE["name"], graph="urn:ostler:user/fixtureowner")
    r = run_box(home, store.base, hub_url)
    print("RED  (old neighbour shape) -> CANNOT: " + r.get("cannot", ""))
    check("fold to a fixture slug" in r.get("cannot", "") and store.updates == 0, "2 RED: the old scale-fixture neighbour (its URI, same displayName as the fixture) -> CANNOT-RUN, zero writes")
    check(any("h:" in g for g in (r.get("slug_collision_snapshot") or [{}])[0].get("graphs", [])), "2 RED: a node held only in a named graph is found and its graph is hashed")

    # new neighbour name must not collide
    check(fold(scale_fixture.NEIGHBOUR_NOTE.split(" is based")[0]) not in ("philip-coe", "alexandra-patel", "catherine-stewart"), "the renamed neighbour folds to no fixture slug")

    # 4 control: a fixture-URI node with the same slug is not a collision
    store.g.clear()
    add_person(store, "urn:ostler-walk-fixture:philip", seed.NONE["name"])
    r = run_box(home, store.base, hub_url)
    check("fold to a fixture slug" not in r.get("cannot", ""), "4 control: a fixture-URI node folding to philip-coe is not a collision")

    # 3 GREEN: nothing colliding -> proceeds to the seed write
    store.g.clear()
    before = store.updates
    r = run_box(home, store.base, hub_url)
    print("GREEN (no colliding node) -> proceeded: cannot=%r, store writes=%d" % (r.get("cannot"), store.updates - before))
    check("fold to a fixture slug" not in r.get("cannot", "") and store.updates > before, "3 GREEN: node removed -> the probe proceeds past the guard and seeds (writes=%d)" % (store.updates - before))

    # 5 control: fold unloadable / failing its control
    bad = pathlib.Path(tempfile.mkdtemp()) / "ical-server.py"
    bad.write_text("def _wiki_slug(name):\n    return 'x'\n")
    msg, _ = mbt.slug_collision_guard(store.base + "/query", ical_path=str(bad))
    check(msg and "could not load" in msg, "5 control: a fold that fails its control -> CANNOT, not clean")
    msg, _ = mbt.slug_collision_guard(store.base + "/query", ical_path=str(bad.parent / "missing.py"))
    check(msg and "could not load" in msg, "5 control: no installed ical-server -> CANNOT, not clean")

    # 6 control: store refuses the credential
    r = run_box(home, store.base, hub_url, token="wrong")
    check("fold to a fixture slug" not in r.get("cannot", "") and r.get("cannot"), "6 control: wrong store credential -> CANNOT (%s)" % (r.get("cannot", "")[:60]))

    # 8 judge prints CANNOT + SNAPSHOT lines, exit 78
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = mbt.report({"cannot": "x", "slug_collision_snapshot": [{"uri": "h:abc"}]})
    check(rc == 78 and "  CANNOT x" in buf.getvalue() and '  SNAPSHOT {"uri": "h:abc"}' in buf.getvalue(), "8 judge: CANNOT line + SNAPSHOT line, exit 78")

    print("FAIL %d" % len(FAILS) if FAILS else "all checks passed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
