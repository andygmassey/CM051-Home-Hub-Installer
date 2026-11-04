#!/bin/bash
# scripts/walk_net_sampler.sh -- host and in-VM network samplers for a box walk
#
#   walk_net_sampler.sh start  --out DIR [--period N]
#   walk_net_sampler.sh stop   --out DIR
#   walk_net_sampler.sh report --out DIR
#
# Runs ON the walk box, started BEFORE the install and stopped after the walk.
#
# WHY (v1.0.123 egress audit, v1.0.124 brief)
# -------------------------------------------
# The v1.0.123 walk sampled host sockets by hand and found gws calling Google
# 76 times in 5 h. The walk's own no_unexpected_egress probe had reported PASS
# from a 6 s window. Two gaps were written down and are closed here:
#
#   1. The host sampler was a hand-typed loop. It is now a script with a
#      control: a held `nc example.com 80` on the host. A sampler whose control
#      was not seen reports CANNOT-RUN, never PASS.
#   2. Container egress inside the colima VM was NOT INSTRUMENTED: it leaves
#      through VM NAT, so host lsof only sees limactl. The in-VM sampler reads
#      the VM's conntrack table (conntrack -L, else /proc/net/nf_conntrack,
#      else `ss -tnp`, which sees the VM namespace only) and maps container IPs
#      with `docker ps`. Its control is a held connection to example.com:80
#      from the VM shell itself (nc, else curl, else wget). No image is pulled.
#
# WHAT A SAMPLE IS. Every sampler here is a periodic SAMPLE, not a capture. A
# connection that opens and closes between two samples is invisible to the
# lsof and ss methods. conntrack keeps closed TCP entries for a while
# (TIME_WAIT), so the VM's conntrack method misses less. Counts are samples,
# not connections. The gws count is taken from the unified log as well, for
# exactly that reason.
#
# OUTPUT (all under --out DIR)
#   status.tsv          epoch, utc, sampler, event, detail
#   host_samples.tsv    epoch, utc, rows_connected, rows_outbound | CANNOT-RUN reason
#   host_outbound.tsv   epoch, utc, cmd, pid, user, proto, local, raddr, rport, state
#   vm_samples.tsv      epoch, utc, method, rows_flows, rows_outbound | CANNOT-RUN reason
#   vm_outbound.tsv     epoch, utc, method, proto, src, dst, dport, state, container
#   controls.tsv        sampler, phase, start_epoch, end_epoch
#   resolved.tsv        epoch, host, ip  (telemetry hosts, resolved on the box once a minute)
#   gws_pgrep.tsv       epoch, pid
#   nettop.txt          once-a-minute nettop snapshot
#
# REPORT EXIT CODES
#   0  both samplers saw their controls; gws_spawn_count=0; telemetry_hosts=0
#   1  FAIL: gws ran, or a telemetry host was contacted
#   2  CANNOT-RUN: a sampler did not see its control, or the gws log could not
#      be read (and nothing failed)
#
# Tool paths are overridable for tests (PATH shims cannot replace an absolute
# path): NETSAMP_SUDO, NETSAMP_LSOF, NETSAMP_NETTOP, NETSAMP_LOG, NETSAMP_PGREP,
# NETSAMP_NC, NETSAMP_CONTROL_HOLD, NETSAMP_DSCACHEUTIL, NETSAMP_COLIMA, NETSAMP_LIMACTL,
# NETSAMP_COLIMA_PROFILE, NETSAMP_CONTROL_HOST, NETSAMP_TELEMETRY_LIST.
#
# /bin/bash 3.2 and BSD userland on the box; GNU userland and mawk in CI.
# British English; " -- " not em dashes.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

SUDO="${NETSAMP_SUDO:-/usr/bin/sudo}"
LSOF="${NETSAMP_LSOF:-/usr/sbin/lsof}"
NETTOP="${NETSAMP_NETTOP:-/usr/bin/nettop}"
LOGBIN="${NETSAMP_LOG:-/usr/bin/log}"
PGREP="${NETSAMP_PGREP:-/usr/bin/pgrep}"
NC="${NETSAMP_NC:-/usr/bin/nc}"
DSCACHEUTIL="${NETSAMP_DSCACHEUTIL:-/usr/bin/dscacheutil}"
CONTROL_HOST="${NETSAMP_CONTROL_HOST:-example.com}"
TELEMETRY_LIST="${NETSAMP_TELEMETRY_LIST:-${SCRIPT_DIR}/box_walk_probes/telemetry_hosts.tsv}"

