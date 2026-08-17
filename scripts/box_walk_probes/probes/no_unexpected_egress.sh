#!/usr/bin/env bash
# probes/no_unexpected_egress.sh
# ============================================================================
# QUESTION: does anything Ostler runs hold a connection to a destination
#           outside the local boundary the product claims never to cross?
#
# WHY THIS EXISTS
#
# The strongest thing the product says is that your data stays on your Mac. A
# cold outside read of the marketing site reached "a diagram, not a proof",
# and it was right: the estate had ZERO runnable instruments that observe the
# network at all. Searched OS003 and CM051 on 2026-08-17 with a positive
# control (11 OS003 files mention codesign/spctl, 43 in CM051, so the search
# could speak). The only lsof in a probe was daemon_is_listening.sh, and that
# reads INBOUND listeners. Nothing had ever looked at what goes OUT.
#
# An inventory built by grepping source for URLs is the same diagram-not-a-
# proof error in different clothes: it enumerates what someone WROTE, not what
# the machine DOES, and it cannot see a call made through a dependency.
#
# ---------------------------------------------------------------------------
# WHAT THIS MEASURES, AND WHAT IT CANNOT SEE
#
# It reads ESTABLISHED TCP sockets, per process, and classifies each remote
# address against a declared boundary. That is a SAMPLE, not a capture.
#
#   IT CANNOT SEE a connection that opens and closes between two samples.
#   IT CANNOT SEE UDP, or DNS, or a request proxied by another process.
#   IT CANNOT SEE the CONTENT of anything -- an allowed destination carrying
#   the wrong payload looks identical to one carrying the right payload.
#
# Those limits are stated here, printed by the probe on every run, and are the
# reason this reports an INVENTORY WITH A DENOMINATOR rather than a bare
# "no egress". "Nothing found" and "nothing looked at" print identically
# unless the denominator is on the page.
#
# A clean result from this probe means: across N samples of M processes, every
# established connection was inside the boundary. It does not mean the product
# cannot leak. It is the floor of an evidence chain, not the whole of it, and
# saying otherwise would repeat the failure it exists to correct.
#
# ---------------------------------------------------------------------------
# THE BOUNDARY IS DECLARED, NOT ASSUMED
#
# OSTLER_EGRESS_ALLOWED_RE is the policy: a remote address matching it is
# inside the boundary. The default admits loopback, RFC1918 LAN, link-local
# and the Tailscale CGNAT range, because the product is explicitly a
# single-machine product reachable over the operator's own tailnet.
#
# It is a variable and not a hardcoded list precisely so the SELF-TEST can
# narrow it and watch a real connection get flagged. A policy that can never
# reject anything is not a policy.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="no_unexpected_egress"
PROBE_QUESTION="does anything Ostler runs hold a connection outside the local boundary?"

# Processes considered part of the product. Matched against lsof's COMMAND.
OSTLER_EGRESS_PROC_RE="${OSTLER_EGRESS_PROC_RE:-ostler|Ostler|qdrant|oxigraph|ollama|mkdocs}"

# Inside the boundary. See the header: declared, not assumed.
OSTLER_EGRESS_ALLOWED_RE="${OSTLER_EGRESS_ALLOWED_RE:-^(127\.|\[::1\]|localhost|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|\[f[cd]|\[fe80)}"

SAMPLES="${OSTLER_EGRESS_SAMPLES:-3}"
SAMPLE_GAP="${OSTLER_EGRESS_SAMPLE_GAP:-2}"

