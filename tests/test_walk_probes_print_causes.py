#!/usr/bin/env python3
"""The people and screens probes must print CAUSES, not just counts (instr119).

v1.0.118 walk 3 failed no_person_holds_two_contact_cards, people_stores_reconcile,
people_count_agreement and hub_screens_customer_read, and every cause was NOT
INSTRUMENTED: the walk printed how many, never why. This drives the REAL probes,
end to end, against synthetic stores served on 127.0.0.1, and asserts each new
cause line is printed, masked, and that every probe's exit code is unchanged.

HOW IT REACHES "THE BOX". The probes run with OSTLER_BOX_HOST set and an `ssh`
stub first on PATH that runs the remote command locally with `bash -c` (no
login shell, so PATH keeps the `launchctl` stub too). The stub launchctl
answers `print` as macOS does for an absent job (exit 113, "Could not find
service") and REFUSES `kickstart`, recording it, so no real job on this Mac can
be started. HOME is a temp dir. Every value is synthetic: reserved
+44 7700 900xxx numbers and example.com addresses.

ON origin/main every cause assertion below FAILS (the lines do not exist) while
the exit-code assertions PASS: that is the red/green pair.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PROBES = os.environ.get("INSTR119_PROBES_DIR") or os.path.join(REPO, "scripts", "box_walk_probes")
ONT = "https://schema.ostler.ai/ontology#"

PASS = 0
FAIL = 0
FIRSTBAD = ""


def ok(msg):
    global PASS
    PASS += 1
    print("  [PASS] %s" % msg)


def bad(msg):
    global FAIL, FIRSTBAD
    FAIL += 1
    if not FIRSTBAD:
        FIRSTBAD = msg
    print("  [FAIL] %s" % msg)


def check(cond, msg, detail=""):
    if cond:
        ok(msg)
    else:
        bad(msg + ((" -- " + detail) if detail else ""))


def cannot(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


def bindings(rows):
    return {"head": {"vars": []}, "results": {"bindings": [
        {k: {"type": "literal", "value": str(v)} for k, v in r.items()} for r in rows]}}


# --------------------------------------------------------------------------
# Synthetic stores. Every request is counted: a stub nobody called proves nothing.
# --------------------------------------------------------------------------
P = "https://example.invalid/person_"
IDX_AT = "2026-10-26T06:00:00Z"


def sparql_answer(q):
    # no_person_holds_two_contact_cards
    if "AS ?side" in q:
        if "<%sa>" % P in q:
            return [{"side": "self", "t": "phone", "v": "+44 7700 900111"},
                    {"side": "self", "t": "name", "v": "Jane Doe"},
                    {"side": P + "a2", "t": "phone", "v": "07700 900111"},
                    {"side": P + "a2", "t": "name", "v": "John Doe"}]
        return [{"side": "self", "t": "email", "v": "one@example.com"},
                {"side": "self", "t": "email", "v": "two@example.com"}]
    cf = CARDS_FIXTURE[0]
    # v1.0.121: the probe re-checks a journalled override IN THE GRAPH. These
    # answer its identifier, holder and live-Person reads: both cards' email
    # identifiers (same value) now sit on the survivor x, the only live node.
    if "?jid ?jt ?jv" in q:
        return [] if cf == "default" else [{"jid": P + "idx_e", "jt": "email", "jv": "one@example.com"},
                                           {"jid": P + "idx2_e", "jt": "email", "jv": "one@example.com"}]
    if "?jh ?jhid" in q:
        return [] if cf == "default" else [{"jh": P + "x", "jhid": P + "idx_e"}, {"jh": P + "x", "jhid": P + "idx2_e"}]
    if "?jlive WHERE" in q:
        return [] if cf == "default" else [{"jlive": P + "x"}]
    if "?jfrom ?jto" in q:
        return [] if cf == "default" else [{"jfrom": P + "x2", "jto": P + "x"}]
    if "?jname_s ?jname" in q:
        if cf == "default":
            return []
        return [{"jname_s": P + "x", "jname": "John Doe"},
                {"jname_s": P + "x2", "jname": "Jane Doe" if cf == "namemismatch" else "John Doe"}]
    if "GROUP BY ?person" in q:
        if cf == "clean":
            return []
        if cf != "default":
            return [{"person": P + "x", "uids": 2}]
        return [{"person": P + "a", "uids": 2}, {"person": P + "b", "uids": 3},
                {"person": P + "c", "uids": 2}, {"person": P + "d", "uids": 2}]
    if "COUNT(DISTINCT ?i) AS ?n" in q:
        return [{"n": 6}]
    if "AS ?uidn" in q:
        return [{"uidn": UIDS[0]}]
    if "HAVING (COUNT(DISTINCT ?h) > 1)" in q:
        return [{"n": OPP[0]}]
    if "?src p:mergedInto ?s ; p:displayName ?m" in q:
        return [{"n": 0}]
    if "?src p:mergedInto ?s }" in q:
        return [{"n": 5}]
    # people_count_agreement (fixture chosen by COUNT_FIXTURE)
    fx = COUNT_FIXTURES[COUNT_FIXTURE[0]]
    if "?unnamed" in q:
        return [{"named": len(fx["oxi_named"]), "unnamed": fx["stubs"], "merged": 0}]
    if "foaf" in q:
        return [{"n": len(fx["oxi_named"]) + fx["stubs"]}]
    if "?gn ?fn ?t ?v" in q:
        rows = [{"p": P + "n%d" % i, "dn": dn} for i, dn in enumerate(fx["oxi_named"])]
        rows += [{"p": P + "s%d" % i, "t": "phone", "v": "+44 7700 9004%02d" % i} for i in range(fx["stubs"])]
        return rows
    # people_stores_reconcile payload
    if q.strip() == "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }":
        return [{"n": 1000}]
    if q.startswith("SELECT ?p WHERE { ?p a <" + ONT + "Person> }"):
        return [{"p": P + str(i)} for i in range(1, 6)]
    if "FILTER NOT EXISTS { ?o a" in q:
        return [{"n": 0}]
    for i in range(1, 6):
        u = "<%s%d>" % (P, i)
        if u not in q:
            continue
        if "prefLabel" in q:
            return [{"l": "jane doe"}] if i == 4 else []
        if "displayName" in q:
            return [] if i == 4 else [{"d": "John Doe"}]
        if "mergedInto" in q:
            return [{"m": P + "1"}] if i == 5 else []
        if "createdAt" in q:
            return {2: [{"c": "2026-10-27T01:00:00Z"}], 3: [{"c": "2026-01-01T00:00:00Z"}]}.get(i, [])
        return []
    return []


# people_count_agreement fixtures. Names are the approved cast; a WhatsApp JID
# is a shape the locked predicate hides on BOTH sides.
JID = "447700900123@s.whatsapp.net"
COUNT_FIXTURES = {
    # 13 unnamed stubs (join anchors) beside 20 named on both sides -> PASS
    "stubs": {"oxi_named": ["John Doe"] * 20, "stubs": 13, "qd_named": ["John Doe"] * 20},
    # named counts genuinely differ -> FAIL
    "short": {"oxi_named": ["John Doe"] * 20, "stubs": 13, "qd_named": ["John Doe"] * 17},
    # two JIDs on both sides: equal only when BOTH sides apply the predicate
    "jids": {"oxi_named": ["John Doe"] * 20 + [JID, JID], "stubs": 0, "qd_named": ["John Doe"] * 20 + [JID, JID]},
}
COUNT_FIXTURE = ["stubs"]
CARDS_FIXTURE = ["default"]
# What the fake Oxigraph answers to the probe's distinct-uid and collision-opportunity
# queries. A non-number is how a broken query looks to _sparql_scalar.
UIDS = [6]
OPP = [3]

# Merge-journal rows in the CM051 #3217 schema. The hash is an HMAC keyed by
# the install's service_token, so it is only ever checked for SHAPE; this value
# is arbitrary and is never compared with anything.
SHAPE_HASH = "0f1e2d3c4b5a6978"


def jrow(keys, reason="", override="exact_identifier:email", rid="20261029T010203Z-0a0b0c0d"):
    return {"kind": "merge", "id": rid, "ts": "2026-10-29T01:02:03Z", "keep": P + "x", "discard": P + "x2",
            "strategy": "email_match", "confidence": 1.0, "details": "identifier values withheld from the journal",
            "override": override, "shared_kinds": sorted({k["kind"] for k in keys}), "matched_keys": keys,
            "matched_keys_reason": reason, "snapshot": "merge_snapshots/x.json", "qdrant_status": "ok", "qdrant_points": 1}


_KEYED = [{"kind": "email", "hash": SHAPE_HASH}]
# The merge snapshot record_merge writes: which identifier node each card held.
SNAPSHOT = {"keep": P + "x", "discard": P + "x2", "nodes": {
    P + "x": {"subj": [[ONT + "hasIdentifier", ["uri", P + "idx_e", ""]]], "obj": []},
    P + "x2": {"subj": [[ONT + "hasIdentifier", ["uri", P + "idx2_e", ""]]], "obj": []}}}
JOURNAL_CASES = {
    # case: (journal rows, or "ABSENT" / "DIR", expected exit, label)
    "pass": ([jrow(_KEYED)], 0, "journalled override with a key hash and identical names PASSES"),
    "norow": ("ABSENT", 1, "no journal row for the extra card FAILS"),
    "nokey": ([jrow([])], 1, "an override row with no key FAILS"),
    "oldrow": ([{k: v for k, v in jrow(_KEYED).items() if k not in ("matched_keys", "shared_kinds", "matched_keys_reason")}], 1,
               "a row written before keys were journalled FAILS"),
    "namemismatch": ([jrow(_KEYED)], 1, "different display names FAIL"),
    "undone": ([jrow(_KEYED), {"kind": "undo", "merge_id": "20261029T010203Z-0a0b0c0d"}], 1,
               "an undone merge is not proof and FAILS"),
    "secret": ([jrow([{"kind": "email", "hash": None}], reason="journal_secret_unavailable")], 78,
               "hash=null with journal_secret_unavailable is CANNOT-RUN, never PASS"),
    "unreadable": ("DIR", 78, "an unreadable journal is CANNOT-RUN, never PASS"),
}


class Store(BaseHTTPRequestHandler):
    calls = 0

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        Store.calls += 1
        u = urllib.parse.urlsplit(self.path)
        if u.path == "/query":
            q = urllib.parse.parse_qs(u.query).get("query", [""])[0]
            return self._send(bindings(sparql_answer(q)))
        if u.path == "/api/v1/hydration/status":
            # The shipped Doctor (ical-server _wiki_people_count) counts the
            # Qdrant points that pass people_rules.is_countable_person (v1.0.121).
            sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vendor", "cm041", "assistant_api"))
            from people_rules import is_countable_person
            n = sum(1 for dn in COUNT_FIXTURES[COUNT_FIXTURE[0]]["qd_named"] if is_countable_person(dn))
            return self._send({"overall_state": "done", "phases": [{"key": "contacts", "count": n}]})
        self._send({}, 404)

    def do_POST(self):
        Store.calls += 1
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n).decode()
        if self.path == "/query":
            return self._send(bindings(sparql_answer(data)))
        if self.path.endswith("/points/scroll") and "display_name" in data:
            pts = [{"payload": {"display_name": dn}} for dn in COUNT_FIXTURES[COUNT_FIXTURE[0]]["qd_named"]]
            return self._send({"result": {"points": pts, "next_page_offset": None}})
        if self.path.endswith("/points/scroll"):
            return self._send({"result": {"points": [{"payload": {"person_uri": P + "1"}}],
                                          "next_page_offset": None}})
        self._send({}, 404)


# --------------------------------------------------------------------------
def make_env(tmp, port):
    stub = os.path.join(tmp, "stub")
    os.makedirs(stub)
    with open(os.path.join(stub, "ssh"), "w") as fh:
        # LIKE REAL ssh: without -n it consumes its stdin (ssh forwards stdin
        # to the remote command), so a box_run inside a while-read loop eats
        # the rest of the list. That is the #3202 defect ORM measured.
        fh.write('#!/bin/bash\nnostdin=0\nfor a; do last="$a"; [ "$a" = "-n" ] && nostdin=1; done\n'
                 'if [ "$nostdin" = 1 ]; then exec /bin/bash -c "$last" </dev/null; fi\n'
                 'cat >/dev/null\nexec /bin/bash -c "$last" </dev/null\n')
    with open(os.path.join(stub, "launchctl"), "w") as fh:
        fh.write('#!/bin/bash\necho "$*" >> "%s/launchctl.calls"\n'
                 'case "$1" in print) echo "Could not find service \\"${2##*/}\\" in domain for user gui: 501" >&2; exit 113 ;;\n'
                 '*) exit 1 ;; esac\n' % tmp)
    for f in ("ssh", "launchctl"):
        os.chmod(os.path.join(stub, f), 0o755)
    home = os.path.join(tmp, "home")
    for d in (".ostler/state/source_activity", ".ostler/state/hydrate", ".ostler/logs"):
        os.makedirs(os.path.join(home, d))
    with open(os.path.join(home, ".ostler/state/source_activity/people_index.tsv"), "w") as fh:
        fh.write("last_success_at=%s\n" % IDX_AT)
    with open(os.path.join(home, ".ostler/state/hydrate/people.done"), "w") as fh:
        fh.write("recorded_at=2026-10-26T05:00:00Z\nsource=people\nstatus=ok\nitem_count=1\npayload=sent=1\n")
    with open(os.path.join(home, ".ostler/logs/install.log"), "w") as fh:
        fh.write("[warn]  Indexed 1 of 4 people for search so far. The rest were not searchable yet; Ostler will retry automatically.\n"
                 "[warn]  The background top-up helper could not be scheduled, so new messages, mail and calendar entries will not be picked up on their own. Re-run the installer to restore it.\n")
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    env.update({
        "PATH": stub + os.pathsep + env.get("PATH", "/usr/bin:/bin"),
        "HOME": home,
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        "OSTLER_BOX_HOST": "synthetic-box",
        "OSTLER_OXIGRAPH_URL": "http://127.0.0.1:%d/query" % port,
        "OSTLER_QDRANT_URL": "http://127.0.0.1:%d" % port,
        "OSTLER_DOCTOR_PEOPLE_URL": "http://127.0.0.1:%d/api/v1/hydration/status" % port,
        "OSTLER_PROBE_STATE_DIR": os.path.join(home, ".ostler/state"),
        "OSTLER_PEOPLE_STABILITY_RUNS": "2", "OSTLER_PEOPLE_STABILITY_STEP_S": "0",
        "OSTLER_PROBE_RECONCILE_READS": "1", "OSTLER_PROBE_TILE_READS": "1",
        "OSTLER_PROBE_WRITER_WAIT_S": "5", "OSTLER_PROBE_WRITER_POLL_S": "1",
        "OSTLER_INGEST_TICK_LABEL": "com.example.instr119.absent",
        "OSTLER_PROBE_TICK_WAIT_S": "5",
        "OSTLER_PEOPLE_RULES_DIR": os.path.join(REPO, "vendor", "cm041", "assistant_api"),
    })
    return env


def run_probe(name, env):
    p = subprocess.run(["/bin/bash", os.path.join(PROBES, "probes", name + ".sh")],
                       env=env, capture_output=True, text=True, timeout=300,
                       stdin=subprocess.DEVNULL)
    return p.returncode, p.stdout + p.stderr


RAW = ("900111", "one@example.com", "two@example.com", "Jane Doe", "John Doe")


def no_raw(name, out):
    leaked = [r for r in RAW if r in out]
    check(not leaked, "%s: no raw phone, email or name in the output" % name, "leaked %s" % leaked)


def probes_end_to_end():
    tmp = tempfile.mkdtemp(prefix="instr119-")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Store)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        env = make_env(tmp, srv.server_address[1])

        rc, out = run_probe("no_person_holds_two_contact_cards", env)
        check(rc == 1, "no_person_holds_two_contact_cards: exit 1 (FAIL) on two over-merged nodes, as before", "rc=%s %s" % (rc, out[-300:]))
        check("join key per offending node" in out, "no_person_holds_two_contact_cards: prints a join key per offending node")
        check("3 cards; no node merged in" in out and "email x2" in out,
              "no_person_holds_two_contact_cards: worst node first, a node with no merged-in source lists its candidate keys")
        check("2 cards; 1 node(s) merged in; joined by phone:" in out,
              "no_person_holds_two_contact_cards: a shared phone is named as the join key (masked)")
        n_explained = sum(1 for l in out.splitlines() if l.strip().startswith("node ") and " cards" in l)
        check(n_explained == 4, "no_person_holds_two_contact_cards: EVERY offending node is explained (4 of 4) with an ssh that consumes stdin",
              "%d of 4 explained" % n_explained)
        no_raw("no_person_holds_two_contact_cards", out)

        jdir = os.path.join(env["HOME"], ".ostler/import-pipeline/backups/merge_journal")
        jpath = os.path.join(jdir, "merge_journal.jsonl")
        for case, (rows, want, label) in JOURNAL_CASES.items():
            CARDS_FIXTURE[0] = case
            shutil.rmtree(jdir, ignore_errors=True)
            if rows == "DIR":
                os.makedirs(jpath)
            elif rows != "ABSENT":
                os.makedirs(os.path.join(jdir, "merge_snapshots"))
                with open(jpath, "w") as fh:
                    fh.write("".join(json.dumps(r) + "\n" for r in rows))
                with open(os.path.join(jdir, "merge_snapshots", "x.json"), "w") as fh:
                    json.dump(SNAPSHOT, fh)
            rc, out = run_probe("no_person_holds_two_contact_cards", env)
            check(rc == want, "no_person_holds_two_contact_cards journal rule: " + label,
                  "rc=%s want %s %s" % (rc, want, out[-300:]))
            if case == "pass":
                check("email_match/email" in out, "journal rule: the node line names the journal's strategy and key kind")
            if SHAPE_HASH in out:
                bad("journal rule: a key hash reached the output (%s)" % case)
        shutil.rmtree(jdir, ignore_errors=True)
        CARDS_FIXTURE[0] = "default"

        COUNT_FIXTURE[0] = "stubs"
        rc, out = run_probe("people_count_agreement", env)
        check(rc == 0 and "VERDICT: PASS" in out and "stubs=13" in out,
              "people_count_agreement: 13 stubs beside 20 named on both sides PASSES, stubs=13 printed",
              "rc=%s %s" % (rc, out[-400:]))
        check("named, not merged (what the vector writer indexes): 20" in out
              and "unnamed stub (no pwg:displayName, never indexed)  : 13" in out,
              "people_count_agreement: prints the oxigraph breakdown named / unnamed stub / merged")
        check("doctor minus indexable named                       : 0" in out,
              "people_count_agreement: prints the doctor gap against the indexable population")
        COUNT_FIXTURE[0] = "short"
        rc, out = run_probe("people_count_agreement", env)
        check(rc == 1 and "VERDICT: FAIL" in out, "people_count_agreement: named counts 20 vs 17 still FAIL",
              "rc=%s %s" % (rc, out[-300:]))
        COUNT_FIXTURE[0] = "jids"
        rc, out = run_probe("people_count_agreement", env)
        check(rc == 0 and "VERDICT: PASS" in out, "people_count_agreement: JIDs on both sides PASS only when both sides apply the predicate",
              "rc=%s %s" % (rc, out[-300:]))
        env_norules = dict(env, OSTLER_PEOPLE_RULES_DIR=os.path.join(tmp, "no-such-dir"))
        COUNT_FIXTURE[0] = "stubs"
        rc, out = run_probe("people_count_agreement", env_norules)
        check(rc == 78 and "could not import is_countable_person" in out,
              "people_count_agreement: no importable predicate is CANNOT-RUN, never a raw-count verdict", "rc=%s" % rc)

        rc, out = run_probe("people_stores_reconcile", env)
        check(rc == 1, "people_stores_reconcile: exit 1 (FAIL) on C=4, as before", "rc=%s %s" % (rc, out[-300:]))
        for line, label in (("merged away (indexer skips)    : 1", "merged"),
                            ("no pwg:displayName (unselectable): 1", "no displayName"),
                            ("Person created after index     : 1", "created after index"),
                            ("embed failed (existed at index): 1", "embed failed"),
                            ("last index                     : %s (from people_index.tsv)" % IDX_AT, "index time")):
            check(line in out, "people_stores_reconcile: C split prints %s" % label)
        check("install-time hydrate-people          : people.done:present status:ok" in out
              and "install_log_line:PARTIAL" in out,
              "people_stores_reconcile: prints the install-time hydrate-people status and people.done presence")
        check("launchctl print gui/<uid>/com.example.instr119.absent: exit 113" in out,
              "recurring-writer check: prints the launchctl print exit code (real /bin/launchctl, absent label)")
        check("install.sh fda-rerun line (warn):" in out and "plist in ~/Library/LaunchAgents: ABSENT" in out,
              "recurring-writer check: prints the install.sh ok/warn line and the plist presence")
        check("writer job is not loaded on this box (launchctl print exit 113)" in out,
              "people_stores_reconcile: the writer-driver note carries launchctl's exit code")
        calls = ""
        try:
            calls = open(os.path.join(tmp, "launchctl.calls")).read()
        except OSError:
            pass
        check("kickstart" not in calls, "no launchctl kickstart was attempted against any job", calls)
        no_raw("people_stores_reconcile", out)
        if Store.calls < 10:
            cannot("the synthetic stores were called %d times: the probes are not reaching them" % Store.calls)
        print("  store calls: %d" % Store.calls)
    finally:
        srv.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
def customer_read_causes():
    path = os.path.join(PROBES, "lib", "customer_read.py")
    spec = importlib.util.spec_from_file_location("customer_read_instr119", path)
    cr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cr)

    class Req(object):
        method = "GET"

    class Resp(object):
        def __init__(self, url, status, body=None, evicted=False):
            self.url, self.status, self._b, self._e, self.request = url, status, body, evicted, Req()

        def text(self):
            if self._e:
                raise RuntimeError("evicted")
            return self._b

    f = {"requests": []}
    pending = []
    body = '<html>502 Bad Gateway: upstream 127.0.0.1:8090 refused; owner jane@example.com +44 7700 900222</html>'
    try:
        cr.record_response(f, Resp("http://127.0.0.1:1/api/v1/hydration/status", 502, body), lambda u: u, pending)
        cr.record_response(f, Resp("http://127.0.0.1:1/api/v1/sources", 200, "{}"), lambda u: u, pending)
        cr.record_response(f, Resp("http://127.0.0.1:1/api/v1/box-status", 503, None, evicted=True), lambda u: u, pending)
        cr.read_pending_bodies(pending, lambda u: (503, "Service Unavailable: doctor starting"))
    except AttributeError as exc:
        bad("customer_read: the 5xx body capture does not exist (%s)" % exc)
        return
    rows = {r["u"]: r for r in f["requests"]}
    b = rows["http://127.0.0.1:1/api/v1/hydration/status"].get("b", "")
    check(b.startswith("<html>502 Bad Gateway: upstream") and len(b) <= 300,
          "customer_read: a 502 from /api/v1/hydration/status keeps its body (first 300 chars)", b)
    check("jane@example.com" not in b and "900222" not in b, "customer_read: the body is masked (no email, no number)", b)
    check("b" not in rows["http://127.0.0.1:1/api/v1/sources"], "customer_read: a 2xx response carries no body")
    check(rows["http://127.0.0.1:1/api/v1/box-status"].get("b") == "(re-fetched) Service Unavailable: doctor starting",
          "customer_read: an evicted body is re-fetched once and marked as such")

    facts = {"requests": [{"m": "GET", "u": "[doctor]/api/v1/hydration/status", "s": 502, "b": "upstream refused"}],
             "needs_now_app": ["Jane Doe\u2019s birthday is in five days", "Two records for John Doe?"],
             "needs_now_wiki": ["Jane Doe's birthday is in five days"],
             "freshness": {"feed": 100, "wiki": 200, "now": 300}}
    got = {n: (o, d) for n, o, d in cr.judge(facts)}
    o4, d4 = got[cr.DECLARED[4]]
    check(o4 is False and "502 [doctor]/api/v1/hydration/status body='upstream refused'" in d4,
          "customer_read: the 2xx assertion still FAILS and now names the 502 body", d4)
    o8, d8 = got[cr.DECLARED[8]]
    check(o8 is False, "customer_read: Needs you now mismatch still FAILS", str(o8))
    check("app keys [" in d8 and "wiki keys [" in d8 and "(only here)" in d8
          and "X X's birthday is in five days" in d8 and "X records for X X? (only here)" in d8,
          "customer_read: Needs you now prints both key lists, the odd card marked", d8)
    check("Jane" not in d8 and "John" not in d8, "customer_read: the key lists carry no name", d8)


def main():
    if not os.path.isdir(os.path.join(PROBES, "probes")):
        cannot("no probes at %s" % PROBES)
    for tool in ("/bin/bash", "/usr/bin/shasum", "curl"):
        if not shutil.which(tool):
            cannot("%s is not available on this host" % tool)
    print("probes under test: %s" % PROBES)
    probes_end_to_end()
    customer_read_causes()
    print("")
    print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
    if FAIL:
        print("first failure: %s" % FIRSTBAD, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
