#!/usr/bin/env bash
# Wiki tailnet gate guard (v1.0.17)
# =============================================================
#
# The wiki is the customer's whole personal graph rendered as a
# browsable site with no auth of its own. v1.0.10 therefore pulled it
# off Tailscale entirely. v1.0.17 puts it back, but ONLY behind an
# nginx gate that checks the identity headers `tailscale serve`
# stamps from the verified WireGuard session.
#
# Everything below is a load-bearing security property, so this guard
# does not merely grep -- it GENERATES the real config the installer
# would write and validates it with the pinned nginx binary, and it
# proves it can fail by feeding that same validator a broken file.
#
# Invariants:
#   1. No owner login  => no listener at all (fail-closed).
#   2. Owner login     => a listener that demands BOTH
#                         Tailscale-User-Login == owner AND the
#                         absence of Tailscale-Funnel-Request.
#   3. A login carrying nginx syntax is refused, not escaped.
#   4. The generated config is accepted by the pinned nginx.
#   5. :8044 is never raw-TCP served on the tailnet, and 8144 is
#      published on loopback only.
#   6. The installer never turns Funnel on.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
# Scratch INSIDE the repo, not $TMPDIR or /tmp. Docker Desktop on
# macOS shares /Users but shares neither /var/folders (where $TMPDIR
# points) nor /tmp by default, and an unshared source silently becomes
# an empty DIRECTORY inside the VM -- so the nginx validation below
# would fail on the bind mount rather than on the config, which is
# exactly the kind of check that lies to you. Under the repo it works
# on both a dev Mac and Linux CI.
TMP="$(mktemp -d "$REPO_ROOT/.wiki-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ── Extract the generator from install.sh and run it for real ──────
# Sourcing install.sh is impossible (it installs Ostler), so lift just
# the function out, between its def line and the explicit END marker.
# A column-0 `}` cannot delimit it -- the nginx heredocs are full of
# them. If either landmark moves, the extraction fails loudly rather
# than silently testing nothing.
awk '/^write_wiki_tailnet_gate\(\) \{$/{f=1} /^# --- END write_wiki_tailnet_gate ---/{exit} f{print}' \
    "$INSTALL" > "$TMP/gate_fn.sh"
grep -q '^write_wiki_tailnet_gate() {' "$TMP/gate_fn.sh" \
    || fail "could not extract write_wiki_tailnet_gate from $INSTALL"
grep -q '^# --- END write_wiki_tailnet_gate ---' "$INSTALL" \
    || fail "the END write_wiki_tailnet_gate marker is gone -- extraction is unbounded"
bash -n "$TMP/gate_fn.sh" \
    || fail "extracted write_wiki_tailnet_gate does not parse -- extraction is wrong"
pass "extracted write_wiki_tailnet_gate() from $INSTALL"

OSTLER_DIR="$TMP"
export OSTLER_DIR
# shellcheck source=/dev/null
source "$TMP/gate_fn.sh"
GATE="$TMP/ostler-wiki-gate.conf"

# ── 1. Fail-closed with no owner ───────────────────────────────────
if write_wiki_tailnet_gate ""; then
    fail "write_wiki_tailnet_gate accepted an empty owner (must return non-zero)"
fi
if grep -q "listen 8144" "$GATE"; then
    fail "empty-owner gate defines a listener -- the wiki would be exposed unauthenticated"
fi
pass "empty owner => no listener, non-zero return (fail-closed)"

# ── 2. Real owner => a gate with both limbs ────────────────────────
OWNER="someone@example.com"
write_wiki_tailnet_gate "$OWNER" || fail "write_wiki_tailnet_gate rejected a valid owner login"
grep -q "listen 8144" "$GATE" || fail "gate has no 8144 listener"
grep -q "\"${OWNER}\" 1;" "$GATE" || fail "gate does not allowlist the owner login"
grep -q 'http_tailscale_user_login' "$GATE" || fail "gate does not read Tailscale-User-Login"
grep -q 'http_tailscale_funnel_request' "$GATE" || fail "gate does not reject Funnel traffic"
grep -q 'ostler_wiki_user_ok = 0' "$GATE" || fail "gate never enforces the identity check"
grep -q 'ostler_wiki_not_funnel = 0' "$GATE" || fail "gate never enforces the Funnel check"
grep -q 'default 0;' "$GATE" || fail "gate identity map does not default to deny"
grep -q 'wiki-site:8000' "$GATE" || fail "gate does not proxy to wiki-site"
pass "owner gate demands identity AND non-Funnel, defaults to deny"

# Mixed-case logins must still match (nginx map keys are case-sensitive).
write_wiki_tailnet_gate "Someone@Example.com" || fail "mixed-case owner rejected"
grep -q '"someone@example.com" 1;' "$GATE" \
    || fail "gate does not allowlist the lowercase form of a mixed-case login"
pass "mixed-case owner login also allowlisted in lowercase"

# ── 3. Conf-injection is refused, not escaped ──────────────────────
for EVIL in \
    'a@b.com" 1; } server { listen 8145; location / { proxy_pass http://wiki-site:8000; } } map $x $y { default' \
    'a@b.com;root /etc' \
    'a@b.com