COLIMA="${NETSAMP_COLIMA:-}"
if [ -z "${COLIMA}" ]; then
    for c in /opt/homebrew/bin/colima /usr/local/bin/colima; do
        [ -x "$c" ] && { COLIMA="$c"; break; }
    done
fi
LIMACTL="${NETSAMP_LIMACTL:-}"
if [ -z "${LIMACTL}" ]; then
    for c in /opt/homebrew/bin/limactl /usr/local/bin/limactl; do
        [ -x "$c" ] && { LIMACTL="$c"; break; }
    done
fi

usage() {
    sed -n '4,6p' "${SELF}" | sed 's/^# \{0,1\}//'
    exit 2
}

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date +%s; }

status() { # sampler event detail
    printf '%s\t%s\t%s\t%s\t%s\n' "$(epoch)" "$(utc)" "$1" "$2" "${3:-}" >> "${OUT}/status.tsv"
}

# ---------------------------------------------------------------------------
# Classification. Outbound = the remote is NOT loopback, link-local, RFC1918,
# ULA (fc00::/7), CGNAT/tailnet (100.64/10) or unspecified. One awk function,
# used by both samplers, so the two cannot disagree about what "outbound" is.
# ---------------------------------------------------------------------------
AWK_CLASSIFY='
function is_local(a,   o2) {
    if (a ~ /^\[/) { a = substr(a, 2); sub(/\].*$/, "", a) }
    a = tolower(a)
    if (a ~ /^127\./ || a == "::1" || a ~ /^localhost/) return 1
    if (a ~ /^10\./ || a ~ /^192\.168\./ || a ~ /^169\.254\./) return 1
    if (a ~ /^172\./) { split(a, o, "."); o2 = o[2] + 0; if (o2 >= 16 && o2 <= 31) return 1 }
    if (a ~ /^100\./) { split(a, o, "."); o2 = o[2] + 0; if (o2 >= 64 && o2 <= 127) return 1 }
    if (a ~ /^f[cd][0-9a-f][0-9a-f]:/ || a ~ /^fe[89ab][0-9a-f]:/) return 1
    if (a ~ /^::ffff:/) { sub(/^::ffff:/, "", a); return is_local(a) }
    if (a == "0.0.0.0" || a == "::" || a == "*") return 1
    return 0
}
'

# ---------------------------------------------------------------------------
# HOST sampler
# ---------------------------------------------------------------------------
host_lsof() { # stdout: lsof -F rows; rc from lsof
    "${SUDO}" -n "${LSOF}" -nP +c0 -i -F pcLfPnT
}

# lsof -F: p<pid> c<cmd> L<login>, then per fd: f<fd> P<proto> n<name> TST=<state>
AWK_LSOF='
function flush(   name, remote, raddr, rport, i) {
    if (!have) return
    have = 0
    if (nm !~ /->/ || st == "LISTEN") return
    connected++
    i = index(nm, "->"); local_ = substr(nm, 1, i - 1); remote = substr(nm, i + 2)
    if (remote ~ /^\[/) { raddr = remote; sub(/\]:[0-9]*$/, "]", raddr); rport = remote; sub(/^.*\]:/, "", rport) }
    else { raddr = remote; sub(/:[^:]*$/, "", raddr); rport = remote; sub(/^.*:/, "", rport) }
    if (is_local(raddr)) return
    outbound++
    gsub(/\t/, " ", cmd)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", E, U, cmd, pid, user, pr, local_, raddr, rport, (st == "" ? "-" : st) >> OUTF
}
/^p/ { flush(); pid = substr($0, 2); cmd = ""; user = ""; next }
/^c/ { cmd = substr($0, 2); next }
/^L/ { user = substr($0, 2); next }
/^f/ { flush(); have = 1; pr = ""; nm = ""; st = ""; next }
/^P/ { pr = substr($0, 2); next }
/^n/ { nm = substr($0, 2); next }
/^TST=/ { st = substr($0, 5); next }
END { flush(); printf "%d\t%d\n", connected, outbound }
'

