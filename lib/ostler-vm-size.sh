#!/usr/bin/env bash
# lib/ostler-vm-size.sh -- how much memory and CPU the container VM gets.
#
# WHY THIS EXISTS (v1.0.125 walk, 2026-11-06)
# -------------------------------------------
# The installer started the shared colima `default` VM with a fixed
# `--cpu 2 --memory 4` on every Mac. On the 125 walk the wiki compile was
# killed inside that VM by the kernel (dmesg global_oom, the compiler's python
# at 883 MB anon-rss), the tick logged it as a watchdog timeout, and the wiki
# silently stopped refreshing. 4 GiB is not enough for the stores, the wiki
# site and a compile at once; most Macs have far more to give.
#
# So the VM is sized from the host's RAM, by ONE table (OSTLER_VM_SIZE_TABLE
# below). ORM's per-compile RSS measurement (SCOPE_126 row c) retunes that
# table and nothing else.
#
# WHO CALLS IT
#   install.sh, fresh install: ostler_vm_size_resolve before `colima start`,
#     and ostler_vm_mark_owned after a start that CREATED the VM.
#   install.sh, upgrade mode (from the payload, services/vm/):
#     ostler_vm_upgrade_prepare after the daemon is booted out, and
#     ostler_vm_upgrade_verify after the new daemon is bootstrapped.
#
# THE SHARED-VM RULE (install.sh, the uninstaller's colima block). The colima
# `default` VM may be the customer's own. The upgrade path resizes it ONLY when
# Ostler owns it: an owner marker written when Ostler created it, or a legacy
# VM that carries exactly an Ostler size from this table with only ostler-*
# containers in it. Anything else is left alone and the decision is logged.
#
# WHY THE UPGRADE DOES NOT RUN `colima start` ITSELF. The VM must be started by
# the signed daemon, which holds Full Disk Access; a VM started by any other
# process cannot mount ~/Documents and the wiki dies (v1.0.10, Group C). So
# the upgrade STOPS the VM and rewrites the size in its colima.yaml, and the
# daemon's own ensure_colima_running starts it at the new size.
#
# Sourcing is side-effect free. bash 3.2 safe: no associative arrays, no
# `local -n`, no ${var,,}. Every function returns 0 unless its contract says
# otherwise, so an armed ERR trap in the caller never fires on a decision.

# ── THE TABLE ─────────────────────────────────────────────────────────
# One row per host-RAM band, highest band first:
#   min_host_gib  vm_memory_gib  vm_cpus
# The last row (min 0) is the floor. CPUs are proportionate to memory, then
# clamped so the host keeps half its cores (never below 2).
OSTLER_VM_SIZE_TABLE="32 10 5
24 8 4
16 6 3
0 4 2"
OSTLER_VM_DISK_GIB=30

# ── host detection ────────────────────────────────────────────────────
# Integer GiB of host RAM, or NOTHING when it cannot be read. Never a guess:
# an unreadable host falls to the floor row with that reason logged.
ostler_vm_host_ram_gib() {
    local _b="${OSTLER_VM_HOST_RAM_BYTES:-}"
    if [ -z "$_b" ]; then
        _b="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)" || _b=""
    fi
    case "$_b" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s\n' $(( _b / 1073741824 ))
}

ostler_vm_host_cpus() {
    local _n="${OSTLER_VM_HOST_NCPU:-}"
    if [ -z "$_n" ]; then
        _n="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null)" || _n=""
    fi
    case "$_n" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s\n' "$_n"
}

# ostler_vm_size_for <ram_gib|""> <ncpu|""> -> "MEM CPU" on stdout.
ostler_vm_size_for() {
    local _ram="$1" _ncpu="$2" _row _min _mem _cpu _cpu_r _cap
    _mem=4; _cpu=2
    case "$_ram" in ''|*[!0-9]*) _ram="" ;; esac
    if [ -n "$_ram" ]; then
        while read -r _min _row _cpu_r; do
            [ -n "$_min" ] || continue
            if [ "$_ram" -ge "$_min" ]; then _mem="$_row"; _cpu="$_cpu_r"; break; fi
        done <<EOF
