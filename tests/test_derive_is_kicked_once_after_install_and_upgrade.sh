#!/usr/bin/env bash
# tests/test_derive_is_kicked_once_after_install_and_upgrade.sh
#
# com.ostler.derive-preferences is RunAtLoad=false on a 6 hour interval, so a
# fresh install, a re-install and an upgraded box each waited up to 6 hours for
# a derived graph ("What you like" empty, or stale and tier-less after an update).
#
#   arm 1  the REAL _install_derive_preferences_agent, in a sandbox HOME with a
#          fake launchctl, kickstarts gui/<uid>/com.ostler.derive-preferences
#          AFTER bootstrap and AFTER `launchctl print` confirmed the label.
#   arm 2  CONTROL / RED CASE: when launchctl print says the label is NOT
#          registered (load "succeeded" but did not take: `launchctl load` exits
#          0 on failure) NO kickstart is sent. A kick that ignored print would
#          pass arm 1 and fail here.
#   arm 3  the kick is plain `kickstart` (never -k) via _ks_bounded, so a
#          penalty-boxed job cannot block the installer.
#   arm 4  the Sparkle upgrade path (_upg_do_upgrade) kicks the same label after
#          the vendored trees are refreshed and BEFORE the VERSION success marker.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-${HERE}/../install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-kick.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

lift_function() { # name -> stdout (first column-0 } at which the text parses)
    local name="$1" start end
    start="$(grep -nE "^${name}\(\) \{" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
        sed -n "${start},${end}p" "$INSTALL_SH" > "${SANDBOX}/lift.sh"
        if bash -n "${SANDBOX}/lift.sh" 2>/dev/null; then cat "${SANDBOX}/lift.sh"; return 0; fi
    done
    return 1
}
lift_function _install_derive_preferences_agent > "${SANDBOX}/agent.sh" \
    || { echo "CANNOT-RUN: could not lift _install_derive_preferences_agent"; exit 2; }
lift_function _ks_bounded > "${SANDBOX}/ks.sh" \
    || { echo "CANNOT-RUN: could not lift _ks_bounded"; exit 2; }

run_install() { # $1 = "registered" | "unregistered"  -> echoes the launchctl call log
    local mode="$1" home="${SANDBOX}/home-${1}" bin="${SANDBOX}/bin-${1}"
    mkdir -p "$home" "$bin"
    cat > "${bin}/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "${home}/launchctl.log"
if [ "\$1" = "print" ] && [ "${mode}" = "unregistered" ]; then exit 113; fi
exit 0
STUB
    chmod +x "${bin}/launchctl"
    (
        export HOME="$home" PATH="${bin}:${PATH}"
        OSTLER_DIR="${home}/.ostler"; LOGS_DIR="${OSTLER_DIR}/logs"
        mkdir -p "$OSTLER_DIR" "$LOGS_DIR"
        ok() { :; }; warn() { :; }; info() { :; }
        MSG_OK_DERIVE_AGENT_LOADED=x; MSG_WARN_DERIVE_AGENT_LOAD_FAILED=y
        . "${SANDBOX}/ks.sh"; . "${SANDBOX}/agent.sh"
        _install_derive_preferences_agent
        # _ks_bounded backgrounds the kick; give it a moment to land.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            grep -q '^kickstart' "${home}/launchctl.log" 2>/dev/null && break; sleep 0.3
        done
    ) >/dev/null 2>&1
    cat "${home}/launchctl.log" 2>/dev/null
}

echo "arm 1: registered label"
LOG1="$(run_install registered)"
[ -n "$LOG1" ] || { echo "CANNOT-RUN: the sandbox produced no launchctl calls"; exit 2; }
KICK_LINE="$(printf '%s\n' "$LOG1" | grep -n '^kickstart ' | head -1 | cut -d: -f1)"
PRINT_LINE="$(printf '%s\n' "$LOG1" | grep -n '^print ' | head -1 | cut -d: -f1)"
BOOT_LINE="$(printf '%s\n' "$LOG1" | grep -n '^bootstrap ' | head -1 | cut -d: -f1)"
if printf '%s\n' "$LOG1" | grep -qE '^kickstart gui/[0-9]+/com\.ostler\.derive-preferences$'; then
    ok "kickstart gui/<uid>/com.ostler.derive-preferences was sent"
else bad "no kickstart of com.ostler.derive-preferences in: $(printf '%s' "$LOG1" | tr '\n' '|')"; fi
if [ -n "$KICK_LINE" ] && [ -n "$PRINT_LINE" ] && [ -n "$BOOT_LINE" ] \
   && [ "$BOOT_LINE" -lt "$PRINT_LINE" ] && [ "$PRINT_LINE" -lt "$KICK_LINE" ]; then
    ok "order: bootstrap ($BOOT_LINE) < print ($PRINT_LINE) < kickstart ($KICK_LINE)"
else bad "order wrong: bootstrap=$BOOT_LINE print=$PRINT_LINE kickstart=$KICK_LINE"; fi

echo "arm 2: control, label not registered"
LOG2="$(run_install unregistered)"
[ -n "$LOG2" ] || { echo "CANNOT-RUN: arm 2 produced no launchctl calls"; exit 2; }
if printf '%s\n' "$LOG2" | grep -q '^kickstart'; then
    bad "kickstart sent although launchctl print said the label is not registered"
else ok "no kickstart when launchctl print fails"; fi

echo "arm 3: never kickstart -k"
if printf '%s\n' "$LOG1" | grep -qE '^kickstart -k'; then bad "kickstart -k used"; else ok "plain kickstart"; fi
grep -qE '_ks_bounded "gui/\$\(id -u\)/\$\{label\}"' "$INSTALL_SH" \
    && ok "the install-time kick goes through _ks_bounded" || bad "install-time kick does not use _ks_bounded"

echo "arm 4: the upgrade path"
UP="$(lift_function _upg_do_upgrade 2>/dev/null || true)"
if [ -z "$UP" ]; then
    # defined inside an `if` block (indented): extract by markers instead
    UP="$(awk '/_upg_do_upgrade\(\) \{/,/_upg_do_rollback\(\) \{/' "$INSTALL_SH")"
fi
[ -n "$UP" ] || { echo "CANNOT-RUN: could not isolate _upg_do_upgrade"; exit 2; }
L_REFRESH="$(printf '%s\n' "$UP" | grep -n '_upg_repair_fda_venv$' | head -1 | cut -d: -f1)"
L_KICK="$(printf '%s\n' "$UP" | grep -n '_ks_bounded "\${_UPG_DOMAIN}/com.ostler.derive-preferences"' | head -1 | cut -d: -f1)"
L_VER="$(printf '%s\n' "$UP" | grep -n 'Write VERSION last' | head -1 | cut -d: -f1)"
if [ -n "$L_KICK" ] && [ -n "$L_REFRESH" ] && [ -n "$L_VER" ] && [ "$L_REFRESH" -lt "$L_KICK" ] && [ "$L_KICK" -lt "$L_VER" ]; then
    ok "upgrade kick sits after the tree refresh ($L_REFRESH) and before VERSION ($L_VER): line $L_KICK"
else bad "upgrade kick missing or misplaced: refresh=$L_REFRESH kick=$L_KICK version=$L_VER"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