# ---------------------------------------------------------------------------
# One sample: "COMMAND<TAB>PID<TAB>REMOTE" per established TCP socket.
#
# lsof's NAME column for an established socket is "local->remote"; the remote
# half is what a boundary question is about. -n and -P keep it numeric so the
# classification is not at the mercy of reverse DNS, which can hang and can
# also rewrite an address into a name the policy regex would miss.
# ---------------------------------------------------------------------------
sample_sockets() {
    # FIND the field containing '->', do not assume a position. lsof appends
    # '(ESTABLISHED)' after the address, so \$NF is the STATE and the address is
    # \$(NF-1). The first version of this used \$NF, saw nothing at all, and the
    # self-test caught it by failing to observe its own planted socket. Scanning
    # for the arrow survives the state suffix being present, absent, or moved.
    box_run "lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
             | awk 'NR>1 { for (f=NF; f>=1; f--) { i=index(\$f,\"->\"); if (i>0) { print \$1 \"\t\" \$2 \"\t\" substr(\$f,i+2); break } } }'"
}

# Everything the product owns, across the samples, deduplicated.
collect() {
    local i out=""
    for i in $(seq 1 "$SAMPLES"); do
        out="${out}$(sample_sockets)
"
        [ "$i" -lt "$SAMPLES" ] && sleep "$SAMPLE_GAP"
    done
    printf '%s' "$out" | grep -vE '^[[:space:]]*$' | sort -u
}

is_outside_boundary() {   # $1 = remote address:port
    local host="${1%:*}"
    printf '%s' "$host" | grep -qE "$OSTLER_EGRESS_ALLOWED_RE" && return 1
    return 0
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi

    probe_note "boundary policy : ${OSTLER_EGRESS_ALLOWED_RE}"
    probe_note "product procs   : ${OSTLER_EGRESS_PROC_RE}"
    probe_note "sampling        : ${SAMPLES} samples, ${SAMPLE_GAP}s apart"
    probe_note "BLIND TO        : sub-sample-lifetime connections, UDP, DNS,"
    probe_note "                  proxied requests, and all payload content."

    local all ours total_sockets ours_n outside
    all="$(collect)"
    total_sockets="$(printf '%s' "$all" | grep -c . )"

    if [ "${total_sockets:-0}" -eq 0 ]; then
        # A zero here is far more likely to be a probe that could not read than
        # a machine with no TCP at all. Refuse to call it clean.
        probe_cannot_run "lsof returned no established sockets at all across ${SAMPLES} samples -- not even the ssh session or a browser. That is a probe that cannot see, not a quiet machine."
    fi

    ours="$(printf '%s' "$all" | grep -E "^(${OSTLER_EGRESS_PROC_RE})" || true)"
    ours_n="$(printf '%s' "$ours" | grep -c . )"

    probe_examined "${ours_n:-0}" "distinct Ostler-owned established connections (of ${total_sockets} on the box)"

    if [ "${ours_n:-0}" -eq 0 ]; then
        # Honest: this is not a pass. Nothing of the product was running, so
        # nothing about the product was measured.
        probe_cannot_run "no process matching '${OSTLER_EGRESS_PROC_RE}' held any established connection. Nothing of the product was observed, so this run says nothing about its egress. Start the product and re-run."
    fi

    outside=""
    while IFS=$'\t' read -r cmd pid remote; do
        [ -n "${remote:-}" ] || continue
        if is_outside_boundary "$remote"; then
            outside="${outside}    ${cmd} (pid ${pid}) -> ${remote}
"
        fi
    done <<< "$ours"

    if [ -n "$outside" ]; then
        probe_note "OUTSIDE THE BOUNDARY:"
        printf '%s' "$outside"
        probe_fail "$(printf '%s' "$outside" | grep -c .) Ostler-owned connection(s) to destinations outside the declared boundary. Each one is either a claim that needs correcting or a defect that needs fixing; neither is resolved by leaving it unreported."
    fi

    probe_pass "all ${ours_n} Ostler-owned established connections were inside the declared boundary, across ${SAMPLES} samples. This is a floor, not a proof of no leak -- see the BLIND TO line above."
}

