#!/usr/bin/env bash
#
# test_qdrant_publishes_no_host_port.sh
#
# #550 -- ANY LOCAL ACCOUNT COULD READ THE VECTOR STORE, AND THE COMMENT
# ABOVE THE PORT EXPLAINED WHY THAT WAS FINE.
#
# install.sh used to publish Qdrant's gRPC port:
#
#     ports:
#       - "127.0.0.1:6334:6334"
#
# with a justification written directly above it: "not browser-DNS-
# rebindable; covered by the v1.0.1 token-auth project". Both halves were
# true. Together they were the wrong test.
#
# A published loopback port is reachable by EVERY LOCAL USER ACCOUNT, not
# only by a browser. And Qdrant ships KEYLESS by default -- the installer
# actively strips QDRANT__SERVICE__API_KEY when store-auth is off. So a
# second account on the same Mac could read and write the whole vector
# store with no credential, no race and no privilege.
#
# DEMONSTRATED 2026-08-28 on real hardware, via the sibling Oxigraph
# route, from an unprivileged second account:
#
#     curl -s -H 'Host: localhost' \
#       'http://127.0.0.1:7878/query?query=SELECT (COUNT(*) AS ?n) WHERE {?s ?p ?o}'
#     -> a valid SPARQL result. The owner's knowledge graph.
#
# The Qdrant publish was the same exposure by a shorter path.
#
# This test asserts the SHIPPING surface: the compose that install.sh
# generates must not publish ANY host port for the qdrant service.
#
# WHY IT IS SAFE TO UNPUBLISH -- measured across all three populations at
# origin/main, each with a positive control proving the predicate matches:
#     355 bundled .py   0 gRPC clients   (control: 6333 in 15 files)
#     759 .rs in oa     0                (daemon uses reqwest REST on 6333)
#     144 .ts/.tsx/.js  0                (control: 14 reference localhost:<port>)
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

[ -f "$INSTALL_SH" ] || {
    echo "FAIL: install.sh not found -- CANNOT-RUN, not a pass" >&2
    exit 1
}

# ── CONTROL 1: the subject exists. ───────────────────────────────────
# Every assertion below is a search over the qdrant service block. If
# that block is absent -- renamed, moved, deleted -- each one returns a
# confident zero for a reason that has nothing to do with #550. A clean
# green on an absent subject is the exact failure this repo has been
# cataloguing all week. Establish the denominator first.
if ! grep -q '^  qdrant:' "$INSTALL_SH"; then
    echo "FAIL: no 'qdrant:' service in install.sh -- this test's subject" >&2
    echo "      is absent, so its zeros mean nothing. CANNOT-RUN." >&2
    exit 1
fi
pass "control 1: the qdrant service block exists"

# Extract the qdrant block: from its own key to the next service key at
# the same indent. Bounded by construction so a runaway range cannot
# silently swallow another service's ports and produce a false FAIL.
QDRANT_BLOCK="$(awk '
    /^  qdrant:/        { inblock = 1; next }
    inblock && /^  [a-z_-]+:/ { exit }
    inblock             { print }
' "$INSTALL_SH")"

if [ -z "$QDRANT_BLOCK" ]; then
    echo "FAIL: the qdrant block extracted EMPTY -- the awk range is wrong," >&2
    echo "      so a 'no ports' result would be vacuous. CANNOT-RUN." >&2
    exit 1
fi
pass "control 2: the qdrant block extracted non-empty"

# ── CONTROL 3: THE PREDICATE CAN FIND A PUBLISH. ─────────────────────
# This is the control that matters most. The whole test is "qdrant
# publishes nothing". If the pattern that looks for a publish is broken,
# that assertion passes for free, forever, and the port could be silently
# restored. So prove the pattern DOES match on a service that genuinely
# publishes: store-proxy, which must keep its host ports.
PUBLISH_RE='^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:[0-9]+:[0-9]+"'
proxy_publishes="$(grep -cE "$PUBLISH_RE" "$INSTALL_SH")"
if [ "$proxy_publishes" -lt 1 ]; then
    echo "FAIL: the publish pattern matches NOTHING anywhere in install.sh." >&2
    echo "      store-proxy is supposed to publish host ports, so a zero" >&2
    echo "      here means the PATTERN is broken, not that qdrant is safe." >&2
    echo "      CANNOT-RUN." >&2
    exit 1
fi
pass "control 3: the publish pattern matches ${proxy_publishes} real publishes elsewhere"

# ── THE ASSERTION ────────────────────────────────────────────────────
if printf '%s\n' "$QDRANT_BLOCK" | grep -qE "$PUBLISH_RE"; then
    failure "the qdrant service PUBLISHES a host port. #550: a published"
    echo "      loopback port is reachable by every local account, and" >&2
    echo "      Qdrant ships keyless. Offending line(s):" >&2
    printf '%s\n' "$QDRANT_BLOCK" | grep -nE "$PUBLISH_RE" | sed 's/^/        /' >&2
else
    pass "qdrant publishes NO host port"
fi

# Belt and braces: 6334 specifically must not be published anywhere, in
# case the service is ever restructured and the block extraction drifts.
if grep -qE '^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:6334:' "$INSTALL_SH"; then
    failure "6334 is published somewhere in install.sh (#550)"
fi

# And the store-proxy MUST keep publishing 6333, or host clients lose
# their only route to Qdrant. A fix that closes the hole by breaking the
# product is not a fix.
if grep -qE '^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:6333:' "$INSTALL_SH"; then
    pass "store-proxy still publishes 6333 -- host clients keep their route"
else
    failure "6333 is no longer published: host clients have NO route to Qdrant"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "" >&2
    echo "qdrant host-port exposure guard: FAIL" >&2
    exit 1
fi
echo ""
echo "qdrant host-port exposure guard: PASS"
