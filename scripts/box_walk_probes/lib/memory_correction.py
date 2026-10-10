#!/usr/bin/env python3
"""memory_correction_round_trip -- does a correction the owner makes reach
every surface that reads the fact? (v1.0.108 wow #9, iOS & Pin's design.)

THE SEVEN STEPS, run on the box against ical-server (:8090) with the
install's own service token:

  1. POST /api/v1/memory/assert two synthetic owner facts (A and B); poll
     each spool status until banked.
  2. GET /api/v1/memory: both present; note their ids.
     CONTROL: before any correction, each fact must be in ALL THREE readers:
     the memory list, /people/context?name=<owner>, and CONTEXT.md after a
     context refresh. A reader that never showed the fact cannot prove its
     absence later, so a failed control is CANNOT-RUN, never PASS.
  3. POST /api/v1/memory/correct/<A> {"forget": true}: ok.
  4. A absent from GET /api/v1/memory.
  5. A absent from /people/context?name=<owner>.
  6. A absent from CONTEXT.md after a context refresh.
  7. POST /api/v1/memory/correct/<B> {"newValue": X}: in each of the three
     readers X is shown and B's old value is nowhere.

Steps 5 and 6 are EXPECTED RED until the CM041 person_context overlay fix is
grafted: /people/context and the digest generator read the source triple and
never the corrections overlay. That red is a FAIL, not a CANNOT-RUN: the
control proved each reader could see the fact, so its presence after the
correction is a measured defect.

Every fact carries a per-run nonce token, and each reader is judged on its
WHOLE response text for that token, so a reader's shape cannot hide it. Only
booleans leave the box: no fact text, no owner name, no reader output.

The facts are written through the owner-facing endpoints (the same
ical-server routes the iOS Memory tab and the assistant call), then removed
from the graph at the end by fact URI.

Modes:
  box [--api URL] [--context PATH]   run the round trip on this machine, print facts JSON
  judge FACTS.json                   grade facts, print rows, exit 0/1/78
  --self-test                        drive the box half against a fake
                                     ical-server, good and mutant readers
"""
from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

READERS = ("memory", "context", "digest")
READER_NAME = {
    "memory": "the memory list (GET /api/v1/memory)",
    "context": "/people/context?name=<owner>",
    "digest": "CONTEXT.md after a context refresh",
}

DECLARED = (
    "owner: exactly one owner Person before the asserts",
    "owner: still exactly one owner Person after the asserts, and both facts attached to it",
    "control: fact A is in all three readers before any correction",
    "control: fact B is in all three readers before any correction",
    "step 3: forget via the owner path is accepted",
    "step 4: the forgotten fact is absent from the memory list",
    "step 5: the forgotten fact is absent from /people/context",
    "step 6: the forgotten fact is absent from CONTEXT.md",
    "step 7: correct via the owner path is accepted",
    "step 7: the memory list shows the correction and not the old value",
    "step 7: /people/context shows the correction and not the old value",
    "step 7: CONTEXT.md shows the correction and not the old value",
)


# ---------------------------------------------------------------------------
# judge: pure, over booleans
# ---------------------------------------------------------------------------

