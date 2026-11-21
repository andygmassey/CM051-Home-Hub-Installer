#!/bin/bash
# tests/test_walk_net_sampler.sh -- scripts/walk_net_sampler.sh, end to end
#
# Drives start -> stop -> report through PATH-style shims for every box tool
# (sudo, lsof, nettop, log, pgrep, nc, dscacheutil, colima, and inside the
# "VM": sudo, conntrack, docker, nc). Nothing here touches a real box, a real
# VM, a real keychain or the network.
#
# Cases (each a fixture mutant of the baseline):
#   A  baseline: both controls seen            -> PASS lines, rc 0
#   B  host control never held                 -> host_sampler=CANNOT-RUN, rc 2
#   C  VM control never held                   -> vm_sampler=CANNOT-RUN, rc 2
#   D  sudo -n refused                         -> CANNOT-RUN row, never an empty read, rc 2
#   E  a gws socket row                        -> gws_spawn_count>0, rc 1
#   F  gws only in the unified log             -> gws_spawn_count>0, rc 1
#   G  host row to a telemetry address         -> telemetry_hosts>0, rc 1
#   H  VM container flow to a telemetry address -> telemetry_hosts>0, rc 1
#   I  VM has socat and curl, no nc            -> socat chosen, VM control seen, rc 0
#      (the colima VM as measured 2026-11-05: curl-first left it unseen)
#   J  hold set on start only                  -> stop's controls hold as long
#      as start's (the hold is persisted in the run dir, not re-read from env)
#   K  VM DNS resolves only on the 3rd lookup  -> the start control waits for
#      it, fires after, is seen; vm_sampler=PASS (v1.0.125 walk race)
#   L  VM DNS never resolves                   -> no VM control fired, the waited
#      time is named, vm_sampler=CANNOT-RUN, rc 2 (never PASS)
#   M  a bare copy with no host list           -> start refuses, rc 2, nothing runs
# Then code mutants of the sampler itself; each must turn its case red.
#
# Debug knobs (never set in CI): ONLY_CASES="A C" runs those cases and skips
# the mutants; KEEP_T=1 keeps the temp tree and prints its path.
#
# Addresses are documentation ranges (RFC 5737), hosts are example.* or the
# listed telemetry names. British English; " -- " not em dashes.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLER="${REPO_ROOT}/scripts/walk_net_sampler.sh"
TELEMETRY="${REPO_ROOT}/scripts/box_walk_probes/telemetry_hosts.tsv"
[ -x "${SAMPLER}" ] || { echo "CANNOT-RUN: ${SAMPLER} missing or not executable"; exit 2; }
[ -r "${TELEMETRY}" ] || { echo "CANNOT-RUN: ${TELEMETRY} missing"; exit 2; }

T="$(mktemp -d)"
OUTS=""
cleanup() {
    local o p
    for o in ${OUTS}; do
        : > "$o/STOP" 2>/dev/null
        for p in "$o/host.pid" "$o/minutely.pid" "$o/vm.pid"; do
            [ -s "$p" ] && kill "$(cat "$p")" 2>/dev/null
        done
    done
    rm -rf "${T}"
}
trap cleanup EXIT; [ -n "${KEEP_T:-}" ] && { trap - EXIT; echo "T=${T}"; }

H="${T}/hostshim"; V="${T}/vmshim"; FIX="${T}/fix"
mkdir -p "$H" "$V" "$FIX"

# ---------------------------------------------------------------- host shims
cat > "$H/sudo" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && shift
if [ -n "${SHIM_SUDO_DENY:-}" ]; then echo "sudo: a password is required" >&2; exit 1; fi
exec "$@"
EOF
cat > "$H/lsof" <<'EOF'
#!/bin/sh
cat "$SHIM_FIX/lsof_base"
[ -r "$SHIM_STATE/lsof_extra" ] && cat "$SHIM_STATE/lsof_extra"
if [ -e "$SHIM_STATE/host_nc_held" ]; then
    printf 'p4242\ncnc\nLwalker\nf3\nPTCP\nn192.168.1.20:50000->198.51.100.80:80\nTST=ESTABLISHED\n'
