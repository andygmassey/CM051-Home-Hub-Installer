#!/usr/bin/env bash
#
# The dev wipe's verdict must mean what a reader assumes it means.
#
# It did not. `scripts/dev-wipe-studio.sh` ended in four bare
#     ls PATH 2>&1 | head -1
# lines under `set -euo pipefail`. On a SUCCESSFUL wipe the first `ls` exits
# 1, pipefail propagates it and errexit aborts the script, so:
#
#     a clean wipe    -> printed 1 of its 4 checks, exited 1
#     a wipe that removed NOTHING -> printed 4 of 4, exited 0
#
# The green meant failure and the red meant success. Both arms measured.
#
# This test drives the REAL `dev_wipe_verify` by sourcing the script, rather
# than re-implementing its logic. A test that re-implements the thing it
# guards is asserting on a copy that cannot drift with the original.
#
# Nothing here is destructive: only `dev_wipe_verify` is called, never
# `dev_wipe_main`, and every root it inspects is redirected into a sandbox.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/dev-wipe-studio.sh"

pass=0; fail=0
OUT=""; RC=0
ok()  { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$SCRIPT" ] || { echo "[CANNOT-RUN] no ${SCRIPT}"; exit 78; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# A docker stub, so "no volumes" and "docker is not running" stay distinct.
mk_docker() {   # $1 = mode: empty | volumes | fail
    local d="$SB/bin-$1"; mkdir -p "$d"
    cat > "$d/docker" <<STUB
#!/bin/bash
case "\$1" in
  volume)
    case "$1" in
      empty)   exit 0 ;;
      volumes) printf 'ostler_qdrant_data\nostler_wiki-docs\nsomething_else\n'; exit 0 ;;
      fail)    echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$d/docker"; printf '%s' "$d/docker"
}

# Run the real verifier against a sandbox HOME. Echoes rc, leaves output in $OUT.
#
# 🔴 THE SCRIPT UNDER TEST IS DESTRUCTIVE, so how it is sourced is load-bearing.
# The source guard is `[ "${BASH_SOURCE[0]}" != "${0}" ]`. Passing the script
# as $0 -- `bash -c 'source "$0"' "$SCRIPT"` -- makes those two EQUAL, so the
# guard reads "executed", and `dev_wipe_main` runs for real. Writing it that
# way during development ran the wipe against this machine; only the sandboxed
# root resolvers kept it harmless, and `>/dev/null 2>&1 || true` on the source
# line hid the whole thing.
#
# So: $0 is a throwaway, the script arrives as $1, and NOTHING is suppressed.
run_verify() {   # $1 = sandbox home, $2 = docker stub path. Sets $OUT and $RC.
    OUT="$(
        HOME="$1" \
        DEV_WIPE_APPS_DIR="$1/Applications" \
        DEV_WIPE_BIN_DIR="$1/usr-local-bin" \
        DEV_WIPE_DOCKER="$2" \
        bash -c 'source "$1"; dev_wipe_verify' _ "$SCRIPT" 2>&1
    )"
    RC=$?
}

clean_home() {  # a box where the wipe fully succeeded
    local h="$SB/$1"; rm -rf "$h"
    mkdir -p "$h/Library/LaunchAgents" "$h/Applications" "$h/usr-local-bin" "$h/Library/Application Support"
    printf '%s' "$h"
}

echo "=== 1. THE ARM THE OLD SCRIPT GOT BACKWARDS ==="
H="$(clean_home clean)"; D="$(mk_docker empty)"
run_verify "$H" "$D"
if [ "$RC" = "0" ]; then
    ok "a fully wiped box verifies CLEAN and exits 0"
else
    bad "a fully wiped box exited ${RC}, not 0 -- the verdict is inverted again"
    printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# The old block stopped after its first check. Count them.
n_reports="$(printf '%s\n' "$OUT" | /usr/bin/grep -cE '^  (gone|RESIDUE|CANNOT) ' || true)"
if [ "$n_reports" -ge 9 ]; then
    ok "all ${n_reports} checks ran on a clean box (the old block stopped after 1)"
else
    bad "only ${n_reports} check(s) ran; errexit is aborting the block again"
fi

echo
echo "=== 2. RESIDUE MUST BE RED, AND MUST BE NAMED ==="
H="$(clean_home res1)"; mkdir -p "$H/.ostler/bin"
run_verify "$H" "$D"
case "${RC}|$(printf '%s' "$OUT" | /usr/bin/grep -c 'RESIDUE.*\.ostler')" in
    "1|"[1-9]*) ok "a surviving ~/.ostler is RESIDUE, exit 1, and is named" ;;
    *) bad "a surviving ~/.ostler gave rc=${RC} and did not name itself" ;;
esac