def judge(f):
    """Rows of (name, ok, detail). ok is True, False, or None (not measured)."""
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok, detail))

    if not f.get("write_allowed"):
        reason = "NOT MEASURED: this walk is read-only; the round trip writes and was not run"
        for d in DECLARED:
            add(d, None, reason)
        return out
    if f.get("setup_error"):
        reason = "NOT MEASURED: " + str(f["setup_error"])
        for d in DECLARED:
            add(d, None, reason)
        return out

    # THE OWNER IS ONE NODE, OR NO READER RESULT MEANS ANYTHING. /people/context
    # resolves by NAME (ical-server.py person_context(name) at :5299; the
    # route reads only ?name= at :10604-10606, so there is no id to pass). If
    # assert minted a second owner Person, that lookup can read the wrong node
    # and the control passes or fails by accident.
    owner = f.get("owner") or {}
    nb, na = owner.get("before"), owner.get("after")
    owner_ok = True
    if nb is None:
        add(DECLARED[0], None, "NOT MEASURED: the owner Person count could not be read")
        owner_ok = False
    else:
        add(DECLARED[0], nb == 1, "{} owner Person node(s) carry the owner's name".format(nb))
        owner_ok = owner_ok and nb == 1
    if na is None:
        add(DECLARED[1], None, "NOT MEASURED: the owner Person count after the asserts could not be read")
        owner_ok = False
    else:
        bad = []
        if na != 1:
            bad.append("{} owner Person node(s) after the asserts".format(na))
        if owner.get("minted"):
            bad.append("assert MINTED a new Person for the owner")
        if owner.get("attached_to_owner") is not True:
            bad.append("a fact is not attached to the owner node")
        add(DECLARED[1], not bad, "; ".join(bad) if bad else "one owner node, both facts on it")
        owner_ok = owner_ok and not bad

    before = f.get("before") or {}
    controls_ok = owner_ok
    for i, key in ((2, "A"), (3, "B")):
        seed = (f.get("seed") or {}).get(key) or {}
        rows = before.get(key) or {}
        if not seed.get("banked"):
            add(DECLARED[i], None, "NOT MEASURED: fact {} was never banked (assert {})".format(
                key, seed.get("status", "not attempted")))
            controls_ok = False
            continue
        unread = [r for r in READERS if rows.get(r) is None]
        missing = [r for r in READERS if rows.get(r) is False]
        if missing:
            add(DECLARED[i], None, "NOT MEASURED: control failed, {} did not show the seeded fact, "
                "so its absence later would prove nothing".format(
                    ", ".join(READER_NAME[r] for r in missing)))
            controls_ok = False
        elif unread:
            add(DECLARED[i], None, "NOT MEASURED: could not read " + ", ".join(READER_NAME[r] for r in unread))
            controls_ok = False
        else:
            add(DECLARED[i], True, "present in all 3 readers")

    if not controls_ok:
        reason = "NOT MEASURED: the owner or the control did not hold (see the rows above)"
        for d in DECLARED[4:]:
            add(d, None, reason)
        return _close(out)

    after = f.get("after") or {}

    # Forget (steps 3 to 6).
    if f.get("forget_ok") is True:
        add(DECLARED[4], True, "ok")
        a_old = after.get("A_old") or {}
        for name, r in zip(DECLARED[5:8], READERS):
            v = a_old.get(r)
            if v is None:
                add(name, None, "NOT MEASURED: could not read " + READER_NAME[r])
            else:
                add(name, v is False, "absent" if v is False else
                    "STILL PRESENT after the owner forgot it")
    else:
        add(DECLARED[4], False, "forget was refused or failed ({})".format(f.get("forget_detail", "no detail")))
        for d in DECLARED[5:8]:
            add(d, None, "NOT MEASURED: the forget was not accepted")

    # Correct (step 7).
    if f.get("correct_ok") is True:
        add(DECLARED[8], True, "ok")
        b_old = after.get("B_old") or {}
        b_new = after.get("B_new") or {}
        for name, r in zip(DECLARED[9:12], READERS):
            old, new = b_old.get(r), b_new.get(r)
            if old is None or new is None:
                add(name, None, "NOT MEASURED: could not read " + READER_NAME[r])
                continue
            bad = []
            if not new:
                bad.append("the correction is NOT shown")
            if old:
                bad.append("the OLD value is STILL shown")
            add(name, not bad, "; ".join(bad) if bad else "correction shown, old value gone")
    else:
        add(DECLARED[8], False, "correct was refused or failed ({})".format(f.get("correct_detail", "no detail")))
        for d in DECLARED[9:12]:
            add(d, None, "NOT MEASURED: the correction was not accepted")
    return _close(out)


def _close(out):
    names = [n for n, _, _ in out]
    missing = [d for d in DECLARED if d not in names]
    out.append(("memory correction: every declared assertion produced a row", not missing, ", ".join(missing)))
    return out


