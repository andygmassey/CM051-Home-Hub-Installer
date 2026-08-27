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
# ATTRIBUTION IS BY EXECUTABLE PATH. NOTHING IS EXCLUDED BY NAME, NOTHING IS
# DROPPED. Archie broke the previous design 2026-08-17 and was right three ways.
#
# The old name list silently did three different jobs:
#   APPS the operator owns (Safari, Slack)  -- excluding those is defensible.
#   SHARED COURIERS (nsurlsessiond, cloudd, bird, apsd) -- these carry traffic
#     ON BEHALF OF WHOEVER ASKS. Excluding a courier by name takes with it
#     whatever WE asked it to carry, reported as "not examined".
#   THE FIVE SURFACES THE PRODUCT EXISTS TO READ -- WhatsApp, Messages, Mail,
#     AddressBook, Photos. `WhatsApp` WAS ON THE LIST. This probe's first real
#     finding was a WhatsApp session to Meta, found ONLY because our DAEMON
#     held the socket. Held by a process named "WhatsApp*" it would have been
#     dropped and the run would have printed clean. The probe was structurally
#     blind to the class of finding it had just made.
#
# So every socket is examined and each is attributed OURS or THIRD-PARTY by
# resolving the PID to its EXECUTABLE PATH. Third-party rows are PRINTED, never
# dropped, so a courier carrying our bytes is visible even when unattributable.
#
# This also retires a bug class: lsof truncates COMMAND to 9 characters, which
# is why the old list carried BOTH `nsurlsessi` and `nsurlsessiond`, plus
# `identityse` and `mDNSRespon`. Nothing matches a truncated name any more.
#
# STATED BLIND SPOT, printed on every run: if our code hands a request to a
# shared system courier, the socket belongs to the courier and this reports it
# THIRD-PARTY. That is a limit of socket-level observation, not a claim of
# cleanliness.
OSTLER_OURS_PATH_RE="${OSTLER_OURS_PATH_RE:-(/\.ostler/|/Ostler[A-Za-z]*\.app/|/ostler-|/OstlerInstaller\.app/|/colima|/lima|/Tailscale\.app/|/tailscale)}"

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
# THE ONE PLACE THE SOCKET READING IS DEFINED.
#
# Shared verbatim by the MEASUREMENT (sample_sockets) and by the CONTROL in
# self_test. If the control exercised a copy, the copy could drift and the
# control would go on certifying a reader nobody uses -- which is the shape of
# every finding in this file. One string, two callers, no drift possible.
#
# FIND the field containing '->', do not assume a position. lsof appends
# '(ESTABLISHED)' after the address, so $NF is the STATE and the address is
# $(NF-1). The first version of this used $NF, saw nothing at all, and the
# self-test caught it by failing to observe its own planted socket. Scanning
# for the arrow survives the state suffix being present, absent, or moved.
_EGRESS_LSOF_SNIPPET='lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk '"'"'NR>1 { for (f=NF; f>=1; f--) { i=index($f,"->"); if (i>0) { print $1 "\t" $2 "\t" substr($f,i+2); break } } }'"'"''

