#!/usr/bin/env bash
#
# scripts/lib_walk_cold_state.sh -- WAS THE BOX COLD WHEN THE INSTALL STARTED?
#
# WHY THIS EXISTS. A walk is fast when the box is WARM: the colima data disk
# still holds the container images, and ~/.ollama still holds the models. On
# the v1.0.117 walk on Mini16 the Vane image pull alone took 6515 s of a 9685 s
# install (3.43 GB at 0.53 MB/s), while the 7.2 GB model step took 5 s because
# the model was already on disk ("existing=kept" in install.log). That walk was
# therefore NOT cold, and its record had a field for only one of the three warm
# surfaces (stores_provenance). Nothing in the record said the model download,
# the image pulls and the VM creation were never exercised.
#
# Warm walks are the cheap way to iterate. They are only honest if the record
# says so. This file is the measurement and the record rows; nothing here
# removes anything.
#
# THREE FUNCTIONS, THREE PLACES THEY RUN:
#   walk_cold_state_measure [home]    ON THE BOX, just before install.sh starts
#                                     (ttywalk.sh). Prints the marker.
#   walk_cold_state_read_box [home]   ON THE BOX, after the walk
#                                     (post_walk_qa.sh). Prints the marker plus
#                                     the install.sh run header as epoch seconds.
#   walk_cold_state_rows              ON THE OPERATOR. Reads what the box
#                                     printed on stdin and emits the record rows.
#
# THE MARKER (~/.walk-cold-state), tab separated:
#   measured_at   <epoch seconds>
#   cold_state    cold | NOT-COLD | unknown(<why>)
#   not_cold      <surface>  <what was not exercised>      (0..n rows)
#
# THE RECORD ROWS:
#   cold_state    cold | NOT-COLD | unknown(...) | not-recorded(<why>)
#   not_cold      <surface>  <detail>                      (0..n rows)
#
# A MARKER IS ONLY BELIEVED FOR THE INSTALL IT WAS MEASURED FOR. A GUI walk
# after a ttywalk on the same box would otherwise inherit the old answer. So
# the reader ties it to the LAST "=== install.sh run <ISO>Z" header in
# ~/.ostler/logs/install.log: the header must fall within
# [measured_at - 60 s, measured_at + 900 s]. Anything else is
# not-recorded(stale ...), never a clean value.
#
# "cold" IS ONLY WRITTEN WHEN EVERY SURFACE WAS LOOKED AT AND FOUND ABSENT. A
# surface that could not be read makes the whole state unknown(...).
#
# BASH 3.2 (macOS). No associative arrays, no mapfile. These functions are
# shipped to the box with `declare -f` and run under `bash -s`, so they must
# not reference anything outside themselves.

# walk_cold_state_measure [home]
walk_cold_state_measure() {
    local _h="${1:-$HOME}" _rows="" _unk="" _kib _m _b _n _list
    local _tab
    _tab="$(printf '\t')"

    # 1. The container VM instance. Its presence means VM creation is skipped.
    if [ -e "${_h}/.colima/_lima/colima" ] || [ -L "${_h}/.colima/_lima/colima" ]; then
        _rows="${_rows}not_cold${_tab}colima_vm${_tab}a container VM instance existed before install (VM creation not exercised)
"
    fi

    # 2. The colima data disk. It survives `colima delete --force` (measured
    #    2026-09-23, box_pristine.sh) and holds every pulled image layer and
    #    every volume. Any image already in it is NOT pulled by the install.
    if [ -e "${_h}/.colima/_lima/_disks/colima" ]; then
        if [ -r "${_h}/.colima/_lima/_disks/colima" ] && [ -x "${_h}/.colima/_lima/_disks/colima" ]; then
            _kib="$(du -sk "${_h}/.colima/_lima/_disks/colima" 2>/dev/null | awk '{print $1}')"
            _rows="${_rows}not_cold${_tab}container_data_disk${_tab}${_kib:-unmeasured} KiB of image layers and volumes carried over (registry pulls not exercised for any image already in it)
"
        else
            _unk="${_unk}colima data disk present but unreadable; "
        fi
    fi

    # 3. Ollama models. box_pristine.sh does not touch ~/.ollama, so before this
    #    field no walk, cold or not, said whether the model download ran.
    _m="${_h}/.ollama/models/manifests"
    _b="${_h}/.ollama/models/blobs"
    if [ -e "$_m" ]; then
        if [ -r "$_m" ] && [ -x "$_m" ]; then
            # manifests/<registry>/<namespace>/<model>/<tag>
            _list="$(cd "$_m" 2>/dev/null && find . -type f 2>/dev/null \
                | awk -F/ 'NF>=5 { ns=$(NF-2); n=$(NF-1); t=$NF; if (ns=="library") print n ":" t; else print ns "/" n ":" t }' \
                | LC_ALL=C sort)"
            if [ -n "$_list" ]; then
                while IFS= read -r _n; do
                    [ -n "$_n" ] || continue
                    _rows="${_rows}not_cold${_tab}ollama_model${_tab}${_n} present before install (model download not exercised)
"
                done <<EOF
$_list
EOF
            fi
        else
            _unk="${_unk}ollama manifests present but unreadable; "
        fi
    fi
    if [ -d "$_b" ] && [ -z "$(printf '%s' "$_rows" | awk -F'\t' '$2=="ollama_model"')" ]; then
        if [ -r "$_b" ] && [ -x "$_b" ]; then
            if [ -n "$(cd "$_b" && find . -type f 2>/dev/null | head -1)" ]; then
                _kib="$(du -sk "$_b" 2>/dev/null | awk '{print $1}')"
                _rows="${_rows}not_cold${_tab}ollama_blobs${_tab}${_kib:-unmeasured} KiB of model blobs with no manifest (a partial download is resumed, not exercised from zero)
"
            fi
        else
            _unk="${_unk}ollama blobs present but unreadable; "
        fi
    fi

    printf 'measured_at\t%s\n' "$(date -u +%s)"
    if [ -n "$_unk" ]; then
        printf 'cold_state\tunknown(%s)\n' "${_unk%; }"
    elif [ -n "$_rows" ]; then
        printf 'cold_state\tNOT-COLD\n'
    else
        printf 'cold_state\tcold\n'
    fi
    printf '%s' "$_rows"
}

