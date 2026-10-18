"""gateway_never_serves_a_stored_secret: box-side sweep, judge, self-test.

The question: does any gateway or companion route hand back a secret the box
stores in ${OSTLER_DIR}/assistant-config/config.toml? The secrets are every
entry of [gateway].paired_tokens and the Vane password embedded in vane_url
(http://<user>:<pw>@localhost:3000). When [email_assistant] is enabled, also
the assistant mailbox's app password, read from the Keychain with `security`
(the tool the installer stored it with, so no access prompt). Its positive
control is the raw Keychain answer, since config.toml never holds it.
POST /api/assistant-mailbox/self-test runs the mailbox self-test (it SENDS a
mail). The probe must never send outward mail, so it is POSTed only when the
mailbox is off or both its IMAP and SMTP hosts are loopback (the mailsim), with
a 75 s timeout so its real response is examined. Otherwise it is NOT POSTed in
either arm: the judge prints CANNOT for it ("mailbox host is not loopback;
self-test would send real mail") and a read-only GET of the same path is swept
instead (it reaches the router and the auth layer, never the handler).

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
SLOW = re.compile(r"/assistant-mailbox/self-test$")
SLOW_TIMEOUT = 75.0
MAILBOX_SERVICE = "Ostler Assistant Mailbox"
MAILBOX_LABEL = "assistant_mailbox_password"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")
NOT_LOOPBACK = "mailbox host is not loopback; self-test would send real mail"
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


def mailbox_address(text):
    """The assistant's own address when [email_assistant] is enabled, else None."""
    sec = _section(text, "email_assistant")
    if not re.search(r"(?m)^\s*enabled\s*=\s*true\s*$", sec):
        return None
    m = re.search(r'(?m)^\s*address\s*=\s*"([^"]+)"', sec)
    return m.group(1) if m else None


def mailbox_hosts_are_loopback(text):
    """True only when BOTH [email_assistant] hosts are loopback. Missing = not."""
    sec = _section(text, "email_assistant")
    hosts = [re.search(r'(?m)^\s*%s\s*=\s*"([^"]*)"' % k, sec) for k in ("imap_host", "smtp_host")]
    return all(h and h.group(1).strip().lower() in LOOPBACK_HOSTS for h in hosts)