$OSTLER_VM_SIZE_TABLE
EOF
    fi
    case "$_ncpu" in ''|*[!0-9]*) _ncpu="" ;; esac
    if [ -n "$_ncpu" ]; then
        _cap=$(( _ncpu / 2 )); [ "$_cap" -ge 2 ] || _cap=2
        [ "$_cpu" -le "$_cap" ] || _cpu="$_cap"
    fi
    printf '%s %s\n' "$_mem" "$_cpu"
}

# Sets OSTLER_VM_MEM_GIB, OSTLER_VM_CPUS and OSTLER_VM_SIZE_LINE (one log line
# naming the size AND what it was chosen from).
ostler_vm_size_resolve() {
    local _ram _ncpu _sz
    _ram="$(ostler_vm_host_ram_gib)"
    _ncpu="$(ostler_vm_host_cpus)"
    _sz="$(ostler_vm_size_for "$_ram" "$_ncpu")"
    OSTLER_VM_MEM_GIB="${_sz%% *}"
    OSTLER_VM_CPUS="${_sz##* }"
    if [ -n "$_ram" ]; then
        OSTLER_VM_SIZE_LINE="container VM size: ${OSTLER_VM_MEM_GIB} GiB memory, ${OSTLER_VM_CPUS} CPUs, ${OSTLER_VM_DISK_GIB} GiB disk (host ${_ram} GiB RAM, ${_ncpu:-unknown} CPUs; lib/ostler-vm-size.sh table)"
    else
        OSTLER_VM_SIZE_LINE="container VM size: ${OSTLER_VM_MEM_GIB} GiB memory, ${OSTLER_VM_CPUS} CPUs, ${OSTLER_VM_DISK_GIB} GiB disk (host RAM UNREADABLE, so the floor row; lib/ostler-vm-size.sh table)"
    fi
    return 0
}

