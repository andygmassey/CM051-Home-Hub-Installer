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
# connect to, from ANY account including the owner's.
#
# ⚠️ THE ROUTE THAT WOULD DELIVER THAT STATE IS DEAD, AND THIS BLOCK USED TO
# NAME IT ANYWAY. It said the owner reaches the stores "over a unix socket in a
# 0700 directory, where the kernel does the authorising". The measurement at
# MUST_BE_CLOSED below kills that: a UDS created inside the colima VM crosses
# the bind-mount as a FILE, not as a connection, so there is no UDS route for
# ANY of these services. Every one of them runs in that VM.
#
# The assertion above is unchanged and still correct. What is gone is the means.
# Leaving the dead means written here as though it were the plan is how the
# ledger sends the next reader to build something that cannot work, so it is
# struck rather than quietly deleted -- somebody has already tried it once.
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
# 8144 IS IN THE LIST, AND MY FIRST DRAFT EXCLUDED IT ON THE ROOT-CAUSE PREMISE
#
# I excluded the wiki tailnet gate because it is "defended by content -- the
# identity headers tailscaled stamps, which a peer cannot forge". The generator
# says exactly that, and the scope is in the sentence:
#
#     # Tailscale stamps this header ... so A TAILNET PEER cannot forge it.
#     map $http_tailscale_user_login $ostler_wiki_user_ok { default 0; "<owner>" 1; }
#     map $http_tailscale_funnel_request $ostler_wiki_not_funnel { default 0; "" 1; }
#     server { listen 8144; ... if either map is 0 -> 403 ... }
#
# `$http_tailscale_user_login` is a REQUEST HEADER. The deletion that makes it
# trustworthy happens inside tailscaled. A local client connecting straight to
# 127.0.0.1:8144 never traverses tailscaled, so nothing deletes anything and the
# client supplies both values itself. Omitting the funnel header satisfies limb
# one; sending the owner's email -- an address, not a secret -- satisfies limb
# two. 8144 IS published: install.sh has - "127.0.0.1:8144:8144".
#
# So it is very likely a seventh route to the same graph, and my exclusion
# inherited the premise this probe exists to kill: a control aimed at the only
# attacker its model contained, and an exclusion that adopted the same model.
# Included. If it turns out to be genuinely defended, the right answer is to
# prove that and remove it, not to assume it.
#
# BASH 3.2. No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="no_store_port_is_tcp_reachable"
PROBE_QUESTION="can any local account open a TCP connection to an Ostler store or UI without a credential?"

# The ports that MUST NOT answer after the fix, and why each is here.
#
# 2026-08-28: THREE OF THESE ROWS USED TO SAY "-> unix socket". That remedy is
# NOT AVAILABLE and the rows are corrected below. Measured with a control: a
# unix socket created INSIDE a container crosses a colima bind-mount as a FILE
# and NOT as a connection -- the host sees a real socket inode (`-S` passes) and
# `curl --unix-socket` against it fails, while the identical curl against a
# host-created socket succeeds. Connectability belongs to the kernel that owns
# the socket, which is the VM's. Every service below runs in that VM, so no
# UDS route exists for any of them. Measured on mountType=virtiofs / vm-type=vz
# (colima's default, and install.sh:10116 does not pin it); sshfs and 9p
# unmeasured.
#
# The ASSERTION is unchanged and still correct: none of these may answer. Only
# the stated route to that state was wrong, and a wrong route in the file that
# explains the hold sends the next reader to build something that cannot work.
#
#   6333  qdrant REST via store-proxy   -> UNRESOLVED. MUST_STILL_PUBLISH pins
#                                          it today: host clients have no other
#                                          route. Needs the native api key
#                                          (scaffolding exists, default-OFF).
#   7878  oxigraph SPARQL via store-proxy -> proxy bearer credential (#1214,
#                                          merged, default-OFF). #550 was
#                                          demonstrated here.
#   6334  qdrant gRPC, direct           -> unpublished (#1209; 0 consumers in
#                                          355 .py, 759 .rs, 144 ts)
#   6379  redis/valkey, direct          -> requirepass, BUT the Doctor's probe
#                                          sends PING and needs PONG, so it
#                                          reports UNHEALTHY under auth
#                                          (-NOAUTH). Upstream + re-vendor.
#   8044  wiki-site                     -> 🔴 UNRESOLVED AND THE WORST SURFACE.
#                                          Serves the whole personal wiki with
#                                          no auth. Its consumer is the
#                                          CUSTOMER'S BROWSER, so it can take
#                                          no bearer; and a cookie gives no
#                                          port isolation (RFC 6265), so a
#                                          second local account's web server
#                                          receives it. No agreed answer.
#   3000  vane                          -> same class as 8044: a browser UI, so
#                                          no bearer. Not solved.
#   8144  wiki tailnet gate            -> its identity check is client-supplied
#                                        over a local connection (see above).
#                                        Its ONLY consumer is `tailscale serve`
#                                        on the host, so it must stay a TCP
#                                        port; the UDS alternative is dead per
#                                        the measurement above.
MUST_BE_CLOSED="6333 7878 6334 6379 8044 3000 8144"

