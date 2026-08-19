#!/usr/bin/env bash
# ============================================================================
# verify_commit_parity.sh -- post-cut integrity gate for daemon + wrapper
# frontend commit parity.
#
# WHY THIS EXISTS
# ---------------
# Task HR015 #226 (permanent commit-parity gate). Sibling to task #221's
# stapling gate; both are post-cut integrity gates that enforce a property
# a green `make ship` alone does NOT.
#
# Class-of-bug caught 2026-07-30 (HR015 #225, v1.0.13):
#   * `make ship` cut a fresh daemon (hub-v0.4.43, new web/dist/index-DCT9-lP0.js,
#     6-digit code removed) into assistant-agent/.
#   * gui/Makefile line 66 OSTLER_APP_PATH points at
#     ~/Documents/Projects/ostler-assistant/target/release/bundle/macos/Ostler.app.
#     That path was NOT rebuilt against the same commit as the daemon: the
#     wrapper on disk was a stale build embedding pre-2026-06-29
#     web/dist/index-BlCfKuJD.js, which STILL rendered the 6-digit code.
#   * DMG mounts fine, install.sh succeeds, both binaries signed + notarised,
#     verify-dmg-contents + verify-stapling pass -- first-launch UI BROKEN.
#
# Root cause: two independently-built binaries (daemon + Tauri wrapper) each
# carry the same web/dist frontend, and the ship pipeline had no gate to
# assert they came from the same source commit. Fresh binary A + stale
# binary B is a class-of-bug that a "green make ship" cannot catch.
#
# WHAT IT DOES
# ------------
# Mounts the DMG (or accepts an already-mounted path), extracts a
# `WRAPPER_FRONTEND_COMMIT=<40-hex>` marker from the Tauri wrapper binary
# and a `DAEMON_FRONTEND_COMMIT=<40-hex>` marker from the daemon binary,
# and fails the cut CLOSED if they are not equal (or if either marker is
# absent -- absence means the binary was built from a pre-#226-sentinel
# commit and cannot be attested).
#
# The sibling PR in ostler-ai/ostler-assistant emits these sentinels at
# build time: build.rs on the daemon stamps DAEMON_FRONTEND_COMMIT into
# the binary, and the Tauri wrapper's build.rs stamps
# WRAPPER_FRONTEND_COMMIT. Both are stringified `env!()` constants -- fully
# codesigning-invariant, discoverable via `strings | grep`.
#
# USAGE
# -----
#   verify_commit_parity.sh <path-to-dmg>            # mount + verify + detach
#   verify_commit_parity.sh --mount <mount-path>     # verify an already-mounted DMG
#
# EXIT CODES
# ----------
#   0  both markers present + equal
#   1  markers differ, or one/both markers absent (pre-#226 binary)
#   2  usage / environment error (missing DMG, mount failed)
#
# NO SKIP SEMANTICS
# -----------------
# There is deliberately no env var that turns this gate off. Per
# feedback_gate_must_prove_it_fires_not_just_compile, a silent no-op gate is
# worse than no gate. If the assertion is wrong, fix the assertion; do not
# add a bypass.
#
# TESTABILITY
# -----------
# The `strings` invocation is routed through the $STRINGS_CMD env var
# (default: `strings`). Tests inject a shim binary whose output is
# controlled per-fixture-path -- see
# scripts/tests/test_verify_commit_parity_gate.sh. This lets us prove the
# gate REJECTS mismatched fixtures without needing a real signed DMG.
# ============================================================================
set -euo pipefail

STRINGS_CMD="${STRINGS_CMD:-strings}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
ok(){ printf '%bOK%b   %s\n' "${GREEN}" "${NC}" "$*"; }
warn(){ printf '%bWARN%b %s\n' "${YEL}" "${NC}" "$*" >&2; }
bad(){ printf '%bFAIL%b %s\n' "${RED}" "${NC}" "$*" >&2; }
die(){ bad "$*"; exit 2; }