listen 9999;' \
    '~.*' \
    ''
do
    if write_wiki_tailnet_gate "$EVIL"; then
        fail "write_wiki_tailnet_gate accepted a malformed login: ${EVIL:0:40}"
    fi
    if grep -q "listen 8144" "$GATE"; then
        fail "malformed login still produced a listener: ${EVIL:0:40}"
    fi
done
pass "conf-injection and wildcard logins refused, gate left fail-closed"

# ── 4. The pinned nginx accepts the real thing ─────────────────────
NGINX_IMAGE="$(grep -oE 'nginx@sha256:[a-f0-9]{64}' "$INSTALL" | head -1)"
[[ -n "$NGINX_IMAGE" ]] || fail "could not read the pinned nginx image from $INSTALL"

if ! docker info >/dev/null 2>&1; then
    echo "skip: docker unavailable -- nginx config validation not run" >&2
else
    # Lift the main conf heredoc exactly as the installer writes it.
    awk "/^cat > \"\\\$\{OSTLER_DIR\}\/ostler-store-proxy.conf\" <<'NGINXEOF'\$/{f=1;next} f&&/^NGINXEOF\$/{exit} f{print}" \
        "$INSTALL" > "$TMP/nginx.conf"
    grep -q 'include /etc/nginx/ostler-wiki-gate.conf;' "$TMP/nginx.conf" \
        || fail "store-proxy nginx.conf does not include the wiki gate"

    write_wiki_tailnet_gate "$OWNER" || fail "regenerating the good gate failed"
    if ! docker run --rm \
            -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$GATE:/etc/nginx/ostler-wiki-gate.conf:ro" \
            "$NGINX_IMAGE" nginx -t >"$TMP/nginx-t.log" 2>&1; then
        cat "$TMP/nginx-t.log" >&2
        fail "pinned nginx rejected the generated config"
    fi
    pass "pinned nginx validates the generated store-proxy + gate config"

    # Positive control: the validator must be capable of going red.
    printf 'this is not nginx syntax {\n' > "$TMP/broken-gate.conf"
    if docker run --rm \
            -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$TMP/broken-gate.conf:/etc/nginx/ostler-wiki-gate.conf:ro" \
            "$NGINX_IMAGE" nginx -t >/dev/null 2>&1; then
        fail "nginx -t accepted a deliberately broken gate -- this check proves nothing"
    fi
    pass "positive control: nginx -t rejects a broken gate"

    # The fail-closed placeholder must ALSO be valid nginx, or a
    # customer who skips Tailscale gets a store-proxy that will not boot.
    write_wiki_tailnet_gate "" || true
    if ! docker run --rm \
            -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$GATE:/etc/nginx/ostler-wiki-gate.conf:ro" \
            "$NGINX_IMAGE" nginx -t >"$TMP/nginx-t-closed.log" 2>&1; then
        cat "$TMP/nginx-t-closed.log" >&2
        fail "the fail-closed placeholder is not valid nginx -- store-proxy would not start"
    fi
    pass "fail-closed placeholder is valid nginx (store-proxy still boots)"

    # ── 4b. Behavioural proof, not just a config parse ─────────────
    # A config that parses can still let the wrong request through, and
    # this gate is the only thing between a tailnet peer and the whole
    # personal graph. So stand the real gate up against a stub wiki and
    # drive actual HTTP at it.
    NET="ostler-wiki-gate-test-net"
    UPSTREAM="ostler-wiki-gate-test-upstream"
    GATEC="ostler-wiki-gate-test-gate"
    cleanup_live() {
        docker rm -f "$GATEC" "$UPSTREAM" >/dev/null 2>&1 || true
        docker network rm "$NET" >/dev/null 2>&1 || true
    }
    trap 'cleanup_live; rm -rf "$TMP"' EXIT
    cleanup_live

    cat > "$TMP/upstream.conf" <<'STUBEOF'
