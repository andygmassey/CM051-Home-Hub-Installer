#!/usr/bin/env bash
#
# test_stores_publish_no_host_port.sh
#
# #550 -- ANY LOCAL ACCOUNT COULD READ THE STORES, AND THE COMMENTS ABOVE
# THE PORTS EXPLAINED WHY THAT WAS FINE.
#
# install.sh used to publish store ports to host loopback:
#
#     qdrant:  - "127.0.0.1:6334:6334"     gRPC, and the store ships KEYLESS
#     redis:   - "127.0.0.1:6379:6379"     valkey, no password by default
#
# Each carried a justification. Qdrant's said it was "not browser-DNS-
# rebindable". Redis's called 127.0.0.1-only a "security lockdown". Both
# were true statements and both were the wrong test.
#
# A published loopback port is reachable by EVERY LOCAL USER ACCOUNT, not
# only by a browser. Bound-to-127.0.0.1 is a defence against the NETWORK.
# It is not an access control on the MACHINE.
#
# DEMONSTRATED 2026-08-28 on real hardware, via the sibling Oxigraph
# route, from an unprivileged second account:
#
#     curl -s -H 'Host: localhost' \
#       'http://127.0.0.1:7878/query?query=SELECT (COUNT(*) AS ?n) WHERE {?s ?p ?o}'
#     -> a valid SPARQL result. The owner's knowledge graph.
#
# ── WHY THIS IS A LIST AND NOT TWO COPIES ────────────────────────────
# The root of #550 is ONE unstated premise -- "a local user is the owner"
# -- observed in six places, not six independent bugs. See
# docs/THREAT_MODEL_LOCAL_USERS.md. A guard shaped as "qdrant must not
# publish" closes the instance we found. A guard shaped as "these
# services must not publish" is where the SEVENTH one gets caught, and
# adding a service to it costs one line.
#
# ── WHY IT IS SAFE TO UNPUBLISH EACH ONE ─────────────────────────────
# Measured across all three shipped populations, each with a positive
# control proving the predicate can match:
#
#   qdrant 6334   355 bundled .py    0 gRPC clients  (control: 6333 in 15)
#                 759 .rs in oa      0              (daemon uses REST 6333)
#                 144 .ts/.tsx/.js   0              (control: 14 localhost:<port>)
#
#   redis 6379    355 bundled .py    0 clients, 0 imports
#                                    (control: a file containing
#                                     redis.Redis(host=...) and
#                                     redis.from_url(...) -- SAME predicate,
#                                     both matched)
#                 759 .rs in oa      0. `redis` is a direct dependency of
#                                    ZERO of 27 Cargo.toml, and
#                                    zeroclaw-memory asserts
#                                    classify_memory_backend("redis")
#                                    == MemoryBackendKind::Unknown
#                 144 .ts/.tsx/.js   0 (the one hit was the substring
#                                    "redis" inside "rediscovers")
#
# Services INSIDE the compose network still reach each other by name.
# Unpublishing removes the HOST route only.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

# ── THE LIST. Add a service here to protect it. ──────────────────────
# Format: <compose service name>:<the port it used to publish>
# The port is named so the belt-and-braces check below can look for it
# anywhere in the file, not only inside its own service block.
MUST_NOT_PUBLISH=(
    "qdrant:6334"
)

# ── WHY redis:6379 IS NOT IN THAT LIST YET ───────────────────────────
# It was, for about ten minutes, on a census showing 0 redis clients
# across all three shipped populations -- a correct measurement that
# answered the WRONG QUESTION.
#
# "Who uses this service" and "who connects to this port" are different
# questions. The Doctor is not a client, it is a PROBER: it opens a TCP
# connection to localhost:6379 without speaking the redis protocol, so a
# search for redis client constructors cannot see it by construction.
# And the Doctor runs as a LAUNCHD JOB on the host, so it reaches redis
# through the published port.
#
#     vendor/doctor/agent/status_collector.py -- redis appears at 8 sites,
#     incl. EXPECTED_OSTLER_SERVICES and a special-case TCP branch
#
# Unpublishing 6379 without removing that probe reds the Doctor on every
# install. Removing the probe is an UPSTREAM change (the doctor tree is
# vendored and gated) plus a re-vendor, so it lands as its own piece of
# work, not smuggled into this one.
#
# When it lands: add "redis:6379" here and to SERVICES in
# tests/test_stores_guard_fires.sh. Both, or the mutation arm stops
# proving the guard fires for it.

