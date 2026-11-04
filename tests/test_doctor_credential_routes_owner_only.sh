#!/usr/bin/env bash
# S1 (red team v1.0.124): the Doctor's five credential routes answer ONLY the
# Mac's owner. A second macOS account and a tailnet peer relayed onto loopback
# by tailscaled are refused, and the owner still gets every credential.
#
#   POST /api/v1/auth/chat-token   GET /api/v1/extension/token
#   GET  /api/v1/pair/status       POST /api/v1/pair/regenerate
#   GET  /api/v1/whatsapp/pair
#
# Four arms, all against the REAL code:
#   A  verdict() matrix: owner, other uid, invisible peer, forwarder,
#      non-loopback source, a lookup that throws, IPv4-mapped loopback.
#   B  the REAL kernel lookup (lsof on macOS, /proc/net/tcp on Linux) finds
#      this process on a live loopback connection; control: a port with no
#      connection finds nothing.
#   C  the REAL Doctor over REAL HTTP, the caller a REAL curl process:
#        owner                               -> 200 on all five
#        second account (the curl's uid is not the Doctor's owner uid)
#                                            -> 403 peer-not-owner, no secret
#        tailnet peer (curl through a real TCP relay process, the relay's
#        name registered as a forwarder, as tailscaled is)
#                                            -> 403 peer-is-forwarder
#        control: a non-credential route through the same relay is NOT 403.
#   The second-account arm cannot create a real macOS account without root;
#   it swaps the owner uid the Doctor compares against, so the real curl
#   becomes "someone else". The walk probe does it with a real account.
#
# exit 0 GREEN, 1 RED, 2 CANNOT-RUN.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${OSTLER_TEST_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: no curl"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "CANNOT-RUN: no perl (the relay)"; exit 2; }
if ! "$PY" -c 'import fastapi, uvicorn, httpx, qrcode'; then
    echo "CANNOT-RUN: the Doctor's deps are not importable by ${PY}. NOTHING was examined."
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export no_proxy='*' NO_PROXY='*'

AGENT="${REPO}/vendor/doctor/agent" EDITOR_HOME="${REPO}/vendor/cm059_editor" TMPD="$TMP" \
"$PY" - <<'PYEOF'
import json, os, secrets, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

AGENT = os.environ["AGENT"]; TMP = os.environ["TMPD"]
sys.path.insert(0, AGENT); os.chdir(AGENT)
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

import owner_peer as op
ME = os.geteuid()

print("== A: verdict() matrix ==")
real_lookup = op._lookup
cases = [
    ("owner, ordinary process",      ("127.0.0.1", 5000), op.Peer(1, ME, "curl"), None),
    ("second account",               ("127.0.0.1", 5000), op.Peer(2, ME + 1, "curl"), "peer-not-owner"),
    ("invisible peer (other account under unprivileged lsof)", ("127.0.0.1", 5000), None, "peer-unknown"),
    ("tailscaled relay, owner uid",  ("127.0.0.1", 5000), op.Peer(3, ME, "tailscaled"), "peer-is-forwarder"),
    ("lima host agent, owner uid",   ("127.0.0.1", 5000), op.Peer(3, ME, "limactl"), "peer-is-forwarder"),
    ("owner uid, process unnamed",   ("127.0.0.1", 5000), op.Peer(None, ME, None), "peer-unknown"),
    ("tailnet source address",       ("100.64.0.7", 5000), op.Peer(1, ME, "curl"), "not-loopback"),
    ("LAN source address",           ("192.0.2.10", 5000), op.Peer(1, ME, "curl"), "not-loopback"),
    ("IPv4-mapped loopback, owner",  ("::ffff:127.0.0.1", 5000), op.Peer(1, ME, "curl"), None),
    ("no client in scope",           None, op.Peer(1, ME, "curl"), "peer-unknown"),
]
for name, client, peer, want in cases:
    op._lookup = lambda h, c, s, _p=peer: _p
    got = op.verdict(client, ("127.0.0.1", 8089))
    (ok if got == want else bad)(f"{name}: want {want} got {got}")
def boom(*a): raise RuntimeError("lsof exploded")
op._lookup = boom
got = op.verdict(("127.0.0.1", 5000), ("127.0.0.1", 8089))
(ok if got == "peer-unknown" else bad)(f"a lookup that throws fails closed: got {got}")
op._lookup = real_lookup

print("== B: the real kernel lookup ==")
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1); sp = srv.getsockname()[1]
cli = socket.socket(); cli.connect(("127.0.0.1", sp)); acc, _ = srv.accept(); cp = cli.getsockname()[1]
peer = op.lookup_peer("127.0.0.1", cp, sp)
if peer is None:
    bad(f"lookup_peer found nothing for a live connection on {sys.platform}: the instrument is blind")
else:
    (ok if peer.uid == ME else bad)(f"peer uid {peer.uid} == this process {ME}")
    (ok if peer.pid == os.getpid() else bad)(f"peer pid {peer.pid} == this process {os.getpid()}")
    (ok if peer.command else bad)(f"peer command named: {peer.command!r}")
ctl = op.lookup_peer("127.0.0.1", free_port(), sp)
(ok if ctl is None else bad)(f"control: a port with no connection finds no peer (got {ctl})")
cli.close(); acc.close(); srv.close()

