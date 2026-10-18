"""gateway_never_serves_a_stored_secret: box-side sweep, judge, self-test.

The question: does any gateway or companion route hand back a secret the box
stores in ${OSTLER_DIR}/assistant-config/config.toml? The secrets are every
entry of [gateway].paired_tokens and the Vane password embedded in vane_url
(http://<user>:<pw>@localhost:3000).

Also swept, when present on the box: the licence id (license/license.json) and
the registered device fingerprint (state/fingerprint.txt) under ${OSTLER_DIR}.
The Hub reads both to proxy POST /api/v1/invites/{mint,rewards} to the licence
server (ostler-assistant #573), so those two routes are ALWAYS swept, added to
the contract's route list if it does not carry them yet, and are sent in the
authenticated arm too (mint is idempotent and the member's own; rewards only
reads). Each file is its own positive control. A box without either file says
so in a NOT INSTRUMENTED line; the token sweep still stands.

  sweep  (runs ON the box) reads the secret values from config.toml, holds
         them in memory only (never printed, never written), derives the
         route list from the hub contract (generated from the daemon's router
         by scripts/gen_hub_contract.py, listener "gateway"), and requests
         every route on every base twice: with no credential, and with a
         paired bearer the gateway accepts. For each response it COUNTS each
         secret in the body and in the raw headers, in three forms: the exact
         value, its URL-encoding and its base64 (plus base64 of the Vane
         user:pw pair, the Basic-auth shape). Emits JSON with secret LABELS
         and counts only.
  judge  (runs on the driver) reads that JSON. PASS = every count is 0.
         FAIL names method, path, base and auth mode, never a value.
         CANNOT-RUN when the positive control saw 0, the config was
         unreadable, no secret was found, no accepted bearer exists, or a
         base answered nothing.

POSITIVE CONTROL, run before any request: the same counter is applied to the
config file's own bytes (or --control-file) and must find every secret at
least once. If it finds 0 the counter is blind and a 0 below would mean
nothing, so the sweep refuses with CANNOT-RUN.

Requests are read-only where it matters. In the authenticated arm, a mutating
route whose effect does not depend on the body (DELETE, rotate, shutdown,
forget, paircode/new, ...) is NOT sent; it is recorded as a skipped row and
counted, never hidden. Every other mutating request carries a body that is
not JSON, so a handler refuses it at parse time. /admin/shutdown is never
sent in either arm.

Exit: 0 pass, 1 fail, 78 cannot-run, 2 usage.
Must run under the box's /usr/bin/python3 (3.9): no tomllib, no match.
"""
import base64
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse

EX_PASS, EX_FAIL, EX_CANNOT, EX_USAGE = 0, 1, 78, 2
PLACEHOLDER = "walk-probe-nonexistent"
NOT_JSON = b"walk-probe: deliberately not json"
READ_CAP = 1 << 20
NEVER_SEND = ("/admin/shutdown",)
# The Hub proxies these with the licence id + fingerprint (ostler-assistant
# #573). Swept even before the contract lists them, in both arms.
INVITE_ROUTES = [("POST", "/api/v1/invites/mint", ["device_bearer"]),
                 ("POST", "/api/v1/invites/rewards", ["device_bearer"])]
BODY_BLIND = re.compile(r"(shutdown|/rotate|/forget|paircode/new|suppress-suggestions|/dismiss|pairing/initiate)")


# ---------------------------------------------------------------- secrets
def _section(text, name):
    out, inside = [], False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and not s.startswith("[["):
            inside = (s == "[%s]" % name)
            continue
        if s.startswith("[["):
            inside = False
            continue
        if inside:
            out.append(line)
    return "\n".join(out)


