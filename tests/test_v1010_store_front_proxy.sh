#!/usr/bin/env bash
#
# tests/test_v1010_store_front_proxy.sh
#
# FIX 2b (v1.0.10 security lockdown -- Host-header-validation reverse
# proxy fronting the HTTP data stores; Andy's decision, full native
# token-auth deferred to v1.0.1).
#
# The two HTTP stores (Qdrant REST :6333, Oxigraph :7878) are no
# longer published to the host directly. A loopback nginx (store-proxy)
# owns those host ports and validates the Host header: loopback /
# compose-service names pass through transparently; anything else gets
# 403. This defeats DNS-rebind (the remote vector) with NO client-side
# changes.
#
# Part 1 (always runs): structural checks -- pure shell + grep/awk.
# Part 2 (runs iff docker is present): behavioural proof that a bad
# Host gets 403 and localhost passes through. Self-skips without docker
# so CI without a daemon still exercises Part 1.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

# ── Part 1: structure ────────────────────────────────────────────
COMPOSE="$(mktemp)"; NGCONF="$(mktemp)"
trap 'rm -f "$COMPOSE" "$NGCONF"' EXIT
awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL_SCRIPT" > "$COMPOSE"
[[ -s "$COMPOSE" ]] || fail "compose heredoc body empty"

# store-proxy service exists and publishes the two HTTP store ports on
# loopback.
grep -q 'store-proxy:' "$COMPOSE" || fail "store-proxy service missing from compose"
grep -q 'container_name: ostler-store-proxy' "$COMPOSE" || fail "store-proxy container_name missing"
grep -qF '"127.0.0.1:6333:6333"' "$COMPOSE" || fail "store-proxy does not publish 127.0.0.1:6333"
grep -qF '"127.0.0.1:7878:7878"' "$COMPOSE" || fail "store-proxy does not publish 127.0.0.1:7878"

# Qdrant/Oxigraph must NOT publish their HTTP ports directly any more
# (would bypass the Host check). Confirm the only 6333/7878 host maps
# belong to the store-proxy block.
qdrant_block="$(awk '/^  qdrant:/{c=1} c&&/^  [a-z]/&&!/^  qdrant:/{c=0} c' "$COMPOSE")"
oxi_block="$(awk '/^  oxigraph:/{c=1} c&&/^  [a-z]/&&!/^  oxigraph:/{c=0} c' "$COMPOSE")"
echo "$qdrant_block" | grep -qF '6333:6333' && fail "qdrant still publishes 6333 to host (bypasses the proxy)"
echo "$oxi_block" | grep -qF '7878:7878' && fail "oxigraph still publishes 7878 to host (bypasses the proxy)"
# gRPC 6334 stays direct on qdrant (documented -- not browser-rebindable).
echo "$qdrant_block" | grep -qF '6334:6334' || fail "qdrant no longer exposes gRPC 6334 (regression)"

# store-proxy depends on both upstreams (so nginx can resolve them).
awk '/store-proxy:/{c=1} c&&/depends_on:/{d=1} c&&/- qdrant/{q=1} c&&/- oxigraph/{o=1} END{exit (d&&q&&o)?0:1}' "$COMPOSE" \
    || fail "store-proxy missing depends_on qdrant + oxigraph"

# Both compose service lists (pull + up) include store-proxy.
grep -q 'docker compose pull qdrant oxigraph redis store-proxy' "$INSTALL_SCRIPT" \
    || fail "store-proxy not in the compose pull list"
grep -q 'docker compose up -d qdrant oxigraph redis store-proxy' "$INSTALL_SCRIPT" \
    || fail "store-proxy not in the compose up list"

# Extract the nginx config heredoc + assert the security-relevant bits.
awk '/ostler-store-proxy.conf" <<'\''NGINXEOF'\''/{c=1;next} /^NGINXEOF$/{c=0} c' "$INSTALL_SCRIPT" > "$NGCONF"
[[ -s "$NGCONF" ]] || fail "nginx store-proxy config heredoc (NGINXEOF) not found / empty"
grep -q 'map \$host \$ostler_store_host_ok' "$NGCONF" || fail "Host allowlist map missing"
grep -q 'return 403;' "$NGCONF" || fail "config never returns 403 for a bad Host"
grep -q 'proxy_pass \$ostler_qdrant_upstream\$request_uri;' "$NGCONF" || fail "qdrant passthrough missing"
grep -q 'proxy_pass \$ostler_oxigraph_upstream\$request_uri;' "$NGCONF" || fail "oxigraph passthrough missing"
grep -q 'client_max_body_size 0;' "$NGCONF" || fail "no unlimited body size -- large Qdrant/SPARQL bodies would 413 (not transparent)"
grep -q 'listen 6333;' "$NGCONF" || fail "proxy does not listen on 6333"
grep -q 'listen 7878;' "$NGCONF" || fail "proxy does not listen on 7878"

echo "PASS [structure]: store-proxy fronts 6333+7878, stores no longer publish them, Host allowlist + 403 + transparent passthrough present."

# ── Part 2: behaviour (docker) ───────────────────────────────────
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP [behaviour]: docker not available -- structural checks passed."
    exit 0
fi

WORK="$(mktemp -d)"
NET="ostler-sp-selftest-$$"
IMG="ostler-storeproxy-selftest-$$"
PORT=16433
bcleanup() {
    docker rm -f "sp-proxy-$$" "qdrant" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker rmi -f "$IMG" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap 'bcleanup; rm -f "$COMPOSE" "$NGCONF"' EXIT

# Point the upstreams at a mock's :80 (the Host-validation logic is
# identical regardless of upstream port; the mock just proves
# passthrough reaches an upstream).
sed 's#http://qdrant:6333#http://qdrant:80#; s#http://oxigraph:7878#http://oxigraph:80#' "$NGCONF" > "$WORK/nginx.conf"
printf 'FROM nginx:1.27-alpine\nCOPY nginx.conf /etc/nginx/nginx.conf\n' > "$WORK/Dockerfile"
docker build -q -t "$IMG" "$WORK" >/dev/null 2>&1 || { echo "SKIP [behaviour]: docker build failed (offline?)."; exit 0; }

docker network create "$NET" >/dev/null 2>&1
docker run -d --name qdrant --network "$NET" nginx:1.27-alpine >/dev/null 2>&1
docker run -d --name "sp-proxy-$$" --network "$NET" -p "127.0.0.1:${PORT}:6333" "$IMG" >/dev/null 2>&1

ready=false
for _ in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1:${PORT}/" || true)" == "200" ]]; then
        ready=true; break
    fi
    sleep 0.5
done
[[ "$ready" == true ]] || fail "proxy/mock never became ready"

check() { # $1 = Host, $2 = expected code, $3 = label
    local got; got="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:${PORT}/")"
    [[ "$got" == "$2" ]] || fail "$3: Host '$1' returned $got, expected $2"
    echo "  ok: Host '$1' -> $got ($3)"
}
check "localhost"          200 "loopback passthrough"
check "127.0.0.1"          200 "loopback IP passthrough"
check "qdrant"             200 "internal service name passthrough"
check "evil.example"       403 "DNS-rebind blocked"
check "attacker.com:6333"  403 "DNS-rebind with port blocked"
check "127.0.0.1.evil.com" 403 "subdomain spoof blocked"

echo "PASS [behaviour]: bad Host -> 403, loopback/service Host -> transparent passthrough."
