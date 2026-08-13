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

# FIX-RT2-F5: cross-origin CSRF write defence. The Host allowlist stops
# DNS-rebind but NOT a plain cross-origin form POST (a CORS simple
# request), so the config must ALSO reject a foreign Origin header. An
# Origin allowlist map + an Origin-based 403 guard must be present in
# BOTH server blocks (a Host-only config would let attacker.com wipe the
# graph via update=DROP ALL).
grep -q 'map \$http_origin \$ostler_store_origin_ok' "$NGCONF" \
    || fail "FIX-RT2-F5: Origin allowlist map missing -- cross-origin CSRF write not blocked"
# The map must allow an ABSENT origin (non-browser clients send none)
# and local origins, but default-deny a foreign origin.
grep -qE '""[[:space:]]+1;' "$NGCONF" \
    || fail "FIX-RT2-F5: empty/absent Origin not explicitly allowed (would 403 legit Python clients)"
grep -qF 'https?://(localhost' "$NGCONF" \
    || fail "FIX-RT2-F5: local Origin allowlist regex missing"
# Both server blocks must gate on the origin map, not just the host map.
origin_guards="$(grep -c 'if (\$ostler_store_origin_ok = 0) { return 403; }' "$NGCONF" || true)"
[[ "$origin_guards" -ge 2 ]] \
    || fail "FIX-RT2-F5: expected the Origin 403 guard in BOTH server blocks (found ${origin_guards})"

echo "PASS [structure]: store-proxy fronts 6333+7878, stores no longer publish them, Host allowlist + Origin(CSRF) allowlist + 403 + transparent passthrough present."

# ── Part 2: behaviour (docker) ───────────────────────────────────
#
# EXIT STATES, and this test used to conflate all three (v1018-D677):
#   0  structural checks passed; behaviour proved, or explicitly declared
#      NOT RUN with the coverage gap named
#   1  an assertion FAILED -- the proxy really does the wrong thing
#   2  the behavioural half was attempted and the ENVIRONMENT broke
#
# It previously exited 0 when docker was absent, so on any box without docker
# the behavioural half silently did not run and the exit code said PASS --
# cannot-verify presented as verified. And it exited 1 when the mock failed to
# come up, presenting a could-not-run as a finding. Both directions, one file.
unavailable() { echo "UNAVAILABLE [behaviour]: $*" >&2
                echo "  This is NOT a pass and NOT a finding: the behavioural half could not run." >&2
                exit 2; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    # Deliberate 0, not 2: the structural half is the part CI wires (hosted
    # macOS runners have no docker daemon), and it genuinely passed. The
    # coverage gap is named on the way out rather than swallowed.
    echo "PASS [structure only]: docker unavailable, so Host-allowlist BEHAVIOUR was NOT PROVED."
    echo "  Run this on a box with docker to exercise the 403/200 matrix."
    exit 0
fi

WORK="$(mktemp -d)"
NET="ostler-sp-selftest-$$"
IMG="ostler-storeproxy-selftest-$$"
MOCK="sp-qdrant-$$"
PORT=16433
# THE CLEANUP USED TO FORCE-REMOVE A CONTAINER LITERALLY NAMED `qdrant`.
# Every other resource here is $$-namespaced; the one that was not is the name
# of this project's production vector store. On the Hub Mac -- THE machine --
# this trap deleted the live Qdrant holding the operator's vectors, and the
# name collision also stopped the mock being created in the first place, which
# is how it surfaced ("proxy/mock never became ready").
#
# The mock must ANSWER to the hostname qdrant, because the generated nginx
# upstream says http://qdrant:80. That is what --network-alias is for: the
# alias is scoped to this throwaway network, the container name is not shared.
# Nothing here now removes a container it did not create.
bcleanup() {
    docker rm -f "sp-proxy-$$" "$MOCK" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker rmi -f "$IMG" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap 'bcleanup; rm -f "$COMPOSE" "$NGCONF"' EXIT

# Point the upstreams at a mock's :80 (the Host-validation logic is
# identical regardless of upstream port; the mock just proves
# passthrough reaches an upstream).
sed 's#http://qdrant:6333#http://qdrant:80#; s#http://oxigraph:7878#http://oxigraph:80#' "$NGCONF" > "$WORK/nginx.conf"

# The store-proxy config ends with `include /etc/nginx/ostler-wiki-gate.conf;`
# (wiki tailnet gate, v1.0.17). Without that file nginx refuses to start, so
# the mock never came up and the run died at the readiness loop -- the second
# reason this test could not pass. The include landed after the test was
# written and nobody found out, because the test has never run.
#
# Extract the REAL shipped placeholder rather than touching an empty file:
# install.sh writes it fail-closed (comments only, nothing listening) until
# Tailscale resolves an owner, so it is both faithful and inert here.
awk '/ostler-wiki-gate.conf" <<'"'"'NGINXWIKIEOF'"'"'/{c=1;next} /^NGINXWIKIEOF$/{c=0} c' \
    "$INSTALL_SCRIPT" > "$WORK/wikigate.conf"
[[ -s "$WORK/wikigate.conf" ]] \
    || unavailable "could not extract the ostler-wiki-gate.conf placeholder (NGINXWIKIEOF heredoc moved?)"
if grep -qvE '^[[:space:]]*(#|$)' "$WORK/wikigate.conf"; then
    fail "the shipped ostler-wiki-gate.conf placeholder is NOT comments-only -- it should be fail-closed until an owner is resolved"
fi

printf 'FROM nginx:1.27-alpine\nCOPY nginx.conf /etc/nginx/nginx.conf\nCOPY wikigate.conf /etc/nginx/ostler-wiki-gate.conf\n' > "$WORK/Dockerfile"
docker build -q -t "$IMG" "$WORK" >/dev/null 2>&1 \
    || unavailable "docker build failed (offline? no nginx:1.27-alpine?)"

docker network create "$NET" >/dev/null 2>&1 \
    || unavailable "could not create throwaway network $NET"
# --network-alias, not --name: the upstream resolves `qdrant` on this network
# without the container claiming that name globally. See the cleanup note.
docker run -d --name "$MOCK" --network "$NET" --network-alias qdrant \
    nginx:1.27-alpine >/dev/null 2>&1 \
    || unavailable "could not start the upstream mock $MOCK"
docker run -d --name "sp-proxy-$$" --network "$NET" \
    -p "127.0.0.1:${PORT}:6333" "$IMG" >/dev/null 2>&1 \
    || unavailable "could not start the proxy container"

ready=false
for _ in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1:${PORT}/" || true)" == "200" ]]; then
        ready=true; break
    fi
    sleep 0.5