def _toml_strings(fragment):
    vals = []
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|\'([^\']*)\'', fragment):
        if m.group(1) is not None:
            vals.append(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
        else:
            vals.append(m.group(2))
    return vals


def read_secrets(text):
    """Return [(label, value, extra_forms)] from config.toml text."""
    secrets = []
    gw = _section(text, "gateway")
    m = re.search(r"(?ms)^\s*paired_tokens\s*=\s*\[(.*?)\]", gw)
    if m:
        for i, v in enumerate(_toml_strings(m.group(1))):
            if v:
                secrets.append(("paired_token[%d]" % i, v, []))
    for m in re.finditer(r'(?m)^\s*vane_url\s*=\s*"([^"]*)"', text):
        u = urllib.parse.urlsplit(m.group(1))
        if u.password:
            pw = urllib.parse.unquote(u.password)
            pair = "%s:%s" % (urllib.parse.unquote(u.username or ""), pw)
            secrets.append(("vane_password", pw, [base64.b64encode(pair.encode()).decode()]))
            break
    return secrets


def read_file_secrets(license_path, fingerprint_path):
    """[(label, value, [], control_bytes)] for the licence id and fingerprint
    files that exist; [(label, None, reason)] style absences in a second list."""
    found, absent = [], []
    try:
        raw = open(license_path, "rb").read()
        lid = (json.loads(raw.decode("utf-8", "replace")).get("license_id") or "").strip()
        if lid:
            found.append(("licence_id", lid, [], raw))
        else:
            absent.append("licence_id (license.json has no license_id)")
    except (OSError, ValueError, AttributeError):
        absent.append("licence_id (no readable license.json)")
    try:
        raw = open(fingerprint_path, "rb").read()
        fp = raw.decode("utf-8", "replace").strip()
        if fp:
            found.append(("device_fingerprint", fp, [], raw))
        else:
            absent.append("device_fingerprint (fingerprint.txt is empty)")
    except OSError:
        absent.append("device_fingerprint (no readable fingerprint.txt)")
    return found, absent


def forms(value, extra):
    out = [value, urllib.parse.quote(value, safe=""), base64.b64encode(value.encode()).decode()]
    out += extra
    seen, uniq = set(), []
    for f in out:
        if f and f not in seen:
            seen.add(f)
            uniq.append(f.encode())
    return uniq


def count(blob, value, extra):
    return sum(blob.count(f) for f in forms(value, extra))


# ---------------------------------------------------------------- routes
def gateway_routes(contract_path):
    c = json.load(open(contract_path))
    routes = [r for r in c.get("routes", []) if r.get("listener") == "gateway"]
    out = [(r["method"].upper(), r["path"], r.get("auth") or []) for r in routes]
    have = {(m, p) for (m, p, _a) in out}
    out += [(m, p, a) for (m, p, a) in INVITE_ROUTES if (m, p) not in have]
    return out


def concrete(path):
    return re.sub(r"\{[^}]+\}", PLACEHOLDER, path)


def request(base, method, path, bearer, timeout):
    u = urllib.parse.urlsplit(base)
    if u.scheme == "https":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection(u.hostname, u.port, timeout=timeout, context=ctx)
    else:
        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=timeout)
    headers = {"Accept-Encoding": "identity", "User-Agent": "ostler-walk-probe"}
    body = None
    if method not in ("GET", "HEAD"):
        body = NOT_JSON
        headers["Content-Type"] = "application/json"
    if bearer is not None:
        headers["Authorization"] = "Bearer " + bearer
    try:
        conn.request(method, concrete(path), body=body, headers=headers)
        resp = conn.getresponse()
        raw_headers = ("%s %s\r\n" % (resp.status, resp.reason)).encode()
        for k, v in resp.getheaders():
            raw_headers += ("%s: %s\r\n" % (k, v)).encode("latin-1", "replace")
        data = b""
        try:
            while len(data) < READ_CAP:
                chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
                if not chunk:
                    break
                data += chunk
        except (socket.timeout, OSError, http.client.HTTPException):
            pass
        return resp.status, raw_headers + b"\r\n" + data
    except (socket.timeout, OSError, http.client.HTTPException, ssl.SSLError):
        return 0, b""
    finally:
        conn.close()


def find_bearer(secrets, bases, routes, timeout):
    """First paired token the gateway accepts on a device_bearer GET route."""
    probe_paths = [p for (m, p, a) in routes if m == "GET" and "device_bearer" in a and "{" not in p]
    probe_paths = sorted(probe_paths, key=lambda p: (p != "/api/status", p))[:3]
    for label, value, _ in secrets:
        if not label.startswith("paired_token"):
            continue
        for base in bases:
            for p in probe_paths:
                st, _ = request(base, "GET", p, value, timeout)
                if 200 <= st < 300:
                    return label, value
    return None, None


