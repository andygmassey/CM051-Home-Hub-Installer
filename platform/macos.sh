#!/usr/bin/env bash
# platform/macos.sh -- macOS implementation of the Ostler installer
# platform seam.
#
# WHAT THIS IS
#   The macOS-specific operations install.sh performs, extracted behind
#   named platform_* functions so the main install flow reads
#   platform-neutrally. Every function body here is a byte-for-byte
#   transplant of the code that previously sat inline in install.sh --
#   this file changes WHERE the Mac primitives live, never WHAT they do.
#
# WHAT THIS IS NOT
#   Not a port. Ostler v1 is single-machine and Mac-only (locked
#   architectural directive, 2026-05-09). No linux.sh or windows.sh
#   exists and none may be added without Andy amending that directive
#   (CROSS_PLATFORM_INSTALLERS_SPEC.md section 11). This seam exists so
#   that a FUTURE, separately-authorised port implements one documented
#   function inventory instead of excavating a 16k-line script. See
#   platform/PORTING.md for the contract each function must honour.
#
# SOURCING
#   Sourced by install.sh immediately after the strings catalogue and
#   GUI emitter, from ${SCRIPT_DIR}/platform/macos.sh (tarball / dev /
#   .app bundle), with an OSTLER_PLATFORM_MODULE env override for
#   tests. A missing module is a packaging bug and install.sh
#   hard-fails, exactly like a missing strings catalogue.
#
#   Sourcing is side-effect-free: this file defines functions only,
#   prints nothing, and reads nothing at load time. It must stay safe
#   under `set -Eeuo pipefail`.
#
# British English. No operator PII. No hardcoded customer-facing
# strings (Rule 0.9: those live in install.sh.strings.<lang>.sh).

# ── Service supervision (launchd) ──────────────────────────────────
#
# Ostler background services are per-user launchd LaunchAgents in
# ~/Library/LaunchAgents, managed with the modern bootstrap/bootout
# verbs and a `launchctl load`/`unload` fallback for older macOS.
# The gui/$(id -u) domain targets the current console user session.

# Directory that holds per-user service definitions.
platform_service_dir() {
    printf '%s' "${HOME}/Library/LaunchAgents"
}

# Register + start a service from its definition file, best-effort.
# Never fails the install: every branch is masked, matching the
# historical inline pattern.
#   $1 = path to the service definition (launchd plist)
platform_service_load() {
    launchctl bootstrap "gui/$(id -u)" "$1" 2>/dev/null || \
        launchctl load "$1" 2>/dev/null || true
}

# Register + start a service, REPORTING failure to the caller so it
# can warn/branch. Same two-step bootstrap-then-legacy-load as
# platform_service_load, without the trailing `|| true` mask.
#   $1 = path to the service definition (launchd plist)
platform_service_load_check() {
    launchctl bootstrap "gui/$(id -u)" "$1" 2>/dev/null || \
        launchctl load "$1" 2>/dev/null
}

# Register + start a service via the modern verb only, reporting
# failure, stderr masked. Used where the legacy-load fallback is
# deliberately not wanted (e.g. the userspace tailscaled agent).
#   $1 = path to the service definition (launchd plist)
platform_service_bootstrap_check() {
    launchctl bootstrap "gui/$(id -u)" "$1" 2>/dev/null
}

# Register + start a service via the modern verb only, loud: stderr
# reaches the caller's log so a bootstrap failure is diagnosable.
#   $1 = path to the service definition (launchd plist)
platform_service_bootstrap() {
    launchctl bootstrap "gui/$(id -u)" "$1"
}

# Stop + unregister a service by label, best-effort.
#   $1 = service label (e.g. com.ostler.doctor)
platform_service_unload() {
    launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
}

# Stop + unregister a service by label with a legacy-unload fallback
# against the on-disk definition, best-effort.
#   $1 = service label; definition assumed at
#        $(platform_service_dir)/<label>.plist
platform_service_unload_fallback() {
    launchctl bootout "gui/$(id -u)/$1" 2>/dev/null \
        || launchctl unload "$(platform_service_dir)/$1.plist" 2>/dev/null \
        || true
}