fi
exit 0
EOF
cat > "$H/nc" <<'EOF'
#!/bin/sh
if [ -n "${SHIM_NC_BROKEN_HOST:-}" ]; then echo "nc: connection refused" >&2; exit 1; fi
echo "$(date +%s) host nc open" >> "$SHIM_STATE/nc.log"
: > "$SHIM_STATE/host_nc_held"; cat >/dev/null; rm -f "$SHIM_STATE/host_nc_held"
echo "$(date +%s) host nc closed" >> "$SHIM_STATE/nc.log"
EOF
cat > "$H/nettop" <<'EOF'
#!/bin/sh
echo "time,,interface,state,bytes_in,bytes_out"
EOF
cat > "$H/pgrep" <<'EOF'
#!/bin/sh
[ -s "$SHIM_STATE/pgrep" ] && { cat "$SHIM_STATE/pgrep"; exit 0; }
exit 1
EOF
cat > "$H/log" <<'EOF'
#!/bin/sh
echo "timestamp               ty process[pid:tid]"
[ -r "$SHIM_STATE/log" ] && cat "$SHIM_STATE/log"
exit 0
EOF
cat > "$H/dscacheutil" <<'EOF'
#!/bin/sh
# -q host -a name <h>   |   -q host -a ip_address <ip>
case "$4" in
    name) awk -v h="$5" '$1 == h { print "name: " $1; print "ip_address: " $2 }' "$SHIM_FIX/dns" ;;
    ip_address) awk -v a="$5" '$2 == a { print "name: " $1; exit }' "$SHIM_FIX/dns" ;;
esac
exit 0
EOF
cat > "$H/colima" <<'EOF'
#!/bin/sh
case "$1" in
    list)
        echo "PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK     RUNTIME    ADDRESS"
        [ -e "$SHIM_STATE/vm_up" ] && echo "default    Running    aarch64    2       4GiB      30GiB    docker"
        exit 0 ;;
    ssh)
        [ -e "$SHIM_STATE/vm_up" ] || { echo "colima is not running" >&2; exit 1; }
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift
        PATH="$SHIM_VM:$SHIM_VMBASE" exec "$@" ;;
esac
exit 1
EOF

# ------------------------------------------------------------------ VM shims
cat > "$V/sudo" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
EOF
cat > "$V/conntrack" <<'EOF'
#!/bin/sh
cat "$SHIM_FIX/conntrack_base"
[ -r "$SHIM_STATE/conntrack_extra" ] && cat "$SHIM_STATE/conntrack_extra"
if [ -e "$SHIM_STATE/vm_nc_held" ]; then
    echo "tcp      6 431999 ESTABLISHED src=192.168.5.15 dst=198.51.100.80 sport=40000 dport=80 src=198.51.100.80 dst=192.168.5.15 sport=80 dport=40000 [ASSURED] mark=0 use=1"
fi
echo "conntrack v1.4.6 (conntrack-tools): 3 flow entries have been shown." >&2
EOF
cat > "$V/docker" <<'EOF'
#!/bin/sh
case "$1" in
    ps) echo "c0ffee01" ;;
    inspect) echo "/ostler-qdrant 172.17.0.2" ;;
