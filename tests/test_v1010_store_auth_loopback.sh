#!/usr/bin/env bash
#
# tests/test_v1010_store_auth_loopback.sh
#
# FIX 2 (v1.0.10 security lockdown -- unauthenticated data stores).
#
# The operative control is that no Qdrant / Oxigraph / Redis host port
# is reachable from off the box. On top of that we make the stack
# auth-READY: per-install secrets are generated and the compose is
# parameterised so native auth is a single-switch flip.
#
# ⚠️ REWRITTEN 2026-08-28 for #550. Two of this file's assertions were
# pinned to the v1.0.10 SPELLING of the remedy rather than to the
# property, and both would have opposed the #550 fix. See the notes at
# each one. The security assertions are now MONOTONE with the fix
# direction: making a store less reachable can never red them.
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

# 1. SECURITY: no data store is reachable from off the box.
#
# ⚠️ This used to REQUIRE the literal "127.0.0.1:<port>:<port>" to be
#    PRESENT for all three stores, and failed with "missing / not
#    loopback-only". That froze an IMPLEMENTATION, not the property the
#    comment claimed:
#
#        not reachable off-box    <- the PROPERTY
#        published on 127.0.0.1   <- ONE way to satisfy it
#        not published at all     <- ANOTHER way, and STRICTLY SAFER
#
#    Measured 2026-08-28: with 7878 unpublished entirely, the old form
#    failed with "store host map 127.0.0.1:7878:7878 missing". A test
#    written to stop a store being exposed would have blocked the fix
#    that stops a store being exposed.
#
#    Counted with `grep -c`, never a piped `grep -q`: under `set -o
#    pipefail` (line 20) a piped `grep -q` exits on first match,
#    SIGPIPEs the producer, and the pipeline reports FAILURE for a
#    needle that IS present -- inverting the answer on exactly the
#    input this exists to catch. `|| true` because grep exits 1 on a
#    legitimate zero and `set -e` would abort on the safest state.
for port in 6333 7878 6379; do
    published="$(grep -cE "^[[:space:]]*-[[:space:]]*\"[^\"]*:${port}\"" "$COMPOSE" || true)"
    loopback="$(grep -cE "^[[:space:]]*-[[:space:]]*\"127\.0\.0\.1:[0-9]+:${port}\"" "$COMPOSE" || true)"
    if [[ "$published" -eq 0 ]]; then
        echo "ok: ${port} is not published to the host at all (safer than loopback)"
    elif [[ "$published" -eq "$loopback" ]]; then
        echo "ok: ${port} publishes ${published}x, all 127.0.0.1-bound"
    else
        fail "${port} has ${published} host publish(es) but only ${loopback} are
      127.0.0.1-bound -- at least one is reachable off-box"
    fi
done

# 1b. FUNCTIONAL, NOT SECURITY: something still depends on these ports.
#
# @TNM's catch on the rewrite above, and it is correct. The old
# assertion did TWO jobs at once. Making the security half MONOTONE
# (absent is as good as loopback) silently dropped the other half:
# proof that a host client still has a route at all. Losing that is how
# a "fix" ships that closes the hole by breaking the product.
#
# ⚠️ THESE ROWS ARE NOT SECURITY INVARIANTS. Each says only "something
# still depends on this port TODAY, and here is what". Delete a row in
# the SAME PR that removes its last consumer -- deliberately, with the
# reason visible in the diff. Same contract as MUST_STILL_PUBLISH in
# tests/test_stores_publish_no_host_port.sh.
#
# The difference the split buys: a #550 PR that closes a port now
# deletes a row that SAYS it is a functional dependency, instead of
# editing a line whose failure message says "off-box reachable". The
# first reads as "the last consumer is gone"; the second is
# indistinguishable on review from weakening a security gate to make it
# pass, which is the one move we have agreed never to make.
STILL_DEPENDED_ON=(
    "6333"   # store-proxy -> Qdrant REST. Host clients have no other
             # route today; the #550 answer here is the API key, not an
             # unpublish. Delete this row if that ever changes.
    "7878"   # store-proxy -> Oxigraph SPARQL. Same shape: the #550
             # answer is the proxy credential, not an unpublish.
    "6379"   # Redis/valkey. requirepass is threaded; the Doctor probes
             # this port directly, so an unpublish needs that probe
             # repointed in the same PR.
)
for port in "${STILL_DEPENDED_ON[@]}"; do
    n="$(grep -cE "^[[:space:]]*-[[:space:]]*\"127\.0\.0\.1:[0-9]+:${port}\"" "$COMPOSE" || true)"
    if [[ "$n" -gt 0 ]]; then
        echo "ok: ${port} still has a host route -- its consumer keeps working"
    else
        fail "${port} is no longer published, but a row in STILL_DEPENDED_ON
      says something needs it. If the last consumer really is gone,
      delete that row IN THIS PR and say why. Do not silence this by
      re-adding the publish."
    fi
done

# No store may be published on a wildcard / all-interfaces host bind.
# Subsumed by the loop above; kept for the specific diagnosis.
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

# 4. The enforcement switch HAS a default -- not which default it is.
#
# ⚠️ This used to require the literal `OSTLER_STORE_AUTH_ENFORCE:-0`,
#    which asserted enforcement stays OFF. That default was right for
#    v1.0.10 and the reason was stated: the pinned clients sent no
#    credentials, so flipping it would have redded the box-walk.
#    Turning it ON is now the explicit object of #550, so a test
#    demanding it stay off opposes the fix. This is the assertion that
#    certainly blocks the plan -- the port assertions above only bite
#    if we choose to unpublish rather than credential.
#
#    What must NOT regress is that the switch has a default at all: an
#    unset ${OSTLER_STORE_AUTH_ENFORCE} under `set -u` aborts install.
grep -qE 'OSTLER_STORE_AUTH_ENFORCE:-[01]' "$INSTALL_SCRIPT" \
    || fail "store auth enforcement switch has no default
      (OSTLER_STORE_AUTH_ENFORCE:-0 or :-1). Unset under set -u would
      abort the install."

echo "PASS: no store is reachable off-box, consumers keep their routes, auth-ready (Qdrant key + Redis requirepass), secrets seeded, enforcement switch has a default."