H="$(clean_home res2)"; : > "$H/Library/LaunchAgents/ai.ostler.assistant.plist"
run_verify "$H" "$D"
if [ "$RC" = "1" ]; then
    ok "a surviving LaunchAgent plist is RESIDUE, exit 1"
else
    bad "a surviving LaunchAgent plist gave rc=${RC}"
fi

echo
echo "=== 3. THE STORES -- the defect that put this file here ==="
H="$(clean_home stores)"; DV="$(mk_docker volumes)"
run_verify "$H" "$DV"
n_vols="$(printf '%s' "$OUT" | /usr/bin/grep -c 'qdrant_data\|wiki-docs' || true)"
if [ "$RC" = "1" ] && [ "$n_vols" -ge 1 ]; then
    ok "surviving data store volumes are RESIDUE, exit 1, and are listed"
else
    bad "surviving store volumes gave rc=${RC} with ${n_vols} named -- a wiped box was claimed"
fi

echo
echo "=== 4. CANNOT-VERIFY IS A THIRD STATE AND IS NEVER A PASS ==="
H="$(clean_home nodocker)"
run_verify "$H" "$SB/definitely-not-a-real-docker"
if [ "$RC" = "78" ]; then
    ok "docker absent is CANNOT-VERIFY (78), not a clean box"
elif [ "$RC" = "0" ]; then
    bad "docker absent reported CLEAN -- 'could not look' is being read as 'found nothing'"
else
    bad "docker absent gave rc=${RC}, expected 78"
fi

H="$(clean_home dockerfail)"; DF="$(mk_docker fail)"
run_verify "$H" "$DF"
if [ "$RC" = "78" ]; then
    ok "a failing docker is CANNOT-VERIFY (78), not a clean box"
else
    bad "a failing docker gave rc=${RC}, expected 78"
fi

echo
echo "=== 5. RESIDUE OUTRANKS CANNOT-VERIFY ==="
# A found defect must not be buried by an unmeasurable neighbour.
H="$(clean_home both)"; mkdir -p "$H/.ostler"
run_verify "$H" "$SB/definitely-not-a-real-docker"
if [ "$RC" = "1" ]; then
    ok "residue plus an unverifiable check reports RESIDUE (1), not 78"
else
    bad "residue was buried under CANNOT-VERIFY: rc=${RC}, expected 1"
fi

echo
echo "=== 6. THE REMOVAL LIST IS NOT MAINTAINED HERE ==="
if [ "$(/usr/bin/grep -c 'ostler-uninstall' "$SCRIPT")" -ge 1 ]; then
    ok "the wipe delegates to the shipped uninstaller"
else
    bad "the wipe carries its own removal list again; the shipped uninstaller is unused"
fi
if [ "$(/usr/bin/grep -c 'docker volume rm' "$SCRIPT")" -eq 0 ]; then
    ok "stores are removed via 'docker compose down -v', not a by-name volume list"
else
    bad "a hand-maintained 'docker volume rm' list has reappeared"
fi

echo
echo "=== 7. ORDER: the compose file must outlive the compose call ==="
# ~/.ostler holds docker-compose.yml. Removing it first destroys the only
# supported route to the volumes. The old script did exactly that.
# 🔴 Strip comments BEFORE numbering. Writing it the other way round --
# `grep -n ... | grep -v '^ *#'` -- filters NOTHING, because grep -n has
# already put a line number in front of the '#'. This file's own header
# quotes "docker compose down -v" in prose, so the arm matched that comment,
# compared it against the real rm, and passed no matter what the order was.
# A mutant that moved the rm to the top survived it.
code_lines() {  # $1 = pattern. Prints line numbers of NON-comment matches.
    awk -v pat="$1" '{ line=$0; sub(/^[ \t]+/, "", line)
                       if (line !~ /^#/ && index($0, pat)) print NR }' "$SCRIPT"
}
# Match the INVOCATION, not the echo that announces it. An echo is a label;
# deleting the call while keeping the message must not read as compliance.
l_compose="$(code_lines '&& docker compose down -v' | head -1)"
l_rm="$(code_lines 'rm -rf "$OSTLER_DIR"' | head -1)"
if [ -z "$l_compose" ] && [ -n "$l_rm" ]; then
    # Not unmeasurable -- measured, and the answer is that the only supported
    # route to the store volumes is gone while the rm that strands them stays.
    bad "the 'docker compose down -v' call is absent; nothing removes the data stores"
elif [ -z "$l_compose" ] || [ -z "$l_rm" ]; then
    echo "[CANNOT-RUN] could not locate either line (compose='${l_compose}' rm='${l_rm}')"
    fail=$((fail + 1))
elif [ "$l_compose" -lt "$l_rm" ]; then
    ok "docker compose down -v (line ${l_compose}) runs before rm -rf ~/.ostler (line ${l_rm})"
else
    bad "rm -rf ~/.ostler (line ${l_rm}) runs BEFORE the compose call (line ${l_compose}); the stores become unreachable"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