sample_sockets() {
    box_run "${_EGRESS_LSOF_SNIPPET}"' \
             | while IFS=$'"'"'\t'"'"' read -r c pp r; do
                 chain=""; cur="$pp"; n=0
                 while [ -n "$cur" ] && [ "$cur" != 1 ] && [ "$cur" != 0 ] && [ $n -lt 8 ]; do
                   chain="${chain}:$(ps -p "$cur" -o comm= 2>/dev/null)"
                   cur=$(ps -p "$cur" -o ppid= 2>/dev/null | tr -d " ")
                   n=$((n+1))
                 done
                 printf "%s\t%s\t%s\t%s\n" "$c" "$pp" "$r" "$chain"
               done'
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

# is_ours <ancestor-chain> -> 0 if WE are anywhere in the process's lineage.
#
# LINEAGE, NOT THE PROCESS'S OWN PATH, and this is the correction that matters.
# Matching only the socket-holder's executable drops the exact finding this
# probe exists for: the installer fetches with /usr/bin/curl and virtualises
# with limactl, whose paths say "Apple" and "Homebrew", not "Ostler". A system
# binary WE spawned is OURS; the same binary spawned by the operator's shell is
# not, and only the parent chain can tell them apart.
#
# The chain is the socket-holder plus up to 8 ancestors, colon-joined, bounded
# so a pid cycle cannot hang a sample.
#
# grep -c not -q: under pipefail a -q exit races SIGPIPE.
is_ours() {
    [ -n "${1:-}" ] || return 1
    [ "$(printf '%s' "$1" | grep -cE "$OSTLER_OURS_PATH_RE")" -gt 0 ]
}

# attribution_of <ancestor-chain> -> ours | third-party | unattributable
#
# THREE STATES, AND THE THIRD ONE IS THE POINT. is_ours() answers a yes/no
# question, and a yes/no answer cannot distinguish "this is definitely somebody
# else's process" from "I could not find out whose process this is". Before this
# function existed, both landed in the same bucket and the report described that
# bucket, in words, as "the operator's own processes".
#
# THE FAILURE IS BIASED TOWARDS EXONERATING US, which is what makes it worse
# than a coin flip. sample_sockets() builds the chain by walking `ps` from the
# socket-holder upwards, AFTER lsof has already listed the socket. A process
# that exits in that window yields an empty chain -- and the processes most
# likely to exit in a sub-second window are exactly ours: the short-lived curl
# and python3 calls the installer and the ingest ticks are built out of. A
# long-running browser is still there when the walk happens. So the sockets this
# probe silently reassigned to the customer were disproportionately the ones it
# was built to watch.
#
# An unattributable socket is NOT evidence of a leak. It is the absence of
# evidence either way, and it has to be counted and printed as such, because a
# blind spot that is not reported reads exactly like a clean result.
#
# A chain of only separators (":", ":::") means every `ps` in the walk returned
# empty -- raced or permission-denied -- so it is unattributable too, not a
# third party with a funny name.
attribution_of() {
    local chain="${1:-}"
    case "$(printf '%s' "$chain" | tr -d ': \t')" in
        "") printf 'unattributable\n'; return 0 ;;
    esac
    if is_ours "$chain"; then printf 'ours\n'; else printf 'third-party\n'; fi
}

is_outside_boundary() {   # $1 = remote address:port
    local host="${1%:*}"
    printf '%s' "$host" | grep -qE "$OSTLER_EGRESS_ALLOWED_RE" && return 1
    return 0
}

# ---------------------------------------------------------------------------
# DETECTION CAPABILITY, PROVED ON EVERY RUN -- not in a self-test somebody
# remembers to invoke.
#
# Plants a real loopback socket ON THE SAMPLING HOST and returns the sampler's
# own reading of it. Echoes "__PORT__ <p>" then the raw socket lines.
#
# Everything is co-located inside ONE box_run. That is the whole point: the
# previous control planted locally and sampled remotely, so it observed
# nothing on every walk and reported PASS anyway.
# ---------------------------------------------------------------------------
plant_and_sample() {
    box_run '
        set -u
        command -v python3 >/dev/null 2>&1 || { echo "__NOPY__"; exit 0; }
        T=$(mktemp -t egressctl.XXXXXX) || { echo "__NOTMP__"; exit 0; }
        cat > "$T" <<'"'"'PYCTL'"'"'
import socket, sys, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
cli = socket.socket(); cli.connect(("127.0.0.1", port))
conn, _ = srv.accept()
sys.stdout.write(str(port) + "\n"); sys.stdout.flush()
time.sleep(20)
PYCTL
        python3 "$T" > "$T.port" 2>/dev/null &
        CPID=$!
        n=0
        while [ ! -s "$T.port" ] && [ $n -lt 60 ]; do sleep 0.1; n=$((n+1)); done
        P=$(tr -d " \n" < "$T.port" 2>/dev/null)
        [ -n "$P" ] || { kill $CPID 2>/dev/null; rm -f "$T" "$T.port"; echo "__NOPORT__"; exit 0; }
        echo "__PORT__ $P"
        '"$_EGRESS_LSOF_SNIPPET"'
        kill $CPID 2>/dev/null; rm -f "$T" "$T.port"
    '
}

