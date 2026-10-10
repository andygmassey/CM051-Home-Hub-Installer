"""Walk #16: meeting_brief_text_is_grounded's seed write got HTTP 401 from the
:7878 store, because the probe never sent the store credential. The product's
writers send `Authorization: Bearer <oxigraph_token>`, resolved env-then-file
(lib/ostler_store_auth.py, route for 7878); the store proxy that install.sh
writes 401s anything else.

This stands up a fake store on a free port that answers exactly as that proxy
does (401 without the right bearer, 204 with it) and drives the probe's own
write function. Synthetic token, temporary secrets dir.
"""
import os
import pathlib
import sys
import tempfile
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/box_walk_probes/lib"))
import meeting_brief_sent_text as probe  # noqa: E402

TOKEN = "fixture-store-token"


class Store(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        auth = self.headers.get("Authorization") or ""
        Store.seen.append(auth)
        self.send_response(204 if auth == "Bearer " + TOKEN else 401)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Store)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d/update" % srv.server_address[1]
    fails = 0
    secrets = tempfile.mkdtemp()
    os.environ.pop("OXIGRAPH_TOKEN", None)
    os.environ["OSTLER_SECRETS_DIR"] = secrets
    for k in [k for k in os.environ if "proxy" in k.lower()]:
        os.environ.pop(k)

    # Control: with no credential on disk the store refuses, so the fake store
    # really is a gate and a pass below means the header was sent.
    try:
        probe.store_update(url, "INSERT DATA {}")
        print("FAIL  control: the fake store accepted a write with no credential")
        fails += 1
    except urllib.error.HTTPError as e:
        print("ok    control: no credential on disk -> HTTP %d" % e.code)

    # The installed secret file, as install.sh seeds it (0600).
    p = pathlib.Path(secrets) / "oxigraph_token"
    p.write_text(TOKEN + "\n")
    os.chmod(p, 0o600)
    try:
        probe.store_update(url, "INSERT DATA {}")
        print("ok    the seed write sends the store credential from ~/.ostler/secrets/oxigraph_token")
    except urllib.error.HTTPError as e:
        print("FAIL  the seed write was refused HTTP %d (sent %r)" % (e.code, Store.seen[-1:]))
        fails += 1

    # The env var wins, as in lib/ostler_store_auth.py.
    p.write_text("stale-token\n")
    os.environ["OXIGRAPH_TOKEN"] = TOKEN
    try:
        probe.store_update(url, "INSERT DATA {}")
        print("ok    OXIGRAPH_TOKEN in the environment takes precedence over the file")
    except urllib.error.HTTPError as e:
        print("FAIL  env token not used, HTTP %d" % e.code)
        fails += 1
    srv.shutdown()
    print("PASS" if not fails else "FAIL: %d" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
