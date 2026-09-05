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

# #550: the store-proxy conf now ALSO includes a 0600 credential file for
# Oxigraph (the only store with no native auth). The include is
# deliberately FAIL-CLOSED -- nginx refuses to start if it is missing --
# so this harness has to stage it exactly as install.sh does, for the
# same reason it already stages the wiki gate above.
AUTH="$TMP/ostler-store-auth.conf"
cat > "$AUTH" <<'AUTHEOF'
# Ostler store credential -- comment-only placeholder, matching the
# installer's DEFAULT-OFF state. See install.sh.
AUTHEOF

# #1594: the same conf now ALSO includes the wiki browser credential, on
# :8044. Identical reasoning to the block above -- the include is
# FAIL-CLOSED, so nginx refuses to start without it and this harness has
# to stage it exactly as install.sh does. Staged with a REAL apr1 hash
# rather than a placeholder, because auth_basic_user_file is parsed.
WIKIAUTH="$TMP/ostler-wiki-auth.conf"
WIKIHTPASSWD="$TMP/ostler-wiki-htpasswd"
cat > "$WIKIAUTH" <<'WAEOF'
auth_basic "Ostler personal wiki";
auth_basic_user_file /etc/nginx/ostler-wiki-htpasswd;
WAEOF
printf 'ostler:%s\n' "$(/usr/bin/openssl passwd -apr1 'harness-only-not-a-secret')" > "$WIKIHTPASSWD"

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
            -v "$AUTH:/etc/nginx/ostler-store-auth.conf:ro" \
            -v "$WIKIAUTH:/etc/nginx/ostler-wiki-auth.conf:ro" \
            -v "$WIKIHTPASSWD:/etc/nginx/ostler-wiki-htpasswd:ro" \
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
            -v "$AUTH:/etc/nginx/ostler-store-auth.conf:ro" \
            -v "$WIKIAUTH:/etc/nginx/ostler-wiki-auth.conf:ro" \
            -v "$WIKIHTPASSWD:/etc/nginx/ostler-wiki-htpasswd:ro" \
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
            -v "$AUTH:/etc/nginx/ostler-store-auth.conf:ro" \
            -v "$WIKIAUTH:/etc/nginx/ostler-wiki-auth.conf:ro" \
            -v "$WIKIHTPASSWD:/etc/nginx/ostler-wiki-htpasswd:ro" \
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
            -v "$AUTH:/etc/nginx/ostler-store-auth.conf:ro" \
            -v "$WIKIAUTH:/etc/nginx/ostler-wiki-auth.conf:ro" \
            -v "$WIKIHTPASSWD:/etc/nginx/ostler-wiki-htpasswd:ro" \
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
# #1594: the wiki's host publish MOVED from wiki-site to store-proxy so it
# lands behind auth_basic. The property this arm has always protected --
# 8044 is bound to loopback and nowhere else -- is unchanged, so it is
# asserted here against the new owner rather than deleted. It is also
# STRENGTHENED: the old spelling was a single must-match, which would have
# stayed green if a SECOND, unbound 8044 publish appeared elsewhere in the
# file. The must-miss below closes that.
grep -q '"127.0.0.1:8044:8044"' "$INSTALL" \
    || fail "the wiki port 8044 is not published loopback-only by store-proxy"
if grep -nE '^[[:space:]]*-[[:space:]]*"[^"]*8044:' "$INSTALL" \
        | grep -vE '"127\.0\.0\.1:8044:' | grep -q .; then
    grep -nE '^[[:space:]]*-[[:space:]]*"[^"]*8044:' "$INSTALL" \
        | grep -vE '"127\.0\.0\.1:8044:' >&2
    fail "an 8044 publish is bound to something other than loopback"
fi
# And the container that has no idea a credential exists must publish nothing.
if grep -A4 'container_name: ostler-wiki-site' "$INSTALL" | grep -qE '^[[:space:]]*ports:'; then
    fail "wiki-site publishes a host port again -- that BYPASSES the :8044 credential"
fi
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