esac
EOF
cat > "$V/nc" <<'EOF'
#!/bin/sh
if [ -n "${SHIM_NC_BROKEN_VM:-}" ]; then echo "nc: connection refused" >&2; exit 1; fi
echo "$(date +%s) vm nc open" >> "$SHIM_STATE/nc.log"
: > "$SHIM_STATE/vm_nc_held"; cat >/dev/null; rm -f "$SHIM_STATE/vm_nc_held"
echo "$(date +%s) vm nc closed" >> "$SHIM_STATE/nc.log"
EOF
cat > "$V/getent" <<'EOF'
#!/bin/sh
# The VM resolver. SHIM_DNS_NEVER: never resolves. SHIM_DNS_FAIL_FIRST=N: the
# first N lookups fail (the resolver is still coming up), then it resolves.
n=$(( $(cat "$SHIM_STATE/dns_calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SHIM_STATE/dns_calls"
echo "$(date +%s) vm dns lookup $n" >> "$SHIM_STATE/nc.log"
[ -n "${SHIM_DNS_NEVER:-}" ] && exit 2
[ "$n" -le "${SHIM_DNS_FAIL_FIRST:-0}" ] && exit 2
echo "198.51.100.80   $3"
EOF
V2="${T}/vmshim_socat"; mkdir -p "$V2"   # second VM shape: socat and curl, no nc
cat > "$V2/socat" <<'EOF'
#!/bin/sh
# socat - TCP:host:port -- holds the connection until stdin closes.
echo "$(date +%s) vm socat open $2" >> "$SHIM_STATE/nc.log"
: > "$SHIM_STATE/vm_nc_held"; cat >/dev/null; rm -f "$SHIM_STATE/vm_nc_held"
echo "$(date +%s) vm socat closed" >> "$SHIM_STATE/nc.log"
EOF
cat > "$V2/curl" <<'EOF'
#!/bin/sh
# A GET that completes at once: the socket never outlives a sample interval.
echo "$(date +%s) vm curl GET done" >> "$SHIM_STATE/nc.log"
exit 0
EOF
chmod +x "$H"/* "$V"/* "$V2"/*

# The "VM" userland: the runner's own tools, minus every network client, so
# which control tool the sampler picks is decided by the shims alone (a real
# nc, socat or curl on the runner would otherwise be chosen and dial out).
VB="${T}/vmbase"; mkdir -p "$VB"
for d in /usr/bin /bin; do
    for f in "$d"/*; do
        b="${f##*/}"
        case "$b" in nc|ncat|netcat|nc.*|socat|curl|wget|busybox|getent|nslookup|host|dig) continue ;; esac
        [ -e "$VB/$b" ] || ln -s "$f" "$VB/$b"
    done
done
# The second VM shape, as measured on the colima VM 2026-11-05.
cp "$V/sudo" "$V/conntrack" "$V/docker" "$V/getent" "$V2/"

# ------------------------------------------------------------------ fixtures
# lsof -F: an ssh session (LAN, not outbound), a listener, and one declared
# outbound fetch to a documentation address.
printf 'p100\ncsshd-session\nLwalker\nf4\nPTCP\nn192.168.1.20:22->192.168.1.5:51000\nTST=ESTABLISHED\n' > "$FIX/lsof_base"
printf 'p200\ncollama\nLwalker\nf5\nPTCP\nn127.0.0.1:11434\nTST=LISTEN\nf6\nPTCP\nn192.168.1.20:51111->203.0.113.10:443\nTST=ESTABLISHED\n' >> "$FIX/lsof_base"
cat > "$FIX/conntrack_base" <<'EOF'
tcp      6 431999 ESTABLISHED src=172.17.0.2 dst=203.0.113.20 sport=41000 dport=443 src=203.0.113.20 dst=192.168.5.15 sport=443 dport=41000 [ASSURED] mark=0 use=1
udp      17 20 src=172.17.0.2 dst=192.168.5.3 sport=53000 dport=53 src=192.168.5.3 dst=172.17.0.2 sport=53 dport=53000 mark=0 use=1
EOF
cat > "$FIX/dns" <<'EOF'
example.com 198.51.100.80
telemetry.qdrant.io 198.51.100.7
fonts.gstatic.com 198.51.100.8
registry.example.net 203.0.113.10
EOF

PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES + 1)); echo "  ok    $*"; }
bad() { FAILS=$((FAILS + 1));  echo "  FAIL  $*"; }

wait_for() { # file min_lines: up to 90 s
    local i=0
    while [ "$i" -lt 90 ]; do
        [ "$(wc -l 2>/dev/null < "$1" | tr -d ' ')" -ge "$2" ] 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    echo "    wait_for: $1 never reached $2 line(s)"
    return 1
}