# ---------------------------------------------------------------------------
# SELF-TEST -- and this one plants a REAL socket rather than adjudicating a
# synthetic reading set.
#
# It stands up a listener and a client inside this machine, then runs the SAME
# classifier over the SAME lsof output twice, changing only the declared
# boundary:
#
#   RED   : boundary excludes loopback -> the real connection MUST be flagged
#   GREEN : boundary includes loopback -> the same connection MUST NOT be
#
# Both directions matter. A probe only ever seen firing is not known to be
# able to pass, and one only ever seen passing is not known to be able to
# fire. Nothing leaves the machine at any point: the "leak" is a loopback
# socket that the RED policy declines to excuse.
#
# EXIT CONVENTION, which is inverted and not a mistake: run_box_walk.sh line
# 130 expects --self-test to return 1 when the negative control behaved
# correctly. probe_fail is therefore the SUCCESS path here.
# ---------------------------------------------------------------------------
self_test() {
    SELF_TEST_LOCAL=1

    command -v python3 >/dev/null 2>&1 || \
        probe_cannot_run "python3 is needed to plant the control socket"

    local port pyfile pid
    pyfile="$(mktemp -t egressctl.XXXXXX)"
    cat > "$pyfile" <<'PY'
import socket, sys, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
cli = socket.socket(); cli.connect(("127.0.0.1", port))
conn, _ = srv.accept()
print(port, flush=True)
time.sleep(float(sys.argv[1]))
PY
    # Hold the socket open long enough for the sampler to see it.
    python3 "$pyfile" 25 > "${pyfile}.port" 2>/dev/null &
    pid=$!
    # Wait for the port line rather than sleeping a guess.
    local waited=0
    while [ ! -s "${pyfile}.port" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    port="$(cat "${pyfile}.port" 2>/dev/null | tr -d ' \n')"
    cleanup() { kill "$pid" 2>/dev/null; rm -f "$pyfile" "${pyfile}.port"; }

    if [ -z "$port" ]; then
        cleanup
        probe_cannot_run "could not plant the control socket; nothing was proved either way"
    fi

    # The classifier reads THIS process's sockets, so the product filter is
    # narrowed to python3 for the control. The thing under test is the
    # BOUNDARY DECISION, and that is exercised for real.
    local seen red_hits green_hits
    OSTLER_EGRESS_PROC_RE='python3|Python'
    SAMPLES=1
    seen="$(sample_sockets | grep -E "^(python3|Python)" | grep -F ":${port}" || true)"

    probe_examined "$(printf '%s' "$seen" | grep -c .)" "planted loopback socket(s) observed by the real sampler"

    if [ -z "$seen" ]; then
        cleanup
        probe_pass "CONTROL DID NOT EVEN OBSERVE ITS OWN PLANTED SOCKET. The sampler cannot see an established connection that is definitely there, so every clean run this probe has ever produced is uninterpretable."
    fi

    # RED: a boundary that does not excuse loopback must flag it.
    OSTLER_EGRESS_ALLOWED_RE='^(10\.)'
    red_hits=0
    while IFS=$'\t' read -r _c _p remote; do
        [ -n "${remote:-}" ] && is_outside_boundary "$remote" && red_hits=$((red_hits + 1))
    done <<< "$seen"

    # GREEN: the shipping boundary excuses loopback, so the same socket must not.
    OSTLER_EGRESS_ALLOWED_RE='^(127\.|\[::1\]|localhost)'
    green_hits=0
    while IFS=$'\t' read -r _c _p remote; do
        [ -n "${remote:-}" ] && is_outside_boundary "$remote" && green_hits=$((green_hits + 1))
    done <<< "$seen"

    cleanup

    if [ "$red_hits" -eq 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a real established connection to an address the policy does NOT excuse was classified as inside the boundary. This probe cannot detect the thing it exists for."
    fi
    if [ "$green_hits" -ne 0 ]; then
        probe_pass "CONTROL OVER-FIRED: a loopback connection was flagged as egress under a policy that excuses loopback. This probe would red every healthy box."
    fi

    probe_fail "negative control behaved correctly on a REAL planted socket: flagged (${red_hits}) under a boundary that excludes loopback, and not flagged (${green_hits}) under one that includes it. Nothing left the machine."
}

probe_main "$@"
