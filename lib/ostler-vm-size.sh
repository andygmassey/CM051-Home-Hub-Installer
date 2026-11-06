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