usage() {
    sed -n '2,60p' "$0"
    exit 2
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
MODE=""; TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount)     MODE="mount"; TARGET="${2:-}"; shift 2 || die "--mount needs a path" ;;
        -h|--help)   usage ;;
        --*)         die "unknown flag: $1" ;;
        *)           MODE="dmg"; TARGET="$1"; shift ;;
    esac
done
[[ -n "${MODE}" ]] || usage
[[ -n "${TARGET}" ]] || die "no target given"

# --------------------------------------------------------------------------
# Mount (or reuse mount). EXIT trap detaches so a failure mid-extract does
# not leak the mount.
# --------------------------------------------------------------------------
MOUNT=""; DETACH_ON_EXIT=0
DMG_PATH=""
if [[ "${MODE}" = "dmg" ]]; then
    [[ -f "${TARGET}" ]] || die "DMG not found: ${TARGET}"
    DMG_PATH="${TARGET}"
    printf '\n[STEP] Mounting %s\n' "${DMG_PATH}"
    MOUNT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly 2>&1 | tail -1 | awk -F'\t' '{print $NF}')"
    [[ -n "${MOUNT}" && -d "${MOUNT}" ]] || die "hdiutil attach did not report a mount path for ${DMG_PATH}"
    DETACH_ON_EXIT=1
else
    [[ -d "${TARGET}" ]] || die "mount path not a directory: ${TARGET}"
    MOUNT="${TARGET}"
    printf '\n[STEP] Verifying pre-mounted %s\n' "${MOUNT}"
fi