# ── the colima VM ─────────────────────────────────────────────────────
ostler_vm_colima_bin() {
    local _c="${OSTLER_VM_COLIMA:-}"
    [ -n "$_c" ] && [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    for _c in /opt/homebrew/bin/colima /usr/local/bin/colima; do
        [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    done
    command -v colima 2>/dev/null || true
}

ostler_vm_docker_bin() {
    local _d="${OSTLER_VM_DOCKER:-}"
    [ -n "$_d" ] && [ -x "$_d" ] && { printf '%s\n' "$_d"; return 0; }
    for _d in /opt/homebrew/bin/docker /usr/local/bin/docker; do
        [ -x "$_d" ] && { printf '%s\n' "$_d"; return 0; }
    done
    command -v docker 2>/dev/null || true
}

ostler_vm_config_file() { printf '%s\n' "${COLIMA_HOME:-${HOME}/.colima}/default/colima.yaml"; }
ostler_vm_owner_marker() { printf '%s\n' "${OSTLER_STATE_DIR:-${HOME}/.ostler/state}/colima-vm-owner"; }
ostler_vm_pending_file() { printf '%s\n' "${OSTLER_STATE_DIR:-${HOME}/.ostler/state}/colima-vm-resize-pending"; }

# Does a colima `default` instance exist? Exact first-column match, the same
# predicate the uninstaller uses, so a sibling profile is never seen.
ostler_vm_default_exists() {
    local _c; _c="$(ostler_vm_colima_bin)"
    [ -n "$_c" ] || return 1
    "$_c" list 2>/dev/null </dev/null | awk 'NR>1 && $1=="default"{f=1} END{exit f?0:1}'
}

# Top-level integer value of <key> in colima.yaml, or nothing.
ostler_vm_config_get() {
    local _f; _f="$(ostler_vm_config_file)"
    [ -r "$_f" ] || return 0
    sed -n "s/^$1:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\$/\1/p" "$_f" 2>/dev/null | head -1
}

# Rewrite cpu and memory in colima.yaml, then READ THEM BACK. 0 only when the
# file now says what was asked; on any miss the original is restored.
ostler_vm_config_set_size() {
    local _mem="$1" _cpu="$2" _f _tmp
    _f="$(ostler_vm_config_file)"
    [ -w "$_f" ] || return 1
    _tmp="${_f}.ostler-tmp"
    cp -p "$_f" "${_f}.ostler-bak" 2>/dev/null || return 1
    sed -e "s/^memory:[[:space:]]*[0-9][0-9]*[[:space:]]*\$/memory: ${_mem}/" \
        -e "s/^cpu:[[:space:]]*[0-9][0-9]*[[:space:]]*\$/cpu: ${_cpu}/" "$_f" > "$_tmp" 2>/dev/null \
        && mv -f "$_tmp" "$_f" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    if [ "$(ostler_vm_config_get memory)" = "$_mem" ] && [ "$(ostler_vm_config_get cpu)" = "$_cpu" ]; then
        rm -f "${_f}.ostler-bak"
        return 0
    fi
    mv -f "${_f}.ostler-bak" "$_f" 2>/dev/null || true
    return 1
}

# Written ONLY when Ostler's own `colima start` created the VM.
ostler_vm_mark_owned() {
    local _m; _m="$(ostler_vm_owner_marker)"
    mkdir -p "${_m%/*}" 2>/dev/null || return 0
    printf 'owner=ostler\ncreated_at=%s\nreason=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-created by the Ostler installer}" > "$_m" 2>/dev/null || true
    return 0
}

# 0 when Ostler owns the `default` VM; sets OSTLER_VM_OWNER_REASON either way.
# A legacy VM (installed before the marker existed) is adopted only when ALL
# hold: its disk is OSTLER_VM_DISK_GIB, its memory/cpu pair is a row of this
# table (or the old fixed 4/2), the engine answers, and every container in it
# is ostler-*. A customer's own VM fails at least one of these.
ostler_vm_is_owned() {
    local _mem _cpu _disk _d _names _n _row_ok=0 _min _rm _rc
    if [ -f "$(ostler_vm_owner_marker)" ]; then
        OSTLER_VM_OWNER_REASON="owner marker present"
        return 0
    fi
    _mem="$(ostler_vm_config_get memory)"; _cpu="$(ostler_vm_config_get cpu)"; _disk="$(ostler_vm_config_get disk)"
    if [ "$_disk" != "$OSTLER_VM_DISK_GIB" ]; then
        OSTLER_VM_OWNER_REASON="no owner marker, and disk ${_disk:-unreadable} is not Ostler's ${OSTLER_VM_DISK_GIB}"
        return 1
    fi
    while read -r _min _rm _rc; do
        [ -n "$_min" ] || continue
        [ "$_mem" = "$_rm" ] && [ "$_cpu" = "$_rc" ] && _row_ok=1
    done <<EOF
$OSTLER_VM_SIZE_TABLE
EOF
    if [ "$_row_ok" -ne 1 ]; then
        OSTLER_VM_OWNER_REASON="no owner marker, and ${_mem:-?} GiB / ${_cpu:-?} CPUs is not a size Ostler sets"
        return 1
    fi
    _d="$(ostler_vm_docker_bin)"
    if [ -z "$_d" ]; then
        OSTLER_VM_OWNER_REASON="no owner marker, and no docker CLI to list what runs in the VM"
        return 1
    fi
    _names="$(DOCKER_HOST="unix://${COLIMA_HOME:-${HOME}/.colima}/default/docker.sock" "$_d" ps -a --format '{{.Names}}' 2>/dev/null </dev/null)" || {
        OSTLER_VM_OWNER_REASON="no owner marker, and the engine did not answer, so what runs in the VM is unknown"
        return 1
    }
    if [ -z "$_names" ]; then
        OSTLER_VM_OWNER_REASON="no owner marker, and the VM holds no containers, so nothing says it is Ostler's"
        return 1
    fi
    while IFS= read -r _n; do
        case "$_n" in
            ostler-*) : ;;
            *) OSTLER_VM_OWNER_REASON="no owner marker, and the VM also holds a container that is not Ostler's"
               return 1 ;;
        esac
    done <<EOF
