#!/usr/bin/env bash
# tests/test_vm_size_from_host_ram.sh
#
# The container VM is sized from host RAM, and an upgrade resizes ONLY a VM
# Ostler owns (v1.0.126 a1 + a2).
#
# THE DEFECT (v1.0.125 walk, 2026-11-06): install.sh started colima with a
# fixed `--cpu 2 --memory 4` on every Mac, and the wiki compile was OOM-killed
# inside that 4 GiB VM (dmesg global_oom, python 883 MB anon-rss).
#
#   arm 1  the table, run: 16/24/32/64 GB hosts, the floor, an unreadable host,
#          and the CPU clamp.
#   arm 2  install.sh starts colima at the table's size, not a literal 4, and
#          marks a VM it CREATED. MUTANT: the old literal line put back must
#          turn this arm red.
#   arm 3  upgrade, behavioural, against stub colima/docker/curl/launchctl and
#          a real colima.yaml: owned+small is resized; a VM with a foreign
#          container, a customer-sized VM, and a big-enough VM are NOT touched;
#          a legacy Ostler VM is adopted; verify passes, reverts (rc 2) or
#          fails loud (rc 1) with the ERR codes.
#   arm 4  the upgrade block calls prepare AFTER the swap and BEFORE the plists
#          are re-rendered (daemon booted out), and verify after, with _upg_die.
#   arm 5  the lib reaches both artefacts: the DMG bundle (project.yml) and the
#          upgrade payload (gui/Makefile, cp + post-copy req list).
#
# Never touches the real colima, docker, keychain or HOME: every binary is a
# stub on PATH or named by OSTLER_VM_COLIMA / OSTLER_VM_DOCKER, HOME is a temp.
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
LIB="${OSTLER_VM_SIZE_LIB:-${REPO}/lib/ostler-vm-size.sh}"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
MAKEFILE="${REPO}/gui/Makefile"
PROJECT_YML="${REPO}/gui/project.yml"
for f in "$INSTALL_SH" "$MAKEFILE" "$PROJECT_YML"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: $f unreadable; nothing was checked"; exit 2; }
done
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
TMP="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/vm-size.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
GIB=1073741824

echo "test_vm_size_from_host_ram"
if [ ! -r "$LIB" ]; then
    bad "lib/ostler-vm-size.sh does not exist: the VM size is still a literal in install.sh"
    echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi

# ── arm 1: the table ─────────────────────────────────────────────────
size_for() {  # ram_gib ncpu -> "MEM CPU"
    ( . "$LIB"; OSTLER_VM_HOST_RAM_BYTES=$(( $1 * GIB )) OSTLER_VM_HOST_NCPU="$2"; export OSTLER_VM_HOST_RAM_BYTES OSTLER_VM_HOST_NCPU
      ostler_vm_size_resolve; printf '%s %s\n' "$OSTLER_VM_MEM_GIB" "$OSTLER_VM_CPUS" )
}
check_size() {  # ram ncpu want label
    local got; got="$(size_for "$1" "$2")"
    if [ "$got" = "$3" ]; then ok "arm 1: $4 -> $got"; else bad "arm 1: $4 -> '$got', want '$3'"; fi
}
check_size 16 8  "6 3"  "16 GB Mac, 8 cores"
check_size 24 10 "8 4"  "24 GB Mac, 10 cores"
check_size 32 10 "10 5" "32 GB Mac, 10 cores"
check_size 64 8  "10 4" "64 GB Mac, 8 cores (CPU clamped to half the host)"
check_size 8  8  "4 2"  "8 GB Mac (floor)"
check_size 15 8  "4 2"  "15 GiB reported (just under the 16 band, floor)"
check_size 32 2  "10 2" "2-core host never goes below 2 CPUs"
line="$( . "$LIB"; OSTLER_VM_HOST_RAM_BYTES=garbage; export OSTLER_VM_HOST_RAM_BYTES; ostler_vm_size_resolve; printf '%s|%s|%s' "$OSTLER_VM_MEM_GIB" "$OSTLER_VM_CPUS" "$OSTLER_VM_SIZE_LINE" )"
case "$line" in
    "4|2|"*UNREADABLE*) ok "arm 1: unreadable host RAM -> floor 4/2, and the log line SAYS it was unreadable" ;;
    *) bad "arm 1: unreadable host RAM gave '$line'" ;;