# Restart a running service in place (kill + kickstart), best-effort.
#   $1 = service label
platform_service_restart() {
    launchctl kickstart -k "gui/$(id -u)/$1" 2>/dev/null || true
}

# ── Permissions (Full Disk Access / TCC) ───────────────────────────

# Probe whether this process holds Full Disk Access by attempting a
# read of a TCC-protected SQLite store, distinguishing the TCC denial
# signature from "file missing / no rows".
#
# CX-103 (DMG #48k, 2026-05-29): Accounts4.sqlite is gated by Full
# Disk Access on Sequoia. On a fresh install where the customer has
# not yet granted FDA to OstlerInstaller.app, sqlite3 returns
# "authorization denied"; a plain `2>/dev/null` mask collapses that
# to "0 accounts" and mis-fires the "Mail not connected" prompt.
#
#   $1 = path to a TCC-protected SQLite database to probe
# Returns 0 if FDA is granted (or the path is missing -- nothing to
# probe). Returns 1 if FDA is denied. Never raises.
platform_has_full_disk_access() {
    local db="$1"
    [[ -f "$db" ]] || return 0
    local err
    err="$(sqlite3 "file:${db}?mode=ro" -bail "SELECT 1 LIMIT 1" 2>&1 >/dev/null)" || true
    if [[ "$err" == *"authorization denied"* ]] \
       || [[ "$err" == *"unable to open database"* ]]; then
        return 1
    fi
    return 0
}

# Open the OS settings UI at the Full Disk Access grant pane,
# best-effort (the customer completes the grant by hand; macOS offers
# no API to grant FDA programmatically, by design).
platform_open_fda_pane() {
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
}

# Open the OS settings UI at the Automation (Apple Events) grant
# pane, best-effort. Redirection shape matches the historical inline
# call site (stdout+stderr masked).
platform_open_automation_pane() {
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" \
        >/dev/null 2>&1 || true
}

# Open the OS settings UI at the internet-accounts pane (where the
# customer connects Mail/Calendar accounts), best-effort.
platform_open_internet_accounts_pane() {
    open "x-apple.systempreferences:com.apple.preferences.internetaccounts" 2>/dev/null || true
}

# ── Power management ───────────────────────────────────────────────

# True (0) when the machine reports a battery, i.e. it is a laptop.
# Used to warn about lid-close sleep during the long Phase 3 run.
platform_has_battery() {
    pmset -g batt 2>/dev/null | grep -qE '[0-9]+%'
}

# Echo the current power source: "AC Power", "Battery Power", or
# nothing when undetectable (callers append their own fallback).
platform_power_source() {
    pmset -g batt 2>/dev/null | grep -oE "'(AC Power|Battery Power)'" | head -1 | tr -d "'"
}

# ── Hardware detection ─────────────────────────────────────────────

# Echo installed RAM in whole GB.
platform_ram_gb() {
    echo "$(( $(sysctl -n hw.memsize) / 1073741824 ))"
}

# ── Installer trust (code signing) ─────────────────────────────────

# Echo the signing details of a binary/bundle (authority chain etc),
# never failing; callers grep the output for the authority they
# expect. On macOS this is `codesign -dv`.
#   $1 = path to binary or .app bundle
platform_app_signature_info() {
    codesign -dv --verbose=4 "$1" 2>&1 || true
}

# Verify a bundle's signature AND the OS gatekeeper assessment,
# capturing each tool's stderr to a caller-supplied log file.
# Returns non-zero when either check fails.
#   $1 = path to .app bundle
#   $2 = signature-verify stderr log path
#   $3 = gatekeeper-assess stderr log path
platform_verify_app_signature() {
    codesign --verify --deep --strict "$1" 2>"$2" \
        && spctl --assess --type execute "$1" 2>"$3"
}

# ── Path layout (two-zone) ─────────────────────────────────────────
#
# Reference implementations of the two-zone layout roots (Engine zone
# private, Visible zone the user's vault). install.sh's historical
# path plumbing (_ostler_set_paths) is not yet routed through these --
# they are provided so new code and the future port share one source
# of truth. See PORTING.md "Not yet behind the seam".

platform_engine_dir() {
    printf '%s' "${HOME}/.ostler"
}

platform_visible_dir() {
    printf '%s' "${HOME}/Documents/Ostler"
}