host_sample_once() {
    local e u raw rc counts err
    e="$(epoch)"; u="$(utc)"
    err="${OUT}/.host_lsof.err"
    raw="$(host_lsof 2>"${err}")"; rc=$?
    if [ -z "${raw}" ]; then
        # An empty read is "could not look", never "nothing connected": the
        # ssh session that started this sampler is itself a socket.
        printf '%s\t%s\tCANNOT-RUN\tlsof rc=%s, no rows: %s\n' "$e" "$u" "$rc" \
            "$(head -1 "${err}" | tr '\t' ' ')" >> "${OUT}/host_samples.tsv"
        return 1
    fi
    counts="$(printf '%s\n' "${raw}" | awk -v E="$e" -v U="$u" -v OUTF="${OUT}/host_outbound.tsv" \
        "${AWK_CLASSIFY}${AWK_LSOF}")"
    printf '%s\t%s\t%s\n' "$e" "$u" "${counts}" >> "${OUT}/host_samples.tsv"
    return 0
}

gws_pgrep_once() {
    local e out rc
    e="$(epoch)"
    out="$("${PGREP}" -x gws 2>&1)"; rc=$?
    case "$rc" in
        0) printf '%s\n' "${out}" | while read -r p; do printf '%s\t%s\n' "$e" "$p"; done >> "${OUT}/gws_pgrep.tsv" ;;
        1) : ;;  # pgrep: no match
        *) status host pgrep_error "rc=${rc}: $(printf '%s' "${out}" | head -1)" ;;
    esac
}

resolve_telemetry_once() {
    local e h ip
    e="$(epoch)"
    [ -r "${TELEMETRY_LIST}" ] || { status host telemetry_list_unreadable "${TELEMETRY_LIST}"; return 1; }
    awk -F'\t' '!/^#/ && NF >= 1 && $1 != "" { print $1 }' "${TELEMETRY_LIST}" | while read -r h; do
        "${DSCACHEUTIL}" -q host -a name "$h" 2>>"${OUT}/resolve.err" \
            | awk '/^ip_address:|^ipv6_address:/ { print $2 }' | while read -r ip; do
                printf '%s\t%s\t%s\n' "$e" "$h" "$ip"
            done
    done >> "${OUT}/resolved.tsv"
}

nettop_once() {
    {
        printf '=== %s\n' "$(utc)"
        "${NETTOP}" -P -L 1 -n -x 2>&1 || printf 'nettop rc=%s\n' "$?"
    } >> "${OUT}/nettop.txt"
}

host_loop() {
    local i=0
    status host loop_started "pid=$$ period=${PERIOD}"
    while [ ! -e "${OUT}/STOP" ]; do
        host_sample_once
        gws_pgrep_once
        i=$(( i + 1 ))
        sleep "${PERIOD}"
    done
    status host loop_stopped "samples=${i}"
}

# The once-a-minute work (nettop, resolving the telemetry list) runs in its
# own loop. Inline, a slow nettop or resolver stalled the socket sampler for
# several seconds, long enough to miss a held control connection.
minutely_loop() {
    local i=0
    status minutely loop_started "pid=$$"
    while [ ! -e "${OUT}/STOP" ]; do
        if [ $(( i % 60 )) -eq 0 ]; then
            resolve_telemetry_once
            nettop_once
        fi
        i=$(( i + 1 ))
        sleep 1
    done
    status minutely loop_stopped ""
}

# ---------------------------------------------------------------------------
# IN-VM sampler
# ---------------------------------------------------------------------------
detect_profile() { # echoes the colima profile, or nothing if no VM exists yet
    if [ -n "${NETSAMP_COLIMA_PROFILE:-}" ]; then
        printf '%s\n' "${NETSAMP_COLIMA_PROFILE}"; return 0
    fi
    [ -n "${COLIMA}" ] || { printf 'default\n'; return 0; }
    # install.sh runs `colima start` with NO --profile, so the product VM is
    # `default`. Prefer it; otherwise take the first listed profile.
    PATH="${COLIMA%/*}:${PATH}" "${COLIMA}" list 2>>"${OUT}/vm.err" \
        | awk 'NR > 1 && $1 != "" { p[++n] = $1 } END { for (i = 1; i <= n; i++) if (p[i] == "default") { print "default"; exit } if (n) print p[1] }'
}