esac
line="$( . "$LIB"; OSTLER_VM_HOST_RAM_BYTES=$((24 * GIB)) OSTLER_VM_HOST_NCPU=10; export OSTLER_VM_HOST_RAM_BYTES OSTLER_VM_HOST_NCPU; ostler_vm_size_resolve; printf '%s' "$OSTLER_VM_SIZE_LINE" )"
case "$line" in
    *"8 GiB memory, 4 CPUs"*"host 24 GiB RAM, 10 CPUs"*) ok "arm 1: the log line names the size AND what it was chosen from" ;;
    *) bad "arm 1: log line '$line'" ;;
esac

# ── arm 2: install.sh uses the table at the colima start ─────────────
arm2() {  # file -> 0 when the start is table-sized and the creation is marked
    local f="$1"
    grep -qE '^[[:space:]]*if colima start --cpu "\$OSTLER_VM_CPUS" --memory "\$OSTLER_VM_MEM_GIB" --disk 30 ' "$f" || return 1
    grep -vE '^[[:space:]]*#' "$f" | grep -qE 'colima start --cpu [0-9]+ --memory [0-9]+' && return 1
    grep -qF '_ostler_vm_lib="${SCRIPT_DIR}/lib/ostler-vm-size.sh"' "$f" || return 1
    grep -qF 'ostler_vm_size_resolve; info "$OSTLER_VM_SIZE_LINE"' "$f" || return 1
    grep -qF '[[ "$_ostler_vm_existed" == 1 ]] || ostler_vm_mark_owned' "$f" || return 1
    return 0
}
if arm2 "$INSTALL_SH"; then ok "arm 2: install.sh starts colima at the table's size, logs it, marks a VM it created"
else bad "arm 2: install.sh does not start colima from the table (or does not log/mark it)"; fi
sed 's/if colima start --cpu "\$OSTLER_VM_CPUS" --memory "\$OSTLER_VM_MEM_GIB" --disk 30 /if colima start --cpu 2 --memory 4 --disk 30 /' "$INSTALL_SH" > "$TMP/install.mutant.sh"
if cmp -s "$INSTALL_SH" "$TMP/install.mutant.sh"; then
    bad "arm 2 MUTANT did not apply; the arm cannot be shown to fail"
elif arm2 "$TMP/install.mutant.sh"; then
    bad "arm 2 MUTANT: the old fixed 4 GiB line put back still passes"
else
    ok "arm 2 MUTANT: the old fixed '--memory 4' line put back is caught"
fi

# ── arm 2b: the REAL install.sh start block, executed ────────────────
# Extracted from install.sh (the sizing lines through the end of the start
# loop) and run under `set -Eeuo pipefail` with an armed ERR trap, as the
# installer runs it, against a stub colima/docker. Proves the block sizes
# the start, logs the size, and marks ONLY a VM it created.
BLK="$TMP/start_block.sh"
awk '/_ostler_vm_lib="\$\{SCRIPT_DIR\}\/lib\/ostler-vm-size.sh"/{f=1} f{print} f && /^            done$/{exit}' "$INSTALL_SH" > "$BLK"
if ! grep -q 'colima start --cpu' "$BLK" || ! grep -q '^            done$' "$BLK"; then
    bad "arm 2b premise: could not extract the colima start block from install.sh"
