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
: > "$SHIM_STATE/host_nc_held"; cat >/dev/null; rm -f "$SHIM_STATE/host_nc_held"
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
        PATH="$SHIM_VM:/usr/bin:/bin" exec "$@" ;;
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
: > "$SHIM_STATE/vm_nc_held"; cat >/dev/null; rm -f "$SHIM_STATE/vm_nc_held"
EOF
chmod +x "$H"/* "$V"/*

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
        [ "$(wc -l < "$1" 2>/dev/null | tr -d ' ')" -ge "$2" ] 2>/dev/null && return 0
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
    case "$name" in
        E) printf 'p777\ncgws\nLwalker\nf7\nPTCP\nn192.168.1.20:52000->198.51.100.50:443\nTST=ESTABLISHED\n' > "$st/lsof_extra" ;;
        F) echo "2026-11-04 16:23:55.867 Df gws[34547:1a2b3] [com.example:net] starting" > "$st/log" ;;
        G) printf 'p888\ncostler-web\nLwalker\nf8\nPTCP\nn192.168.1.20:53000->198.51.100.7:443\nTST=ESTABLISHED\n' > "$st/lsof_extra" ;;
        H) echo "tcp      6 100 ESTABLISHED src=172.17.0.2 dst=198.51.100.8 sport=42000 dport=443 src=198.51.100.8 dst=192.168.5.15 sport=443 dport=42000 [ASSURED] mark=0 use=1" > "$st/conntrack_extra" ;;
    esac
    local env_common
    env_common="SHIM_FIX=${FIX} SHIM_STATE=${st} SHIM_VM=${V} NETSAMP_SUDO=${H}/sudo NETSAMP_LSOF=${H}/lsof NETSAMP_NETTOP=${H}/nettop NETSAMP_LOG=${H}/log NETSAMP_PGREP=${H}/pgrep NETSAMP_NC=${H}/nc NETSAMP_DSCACHEUTIL=${H}/dscacheutil NETSAMP_COLIMA=${H}/colima NETSAMP_TELEMETRY_LIST=${TELEMETRY} NETSAMP_CONTROL_HOLD=4"
    # The VM comes up AFTER the sampler starts: the sampler must wait for it.
    env ${env_common} ${1+"$@"} "${sampler}" start --out "${OUTD}" --period 1 > "${OUTD}.start.log" 2>&1
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
    esac
    if [ "$e" -ne 0 ]; then
        printf '%s\n' "${REPORT}" | sed 's/^/      | /'
    fi
    return $e
}

echo "== cases against scripts/walk_net_sampler.sh"
for c in ${ONLY_CASES:-A B C D E F G H}; do
    if expect_case "${SAMPLER}" "$c"; then ok "case $c"; else bad "case $c"; fi
done

# --------------------------------------------------------------- code mutants
# Each mutant breaks one check in a copy of the sampler; the case that guards
# it must go red. A mutant whose sed did not change the file is itself a FAIL
# (a mutant that did not apply looks exactly like one that was not caught).
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
[ -n "${ONLY_CASES:-}" ] || mutant vm_rows_not_in_telemetry H 'awk -F'"'"'\t'"'"' '"'"'{ print "vm\t" $9 "\t" $6 }'"'"'' 'true'

echo
echo "test_walk_net_sampler: ${PASSES} ok, ${FAILS} failed (of $((PASSES + FAILS)))"
[ "${FAILS}" -eq 0 ] && [ "${PASSES}" -eq 14 ] || exit 1
exit 0