# ── ⚠️ 8144: EXPECTED RED, AND DO NOT "FIX" IT BY UNPUBLISHING THE PORT ──────
#
# 8144 belongs in the list: its two identity limbs are request headers, and a
# local client that never traverses tailscaled supplies them itself. That is
# real and it is why the port is here.
#
# But it CANNOT be closed the way 6334 and 6379 were, and the reason is
# measured rather than assumed:
#
#     install.sh:21269
#       "$TS_CLI" --socket="$TS_SOCK" serve --bg --https=443 "http://127.0.0.1:8144"
#
# **tailscaled reaches the gate by connecting to 127.0.0.1:8144 from the host.**
# So whatever can reach it for tailscaled can be reached by any local account:
# they are the same loopback. Unpublish the port and `tailscale serve` has
# nothing to proxy to, and the tailnet wiki path dies silently.
#
# So this row is expected RED until the HAND-OFF changes, not until somebody
# deletes a compose line. The open question that decides the shape of that fix:
# can `tailscale serve` be pointed at anything other than a host TCP port?
# If yes, 8144 is a topology fix like the stores. If no, it joins 8044 and
# 3000 and is solved by whatever solves those.
#
# A red that carries its own reason is a gate. A red that invites a wrong fix
# is a trap. This comment is the difference.

# Must be OPEN, or we cannot tell "closed" from "cannot look".
CONTROL_PORT="${OSTLER_GATEWAY_PORT:-8000}"

# THE SENSOR IS A CONNECT, NOT A LISTENER LOOKUP.
#
# The first draft used `lsof -nP -iTCP:<port> -sTCP:LISTEN`. That is the defect
# of #549 reproduced inside the gate built to close it: **lsof is
# permission-scoped**, so a listener owned by ANOTHER account is invisible and
# reads as closed. A positive control does not save it, because the control is
# read through the same permission scope: on a box where the gateway is owned by
# the running account and the stores are owned by another (which is the exact
# topology of the 2026-08-28 walk box), the control PASSES and every store port
# reads closed. The gate would have printed PASS on the machine that produced
# the demonstration.
#
# A connect is what the attacker does. It is not permission-scoped, and on
# loopback there is no filtering to confuse it.
#
# And no `2>/dev/null` on the decisive read: a swallowed error becomes a zero
# and a zero reads as closed.
#
#   prints: open | closed | error:<rc>
port_state() {
    _rc="$(box_run "nc -z -w 2 127.0.0.1 $1 >/dev/null 2>&1; echo \$?")"
    case "$_rc" in
        0) printf 'open\n' ;;
        1) printf 'closed\n' ;;
        *) printf 'error:%s\n' "$_rc" ;;
    esac
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

    c_state="$(port_state "$CONTROL_PORT")"
    case "$c_state" in open) c=1 ;; closed) c=0 ;; *) c="" ;; esac
    case "$(classify "$c" "")" in
        CANNOT_RUN)
            probe_examined 0 "store/UI ports"
            probe_cannot_run "control port ${CONTROL_PORT} is ${c_state}. A closed or unreadable control cannot be told apart from a closed store port, so this run proves nothing about #550."
            ;;
    esac
    probe_note "positive control: ${CONTROL_PORT} has a listener, so this probe can see an open port"

    for p in $MUST_BE_CLOSED; do
        n_checked=$((n_checked + 1))
        st="$(port_state "$p")"
        case "$st" in
            error:*)
                probe_examined "$n_checked" "store/UI ports"
                probe_cannot_run "connect to ${p} returned ${st}; neither open nor refused, so it cannot be adjudicated."
                ;;
            open) open_list="${open_list} ${p}" ;;
        esac
    done

    probe_examined "$n_checked" "store/UI ports (control ${CONTROL_PORT} confirmed open)"

    case "$(classify "$c" "$open_list")" in
        FAIL)
            probe_fail "TCP-reachable on loopback, therefore readable by every account on this Mac:${open_list}. #550 was demonstrated against 7878 with one unauthenticated curl."
            ;;
        PASS)
            # States ONLY what was measured. The previous wording explained the
            # pass by saying the stores were "reachable only over the unix
            # socket, where the 0700 directory is the authorisation" -- a route
            # this same file measures as UNAVAILABLE (a UDS inside the colima VM
            # crosses the bind-mount as a file, not a connection). A green
            # verdict that hands the reader a false mechanism is worse than a
            # terse one: it is the sentence that gets quoted into a ship note.
            probe_pass "none of the ${n_checked} store/UI ports accepts a TCP connection from this account, with ${CONTROL_PORT} confirmed open in the same run so this is a measured refusal and not a blind probe. HOW they became unreachable is NOT asserted here -- read the per-port table in this file for the route each one actually took"
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
