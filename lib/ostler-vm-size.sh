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
#     and ostler_vm_mark_owned after a start that CREATED the VM. An upgrade
#     does NOT resize an existing VM in this build (Archie, 126: the upgrade
#     never touches colima); that is the post-launch branch
#     post-launch/vm-resize-on-upgrade.
#
# Sourcing is side-effect free. bash 3.2 safe: no associative arrays, no
# `local -n`, no ${var,,}. Every function returns 0 unless its contract says
# otherwise, so an armed ERR trap in the caller never fires on a decision.

# ── THE TABLE ─────────────────────────────────────────────────────────
# One row per host-RAM band, highest band first:
#   min_host_gib  vm_memory_gib  vm_cpus  wiki_compiler_mib  wiki_site_mib
# The last row (min 0) is the floor. CPUs are proportionate to memory, then
# clamped so the host keeps half its cores (never below 2).
#
# The two last columns are docker cgroup memory limits (compose mem_limit)
# for the wiki containers. On the 125 box the kernel made 9 global OOM kills
# in the 4 GiB VM: 7 compiler pythons at 838-960 MB, 1 mkdocs, and the
# OXIGRAPH store. With a cgroup limit the compiler is killed inside its own
# cgroup (memcg OOM) and never reaches the global OOM killer that took the
# store. The site's mkdocs build RSS is NOT MEASURED; its limit is generous
# so a big wiki is not memcg-killed in a restart loop (ORM row c retunes).
# Whatever the limits leave is the stores' (qdrant, oxigraph, redis),
# which carry no cap and a negative oom_score_adj in the compose file.
OSTLER_VM_SIZE_TABLE="32 10 5 4096 2048
24 8 4 3072 1536
16 6 3 2048 1024
0 4 2 1536 1024"
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

# ostler_vm_size_for <ram_gib|""> <ncpu|""> -> "MEM CPU COMPILER_MIB SITE_MIB".
ostler_vm_size_for() {
    local _ram="$1" _ncpu="$2" _row _min _mem _cpu _cpu_r _cap _cm _sm _cm_r _sm_r
    _mem=4; _cpu=2; _cm=1536; _sm=1024
    case "$_ram" in ''|*[!0-9]*) _ram="" ;; esac
    if [ -n "$_ram" ]; then
        while read -r _min _row _cpu_r _cm_r _sm_r; do
            [ -n "$_min" ] || continue
            if [ "$_ram" -ge "$_min" ]; then _mem="$_row"; _cpu="$_cpu_r"; _cm="$_cm_r"; _sm="$_sm_r"; break; fi
        done <<EOF
$OSTLER_VM_SIZE_TABLE
EOF
    fi
    case "$_ncpu" in ''|*[!0-9]*) _ncpu="" ;; esac
    if [ -n "$_ncpu" ]; then
        _cap=$(( _ncpu / 2 )); [ "$_cap" -ge 2 ] || _cap=2
        [ "$_cpu" -le "$_cap" ] || _cpu="$_cap"
    fi
    printf '%s %s %s %s\n' "$_mem" "$_cpu" "$_cm" "$_sm"
}

# Sets OSTLER_VM_MEM_GIB, OSTLER_VM_CPUS and OSTLER_VM_SIZE_LINE (one log line
# naming the size AND what it was chosen from).
ostler_vm_size_resolve() {
    local _ram _ncpu _sz
    _ram="$(ostler_vm_host_ram_gib)"
    _ncpu="$(ostler_vm_host_cpus)"
    _sz="$(ostler_vm_size_for "$_ram" "$_ncpu")"
    set -- $_sz
    OSTLER_VM_MEM_GIB="$1"; OSTLER_VM_CPUS="$2"
    OSTLER_WIKI_COMPILER_MEM_MIB="$3"; OSTLER_WIKI_SITE_MEM_MIB="$4"
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

ostler_vm_owner_marker() { printf '%s\n' "${OSTLER_STATE_DIR:-${HOME}/.ostler/state}/colima-vm-owner"; }

# Does a colima `default` instance exist? Exact first-column match, the same
# predicate the uninstaller uses, so a sibling profile is never seen.
ostler_vm_default_exists() {
    local _c; _c="$(ostler_vm_colima_bin)"
    [ -n "$_c" ] || return 1
    "$_c" list 2>/dev/null </dev/null | awk 'NR>1 && $1=="default"{f=1} END{exit f?0:1}'
}

# Written ONLY when Ostler's own `colima start` created the VM. Nothing reads
# it in this build; it records ownership now so a later upgrade-time resize
# (post-launch) can tell Ostler's VM from a customer's.
ostler_vm_mark_owned() {
    local _m; _m="$(ostler_vm_owner_marker)"
    mkdir -p "${_m%/*}" 2>/dev/null || return 0
    printf 'owner=ostler\ncreated_at=%s\nreason=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-created by the Ostler installer}" > "$_m" 2>/dev/null || true
    return 0
}

# Write the wiki containers' memory limits for THIS host's table row into the
# compose .env (docker compose reads it from the project dir on every call:
# install, the refresh tick, the daemon). Replaces any earlier value, keeps
# every other key and the file mode. Sets OSTLER_VM_LIMITS_LINE for the log.
# Always returns 0; a write failure leaves the compose defaults (the floor
# row) in force and says so in the line.
ostler_vm_write_container_limits() {
    local _env="$1" _tmp
    ostler_vm_size_resolve
    OSTLER_VM_LIMITS_LINE="wiki container memory limits: compiler ${OSTLER_WIKI_COMPILER_MEM_MIB}m, site ${OSTLER_WIKI_SITE_MEM_MIB}m (VM ${OSTLER_VM_MEM_GIB} GiB; stores uncapped)"
    [ -n "$_env" ] || return 0
    _tmp="${_env}.ostler-vm-tmp"
    if { [ -f "$_env" ] && grep -vE '^OSTLER_WIKI_(COMPILER|SITE)_MEM_LIMIT=' "$_env" > "$_tmp" 2>/dev/null || : > "$_tmp"; } \
        && printf 'OSTLER_WIKI_COMPILER_MEM_LIMIT=%sm\nOSTLER_WIKI_SITE_MEM_LIMIT=%sm\n' \
            "$OSTLER_WIKI_COMPILER_MEM_MIB" "$OSTLER_WIKI_SITE_MEM_MIB" >> "$_tmp" \
        && chmod 600 "$_tmp" && mv -f "$_tmp" "$_env"; then
        return 0
    fi
    rm -f "$_tmp" 2>/dev/null || true
    OSTLER_VM_LIMITS_LINE="${OSTLER_VM_LIMITS_LINE}; COULD NOT WRITE ${_env}, so the compose floor defaults apply"
    return 0
}
