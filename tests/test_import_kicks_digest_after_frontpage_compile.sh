#!/usr/bin/env bash
#
# tests/test_import_kicks_digest_after_frontpage_compile.sh
#
# The owner digest (com.creativemachines.ostler.context-refresh) reads the
# interest profile that the editor-frontpage compile writes. Nothing ordered
# the two, so a digest could run before the profile existed and show no
# preferences until its next slot. The generated ostler-import (the IMPORTEOF
# heredoc extracted from install.sh) now kicks the digest only AFTER the
# compile it kicked has rewritten the profile (bounded).
#
# Launchd is faked: the stub launchctl appends every call to one log, and a
# kickstart of the front-page label runs a fake compile (in its own process
# group, as a launchd job is) that sleeps, rewrites
# the profile and then appends COMPILE-DONE to the SAME log. Order in that one
# file is the order of events. Synthetic data only; nothing touches the real
# session or HOME.
#
#   arm A  RED on main: the digest is kickstarted, and its kick line comes
#          AFTER COMPILE-DONE
#   arm B  bound: a compile that never writes the profile still gets its
#          digest once the (shortened) bound passes
#   arm C  front-page agent not loaded: no wait and no digest kick, and the
#          import returns promptly
#   arm D  the waiter survives its caller's process group being killed (what
#          launchd does when the job that ran ostler-import exits)
#   arm E  mutant: wait loop removed -> arm A's order check goes red
#   arm F  mutant: own process group removed -> arm D goes red
#
# Runs under bash 3.2.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
FRONTPAGE_LABEL="com.creativemachines.ostler.editor-frontpage"
DIGEST_LABEL="com.creativemachines.ostler.context-refresh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }

echo "test_import_kicks_digest_after_frontpage_compile"
[ -f "$INSTALL_SH" ] || cannot "install.sh is missing"
command -v cksum >/dev/null 2>&1 || cannot "cksum is missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/cat > "\$IMPORT_SCRIPT" <<.IMPORTEOF./{f=1;next} f&&/^IMPORTEOF$/{exit} f{print}' "$INSTALL_SH" > "$WORK/ostler-import.orig"
/usr/bin/grep -q 'services.enrich.src.cli enrich' "$WORK/ostler-import.orig" || cannot "could not extract ostler-import from install.sh"

# $1 = arm name, $2 = "write" | "nowrite" (does the fake compile write the
# profile), $3 = "loaded" | "absent" (is the front-page agent loaded)
build_box() {
    BOX="$WORK/box.$1"; H="$BOX/home"; OD="$H/.ostler"; STUB="$BOX/stub"; CALLS="$BOX/launchctl.log"
    PROFILE="$OD/preferences/interest_profile.json"
    mkdir -p "$OD/preferences" "$OD/state" "$OD/config" "$OD/services/cm019/.venv/bin" "$STUB" "$BOX/exports/synthetic"
    : > "$BOX/exports/synthetic/placeholder.json"
    : > "$CALLS"
    printf '{"schema_version":1,"generated_at":"0","interests":[]}\n' > "$PROFILE"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$OD/services/cm019/.venv/bin/python"
    chmod +x "$OD/services/cm019/.venv/bin/python"
    printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n' > "$OD/config/.env"
    if [ "$2" = "write" ]; then
        _compile='sleep 3; printf "{\"schema_version\":1,\"generated_at\":\"1\",\"interests\":[{\"subject\":\"Sea kayaking\"}]}\n" > "'"$PROFILE"'"; echo COMPILE-DONE >> "'"$CALLS"'"'
    else
        _compile='sleep 1; echo COMPILE-FAILED >> "'"$CALLS"'"'
    fi
    if [ "$3" = "loaded" ]; then _print='exit 0'; else _print='case "$*" in *'"$FRONTPAGE_LABEL"'*) exit 113 ;; esac; exit 0'; fi
    cat > "$STUB/launchctl" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1" in
    print) $_print ;;
    kickstart)
        case "\$*" in
            *${FRONTPAGE_LABEL}*) ( set -m; ( $_compile ) </dev/null >/dev/null 2>&1 & ) ;;
        esac
        exit 0 ;;
esac
exit 0
STUBEOF
    chmod +x "$STUB/launchctl"
}

run_import() {  # $1 = ostler-import file; extra env via the caller
    cp "$1" "$BOX/ostler-import"; chmod +x "$BOX/ostler-import"
    HOME="$H" PATH="$STUB:$PATH" "$BOX/ostler-import" "$BOX/exports" --user-name "Jane Doe" --user-id jane >"$BOX/import.log" 2>&1
}