else
    run_block() {  # vm_existed(0/1) -> prints the stub log
        local d="$TMP/blk$1"; mkdir -p "$d/bin" "$d/lib" "$d/state"
        cp "$LIB" "$d/lib/ostler-vm-size.sh"
        cat > "$d/bin/colima" <<STUB
#!/bin/bash
echo "colima \$*" >> "$d/log"
if [ "\$1" = list ]; then echo 'PROFILE STATUS'; [ "$1" = 1 ] && echo 'default Stopped'; fi
exit 0
STUB
        printf '#!/bin/bash\necho "docker $*" >> "%s/log"\nexit 0\n' "$d" > "$d/bin/docker"
        chmod 755 "$d/bin/colima" "$d/bin/docker"
        ( set -Eeuo pipefail; trap 'echo "ERR TRAP FIRED at $LINENO" >> "'"$d"'/log"; exit 99' ERR
          export PATH="$d/bin:/usr/bin:/bin" OSTLER_STATE_DIR="$d/state" OSTLER_VM_COLIMA="$d/bin/colima" \
                 OSTLER_VM_HOST_RAM_BYTES=$((16 * GIB)) OSTLER_VM_HOST_NCPU=8
          SCRIPT_DIR="$d"; MSG_INFO_COLIMA_START_ATTEMPT='attempt %s of %s'; MSG_WARN_COLIMA_START_RETRY='retry in %s'
          info() { echo "INFO $*" >> "$d/log"; }; warn() { echo "WARN $*" >> "$d/log"; }
          . "$BLK"
          echo "started=$colima_started" >> "$d/log" ) || echo "BLOCK EXIT $?" >> "$d/log"
        [ -f "$d/state/colima-vm-owner" ] && echo "MARKER WRITTEN" >> "$d/log"
        cat "$d/log"
    }
    out0="$(run_block 0)"; out1="$(run_block 1)"
    if grep -q 'colima start --cpu 3 --memory 6 --disk 30' <<< "$out0" && grep -q 'INFO container VM size: 6 GiB memory, 3 CPUs' <<< "$out0" \
       && grep -q 'started=1' <<< "$out0" && grep -q 'MARKER WRITTEN' <<< "$out0" && ! grep -q 'ERR TRAP\|BLOCK EXIT' <<< "$out0"; then
        ok "arm 2b: the real block, under set -Eeuo pipefail + ERR trap: 16 GB host starts colima at 6 GiB / 3 CPUs, logs it, marks the VM it created"
    else bad "arm 2b: real block on a fresh Mac: $(tr '\n' ';' <<< "$out0")"; fi
    if grep -q 'colima start --cpu 3 --memory 6' <<< "$out1" && ! grep -q 'MARKER WRITTEN' <<< "$out1" && ! grep -q 'ERR TRAP\|BLOCK EXIT' <<< "$out1"; then
        ok "arm 2b control: a VM that existed before the start is NOT marked as Ostler's"
    else bad "arm 2b control: pre-existing VM: $(tr '\n' ';' <<< "$out1")"; fi
fi

# ── arm 3: upgrade, behavioural ──────────────────────────────────────
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/colima" <<EOF
#!/bin/bash
echo "\$@" >> "\$STUB_LOG"
case "\$1" in
    list) printf 'PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK      RUNTIME    ADDRESS\n'
          [ -f "\$STUB_VM_EXISTS" ] && printf 'default    Running    aarch64    2       4GiB      30GiB     docker\n'
          exit 0 ;;
    stop) exit 0 ;;
esac
exit 0
EOF
cat > "$STUBS/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
[ "$1 $2" = "ps -a" ] && cat "$STUB_CONTAINERS"
exit 0
EOF
# curl: healthy unless STUB_CURL_MODE says otherwise. "old-only" models a VM
# whose stores come back only at the OLD size (memory: 4 in colima.yaml).
cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$STUB_LOG"
case "${STUB_CURL_MODE:-ok}" in
    ok) exit 0 ;;
    down) exit 7 ;;
    old-only) grep -q '^memory: 4$' "$COLIMA_HOME/default/colima.yaml" && exit 0; exit 7 ;;
