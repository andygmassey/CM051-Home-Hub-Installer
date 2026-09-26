#!/usr/bin/env bash
#
# tests/test_ostler_home_is_owner_only_on_every_path.sh
#
# ~/.ostler must be 0700 on EVERY install path, verified, never assumed.
# (v1.0.103 security pass, from the Muse comparison.)
#
# The defect: the only chmod of ~/.ostler lived inside
# _ostler_promote_prelaunch_tree, which returns early when there is no staging
# tree (every re-install), and was written `2>/dev/null || true`, so a mode
# that did not stick read exactly like one that did. Sparkle upgrades never ran
# it at all. So a Mac first installed by an older build kept a 0755 ~/.ostler
# forever, and any other account on the Mac could list the tree that holds the
# secrets and the databases.
#
# The upgrade path is proven BEHAVIOURALLY in tests/test_upgrade_mode_invariants.sh
# (scenario A starts from 0755 and asserts 0700 after). This file proves:
#   1. the helper itself: 0755 -> 0700 with rc 0, a missing dir is left alone,
#      an empty argument is refused;
#   2. it is CALLED at the start of every install over an existing tree, inside
#      the promote, and in upgrade mode before any swap;
#   3. the old unverified `chmod 700 "$OSTLER_FINAL_DIR" 2>/dev/null || true`
#      is gone.
#
# macOS only: modes are read with BSD `stat -f '%Lp'`.
# Exit: 0 all pass, 1 any FAIL, 2 CANNOT-RUN.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO_ROOT}/install.sh}"

pass=0; fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: ${INSTALL_SH} not readable"; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "CANNOT-RUN: needs macOS (BSD stat)"; exit 2; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ── 1. the helper ────────────────────────────────────────────────────────
FN="$(sed -n '/^_ostler_lock_home_dir() {/,/^}/p' "$INSTALL_SH")"
if [ -z "$FN" ]; then
    bad "_ostler_lock_home_dir is not defined in install.sh"
else
    eval "$FN"
    mkdir -p "${WORK}/h1/.ostler"; chmod 755 "${WORK}/h1/.ostler"
    if _ostler_lock_home_dir "${WORK}/h1/.ostler"; then rc=0; else rc=$?; fi
    m="$(/usr/bin/stat -f '%Lp' "${WORK}/h1/.ostler")"
    [ "$rc" = 0 ] && [ "$m" = 700 ] \
        && ok "a 0755 ~/.ostler becomes 0700 and the helper returns 0" \
        || bad "0755 ~/.ostler: rc=${rc} mode=${m} (want rc 0, mode 700)"
    if _ostler_lock_home_dir "${WORK}/absent/.ostler"; then rc=0; else rc=$?; fi
    [ "$rc" = 0 ] && [ ! -e "${WORK}/absent/.ostler" ] \
        && ok "a missing ~/.ostler is left alone (the promote creates and locks it)" \
        || bad "missing ~/.ostler: rc=${rc}, or it was created"
    if _ostler_lock_home_dir ""; then rc=0; else rc=$?; fi
    [ "$rc" != 0 ] && ok "an empty path is refused, not treated as done" \
        || bad "an empty path returned 0"
    # The verify must be real: a helper whose stat reads a DIFFERENT mode must fail.
    MUT="$(printf '%s\n' "$FN" | sed "s|/usr/bin/stat -f '%Lp' \"\${_d}\"|echo 755|")"
    if [ "$MUT" = "$FN" ]; then
        bad "CONTROL could not be built: the helper no longer reads its mode with /usr/bin/stat -f '%Lp' \"\${_d}\""
    elif ! ( eval "$MUT" ) 2>/dev/null; then
        bad "CONTROL could not be built: the mutated helper does not parse"
    else ( eval "$MUT"; mkdir -p "${WORK}/h2/.ostler"; _ostler_lock_home_dir "${WORK}/h2/.ostler" ) \
        && bad "CONTROL: a helper whose readback says 755 still returned 0 (the verify is decorative)" \
        || ok "CONTROL: a readback that is not 700 makes the helper fail (the verify is load-bearing)"
    fi
fi

# ── 2. every path calls it ───────────────────────────────────────────────
# (a) install over an existing tree, right after the pre-existence probe
n="$(/usr/bin/grep -n '^\[\[ -d "\$OSTLER_FINAL_DIR" \]\] && _OSTLER_FINAL_PREEXISTED=true$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [ -n "$n" ] && sed -n "$((n+1)),$((n+4))p" "$INSTALL_SH" | /usr/bin/grep -q '^_ostler_lock_home_dir "\$OSTLER_FINAL_DIR"'; then
    ok "install over an existing tree locks ~/.ostler before anything else touches it"
else
    bad "no _ostler_lock_home_dir call right after the _OSTLER_FINAL_PREEXISTED probe"
fi
# (b) inside the promote
PROMOTE="$(sed -n '/^_ostler_promote_prelaunch_tree() {/,/^}/p' "$INSTALL_SH")"
printf '%s\n' "$PROMOTE" | /usr/bin/grep -q '_ostler_lock_home_dir "\$OSTLER_FINAL_DIR"' \
    && ok "the promote locks ~/.ostler through the verified helper" \
    || bad "the promote does not call _ostler_lock_home_dir"
# (c) upgrade mode, before the daemon is staged
UPG="$(sed -n '/^    _upg_do_upgrade() {/,/^    }/p' "$INSTALL_SH")"
lock_ln="$(printf '%s\n' "$UPG" | /usr/bin/grep -n '_ostler_lock_home_dir "\$_UPG_OSTLER_DIR"' | head -1 | cut -d: -f1)"
stage_ln="$(printf '%s\n' "$UPG" | /usr/bin/grep -n '^        _upg_stage_daemon$' | head -1 | cut -d: -f1)"
[ -n "$lock_ln" ] && [ -n "$stage_ln" ] && [ "$lock_ln" -lt "$stage_ln" ] \
    && ok "upgrade mode locks ~/.ostler before staging or swapping anything" \
    || bad "upgrade mode: lock line ${lock_ln:-absent}, stage line ${stage_ln:-absent}"

# ── 3. the unverified form is gone ───────────────────────────────────────
if /usr/bin/grep -nE 'chmod 700 "\$OSTLER_FINAL_DIR" 2>/dev/null \|\| true' "$INSTALL_SH" >/dev/null; then
    bad "an unverified 'chmod 700 \"\$OSTLER_FINAL_DIR\" 2>/dev/null || true' is still in install.sh"
else
    ok "no unverified chmod of ~/.ostler remains"
fi

echo "RESULT: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