$_names
EOF
    OSTLER_VM_OWNER_REASON="legacy VM adopted: Ostler's size and only ostler-* containers"
    ostler_vm_mark_owned "$OSTLER_VM_OWNER_REASON"
    return 0
}

# ── stores ────────────────────────────────────────────────────────────
# 0 when qdrant AND oxigraph answer through the host front door. Qdrant's
# /healthz is outside its api-key by the vendor's design; Oxigraph needs the
# credential when store auth is on, read from the same curl config the
# installer writes (no value ever passes through argv).
ostler_vm_stores_healthy() {
    local _conf="${OSTLER_DIR:-${HOME}/.ostler}/secrets/store-curl.conf"
    curl -sf --max-time 5 http://localhost:6333/healthz >/dev/null 2>&1 </dev/null || return 1
    if [ -r "$_conf" ]; then
        curl -sf --max-time 5 -K "$_conf" http://localhost:7878/ >/dev/null 2>&1 </dev/null || return 1
    else
        curl -sf --max-time 5 http://localhost:7878/ >/dev/null 2>&1 </dev/null || return 1
    fi
    return 0
}

# Poll until the stores are healthy or <secs> pass. 0 healthy, 1 not.
ostler_vm_wait_stores() {
    local _limit="$1" _waited=0 _step="${OSTLER_VM_POLL_SECS:-5}"
    while [ "$_waited" -lt "$_limit" ]; do
        ostler_vm_stores_healthy && { OSTLER_VM_WAITED="$_waited"; return 0; }
        sleep "$_step"
        _waited=$(( _waited + _step ))
    done
    OSTLER_VM_WAITED="$_waited"
    ostler_vm_stores_healthy && return 0
    return 1
}

# ── upgrade mode ──────────────────────────────────────────────────────
# Step 1, with the daemon booted out. Decides, and when the VM is Ostler's and
# smaller than the table says: stop it and rewrite its size. Writes the
# pending file the verify step reads. Always returns 0: every outcome is a
# logged decision, and a VM left as it was is never a reason to abort.
#   $1 = log function (called with one line)
ostler_vm_upgrade_prepare() {
    local _log="${1:-echo}" _c _cur _curcpu _p
    _p="$(ostler_vm_pending_file)"
    rm -f "$_p" 2>/dev/null || true
    _c="$(ostler_vm_colima_bin)"
    if [ -z "$_c" ]; then
        "$_log" "vm resize: no colima on this Mac (Docker Desktop or no engine); nothing to resize"
        return 0
    fi
    if ! ostler_vm_default_exists; then
        "$_log" "vm resize: no colima 'default' VM; nothing to resize"
        return 0
    fi
    ostler_vm_size_resolve
    _cur="$(ostler_vm_config_get memory)"; _curcpu="$(ostler_vm_config_get cpu)"
    if [ -z "$_cur" ] || [ -z "$_curcpu" ]; then
        "$_log" "vm resize: CANNOT-RUN: $(ostler_vm_config_file) does not state memory and cpu; VM left as it is"
        return 0
    fi
    if [ "$_cur" -ge "$OSTLER_VM_MEM_GIB" ]; then
        "$_log" "vm resize: VM has ${_cur} GiB, the table asks ${OSTLER_VM_MEM_GIB}; nothing to do. ${OSTLER_VM_SIZE_LINE}"
        return 0
    fi
    if ! ostler_vm_is_owned; then
        "$_log" "vm resize: NOT resizing the colima 'default' VM (${_cur} GiB, the table asks ${OSTLER_VM_MEM_GIB}): ${OSTLER_VM_OWNER_REASON}. The wiki compile may run out of memory in it."
        return 0
    fi
    "$_log" "vm resize: Ostler's VM has ${_cur} GiB / ${_curcpu} CPUs, the table asks ${OSTLER_VM_MEM_GIB} / ${OSTLER_VM_CPUS} (${OSTLER_VM_OWNER_REASON}); stopping it to resize. ${OSTLER_VM_SIZE_LINE}"
    if ! "$_c" stop default >/dev/null 2>&1 </dev/null; then
        "$_c" stop --force default >/dev/null 2>&1 </dev/null || {
            "$_log" "ERROR: ERR-UPG-VM-RESIZE-STOP-FAILED: colima stop failed; the VM is left at ${_cur} GiB"
            return 0
        }
    fi
    if ! ostler_vm_config_set_size "$OSTLER_VM_MEM_GIB" "$OSTLER_VM_CPUS"; then
        "$_log" "ERROR: ERR-UPG-VM-RESIZE-CONFIG-FAILED: could not rewrite $(ostler_vm_config_file); the VM stays at ${_cur} GiB and the daemon will start it as it was"
        return 0
    fi
    mkdir -p "${_p%/*}" 2>/dev/null || true
    printf 'prev_memory=%s\nprev_cpu=%s\nnew_memory=%s\nnew_cpu=%s\n' \
        "$_cur" "$_curcpu" "$OSTLER_VM_MEM_GIB" "$OSTLER_VM_CPUS" > "$_p" 2>/dev/null || true
    "$_log" "vm resize: VM stopped and set to ${OSTLER_VM_MEM_GIB} GiB / ${OSTLER_VM_CPUS} CPUs; the daemon starts it"
    return 0
}

