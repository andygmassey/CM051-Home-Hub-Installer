"""walk #31 (v1.0.108): owner_digest_knows_the_owner graded the generator's
"Recent meetings (last 7 days): nothing stored" as a lie, "store holds 1".

The probe's count used LOCAL dates and no now-bound. The calendar ingest stores
UTC ("YYYY-MM-DD HH:MM:SS+00:00", vendor/ostler_fda/extract_all.py, 30 days
ahead), and the generator keeps a PAST meeting only when it has started
(generate_pwg_context.py _meeting_rows). So an entry later today was counted by
the probe and rightly left out by the generator.

This runs the probe's OWN measure_stores() against a REAL SPARQL engine
(pyoxigraph behind HTTP /query): only the host it dials is redirected.
  RED   the v1.0.108 probe (pinned by SHA) counts an entry 3h ahead as a recent meeting.
  GREEN this probe does not, and still counts one that started 2 days ago,
        and counts the 3h-ahead entry as upcoming. Synthetic only.
"""
import datetime
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyoxigraph as ox

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
REL = "scripts/box_walk_probes/lib/owner_digest.py"
V1_0_108 = "56a5ed21f708e517bc812fa03b6ff49b01bc2fc8"
PWG = "https://schema.ostler.ai/ontology#"


def _serve(store):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            q = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            res = store.query(q)
            vars_ = [v.value for v in res.variables]
            rows = [{v: {"type": "literal", "value": s[v].value} for v in vars_ if s[v] is not None} for s in res]
            body = json.dumps({"head": {"vars": vars_}, "results": {"bindings": rows}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _measure(mod, port):
    real = mod._http

    def redirected(url, data=None, headers=None, timeout=30):
        if url.startswith("http://127.0.0.1:7878"):
            return real(url.replace(":7878", ":%d" % port), data, headers, timeout)
        raise OSError("qdrant not part of this test")  # -> None, never a number
    mod._http = redirected
    return mod.measure_stores()


def _store(*hours):
    st = ox.Store()
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    for i, h in enumerate(hours):
        m = ox.NamedNode(PWG + "meeting_t%d" % i)
        d = str(now + datetime.timedelta(hours=h))  # the calendar ingest's own shape
        for p, o in (("http://www.w3.org/1999/02/22-rdf-syntax-ns#type", ox.NamedNode(PWG + "Meeting")),
                     (PWG + "meetingSummary", ox.Literal("Synthetic entry %d" % i)),
                     (PWG + "meetingDate", ox.Literal(d))):
            st.add(ox.Quad(m, ox.NamedNode(p), o, ox.DefaultGraph()))
    return st


def main():
    # The local zone the walk box ran in. Set before any module reads the clock.
    os.environ["TZ"] = "Asia/Hong_Kong"
    import time
    time.tzset()
    fails = 0

    def arm(name, ok, got):
        nonlocal fails
        print("  [%s] %s (%s)" % ("PASS" if ok else "FAIL", name, got))
        fails += 0 if ok else 1

    try:
        old_src = subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (V1_0_108, REL)],
                                 capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, OSError) as exc:
        print("CANNOT-RUN: v1.0.108 probe not readable (needs full history): %s" % exc)
        return 2
    tmp = tempfile.mkdtemp()
    old_path = os.path.join(tmp, "owner_digest_v1_0_108.py")
    open(old_path, "w").write(old_src)

    future = _store(3)          # an entry 3 hours from now: not yet a meeting that happened
    past = _store(-48)          # started two days ago
    s1, s2 = _serve(future), _serve(past)
    try:
        old = _measure(_load(old_path, "od_old"), s1.server_address[1])
        new = _measure(_load(os.path.join(REPO, REL), "od_new"), s1.server_address[1])
        new_past = _measure(_load(os.path.join(REPO, REL), "od_new2"), s2.server_address[1])
    finally:
        s1.shutdown()
        s2.shutdown()

    print("1. the defect, reproduced on the v1.0.108 probe")
    arm("RED: v1.0.108 counts an entry 3h ahead as a recent meeting", old["meetings_7d"] == 1, old["meetings_7d"])
    print("2. this probe")
    arm("an entry 3h ahead is not a recent meeting", new["meetings_7d"] == 0, new["meetings_7d"])
    arm("an entry 3h ahead IS an upcoming calendar event", new["calendar_events"] == 1, new["calendar_events"])
    arm("CONTROL: a meeting that started 2 days ago is counted", new_past["meetings_7d"] == 1, new_past["meetings_7d"])
    arm("CONTROL: it is not counted as upcoming", new_past["calendar_events"] == 0, new_past["calendar_events"])
    print("%d failed" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
