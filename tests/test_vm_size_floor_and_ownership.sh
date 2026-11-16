#!/bin/bash
# (1) When the sizing table is missing, the installer's fallback starts an absent
#     VM at the 2 CPU / 4 GiB floor (never a bare colima start, whose default
#     memory is below 4 GiB), and starts an existing VM with its own stored size.
# (2) OWNERSHIP: a customer's own default VM (no Ostler owner marker) keeps its
#     colima.yaml BYTE-IDENTICAL through the installer's start and record path.
# Stub colima and docker only; throwaway HOME and state dir. Nothing real is touched.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/lib/ostler-vm-size.sh"
INSTALL="${ROOT}/install.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" OSTLER_STATE_DIR="$W/home/.ostler/state"
STUB="$W/stub"; mkdir -p "$STUB" "$HOME/.colima/default" "$OSTLER_STATE_DIR"
export STUB_DIR="$STUB"
fails=0; total=0
ok()  { total=$((total+1)); echo "PASS: $1"; }
bad() { total=$((total+1)); echo "FAIL: $1"; fails=$((fails+1)); }

# Stub colima: an absent VM is created with colima's OWN defaults (2 CPU / 2 GiB)
# unless --cpu/--memory are passed. An existing VM ignores them, as colima does.
cat > "$STUB/colima" <<'STUBEOF'
#!/bin/bash
echo "colima $*" >> "$STUB_DIR/calls"
GIB=1073741824; state="$STUB_DIR/vm"
case "$1" in
  list)
    if [ "${2:-}" = "--json" ]; then
      [ -f "$state" ] && { read -r c m < "$state"; echo "{\"name\":\"default\",\"status\":\"Running\",\"cpus\":${c},\"memory\":$((m * GIB))}"; }
    else
      echo "PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK"
      [ -f "$state" ] && echo "default    Running    aarch64    2       4GiB      30GiB"
    fi ;;
  start)
    if [ ! -f "$state" ]; then
      c=2; m=2; prev=""
      for a in "$@"; do case "$prev" in --cpu) c=$a ;; --memory) m=$a ;; esac; prev=$a; done
      echo "$c $m" > "$state"
    fi ;;
esac
exit 0
STUBEOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/docker"
chmod 755 "$STUB/colima" "$STUB/docker"
export PATH="$STUB:$PATH" OSTLER_VM_COLIMA="$STUB/colima"

reset() {
    case "$OSTLER_STATE_DIR" in "$W"/*) ;; *) echo "refusing: state dir outside sandbox"; exit 9 ;; esac
    rm -rf "$OSTLER_STATE_DIR" "$STUB/vm" "$STUB/calls"; mkdir -p "$OSTLER_STATE_DIR"
    rm -f "$HOME/.colima/default/colima.yaml"
}

# ── (1) the missing-table fallback, extracted from the REAL install.sh line ──
# Takes the else-branch text that install.sh runs when lib/ostler-vm-size.sh is absent.
FALLBACK="$(sed -n 's/^ *else \(warn "VM sizing table missing.*\)  # i18n-exempt$/\1/p' "$INSTALL")"
FALLBACK="${FALLBACK%; fi}"   # the closing fi of the if/else is outside the else branch text
if [ -z "$FALLBACK" ]; then bad "install.sh fallback line not found (grep returned nothing)"; else ok "install.sh fallback line found"; fi
warn() { :; }; info() { :; }; INSTALL_LOG=/dev/null
SCRIPT_DIR="$W/no-lib-here"
run_fallback() { _ostler_vm_lib="${SCRIPT_DIR}/lib/ostler-vm-size.sh"; eval "$FALLBACK"; ostler_vm_install_start; }

reset
run_fallback; rc=$?
if [ "$rc" = 0 ] && [ -f "$STUB/vm" ] && [ "$(cat "$STUB/vm")" = "2 4" ] && grep -q "^colima start --cpu 2 --memory 4 --disk 30$" "$STUB/calls"; then
    ok "missing table + absent VM: created at the 2 CPU / 4 GiB floor with --disk 30"
else
    bad "missing table + absent VM: expected floor flags, got calls=$(tr '\n' ';' < "$STUB/calls" 2>/dev/null) vm=$(cat "$STUB/vm" 2>/dev/null)"
fi

reset
echo "3 6" > "$STUB/vm"          # an existing VM the installer did not size
run_fallback
if grep -q "^colima start$" "$STUB/calls" && ! grep -q -- "--cpu" "$STUB/calls"; then
    ok "missing table + existing VM: bare start, its stored size kept"
else
    bad "missing table + existing VM: expected bare start, got $(tr '\n' ';' < "$STUB/calls" 2>/dev/null)"
fi

# ── (2) OWNERSHIP: a customer's own VM's colima.yaml is byte-identical ──
. "$LIB"
reset
echo "3 6" > "$STUB/vm"
printf 'cpu: 3\nmemory: 6\ndisk: 60\narch: aarch64\n' > "$HOME/.colima/default/colima.yaml"
cp "$HOME/.colima/default/colima.yaml" "$W/yaml.before"
# The installer's real path for an existing VM with no Ostler marker:
ostler_vm_install_start; ostler_vm_after_start
if cmp -s "$W/yaml.before" "$HOME/.colima/default/colima.yaml"; then
    ok "customer's own VM (no owner marker): colima.yaml byte-identical after start and record"
else
    bad "customer's own VM: colima.yaml CHANGED after start and record"
fi

# The persist function itself refuses without the marker, and leaves the file alone.
reset
echo "3 6" > "$STUB/vm"
printf 'cpu: 3\nmemory: 6\ndisk: 60\narch: aarch64\n' > "$HOME/.colima/default/colima.yaml"
cp "$HOME/.colima/default/colima.yaml" "$W/yaml.before"
if ostler_vm_persist_colima_yaml "$HOME/.colima/default/colima.yaml" 2 4; then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && cmp -s "$W/yaml.before" "$HOME/.colima/default/colima.yaml"; then
    ok "persist refuses a VM with no owner marker and leaves colima.yaml untouched"
else
    bad "persist rewrote a VM with no owner marker (rc=$rc)"
fi

# Control: an Ostler-owned VM IS persisted, so the guard is not blanket-refusing.
reset
echo "3 6" > "$STUB/vm"
printf 'cpu: 3\nmemory: 6\ndisk: 60\narch: aarch64\n' > "$HOME/.colima/default/colima.yaml"
ostler_vm_mark_owned "control"
if ostler_vm_persist_colima_yaml "$HOME/.colima/default/colima.yaml" 3 6 && grep -q '^cpu: 3$' "$HOME/.colima/default/colima.yaml"; then
    ok "control: an Ostler-owned VM is persisted"
else
    bad "control: an Ostler-owned VM was not persisted"
fi

echo "== $((total - fails))/$total passed"
[ "$fails" -eq 0 ]