def report(rows):
    for name, ok, detail in rows:
        tag = "  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  ")
        print(tag + name + ("" if ok is True and not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} memory-correction assertions ({} failed, {} not measured)".format(
        len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


# ---------------------------------------------------------------------------
# box half
# ---------------------------------------------------------------------------

PWG_NS = "https://schema.ostler.ai/ontology#"


def _http(method, url, token, body=None, timeout=30):
    """(status, text). Loopback never goes through a proxy."""
    import urllib.error
    import urllib.request
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def _read_env(path):
    vals = {}
    try:
        for line in open(path):
            m = re.match(r'\s*(?:export\s+)?([A-Z_]+)=(.*)$', line)
            if m:
                v = m.group(2).strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                vals[m.group(1)] = v
    except IOError:
        pass
    return vals


class Box:
    """Everything the round trip touches, so the self-test can stand in."""

    def __init__(self, api, token, owner, context_path, refresh, cleanup, owner_nodes):
        self.api, self.token, self.owner = api.rstrip("/"), token, owner
        self.context_path, self.refresh, self.cleanup = context_path, refresh, cleanup
        # owner_nodes() -> list of Person URIs carrying the owner's name, or None
        self.owner_nodes = owner_nodes

    def assert_fact(self, text, deadline_s=180):
        st, body = _http("POST", self.api + "/api/v1/memory/assert", self.token,
                         {"subject": self.owner, "fact_text": text, "asserted_via": "walk-probe"})
        try:
            j = json.loads(body)
        except ValueError:
            return {"banked": False, "status": "HTTP {} non-JSON".format(st)}
        status = j.get("status", "HTTP {}".format(st))
        if status in ("stored", "created_person"):
            return {"banked": True, "status": status, "fact_id": j.get("fact_id"),
                    "person_uri": j.get("person_uri"), "created_person": status == "created_person"}
        if status == "accepted_pending" and j.get("status_url"):
            end = time.time() + deadline_s
            while time.time() < end:
                time.sleep(3)
                _, pb = _http("GET", self.api + j["status_url"], self.token)
                try:
                    p = json.loads(pb)
                except ValueError:
                    continue
                if p.get("state") == "done":
                    return {"banked": True, "status": "accepted_pending->done",
                            "fact_id": p.get("fact_id") or j.get("fact_id"),
                            "person_uri": p.get("person_uri"),
                            "created_person": bool(p.get("created_person"))}
                if p.get("state") not in (None, "pending"):
                    return {"banked": False, "status": "spool " + str(p.get("state"))}
            return {"banked": False, "status": "spool still pending after {}s".format(deadline_s)}
        return {"banked": False, "status": status}

    def readers(self):
        """{reader: text or None}. None means the reader could not be read."""
        out = {}
        st, body = _http("GET", self.api + "/api/v1/memory", self.token)
        out["memory"] = body if st == 200 else None
        import urllib.parse
        st, body = _http("GET", self.api + "/api/v1/people/context?name=" +
                         urllib.parse.quote(self.owner), self.token)
        out["context"] = body if st == 200 else None
        try:
            out["digest"] = open(self.context_path).read()
        except IOError:
            out["digest"] = None
        return out

    def correct(self, fact_id, body):
        st, text = _http("POST", self.api + "/api/v1/memory/correct/" + fact_id, self.token, body)
        try:
            j = json.loads(text)
        except ValueError:
            j = {}
        return (st == 200 and j.get("ok") is True), "HTTP {} ok={}".format(st, j.get("ok"))


def _present(texts, token):
    return {r: (None if texts.get(r) is None else (token in texts[r])) for r in READERS}


def round_trip(box, write_allowed=True, nonce=None):
    """Run the seven steps. Returns booleans only."""
    f = {"write_allowed": bool(write_allowed)}
    if not write_allowed:
        return f
    if not box.owner:
        f["setup_error"] = "the owner's name is not configured on this box (USER_NAME in ~/.ostler/config/.env)"
        return f
    nonce = nonce or secrets.token_hex(4)
    tok = {"A": "mcrt-a-" + nonce, "B": "mcrt-b-" + nonce, "X": "mcrt-x-" + nonce}
    text = {
        "A": "Walk probe synthetic fact: the owner's spare bicycle is painted " + tok["A"],
        "B": "Walk probe synthetic fact: the owner's study lamp is " + tok["B"],
        "X": "Walk probe synthetic fact, corrected: the owner's study lamp is " + tok["X"],
    }
    seeds = {}
    try:
        owners_before = box.owner_nodes()
        f["owner"] = {"before": None if owners_before is None else len(owners_before)}
        f["seed"] = {}
        for k in ("A", "B"):
            seeds[k] = box.assert_fact(text[k])
            f["seed"][k] = {"banked": seeds[k].get("banked", False), "status": seeds[k].get("status"),
                            "created_person": seeds[k].get("created_person")}
        owners_after = box.owner_nodes()
        f["owner"]["after"] = None if owners_after is None else len(owners_after)
        f["owner"]["minted"] = any(seeds[k].get("created_person") for k in ("A", "B"))
        f["owner"]["attached_to_owner"] = (
            None if owners_before is None else
            all(seeds[k].get("person_uri") in owners_before for k in ("A", "B")))
        if not all(seeds[k].get("banked") and seeds[k].get("fact_id") for k in ("A", "B")):
            return f
        f["refresh_before"] = box.refresh()
        texts = box.readers()
        f["before"] = {k: _present(texts, tok[k]) for k in ("A", "B")}
        if not f["refresh_before"]:
            f["before"] = {k: dict(v, digest=None) for k, v in f["before"].items()}
        if any(v is not True for k in ("A", "B") for v in f["before"][k].values()):
            return f

        f["forget_ok"], f["forget_detail"] = box.correct(seeds["A"]["fact_id"], {"forget": True})
        f["correct_ok"], f["correct_detail"] = box.correct(seeds["B"]["fact_id"], {"newValue": text["X"]})
        f["refresh_after"] = box.refresh()
        texts = box.readers()
        if not f["refresh_after"]:
            texts["digest"] = None
        f["after"] = {"A_old": _present(texts, tok["A"]), "B_old": _present(texts, tok["B"]),
                      "B_new": _present(texts, tok["X"])}
        return f
    finally:
        try:
            f["cleanup"] = box.cleanup([s for s in seeds.values() if s.get("banked")])
        except Exception as exc:  # cleanup never changes a verdict
            f["cleanup"] = "failed: " + type(exc).__name__


def _box_refresh(context_path, timeout_s=600):
    """Re-run the context-refresh LaunchAgent and wait for CONTEXT.md to be rewritten."""
    try:
        before = os.stat(context_path).st_mtime
    except OSError:
        before = 0
    subprocess.run(["launchctl", "kickstart", "-k",
                    "gui/{}/com.creativemachines.ostler.context-refresh".format(os.getuid())],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.time() + timeout_s
    while time.time() < end:
        time.sleep(5)
        try:
            if os.stat(context_path).st_mtime > before:
                return True
        except OSError:
            pass
    return False


def _store_headers():
    hdrs = {}
    try:
        for line in open(os.path.expanduser("~/.ostler/secrets/store-curl.conf")):
            m = re.match(r'\s*header\s*=\s*"?([^:"]+):\s*([^"]*)"?\s*$', line)
            if m:
                hdrs[m.group(1).strip()] = m.group(2).strip()
    except IOError:
        pass
    return hdrs


def _box_owner_nodes(owner):
    """Person URIs whose displayName is the owner's name (case-insensitive),
    or None when the store could not be read. URIs stay on the box."""
    import urllib.parse
    import urllib.request
    esc = owner.lower().replace("\\", "\\\\").replace('"', '\\"')
    q = ('PREFIX pwg: <%s>\nSELECT DISTINCT ?p WHERE { ?p a pwg:Person ; pwg:displayName ?n . '
         'FILTER(LCASE(STR(?n)) = "%s") }' % (PWG_NS, esc))
    oxi = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878/query")
    h = _store_headers()
    h.update({"Content-Type": "application/sparql-query", "Accept": "application/sparql-results+json"})
    req = urllib.request.Request(oxi, data=q.encode(), headers=h)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=20) as r:
            rows = json.loads(r.read().decode())["results"]["bindings"]
    except Exception:
        return None
    return [b["p"]["value"] for b in rows if "p" in b]


def _box_cleanup(seeds):
    """Delete the synthetic facts from the graph by URI; a person node only if
    this run minted it. Returns a count, never text."""
    conf = os.path.expanduser("~/.ostler/secrets/store-curl.conf")
    oxi = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878/query")
    uris = [PWG_NS + s["fact_id"] for s in seeds if s.get("fact_id")]
    uris += [s["person_uri"] for s in seeds if s.get("created_person") and s.get("person_uri")]
    uris = [u for u in uris if re.fullmatch(r"https://schema\.ostler\.ai/ontology#[A-Za-z0-9_\-]+", u)]
    if not uris:
        return 0
    update = "DELETE WHERE { VALUES ?s { %s } ?s ?p ?o }" % " ".join("<%s>" % u for u in uris)
    rc = subprocess.run(["/usr/bin/curl", "-sS", "--noproxy", "*", "-m", "30", "-K", conf,
                         "-H", "Content-Type: application/sparql-update", "--data-binary", update,
                         oxi.rsplit("/query", 1)[0] + "/update"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    subprocess.run(["launchctl", "kickstart", "-k",
                    "gui/{}/com.creativemachines.ostler.context-refresh".format(os.getuid())],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "deleted {} node(s), rc={}".format(len(uris), rc)


def box_main(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    home = os.path.expanduser("~/.ostler")
    env = _read_env(os.path.join(home, "config", ".env"))
    env.update({k: v for k, v in _read_env(os.path.join(home, ".env")).items() if k not in env})
    owner = env.get("USER_NAME") or env.get("WIKI_OPERATOR_NAME") or ""
    try:
        token = open(os.path.join(home, "secrets", "service_token")).read().strip()
    except IOError:
        token = ""
    context = a.get("--context", os.path.join(home, "assistant-config", "workspace", "CONTEXT.md"))
    write_allowed = a.get("--write-allowed", "0") == "1"
    if write_allowed and not token:
        print(json.dumps({"write_allowed": True, "setup_error": "no service token at ~/.ostler/secrets/service_token"}))
        return 0
    box = Box(a.get("--api", "http://127.0.0.1:8090"), token, owner, context,
              lambda: _box_refresh(context), _box_cleanup, lambda: _box_owner_nodes(owner))
    print(json.dumps(round_trip(box, write_allowed)))
    return 0


# ---------------------------------------------------------------------------
# self-test: the box half against a fake ical-server
# ---------------------------------------------------------------------------

def _fake_server(ignore_corrections_in=(), keep_old_in=(), drop_new_in=(), mint_duplicate=False):
    """A stand-in for ical-server with the real wire shapes. Readers named in
    ignore_corrections_in read the source facts and never the overlay: the
    mutant, and also the shape /people/context and the digest have today."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    state = {"facts": {}, "corr": {}, "n": 0, "owners": [PWG_NS + "user_jane"]}

    def view(reader):
        rows = []
        for fid, text in state["facts"].items():
            c = state["corr"].get(fid)
            if c and reader not in ignore_corrections_in:
                if c.get("forget"):
                    continue
                if c.get("newValue") and reader in drop_new_in:
                    continue  # treats a correction as a deletion
                if c.get("newValue") and reader in keep_old_in:
                    rows.append((fid, text))  # shows the correction AND the original
                text = c.get("newValue") or text
            rows.append((fid, text))
        return rows

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.headers.get("Authorization") != "Bearer synthetic-service-token":
                return self._send(401, {"error": "unauthorized"})
            if self.path == "/api/v1/memory":
                return self._send(200, {"facts": [{"id": i, "object": t} for i, t in view("memory")]})
            if self.path.startswith("/api/v1/people/context?name="):
                return self._send(200, {"found": True, "results": [{"name": "Jane Doe",
                                  "facts": [t for _, t in view("context")]}]})
            return self._send(404, {})

        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer synthetic-service-token":
                return self._send(401, {"error": "unauthorized"})
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            if self.path == "/api/v1/memory/assert":
                state["n"] += 1
                fid = "fact_%012d" % state["n"]
                state["facts"][fid] = body["fact_text"]
                if mint_duplicate:
                    # The defect this guards: no confident match, so assert
                    # mints a SECOND Person carrying the owner's name.
                    dup = PWG_NS + "person_dup%d" % state["n"]
                    state["owners"].append(dup)
                    return self._send(200, {"status": "created_person", "fact_id": fid,
                                            "person_uri": dup})
                return self._send(200, {"status": "stored", "fact_id": fid,
                                        "person_uri": PWG_NS + "user_jane"})
            if self.path.startswith("/api/v1/memory/correct/"):
                fid = self.path.rsplit("/", 1)[1]
                if fid not in state["facts"]:
                    return self._send(404, {"ok": False})
                state["corr"][fid] = body
                return self._send(200, {"ok": True, "id": fid,
                                        "action": "forget" if body.get("forget") else "correct"})
            return self._send(404, {})

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, state, view


def _run_fake(ignore=(), keep_old=(), drop_new=(), mint_duplicate=False, owners_readable=True, digest_refreshes=True, correct_ok=True, readonly=False, owner="Jane Doe"):
    import tempfile
    srv, state, view = _fake_server(ignore, keep_old, drop_new, mint_duplicate)
    d = tempfile.mkdtemp()
    ctx = os.path.join(d, "CONTEXT.md")

    def refresh():
        if digest_refreshes:
            with open(ctx, "w") as fh:
                fh.write("# Personal Context\n\n## Confirmed by you\n\n" +
                         "".join("- %s\n" % t for _, t in view("digest")))
        return digest_refreshes

    box = Box("http://127.0.0.1:%d" % srv.server_address[1], "synthetic-service-token",
              owner, ctx, refresh, lambda seeds: "fake cleanup of {}".format(len(seeds)),
              lambda: list(state["owners"]) if owners_readable else None)
    if not correct_ok:
        box.correct = lambda fid, body: (False, "HTTP 503 ok=None")
    try:
        return round_trip(box, write_allowed=not readonly, nonce="5e1f7e57")
    finally:
        srv.shutdown()


def self_test():
    fails = []

    def expect(label, facts, want_rc, want_row=None, want_unmeasured=None):
        rows = judge(facts)
        rc = EX_FAIL if any(ok is False for _, ok, _ in rows) else (
            EX_CANNOT if any(ok is None for _, ok, _ in rows) else EX_PASS)
        bad = rc != want_rc
        if want_row is not None:
            hit = [ok for n, ok, _ in rows if n == want_row]
            bad = bad or hit != [False]
        if want_unmeasured is not None:
            hit = [ok for n, ok, _ in rows if n == want_unmeasured]
            bad = bad or hit != [None]
        print(("  ok    " if not bad else "  FAIL  ") + label)
        if bad:
            fails.append(label)
        if leaked(facts):
            print("  FAIL  facts leave the box carrying text: " + label)
            fails.append("leak: " + label)

    def leaked(facts):
        s = json.dumps(facts)
        return "Walk probe synthetic fact" in s or "Jane Doe" in s

    good = _run_fake()
    expect("good: every reader honours the correction, PASS", good, EX_PASS)
    expect("MUTANT: /people/context ignores corrections, FAIL on step 5",
           _run_fake(ignore=("context",)), EX_FAIL, DECLARED[6])
    expect("MUTANT: CONTEXT.md ignores corrections, FAIL on step 6",
           _run_fake(ignore=("digest",)), EX_FAIL, DECLARED[7])
    expect("MUTANT: the memory list ignores corrections, FAIL on step 4",
           _run_fake(ignore=("memory",)), EX_FAIL, DECLARED[5])
    expect("MUTANT: every reader ignores corrections, FAIL on step 7 (memory list)",
           _run_fake(ignore=READERS), EX_FAIL, DECLARED[9])
    expect("today's shape (context and digest ignore the overlay) is FAIL, not CANNOT-RUN",
           _run_fake(ignore=("context", "digest")), EX_FAIL, DECLARED[11])
    expect("MUTANT: /people/context shows the correction but keeps the old value, FAIL on step 7",
           _run_fake(keep_old=("context",)), EX_FAIL, DECLARED[10])
    expect("MUTANT: the memory list drops a corrected fact instead of showing it, FAIL on step 7",
           _run_fake(drop_new=("memory",)), EX_FAIL, DECLARED[9])
    expect("the owner path refuses the correction: FAIL",
           _run_fake(correct_ok=False), EX_FAIL, DECLARED[8])
    expect("MUTANT: assert mints a SECOND owner Person, FAIL on the owner row, later steps unmeasured",
           _run_fake(mint_duplicate=True), EX_FAIL, DECLARED[1], want_unmeasured=DECLARED[4])
    for label, change in (("assert reports it minted a Person", {"minted": True}),
                          ("a second owner node appears", {"after": 2}),
                          ("a fact attached to a node that is not the owner", {"attached_to_owner": False})):
        one = json.loads(json.dumps(good))
        one["owner"].update(change)
        expect("owner row alone: " + label + " FAILS", one, EX_FAIL, DECLARED[1])
    expect("the owner count cannot be read: CANNOT-RUN, never PASS",
           _run_fake(owners_readable=False), EX_CANNOT, want_unmeasured=DECLARED[0])
    two = json.loads(json.dumps(good))
    two["owner"]["before"] = 2
    expect("a box whose owner is already two nodes FAILS the owner row", two, EX_FAIL, DECLARED[0])
    expect("CONTROL: the digest never refreshes, so absence proves nothing: CANNOT-RUN",
           _run_fake(digest_refreshes=False), EX_CANNOT)
    expect("a read-only walk is CANNOT-RUN, never PASS", _run_fake(readonly=True), EX_CANNOT)
    expect("no owner name on the box is CANNOT-RUN", _run_fake(owner=""), EX_CANNOT)
    expect("an empty fact set is not a PASS", {}, EX_CANNOT)

    # A reader that never showed the fact must not let absence read as a pass.
    blind = json.loads(json.dumps(good))
    blind["before"]["A"]["context"] = False
    expect("CONTROL: a reader blind before the correction is CANNOT-RUN, not PASS", blind, EX_CANNOT,
           want_unmeasured=DECLARED[2])

    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: the good box passes, every mutant reader that ignores a correction FAILS "
          "by its own row, and every blind control is CANNOT-RUN")
    return EX_PASS


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