def keychain_reader(address):
    """Raw bytes of the Keychain answer, or None. Never printed."""
    try:
        # OSTLER_SECRET_SWEEP_SECURITY: a test seam (the stand-in's absolute path),
        # because box_run's login shell resets PATH. Unset on a box.
        r = subprocess.run([os.environ.get("OSTLER_SECRET_SWEEP_SECURITY") or "security", "find-generic-password", "-s", MAILBOX_SERVICE, "-a", address, "-w"],
                           capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 and r.stdout.strip() else None


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
    return [(r["method"].upper(), r["path"], r.get("auth") or []) for r in routes]


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


def sweep(config_path, contract_path, bases, control_file=None, timeout=8.0, mailbox_reader=None):
    res = {"bases": bases, "rows": [], "skipped": [], "control": {}, "cannot": None}
    try:
        text = open(config_path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        res["cannot"] = "config.toml unreadable at %s: %s" % (config_path, e.strerror)
        return res
    secrets = read_secrets(text)
    controls = {}
    addr = mailbox_address(text)
    res["mailbox"] = "enabled" if addr else "not configured"
    may_send_selftest = (not addr) or mailbox_hosts_are_loopback(text)
    res["selftest_sent"] = may_send_selftest
    if addr:
        raw = (mailbox_reader or keychain_reader)(addr)
        if raw is None:
            res["cannot"] = "[email_assistant] is enabled but its password could not be read from the Keychain, so no route can be checked for it"
            return res
        secrets.append((MAILBOX_LABEL, raw.decode("utf-8", "replace").strip(), []))
        controls[MAILBOX_LABEL] = raw
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
        res["control"][label] = count(controls.get(label, ctrl), value, extra)
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
            if SLOW.search(path) and method == "POST" and not may_send_selftest:
                # Read-only stand-in: the same path by GET, both arms.
                res.setdefault("cannot_routes", []).append({"method": method, "path": path, "base": base,
                                                            "why": NOT_LOOPBACK})
                for mode in ("none", "paired_bearer"):
                    st, blob = request(base, "GET", path, bearer if mode == "paired_bearer" else None, timeout)
                    counts = {l: count(blob, v, x) for (l, v, x) in secrets}
                    res["rows"].append({"method": "GET", "path": path, "base": base, "auth": mode,
                                        "status": st, "counts": counts, "read_only_for": "POST"})
                continue
            for mode in ("none", "paired_bearer"):
                if mode == "paired_bearer" and method != "GET" and (method == "DELETE" or BODY_BLIND.search(path)):
                    res["skipped"].append({"method": method, "path": path, "base": base, "auth": mode,
                                           "why": "mutating, body-independent effect"})
                    continue
                st, blob = request(base, method, path, bearer if mode == "paired_bearer" else None,
                                   max(timeout, SLOW_TIMEOUT) if SLOW.search(path) else timeout)
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
    lines.append("  ok     assistant mailbox: %s%s" % (res.get("mailbox", "not configured"),
                 ", its password is swept" if res.get("mailbox") == "enabled" else ", so its password is not swept"))
    for b in res.get("bases", []):
        answered = [r for r in rows if r["base"] == b and r["status"]]
        if not answered:
            lines.append("  CANNOT %s answered none of its %d requests" % (b, len([r for r in rows if r["base"] == b])))
            return lines, EX_CANNOT
        lines.append("  ok     %s answered %d of %d requests" % (b, len(answered), len([r for r in rows if r["base"] == b])))
    for c in res.get("cannot_routes", []):
        lines.append("  CANNOT %s %s on %s: %s (a read-only GET of the path was swept instead)" % (
            c["method"], c["path"], c["base"], c["why"]))
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
SYN_MAILBOX = "walkprobemailboxapppw"
SYN_MAILBOX_ADDR = "tess.assistant@icloud.example"
CONTRACT = {"routes": [
    {"listener": "gateway", "method": "GET", "path": "/health", "auth": ["handler_defined"]},
    {"listener": "gateway", "method": "GET", "path": "/api/status", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "GET", "path": "/api/config", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "POST", "path": "/api/memory", "auth": ["device_bearer"]},
    {"listener": "gateway", "method": "POST", "path": "/api/assistant-mailbox/self-test", "auth": ["device_bearer"]},
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
            srv.hits.append((self.command, self.path.split("?")[0]))
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
    srv.hits = []
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def write_fixture(d, mailbox_host="127.0.0.1"):
    cfg = os.path.join(d, "config.toml")
    fd = os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write('[gateway]\nrequire_pairing = true\npaired_tokens = [\n  "%s",\n  "%s",\n]\n\n[web_search]\nprovider = "vane"\n'
                'vane_url = "http://ostler:%s@localhost:3000"\n\n[email_assistant]\nenabled = true\naddress = "%s"\n'
                'imap_host = "%s"\nsmtp_host = "%s"\n'
                % (SYN_TOKEN, SYN_TOKEN2, SYN_VANE, SYN_MAILBOX_ADDR, mailbox_host, mailbox_host))
    con = os.path.join(d, "hub_contract.yaml")
    json.dump(CONTRACT, open(con, "w"))
    blind = os.path.join(d, "control_without_secret.txt")
    open(blind, "w").write("[gateway]\npaired_tokens = []\n")
    return cfg, con, blind


def fake_keychain(address):
    return (SYN_MAILBOX + "\n").encode() if address == SYN_MAILBOX_ADDR else None


def self_test():
    ok = True
    d = tempfile.mkdtemp(prefix="secret-sweep-st-")
    cfg, con, blind = write_fixture(d)

    def arm(name, leak, expect_rc, control_file=None, bases=None, must=None, reader=None):
        nonlocal ok
        srv = _fake_server(leak)
        b = bases or ["http://127.0.0.1:%d" % srv.server_address[1]]
        res = sweep(cfg, con, b, control_file=control_file, timeout=3, mailbox_reader=reader or fake_keychain)
        lines, rc = judge(res)
        srv.shutdown()
        text = "\n".join(lines) + json.dumps(res)
        good = rc == expect_rc and (must is None or must in "\n".join(lines)) \
            and not any(v in text for v in (SYN_TOKEN, SYN_TOKEN2, SYN_VANE, SYN_MAILBOX))
        print("  %s %s: rc=%d (want %d)" % ("ok    " if good else "FAIL  ", name, rc, expect_rc))
        ok &= good

    arm("a clean fake gateway passes", None, EX_PASS)
    arm("a token leaked on GET /api/config fails naming the route", ("GET", "/api/config", SYN_TOKEN), EX_FAIL,
        must="GET /api/config")
    arm("a URL-encoded second token leaked on GET /api/status fails", ("GET", "/api/status", urllib.parse.quote(SYN_TOKEN2, safe="")),
        EX_FAIL, must="GET /api/status")
    arm("a base64 Vane password leaked on POST /api/memory fails", ("POST", "/api/memory",
        base64.b64encode(SYN_VANE.encode()).decode()), EX_FAIL, must="POST /api/memory")
    arm("the mailbox app password echoed by POST /api/assistant-mailbox/self-test fails naming the route",
        ("POST", "/api/assistant-mailbox/self-test", SYN_MAILBOX), EX_FAIL, must="POST /api/assistant-mailbox/self-test")
    arm("an enabled mailbox whose Keychain item is unreadable is CANNOT-RUN", None, EX_CANNOT,
        must="could not be read from the Keychain", reader=lambda a: None)
    arm("a control that sees 0 is CANNOT-RUN, never PASS", None, EX_CANNOT, control_file=blind,
        must="positive control saw 0")
    arm("no route responding is CANNOT-RUN", None, EX_CANNOT, bases=["http://127.0.0.1:9"])
    res = sweep(os.path.join(d, "absent.toml"), con, ["http://127.0.0.1:9"])
    good = judge(res)[1] == EX_CANNOT
    print("  %s an unreadable config.toml is CANNOT-RUN" % ("ok    " if good else "FAIL  "))
    ok &= good
    srv = _fake_server(None)
    res = sweep(cfg, con, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3, mailbox_reader=fake_keychain)
    srv.shutdown()
    sent = {(r["method"], r["path"], r["auth"]) for r in res["rows"]}
    good = ("GET", "/doctor-only", "none") not in sent and not any(r["path"] == "/admin/shutdown" for r in res["rows"]) \
        and ("DELETE", "/api/devices/{id}", "paired_bearer") not in sent and ("DELETE", "/api/devices/{id}", "none") in sent \
        and ("POST", "/api/assistant-mailbox/self-test", "paired_bearer") in sent
    print("  %s routes come from the contract's gateway listener; shutdown never sent; authed DELETE skipped" % (
        "ok    " if good else "FAIL  "))
    ok &= good
    # Branch 2: a REAL provider host. The self-test is never POSTed (no
    # outward mail), the judge says CANNOT with the reason, a read-only GET is
    # swept, and the overall verdict comes from everything else.
    d2 = tempfile.mkdtemp(prefix="secret-sweep-st2-")
    cfg2, con2, _ = write_fixture(d2, mailbox_host="imap.mail.me.com")
    srv = _fake_server(None)
    res = sweep(cfg2, con2, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3, mailbox_reader=fake_keychain)
    srv.shutdown()
    lines, rc = judge(res)
    text = "\n".join(lines)
    posted = [h for h in srv.hits if h == ("POST", "/api/assistant-mailbox/self-test")]
    got = [h for h in srv.hits if h == ("GET", "/api/assistant-mailbox/self-test")]
    good = rc == EX_PASS and not posted and len(got) == 2 and ("CANNOT POST /api/assistant-mailbox/self-test" in text) \
        and NOT_LOOPBACK in text
    print("  %s a real mailbox host: self-test never POSTed (%d), read-only GET swept (%d), CANNOT names the reason" % (
        "ok    " if good else "FAIL  ", len(posted), len(got)))
    ok &= good
    srv = _fake_server(("GET", "/api/assistant-mailbox/self-test", SYN_MAILBOX))
    res = sweep(cfg2, con2, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3, mailbox_reader=fake_keychain)
    srv.shutdown()
    lines, rc = judge(res)
    good = rc == EX_FAIL and "FAIL   GET /api/assistant-mailbox/self-test" in "\n".join(lines) \
        and not any(h == ("POST", "/api/assistant-mailbox/self-test") for h in srv.hits)
    print("  %s a real mailbox host: the read-only check still catches the password on that path" % (
        "ok    " if good else "FAIL  "))
    ok &= good
    # Branch 1 control: loopback hosts DO post it (the mailsim case).
    srv = _fake_server(None)
    sweep(cfg, con, ["http://127.0.0.1:%d" % srv.server_address[1]], timeout=3, mailbox_reader=fake_keychain)
    srv.shutdown()
    good = ("POST", "/api/assistant-mailbox/self-test") in srv.hits
    print("  %s loopback mailbox hosts: the self-test IS posted" % ("ok    " if good else "FAIL  "))
    ok &= good
    for dd in (d, d2):
        for f in os.listdir(dd):
            os.unlink(os.path.join(dd, f))
        os.rmdir(dd)
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
        a = ap.parse_args(argv[1:])
        bases = a.base
        if not bases:
            bases, has_lan = default_bases()
            if not has_lan:
                print(json.dumps({"cannot": "no LAN address on en0/en1 and OSTLER_PAIR_PROBE_HOST unset: the :8443 LAN surface cannot be swept"}))
                return EX_PASS
        print(json.dumps(sweep(a.config, a.contract, bases, control_file=a.control_file)))
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
