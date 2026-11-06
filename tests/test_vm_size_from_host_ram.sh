#!/usr/bin/env bash
# tests/test_vm_size_from_host_ram.sh
#
# The container VM is sized from host RAM at install (v1.0.126 a1).
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
#   arm 4  the upgrade block does NOT touch colima (Archie, 126); the resize
#          on upgrade is post-launch/vm-resize-on-upgrade.
#   arm 5  the lib reaches the DMG bundle (project.yml).
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

# ── arm 4: the upgrade path does NOT touch colima in this build ──────
# Archie, 126: an upgrade never touches colima (Hub upgrade_reconcile.rs
# invariant 4). The resize lives on post-launch/vm-resize-on-upgrade.
BS="$(grep -nE '^if \[\[ "\$\{OSTLER_UPGRADE_MODE:-0\}" == "1"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
BE="$(awk -v s="${BS:-0}" 'NR>=s && /^fi$/{print NR; exit}' "$INSTALL_SH")"
if [ -z "$BS" ] || [ -z "$BE" ]; then
    bad "arm 4 premise: upgrade block not found"
else
    n="$(sed -n "${BS},${BE}p" "$INSTALL_SH" | grep -v '^[[:space:]]*#' | grep -cE 'colima|ostler-vm-size|ostler_vm_' || true)"
    ctl="$(grep -v '^[[:space:]]*#' "$INSTALL_SH" | grep -cE 'ostler_vm_' || true)"
    if [ "${n:-1}" = 0 ] && [ "${ctl:-0}" -gt 0 ]; then ok "arm 4: the upgrade block has 0 colima / VM-size lines (control: ${ctl} ostler_vm_ lines elsewhere in install.sh)"
    else bad "arm 4: upgrade block touches colima or the VM lib (${n} lines; control ${ctl})"; fi
fi

# ── arm 5: both artefacts carry the lib ──────────────────────────────
grep -qF 'cp "${SRCROOT}/../lib/ostler-vm-size.sh"' "$PROJECT_YML" && grep -qF -- '- $(SRCROOT)/../lib/ostler-vm-size.sh' "$PROJECT_YML" \
    && ok "arm 5: the DMG bundle phase copies lib/ostler-vm-size.sh and declares it" \
    || bad "arm 5: project.yml does not bundle lib/ostler-vm-size.sh (fresh installs would get the old 4 GiB)"
# ── arm 6: container memory limits (125 box: 9 OOM kills incl. OXIGRAPH) ──
# The compiler and wiki-site get a cgroup memory limit sized from the same
# table, so a runaway compile is killed INSIDE its own cgroup and never reaches
# the global OOM killer; the stores get a negative oom_score_adj so that, if a
# global OOM still happens, the kernel picks the wiki first.
CMP="$TMP/compose.yml"
awk '/^cat > "\$\{OSTLER_DIR\}\/docker-compose.yml" <<.DCEOF.$/{f=1; next} /^DCEOF$/{f=0} f' "$INSTALL_SH" > "$CMP"
svc() { awk -v s="  $1:" '$0==s{f=1; next} f && /^  [a-z][a-z0-9-]*:$/{exit} f' "$CMP"; }
if [ ! -s "$CMP" ] || ! svc oxigraph | grep -q 'container_name: ostler-oxigraph'; then
    bad "arm 6 premise: could not extract the compose heredoc and its oxigraph service"
