#!/usr/bin/env bash
# probes/no_store_port_is_tcp_reachable.sh
# ============================================================================
# QUESTION: can anything on this Mac open a TCP connection to an Ostler store
#           or UI, without presenting any credential?
#
# THIS IS THE PROBE FOR #550, AND #550 WAS DEMONSTRATED, NOT ARGUED.
#
# From an ordinary second account on the owner's Mac, with no credential and no
# race:
#
#     curl -s -m 5 --noproxy '*' -H 'Host: localhost' \
#       'http://127.0.0.1:7878/query?query=SELECT (COUNT(*) AS ?n) WHERE {?s ?p ?o}'
#     -> a valid SPARQL result over the owner's entire knowledge graph
#
# The store-proxy in front of it checks the Host header and the Origin header.
# Both are supplied by the client. They were built against DNS-rebinding and
# cross-origin form POSTs -- BROWSER threats -- under an assumption written
# down at install.sh:14674: "a local user on this Mac can already read :8044
# directly, so it adds no local surface." That assumption is `local == owner`,
# and it is the root of the whole class.
#
# ---------------------------------------------------------------------------
# WHY THIS ASSERTS ABSENCE OF A PORT AND NOT A REFUSED CREDENTIAL
#
# Every credential-based design was defeated on this box:
#   - a shared nonce is presented TO whatever answers the port, so a squatter
#     receives it on first use
#   - a token in the URL is harvested from argv, which is READABLE ACROSS
#     ACCOUNTS on macOS (measured)
#   - a cookie is scoped to HOST and not to PORT (RFC 6265), so any loopback
#     port the neighbour binds receives it
#
# So the assertion is topological: after the fix there is no TCP endpoint to
# connect to, from ANY account including the owner's. The owner reaches the
# stores over a unix socket in a 0700 directory, where the kernel does the
# authorising and there is no credential in existence to steal.
#
# That is also why this probe does NOT need a second account. Before the fix
# the ports answer everyone; after it they answer no one. One account can tell
# those apart.
#
# ---------------------------------------------------------------------------
# THE POSITIVE CONTROL, AND WHY IT IS NOT ONE OF THE STORE PORTS
#
# "Nothing is listening" and "I could not look" print identically. So this
# probe refuses to report PASS unless it has SEEN a listening port in the same
# invocation. The Hub gateway is used for that: it must stay reachable on
# loopback for the product to work at all, and daemon_is_listening.sh already
# treats it as a hard requirement.
#
# If the control port is closed, the verdict is CANNOT_RUN, never PASS. A run
# where the whole stack is down must not be reported as a security property.
#
# ---------------------------------------------------------------------------
# 8144 IS DELIBERATELY NOT IN THE LIST
#
# The wiki tailnet gate binds 127.0.0.1:8144 and demands identity headers that
# tailscaled stamps and a tailnet peer cannot forge. It is defended by CONTENT,
# not by topology, and it ships fail-closed with no listener until an owner
# identity is resolved. Asserting it closed would red on a correctly configured
# box; asserting it open would red on a fail-closed one. Out of scope, stated
# rather than silently dropped.
#
# BASH 3.2. No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="no_store_port_is_tcp_reachable"
PROBE_QUESTION="can any local account open a TCP connection to an Ostler store or UI without a credential?"

# The ports that MUST NOT answer after the fix, and why each is here.
#   6333  qdrant REST via store-proxy   -> unix socket
#   7878  oxigraph SPARQL via store-proxy -> unix socket   (#550 was demonstrated here)
#   6334  qdrant gRPC, direct           -> unpublished (#1209; 0 consumers in
#                                          355 .py, 759 .rs, 144 ts)
#   6379  redis/valkey, direct          -> unpublished (0 clients; the only
#                                          consumer was a health probe)
#   8044  wiki-site                     -> served in-app over the socket
#   3000  vane                          -> served in-app or gated
MUST_BE_CLOSED="6333 7878 6334 6379 8044 3000"

# Must be OPEN, or we cannot tell "closed" from "cannot look".
CONTROL_PORT="${OSTLER_GATEWAY_PORT:-8000}"

port_open() {
    # 0 = something is listening. Uses lsof for the listener rather than a
    # connect, so a half-open or filtered state cannot read as closed.
    box_run "lsof -nP -iTCP:$1 -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' '"
}