def sweep(config_path, contract_path, bases, control_file=None, timeout=8.0,
          license_path=None, fingerprint_path=None):
    res = {"bases": bases, "rows": [], "skipped": [], "control": {}, "cannot": None}
    try:
        text = open(config_path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        res["cannot"] = "config.toml unreadable at %s: %s" % (config_path, e.strerror)
        return res
    secrets = read_secrets(text)
    res["secret_labels"] = [s[0] for s in secrets]
    if not any(s[0].startswith("paired_token") for s in secrets):
        res["cannot"] = "no [gateway].paired_tokens entry found in config.toml"
        return res
    try:
        ctrl = open(control_file or config_path, "rb").read()
    except OSError as e:
        res["cannot"] = "positive-control file unreadable: %s" % e.strerror
        return res
    for label, value, extra in secrets:
        res["control"][label] = count(ctrl, value, extra)
    od = os.path.dirname(os.path.dirname(os.path.abspath(config_path)))
    fsec, absent = read_file_secrets(license_path or os.path.join(od, "license", "license.json"),
                                     fingerprint_path or os.path.join(od, "state", "fingerprint.txt"))
    res["not_instrumented"] = absent
    for label, value, extra, raw in fsec:
        res["control"][label] = count(raw, value, extra)
        secrets.append((label, value, extra))
    res["secret_labels"] = [s[0] for s in secrets]
    blind = [l for l, n in res["control"].items() if n < 1]
    if blind:
        res["cannot"] = "positive control saw 0 for %s in %s: the counter is blind, so a 0 below would mean nothing" % (
            ", ".join(blind), "the control file" if control_file else "config.toml")
        return res
    try:
        routes = gateway_routes(contract_path)
    except (OSError, ValueError, KeyError) as e:
        res["cannot"] = "hub contract unreadable: %s" % e
        return res
    if not routes:
        res["cannot"] = "the hub contract lists no gateway routes"
        return res
    blabel, bearer = find_bearer(secrets, bases, routes, timeout)
    res["bearer_label"] = blabel
    if bearer is None:
        res["cannot"] = "no paired token was accepted as a bearer on any base, so the authenticated arm cannot run"
        return res
    for base in bases:
        for method, path, _auth in routes:
            if path in NEVER_SEND:
                res["skipped"].append({"method": method, "path": path, "base": base, "auth": "both", "why": "never sent"})
                continue
            for mode in ("none", "paired_bearer"):
                if mode == "paired_bearer" and method != "GET" and (method == "DELETE" or BODY_BLIND.search(path)):
                    res["skipped"].append({"method": method, "path": path, "base": base, "auth": mode,
                                           "why": "mutating, body-independent effect"})
                    continue
                st, blob = request(base, method, path, bearer if mode == "paired_bearer" else None, timeout)
                counts = {l: count(blob, v, x) for (l, v, x) in secrets}
                res["rows"].append({"method": method, "path": path, "base": base, "auth": mode,
                                    "status": st, "counts": counts})
    return res


# ---------------------------------------------------------------- judge
def judge(res):
    lines = []
    if res.get("cannot"):
        return ["  CANNOT %s" % res["cannot"]], EX_CANNOT
    rows = res.get("rows", [])
    lines.append("  ok     positive control: %s each found >= 1 time by the same counter" % (
        ", ".join("%s=%d" % kv for kv in sorted(res.get("control", {}).items())) or "nothing"))
    lines.append("  ok     authenticated arm uses %s" % res.get("bearer_label"))
    for a in res.get("not_instrumented", []):
        lines.append("  ok     NOT INSTRUMENTED on this box: %s, so the invite routes were checked for the other secrets only" % a)
    for b in res.get("bases", []):
        answered = [r for r in rows if r["base"] == b and r["status"]]
        if not answered:
            lines.append("  CANNOT %s answered none of its %d requests" % (b, len([r for r in rows if r["base"] == b])))
            return lines, EX_CANNOT
        lines.append("  ok     %s answered %d of %d requests" % (b, len(answered), len([r for r in rows if r["base"] == b])))
    leaks = [r for r in rows if any(n > 0 for n in r["counts"].values())]
    for s in res.get("skipped", []):
        lines.append("  ok     skipped %s %s on %s (%s): %s" % (s["method"], s["path"], s["base"], s["auth"], s["why"]))
    for r in leaks:
        which = ", ".join("%s x%d" % (l, n) for l, n in sorted(r["counts"].items()) if n > 0)
        lines.append("  FAIL   %s %s on %s auth=%s status=%s served a stored secret (%s)" % (
            r["method"], r["path"], r["base"], r["auth"], r["status"], which))
    lines.append("  %s %d requests, %d skipped, %d served a stored secret" % (
        "FAIL  " if leaks else "ok    ", len(rows), len(res.get("skipped", [])), len(leaks)))
    return lines, (EX_FAIL if leaks else EX_PASS)


def tsv(res):
    out = ["method\tpath\tbase\tauth\tstatus\tcount"]
    for r in res.get("rows", []):
        out.append("%s\t%s\t%s\t%s\t%s\t%d" % (r["method"], r["path"], r["base"], r["auth"], r["status"],
                                               sum(r["counts"].values())))
    return "\n".join(out)


# ---------------------------------------------------------------- box bases
def default_bases():
    gw = os.environ.get("OSTLER_GATEWAY_PORT", "8000")
    cp = os.environ.get("OSTLER_COMPANION_PORT", "8443")
    lan = os.environ.get("OSTLER_PAIR_PROBE_HOST", "")
    if not lan:
        for ifc in ("en0", "en1"):
            try:
                lan = subprocess.run(["ipconfig", "getifaddr", ifc], capture_output=True, text=True,
                                     timeout=5).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                lan = ""
            if lan:
                break
    bases = ["https://127.0.0.1:%s" % cp, "http://127.0.0.1:%s" % gw]
    if lan:
        bases.insert(0, "https://%s:%s" % (lan, cp))
    return bases, bool(lan)


# ---------------------------------------------------------------- self-test
SYN_TOKEN = "zc_walkprobe_synthetic_token_0123456789abcdef"
SYN_VANE = "walkprobe-synthetic-vane-pw"
SYN_TOKEN2 = "zc+walkprobe/second=token"
SYN_LICENCE = "0000beef-walk-4000-8000-probe0licence"
SYN_FPRINT = "walkprobe-synthetic-fingerprint-0001"
CONTRACT = {"routes": [
    {"listener": "gateway", "method": "GET", "path": "/health", "auth": ["handler_defined"]},
    {"listener": "gateway", "method": "GET", "path": "/api/status", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "GET", "path": "/api/config", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "POST", "path": "/api/memory", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "DELETE", "path": "/api/devices/{id}", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "POST", "path": "/admin/shutdown", "auth": ["admin_token"]},
    {"listener": "doctor", "method": "GET", "path": "/doctor-only", "auth": ["none"]},
]}


def _fake_server(leak):
    """leak: None (clean), or (method, path, form) to leak on that route when authorised."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _do(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(n)
            authed = self.headers.get("Authorization") == "Bearer " + SYN_TOKEN
            path = self.path.split("?")[0]
            if path == "/health":
                code, body = 200, b'{"ok":true}'
            elif not authed:
                code, body = 401, b'{"error":"unauthorized"}'
            else:
                code, body = (200, b'{"status":"ok"}') if self.command == "GET" else (400, b'{"error":"bad json"}')
            if leak and authed and self.command == leak[0] and path == leak[1]:
                body = body[:-1] + b',"vane_url":"http://ostler:' + leak[2].encode() + b'@localhost:3000"}'
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = do_POST = do_DELETE = do_PUT = do_PATCH = _do

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def write_fixture(d):
    cfg = os.path.join(d, "config.toml")
    fd = os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write('[gateway]\nrequire_pairing = true\npaired_tokens = [\n  "%s",\n  "%s",\n]\n\n[web_search]\nprovider = "vane"\n'
                'vane_url = "http://ostler:%s@localhost:3000"\n' % (SYN_TOKEN, SYN_TOKEN2, SYN_VANE))
    con = os.path.join(d, "hub_contract.yaml")
    json.dump(CONTRACT, open(con, "w"))
    open(os.path.join(d, "license.json"), "w").write('{"license_id":"%s"}\n' % SYN_LICENCE)
    open(os.path.join(d, "fingerprint.txt"), "w").write(SYN_FPRINT + "\n")
    blind = os.path.join(d, "control_without_secret.txt")
    open(blind, "w").write("[gateway]\npaired_tokens = []\n")
    return cfg, con, blind


def self_test():
    ok = True
    d = tempfile.mkdtemp(prefix="secret-sweep-st-")
    cfg, con, blind = write_fixture(d)
    lic, fpr = os.path.join(d, "license.json"), os.path.join(d, "fingerprint.txt")

    def arm(name, leak, expect_rc, control_file=None, bases=None, must=None):
        nonlocal ok
        srv = _fake_server(leak)
        b = bases or ["http://127.0.0.1:%d" % srv.server_address[1]]
        res = sweep(cfg, con, b, control_file=control_file, timeout=3, license_path=lic, fingerprint_path=fpr)
        lines, rc = judge(res)
        srv.shutdown()
        text = "\n".join(lines) + json.dumps(res)
        good = rc == expect_rc and (must is None or must in "\n".join(lines)) \
            and not any(v in text for v in (SYN_TOKEN, SYN_TOKEN2, SYN_VANE, SYN_LICENCE, SYN_FPRINT))
        print("  %s %s: rc=%d (want %d)" % ("ok    " if good else "FAIL  ", name, rc, expect_rc))
        ok &= good

    arm("a clean fake gateway passes", None, EX_PASS)
    arm("a token leaked on GET /api/config fails naming the route", ("GET", "/api/config", SYN_TOKEN), EX_FAIL,
        must="GET /api/config")
    arm("a URL-encoded second token leaked on GET /api/status fails", ("GET", "/api/status", urllib.parse.quote(SYN_TOKEN2, safe="")),
        EX_FAIL, must="GET /api/status")
    arm("a base64 Vane password leaked on POST /api/memory fails", ("POST", "/api/memory",
        base64.b64encode(SYN_VANE.encode()).decode()), EX_FAIL, must="POST /api/memory")
    arm("the fingerprint echoed on POST /api/v1/invites/mint fails naming the route",
        ("POST", "/api/v1/invites/mint", SYN_FPRINT), EX_FAIL, must="POST /api/v1/invites/mint")
    arm("the licence id echoed on POST /api/v1/invites/rewards fails naming the route",
        ("POST", "/api/v1/invites/rewards", SYN_LICENCE), EX_FAIL, must="POST /api/v1/invites/rewards")
    arm("a control that sees 0 is CANNOT-RUN, never PASS", None, EX_CANNOT, control_file=blind,
        must="positive control saw 0")
    arm("no route responding is CANNOT-RUN", None, EX_CANNOT, bases=["http://127.0.0.1:9"])
    res = sweep(os.path.join(d, "absent.toml"), con, ["http://127.0.0.1:9"])
    good = judge(res)[1] == EX_CANNOT
    print("  %s an unreadable config.toml is CANNOT-RUN" % ("ok    " if good else "FAIL  "))
    ok &= good
    srv = _fake_server(None)
    res = sweep(cfg, con, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3,
                license_path=lic, fingerprint_path=fpr)
    srv.shutdown()
    sent = {(r["method"], r["path"], r["auth"]) for r in res["rows"]}
    good = ("GET", "/doctor-only", "none") not in sent and not any(r["path"] == "/admin/shutdown" for r in res["rows"]) \
        and ("DELETE", "/api/devices/{id}", "paired_bearer") not in sent and ("DELETE", "/api/devices/{id}", "none") in sent \
        and all((m, p, a) in sent for (m, p, _x) in INVITE_ROUTES for a in ("none", "paired_bearer"))
    print("  %s routes come from the contract's gateway listener; shutdown never sent; authed DELETE skipped; invite routes sent in both arms" % (
        "ok    " if good else "FAIL  "))
    ok &= good
    srv = _fake_server(None)
    res = sweep(cfg, con, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3,
                license_path=os.path.join(d, "absent.json"), fingerprint_path=os.path.join(d, "absent.txt"))
    srv.shutdown()
    lines, rc = judge(res)
    good = rc == EX_PASS and sum("NOT INSTRUMENTED" in l for l in lines) == 2
    print("  %s no licence or fingerprint on the box: PASS on tokens, with 2 NOT INSTRUMENTED lines" % ("ok    " if good else "FAIL  "))
    ok &= good
    for f in os.listdir(d):
        os.unlink(os.path.join(d, f))
    os.rmdir(d)
    return ok


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return EX_PASS if self_test() else EX_FAIL
    if len(argv) >= 2 and argv[1] == "sweep":
        import argparse
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd")
        ap.add_argument("--config", required=True)
        ap.add_argument("--contract", required=True)
        ap.add_argument("--base", action="append", default=[])
        ap.add_argument("--control-file")
        ap.add_argument("--license")
        ap.add_argument("--fingerprint")
        a = ap.parse_args(argv[1:])
        bases = a.base
        if not bases:
            bases, has_lan = default_bases()
            if not has_lan:
                print(json.dumps({"cannot": "no LAN address on en0/en1 and OSTLER_PAIR_PROBE_HOST unset: the :8443 LAN surface cannot be swept"}))
                return EX_PASS
        print(json.dumps(sweep(a.config, a.contract, bases, control_file=a.control_file,
                               license_path=a.license, fingerprint_path=a.fingerprint)))
        return EX_PASS
    if len(argv) == 3 and argv[1] == "judge":
        res = json.load(open(argv[2]))
        lines, rc = judge(res)
        print("\n".join(lines))
        if os.environ.get("OSTLER_SECRET_SWEEP_TSV"):
            with open(os.environ["OSTLER_SECRET_SWEEP_TSV"], "w") as f:
                f.write(tsv(res) + "\n")
        return rc
    print("usage: stored_secret_sweep.py --self-test | sweep --config F --contract F [--base URL]... | judge FILE",
          file=sys.stderr)
    return EX_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv))