vm_exec() { # profile, then a command; stdin passes through to the VM
    local prof="$1"; shift
    if [ -n "${COLIMA}" ]; then
        # colima shells out to limactl, so its directory must be on PATH.
        PATH="${COLIMA%/*}:${PATH}" "${COLIMA}" ssh -p "${prof}" -- "$@"
    elif [ -n "${LIMACTL}" ]; then
        local inst=colima
        [ "${prof}" = "default" ] || inst="colima-${prof}"
        LIMA_HOME="${HOME}/.colima/_lima" "${LIMACTL}" shell "${inst}" -- "$@"
    else
        echo "neither colima nor limactl found" >&2
        return 127
    fi
}

# Runs inside the VM via `sh -s`. Prints "#method <m>", the flow lines, then
# "#docker" and one "name ip ip..." line per container.
VM_SAMPLE_SNIPPET='
m=none
if command -v conntrack >/dev/null 2>&1 && ct="$(sudo -n conntrack -L 2>&1)"; then m=conntrack
elif ct="$(sudo -n cat /proc/net/nf_conntrack 2>&1)"; then m=nf_conntrack
elif ct="$(sudo -n ss -tnpH 2>&1)"; then m=ss
fi
echo "#method $m"
printf "%s\n" "$ct"
echo "#docker"
for id in $(sudo -n docker ps -q); do
    sudo -n docker inspect -f "{{.Name}}{{range .NetworkSettings.Networks}} {{.IPAddress}}{{end}}" "$id"
done
'

AWK_VM='
/^#method / { method = $2; next }
/^#docker/ { indocker = 1; next }
indocker { n = $1; sub(/^\//, "", n); for (i = 2; i <= NF; i++) if ($i != "") ctr[$i] = n; next }
{ lines[++L] = $0 }
END {
    for (k = 1; k <= L; k++) {
        line = lines[k]; src = ""; dst = ""; dport = ""; st = "-"; proto = "-"
        if (method == "ss") {
            nf = split(line, f, /[ \t]+/)
            # ss -tnpH columns: state, recv-q, send-q, local, peer, users
            if (nf < 5) continue
            st = f[1]; proto = "tcp"; src = f[4]; dst = f[5]
            dport = dst; sub(/^.*:/, "", dport); sub(/:[^:]*$/, "", dst); sub(/:[^:]*$/, "", src)
        } else {
            if (line !~ /src=/) continue
            nf = split(line, f, /[ \t]+/)
            for (i = 1; i <= nf; i++) {
                if (f[i] == "tcp" || f[i] == "udp" || f[i] == "icmp") { if (proto == "-") proto = f[i] }
                else if (f[i] ~ /^[A-Z_]+$/ && st == "-") st = f[i]
                else if (f[i] ~ /^src=/ && src == "") src = substr(f[i], 5)
                else if (f[i] ~ /^dst=/ && dst == "") dst = substr(f[i], 5)
                else if (f[i] ~ /^dport=/ && dport == "") dport = substr(f[i], 7)
            }
        }
        if (src == "" || dst == "") continue
        flows++
        if (is_local(dst)) continue
        outbound++
        c = (src in ctr) ? ctr[src] : "vm"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", E, U, method, proto, src, dst, (dport == "" ? "-" : dport), st, c >> OUTF
    }
    printf "%s\t%d\t%d\n", (method == "" ? "none" : method), flows, outbound
}
'

vm_sample_once() {
    local prof="$1" e u raw rc counts method
    e="$(epoch)"; u="$(utc)"
    raw="$(printf '%s' "${VM_SAMPLE_SNIPPET}" | vm_exec "${prof}" sh -s 2>>"${OUT}/vm.err")"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "${raw}" ]; then
        printf '%s\t%s\tCANNOT-RUN\tvm exec rc=%s, %s byte(s)\n' "$e" "$u" "$rc" "${#raw}" >> "${OUT}/vm_samples.tsv"
        return 1
    fi
    counts="$(printf '%s\n' "${raw}" | awk -v E="$e" -v U="$u" -v OUTF="${OUT}/vm_outbound.tsv" \
        "${AWK_CLASSIFY}${AWK_VM}")"
    method="${counts%%	*}"
    if [ "${method}" = "none" ]; then
        printf '%s\t%s\tCANNOT-RUN\tno method worked in the VM (conntrack, nf_conntrack, ss)\n' "$e" "$u" >> "${OUT}/vm_samples.tsv"
        return 1
    fi
    printf '%s\t%s\t%s\n' "$e" "$u" "${counts}" >> "${OUT}/vm_samples.tsv"
}

vm_loop() {
    local prof="" up=""
    status vm loop_started "pid=$$ period=${PERIOD}"
    while [ ! -e "${OUT}/STOP" ]; do
        if [ -z "${up}" ]; then
            prof="$(detect_profile)"
            if [ -n "${prof}" ] && vm_exec "${prof}" true </dev/null >/dev/null 2>>"${OUT}/vm.err"; then
                up=1
                status vm vm_up "profile=${prof}"
                printf '%s\n' "${prof}" > "${OUT}/vm_profile"
                fire_control vm start "${prof}"
            else
                [ -e "${OUT}/.vm_waiting" ] || { status vm waiting "VM not up yet (profile='${prof}')"; : > "${OUT}/.vm_waiting"; }
                sleep "${PERIOD}"
                continue
            fi
        fi
        vm_sample_once "${prof}"
        sleep "${PERIOD}"
    done
    status vm loop_stopped ""
}

control_hold() { # seconds a control connection is held: 2 x PERIOD unless overridden
    case "${NETSAMP_CONTROL_HOLD:-}" in
        ""|*[!0-9]*) echo $(( PERIOD * 2 )) ;;
        *) echo "${NETSAMP_CONTROL_HOLD}" ;;
    esac
}

