#!/usr/bin/env python3
"""The RECONCILE payload must tell our own leaked fixture from a product orphan.

WHY THIS FILE EXISTS, AND IT IS THE POINT OF IT.

people_stores_reconcile.sh carries a negative control with eighteen cases. Every
one of them drives the SHELL verdict through FAKE_RECONCILE, which substitutes a
canned result line -- so the embedded python that PRODUCES that line is never
executed by the probe's own self-test. Measured: mutating the python to count
every orphan as one of ours, which is the false-green direction, left the
self-test green at 18 of 18.

That is a fixture encoding the flag rather than the property. The shell half was
tested; the classification was not. This drives the real payload.

WHAT IT ASSERTS
  1. an orphan vector carrying "box_walk_probe": true counts as OURS
  2. an orphan vector without it counts against the PRODUCT
  3. both present -> counted one each, neither absorbing the other
  4. the flag does NOT excuse a URI that is present in the graph, because such a
     URI is not an orphan at all and must land in neither bucket
  5. a payload that cannot be found, or a stub store that is never called, is
     CANNOT-RUN -- a green result here must not be obtainable by measuring nothing

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import io
import json
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PROBE = os.path.join(REPO, "scripts", "box_walk_probes", "probes",
                     "people_stores_reconcile.sh")

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


def cannot(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------
# Extract the payload. It is a QUOTED heredoc, so what is on disk is what runs
# on the box: no shell expansion stands between this text and the interpreter.
# --------------------------------------------------------------------------
def extract_payload():
    if not os.path.isfile(PROBE):
        cannot("no probe at %s" % PROBE)
    src = io.open(PROBE, encoding="utf-8").read()
    m = re.search(r"read -r -d '' RECONCILE_PY <<'PYPAYLOAD'\n(.*?)\nPYPAYLOAD\n",
                  src, re.S)
    if not m:
        cannot("could not find the RECONCILE_PY heredoc in %s -- it was renamed "
               "or reshaped, so this test is measuring nothing. Re-point it "
               "rather than trusting a green." % PROBE)
    body = m.group(1)
    if "box_walk_probe" not in body:
        cannot("the payload does not mention box_walk_probe at all. There is no "
               "attribution to test, which is a finding, not a pass.")
    return body


# --------------------------------------------------------------------------
# A fake store. Every call is counted, because a stub that is never reached
# produces the same silence as a store that answers nothing.
# --------------------------------------------------------------------------
class Store(object):
    def __init__(self, people, points):
        self.people = people          # list of graph Person URIs
        self.points = points          # list of (person_uri, is_fixture)
        self.calls = 0
        # URIs that exist in the graph in SOME position without being a Person.
        self.mentioned = set(people)

    def sparql(self, q):
        self.calls += 1
        if "?s ?p ?o }" in q and "COUNT(*)" in q and "<" not in q.split("WHERE")[1]:
            return [{"n": {"value": "424242"}}]        # the non-empty control
        if "a <" + ONT + "Person>" in q and q.startswith("SELECT ?p"):
            return [{"p": {"value": u}} for u in self.people]
        if "mergedInto" in q:
            return [{"n": {"value": "0"}}]             # residual A: none
        m = re.search(r"WHERE \{ <([^>]+)> \?p \?o \}", q)
        if m:
            return [{"n": {"value": "1" if m.group(1) in self.mentioned else "0"}}]
        m = re.search(r"WHERE \{ \?s \?p <([^>]+)> \}", q)
        if m:
            return [{"n": {"value": "1" if m.group(1) in self.mentioned else "0"}}]
        return []                                      # labels, emails: unnamed

    def qpost(self, path, body):
        self.calls += 1
        with_payload = body.get("with_payload")
        pts = []
        for uri, is_fixture in self.points:
            payload = {"person_uri": uri}
            # HONOUR with_payload. If the probe stops ASKING for the flag, the
            # store must stop returning it -- otherwise this test would pass on
            # a probe that never requested the field, which is exactly the
            # regression it is here to catch.
            if is_fixture and with_payload and "box_walk_probe" in with_payload:
                payload["box_walk_probe"] = True
            pts.append({"payload": payload})
        return {"result": {"points": pts, "next_page_offset": None}}


def run_payload(payload, store):
    """Execute the real payload against the fake store; return its printed line."""
    urlreq = types.ModuleType("urllib.request")
    urlerr = types.ModuleType("urllib.error")

    class HTTPError(Exception):
        def __init__(self, code=500):
            self.code = code

    urlerr.HTTPError = HTTPError

    class Req(object):
        def __init__(self, url, data=None, headers=None):
            self.url = url
            self.data = data

    def urlopen(req, timeout=None):
        if req.url.startswith("http://oxi"):
            out = {"results": {"bindings": store.sparql(req.data.decode())}}
        else:
            path = req.url[len("http://qd"):]
            out = store.qpost(path, json.loads(req.data.decode()))
        return io.BytesIO(json.dumps(out).encode())

    urlreq.Request = Req
    urlreq.urlopen = urlopen
    urlreq.install_opener = lambda o: None
    urlreq.build_opener = lambda *a: None
    urlreq.ProxyHandler = lambda d: None

    urllib_mod = types.ModuleType("urllib")
    urllib_mod.request = urlreq
    urllib_mod.error = urlerr

    saved = {k: sys.modules.get(k) for k in ("urllib", "urllib.request", "urllib.error")}
    sys.modules["urllib"] = urllib_mod
    sys.modules["urllib.request"] = urlreq
    sys.modules["urllib.error"] = urlerr
    old_argv, old_out = sys.argv, sys.stdout
    sys.argv = ["-", "http://oxi", "http://qd", "people", ""]
    sys.stdout = io.StringIO()
    try:
        g = {"__name__": "__main__"}
        try:
            exec(compile(payload, "RECONCILE_PY", "exec"), g)
        except SystemExit:
            pass
        return sys.stdout.getvalue().strip()
    finally:
        sys.stdout = old_out
        sys.argv = old_argv
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


def fields(line):
    parts = line.split()
    if not parts or parts[0] != "OK":
        return None
    return parts


def main():
    payload = extract_payload()
    print("payload: %d lines extracted from %s"
          % (len(payload.splitlines()), os.path.relpath(PROBE, REPO)))

    P1 = "urn:person:one"
    OURS = "urn:person:walkfixture"
    THEIRS = "urn:person:realorphan"

    # (label, graph people, qdrant points, expected b_orphan, expected b_fixture)
    cases = [
        ("only OUR fixture is orphaned",
         [P1], [(P1, False), (OURS, True)], 0, 1),
        ("only a PRODUCT orphan",
         [P1], [(P1, False), (THEIRS, False)], 1, 0),
        ("one of each -- neither absorbs the other",
         [P1], [(P1, False), (OURS, True), (THEIRS, False)], 1, 1),
        ("the flag does NOT excuse a URI the graph knows",
         [P1, OURS], [(P1, False), (OURS, True)], 0, 0),
        ("a clean box",
         [P1], [(P1, False)], 0, 0),
    ]

    total_calls = 0
    for label, people, points, want_b, want_f in cases:
        store = Store(people, points)
        line = run_payload(payload, store)
        total_calls += store.calls
        f = fields(line)
        if f is None:
            bad("%s: payload did not print an OK line, it printed %r" % (label, line[:90]))
            continue
        if len(f) < 9:
            bad("%s: the payload printed %d fields, so it reports no fixture "
                "attribution at all: %r" % (label, len(f), line))
            continue
        # OK graph vec A B Cn Cu both ours
        #  0    1    2  3 4  5  6   7    8
        got_b, got_f = f[4], f[8]
        if got_b == str(want_b) and got_f == str(want_f):
            ok("%s -> B=%s ours=%s" % (label, got_b, got_f))
        else:
            bad("%s -> B=%s ours=%s, expected B=%s ours=%s   (%s)"
                % (label, got_b, got_f, want_b, want_f, line))

    # ANTI-VACUITY. Every assertion above could be satisfied by a payload that
    # never talked to the store, if the expectations happened to be zeros.
    if total_calls < len(cases):
        cannot("the fake store was called %d times across %d cases -- the payload "
               "is not reaching it, so nothing above was measured."
               % (total_calls, len(cases)))
    print("  store calls across all cases: %d" % total_calls)

    print("")
    print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
    if FAIL:
        print("first failure: %s" % FIRSTBAD, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
