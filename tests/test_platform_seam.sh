#!/usr/bin/env bash
# test_platform_seam.sh
#
# Guards the installer platform seam (platform/macos.sh + the sourcing
# block in install.sh). The seam is groundwork for a FUTURE, separately
# authorised port -- Ostler v1 is single-machine, Mac-only (locked
# directive 2026-05-09) -- so this test asserts three things:
#
#   1. install.sh sources the module with the strings-catalogue
#      availability contract (SCRIPT_DIR sibling, env override,
#      hard-fail on missing = packaging bug).
#   2. platform/macos.sh is syntactically clean, side-effect-free to
#      source under `set -u`, and defines the COMPLETE documented
#      function inventory (platform/PORTING.md section 2). A function
#      silently dropped or renamed would otherwise only surface as a
#      mid-install unbound-function death on a customer Mac.
#   3. No second platform implementation has appeared in platform/ --
#      adding one requires Andy amending the locked directive first.
#
# Static + pure checks only: nothing here talks to launchctl, pmset,
# codesign or System Settings, so the test runs identically on macOS
# and Linux CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
MODULE="${REPO_ROOT}/platform/macos.sh"

fail_test() {
    echo "FAIL: $*" >&2
    exit 1
}

# ── 1. Files exist and parse ───────────────────────────────────────

[[ -f "$INSTALL_SH" ]] || fail_test "install.sh not found at $INSTALL_SH"
[[ -f "$MODULE" ]] || fail_test "platform module not found at $MODULE"

bash -n "$INSTALL_SH" || fail_test "install.sh has a syntax error"
bash -n "$MODULE" || fail_test "platform/macos.sh has a syntax error"
echo "PASS: install.sh + platform/macos.sh parse clean"

# ── 2. install.sh sources the module with the hard-fail contract ───

grep -q 'OSTLER_PLATFORM_MODULE' "$INSTALL_SH" \
    || fail_test "install.sh lost the OSTLER_PLATFORM_MODULE env override"
grep -q '\${SCRIPT_DIR}/platform/macos.sh' "$INSTALL_SH" \
    || fail_test "install.sh does not resolve \${SCRIPT_DIR}/platform/macos.sh"
grep -q 'platform module not found' "$INSTALL_SH" \
    || fail_test "install.sh lost the hard-fail (missing module must be a loud packaging bug, not a silent degrade)"
echo "PASS: sourcing block present with env override + hard-fail"

# ── 3. Sourcing is side-effect-free under set -u ───────────────────

SOURCE_OUTPUT="$(bash -c "set -u; source '$MODULE'" 2>&1)" \
    || fail_test "sourcing platform/macos.sh failed under set -u: $SOURCE_OUTPUT"
[[ -z "$SOURCE_OUTPUT" ]] \
    || fail_test "sourcing platform/macos.sh printed output (must be silent): $SOURCE_OUTPUT"
echo "PASS: module sources silently under set -u"

# ── 4. The documented function inventory is complete ───────────────
#
# KEEP IN LOCKSTEP with platform/PORTING.md section 2. A future port
# implements exactly this list; drift here is drift in the port
# contract.

REQUIRED_FUNCTIONS=(
    platform_service_dir
    platform_service_load
    platform_service_load_check
    platform_service_bootstrap
    platform_service_bootstrap_check
    platform_service_unload
    platform_service_unload_fallback
    platform_service_restart
    platform_has_full_disk_access
    platform_open_fda_pane
    platform_open_automation_pane
    platform_open_internet_accounts_pane
    platform_has_battery
    platform_power_source
    platform_ram_gb
    platform_app_signature_info
    platform_verify_app_signature
    platform_engine_dir
    platform_visible_dir
)

for fn in "${REQUIRED_FUNCTIONS[@]}"; do
    bash -c "set -u; source '$MODULE'; declare -F '$fn' >/dev/null" \
        || fail_test "platform/macos.sh does not define $fn (PORTING.md section 2 inventory)"
done
echo "PASS: all ${#REQUIRED_FUNCTIONS[@]} inventory functions defined"

# ── 5. Pure-function spot checks (no OS mutation, safe on Linux) ───

got="$(bash -c "set -u; source '$MODULE'; platform_service_dir")"
[[ "$got" == "${HOME}/Library/LaunchAgents" ]] \
    || fail_test "platform_service_dir returned '$got' (expected \${HOME}/Library/LaunchAgents)"

got="$(bash -c "set -u; source '$MODULE'; platform_engine_dir")"
[[ "$got" == "${HOME}/.ostler" ]] \
    || fail_test "platform_engine_dir returned '$got' (expected \${HOME}/.ostler)"

got="$(bash -c "set -u; source '$MODULE'; platform_visible_dir")"
[[ "$got" == "${HOME}/Documents/Ostler" ]] \
    || fail_test "platform_visible_dir returned '$got' (expected \${HOME}/Documents/Ostler)"

# Missing probe target = nothing to probe = FDA treated as granted
# (the CX-103 contract: only the TCC denial signature returns 1).
bash -c "set -u; source '$MODULE'; platform_has_full_disk_access '/nonexistent/probe.sqlite'" \
    || fail_test "platform_has_full_disk_access must return 0 when the probe target is missing"
echo "PASS: pure-function spot checks"

# ── 6. Single-machine Mac-only lock: exactly one implementation ────

impl_count=0
for f in "${REPO_ROOT}/platform/"*.sh; do
    [[ -e "$f" ]] || continue
    impl_count=$((impl_count + 1))
done
[[ "$impl_count" -eq 1 ]] \
    || fail_test "platform/ contains $impl_count implementations; v1 is Mac-only (locked directive 2026-05-09) -- a second platform needs Andy's explicit ruling, not a PR"
echo "PASS: exactly one platform implementation (macos.sh)"

echo "OK: platform seam guard checks all passed"