# ---------------------------------------------------------------------------
# CONTROLS. A connection to CONTROL_HOST:80 held for HOLD = 2 x PERIOD, and
# re-opened if the far end closes it early, so at least one sample lands
# inside it.
# ---------------------------------------------------------------------------
fire_control() { # sampler phase [profile]
    local s="$1" ph="$2" prof="${3:-}" hold start
    hold="$(control_hold)"
    start="$(epoch)"
    printf '%s\t%s\t%s\t%s\n' "$s" "$ph" "$start" "$(( start + hold ))" >> "${OUT}/controls.tsv"
    if [ "$s" = host ]; then
        (
            end=$(( start + hold ))
            while [ "$(epoch)" -lt "$end" ]; do
                left=$(( end - $(epoch) )); [ "$left" -lt 1 ] && left=1
                sleep "$left" | "${NC}" "${CONTROL_HOST}" 80
                sleep 1
            done
        ) >> "${OUT}/control_host.log" 2>&1 &
    else
        printf '%s\n' "
end=\$(( \$(date +%s) + ${hold} ))
if command -v nc >/dev/null 2>&1; then t=nc
elif command -v curl >/dev/null 2>&1; then t=curl
elif command -v wget >/dev/null 2>&1; then t=wget
else echo '#tool none'; exit 3; fi
echo \"#tool \$t\"
while [ \$(date +%s) -lt \$end ]; do
    left=\$(( end - \$(date +%s) )); [ \$left -lt 1 ] && left=1
    case \$t in
        nc) sleep \$left | nc ${CONTROL_HOST} 80 ;;
        curl) curl -s -o /dev/null --max-time \$left http://${CONTROL_HOST}/ ;;
        wget) wget -q -O /dev/null -T \$left http://${CONTROL_HOST}/ ;;
    esac
    sleep 1
done
" | vm_exec "${prof}" sh -s >> "${OUT}/control_vm.log" 2>&1 &
    fi
}

# ---------------------------------------------------------------------------
# start / stop
# ---------------------------------------------------------------------------
cmd_start() {
    mkdir -p "${OUT}" || { echo "cannot create ${OUT}" >&2; exit 2; }
    if [ -e "${OUT}/host.pid" ] || [ -e "${OUT}/vm.pid" ]; then
        echo "walk_net_sampler: ${OUT} already holds a run (pid files present). Use a new --out." >&2
        exit 2
    fi
    rm -f "${OUT}/STOP"
    printf '%s\t%s\t%s\n' "$(epoch)" "$(utc)" "$(date '+%Y-%m-%d %H:%M:%S')" > "${OUT}/window_start"
    printf '%s\n' "${PERIOD}" > "${OUT}/period"
    status sampler start "out=${OUT} period=${PERIOD}"

    # Host preflight: one real read. Empty means sudo -n or lsof cannot run,
    # and that is recorded as CANNOT-RUN, never as an empty TSV.
    if host_sample_once; then
        nohup "${SELF}" _loop host --out "${OUT}" --period "${PERIOD}" \
            </dev/null >> "${OUT}/host_loop.log" 2>&1 &
        echo $! > "${OUT}/host.pid"
        nohup "${SELF}" _loop minutely --out "${OUT}" --period "${PERIOD}" \
            </dev/null >> "${OUT}/minutely_loop.log" 2>&1 &
        echo $! > "${OUT}/minutely.pid"
        fire_control host start
        echo "host sampler: started pid $(cat "${OUT}/host.pid")"
    else
        status host CANNOT-RUN "preflight: $(tail -1 "${OUT}/host_samples.tsv" | cut -f4)"
        echo "host sampler: CANNOT-RUN ($(tail -1 "${OUT}/host_samples.tsv" | cut -f4))"
    fi
    nohup "${SELF}" _loop vm --out "${OUT}" --period "${PERIOD}" \
        </dev/null >> "${OUT}/vm_loop.log" 2>&1 &
    echo $! > "${OUT}/vm.pid"
    echo "vm sampler: started pid $(cat "${OUT}/vm.pid") (waits for the colima VM if it is not up yet)"
}