cleanup() {
    if [[ "${DETACH_ON_EXIT}" -eq 1 && -n "${MOUNT}" ]]; then
        hdiutil detach "${MOUNT}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Locate the two binaries in the DMG payload.
#
# Shape mirrors gui/Makefile verify-dmg-contents:
#   Wrapper: OstlerInstaller.app/Contents/Resources/Ostler.app -- main binary
#            resolved from CFBundleExecutable, NOT hardcoded. It was pinned to
#            "zeroclaw-desktop", a name retired in the ZeroClaw -> Ostler
#            rename; the Hub now ships "ostler-hub". A hardcoded executable
#            name is the same rot as a hardcoded branch or registry namespace:
#            it fails the cut on a bundle that is perfectly correct, AND it
#            would silently pass a bundle whose real executable was missing so
#            long as a stale-named file happened to sit beside it. Ask the
#            bundle what it execs.
#   Daemon:  OstlerInstaller.app/Contents/Resources/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant
#     fallback: OstlerInstaller.app/Contents/Resources/assistant-agent/bin/ostler-assistant
# --------------------------------------------------------------------------
RES="${MOUNT}/OstlerInstaller.app/Contents/Resources"
WRAPPER_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "${RES}/Ostler.app/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "${WRAPPER_EXE}" ]] || die "Ostler.app declares no CFBundleExecutable (Info.plist missing or unreadable)"
WRAPPER="${RES}/Ostler.app/Contents/MacOS/${WRAPPER_EXE}"
DAEMON="${RES}/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
if [[ ! -e "${DAEMON}" ]]; then
    DAEMON="${RES}/assistant-agent/bin/ostler-assistant"
fi

[[ -e "${WRAPPER}" ]] || die "wrapper binary not found in DMG payload: ${WRAPPER#${MOUNT}/}"
[[ -e "${DAEMON}"  ]] || die "daemon binary not found in DMG payload: expected either assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant or assistant-agent/bin/ostler-assistant"

# --------------------------------------------------------------------------
# Extract the sentinel markers. The `${STRINGS_CMD}` indirection lets the
# self-test inject a shim; production runs use the system `strings`.
#
# Marker shape (emitted by ostler-assistant sibling PR for HR015 #226):
#   WRAPPER_FRONTEND_COMMIT=<40-hex>
#   DAEMON_FRONTEND_COMMIT=<40-hex>
# `head -1` in case the string appears more than once (linker rodata may
# dedupe or not depending on optimisation level -- either way we want the
# first hit).
# --------------------------------------------------------------------------
WRAPPER_SHA="$(${STRINGS_CMD} "${WRAPPER}" 2>/dev/null | grep -oE 'WRAPPER_FRONTEND_COMMIT=[0-9a-f]{40}' | head -1 | cut -d= -f2 || true)"
DAEMON_SHA="$(${STRINGS_CMD} "${DAEMON}" 2>/dev/null | grep -oE 'DAEMON_FRONTEND_COMMIT=[0-9a-f]{40}' | head -1 | cut -d= -f2 || true)"

# --------------------------------------------------------------------------
# Assertions. Every failure explains: which binary is affected, why it is
# a fail, and the exact remediation path (rebuild-command + which commit).
# --------------------------------------------------------------------------
WRAPPER_MISSING=0
DAEMON_MISSING=0
if [[ -z "${WRAPPER_SHA}" ]]; then
    WRAPPER_MISSING=1
    bad "wrapper binary carries no WRAPPER_FRONTEND_COMMIT marker"
    printf '  path: %s\n' "${WRAPPER#${MOUNT}/}" >&2
    printf '  meaning: this Ostler.app was built from a pre-#226-sentinel\n' >&2
    printf '           commit and cannot attest which frontend it embeds.\n' >&2
    printf '  fix: check out ostler-assistant at a commit that carries the\n' >&2
    printf '       WRAPPER_FRONTEND_COMMIT sentinel and rebuild via\n' >&2
    printf '       `cargo tauri build --release` in apps/tauri/, then\n' >&2
    printf '       re-run `make ship` in gui/.\n' >&2
fi
if [[ -z "${DAEMON_SHA}" ]]; then
    DAEMON_MISSING=1
    bad "daemon binary carries no DAEMON_FRONTEND_COMMIT marker"
    printf '  path: %s\n' "${DAEMON#${MOUNT}/}" >&2
    printf '  meaning: this ostler-assistant daemon was built from a\n' >&2
    printf '           pre-#226-sentinel commit and cannot attest which\n' >&2
    printf '           frontend it embeds.\n' >&2
    printf '  fix: rebuild the daemon from a commit that carries the\n' >&2
    printf '       DAEMON_FRONTEND_COMMIT sentinel (see ostler-assistant\n' >&2
    printf '       sibling PR for HR015 #226) and re-cut.\n' >&2
fi

if [[ ${WRAPPER_MISSING} -eq 1 || ${DAEMON_MISSING} -eq 1 ]]; then
    printf '\n' >&2
    bad "post-cut commit-parity gate FAILED (HR015 #226) -- missing sentinel(s)"
    exit 1
fi

if [[ "${WRAPPER_SHA}" != "${DAEMON_SHA}" ]]; then
    bad "hub wrapper frontend commit mismatch: daemon=${DAEMON_SHA} wrapper=${WRAPPER_SHA}"
    printf '\n' >&2
    printf 'This is the class-of-bug caught by HR015 #225 (v1.0.13 cut):\n' >&2
    printf '  daemon was rebuilt fresh; Ostler.app wrapper was NOT, so the\n' >&2
    printf '  DMG shipped with two different frontends. Customer first-launch\n' >&2
    printf '  UI is broken.\n' >&2
    printf 'Fix: rebuild the wrapper via `cargo tauri build --release` in\n' >&2
    printf '     apps/tauri/ from a checkout at the daemon`s commit\n' >&2
    printf '     (%s), then re-run `make ship`.\n' "${DAEMON_SHA}" >&2
    printf 'HR015 #226 -- see #225 for the class-of-bug that produced this gate.\n' >&2
    exit 1
fi

ok "commit-parity verified: daemon=${DAEMON_SHA} wrapper=${WRAPPER_SHA}"
exit 0
