#!/bin/bash
# The installed VM size: who may be sized, what is recorded, and the installer's
# REAL colima start block, executed in a sandbox against a stub colima and docker.
# Every case runs under a throwaway HOME and OSTLER_STATE_DIR, and the stub is the
# only colima reachable (PATH and OSTLER_VM_COLIMA point at it). Nothing touches
# the real ~/.colima, ~/.ostler or a real VM.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/lib/ostler-vm-size.sh"
INSTALL="${ROOT}/install.sh"
FIX="${ROOT}/tests/fixtures/vm_size_state_contract.txt"
GIB=1073741824
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" OSTLER_STATE_DIR="$W/home/.ostler/state"
STUB="$W/stub"; mkdir -p "$STUB" "$HOME/.colima/default"
fails=0; total=0
ok()  { total=$((total+1)); echo "PASS: $1"; }
bad() { total=$((total+1)); echo "FAIL: $1"; fails=$((fails+1)); }

# ── stub colima ─────────────────────────────────────────────────────
# $STUB/vm holds "CPUS MEM_GIB" of the default profile when it exists. Like the
# real colima, `start` honours --cpu/--memory only when it CREATES the VM; on a
# running or existing VM the flags are ignored (the measured behaviour).
# STUB_OTHER=1 adds a second profile BEFORE default. STUB_READBACK_FAIL=1 makes
# `list --json` fail.
cat > "$STUB/colima" <<'STUBEOF'
#!/bin/bash
echo "colima $*" >> "$STUB_DIR/calls"
GIB=1073741824
state="$STUB_DIR/vm"
case "$1" in
  list)
    if [ "${2:-}" = "--json" ]; then
      [ "${STUB_READBACK_FAIL:-0}" = 1 ] && exit 1
      [ "${STUB_OTHER:-0}" = 1 ] && echo '{"name":"other","status":"Running","cpus":12,"memory":34359738368}'
      if [ -f "$state" ]; then read -r c m < "$state"; echo "{\"name\":\"default\",\"status\":\"Running\",\"cpus\":${c},\"memory\":$((m * GIB))}"; fi
    else
      echo "PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK"
      [ -f "$state" ] && echo "default    Running    aarch64    2       4GiB      30GiB"
    fi ;;
  start)
    if [ ! -f "$state" ]; then
      c=2; m=4; prev=""
      for a in "$@"; do case "$prev" in --cpu) c=$a ;; --memory) m=$a ;; esac; prev=$a; done
      echo "$c $m" > "$state"
    fi ;;
esac
exit 0
STUBEOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/docker"
chmod 755 "$STUB/colima" "$STUB/docker"
export STUB_DIR="$STUB"