esac
EOF
cat > "$STUBS/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$STUB_LOG"
exit 0
EOF
chmod 755 "$STUBS"/*

new_box() {  # name mem cpu disk containers(\n-separated) marker(0/1)
    local b="$TMP/$1"
    mkdir -p "$b/hm" "$b/colima/default" "$b/state"
    printf 'cpu: %s\ndisk: %s\nmemory: %s\narch: host\nruntime: docker\n' "$3" "$4" "$2" > "$b/colima/default/colima.yaml"
    printf '%b' "$5" > "$b/containers"
    : > "$b/vm_exists"; : > "$b/log"
    [ "$6" = 1 ] && printf 'owner=ostler\n' > "$b/state/colima-vm-owner"
    printf '%s\n' "$b"
}
in_box() {  # box cmd... ; runs a lib function in an isolated environment
    local b="$1"; shift
    ( export HOME="$b/hm" COLIMA_HOME="$b/colima" OSTLER_STATE_DIR="$b/state" \
             OSTLER_DIR="$b/hm/.ostler" PATH="$STUBS:/usr/bin:/bin" \
             OSTLER_VM_COLIMA="$STUBS/colima" OSTLER_VM_DOCKER="$STUBS/docker" \
             STUB_LOG="$b/log" STUB_VM_EXISTS="$b/vm_exists" STUB_CONTAINERS="$b/containers" \
             OSTLER_VM_HOST_RAM_BYTES=$((16 * GIB)) OSTLER_VM_HOST_NCPU=8 \
             OSTLER_VM_VERIFY_SECS="${VSECS:-2}" OSTLER_VM_POLL_SECS=1
      . "$LIB"; "$@" )
}
ylog() { printf '%s\n' "$*" >> "$YLOG"; }
yaml_mem() { sed -n 's/^memory: //p' "$1/colima/default/colima.yaml"; }
yaml_cpu() { sed -n 's/^cpu: //p' "$1/colima/default/colima.yaml"; }

# 3a owned (marker) and small -> stopped and resized
b="$(new_box owned 4 2 30 'ostler-qdrant\nostler-oxigraph\n' 1)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if grep -q '^stop default' "$b/log" && [ "$(yaml_mem "$b")" = 6 ] && [ "$(yaml_cpu "$b")" = 3 ] && [ -f "$b/state/colima-vm-resize-pending" ]; then
    ok "arm 3a: Ostler's 4 GiB VM on a 16 GB Mac is stopped and set to 6 GiB / 3 CPUs, verify pending"
else bad "arm 3a: owned VM not resized: yaml mem=$(yaml_mem "$b") cpu=$(yaml_cpu "$b"); log: $(tr '\n' ';' < "$b/log")"; fi

# 3b a foreign container in the VM, no marker -> NEVER touched
b="$(new_box foreign 4 2 30 'ostler-qdrant\nmy-postgres\n' 0)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if ! grep -q '^stop' "$b/log" && [ "$(yaml_mem "$b")" = 4 ] && grep -q "NOT resizing" "$b/ylog" && grep -q "not Ostler's" "$b/ylog"; then
    ok "arm 3b: a VM that also holds a customer's container is not stopped, not edited, and the log says why"
else bad "arm 3b: a shared VM was touched: mem=$(yaml_mem "$b"); log: $(tr '\n' ';' < "$b/log")"; fi

# 3c customer-sized VM (colima defaults, disk 100), no marker -> not touched
b="$(new_box custsize 2 2 100 'ostler-qdrant\n' 0)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if ! grep -q '^stop' "$b/log" && [ "$(yaml_mem "$b")" = 2 ]; then
    ok "arm 3c: a VM with a disk size Ostler never sets is not touched"
else bad "arm 3c: a customer-sized VM was resized"; fi

# 3d legacy Ostler VM (no marker, 4/2/30, only ostler-* containers) -> adopted
b="$(new_box legacy 4 2 30 'ostler-qdrant\nostler-oxigraph\nostler-wiki-site\n' 0)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if [ "$(yaml_mem "$b")" = 6 ] && [ -f "$b/state/colima-vm-owner" ] && grep -q 'legacy VM adopted' "$b/ylog"; then
    ok "arm 3d: a pre-marker Ostler VM is adopted (marker written) and resized"
else bad "arm 3d: legacy VM not adopted: mem=$(yaml_mem "$b"); $(cat "$b/ylog")"; fi

# 3e empty VM, no marker -> not adopted (nothing says it is ours)
b="$(new_box empty 4 2 30 '' 0)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if [ "$(yaml_mem "$b")" = 4 ] && ! grep -q '^stop' "$b/log"; then ok "arm 3e: an empty 4/2/30 VM with no marker is not adopted"
else bad "arm 3e: an empty VM was adopted and resized"; fi

# 3f already big enough -> nothing
b="$(new_box big 8 4 30 'ostler-qdrant\n' 1)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
if ! grep -q '^stop' "$b/log" && [ "$(yaml_mem "$b")" = 8 ] && grep -q 'nothing to do' "$b/ylog"; then
    ok "arm 3f: an 8 GiB VM on a 16 GB Mac is left alone (never shrunk)"
else bad "arm 3f: a big-enough VM was touched"; fi

# 3g no default VM -> nothing
b="$(new_box novm 4 2 30 '' 1)"; YLOG="$b/ylog"; export YLOG; rm -f "$b/vm_exists"
in_box "$b" ostler_vm_upgrade_prepare ylog
if ! grep -q '^stop' "$b/log" && grep -q "no colima 'default' VM" "$b/ylog"; then ok "arm 3g: no default VM -> nothing to resize, logged"
else bad "arm 3g: no-VM case wrong: $(cat "$b/ylog")"; fi

# 3h verify, stores healthy -> rc 0, pending cleared
b="$(new_box vok 4 2 30 'ostler-qdrant\n' 1)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
STUB_CURL_MODE=ok in_box "$b" ostler_vm_upgrade_verify ylog gui/501/com.example.daemon; rc=$?
if [ "$rc" = 0 ] && [ ! -f "$b/state/colima-vm-resize-pending" ] && grep -q 'qdrant and oxigraph healthy' "$b/ylog"; then
    ok "arm 3h: verify sees both stores healthy at the new size -> rc 0"
else bad "arm 3h: verify rc=$rc; $(cat "$b/ylog")"; fi

# 3i verify, stores only come back at the OLD size -> reverted, rc 2, ERR code
b="$(new_box vrevert 4 2 30 'ostler-qdrant\n' 1)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
STUB_CURL_MODE=old-only in_box "$b" ostler_vm_upgrade_verify ylog gui/501/com.example.daemon; rc=$?
if [ "$rc" = 2 ] && [ "$(yaml_mem "$b")" = 4 ] && grep -q 'ERR-UPG-VM-RESIZE-STORES-UNHEALTHY' "$b/ylog" \
   && grep -q 'ERR-UPG-VM-RESIZE-REVERTED' "$b/ylog" && grep -q 'launchctl kickstart -k gui/501/com.example.daemon' "$b/log"; then
    ok "arm 3i: stores dead at the new size -> VM put back to 4 GiB, daemon kickstarted, rc 2, both ERR codes logged"
else bad "arm 3i: revert path rc=$rc mem=$(yaml_mem "$b"); $(cat "$b/ylog")"; fi

# 3j verify, stores dead at either size -> rc 1, STORES-DOWN
b="$(new_box vdown 4 2 30 'ostler-qdrant\n' 1)"; YLOG="$b/ylog"; export YLOG
in_box "$b" ostler_vm_upgrade_prepare ylog
STUB_CURL_MODE=down in_box "$b" ostler_vm_upgrade_verify ylog gui/501/com.example.daemon; rc=$?
if [ "$rc" = 1 ] && grep -q 'ERR-UPG-VM-RESIZE-STORES-DOWN' "$b/ylog"; then
    ok "arm 3j: stores dead even at the old size -> rc 1 with ERR-UPG-VM-RESIZE-STORES-DOWN (the caller fails the upgrade)"
else bad "arm 3j: rc=$rc; $(cat "$b/ylog")"; fi

# 3k verify with nothing pending -> rc 0, no probes
b="$(new_box vnone 4 2 30 '' 1)"; YLOG="$b/ylog"; export YLOG
STUB_CURL_MODE=down in_box "$b" ostler_vm_upgrade_verify ylog x; rc=$?
if [ "$rc" = 0 ] && ! grep -q '^curl' "$b/log"; then ok "arm 3k: verify with no resize pending does nothing (control: down stores not probed)"
else bad "arm 3k: verify acted with nothing pending (rc=$rc)"; fi

# ── arm 4: the upgrade block wires prepare and verify in order ───────
BS="$(grep -nE '^if \[\[ "\$\{OSTLER_UPGRADE_MODE:-0\}" == "1"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
BE="$(awk -v s="${BS:-0}" 'NR>=s && /^fi$/{print NR; exit}' "$INSTALL_SH")"
if [ -z "$BS" ] || [ -z "$BE" ]; then
    bad "arm 4 premise: upgrade block not found; the order checks would be vacuous"
else
    n_swap="$(awk -v s="$BS" -v e="$BE" 'NR>=s && NR<=e && /daemon swapped; previous kept at/ && /ostler_vm_upgrade_prepare _upg_log/ {print NR; exit}' "$INSTALL_SH")"
    BD="$(awk -v s="$BS" -v e="$BE" 'NR>=s && NR<=e && /^[[:space:]]*_upg_do_upgrade\(\) \{/ {print NR; exit}' "$INSTALL_SH")"
    n_boot="$(awk -v s="${BD:-$BS}" -v e="$BE" 'NR>=s && NR<=e && /launchctl bootout "\$\{_UPG_DOMAIN\}\/\$\{_UPG_ASSISTANT_LABEL\}"/ {print NR; exit}' "$INSTALL_SH")"
    n_rr="$(awk -v s="$BS" -v e="$BE" 'NR>=s && NR<=e && /^[[:space:]]*_upg_rerender_plists[[:space:]]*$/ {print NR; exit}' "$INSTALL_SH")"
    n_ver="$(awk -v s="$BS" -v e="$BE" 'NR>=s && NR<=e && /ostler_vm_upgrade_verify _upg_log/ && /_upg_die 26/ {print NR; exit}' "$INSTALL_SH")"
    if [ -n "$BD" ] && [ -n "$n_swap" ] && [ -n "$n_boot" ] && [ -n "$n_rr" ] && [ -n "$n_ver" ] \
       && [ "$n_boot" -lt "$n_swap" ] && [ "$n_swap" -lt "$n_rr" ] && [ "$n_rr" -lt "$n_ver" ]; then
        ok "arm 4: bootout :$n_boot < prepare :$n_swap < re-render :$n_rr < verify+die :$n_ver"
    else
        bad "arm 4: order wrong or missing (bootout=$n_boot prepare=$n_swap rerender=$n_rr verify=$n_ver)"
    fi
    grep -qF '_upg_payload_dir services/vm' "$INSTALL_SH" && ok "arm 4: upgrade reads the lib from the payload's services/vm" \
        || bad "arm 4: upgrade does not read services/vm from the payload"
fi

# ── arm 5: both artefacts carry the lib ──────────────────────────────
grep -qF 'cp "${SRCROOT}/../lib/ostler-vm-size.sh"' "$PROJECT_YML" && grep -qF -- '- $(SRCROOT)/../lib/ostler-vm-size.sh' "$PROJECT_YML" \
    && ok "arm 5: the DMG bundle phase copies lib/ostler-vm-size.sh and declares it" \
    || bad "arm 5: project.yml does not bundle lib/ostler-vm-size.sh (fresh installs would get the old 4 GiB)"
grep -qF 'cp "$$VM_SIZE_SRC" "$$PAYLOAD/services/vm"' "$MAKEFILE" \
    && grep -E '^[[:space:]]*for req in ' "$MAKEFILE" | grep -qF 'services/vm/ostler-vm-size.sh' \
    && ok "arm 5: stage-payload copies it to services/vm and its post-copy req loop requires it" \
    || bad "arm 5: the upgrade payload does not carry services/vm/ostler-vm-size.sh (upgrades would never resize)"

/bin/bash -n "$LIB" && ok "lib parses under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'))" || bad "lib does not parse under /bin/bash"

echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