# The POSITIVE control, run before any measurement is reported. If the sampler
# cannot see a socket that is definitely there, this run has measured nothing
# and must say so -- CANNOT-RUN (exit 2), never a quiet exit 0.
#
# "Nothing found" and "nothing looked at" print identically unless something
# refuses to let them.
assert_detection_capability() {
    local out port seen
    out="$(plant_and_sample)"
    case "$out" in
        *__NOPY__*)   probe_cannot_run "python3 is not available where the sampler runs, so detection capability could not be established. This run proves nothing about egress." ;;
        *__NOTMP__*)  probe_cannot_run "could not create a temp file where the sampler runs; detection capability not established." ;;
        *__NOPORT__*) probe_cannot_run "the control socket never came up where the sampler runs; detection capability not established." ;;
    esac
    port="$(printf '%s\n' "$out" | sed -n 's/^__PORT__ //p' | head -1)"
    [ -n "$port" ] || probe_cannot_run "the control did not report a port; detection capability not established."

    seen="$(printf '%s\n' "$out" | grep -E "^(python3|Python)" | grep -F ":${port}" || true)"
    if [ -z "$seen" ]; then
        probe_cannot_run "POSITIVE CONTROL FAILED: the sampler did not observe a loopback socket planted on the sampling host itself. It cannot see an established connection that is definitely there, so a clean reading below would be uninterpretable. This is CANNOT-RUN, not a pass."
    fi
    probe_note "detection proved: planted socket on :${port} observed by this run's own sampler"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi

    # EVERY RUN, BEFORE ANY VERDICT. A pass from an instrument that has not
    # demonstrated it can detect is indistinguishable from a pass from one that
    # is blind, and those two print the same string.
    assert_detection_capability

    probe_note "boundary policy : ${OSTLER_EGRESS_ALLOWED_RE}"
    # SAY WHICH BOUNDARY. The regex above is the LOCAL-NETWORK boundary --
    # loopback, RFC1918, link-local, CGNAT. It is the only thing consulted on
    # this path. egress_hosts.tsv, the contemporaneous dig loop and the live
    # DERP map are all read by self_test() and by nothing else, so on a walk a
    # destination the ledger DECLARES is reported exactly like one it does not.
    # Measured 2026-08-27: two of three flagged addresses were
    # controlplane.tailscale.com (ledger rows 30/54) and a DERP relay
    # (derp20c.tailscale.com). See #1145.
    probe_note "ledger          : NOT consulted on this path -- ${HOSTS_FILE:-egress_hosts.tsv} and the DERP map are read only by self_test (#1145)"
    probe_note "ours (lineage)  : ${OSTLER_OURS_PATH_RE}"
    probe_note "                  Matched against the socket-holder AND its"
    probe_note "                  ancestors. NOTHING is excluded by name."
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
    # THREE BUCKETS. The third one is the fix: a socket whose owner we could not
    # resolve is NOT the operator's, it is UNKNOWN, and it is counted and named
    # as unknown. See attribution_of() for why conflating the two was biased
    # towards clearing us rather than towards a false alarm.
    local third_n unattrib unattrib_n
    ours="$(printf '%s\n' "$all" | while IFS=$'\t' read -r c p r path; do
        [ "$(attribution_of "${path:-}")" = ours ] && printf '%s\t%s\t%s\t%s\n' "$c" "$p" "$r" "$path"
    done || true)"
    unattrib="$(printf '%s\n' "$all" | while IFS=$'\t' read -r c p r path; do
        [ "$(attribution_of "${path:-}")" = unattributable ] && printf '%s\t%s\t%s\n' "$c" "$p" "$r"
    done || true)"
    ours_n="$(printf '%s' "$ours" | grep -c . )"
    unattrib_n="$(printf '%s' "$unattrib" | grep -c . )"
    third_n=$(( total_sockets - ours_n - unattrib_n ))

    probe_examined "${ours_n:-0}" "established connections examined (of ${total_sockets} on the box; ${third_n} attributed to the operator's own processes; ${unattrib_n} UNATTRIBUTABLE)"

    # Print them. An unreported blind spot is indistinguishable from a clean run,
    # which is the whole complaint this change answers.
    if [ "${unattrib_n:-0}" -gt 0 ]; then
        probe_note "UNATTRIBUTABLE (owner could not be resolved; may be ours, may not):"
        printf '%s\n' "$unattrib" | while IFS=$'\t' read -r c p r; do
            [ -n "${c:-}" ] && printf '    %s (pid %s) -> %s\n' "$c" "$p" "$r"
        done
    fi

    if [ "${ours_n:-0}" -eq 0 ]; then
        # Honest: this is not a pass. Nothing attributable to us was running,
        # so nothing about our egress was measured.
        probe_cannot_run "every established connection on the box belonged to a process named in the operator-process exclusion list. Nothing attributable to Ostler was observed, so this run says nothing about its egress. Start the product and re-run."
    fi

    # THE BLIND-SPOT CEILING. If we could not attribute more sockets than we
    # could, the examined set is not a representative floor and a PASS off it
    # would be a guess dressed as a measurement. Deliberately a ratio and not
    # "any unattributable at all": a single raced short-lived process is normal
    # on a busy box, and a probe that refuses to run on one is a probe nobody
    # keeps. The threshold is stated so it can be argued with.
    if [ "${unattrib_n:-0}" -gt "${ours_n:-0}" ]; then
        probe_cannot_run "more sockets were UNATTRIBUTABLE (${unattrib_n}) than were attributable to Ostler (${ours_n}). The examined set is not a floor worth reporting: the processes that race the ps-walk are disproportionately short-lived ones like ours. Re-run when the box is quieter, or raise OSTLER_EGRESS_SAMPLES."
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
        probe_fail "$(printf '%s' "$outside" | grep -c .) attributable connection(s) to destinations outside the LOCAL-NETWORK boundary (loopback, RFC1918, link-local, CGNAT). THE DECLARED LEDGER WAS NOT CONSULTED on this path, so a destination egress_hosts.tsv declares is listed here exactly like one it does not -- do not read this list as undeclared traffic (#1145). Each one is a claim to check against the ledger by hand, a claim that needs correcting, or a defect that needs fixing; none is resolved by leaving it unreported."
    fi

    # The PASS line CARRIES the blind-spot count. A verdict that states its own
    # denominator and its own unknowns cannot be quoted as "clean" by someone
    # reading only the last line, which is how a floor gets promoted to a proof.
    probe_pass "all ${ours_n} examined established connections were inside the LOCAL-NETWORK boundary, across ${SAMPLES} samples, with ${unattrib_n} socket(s) unattributable. This says nothing about the declared ledger, which is not consulted on this path (#1145): it means no examined connection left the local network at all. A floor, not a proof of no leak -- see the BLIND TO line above."
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

    command -v python3 >/dev/null 2>&1 || \
        probe_cannot_run "python3 is needed to plant the control socket"

    # 🔴 THE PLANTED SOCKET AND THE SAMPLER MUST BE ON THE SAME MACHINE.
    #
    # This is the defect that made every walk-time clean run uninterpretable,
    # and it was invisible from a local run.
    #
    # The old control planted a python socket with a bare `python3 ... &` --
    # i.e. on the machine RUNNING the probe -- and then called sample_sockets,
    # which goes through box_run. box_run SSHes to $OSTLER_BOX_HOST when it is
    # set, and a walk always sets it. So lsof ran on the TARGET box while the
    # socket existed on the LAPTOP. The control could not observe its own
    # planted socket for the same reason you cannot see your own house from
    # inside someone else's.
    #
    # It set SELF_TEST_LOCAL=1 intending to prevent exactly this. Nothing ever
    # read that variable -- `grep -rn SELF_TEST_LOCAL` returns its own
    # assignment and nothing else. A write-only flag, the same shape as #678.
    #
    # MEASURED, both directions, before the fix:
    #     local  (OSTLER_BOX_HOST unset)   EXAMINED: 1   control behaves
    #     remote (OSTLER_BOX_HOST set)     EXAMINED: 0   "CONTROL DID NOT EVEN
    #                                                     OBSERVE ITS OWN
    #                                                     PLANTED SOCKET"
    #
    # The fix is not to make box_run honour the flag. It is to remove the
    # possibility: plant, sample and tear down in ONE box_run, so the socket
    # and the sampler are co-located by construction rather than by a variable
    # somebody has to remember to read. There is no longer a flag to get wrong.
    local out port seen
    out="$(box_run '
        set -u
        command -v python3 >/dev/null 2>&1 || { echo "__NOPY__"; exit 0; }
        T=$(mktemp -t egressctl.XXXXXX) || { echo "__NOTMP__"; exit 0; }
        cat > "$T" <<'"'"'PYCTL'"'"'