cmd_stop() {
    [ -d "${OUT}" ] || { echo "no run at ${OUT}" >&2; exit 2; }
    PERIOD="$(cat "${OUT}/period" 2>/dev/null || echo "${PERIOD}")"
    # End-of-window controls: prove the samplers were still alive at the end.
    [ -e "${OUT}/host.pid" ] && fire_control host stop
    if [ -s "${OUT}/vm_profile" ]; then
        fire_control vm stop "$(cat "${OUT}/vm_profile")"
    else
        status vm never_up "the VM never came up during the window"
    fi
    sleep $(( $(control_hold) + PERIOD + 1 ))
    : > "${OUT}/STOP"
    printf '%s\t%s\t%s\n' "$(epoch)" "$(utc)" "$(date '+%Y-%m-%d %H:%M:%S')" > "${OUT}/window_stop"
    local f pid n
    for f in host.pid minutely.pid vm.pid; do
        [ -s "${OUT}/$f" ] || continue
        pid="$(cat "${OUT}/$f")"
        n=0
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt $(( PERIOD + 10 )) ]; do sleep 1; n=$(( n + 1 )); done
        # Only the pid this run recorded; never by pattern.
        kill -0 "$pid" 2>/dev/null && kill "$pid"
    done
    status sampler stop ""
    echo "stopped; run: ${SELF} report --out ${OUT}"
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
rdns() {
    local n
    n="$("${DSCACHEUTIL}" -q host -a ip_address "$1" 2>/dev/null | awk '/^name:/ { print $2; exit }')"
    printf '%s\n' "${n:--}"
}

control_seen() { # sampler -> prints "phase:seen" lines; rc 0 only if every phase was seen
    local s="$1" all=0 ph st en n
    [ -s "${OUT}/controls.tsv" ] || return 1
    while IFS="$(printf '\t')" read -r cs ph st en; do
        [ "$cs" = "$s" ] || continue
        en=$(( en + PERIOD * 2 ))
        if [ "$s" = host ]; then
            n="$(awk -F'\t' -v a="$st" -v b="$en" '$1 >= a && $1 <= b && $3 ~ /^nc/ && $9 == "80"' "${OUT}/host_outbound.tsv" 2>/dev/null | wc -l | tr -d ' ')"
        else
            n="$(awk -F'\t' -v a="$st" -v b="$en" '$1 >= a && $1 <= b && $7 == "80"' "${OUT}/vm_outbound.tsv" 2>/dev/null | wc -l | tr -d ' ')"
        fi
        echo "  ${s} control (${ph}): $([ "$n" -gt 0 ] && echo "SEEN in ${n} sample row(s)" || echo "NOT SEEN")"
        [ "$n" -gt 0 ] || all=1
        SEEN_ANY=1
    done < "${OUT}/controls.tsv"
    return $all
}