# Ports that MUST keep publishing. A fix that closes the hole by breaking
# the product is not a fix, and this is the arm that says so.
#
# ⚠️ THIS IS NOT A SECURITY INVARIANT. It is a statement about TODAY's
# topology: host clients reach Qdrant only through the store-proxy on
# 6333. The in-flight #550 work moves host clients onto a Unix domain
# socket, at which point 6333 SHOULD stop publishing and this row must be
# deleted in the same PR that moves them. Do not read a row here as
# "this port is meant to be open forever" -- read it as "something still
# depends on it, and here is what".
MUST_STILL_PUBLISH=(
    "6333"   # store-proxy -> Qdrant REST. Host clients have no other route
             # TODAY. Delete this row when the UDS route lands.
)

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

[ -f "$INSTALL_SH" ] || {
    echo "FAIL: install.sh not found -- CANNOT-RUN, not a pass" >&2
    exit 1
}

PUBLISH_RE='^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:[0-9]+:[0-9]+"'

# ── CONTROL: THE PREDICATE CAN FIND A PUBLISH. ───────────────────────
# This is the control that matters most. Every assertion below is of the
# form "X publishes nothing". If the pattern that looks for a publish is
# broken, all of them pass for free, forever, and any port could be
# silently restored. So prove the pattern DOES match on the services
# that genuinely publish and must keep doing so.
publishes_found="$(grep -cE "$PUBLISH_RE" "$INSTALL_SH")"
if [ "$publishes_found" -lt 1 ]; then
    echo "FAIL: the publish pattern matches NOTHING anywhere in install.sh." >&2
    echo "      store-proxy is supposed to publish host ports, so a zero" >&2
    echo "      here means the PATTERN is broken, not that the stores are" >&2
    echo "      safe. CANNOT-RUN." >&2
    exit 1
fi
pass "control: the publish pattern matches ${publishes_found} real publishes elsewhere"

# ── PER-SERVICE ──────────────────────────────────────────────────────
for entry in "${MUST_NOT_PUBLISH[@]}"; do
    svc="${entry%%:*}"
    port="${entry##*:}"

    # CONTROL: the subject exists. Without this, a renamed, moved or
    # deleted service returns a confident zero for a reason that has
    # nothing to do with #550 -- a clean green on an absent subject,
    # which is the exact failure this repo has spent a week cataloguing.
    if ! grep -q "^  ${svc}:" "$INSTALL_SH"; then
        echo "FAIL: no '${svc}:' service in install.sh -- this test's subject" >&2
        echo "      is absent, so its zeros mean nothing. CANNOT-RUN." >&2
        echo "      If the service was deliberately removed, delete its row" >&2
        echo "      from MUST_NOT_PUBLISH rather than leaving a guard that" >&2
        echo "      passes by looking at nothing." >&2
        exit 1
    fi
    pass "control: the ${svc} service block exists"

    # Extract the block: from its own key to the next service key at the
    # same indent. Bounded by construction, so a runaway range cannot
    # swallow another service's ports and produce a false FAIL.
    BLOCK="$(awk -v svc="$svc" '
        $0 == "  " svc ":"        { inblock = 1; next }
        inblock && /^  [a-z_-]+:/ { exit }
        inblock                   { print }
    ' "$INSTALL_SH")"

    if [ -z "$BLOCK" ]; then
        echo "FAIL: the ${svc} block extracted EMPTY -- the awk range is" >&2
        echo "      wrong, so a 'no ports' result would be vacuous." >&2
        echo "      CANNOT-RUN." >&2
        exit 1
    fi
    pass "control: the ${svc} block extracted non-empty"

    # THE ASSERTION
    if printf '%s\n' "$BLOCK" | grep -qE "$PUBLISH_RE"; then
        failure "the ${svc} service PUBLISHES a host port. #550: a published"
        echo "      loopback port is reachable by every local account." >&2
        echo "      Offending line(s):" >&2
        printf '%s\n' "$BLOCK" | grep -nE "$PUBLISH_RE" | sed 's/^/        /' >&2
    else
        pass "${svc} publishes NO host port"
    fi

    # Belt and braces: the specific port must not be published ANYWHERE,
    # in case the service is restructured and the block extraction drifts.
    if grep -qE "^[[:space:]]*-[[:space:]]*\"127\.0\.0\.1:${port}:" "$INSTALL_SH"; then
        failure "${port} is published somewhere in install.sh (#550)"
    fi
done

# ── THE PRODUCT MUST STILL WORK ──────────────────────────────────────
for port in "${MUST_STILL_PUBLISH[@]}"; do
    if grep -qE "^[[:space:]]*-[[:space:]]*\"127\.0\.0\.1:${port}:" "$INSTALL_SH"; then
        pass "store-proxy still publishes ${port} -- host clients keep their route"
    else
        failure "${port} is no longer published: host clients have NO route"
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "" >&2
    echo "store host-port exposure guard: FAIL" >&2
    exit 1
fi
echo ""
echo "store host-port exposure guard: PASS"