# run_case <sampler> <name> [VAR=value ...] ; sets RC and REPORT, OUTD
run_case() {
    local sampler="$1" name="$2"; shift 2
    local st="${T}/state.${name}.$$.${RANDOM}"
    OUTD="${T}/out.${name}.${RANDOM}"
    OUTS="${OUTS} ${OUTD}"
    mkdir -p "$st"
    ST="$st"
    case "$name" in
        E) printf 'p777\ncgws\nLwalker\nf7\nPTCP\nn192.168.1.20:52000->198.51.100.50:443\nTST=ESTABLISHED\n' > "$st/lsof_extra" ;;
        F) echo "2026-11-04 16:23:55.867 Df gws[34547:1a2b3] [com.example:net] starting" > "$st/log" ;;
        G) printf 'p888\ncostler-web\nLwalker\nf8\nPTCP\nn192.168.1.20:53000->198.51.100.7:443\nTST=ESTABLISHED\n' > "$st/lsof_extra" ;;
        H) echo "tcp      6 100 ESTABLISHED src=172.17.0.2 dst=198.51.100.8 sport=42000 dport=443 src=198.51.100.8 dst=192.168.5.15 sport=443 dport=42000 [ASSURED] mark=0 use=1" > "$st/conntrack_extra" ;;
    esac
    local env_common
    env_common="SHIM_FIX=${FIX} SHIM_STATE=${st} SHIM_VM=${V} SHIM_VMBASE=${VB} NETSAMP_SUDO=${H}/sudo NETSAMP_LSOF=${H}/lsof NETSAMP_NETTOP=${H}/nettop NETSAMP_LOG=${H}/log NETSAMP_PGREP=${H}/pgrep NETSAMP_NC=${H}/nc NETSAMP_DSCACHEUTIL=${H}/dscacheutil NETSAMP_COLIMA=${H}/colima NETSAMP_TELEMETRY_LIST=${TELEMETRY} NETSAMP_CONTROL_HOLD=8"
    # The VM comes up AFTER the sampler starts: the sampler must wait for it.
    env ${env_common} ${1+"$@"} ${START_ENV:-} "${sampler}" start --out "${OUTD}" --period 1 > "${OUTD}.start.log" 2>&1
    # Wait on conditions, not on the clock: a loaded CI runner can stall a
    # 1 s loop for several seconds.
    wait_for "${OUTD}/host_samples.tsv" 1
    sleep 1
    : > "$st/vm_up"
    wait_for "${OUTD}/vm_samples.tsv" 3
    env ${env_common} ${1+"$@"} "${sampler}" stop --out "${OUTD}" > "${OUTD}.stop.log" 2>&1
    REPORT="$(env ${env_common} ${1+"$@"} "${sampler}" report --out "${OUTD}" 2>&1)"; RC=$?
}

has() { printf '%s\n' "${REPORT}" | grep -qF -- "$1"; }
num() { printf '%s\n' "${REPORT}" | sed -n "s/^$1=\\([0-9][0-9]*\\)\$/\\1/p" | head -1; }