# ── 6b. The Funnel predicate discriminates (v1018-D001) ────────────
#
# The check above proves the installer never ENABLES Funnel. It says
# nothing about whether the DETECTION is right, and until 2026-08-09 it
# was not. The shipped predicate was
#
#     funnel status | grep -qi "https://"
#
# which fires on the SUCCESS path. `funnel status` and `serve status`
# are the same upstream function -- both subcommands register
# `runServeStatus` in cmd/tailscale/cli/serve_legacy.go, with no
# funnel-only filter -- so a tailnet-PRIVATE serve prints
#
#     https://<host> (tailnet only)
#
# and the grep matched it. Every customer whose wiki was successfully
# published over HTTPS on the tailnet was then told their machine had a
# public front door. Verified on the shipped v1.0.18 box: `funnel
# status` and `serve status` emitted byte-identical output and the line
# read "(tailnet only)".
#
# So this section does not grep for the fix. It extracts the shipped
# detection block and runs it against fixtures on BOTH sides of the
# line, and it separately demonstrates that the old predicate went red
# on the funnel-OFF fixture. A gate that has not been watched failing
# is not a gate.
awk '/# >>> OSTLER_FUNNEL_DETECT_BEGIN$/{f=1;next} /# <<< OSTLER_FUNNEL_DETECT_END$/{exit} f{print}' \
    "$INSTALL" > "$TMP/funnel_detect.sh"
grep -q 'OSTLER_FUNNEL_PORTS=' "$TMP/funnel_detect.sh" \
    || fail "could not extract the Funnel detection block from $INSTALL (markers moved?)"
grep -q '# <<< OSTLER_FUNNEL_DETECT_END' "$INSTALL" \
    || fail "the OSTLER_FUNNEL_DETECT_END marker is gone -- extraction is unbounded"
bash -n "$TMP/funnel_detect.sh" \
    || fail "extracted Funnel detection block does not parse -- extraction is wrong"

# Stub CLI. It BEHAVES like the real tool rather than replaying one
# blob: `--json` gets the machine shape, anything else gets the human
# tree. That matters. If the stub only ever returned JSON, then
# reverting the fix to the old prose-grep predicate would still pass
# here (the JSON happens not to contain "https://"), and the test would
# be measuring the fixture format instead of the predicate. Every case
# below therefore carries BOTH representations of the same box.
cat > "$TMP/fake-tailscale" <<'FAKETS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGV_LOG}"
case " $* " in
    *" --json "*|*" --json") cat "${FIXTURE_JSON}" ;;
    *)                       cat "${FIXTURE_HUMAN}" ;;
esac
FAKETS
chmod +x "$TMP/fake-tailscale"

detect_funnel() {
    # $1 = fixture stem. Echoes the detected host:port list (possibly empty).
    env TS_CLI="$TMP/fake-tailscale" TS_SOCK="/dev/null" \
        FIXTURE_JSON="$TMP/$1.json" FIXTURE_HUMAN="$TMP/$1.human" \
        ARGV_LOG="$TMP/argv.log" \
        bash -c 'source "$1"; printf "%s" "${OSTLER_FUNNEL_PORTS:-}"' _ "$TMP/funnel_detect.sh"
}

# Fixtures are SYNTHETIC. The structure is copied from a real box, the
# tailnet name is not (Rule zero -- no real-instance identifiers in
# tracked fixtures).
#
# (a) Exactly what a healthy install looks like: our own serve on 443
#     proxying the wiki gate, and no AllowFunnel key at all. This is the
#     case the old predicate got wrong.
cat > "$TMP/funnel_off_real.json" <<'JSON'
{
  "TCP": { "443": { "HTTPS": true }, "8089": { "TCPForward": "localhost:8089" } },
  "Web": {
    "hub.example-tailnet.ts.net:443": {
      "Handlers": { "/": { "Proxy": "http://127.0.0.1:8144" } }
    }
  }
}
JSON
#     ...and the human tree the same box prints. Note "(tailnet only)"
#     on a line that still contains "https://". THAT is v1018-D001.
cat > "$TMP/funnel_off_real.human" <<'HUMAN'
|-- tcp://hub.example-tailnet.ts.net:8089 (tailnet only)
|--> tcp://localhost:8089