# walk_cold_state_read_box [home]
# Prints the marker verbatim, then `install_run_epoch <epoch>` (empty if the
# header is absent or does not parse). BSD date first (the box), GNU second.
walk_cold_state_read_box() {
    local _h="${1:-$HOME}" _iso _ep=""
    cat "${_h}/.walk-cold-state" 2>/dev/null
    _iso="$(grep -a '^=== install.sh run ' "${_h}/.ostler/logs/install.log" 2>/dev/null \
        | tail -1 | awk '{print $4}')"
    if [ -n "$_iso" ]; then
        _ep="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$_iso" +%s 2>/dev/null)" \
            || _ep="$(date -u -d "$_iso" +%s 2>/dev/null)" || _ep=""
    fi
    printf 'install_run_epoch\t%s\n' "$_ep"
}

# walk_cold_state_rows   (reads the box output on stdin)
walk_cold_state_rows() {
    local _raw _at _state _run _rows _bad
    _raw="$(cat)"
    _at="$(printf '%s\n' "$_raw" | awk -F'\t' '$1=="measured_at"{print $2; exit}')"
    _state="$(printf '%s\n' "$_raw" | awk -F'\t' '$1=="cold_state"{print $2; exit}')"
    _run="$(printf '%s\n' "$_raw" | awk -F'\t' '$1=="install_run_epoch"{print $2; exit}')"
    # Exactly three fields, a known surface word, no empty detail. Anything else
    # is a malformed marker, and a malformed marker is not a clean one.
    _rows="$(printf '%s\n' "$_raw" | awk -F'\t' '$1=="not_cold"')"
    _bad="$(printf '%s\n' "$_rows" | awk -F'\t' 'NF && (NF!=3 || $2 !~ /^[a-z_]+$/ || $3=="")' | head -1)"

    # "COULD NOT LOOK" IS NOT "FOUND NOTHING". walk_cold_state_read_box always
    # prints install_run_epoch, so its absence means the read never happened
    # (ssh failed, bash -s refused), which must not be reported as "no marker".
    if ! printf '%s\n' "$_raw" | awk -F'\t' '$1=="install_run_epoch"{f=1} END{exit !f}'; then
        printf 'cold_state\tnot-recorded(the box read returned nothing: ssh or the reader failed, so nothing was looked at)\n'
        return 0
    fi
    if [ -z "$_at" ] && [ -z "$_state" ]; then
        printf 'cold_state\tnot-recorded(no ~/.walk-cold-state on the box: a GUI walk, or one that predates the marker; whether caches were warm is NOT KNOWN)\n'
        return 0
    fi
    case "$_at" in
        ''|*[!0-9]*)
            printf 'cold_state\tnot-recorded(marker has no numeric measured_at)\n'; return 0 ;;
    esac
    case "$_state" in
        cold|NOT-COLD|unknown\(*\)) : ;;
        *) printf 'cold_state\tnot-recorded(marker held an unrecognised cold_state)\n'; return 0 ;;
    esac
    if [ -n "$_bad" ]; then
        printf 'cold_state\tnot-recorded(marker held a malformed not_cold row)\n'; return 0
    fi
    if [ "$_state" = "cold" ] && [ -n "$_rows" ]; then
        printf 'cold_state\tnot-recorded(marker says cold AND lists warm surfaces)\n'; return 0
    fi
    if [ "$_state" = "NOT-COLD" ] && [ -z "$_rows" ]; then
        printf 'cold_state\tnot-recorded(marker says NOT-COLD and names no surface)\n'; return 0
    fi
    case "$_run" in
        ''|*[!0-9]*)
            printf 'cold_state\tnot-recorded(no install.sh run header to tie the marker to this install)\n'; return 0 ;;
    esac
    if [ "$_run" -lt $((_at - 60)) ] || [ "$_run" -gt $((_at + 900)) ]; then
        printf 'cold_state\tnot-recorded(stale: measured at epoch %s, the last install.sh run started at epoch %s)\n' "$_at" "$_run"
        return 0
    fi
    printf 'cold_state\t%s\n' "$_state"
    [ -n "$_rows" ] && printf '%s\n' "$_rows"
    return 0
}