print("== C: the real Doctor, real HTTP, a real curl ==")
STUB = free_port()
class H(BaseHTTPRequestHandler):
    def _j(self, st, p):
        b = json.dumps(p).encode(); self.send_response(st)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        if self.path == "/api/pairing/initiate": self._j(200, {"pairing_code": secrets.token_hex(4)})
        elif self.path == "/api/pair": self._j(200, {"token": secrets.token_hex(16)})
        else: self._j(404, {})
    def log_message(self, *a): pass
threading.Thread(target=HTTPServer(("127.0.0.1", STUB), H).serve_forever, daemon=True).start()
adm = os.path.join(TMP, "admin_token"); open(adm, "w").write(secrets.token_hex(16)); os.chmod(adm, 0o600)
os.makedirs(os.path.join(TMP, "editor"), exist_ok=True)
os.environ.update({
    "OSTLER_CHAT_GATEWAY_PORT": str(STUB), "OSTLER_CHAT_ADMIN_TOKEN_FILE": adm,
    "OSTLER_EDITOR_HOME": os.environ["EDITOR_HOME"], "OSTLER_EDITOR_DIR": os.path.join(TMP, "editor"),
    "OSTLER_EXTENSION_TOKEN": "not-a-real-token-%d" % os.getpid(),
})
import uvicorn, web_ui
PORT = free_port()
server = uvicorn.Server(uvicorn.Config(web_ui.app, host="127.0.0.1", port=PORT, log_level="warning"))
threading.Thread(target=server.run, daemon=True).start()
for _ in range(100):
    if server.started: break
    time.sleep(0.1)
if not server.started:
    print("CANNOT-RUN: the Doctor did not start"); sys.exit(2)

RELAY = free_port()
relay = subprocess.Popen(["perl", "-MIO::Socket::INET", "-MIO::Select", "-e", r'''
my ($lp,$tp)=@ARGV; my $l=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>$lp,Listen=>5,ReuseAddr=>1) or die;
while(my $c=$l->accept){ if(fork==0){ my $t=IO::Socket::INET->new(PeerAddr=>"127.0.0.1",PeerPort=>$tp) or exit;
 my $s=IO::Select->new($c,$t); my $buf; while(my @r=$s->can_read){ for my $h(@r){ my $o=$h==$c?$t:$c;
 my $n=sysread($h,$buf,65536); exit unless $n; syswrite($o,$buf);} } exit } }''', str(RELAY), str(PORT)])
time.sleep(0.5)

ROUTES = [
    ("POST", "/api/v1/auth/chat-token", "token"),
    ("GET",  "/api/v1/extension/token", "not-a-real-token"),
    ("GET",  "/api/v1/pair/status", None),
    ("POST", "/api/v1/pair/regenerate", None),
    ("GET",  "/api/v1/whatsapp/pair", None),
]
def curl(method, path, port):
    out = subprocess.run(["curl", "-s", "--noproxy", "*", "-m", "15", "-X", method,
                          "-H", "Host: 127.0.0.1", "-H", "Sec-Fetch-Site: same-origin",
                          "-w", "\n%{http_code}", f"http://127.0.0.1:{port}{path}"],
                         capture_output=True, text=True).stdout
    body, _, st = out.rpartition("\n"); return st, body

print("-- owner --")
for m, p, secret in ROUTES:
    st, body = curl(m, p, PORT)
    (ok if st == "200" else bad)(f"owner {m} {p}: {st}")
    if secret and secret not in body: bad(f"owner {m} {p}: the credential is not in the body")

print("-- second account (owner uid swapped so the real curl is someone else) --")
real_owner = op.owner_uid
op.owner_uid = lambda: ME + 1
for m, p, secret in ROUTES:
    st, body = curl(m, p, PORT)
    good = st == "403" and "peer-not-owner" in body
    (ok if good else bad)(f"second account {m} {p}: {st} {body[:80] if not good else 'peer-not-owner'}")
    if secret and secret in body: bad(f"LEAK: {p} refusal carries the credential")
op.owner_uid = real_owner

print("-- tailnet peer (curl -> relay process -> Doctor; the relay is a forwarder, like tailscaled) --")
real_fw = op.FORWARDERS
op.FORWARDERS = real_fw | {"perl"}
for m, p, secret in ROUTES:
    st, body = curl(m, p, RELAY)
    good = st == "403" and "peer-is-forwarder" in body
    (ok if good else bad)(f"tailnet relay {m} {p}: {st} {body[:80] if not good else 'peer-is-forwarder'}")
st, _ = curl("GET", "/doctor/api/health", RELAY)
(ok if st == "200" else bad)(f"control: a non-credential route through the relay still answers ({st})")
st, _ = curl("GET", "/api/v1/pair/status", PORT)
(ok if st == "200" else bad)(f"control: the owner, direct, still gets pair/status ({st})")
op.FORWARDERS = real_fw

relay.terminate(); server.should_exit = True
print(f"RESULT: {PASS} passed, {FAIL} failed")
if PASS == 0: print("CANNOT-RUN: nothing examined"); sys.exit(2)
sys.exit(1 if FAIL else 0)
PYEOF
rc=$?
[ "$rc" -eq 0 ] && echo GREEN
exit "$rc"