import socket, sys, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
cli = socket.socket(); cli.connect(("127.0.0.1", port))
conn, _ = srv.accept()
sys.stdout.write(str(port) + "\n"); sys.stdout.flush()
time.sleep(20)
PYCTL
        python3 "$T" > "$T.port" 2>/dev/null &
        CPID=$!
        n=0
        while [ ! -s "$T.port" ] && [ $n -lt 60 ]; do sleep 0.1; n=$((n+1)); done
        P=$(tr -d " \n" < "$T.port" 2>/dev/null)
        [ -n "$P" ] || { kill $CPID 2>/dev/null; rm -f "$T" "$T.port"; echo "__NOPORT__"; exit 0; }
        echo "__PORT__ $P"
        '"$_EGRESS_LSOF_SNIPPET"'
        kill $CPID 2>/dev/null; rm -f "$T" "$T.port"
    ')"

    case "$out" in
        *__NOPY__*)   probe_cannot_run "python3 is not available where the sampler runs; the control socket could not be planted there" ;;
        *__NOTMP__*)  probe_cannot_run "could not create a temp file where the sampler runs" ;;
        *__NOPORT__*) probe_cannot_run "the control socket never came up where the sampler runs; nothing was proved either way" ;;
    esac
    port="$(printf '%s\n' "$out" | sed -n 's/^__PORT__ //p' | head -1)"
    if [ -z "$port" ]; then
        probe_cannot_run "the control did not report a port; nothing was proved either way"
    fi

    # SAME host, SAME lsof snippet the measurement uses.
    seen="$(printf '%s\n' "$out" | grep -E "^(python3|Python)" | grep -F ":${port}" || true)"
    cleanup() { :; }

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
# ---------------------------------------------------------------------------
# --inventory
#
# Produce the ATTRIBUTED inventory: every outside-boundary connection, joined
# to a declared host, with a stated purpose. Unmatched observations are printed
# as UNATTRIBUTED and are the point of the exercise.
#
# THE JOIN IS CONTEMPORANEOUS AND THAT IS THE WHOLE DESIGN. The socket read and
# the hostname resolution happen in ONE remote invocation, on the same box, at
# the same instant. Resolving afterwards is unsound: on 2026-08-17 github.com
# returned 20.205.243.166 and then 140.82.114.3 inside a single minute, so an
# address observed at time T cannot be attributed by a lookup at T+n. Two of
# six addresses in the first attempt matched only because the lookup happened
# to be close enough in time to get lucky.
#
# WHAT THIS STILL DOES NOT PROVE, stated because a sceptic will ask:
#   a shared CDN address serves many tenants, so a match is "consistent with",
#   never "was". Content is not observed at all. This narrows what an
#   unexplained connection could be. It does not certify what an explained one
#   carried, and the ledger's third column is a CLAIM by us, not a measurement.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--inventory" ]; then
    HOSTS_FILE="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/egress_hosts.tsv}"
    [ -f "$HOSTS_FILE" ] || { echo "CANNOT-RUN: no declared host ledger at '$HOSTS_FILE'" >&2; exit 2; }

    hosts="$(grep -vE '^[[:space:]]*(#|$)' "$HOSTS_FILE" | cut -f1 | tr '\n' ' ')"
    [ -n "$hosts" ] || { echo "CANNOT-RUN: ledger declares no hosts" >&2; exit 2; }

    # DYNAMIC SOURCES. Some destinations cannot be declared statically and
    # pretending otherwise would make the inventory permanently noisy, which is
    # how a report gets ignored. Tailscale is the case in point: the client
    # FETCHES its DERP map from the control plane at runtime and picks a relay
    # by latency, so the relay address set is served, not fixed, and rotates.
    # A static row would be wrong within days.
    #
    # So the probe fetches the SAME map the client used, in the SAME call as
    # the socket read, and treats its node addresses as attributed to the
    # relay purpose. Contemporaneous, like everything else here.
    derp_purpose="tailnet: encrypted relay when no direct path exists"
    derp_carries="relayed WireGuard packets. Tailscale cannot read them; keys never leave the devices."

    # ONE remote call: sockets, resolutions and the DERP map together, same instant.
    joint="$(box_run "
        curl -fsS --max-time 8 https://controlplane.tailscale.com/derpmap/default 2>/dev/null \
          | python3 -c \"
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for rid,r in (d.get('Regions') or {}).items():
    for n in (r.get('Nodes') or []):
        ip=n.get('IPv4')
        if ip: print('DERP\\t%s\\t%s' % (n.get('HostName') or 'derp', ip))