# Step 2, after the new daemon is bootstrapped (it starts the VM). Returns:
#   0  nothing was pending, or the stores are healthy at the new size
#   2  the stores did not come back at the new size, the old size was put
#      back and they ARE healthy again (logged as an ERR; the upgrade goes on)
#   1  the stores are down even at the old size (logged as an ERR; the caller
#      fails the upgrade so the Hub rolls back)
#   $1 = log function   $2 = launchd target of the daemon, for the revert restart
ostler_vm_upgrade_verify() {
    local _log="${1:-echo}" _target="${2:-}" _p _pm _pc _nm _c _limit
    _p="$(ostler_vm_pending_file)"
    [ -f "$_p" ] || return 0
    _pm="$(sed -n 's/^prev_memory=//p' "$_p")"; _pc="$(sed -n 's/^prev_cpu=//p' "$_p")"
    _nm="$(sed -n 's/^new_memory=//p' "$_p")"
    _limit="${OSTLER_VM_VERIFY_SECS:-420}"
    if ostler_vm_wait_stores "$_limit"; then
        "$_log" "vm resize: VM now ${_nm} GiB (was ${_pm}); qdrant and oxigraph healthy after ${OSTLER_VM_WAITED}s"
        rm -f "$_p"
        return 0
    fi
    "$_log" "ERROR: ERR-UPG-VM-RESIZE-STORES-UNHEALTHY: qdrant/oxigraph not healthy ${OSTLER_VM_WAITED}s after resizing the VM to ${_nm} GiB; putting it back to ${_pm} GiB"
    _c="$(ostler_vm_colima_bin)"
    if [ -n "$_c" ]; then
        "$_c" stop default >/dev/null 2>&1 </dev/null || "$_c" stop --force default >/dev/null 2>&1 </dev/null || true
    fi
    ostler_vm_config_set_size "$_pm" "$_pc" \
        || "$_log" "ERROR: ERR-UPG-VM-RESIZE-REVERT-CONFIG-FAILED: could not put $(ostler_vm_config_file) back to ${_pm} GiB"
    if [ -n "$_target" ]; then
        launchctl kickstart -k "$_target" >/dev/null 2>&1 </dev/null || true
    fi
    rm -f "$_p"
    if ostler_vm_wait_stores "$_limit"; then
        "$_log" "ERROR: ERR-UPG-VM-RESIZE-REVERTED: the VM is back at ${_pm} GiB and the stores are healthy; it was NOT resized, so the wiki compile may still run out of memory"
        return 2
    fi
    "$_log" "ERROR: ERR-UPG-VM-RESIZE-STORES-DOWN: qdrant/oxigraph are not healthy even at the old ${_pm} GiB"
    return 1
}