reset() {  # a fresh sandbox state for one scenario; paths are all under $W
    case "$OSTLER_STATE_DIR" in "$W"/*) ;; *) echo "refusing: state dir outside sandbox"; exit 9 ;; esac
    rm -rf "$OSTLER_STATE_DIR" "$STUB/vm" "$STUB/calls"
    mkdir -p "$OSTLER_STATE_DIR" "$HOME/.colima/default"
    rm -f "$HOME/.colima/default/colima.yaml"
    unset STUB_OTHER STUB_READBACK_FAIL
}
yaml_before_start() { printf 'cpu: 2\ndisk: 30\nmemory: 4\narch: aarch64\n' > "$HOME/.colima/default/colima.yaml"; }

# ── unit: the writers and the ownership predicate ───────────────────
# shellcheck source=/dev/null
source "$LIB"
OSTLER_VM_COLIMA="$STUB/colima"; OSTLER_VM_DISK_GIB=30
reset
ostler_vm_record_size 3 6 installer && grep -qx 'cpus=3' "$OSTLER_STATE_DIR/vm_size" && grep -qx 'memory_gib=6' "$OSTLER_STATE_DIR/vm_size" \
  && ok "record_size writes cpus=3 memory_gib=6" || bad "record_size did not write the record"
for k in cpus memory_gib disk_gib source; do
  grep -q "^${k}=" "$OSTLER_STATE_DIR/vm_size" && grep -q "^${k}=" "$FIX" && ok "contract key $k on both sides" || bad "contract key $k missing on one side"
done
yaml_before_start; printf 'cpu: 2\narch: aarch64\n' > "$HOME/.colima/default/colima.yaml"; before="$(cat "$HOME/.colima/default/colima.yaml")"
if ostler_vm_persist_colima_yaml "$HOME/.colima/default/colima.yaml" 3 6; then bad "yaml with no memory key was accepted"
elif [ "$(cat "$HOME/.colima/default/colima.yaml")" = "$before" ]; then ok "yaml missing a key is refused and left byte-identical"
else bad "refused yaml was modified"; fi
reset; ( OSTLER_STATE_DIR="$W/home/file-not-dir/state"; : > "$W/home/file-not-dir"; ostler_vm_record_size 3 6 installer ) \
  && bad "record_size into an unwritable dir reported success" || ok "record_size into an unwritable dir returns non-zero"
reset; ostler_vm_is_owned && bad "a VM with no marker reads as Ostler's" || ok "no marker: not owned"
ostler_vm_mark_owned "test"; ostler_vm_is_owned && ok "marker written: owned" || bad "marker written but not read as owned"

# ── the installer's REAL start block, executed ──────────────────────
# Extracted from install.sh: from the sizing lines through the end of the start
# loop. Run under `set -Eeuo pipefail` with an ERR trap, as install.sh runs it.
BLOCK="$W/start_block.sh"
awk '/_ostler_vm_lib="\$\{SCRIPT_DIR\}\/lib\/ostler-vm-size.sh"/{f=1} f{print} f && /^            done$/{exit}' "$INSTALL" > "$BLOCK"
if ! grep -q 'colima_started' "$BLOCK" || ! grep -q '^            done$' "$BLOCK"; then
  bad "premise: could not extract the start block from install.sh"
else
  ok "premise: extracted the installer's start block ($(wc -l < "$BLOCK" | tr -d ' ') lines)"
fi

run_block() {  # executes the installer block; output is the log it writes
  ( set -Eeuo pipefail
    trap 'echo "ERR TRAP FIRED at line $LINENO"; exit 99' ERR
    export PATH="$STUB:/usr/bin:/bin" OSTLER_VM_COLIMA="$STUB/colima" OSTLER_VM_HOST_RAM_BYTES=$((16 * GIB)) OSTLER_VM_HOST_NCPU=8
    SCRIPT_DIR="$ROOT"; INSTALL_LOG="$W/install.log"
    MSG_INFO_COLIMA_START_ATTEMPT='attempt %s of %s'; MSG_WARN_COLIMA_START_RETRY='retry in %s s'
    info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }; sleep() { :; }
    # shellcheck source=/dev/null
    . "$BLOCK"
    echo "colima_started=$colima_started"
  ) 2>&1
}
grep_n() { grep -c -- "$1" "$2" || true; }

# S1. A customer's own VM (8 CPU / 16 GiB, no Ostler marker) must stay untouched.
reset; yaml_before_start; printf '8 16' > "$STUB/vm"
cp "$HOME/.colima/default/colima.yaml" "$W/yaml.s1"
out="$(run_block)"
if [ "$(grep_n -- '--cpu' "$STUB/calls")" = 0 ] && grep -q '^colima start$' "$STUB/calls"; then ok "S1 customer VM: colima start is run with NO size flags"
else bad "S1 customer VM: start carried size flags: $(cat "$STUB/calls")"; fi
[ "$(cat "$STUB/vm")" = "8 16" ] && ok "S1 customer VM: still 8 CPU / 16 GiB after the installer's start" || bad "S1 customer VM was resized to $(cat "$STUB/vm")"
cmp -s "$W/yaml.s1" "$HOME/.colima/default/colima.yaml" && ok "S1 customer VM: colima.yaml byte-identical" || bad "S1 customer VM: colima.yaml rewritten"
[ ! -e "$OSTLER_STATE_DIR/vm_size" ] && [ ! -e "$OSTLER_STATE_DIR/colima-vm-owner" ] && ok "S1 customer VM: no size record and no ownership marker" || bad "S1 customer VM: record or marker written"
grep -q 'colima_started=1' <<< "$out" && ok "S1 customer VM: the install still counts the start as done" || bad "S1 customer VM: start not counted: $out"

# S2. Fresh Mac: Ostler creates the VM at the table size, marks it, records what it measured.
reset; yaml_before_start
out="$(run_block)"
grep -q '^colima start --cpu 3 --memory 6 --disk 30$' "$STUB/calls" && ok "S2 fresh: colima created at the table size 3 CPU / 6 GiB, disk 30" || bad "S2 fresh: start args wrong: $(cat "$STUB/calls")"
[ -f "$OSTLER_STATE_DIR/colima-vm-owner" ] && grep -qx 'owner=ostler' "$OSTLER_STATE_DIR/colima-vm-owner" && ok "S2 fresh: VM marked as Ostler's" || bad "S2 fresh: not marked"
grep -qx 'cpus=3' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null && grep -qx 'memory_gib=6' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null && ok "S2 fresh: record holds the measured 3 CPU / 6 GiB" || bad "S2 fresh: record wrong: $(cat "$OSTLER_STATE_DIR/vm_size" 2>&1)"
grep -qx 'cpu: 3' "$HOME/.colima/default/colima.yaml" && grep -qx 'memory: 6' "$HOME/.colima/default/colima.yaml" && ok "S2 fresh: colima.yaml persisted 3 / 6" || bad "S2 fresh: colima.yaml not persisted"
grep -q 'colima_started=1' <<< "$out" && ok "S2 fresh: started" || bad "S2 fresh: not started: $out"

# S3. Ostler's own VM, where colima IGNORES the requested size on a running VM:
# the record must hold what colima reports (2 / 4), not what was requested (3 / 6).
reset; yaml_before_start; printf '2 4' > "$STUB/vm"; ostler_vm_mark_owned "test"
run_block >/dev/null
grep -qx 'cpus=2' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null && grep -qx 'memory_gib=4' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null \
  && ok "S3 owned, flags ignored: record holds the measured 2 CPU / 4 GiB, not the requested 3 / 6" \
  || bad "S3 owned: record is not the measured size: $(cat "$OSTLER_STATE_DIR/vm_size" 2>&1)"
grep -qx 'cpu: 2' "$HOME/.colima/default/colima.yaml" && grep -qx 'memory: 4' "$HOME/.colima/default/colima.yaml" \
  && ok "S3 owned: colima.yaml persisted the measured size too" || bad "S3 owned: colima.yaml holds the requested size, not the measured"

# S4. Ostler's VM, but colima cannot be read back: nothing is recorded as a size.
reset; yaml_before_start; printf '3 6' > "$STUB/vm"; ostler_vm_mark_owned "test"
out="$(STUB_READBACK_FAIL=1 run_block)"
[ ! -e "$OSTLER_STATE_DIR/vm_size" ] && grep -q 'NOT RECORDED' <<< "$out" && grep -q 'colima_started=1' <<< "$out" \
  && ok "S4 read-back fails: no record written, named NOT RECORDED, install still started" \
  || bad "S4 read-back fails: record or message wrong: $out"

# S5. A second profile sits before default. The default's size must be read, not the other's.
reset; yaml_before_start; printf '2 4' > "$STUB/vm"; ostler_vm_mark_owned "test"
STUB_OTHER=1 run_block >/dev/null
grep -qx 'cpus=2' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null && grep -qx 'memory_gib=4' "$OSTLER_STATE_DIR/vm_size" 2>/dev/null \
  && ok "S5 two profiles (other first, 12 CPU): the default's 2 CPU / 4 GiB is recorded" || bad "S5 two profiles: record $(cat "$OSTLER_STATE_DIR/vm_size" 2>&1)"

# CONTROL: the stub must be able to show each arm fail. The fresh case (S2) is the
# positive control for the stub's start/list behaviour; S1 is its negative.
[ "$(cat "$STUB/vm" 2>/dev/null)" != "" ] && ok "control: the stub keeps VM state across calls" || bad "control: stub lost state"

echo "vm_size_record: ${total} checks run, ${fails} failed"
exit $fails