cmd_report() {
    [ -d "${OUT}" ] || { echo "no run at ${OUT}" >&2; exit 2; }
    PERIOD="$(cat "${OUT}/period" 2>/dev/null || echo "${PERIOD}")"
    local ws we host_v vm_v rc=0 fail=0 cr=0
    ws="$(cut -f2 "${OUT}/window_start" 2>/dev/null)"; we="$(cut -f2 "${OUT}/window_stop" 2>/dev/null)"
    echo "== walk_net_sampler report: ${ws:-?} .. ${we:-not stopped} (period ${PERIOD}s; samples, not connections)"

    # -- host
    local hs hok hcr
    hs="$(wc -l < "${OUT}/host_samples.tsv" 2>/dev/null | tr -d ' ')"; hs="${hs:-0}"
    hcr="$(grep -c '	CANNOT-RUN	' "${OUT}/host_samples.tsv" 2>/dev/null)"; hcr="${hcr:-0}"
    hok=$(( hs - hcr ))
    echo "host sampler: method=sudo-lsof samples=${hs} readable=${hok} cannot_run=${hcr}"
    SEEN_ANY=0
    if [ "$hok" -gt 0 ] && control_seen host && [ "$SEEN_ANY" -eq 1 ]; then
        host_v=PASS
    else
        host_v=CANNOT-RUN; cr=1
        [ "$hok" -gt 0 ] || echo "  reason: no readable host sample ($(grep -m1 'CANNOT-RUN' "${OUT}/host_samples.tsv" 2>/dev/null | cut -f4))"
        [ "$SEEN_ANY" -eq 1 ] || [ "$hok" -eq 0 ] || echo "  reason: no host control was fired"
    fi
    echo "host_sampler=${host_v}"

    # -- vm
    local vs vok vcr vm_method vm_up
    vs="$(wc -l < "${OUT}/vm_samples.tsv" 2>/dev/null | tr -d ' ')"; vs="${vs:-0}"
    vcr="$(grep -c '	CANNOT-RUN	' "${OUT}/vm_samples.tsv" 2>/dev/null)"; vcr="${vcr:-0}"
    vok=$(( vs - vcr ))
    vm_method="$(awk -F'\t' '$3 != "CANNOT-RUN" { print $3 }' "${OUT}/vm_samples.tsv" 2>/dev/null | sort | uniq -c | awk '{ printf "%s%s(%s)", s, $2, $1; s = "," }')"
    vm_up="$(awk -F'\t' '$4 == "vm_up" { print $2 " " $5; exit }' "${OUT}/status.tsv" 2>/dev/null)"
    echo "vm sampler: up_at=${vm_up:-never} method=${vm_method:-none} samples=${vs} readable=${vok} cannot_run=${vcr}"
    case "${vm_method}" in *ss\(*) echo "  limit: the ss method sees the VM network namespace only; container namespaces are not visible to it" ;; esac
    SEEN_ANY=0
    if [ "$vok" -gt 0 ] && control_seen vm && [ "$SEEN_ANY" -eq 1 ]; then
        vm_v=PASS
    else
        vm_v=CANNOT-RUN; cr=1
        [ "$vok" -gt 0 ] || echo "  reason: no readable VM sample"
    fi
    grep -m1 '^#tool' "${OUT}/control_vm.log" 2>/dev/null | sed 's/^#tool /  vm control tool: /'
    echo "vm_sampler=${vm_v}"

    # -- per-process / per-container remotes
    echo "-- host outbound by process (process, remote, rdns, sample rows)"
    if [ -s "${OUT}/host_outbound.tsv" ]; then
        awk -F'\t' '{ k = $3 "\t" $8 ":" $9; c[k]++ } END { for (k in c) print k "\t" c[k] }' "${OUT}/host_outbound.tsv" \
            | sort | while IFS="$(printf '\t')" read -r p r n; do
                printf '  %s\t%s\t%s\t%s\n' "$p" "$r" "$(rdns "${r%:*}")" "$n"
            done
    else
        echo "  (no outbound rows)"
    fi
    echo "-- vm outbound by container (container, remote, rdns, sample rows)"
    if [ -s "${OUT}/vm_outbound.tsv" ]; then
        awk -F'\t' '{ k = $9 "\t" $6 ":" $7; c[k]++ } END { for (k in c) print k "\t" c[k] }' "${OUT}/vm_outbound.tsv" \
            | sort | while IFS="$(printf '\t')" read -r p r n; do
                printf '  %s\t%s\t%s\t%s\n' "$p" "$r" "$(rdns "${r%:*}")" "$n"
            done
    else
        echo "  (no outbound rows)"
    fi

    # -- gws: unified log over the window, pgrep samples, and socket rows
    local logst logout lrc gws_log_pids gws_n
    logst="$(cut -f3 "${OUT}/window_start" 2>/dev/null)"
    logout="$("${LOGBIN}" show --start "${logst}" --predicate 'process == "gws"' --style compact 2>&1)"; lrc=$?
    {
        if [ "$lrc" -eq 0 ]; then printf '%s\n' "${logout}" | grep -o 'gws\[[0-9]*' | sed 's/^gws\[//'; fi
        cut -f2 "${OUT}/gws_pgrep.tsv" 2>/dev/null
        awk -F'\t' '$3 == "gws" { print $4 }' "${OUT}/host_outbound.tsv" 2>/dev/null
    } | grep -E '^[0-9]+$' | sort -u > "${OUT}/.gws_pids"
    gws_n="$(wc -l < "${OUT}/.gws_pids" | tr -d ' ')"
    gws_log_pids="$([ "$lrc" -eq 0 ] && printf '%s\n' "${logout}" | grep -o 'gws\[[0-9]*' | sort -u | wc -l | tr -d ' ')"
    echo "-- gws"
    if [ "$lrc" -ne 0 ]; then
        echo "  gws_log=CANNOT-RUN (log show rc=${lrc}: $(printf '%s' "${logout}" | head -1))"
        [ "$gws_n" -eq 0 ] && cr=1
    else
        echo "  gws_log=read (${gws_log_pids} distinct pid(s))"
    fi
    echo "  pgrep samples: $(cut -f2 "${OUT}/gws_pgrep.tsv" 2>/dev/null | sort -u | wc -l | tr -d ' ') distinct pid(s); socket rows: $(awk -F'\t' '$3 == "gws"' "${OUT}/host_outbound.tsv" 2>/dev/null | wc -l | tr -d ' ')"
    echo "gws_spawn_count=${gws_n}"
    [ "$gws_n" -gt 0 ] && fail=1

    # -- telemetry: outbound remotes that resolved, on the box, to a listed host
    local tel_n
    echo "-- telemetry (list: ${TELEMETRY_LIST##*/}; a match on a shared CDN address is 'consistent with', not proof)"
    if [ ! -s "${OUT}/resolved.tsv" ]; then
        echo "  telemetry resolution: CANNOT-RUN (no telemetry host resolved on the box)"
        cr=1
    fi
    {
        [ -s "${OUT}/host_outbound.tsv" ] && awk -F'\t' '{ print "host\t" $3 "\t" $8 }' "${OUT}/host_outbound.tsv"
        [ -s "${OUT}/vm_outbound.tsv" ] && awk -F'\t' '{ print "vm\t" $9 "\t" $6 }' "${OUT}/vm_outbound.tsv"
    } | awk -F'\t' -v R="${OUT}/resolved.tsv" '
        BEGIN { while ((getline l < R) > 0) { split(l, f, "\t"); a = f[3]; h[a] = f[2]; b = "[" a "]"; h[b] = f[2] } }
        ($3 in h) { k = h[$3] "\t" $1 ":" $2 "\t" $3; c[k]++ }
        END { for (k in c) print k "\t" c[k] }' | sort > "${OUT}/.telemetry_hits"
    if [ -s "${OUT}/.telemetry_hits" ]; then
        sed 's/^/  /' "${OUT}/.telemetry_hits"
    fi
    tel_n="$(cut -f1 "${OUT}/.telemetry_hits" | sort -u | grep -c . )"
    echo "telemetry_hosts=${tel_n}"
    [ "$tel_n" -gt 0 ] && fail=1

    if [ "$fail" -eq 1 ]; then rc=1; echo "verdict=FAIL"
    elif [ "$cr" -eq 1 ]; then rc=2; echo "verdict=CANNOT-RUN"
    else rc=0; echo "verdict=PASS"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
SUB="${1:-}"; [ -n "${SUB}" ] && shift
LOOP_KIND=""
if [ "${SUB}" = "_loop" ]; then LOOP_KIND="${1:-}"; shift; fi
OUT=""; PERIOD="${NETSAMP_PERIOD:-5}"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        --period) PERIOD="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "${OUT}" ] || usage
case "${PERIOD}" in ''|*[!0-9]*|0) echo "--period must be a positive integer" >&2; exit 2 ;; esac

case "${SUB}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    report) cmd_report; exit $? ;;
    _loop)
        case "${LOOP_KIND}" in
            host) host_loop ;;
            minutely) minutely_loop ;;
            vm) vm_loop ;;
            *) exit 2 ;;
        esac ;;
    *) usage ;;
esac