# expect_case <sampler> <name> ; echoes nothing, returns 0 if the case's
# expectations held, 1 otherwise (printing which)
expect_case() {
    local s="$1" n="$2" e=0
    case "$n" in
        A) run_case "$s" A
           has "host_sampler=PASS" || { echo "    A: no host_sampler=PASS"; e=1; }
           has "vm_sampler=PASS" || { echo "    A: no vm_sampler=PASS"; e=1; }
           has "gws_spawn_count=0" || { echo "    A: gws_spawn_count is not 0"; e=1; }
           has "telemetry_hosts=0" || { echo "    A: telemetry_hosts is not 0"; e=1; }
           has "method=conntrack(" || { echo "    A: VM method not recorded as conntrack"; e=1; }
           printf '%s\n' "${REPORT}" | grep -q 'up_at=20' || { echo "    A: VM up time not recorded"; e=1; }
           has "ostler-qdrant	203.0.113.20:443" || { echo "    A: container flow not attributed to its container"; e=1; }
           [ "$RC" -eq 0 ] || { echo "    A: rc=$RC, want 0"; e=1; } ;;
        B) run_case "$s" B SHIM_NC_BROKEN_HOST=1
           has "host_sampler=CANNOT-RUN" || { echo "    B: host sampler not CANNOT-RUN without its control"; e=1; }
           has "host control (start): NOT SEEN" || { echo "    B: missing control not named"; e=1; }
           [ "$RC" -eq 2 ] || { echo "    B: rc=$RC, want 2"; e=1; } ;;
        C) run_case "$s" C SHIM_NC_BROKEN_VM=1
           has "vm_sampler=CANNOT-RUN" || { echo "    C: VM sampler not CANNOT-RUN without its control"; e=1; }
           has "host_sampler=PASS" || { echo "    C: host sampler should still PASS"; e=1; }
           [ "$RC" -eq 2 ] || { echo "    C: rc=$RC, want 2"; e=1; } ;;
        D) run_case "$s" D SHIM_SUDO_DENY=1
           has "host_sampler=CANNOT-RUN" || { echo "    D: host sampler not CANNOT-RUN when sudo -n is refused"; e=1; }
           grep -q 'CANNOT-RUN	lsof rc=1, no rows: sudo: a password is required' "${OUTD}/host_samples.tsv" 2>/dev/null \
               || { echo "    D: no explicit CANNOT-RUN row naming the sudo refusal"; e=1; }
           [ "$RC" -eq 2 ] || { echo "    D: rc=$RC, want 2"; e=1; } ;;
        E) run_case "$s" E
           [ "$(num gws_spawn_count)" -gt 0 ] 2>/dev/null || { echo "    E: gws socket row not counted"; e=1; }
           [ "$RC" -eq 1 ] || { echo "    E: rc=$RC, want 1"; e=1; } ;;
        F) run_case "$s" F
           [ "$(num gws_spawn_count)" -gt 0 ] 2>/dev/null || { echo "    F: gws in the unified log not counted"; e=1; }
           [ "$RC" -eq 1 ] || { echo "    F: rc=$RC, want 1"; e=1; } ;;
        G) run_case "$s" G
           [ "$(num telemetry_hosts)" -gt 0 ] 2>/dev/null || { echo "    G: host telemetry row not counted"; e=1; }
           has "telemetry.qdrant.io	host:ostler-web" || { echo "    G: telemetry hit not attributed"; e=1; }
           [ "$RC" -eq 1 ] || { echo "    G: rc=$RC, want 1"; e=1; } ;;
        H) run_case "$s" H
           [ "$(num telemetry_hosts)" -gt 0 ] 2>/dev/null || { echo "    H: VM telemetry flow not counted"; e=1; }
           has "fonts.gstatic.com	vm:ostler-qdrant" || { echo "    H: VM telemetry hit not attributed to its container"; e=1; }
           [ "$RC" -eq 1 ] || { echo "    H: rc=$RC, want 1"; e=1; } ;;
        I) run_case "$s" I SHIM_VM="${V2}"
           has "vm control tool: socat" || { echo "    I: socat not chosen when the VM has socat and no nc"; e=1; }
           has "vm control (start): SEEN" || { echo "    I: VM start control not seen"; e=1; }
           has "vm control (stop): SEEN" || { echo "    I: VM stop control not seen"; e=1; }
           has "vm_sampler=PASS" || { echo "    I: no vm_sampler=PASS"; e=1; }
           [ "$RC" -eq 0 ] || { echo "    I: rc=$RC, want 0"; e=1; } ;;
        J) START_ENV="NETSAMP_CONTROL_HOLD=8" run_case "$s" J NETSAMP_CONTROL_HOLD=
           # Without the persisted hold, stop falls back to 2 x period = 2.
           local rows
           rows="$(awk -F'\t' '{ print $1 ":" $2 ":" ($4 - $3) }' "${OUTD}/controls.tsv" 2>/dev/null | sort | tr '\n' ' ')"
           [ "${rows}" = "host:start:8 host:stop:8 vm:start:8 vm:stop:8 " ] \
               || { echo "    J: control holds are '${rows}', want all four at 8"; e=1; }
           [ "$(cat "${OUTD}/control_hold" 2>/dev/null)" = "8" ] || { echo "    J: start's hold not persisted"; e=1; } ;;
        K) run_case "$s" K SHIM_DNS_FAIL_FIRST=2 NETSAMP_VM_DNS_POLL_S=1
           has "vm control dns ready after 2s" || { echo "    K: the DNS wait was not logged as ready after 2s"; e=1; }
           has "vm control (start): SEEN" || { echo "    K: VM start control not seen after the DNS wait"; e=1; }
           has "vm_sampler=PASS" || { echo "    K: no vm_sampler=PASS"; e=1; }
           [ "$RC" -eq 0 ] || { echo "    K: rc=$RC, want 0"; e=1; } ;;
        L) run_case "$s" L SHIM_DNS_NEVER=1 NETSAMP_VM_DNS_WAIT_S=3 NETSAMP_VM_DNS_POLL_S=1
           has "reason: no VM control fired: dns never resolved example.com inside the VM after 3s" \
               || { echo "    L: the never-resolved reason with its waited time is missing"; e=1; }
           has "vm_sampler=CANNOT-RUN" || { echo "    L: vm_sampler is not CANNOT-RUN"; e=1; }
           awk -F'\t' '$1 == "vm"' "${OUTD}/controls.tsv" 2>/dev/null | grep -q . \
               && { echo "    L: a VM control window was stamped though no control could fire"; e=1; }
           [ "$RC" -eq 2 ] || { echo "    L: rc=$RC, want 2"; e=1; } ;;
    esac
    if [ "$e" -ne 0 ]; then
        printf '%s\n' "${REPORT}" | sed 's/^/      | /'
        echo "      controls fired (sampler phase start end):"
        sed 's/^/      | /' "${OUTD}/controls.tsv" 2>/dev/null
        echo "      shim nc log:"
        sed 's/^/      | /' "${ST}/nc.log" 2>/dev/null
    fi
    return $e
}