else
    svc wiki-compiler | grep -qE '^    mem_limit: "\$\{OSTLER_WIKI_COMPILER_MEM_LIMIT:-1536m\}"( +#.*)?$' \
        && svc wiki-compiler | grep -qE '^    oom_score_adj: [1-9][0-9]*( +#.*)?$' \
        && ok "arm 6: wiki-compiler has a sized mem_limit (floor 1536m) and a positive oom_score_adj" \
        || bad "arm 6: wiki-compiler has no sized mem_limit / positive oom_score_adj: a compile can still take a store down"
    svc wiki-site | grep -qE '^    mem_limit: "\$\{OSTLER_WIKI_SITE_MEM_LIMIT:-1024m\}"( +#.*)?$' \
        && svc wiki-site | grep -qE '^    oom_score_adj: [1-9][0-9]*( +#.*)?$' \
        && ok "arm 6: wiki-site (mkdocs, killed once on 125) has a sized mem_limit and a positive oom_score_adj" \
        || bad "arm 6: wiki-site has no sized mem_limit / positive oom_score_adj"
    for st in qdrant oxigraph redis; do
        svc "$st" | grep -qE '^    oom_score_adj: -[1-9][0-9]*( +#.*)?$' && ! svc "$st" | grep -q 'mem_limit' \
            && ok "arm 6: store $st keeps priority: negative oom_score_adj, no memory cap" \
            || bad "arm 6: store $st has no negative oom_score_adj (or was capped)"
    done
    # The call sits on the line BEFORE the heredoc, never on the heredoc line
    # itself (editor-feed-gate and install-sh-behaviour parse that line).
    awk '/^cat > "\$\{OSTLER_DIR\}\/docker-compose.yml" <<.DCEOF.$/{print prev; found=1} {prev=$0} END{exit found?0:1}' "$INSTALL_SH" \
        | grep -qE '^if \[\[ -f .*ostler_vm_write_container_limits "\$\{OSTLER_DIR\}/\.env".*; fi$' \
        && ok "arm 6: install.sh writes the limits into the compose .env on the line before the bare compose heredoc" \
        || bad "arm 6: the limits are not written on the line before a bare compose heredoc line"
    E="$TMP/env6"; printf 'JWT_SECRET=x\nOSTLER_WIKI_COMPILER_MEM_LIMIT=9m\n' > "$E"; chmod 600 "$E"
    got="$( . "$LIB"; OSTLER_VM_HOST_RAM_BYTES=$((16 * GIB)) OSTLER_VM_HOST_NCPU=8; export OSTLER_VM_HOST_RAM_BYTES OSTLER_VM_HOST_NCPU
            ostler_vm_write_container_limits "$E" >/dev/null 2>&1; echo "rc=$?" )"
    if [ "$got" = "rc=0" ] && grep -qx 'OSTLER_WIKI_COMPILER_MEM_LIMIT=2048m' "$E" && grep -qx 'OSTLER_WIKI_SITE_MEM_LIMIT=1024m' "$E" \
       && grep -qx 'JWT_SECRET=x' "$E" && [ "$(grep -c '^OSTLER_WIKI_COMPILER_MEM_LIMIT=' "$E")" = 1 ] \
       && [ "$(stat -f '%Lp' "$E" 2>/dev/null || stat -c '%a' "$E")" = 600 ]; then
        ok "arm 6: 16 GB host (6 GiB VM) -> compiler 2048m, site 1024m in .env; stale value replaced, other keys and mode 600 kept"
    else bad "arm 6: .env limits wrong ($got): $(tr '\n' ';' < "$E")"; fi
    # A .env that cannot be READ must be left alone: grep exit 2 is not
    # "no other keys", and treating it so replaced the whole compose .env
    # (JWT_SECRET, USER_FIRST_NAME, ...) with two lines (Archie, #3364).
    E2="$TMP/env6b"; printf 'JWT_SECRET=keepme\nOSTLER_LANG=en-GB\n' > "$E2"; chmod 000 "$E2"
    line="$( . "$LIB"; OSTLER_VM_HOST_RAM_BYTES=$((16 * GIB)); export OSTLER_VM_HOST_RAM_BYTES
             ostler_vm_write_container_limits "$E2" >/dev/null 2>&1; echo "rc=$? $OSTLER_VM_LIMITS_LINE" )"
    chmod 600 "$E2"
    if [ "$(id -u)" = 0 ]; then
        echo "  note CANNOT-RUN: running as root, chmod 000 does not make the .env unreadable"
    elif [ "$(cat "$E2")" = "$(printf 'JWT_SECRET=keepme\nOSTLER_LANG=en-GB')" ] && case "$line" in "rc=0 "*"COULD NOT READ"*) true ;; *) false ;; esac; then
        ok "arm 6: an unreadable .env is left byte-identical (rc 0, the log line says it could not be read)"
    else bad "arm 6: an unreadable .env was rewritten or the refusal was not logged: [$line] now: $(tr '\n' ';' < "$E2")"; fi
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        printf 'OSTLER_WIKI_COMPILER_MEM_LIMIT=2048m\nOSTLER_WIKI_SITE_MEM_LIMIT=1024m\n' > "$TMP/.env"
        cfg="$(cd "$TMP" && docker compose -f "$CMP" --profile compile config 2>&1)"  # read-only; real HOME so the CLI finds its compose plugin
        if grep -q 'mem_limit: "2147483648"' <<< "$cfg" && grep -q 'oom_score_adj: -500' <<< "$cfg"; then
            ok "arm 6: docker compose config accepts the file and resolves the compiler limit to 2 GiB"
        else bad "arm 6: docker compose config: $(grep -iE 'error|mem_limit|oom' <<< "$cfg" | head -3 | tr '\n' ';')"; fi
    else
        echo "  note CANNOT-RUN: no docker compose CLI here, so compose config was not validated (counted neither pass nor fail)"
    fi
fi

/bin/bash -n "$LIB" && ok "lib parses under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'))" || bad "lib does not parse under /bin/bash"

echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