https://hub.example-tailnet.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8144
HUMAN
# (b) AllowFunnel present but every entry false -- `tailscale serve`
#     writes this shape when it re-declares a port as tailnet-only.
cat > "$TMP/funnel_off_explicit.json" <<'JSON'
{ "AllowFunnel": { "hub.example-tailnet.ts.net:443": false } }
JSON
cp "$TMP/funnel_off_real.human" "$TMP/funnel_off_explicit.human"
# (c) Genuinely on. The human tree says "Funnel on" instead.
cat > "$TMP/funnel_on.json" <<'JSON'
{ "AllowFunnel": { "hub.example-tailnet.ts.net:443": true } }
JSON
cat > "$TMP/funnel_on.human" <<'HUMAN'
https://hub.example-tailnet.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:8144
HUMAN
# (d) Mixed -- only the true one is the customer's problem.
cat > "$TMP/funnel_on_mixed.json" <<'JSON'
{
  "AllowFunnel": {
    "hub.example-tailnet.ts.net:443": false,
    "hub.example-tailnet.ts.net:8443": true
  }
}
JSON
cp "$TMP/funnel_on.human" "$TMP/funnel_on_mixed.human"
# (e) Foreground sessions carry their own nested ServeConfig. A funnel
#     declared in one is just as public as a background one.
cat > "$TMP/funnel_on_foreground.json" <<'JSON'
{
  "Foreground": {
    "sess-1": { "AllowFunnel": { "hub.example-tailnet.ts.net:9000": true } }
  }
}
JSON
cp "$TMP/funnel_on.human" "$TMP/funnel_on_foreground.human"
# (f) No serve config at all -- tailscale marshals a nil ServeConfig as
#     literal null, which must not crash the parser.
printf 'null\n' > "$TMP/funnel_null.json"
printf 'No serve config\n' > "$TMP/funnel_null.human"
# (g) Daemon unreachable / CLI missing: empty output.
: > "$TMP/funnel_empty.json"
: > "$TMP/funnel_empty.human"
# (h) Not JSON at all (an error message on stdout).
printf 'The Tailscale command is not installed.\n' > "$TMP/funnel_garbage.json"
cp "$TMP/funnel_garbage.json" "$TMP/funnel_garbage.human"

for f in funnel_off_real funnel_off_explicit funnel_null funnel_empty funnel_garbage; do
    got="$(detect_funnel "$f")"
    [[ -z "$got" ]] \
        || fail "$f: Funnel is OFF but the installer reported it on (got: '$got')"
done
pass "Funnel-off fixtures produce no warning (incl. the healthy-serve shape D001 got wrong)"

got="$(detect_funnel funnel_on)"
[[ "$got" == "hub.example-tailnet.ts.net:443" ]] \
    || fail "funnel_on: expected the funnelled host:port, got '$got'"
got="$(detect_funnel funnel_on_mixed)"
[[ "$got" == "hub.example-tailnet.ts.net:8443" ]] \
    || fail "funnel_on_mixed: expected only the true entry, got '$got'"
got="$(detect_funnel funnel_on_foreground)"
[[ "$got" == "hub.example-tailnet.ts.net:9000" ]] \
    || fail "funnel_on_foreground: nested Foreground funnel not detected, got '$got'"
pass "Funnel-on fixtures name the exact host:port, including nested Foreground"

# The block must only ever READ. If someone later reaches for a
# mutating verb inside these markers, this catches it even though the
# file-wide grep in 6 would too.
grep -q 'funnel status --json' "$TMP/funnel_detect.sh" \
    || fail "the detection block no longer asks for --json -- it is back to parsing prose"
if grep -qE '\bfunnel\b[^|]*\b(reset|off|on)\b' "$TMP/funnel_detect.sh"; then
    fail "the detection block invokes a mutating funnel verb"
fi
pass "detection block reads funnel status --json and mutates nothing"

# ── The demonstrated RED ───────────────────────────────────────────
# Proof the OLD predicate was wrong, not merely different. Run it, here,
# against the human output of the Funnel-OFF box in fixture (a) and
# assert it says "on". Because the stub answers prose and JSON the same
# way the real CLI does, restoring that predicate inside the markers
# makes the funnel_off_real case above fail -- which is what makes the
# section above a gate rather than a formality.
if ! grep -i "https://" "$TMP/funnel_off_real.human" >/dev/null; then
    fail "fixture no longer reproduces the D001 trap -- update it deliberately"
fi
grep -q "tailnet only" "$TMP/funnel_off_real.human" \
    || fail "fixture must show Funnel OFF for the demonstration to mean anything"
# Comments stripped first: the code above quotes the broken predicate
# verbatim so the next reader knows what went wrong, and that prose
# must not trip the guard on the prose's own subject.
if grep -vE '^[[:space:]]*#' "$INSTALL" \
    | grep -qE 'funnel status[^|]*\|[[:space:]]*grep'; then
    fail "$INSTALL still pipes funnel status into grep -- the v1018-D001 false positive is back"
fi
pass "old predicate matches a Funnel-OFF box (demonstrated RED); shipped code no longer uses it"

# ── 7. The serve call targets the gate, not the wiki directly ──────
grep -q 'serve --bg --https=443 "http://127.0.0.1:8144"' "$INSTALL" \
    || fail "no HTTPS serve of the gate port"
grep -q 'serve --bg --http=80 "http://127.0.0.1:8144"' "$INSTALL" \
    || fail "no HTTP fallback serve of the gate port"
pass "tailscale serve points at the gate (8144), never at the wiki (8044)"

echo "PASS: wiki tailnet gate guard"