wait_digest() {  # up to $1 seconds for a digest kick line
    local i=0
    while [ "$i" -lt "$(( $1 * 2 ))" ]; do
        /usr/bin/grep -q "kickstart .*${DIGEST_LABEL}" "$CALLS" && return 0
        sleep 0.5; i=$((i+1))
    done
    return 1
}

line_of() { /usr/bin/grep -n "$1" "$CALLS" | head -1 | cut -d: -f1; }

# order check: digest kicked, and after COMPILE-DONE
check_order() {  # $1 = label for messages; returns 0 on correct order
    wait_digest 20 || { echo "no digest kick"; return 1; }
    sleep 1
    local d c; d="$(line_of "kickstart .*${DIGEST_LABEL}")"; c="$(line_of COMPILE-DONE)"
    [ -n "$c" ] || { echo "digest kicked at line $d with no COMPILE-DONE before it"; return 1; }
    [ "$d" -gt "$c" ] || { echo "digest kicked at line $d, BEFORE COMPILE-DONE at line $c"; return 1; }
    echo "digest kick line $d after COMPILE-DONE line $c"; return 0
}

# ---- arm A: the import kicks the digest after the compile finishes ---------
build_box A write loaded
run_import "$WORK/ostler-import.orig"
if msg="$(check_order)"; then ok "A: ${msg}"; else bad "A: ${msg}"; fi

# ---- arm B: bound, a compile that never writes still gets its digest -------
build_box B nowrite loaded
OSTLER_DIGEST_AFTER_COMPILE_WAIT=4 run_import "$WORK/ostler-import.orig"
if wait_digest 20; then ok "B: compile wrote nothing; digest still kicked after the bound"; else bad "B: compile wrote nothing and the digest was never kicked (the wait is unbounded)"; fi

# ---- arm C: front-page agent absent -> no wait, no digest kick ------------
build_box C write absent
t0="$(date +%s)"; run_import "$WORK/ostler-import.orig"; t1="$(date +%s)"
sleep 6
if /usr/bin/grep -q "kickstart .*${DIGEST_LABEL}" "$CALLS"; then
    bad "C: the front-page agent is not loaded but the import still kicked the digest"
elif [ $((t1 - t0)) -gt 20 ]; then
    bad "C: the import took $((t1 - t0))s with the front-page agent absent"
else
    ok "C: front-page agent absent: no digest kick, import returned in $((t1 - t0))s"
fi

# ---- arm D: the waiter survives its caller's process group being killed ---
# Run the import as its own job (set -m), then SIGKILL that whole process
# group the moment it returns: launchd does this to a job's group when the
# job that ran ostler-import exits.
arm_d() {  # $1 = ostler-import file; prints the verdict line
    build_box "D.$2" write loaded
    cp "$1" "$BOX/ostler-import"; chmod +x "$BOX/ostler-import"
    (
        set -m
        HOME="$H" PATH="$STUB:$PATH" "$BOX/ostler-import" "$BOX/exports" --user-name "Jane Doe" --user-id jane >"$BOX/import.log" 2>&1 &
        _pg=$!
        wait "$_pg"
        kill -KILL -- "-$_pg" 2>/dev/null || true
    )
    check_order
}
if msg="$(arm_d "$WORK/ostler-import.orig" orig)"; then ok "D: caller's process group killed on exit; ${msg}"; else bad "D: caller's process group killed on exit: ${msg}"; fi

# ---- arm E: mutant, the wait loop removed ---------------------------------
sed -e 's/while \[ "\$_w" -lt [^;]*; do sleep 2; _w=\$((_w+2)); done; sleep 2; //' "$WORK/ostler-import.orig" > "$WORK/ostler-import.nowait"
if cmp -s "$WORK/ostler-import.orig" "$WORK/ostler-import.nowait"; then
    bad "E: mutant did not apply (no wait loop found)"
else
    build_box E write loaded
    run_import "$WORK/ostler-import.nowait"
    if msg="$(check_order)"; then bad "E: mutant (no wait) still passed the order check: ${msg}"; else ok "E: mutant (no wait) goes red: ${msg}"; fi
fi

# ---- arm F: mutant, own process group removed -----------------------------
sed -e 's/( set -m; (/( (/' "$WORK/ostler-import.orig" > "$WORK/ostler-import.nopg"
if cmp -s "$WORK/ostler-import.orig" "$WORK/ostler-import.nopg"; then
    bad "F: mutant did not apply (no set -m found)"
else
    if msg="$(arm_d "$WORK/ostler-import.nopg" nopg)"; then bad "F: mutant (no own process group) survived the group kill: ${msg}"; else ok "F: mutant (no own process group) goes red: ${msg}"; fi
fi

echo "  $pass passed, $fail failed (6 arms, real generated ostler-import, fake launchd)"
[ "$fail" -eq 0 ]