done
# Never became ready = the harness did not come up. That is an environment
# failure, not evidence the proxy allowlist is wrong, so it is 2 and not 1.
[[ "$ready" == true ]] || unavailable "proxy/mock never became ready after 15s"

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

# FIX-RT2-F5: cross-origin CSRF. Host stays allowlisted (localhost) in
# every case here -- we vary ONLY the Origin header, which is exactly the
# browser-CSRF shape the Host map cannot see. A foreign Origin must 403;
# an absent Origin (non-browser client) and a local Origin must pass.
ocheck() { # $1 = Origin (empty => header omitted), $2 = expected, $3 = label
    local got
    if [[ -z "$1" ]]; then
        got="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1:${PORT}/")"
    else
        got="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' -H "Origin: $1" "http://127.0.0.1:${PORT}/")"
    fi
    [[ "$got" == "$2" ]] || fail "$3: Origin '${1:-<none>}' returned $got, expected $2"
    echo "  ok: Origin '${1:-<none>}' -> $got ($3)"
}
ocheck ""                        200 "absent Origin (non-browser client) passes"
ocheck "http://localhost:8044"   200 "local wiki origin passes"
ocheck "http://127.0.0.1:8044"   200 "local loopback-IP origin passes"
ocheck "https://evil.example"    403 "cross-origin CSRF blocked"
ocheck "http://attacker.com"     403 "cross-origin CSRF (http) blocked"
ocheck "http://localhost.evil.com" 403 "origin suffix-spoof blocked"

echo "PASS [behaviour]: bad Host -> 403; foreign Origin -> 403; loopback/service Host + absent/local Origin -> transparent passthrough."
