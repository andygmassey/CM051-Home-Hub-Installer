#!/usr/bin/env bash
# Walk probes must reach forwarded loopback ports even when the driver carries
# HTTP_PROXY with no NO_PROXY (measured 2026-10-03: a laptop running a local
# privacy proxy turned every 127.0.0.1 call into "503 Forwarding failure",
# which read as the product failing). Two halves:
#   1. lib/probe.sh exports a loopback NO_PROXY, so curl and Python urllib in
#      every probe bypass the proxy for 127.0.0.1.
#   2. lib/customer_read.py uses a no-proxy opener for loopback only (its own
#      --self-test arm, run here).
# CONTROL: with the same fake proxy and without probe.sh, the same local call
# must FAIL, or the fake proxy proved nothing.
set -u
cd "$(dirname "$0")/.."
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
up=0
for _ in $(seq 1 30); do /usr/bin/curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:${PORT}/" && { up=1; break; }; sleep 0.2; done
[ "$up" = 1 ] || { echo "CANNOT-RUN: the local test server did not start"; exit 2; }

run() {  # $1 = 1 to source probe.sh first
    env -u NO_PROXY -u no_proxy HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
        bash -c '
        [ "$1" = 1 ] && . scripts/box_walk_probes/lib/probe.sh
        c=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$2/")
        p=$(python3 -c "import urllib.request,sys; print(urllib.request.urlopen(sys.argv[1], timeout=3).status)" "http://127.0.0.1:$2/" 2>/dev/null || echo ERR)
        echo "$c $p"' _ "$1" "$PORT"
}
read -r cc cp < <(run 0)
read -r bc bp < <(run 1)
{ [ "$cc" != 200 ] && [ "$cp" != 200 ]; } && ok "control: without probe.sh the fake proxy breaks the call (curl $cc, urllib $cp)" \
    || bad "control did not fail (curl $cc, urllib $cp): the fake proxy is not in effect, so the next arm proves nothing"
[ "$bc" = 200 ] && ok "with probe.sh, curl reaches 127.0.0.1 through a dead HTTP_PROXY (200)" || bad "with probe.sh, curl got $bc"
[ "$bp" = 200 ] && ok "with probe.sh, Python urllib reaches 127.0.0.1 through a dead HTTP_PROXY (200)" || bad "with probe.sh, urllib got $bp"

out=$(python3 scripts/box_walk_probes/lib/customer_read.py --self-test 2>&1); rc=$?
printf '%s\n' "$out" | grep -q "a loopback call bypasses a dead HTTP_PROXY" && [ "$rc" = 0 ] \
    && ok "customer_read.py: its own loopback-bypass arm passes" || bad "customer_read.py self-test rc=$rc or the bypass arm is missing"

[ "$FAIL" = 0 ] && echo "PASS: walk probes bypass a local proxy for loopback" || { echo "FAIL"; exit 1; }
