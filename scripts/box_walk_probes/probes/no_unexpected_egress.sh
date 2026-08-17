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

# ---------------------------------------------------------------------------
# ATTRIBUTION IS AN EXCLUSION LIST, NOT AN INCLUSION LIST. This is the whole
# correctness argument of the file, so it is stated before the code.
#
# THIS PROBE SHIPPED WITH THE OPPOSITE, AND IT WAS BLIND. The first version
# kept only processes matching a hand-written product name list
#
#     ostler|Ostler|qdrant|oxigraph|ollama|mkdocs
#
# and silently dropped everything else. Run against a real box mid-install on
# 2026-08-17, it reported FOUR ollama sockets, all loopback, and PASSED. What
# was actually established on that machine at the same instant:
#
#     curl       185.199.109.153:443     outside the boundary
#     curl       185.199.109.154:443     outside the boundary
#     curl       20.205.243.164:443      outside the boundary
#     limactl    208.80.154.224:443      outside the boundary
#     tailscale  192.200.0.115:80        outside the boundary
#     tailscale  199.165.136.100:443     outside the boundary
#
# curl, limactl and tailscale are how the INSTALLER fetches, virtualises and
# joins the tailnet. They are as much "what Ostler runs" as ollama is, and not
# one of them matched the list. The green was a property of the regex, not of
# the machine, and it was queued to be published as evidence.
#
# So the default is inverted. An outside-boundary socket is REPORTABLE unless
# its process is positively named as belonging to the operator rather than to
# us. Unknown becomes loud instead of invisible, which is the same contract as
# verify_cut_freshness.sh's verify_exempt rows: an exclusion is a ledger line a
# reader can audit, never an absence they have to infer.
#
# Adding a process here is a claim that it is the OPERATOR'S, not ours. Get it
# wrong and the probe goes blind again, in exactly the way it just did.
# ---------------------------------------------------------------------------
# NOTE THE ANCHOR. lsof truncates COMMAND to 9 characters (sshd-sess, llama-ser,
# identityse), and the row is COMMAND<TAB>PID<TAB>REMOTE, so the name must be
# anchored to the TAB and not to end-of-line. The first version used $ and
# matched nothing at all: Mail and WhatsApp both came back flagged as ours on
# the very first fixture run. Truncated forms are listed explicitly.
OSTLER_EGRESS_FOREIGN_RE="${OSTLER_EGRESS_FOREIGN_RE:-^(Mail|WhatsApp|Messages|Safari|firefox|Google|Slack|Spotify|Dropbox|zoom|Music|Photos|AddressBook|akd|apsd|rapportd|nsurlsessi|nsurlsessiond|trustd|cloudd|bird|identityse|Finder|sshd|sshd-sess|ssh|mDNSRespon|mDNSResponder|configd|netbiosd|Terminal|iTerm2|Code)[[:space:]]}"

# Kept ONLY to label a row as unmistakably ours in the report. It no longer
# decides what is examined, and nothing is dropped for failing to match it.
OSTLER_EGRESS_PROC_RE="${OSTLER_EGRESS_PROC_RE:-ostler|Ostler|qdrant|oxigraph|ollama|mkdocs|curl|limactl|tailscale|colima|docker|python3}"

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
    probe_note "operator procs  : ${OSTLER_EGRESS_FOREIGN_RE}"
    probe_note "                  (EXCLUDED by name. Everything else is examined.)"
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

    # EXCLUDE the operator's own processes by name; keep EVERYTHING else. The
    # old code did the reverse and that is the defect this change exists to
    # fix, so the direction of this grep is the load-bearing character in the
    # file: -vE, not -E.
    local foreign_n
    ours="$(printf '%s' "$all" | grep -vE "$OSTLER_EGRESS_FOREIGN_RE" || true)"
    ours_n="$(printf '%s' "$ours" | grep -c . )"
    foreign_n=$((total_sockets - ours_n))

    probe_examined "${ours_n:-0}" "established connections examined (of ${total_sockets} on the box; ${foreign_n} excluded as the operator's own processes)"

    if [ "${ours_n:-0}" -eq 0 ]; then
        # Honest: this is not a pass. Nothing attributable to us was running,
        # so nothing about our egress was measured.
        probe_cannot_run "every established connection on the box belonged to a process named in the operator-process exclusion list. Nothing attributable to Ostler was observed, so this run says nothing about its egress. Start the product and re-run."
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
        probe_fail "$(printf '%s' "$outside" | grep -c .) attributable connection(s) to destinations outside the declared boundary. Each one is either a claim that needs correcting or a defect that needs fixing; neither is resolved by leaving it unreported."
    fi

    probe_pass "all ${ours_n} examined established connections were inside the declared boundary, across ${SAMPLES} samples. This is a floor, not a proof of no leak -- see the BLIND TO line above."
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

# ---------------------------------------------------------------------------
# --classify-fixture <file>
#
# Run the attribution and boundary logic over a RECORDED reading instead of a
# live box, and print the rows it would flag. One flagged row per line, exit 1
# if any, 0 if none.
#
# This exists so the reading that caught the blindness becomes a permanent
# control. The 2026-08-17 mid-install capture is committed as a fixture: under
# the old inclusion filter it flagged NOTHING, under this one it flags six.
# A test can now prove the regression cannot come back, which a self-test that
# only plants its own loopback socket could never do -- that control was
# working perfectly and was blind to this defect, because it never exercised
# ATTRIBUTION at all, only the boundary regex.
#
# Input format is exactly what sample_sockets emits: COMMAND<TAB>PID<TAB>REMOTE
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--classify-fixture" ]; then
    fixture="${2:-}"
    [ -f "$fixture" ] || { echo "CANNOT-RUN: no fixture at '${fixture}'" >&2; exit 2; }

    kept="$(grep -vE '^[[:space:]]*(#|$)' "$fixture" | grep -vE "$OSTLER_EGRESS_FOREIGN_RE" || true)"
    [ -n "$kept" ] || { echo "CANNOT-RUN: fixture has no rows left after exclusion" >&2; exit 2; }

    flagged=0
    while IFS=$'\t' read -r cmd pid remote; do
        [ -n "${remote:-}" ] || continue
        if is_outside_boundary "$remote"; then
            printf '%s\t%s\n' "$cmd" "$remote"
            flagged=$((flagged + 1))
        fi
    done <<< "$kept"

    [ "$flagged" -eq 0 ] && exit 0
    exit 1
fi

probe_main "$@"
