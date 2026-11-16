#!/usr/bin/env bash
# walk_vm_resources LABEL
#
# Prints the resources the walk ran on, so a FAIL on a memory-starved box can be read against them:
# the colima VM's cpus, memory and disk (from `colima list --json`) and vm_stat's free pages. READ-ONLY:
# it runs `colima list` and `vm_stat` and writes nothing. Each value that cannot be read says so
# ("not measured: ..."); it is never a zero it did not read.
#
# When OSTLER_BOX_HOST is set, the commands run on that box over ssh; otherwise on this machine.
# Called at walk START and at walk END (run_box_walk.sh), so the record shows both.
walk_vm_resources() {
    local label="$1" remote="" out
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        remote="${OSTLER_BOX_HOST}"
    fi
    _wvr() {
        if [ -n "$remote" ]; then
            /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" "$1" 2>/dev/null
        else
            /bin/sh -c "$1" 2>/dev/null
        fi
    }
    printf 'VM RESOURCES (%s) on %s\n' "$label" "${remote:-this machine}"
    local colima_json
    colima_json="$(_wvr 'colima list --json' || true)"
    if [ -z "$colima_json" ]; then
        printf '  colima: not measured (colima not present or did not answer)\n'
    else
        printf '%s\n' "$colima_json" | python3 -c '
import json, sys
seen = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        vm = json.loads(line)
    except ValueError:
        continue
    seen += 1
    def gib(v):
        try:
            return "%.1fGiB" % (float(v) / 1073741824.0)
        except (TypeError, ValueError):
            return "?"
    print("  colima VM %s: cpus=%s memory=%s disk=%s status=%s" % (
        vm.get("name", "?"), vm.get("cpus", "?"), gib(vm.get("memory")), gib(vm.get("disk")), vm.get("status", "?")))
if not seen:
    print("  colima: not measured (no VM listed)")
' 2>/dev/null || printf '  colima: not measured (could not parse colima list)\n'
    fi
    out="$(_wvr 'vm_stat' || true)"
    if [ -z "$out" ] || ! printf '%s' "$out" | /usr/bin/grep -qF 'Pages free'; then
        printf '  vm_stat: not measured (vm_stat did not answer)\n'
    else
        local page free
        page="$(printf '%s' "$out" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -1)"
        free="$(printf '%s' "$out" | sed -n 's/^Pages free: *\([0-9][0-9]*\)\..*/\1/p' | head -1)"
        printf '  vm_stat: Pages free=%s page_size=%s bytes\n' "${free:-not measured}" "${page:-not measured}"
    fi
    printf '\n'
}
