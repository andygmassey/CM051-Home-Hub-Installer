#!/usr/bin/env bash
#
# tests/test_v1010_store_auth_loopback.sh
#
# FIX 2 (v1.0.10 security lockdown -- unauthenticated data stores).
#
# The operative control is that Qdrant / Oxigraph / Redis host port
# maps are 127.0.0.1-only (nothing off-box). On top of that we make
# the stack auth-READY: per-install secrets are generated and the
# compose is parameterised so native auth is a single-switch flip.
# Enforcement is DEFAULT-OFF for v1.0.10 because the pinned vendored
# clients do not send credentials (flipping it on would red the
# box-walk). This test locks all of that.
#
# Pure shell + grep / awk. No docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

# Extract the docker-compose heredoc body.
COMPOSE="$(mktemp)"; trap 'rm -f "$COMPOSE"' EXIT
awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL_SCRIPT" > "$COMPOSE"
[[ -s "$COMPOSE" ]] || fail "compose heredoc body empty (markers changed?)"

# 1. Loopback-only host port maps for all three stores. Guard against
#    a future edit exposing a store on 0.0.0.0 / a LAN interface.
for map in "127.0.0.1:6333:6333" "127.0.0.1:7878:7878" "127.0.0.1:6379:6379"; do
    grep -qF -- "$map" "$COMPOSE" || fail "store host map $map missing / not loopback-only"
done
# No store may be published on a wildcard / all-interfaces host bind.
if grep -Eq '"0\.0\.0\.0:(6333|7878|6379):' "$COMPOSE"; then
    fail "a data store is published on 0.0.0.0 (off-box reachable)"
fi
# A bare "6333:6333" (no host IP) also binds all interfaces -- forbid.
if grep -Eq '^\s*-\s*"(6333|6379|7878):(6333|6379|7878)"' "$COMPOSE"; then
    fail "a data store host map omits the 127.0.0.1 prefix (binds all interfaces)"
fi

# 2. Compose is auth-READY: Qdrant API-key + Redis requirepass params,
#    both interpolated from the compose .env (empty => no auth).
grep -q 'QDRANT__SERVICE__API_KEY: "\${QDRANT_API_KEY:-}"' "$COMPOSE" \
    || fail "Qdrant service missing parameterised QDRANT__SERVICE__API_KEY"
grep -q 'command: valkey-server \${REDIS_AUTH_ARGS:-}' "$COMPOSE" \
    || fail "Redis/valkey missing parameterised --requirepass via REDIS_AUTH_ARGS"

# 3. Per-install secrets are generated for all three stores.
grep -q '_seed_store_secret "qdrant_api_key"' "$INSTALL_SCRIPT" \
    || fail "qdrant_api_key secret not seeded"
grep -q '_seed_store_secret "redis_password"' "$INSTALL_SCRIPT" \
    || fail "redis_password secret not seeded"
grep -q '_seed_store_secret "oxigraph_token"' "$INSTALL_SCRIPT" \
    || fail "oxigraph_token secret not seeded"

# 4. Enforcement defaults OFF (so the pinned clients keep working /
#    box-walk stays green). The switch reads OSTLER_STORE_AUTH_ENFORCE
#    with a :-0 default.
grep -q 'OSTLER_STORE_AUTH_ENFORCE:-0' "$INSTALL_SCRIPT" \
    || fail "store auth enforcement switch missing its default-off (OSTLER_STORE_AUTH_ENFORCE:-0)"

echo "PASS: stores are loopback-only, auth-ready (Qdrant key + Redis requirepass), secrets seeded, enforcement default-off."