# ---------------------------------------------------------------------------
# THE ADJUDICATION, AS A PURE FUNCTION.
#
# Separated from the measuring so the self-test can exercise the DECISION with
# fabricated readings, rather than asserting things about its own fixtures. A
# self-test that only proves its stubs return what they were written to return
# has demonstrated nothing about the probe.
#
#   classify <control_listener_count> <space-separated open store ports>
#     -> CANNOT_RUN | FAIL | PASS
classify() {
    _c="$1"; _open="$2"
    case "$_c" in ''|*[!0-9]*) printf 'CANNOT_RUN\n'; return ;; esac
    # A closed control means the stack is down. Every store port then reads
    # closed for a reason that is not the fix.
    if [ "$_c" -eq 0 ]; then printf 'CANNOT_RUN\n'; return; fi
    if [ -n "$_open" ]; then printf 'FAIL\n'; return; fi
    printf 'PASS\n'
}

run_probe() {
    n_checked=0; open_list=""

    c="$(port_open "$CONTROL_PORT")"
    case "$(classify "$c" "")" in
        CANNOT_RUN)
            probe_examined 0 "store/UI ports"
            probe_cannot_run "control port ${CONTROL_PORT} reported '${c}' listeners. A closed or unreadable control cannot be told apart from a closed store port, so this run proves nothing about #550."
            ;;
    esac
    probe_note "positive control: ${CONTROL_PORT} has a listener, so this probe can see an open port"

    for p in $MUST_BE_CLOSED; do
        n_checked=$((n_checked + 1))
        o="$(port_open "$p")"
        case "$o" in
            ''|*[!0-9]*)
                probe_examined "$n_checked" "store/UI ports"
                probe_cannot_run "lsof returned '${o}' for port ${p}; cannot adjudicate."
                ;;
        esac
        [ "$o" -ne 0 ] && open_list="${open_list} ${p}"
    done

    probe_examined "$n_checked" "store/UI ports (control ${CONTROL_PORT} confirmed open)"

    case "$(classify "$c" "$open_list")" in
        FAIL)
            probe_fail "TCP-reachable on loopback, therefore readable by every account on this Mac:${open_list}. #550 was demonstrated against 7878 with one unauthenticated curl."
            ;;
        PASS)
            probe_pass "none of the ${n_checked} store/UI ports accepts a TCP connection; the stores are reachable only over the unix socket, where the 0700 directory is the authorisation"
            ;;
        *)
            probe_cannot_run "adjudication was inconclusive for control='${c}' open='${open_list}'"
            ;;
    esac
}

self_test() {
    # Exercises classify() with fabricated readings. Every case names the real
    # situation it stands for.
    fails=""

    # 1. THE DEFECT. Control up, a store port open -> must FAIL.
    [ "$(classify 1 ' 7878')" = "FAIL" ] || fails="${fails} open-store-port-not-FAIL"

    # 2. THE FIX. Control up, nothing open -> must PASS.
    [ "$(classify 1 '')" = "PASS" ] || fails="${fails} closed-ports-not-PASS"

    # 3. THE TRAP THIS PROBE EXISTS TO AVOID. Control DOWN, nothing open.
    #    A stopped stack must never be adjudicated PASS.
    [ "$(classify 0 '')" = "CANNOT_RUN" ] || fails="${fails} stopped-stack-read-as-PASS"

    # 4. Control unreadable -> CANNOT_RUN, not PASS.
    [ "$(classify '' '')" = "CANNOT_RUN" ] || fails="${fails} unreadable-control-not-CANNOT_RUN"

    # 5. Control down AND a port open -> still CANNOT_RUN. We cannot claim a
    #    finding from a run whose control failed, in either direction.
    [ "$(classify 0 ' 6333')" = "CANNOT_RUN" ] || fails="${fails} down-control-with-open-port-adjudicated"

    probe_examined 5 "adjudication cases"
    if [ -n "$fails" ]; then
        probe_fail "SELF-TEST FAILED:${fails}. This probe cannot be trusted to detect #550."
    fi
    probe_pass "classify() returns FAIL on an open store port, PASS only with the control up and nothing open, and CANNOT_RUN on a stopped or unreadable control in both directions"
}

probe_main "$@"
