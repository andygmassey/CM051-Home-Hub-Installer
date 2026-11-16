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
# store. ORM measured (walk125/compile_rss/TABLE.tsv, real RSS, NOT docker
# stats, which under-reads 64-96 MiB against a real 173-811): compiler about
# 60 MiB + 22 KiB/page (173 / 550 / 841 MiB at 5k / 20k / 36k pages), and
# wiki-site mkdocs up to 958 MiB on a real book, so both floors are 1536m.
# 16 GB row fits its 6 GiB VM: compiler 1536 + site 1536 + oxigraph ~955 +
# qdrant ~812 + vane ~276 + VM base ~400 = 5515 MiB of 6144.
# Whatever the limits leave is the stores' (qdrant, oxigraph, redis),
# which carry no cap and a negative oom_score_adj in the compose file.
OSTLER_VM_SIZE_TABLE="32 10 5 4096 2048
24 8 4 3072 1536
16 6 3 1536 1536
0 4 2 1536 1536"
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
    _mem=4; _cpu=2; _cm=1536; _sm=1536
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
    # Copy every OTHER key. grep exit 1 means "no other lines", exit 2 means
    # the file could not be read: that must REFUSE, never become an empty
    # copy that replaces JWT_SECRET and the rest (Archie, #3364).
    local _g=0
    if [ -e "$_env" ]; then
        grep -vE '^OSTLER_WIKI_(COMPILER|SITE)_MEM_LIMIT=' "$_env" > "$_tmp" 2>/dev/null || _g=$?
        if [ "$_g" -gt 1 ]; then
            rm -f "$_tmp" 2>/dev/null || true
            OSTLER_VM_LIMITS_LINE="${OSTLER_VM_LIMITS_LINE}; COULD NOT READ ${_env} (grep exit ${_g}), so it was left untouched and the compose floor defaults apply"
            return 0
        fi
    else
        : > "$_tmp" || { OSTLER_VM_LIMITS_LINE="${OSTLER_VM_LIMITS_LINE}; COULD NOT WRITE ${_env}, so the compose floor defaults apply"; return 0; }
    fi
    if printf 'OSTLER_WIKI_COMPILER_MEM_LIMIT=%sm\nOSTLER_WIKI_SITE_MEM_LIMIT=%sm\n' \
            "$OSTLER_WIKI_COMPILER_MEM_MIB" "$OSTLER_WIKI_SITE_MEM_MIB" >> "$_tmp" \
        && chmod 600 "$_tmp" && mv -f "$_tmp" "$_env"; then
        return 0
    fi
    rm -f "$_tmp" 2>/dev/null || true
    OSTLER_VM_LIMITS_LINE="${OSTLER_VM_LIMITS_LINE}; COULD NOT WRITE ${_env}, so the compose floor defaults apply"
    return 0
}

# ── the size record, read by the daemon and the Doctor ────────────────
# WHY (2026-11-14, Mini16): the installer sized the VM 3 CPU / 6 GiB, but
# colima.yaml kept 2/4 and the ostler-assistant daemon restarted colima with a
# hard-coded `--cpu 2 --memory 4`, so every restart shrank the VM. The chosen
# size is now recorded here, and oa reads this file (src/main.rs
# recorded_vm_size). Keys match tests/fixtures/vm_size_state_contract.txt.
ostler_vm_state_dir() { printf '%s\n' "${OSTLER_STATE_DIR:-${HOME}/.ostler/state}"; }

