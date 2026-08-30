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

# ── PORTS WHOSE OPENNESS IS ADJUDICATED BY AUTH, NOT BY TOPOLOGY ────────────
#
# These three carry a credential requirement that was DEMONSTRATED on real
# hardware 2026-08-29, with controls: keyless 6333 and 7878 both returned 401,
# and the credential was unreadable by any other account. Andy closed the
# finding on that evidence and scoped the closure to the STORES; the wiki and
# vane were explicitly left open as a separate call.
#
# For these, "is the socket open" is the WRONG QUESTION and answering it was
# making this probe's verdict uninformative. The question the closure actually
# rests on is: CAN A LOCAL ACCOUNT WITH NO CREDENTIAL READ THE DATA. That is
# what keyless_answer() asks.
#
# 8044, 3000, 8144 and 6334 are deliberately NOT here. 8044 and 3000 serve a
# browser and can carry no bearer, so for them open really does mean readable
# and the old topology rule is the correct rule. 6334 is unpublished. 8144's
# identity is client-supplied, so a keyless probe would be answering a question
# it cannot adjudicate -- and a probe that cannot adjudicate must not score.
AUTH_EXPECTED="6333 7878 6379"

# Does an UNCREDENTIALLED caller get served? -> refused | served | <reason>
#
# ⚠️ THE `-q` IS LOAD-BEARING AND IS THE WHOLE CORRECTNESS ARGUMENT.
# install.sh writes a curl config carrying the store credentials
# (_ostler_write_store_curl_config). curl reads ~/.curlrc BY DEFAULT. Without
# `-q` this probe would authenticate itself, receive 200, and report the store
# as WORLD-READABLE -- the exact opposite of the truth, on the one question the
# probe exists to answer. `-q` must stay the FIRST argument; it is ignored
# anywhere else. `--noproxy '*'` for the same class of reason: a local proxy
# can answer for every host probed and manufacture a uniform result.
keyless_answer() {
    _p="$1"
    case "$_p" in
        6379)
            # Redis speaks RESP, not HTTP. Under requirepass an uncredentialled
            # PING returns -NOAUTH; without it, +PONG.
            _r="$(printf 'PING\r\n' | nc -w 3 127.0.0.1 "$_p" 2>/dev/null | tr -d '\r\n')"
            case "$_r" in
                *NOAUTH*|*WRONGPASS*|*"no password"*) printf 'refused\n' ;;
                *PONG*)                              printf 'served\n'  ;;
                "")                                  printf 'empty-response\n' ;;
                *)                                   printf 'unrecognised:%s\n' "$_r" ;;
            esac
            ;;
        *)
            _code="$(curl -q -s -o /dev/null -w '%{http_code}' \
                          --noproxy '*' --max-time 5 \
                          "http://127.0.0.1:${_p}/" 2>/dev/null)"
            case "$_code" in
                401|403)     printf 'refused\n' ;;
                200|204|301|302) printf 'served\n' ;;
                000)         printf 'no-http-response\n' ;;
                *)           printf 'http-%s\n' "$_code" ;;
            esac
            ;;
    esac
}

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
    n_checked=0; open_list=""; authed_list=""

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
            open)
                # AN OPEN SOCKET IS NOT THE DEFECT. READABILITY IS.
                #
                # This probe's FAIL string used to read "TCP-reachable on
                # loopback, THEREFORE readable by every account on this Mac".
                # That "therefore" is false and we measured it false: on real
                # hardware 2026-08-29, keyless 6333 and 7878 both returned 401
                # and gRPC 6334 was REFUSED. Andy closed the finding on that
                # evidence, scoping it to the stores and leaving the wiki and
                # vane open as a separate call.
                #
                # So a pure connect() cannot distinguish the two states the
                # decision turns on:
                #     open + authenticated   -> not readable, not the defect
                #     open + unauthenticated -> readable by any local account
                # It called both FAIL, which makes its FAIL carry no
                # information -- and, worse, means it CANNOT DETECT auth being
                # switched off, because it already fails either way. Splitting
                # the verdict makes this probe STRICTER, not weaker: the
                # regression it now catches is one it was previously blind to.
                case " $AUTH_EXPECTED " in
                    *" $p "*)
                        ka="$(keyless_answer "$p")"
                        case "$ka" in
                            refused)  authed_list="${authed_list} ${p}" ;;
                            served)   open_list="${open_list} ${p}" ;;
                            *)
                                probe_examined "$n_checked" "store/UI ports"
                                probe_cannot_run "port ${p} is open and carries a credential requirement, but the keyless probe returned '${ka}' -- neither a refusal nor a served response. An unadjudicated auth check must not be scored either way."
                                ;;
                        esac
                        ;;
                    *) open_list="${open_list} ${p}" ;;
                esac
                ;;
        esac
    done

    probe_examined "$n_checked" "store/UI ports (control ${CONTROL_PORT} confirmed open)"

    case "$(classify "$c" "$open_list")" in
        FAIL)
            probe_fail "READABLE by every account on this Mac with no credential:${open_list}. Each was reached over loopback and, where it carries a credential requirement, an UNCREDENTIALLED request was SERVED rather than refused. The store-exposure finding was demonstrated against 7878 with one unauthenticated curl, and this is that same read succeeding.${authed_list:+ Reachable but correctly REFUSING keyless callers, which is not this defect:${authed_list}.}"
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

    # ── THE RUNNER'S CONTRACT, WHICH THIS FUNCTION USED TO BREAK ──────────
    #
    # run_box_walk.sh phase 1 invokes every probe with --self-test and reads:
    #     output contains 'VERDICT: BROKEN'  -> BROKEN
    #     else rc == 1                       -> ok, "goes red on known-bad input"
    #     else                               -> BROKEN, "returned N, expected 1"
    #
    # A --self-test is a NEGATIVE CONTROL: its job is to prove the probe CAN
    # return red. Ending the healthy path in probe_pass exits 0, so the runner
    # took the third branch and marked this probe BROKEN -- which is exactly
    # what the v1.0.50 walk recorded, and why its store-port verdict was
    # discarded rather than counted.
    #
    # The measurement was never wrong. The probe was reporting "my logic is
    # correct" in a slot that asks "prove you can fail", and the runner was
    # right to refuse it.
    #
    # THE TWO OUTCOMES STAY DISTINGUISHABLE, which is the whole point:
    #   cases misbehave -> emit VERDICT: BROKEN, runner reports BROKEN
    #   cases behave    -> probe_fail, exit 1, no BROKEN string, runner ok
    # Both exit 1; the RUNNER discriminates on the string, not the code. A
    # single exit code carrying two meanings is the defect class this whole
    # suite exists to refuse, so the discriminator is made explicit here.
    if [ -n "$fails" ]; then
        printf 'VERDICT: BROKEN -- %s self-test adjudication is wrong:%s\n' \
            "${PROBE_NAME:-no_store_port_is_tcp_reachable}" "$fails"
        printf '%s: BROKEN -- classify() misadjudicated%s, so this probe cannot be trusted to detect #550\n' \
            "${PROBE_NAME:-no_store_port_is_tcp_reachable}" "$fails"
        exit 1
    fi
    probe_fail "NEGATIVE CONTROL DEMONSTRATED (this red is the expected result of --self-test, not a finding): classify() returned FAIL on a fabricated open store port, PASS only with the control up and nothing open, and CANNOT_RUN on a stopped or unreadable control in both directions. 5 of 5 adjudication cases behaved."
}

probe_main "$@"