echo "== cases against scripts/walk_net_sampler.sh"
for c in ${ONLY_CASES:-A B C D E F G H I J K L}; do
    if expect_case "${SAMPLER}" "$c"; then ok "case $c"; else bad "case $c"; fi
done

# --------------------------------------------------------------- code mutants
# Each mutant breaks one check in a copy of the sampler; the case that guards
# it must go red. A mutant whose sed did not change the file is itself a FAIL
# (a mutant that did not apply looks exactly like one that was not caught).
# Case M (v1.0.125: the sampler ran from a bare copy without its host list).
# A start with no readable list must refuse, rc 2, start nothing, and say why.
expect_m() { # sampler ; returns 0 when the refusal held
    local s="$1" o="${T}/out.M.${RANDOM}" bare="${T}/bare.${RANDOM}" e=0 out rc
    mkdir -p "$bare"; cp "$s" "$bare/walk_net_sampler.sh"; chmod +x "$bare/walk_net_sampler.sh"
    OUTS="${OUTS} ${o}"
    out="$(env NETSAMP_SUDO="${H}/sudo" NETSAMP_LSOF="${H}/lsof" NETSAMP_COLIMA="${H}/colima" \
        "$bare/walk_net_sampler.sh" start --out "$o" --period 1 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] || { echo "    M: rc=$rc, want 2"; e=1; }
    printf '%s' "$out" | grep -q 'telemetry host list is unreadable or empty' || { echo "    M: refusal not named: $out"; e=1; }
    [ -e "$o/host.pid" ] || [ -e "$o/vm.pid" ] && { echo "    M: a sampler started without its host list"; e=1; }
    return $e
}
if [ -z "${ONLY_CASES:-}" ] || case " ${ONLY_CASES} " in *" M "*) true ;; *) false ;; esac; then
    if expect_m "${SAMPLER}"; then ok "case M"; else bad "case M"; fi
fi