\" 2>/dev/null
        lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
          | awk 'NR>1 { for (f=NF; f>=1; f--) { i=index(\$f,\"->\"); if (i>0) { print \"SOCK\t\" \$1 \"\t\" substr(\$f,i+2) \"\t\" \$2; break } } }'
        for h in ${hosts}; do
            for a in \$(dig +short +time=3 +tries=1 \"\$h\" 2>/dev/null | grep -E '^[0-9]+\.'); do
                printf 'HOST\t%s\t%s\n' \"\$h\" \"\$a\"
            done
        done
    ")"
    [ -n "$joint" ] || { echo "CANNOT-RUN: the box returned nothing; not a clean result" >&2; exit 2; }

    resolved="$(printf '%s\n' "$joint" | grep '^HOST	' || true)"
    derps="$(printf '%s\n' "$joint" | grep '^DERP	' || true)"
    # Exclusion happens per row in the loop below, against the COMMAND field,
    # not here against the whole line. Filtering the tagged stream would match
    # the tag and the address too.
    socks="$(printf '%s\n' "$joint" | grep '^SOCK	' || true)"

    echo "DECLARED EGRESS INVENTORY"
    echo "  ledger        : $HOSTS_FILE ($(printf '%s\n' "$hosts" | wc -w | tr -d ' ') hosts declared)"
    echo "  resolutions   : $(printf '%s\n' "$resolved" | grep -c . ) addresses, resolved ON THE BOX in the SAME call as the socket read"
    echo "  derp map      : $(printf '%s\n' "$derps" | grep -c . ) relay nodes, fetched live in that same call (served, not declarable)"
    echo "  NOT PROOF     : shared CDN addresses serve many tenants, so a match is"
    echo "                  'consistent with', never 'was'. Content is never observed."
    echo

    att=0; unatt=0
    while IFS=$'\t' read -r tag cmd remote path; do
        [ "$tag" = "SOCK" ] || continue
        is_ours "${path:-}" || continue
        is_outside_boundary "$remote" || continue
        ip="${remote%:*}"
        host="$(printf '%s\n' "$resolved" | awk -F'\t' -v ip="$ip" '$3==ip {print $2; exit}')"
        derp="$(printf '%s\n' "$derps" | awk -F'\t' -v ip="$ip" '$3==ip {print $2; exit}')"
        if [ -z "$host" ] && [ -n "$derp" ]; then
            printf '  ATTRIBUTED    %-12s %-22s %s\n' "$cmd" "$ip" "$derp"
            printf '                purpose : %s\n' "$derp_purpose"
            printf '                carries : %s\n' "$derp_carries"
            printf '                source  : live DERP map from controlplane.tailscale.com, fetched in this same call\n'
            att=$((att + 1))
            continue
        fi
        if [ -n "$host" ]; then
            purpose="$(grep -E "^${host}	" "$HOSTS_FILE" | cut -f2)"
            carries="$(grep -E "^${host}	" "$HOSTS_FILE" | cut -f3)"
            printf '  ATTRIBUTED    %-12s %-22s %s\n' "$cmd" "$ip" "$host"
            printf '                purpose : %s\n' "$purpose"
            printf '                carries : %s\n' "$carries"
            att=$((att + 1))
        else
            printf '  UNATTRIBUTED  %-12s %-22s no declared host resolved to this address\n' "$cmd" "$ip"
            unatt=$((unatt + 1))
        fi
    done <<< "$(printf '%s\n' "$socks" | sort -u)"

    echo
    echo "  attributed=${att}  unattributed=${unatt}"
    [ "$unatt" -eq 0 ] && { echo "  every outside-boundary connection matched a declared host."; exit 0; }
    echo "  UNATTRIBUTED connections are not a pass. Either the ledger is incomplete" >&2
    echo "  or something is talking to a destination nobody declared." >&2
    exit 1
fi

if [ "${1:-}" = "--classify-fixture" ]; then
    fixture="${2:-}"
    [ -f "$fixture" ] || { echo "CANNOT-RUN: no fixture at '${fixture}'" >&2; exit 2; }

    kept="$(grep -vE '^[[:space:]]*(#|$)' "$fixture" || true)"
    [ -n "$kept" ] || { echo "CANNOT-RUN: fixture has no rows left after exclusion" >&2; exit 2; }

    flagged=0; ours_seen=0
    while IFS=$'\t' read -r cmd pid remote path; do
        [ -n "${remote:-}" ] || continue
        is_ours "${path:-}" || continue
        ours_seen=$((ours_seen + 1))
        if is_outside_boundary "$remote"; then
            printf '%s\t%s\n' "$cmd" "$remote"
            flagged=$((flagged + 1))
        fi
    done <<< "$kept"

    # Nothing of ours in the reading is CANNOT-RUN, never a quiet pass: the run
    # observed no Ostler-owned connection, so it says nothing about our egress.
    if [ "$ours_seen" -eq 0 ]; then
        echo "CANNOT-RUN: no row in the fixture is attributable to us by lineage." >&2
        exit 2
    fi
    [ "$flagged" -eq 0 ] && exit 0
    exit 1
fi

probe_main "$@"