# ostler_vm_record_size <cpus> <mem_gib> <source>
# Writes the record atomically. Returns 1 when it could not, and never aborts
# an armed ERR trap: the caller decides what to log.
ostler_vm_record_size() {
    local _d _f _tmp
    _d="$(ostler_vm_state_dir)"; _f="${_d}/vm_size"; _tmp="${_f}.tmp.$$"
    mkdir -p "$_d" 2>/dev/null || return 1
    { printf 'cpus=%s\nmemory_gib=%s\ndisk_gib=%s\nsource=%s\nrecorded_at=%s\n' \
        "$1" "$2" "$OSTLER_VM_DISK_GIB" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_tmp" \
      && mv -f "$_tmp" "$_f"; } 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    return 0
}

# ostler_vm_persist_colima_yaml <colima.yaml> <cpus> <mem_gib>
# Sets the top-level cpu and memory keys in colima's own config, so a bare
# `colima start` (the Doctor's fix commands) starts the installed size too.
# Both keys must already exist: a missing key is refused, not invented.
# Rewrites in place (cat into the existing file keeps its mode and inode).
ostler_vm_persist_colima_yaml() {
    local _y="$1" _tmp _rc
    # OWNERSHIP GUARD: a customer's own VM is never rewritten. Refused unless
    # the owner marker says Ostler created this VM (ostler_vm_is_owned).
    ostler_vm_is_owned || return 1
    [ -f "$_y" ] || return 1
    _tmp="${_y}.ostler-vm-tmp.$$"
    awk -v c="$2" -v m="$3" '
        /^cpu:/    { print "cpu: " c; n++; next }
        /^memory:/ { print "memory: " m; n++; next }
        { print }
        END { exit (n == 2 ? 0 : 3) }' "$_y" > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" -ne 0 ]; then rm -f "$_tmp" 2>/dev/null; return 1; fi
    if cat "$_tmp" > "$_y" 2>/dev/null; then rm -f "$_tmp" 2>/dev/null; return 0; fi
    rm -f "$_tmp" 2>/dev/null; return 1
}

# ostler_vm_is_owned: 0 when the owner marker says Ostler created this VM.
ostler_vm_is_owned() {
    local _m; _m="$(ostler_vm_owner_marker)"
    if [ -f "$_m" ] && grep -qx 'owner=ostler' "$_m" 2>/dev/null; then return 0; fi
    return 1
}

# ostler_vm_measured_size -> prints "CPUS MEM_GIB" for the `default` profile as
# colima reports it NOW (`colima list --json`, which is NDJSON: one object per
# line, so another profile is its own line and is skipped). Prints nothing when
# it cannot be read, or the profile is not Running.
ostler_vm_measured_size() {
    local _c _out _l="" _line _cpus _bytes _gib
    _c="$(ostler_vm_colima_bin)"
    [ -n "$_c" ] || return 0
    _out="$("$_c" list --json 2>/dev/null </dev/null)" || return 0
    while IFS= read -r _line; do
        case "$_line" in
            *'"name":"default"'*|*'"name": "default"'*) _l="$_line"; break ;;
        esac
    done <<VMSIZE_ROWS
$_out
VMSIZE_ROWS
    [ -n "$_l" ] || return 0
    case "$_l" in *'"status":"Running"'*|*'"status": "Running"'*) ;; *) return 0 ;; esac
    _cpus="$(printf '%s\n' "$_l" | sed -n 's/.*"cpus": *\([0-9][0-9]*\).*/\1/p')"
    _bytes="$(printf '%s\n' "$_l" | sed -n 's/.*"memory": *\([0-9][0-9]*\).*/\1/p')"
    case "$_cpus" in ''|*[!0-9]*) return 0 ;; esac
    case "$_bytes" in ''|*[!0-9]*) return 0 ;; esac
    _gib=$(( (_bytes + 536870912) / 1073741824 ))
    [ "$_cpus" -ge 1 ] && [ "$_gib" -ge 1 ] || return 0
    printf '%s %s\n' "$_cpus" "$_gib"
    return 0
}

# ostler_vm_after_start: runs after the installer's colima start. Records and
# persists the size colima REPORTS for the default profile, never the requested
# one (colima ignores --cpu/--memory on a running VM). Only Ostler's own VM (the
# owner marker) is recorded or rewritten. Always returns 0; sets
# OSTLER_VM_RECORD_LINE to say what happened.
ostler_vm_after_start() {
    local _m _c _g _rec _cfg
    if ! ostler_vm_is_owned; then
        OSTLER_VM_RECORD_LINE="container VM is not Ostler's, so its size is left as it is and nothing is recorded"
        return 0
    fi
    _m="$(ostler_vm_measured_size)"
    if [ -z "$_m" ]; then
        OSTLER_VM_RECORD_LINE="size NOT RECORDED: could not read the running size back from colima (the background engine will use colima's stored config)"
        return 0
    fi
    _c="${_m%% *}"; _g="${_m##* }"
    if ostler_vm_record_size "$_c" "$_g" installer; then _rec="recorded in $(ostler_vm_state_dir)/vm_size"
    else _rec="NOT RECORDED (could not write $(ostler_vm_state_dir)/vm_size)"; fi
    _cfg="${HOME}/.colima/default/colima.yaml"
    if ostler_vm_persist_colima_yaml "$_cfg" "$_c" "$_g"; then _cfg="colima.yaml set to ${_c} CPU / ${_g} GiB"
    else _cfg="colima.yaml NOT updated (${_cfg} missing a cpu/memory key)"; fi
    OSTLER_VM_RECORD_LINE="container VM size ${_c} CPU / ${_g} GiB (read back from colima): ${_rec}; ${_cfg}"
    return 0
}

# ostler_vm_install_start: THE INSTALLER'S COLIMA START, the one call install.sh
# makes in its retry loop. A VM is sized only when Ostler creates it or already
# owns it. A VM that existed before and has no Ostler marker is started with its
# OWN stored size: no --cpu/--memory, no record, no colima.yaml rewrite.
# Returns 0 only when colima started AND docker answers (the caller retries).
ostler_vm_install_start() {
    local _c _existed=0
    _c="$(ostler_vm_colima_bin)"
    if [ -z "$_c" ]; then OSTLER_VM_RECORD_LINE="colima not found"; return 127; fi
    if ostler_vm_default_exists; then _existed=1; fi
    if [ "$_existed" = 0 ]; then
        "$_c" start --cpu "$OSTLER_VM_CPUS" --memory "$OSTLER_VM_MEM_GIB" --disk "$OSTLER_VM_DISK_GIB" || return 1
        ostler_vm_mark_owned "created by the Ostler installer's colima start"
    elif ostler_vm_is_owned; then
        "$_c" start --cpu "$OSTLER_VM_CPUS" --memory "$OSTLER_VM_MEM_GIB" --disk "$OSTLER_VM_DISK_GIB" || return 1
    else
        "$_c" start || return 1
    fi
    docker info &>/dev/null 2>&1 || return 1
    ostler_vm_after_start
    return 0
}