echo "== code mutants (each must turn its case red)"
mutant() { # label case old new
    local label="$1" c="$2" old="$3" new="$4" m="${T}/mut.$1"
    mkdir -p "$m/box_walk_probes"
    cp "${SAMPLER}" "$m/walk_net_sampler.sh"
    OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$m/walk_net_sampler.sh"
    if cmp -s "${SAMPLER}" "$m/walk_net_sampler.sh"; then
        bad "mutant ${label}: did not apply"
        return
    fi
    chmod +x "$m/walk_net_sampler.sh"
    if expect_case "$m/walk_net_sampler.sh" "$c" > "${T}/mut.${label}.log" 2>&1; then
        bad "mutant ${label}: case ${c} stayed green (not caught)"
    else
        ok "mutant ${label}: case ${c} went red ($(grep -m1 "^    ${c}:" "${T}/mut.${label}.log" | sed 's/^ *//'))"
    fi
}
[ -n "${ONLY_CASES:-}" ] || mutant control_always_seen B '[ "$n" -gt 0 ] || all=1' 'all=0'
[ -n "${ONLY_CASES:-}" ] || mutant empty_read_accepted D 'if [ -z "${raw}" ]; then' 'if false; then'
[ -n "${ONLY_CASES:-}" ] || mutant gws_socket_rows_dropped E '$3 == "gws" { print $4 }' '$3 == "nothing" { print $4 }'
[ -n "${ONLY_CASES:-}" ] || mutant gws_log_ignored F 'if [ "$lrc" -eq 0 ]; then printf' 'if false; then printf'
[ -n "${ONLY_CASES:-}" ] || mutant telemetry_match_off G '($3 in h) {' '(0) {'
[ -n "${ONLY_CASES:-}" ] || mutant vm_control_curl_first I 'if command -v socat >/dev/null 2>&1; then t=socat' 'if command -v curl >/dev/null 2>&1; then t=curl
elif command -v socat >/dev/null 2>&1; then t=socat'
[ -n "${ONLY_CASES:-}" ] || mutant stop_rereads_hold_from_env J 'case "${saved}" in ""|*[!0-9]*) ;; *) echo "${saved}"; return 0 ;; esac' ':'
[ -n "${ONLY_CASES:-}" ] || mutant dns_wait_skipped L 'if \$r >/dev/null 2>&1; then' 'if true; then'
[ -n "${ONLY_CASES:-}" ] || mutant dns_failure_still_fires L '                exit 0
            fi
            status vm control_dns' '            fi
            status vm control_dns'
if [ -z "${ONLY_CASES:-}" ]; then
    mm="${T}/mut.no_host_list_refusal"; mkdir -p "$mm"; cp "${SAMPLER}" "$mm/walk_net_sampler.sh"
    OLD='if [ ! -r "${TELEMETRY_LIST}" ] ||' NEW='if false &&' perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$mm/walk_net_sampler.sh"
    if cmp -s "${SAMPLER}" "$mm/walk_net_sampler.sh"; then bad "mutant no_host_list_refusal: did not apply"
    elif expect_m "$mm/walk_net_sampler.sh" > "${T}/mut.M.log" 2>&1; then bad "mutant no_host_list_refusal: case M stayed green"
    else ok "mutant no_host_list_refusal: case M went red ($(grep -m1 '^    M:' "${T}/mut.M.log" | sed 's/^ *//'))"; fi
fi
[ -n "${ONLY_CASES:-}" ] || mutant vm_rows_not_in_telemetry H 'awk -F'"'"'\t'"'"' '"'"'{ print "vm\t" $9 "\t" $6 }'"'"'' 'true'

echo
echo "test_walk_net_sampler: ${PASSES} ok, ${FAILS} failed (of $((PASSES + FAILS)))"
[ "${FAILS}" -eq 0 ] || exit 1
# The denominator: 13 cases + 11 mutants. Fewer means something did not run.
[ -n "${ONLY_CASES:-}" ] || [ "${PASSES}" -eq 24 ] || { echo "denominator: ${PASSES} of 24 ran"; exit 1; }
exit 0
