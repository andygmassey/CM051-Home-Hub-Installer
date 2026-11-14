#!/bin/bash
# The installed VM size is recorded and persisted, and the record matches the
# shared contract fixture (oa reads the same file; see oa src/main.rs).
# Every case runs under a throwaway HOME and OSTLER_STATE_DIR. Nothing touches
# the real ~/.colima or ~/.ostler.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/lib/ostler-vm-size.sh"
FIX="${ROOT}/tests/fixtures/vm_size_state_contract.txt"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/fakehome" OSTLER_STATE_DIR="$W/fakehome/.ostler/state"
mkdir -p "$HOME/.colima/default"
fails=0
total=0
ok()  { total=$((total+1)); echo "PASS: $1"; }
bad() { total=$((total+1)); echo "FAIL: $1"; fails=$((fails+1)); }
# shellcheck source=/dev/null
source "$LIB"
OSTLER_VM_DISK_GIB=30; OSTLER_VM_CPUS=3; OSTLER_VM_MEM_GIB=6

# 1. the record the installer writes carries the chosen size
ostler_vm_record_installed_size
REC="$OSTLER_STATE_DIR/vm_size"
grep -qx 'cpus=3' "$REC" 2>/dev/null && grep -qx 'memory_gib=6' "$REC" 2>/dev/null \
  && ok "record holds cpus=3 memory_gib=6" || bad "record missing or wrong: $(cat "$REC" 2>&1)"

# 2. the contract fixture's keys are all present in the written record (same names)
for k in cpus memory_gib disk_gib source; do
  grep -q "^${k}=" "$REC" && grep -q "^${k}=" "$FIX" && ok "contract key $k on both sides" \
    || bad "contract key $k missing on one side"
done

# 3. colima.yaml is rewritten for cpu and memory, other keys kept
cat > "$HOME/.colima/default/colima.yaml" <<'Y'
cpu: 2
disk: 30
memory: 4
arch: aarch64
Y
ostler_vm_record_installed_size
Y="$HOME/.colima/default/colima.yaml"
grep -qx 'cpu: 3' "$Y" && grep -qx 'memory: 6' "$Y" && grep -qx 'arch: aarch64' "$Y" && grep -qx 'disk: 30' "$Y" \
  && ok "colima.yaml cpu 3 memory 6, other keys kept" || bad "colima.yaml not persisted: $(cat "$Y")"

# 4. a yaml missing a key is refused and left byte-identical
printf 'cpu: 2\narch: aarch64\n' > "$Y"; before="$(cat "$Y")"
if ostler_vm_persist_colima_yaml "$Y" 3 6; then bad "yaml with no memory key was accepted"
else [ "$(cat "$Y")" = "$before" ] && ok "yaml missing a key refused, unchanged" || bad "refused yaml was modified"; fi

# 5. an unwritable state dir does not abort: returns 1 and the line says NOT RECORDED
OSTLER_STATE_DIR="$W/fakehome/file-not-dir/state"; : > "$W/fakehome/file-not-dir"
ostler_vm_record_installed_size; rc=$?
[ "$rc" -eq 0 ] && case "$OSTLER_VM_RECORD_LINE" in *"NOT RECORDED"*) ok "unwritable record reports NOT RECORDED and returns 0" ;; *) bad "unwritable record not named: $OSTLER_VM_RECORD_LINE" ;; esac

# 6. WIRED: the installer calls the recorder right after its colima start
# succeeds, before the loop breaks. A recorder nothing calls is not a record.
INSTALL="${ROOT}/install.sh"
start_ln="$(grep -n 'if colima start --cpu "\$OSTLER_VM_CPUS"' "$INSTALL" | head -1 | cut -d: -f1)"
call_ln="$(grep -n 'ostler_vm_record_installed_size; info' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -n "$start_ln" ] && [ -n "$call_ln" ] && [ "$call_ln" -gt "$start_ln" ] && [ "$((call_ln - start_ln))" -lt 8 ]; then
  ok "install.sh records the size right after its colima start (lines ${start_ln} and ${call_ln})"
else
  bad "install.sh does not call ostler_vm_record_installed_size after colima start (start=${start_ln:-none} call=${call_ln:-none})"
fi

echo "vm_size_record: ${total} checks run, ${fails} failed"
exit $fails