worker_processes 1;
events { worker_connections 16; }
http {
    server {
        listen 8000;
        location / { return 200 "WIKI-BODY-REACHED\n"; }
    }
}
STUBEOF
    docker network create "$NET" >/dev/null
    # The stub answers to the hostname the gate proxies to.
    docker run -d --name "$UPSTREAM" --network "$NET" --network-alias wiki-site \
        -v "$TMP/upstream.conf:/etc/nginx/nginx.conf:ro" \
        "$NGINX_IMAGE" >/dev/null

    write_wiki_tailnet_gate "$OWNER" || fail "regenerating the good gate failed"
    docker run -d --name "$GATEC" --network "$NET" -p 18144:8144 \
        -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$GATE:/etc/nginx/ostler-wiki-gate.conf:ro" \
        "$NGINX_IMAGE" >/dev/null

    # Wait for the listener rather than sleeping blind.
    LIVE=0
    for _ in $(seq 1 40); do
        if curl -s -o /dev/null -m 2 "http://127.0.0.1:18144/" 2>/dev/null; then
            LIVE=1; break
        fi
        sleep 0.25
    done
    [[ "$LIVE" == 1 ]] || { docker logs "$GATEC" >&2 || true; fail "gate container never answered on 18144"; }

    probe() { curl -s -o /dev/null -w '%{http_code}' -m 5 "$@" "http://127.0.0.1:18144/"; }

    # Deny: no identity at all (a direct hit that never went through
    # tailscaled, which is what a rebind or a stray LAN route looks like).
    [[ "$(probe)" == "403" ]] \
        || fail "gate allowed a request with NO Tailscale-User-Login (got $(probe))"
    # Deny: a different tailnet user -- the shared-in-peer case.
    [[ "$(probe -H 'Tailscale-User-Login: someone-else@example.com')" == "403" ]] \
        || fail "gate allowed a request from a NON-owner tailnet user"
    # Deny: empty header.
    [[ "$(probe -H 'Tailscale-User-Login:')" == "403" ]] \
        || fail "gate allowed a request with an empty Tailscale-User-Login"
    # Deny: Funnel (public internet) even when carrying the owner login.
    [[ "$(probe -H "Tailscale-User-Login: ${OWNER}" -H 'Tailscale-Funnel-Request: ?1')" == "403" ]] \
        || fail "gate allowed FUNNEL traffic -- the wiki would be on the open internet"
    pass "gate returns 403 for: no identity, wrong user, empty header, Funnel"

    # Allow: the owner, not via Funnel, reaches the wiki body.
    OWNER_CODE="$(probe -H "Tailscale-User-Login: ${OWNER}")"
    [[ "$OWNER_CODE" == "200" ]] \
        || fail "gate did NOT let the owner through (got $OWNER_CODE) -- the feature is dead on arrival"
    curl -s -m 5 -H "Tailscale-User-Login: ${OWNER}" "http://127.0.0.1:18144/" \
        | grep -q 'WIKI-BODY-REACHED' \
        || fail "owner got 200 but not the wiki body -- the proxy_pass is wrong"
    pass "gate proxies the owner through to the wiki (200 + body)"

    # And the fail-closed gate refuses even the owner.
    write_wiki_tailnet_gate "" || true
    docker exec "$GATEC" nginx -s reload >/dev/null 2>&1 || true
    sleep 1
    CLOSED_CODE="$(probe -H "Tailscale-User-Login: ${OWNER}" || true)"
    if [[ "$CLOSED_CODE" == "200" ]]; then
        fail "fail-closed gate still served the wiki"
    fi
    pass "fail-closed gate serves nobody, not even the owner (got ${CLOSED_CODE:-no-listener})"

    cleanup_live
fi

# ── 5. The wiki is never raw-served, and 8144 stays on loopback ────
# Strip comment lines first: the code explains WHY a raw --tcp=8044
# passthrough is forbidden, and that explanation must not trip its own
# guard.
if grep -vE '^[[:space:]]*#' "$INSTALL" \
        | grep -qE 'serve .*--tcp=8044|tcp://localhost:8044'; then
    grep -nvE '^[[:space:]]*#' "$INSTALL" \
        | grep -E 'serve .*--tcp=8044|tcp://localhost:8044' >&2
    fail "$INSTALL raw-TCP serves :8044 -- that is the unauthenticated graph leak v1.0.10 closed"
fi
grep -q '"127.0.0.1:8044:8000"' "$INSTALL" \
    || fail "wiki-site is no longer published loopback-only"
grep -q '"127.0.0.1:8144:8144"' "$INSTALL" \
    || fail "the gate port 8144 is not published loopback-only"
grep -q 'ostler-wiki-gate.conf:/etc/nginx/ostler-wiki-gate.conf:ro' "$INSTALL" \
    || fail "store-proxy does not mount the wiki gate config"
pass ":8044 never raw-served; 8044 and 8144 both loopback-only"

# ── 6. The installer never enables Funnel ──────────────────────────
# `funnel status` is a read; anything else on that verb turns a public
# front door on. Comment lines are stripped first -- the code explains
# at length WHY Funnel is refused, and prose about Funnel must not
# trip the guard on Funnel. Customer-facing MSG_* strings live in the
# separate catalogue, so they are out of scope here by construction.
FUNNEL_HITS="$(grep -nvE '^[[:space:]]*#' "$INSTALL" \
    | grep -E '\bfunnel\b' | grep -vE 'funnel status' || true)"
if [[ -n "$FUNNEL_HITS" ]]; then
    echo "$FUNNEL_HITS" >&2
    fail "$INSTALL invokes a tailscale funnel subcommand other than 'status'"
fi
grep -q 'funnel status' "$INSTALL" \
    || fail "the installer no longer checks funnel status -- the warning is gone"
pass "installer only ever reads funnel status, never enables it"

# ── 7. The serve call targets the gate, not the wiki directly ──────
grep -q 'serve --bg --https=443 "http://127.0.0.1:8144"' "$INSTALL" \
    || fail "no HTTPS serve of the gate port"
grep -q 'serve --bg --http=80 "http://127.0.0.1:8144"' "$INSTALL" \
    || fail "no HTTP fallback serve of the gate port"
pass "tailscale serve points at the gate (8144), never at the wiki (8044)"

echo "PASS: wiki tailnet gate guard"
