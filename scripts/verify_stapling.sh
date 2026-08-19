#!/usr/bin/env bash
# ============================================================================
# verify_stapling.sh -- post-cut integrity gate for DMG notarisation staples.
#
# WHY THIS EXISTS
# ---------------
# Task HR015 #221: the v1.0.8 DMG shipped with Ostler.app UNSTAPLED. Apple
# notarisation was submitted + accepted for the DMG wrapper, and the wrapper
# itself was stapled -- but the .app bundles NESTED inside the DMG's
# OstlerInstaller.app/Contents/Resources/ never received their tickets.
# When install.sh moves those apps to /Applications on the customer Mac,
# Gatekeeper looks for a stapled ticket on the .app itself and finds none.
# On a first-launch WITH internet, Gatekeeper falls back to an online
# ticket lookup and Ostler.app opens. On a first-launch WITHOUT internet
# (cafe, plane, firewall-blocked LAN) the launch is blocked.
#
# Sibling task #226: post-cut integrity gates. This is one of them. Every
# gate under this class enforces one property that a "green make ship"
# alone does NOT: notarisation success != every .app inside actually
# carries its ticket.
#
# WHAT IT DOES
# ------------
# Mounts the DMG (or accepts an already-mounted path), walks every .app
# bundle inside, runs `xcrun stapler validate` on each, and fails the
# cut CLOSED if ANY app is unstapled. Prints a per-app status line so
# the failure is diagnosable without re-running.
#
# Also validates the DMG itself is stapled -- that half already works
# today but a regression would silently break offline distribution too.
#
# USAGE
# -----
#   verify_stapling.sh <path-to-dmg>            # mount + verify + detach
#   verify_stapling.sh --mount <mount-path>     # verify an already-mounted DMG
#
# EXIT CODES
# ----------
#   0  every .app + the DMG is stapled
#   1  one or more items are UNSTAPLED (see per-item lines)
#   2  usage / environment error (missing DMG, mount failed, xcrun absent)
#
# TESTABILITY
# -----------
# The `xcrun stapler validate` invocation is routed through the
# $STAPLER_CMD env var (default: `xcrun stapler validate`). Tests inject
# a shim command that returns fake exit codes per fixture path -- see
# scripts/tests/test_verify_stapling_gate.sh. This lets us prove the gate
# REJECTS unstapled fixtures without needing a real notarised DMG to hand.
# ============================================================================
set -euo pipefail

STAPLER_CMD="${STAPLER_CMD:-xcrun stapler validate}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
ok(){ printf '%bOK%b   %s\n' "${GREEN}" "${NC}" "$*"; }
warn(){ printf '%bWARN%b %s\n' "${YEL}" "${NC}" "$*" >&2; }
bad(){ printf '%bFAIL%b %s\n' "${RED}" "${NC}" "$*" >&2; }
die(){ bad "$*"; exit 2; }

usage() {
    sed -n '2,42p' "$0"
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
# Mount (or reuse mount)
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
# Discover every .app bundle inside the mount.
#
# -maxdepth 6 is generous: OstlerInstaller.app/Contents/Resources/
# assistant-agent/OstlerAssistant.app sits at depth 5 from the mount
# root. Anything deeper is unusual enough to be worth surfacing.
#
# Sorted so the report is stable across runs (useful for diffing two
# cuts and for cut-record recording under SHIPPING_LEDGER.yaml).
# --------------------------------------------------------------------------
APPS=()
while IFS= read -r line; do APPS+=("$line"); done < <(
    find "${MOUNT}" -maxdepth 6 -name '*.app' -type d 2>/dev/null | LC_ALL=C sort
)

if [[ "${#APPS[@]}" -eq 0 ]]; then
    die "no .app bundles found under ${MOUNT} -- DMG shape has changed; update this gate"
fi

# --------------------------------------------------------------------------
# Walk each .app + record pass/fail. Every failure is enumerated so the
# ship record captures which specific bundle is missing its ticket.
#
# `xcrun stapler validate` exit codes we care about:
#   0   ticket present + valid
#   65  ticket missing (Sonoma quiet mode)
#   16  ticket missing (older / verbose mode)
#   *   any other non-zero: treat as fail
# --------------------------------------------------------------------------
FAILURES=()
PASSES=()
for app in "${APPS[@]}"; do
    rel="${app#${MOUNT}/}"
    # Route the call through STAPLER_CMD so tests can inject a shim.
    # We deliberately swallow the tool's own stdout/stderr (they are
    # verbose + noisy) and print our own single-line summary; the raw
    # output is available on re-run for anyone diagnosing.
    if ${STAPLER_CMD} "$app" >/dev/null 2>&1; then
        ok "stapled: ${rel}"
        PASSES+=("${rel}")
    else
        bad "UNSTAPLED: ${rel}"
        FAILURES+=("${rel}")
    fi
done

# --------------------------------------------------------------------------
# DMG-level check (only meaningful when we mounted from a DMG path).
# When called with --mount there is no DMG to validate here.
# --------------------------------------------------------------------------
DMG_FAIL=0
if [[ "${MODE}" = "dmg" ]]; then
    if ${STAPLER_CMD} "${DMG_PATH}" >/dev/null 2>&1; then
        ok "stapled: $(basename "${DMG_PATH}") (DMG wrapper)"
    else
        bad "UNSTAPLED: $(basename "${DMG_PATH}") (DMG wrapper)"
        DMG_FAIL=1
    fi
fi

# --------------------------------------------------------------------------
# Summary + exit
# --------------------------------------------------------------------------
printf '\n[SUMMARY] %d/%d .app bundles stapled; DMG wrapper=%s\n' \
    "${#PASSES[@]}" "${#APPS[@]}" \
    "$([[ ${MODE} = dmg ]] && ([[ ${DMG_FAIL} -eq 0 ]] && echo stapled || echo UNSTAPLED) || echo n/a)"

if [[ "${#FAILURES[@]}" -gt 0 || "${DMG_FAIL}" -eq 1 ]]; then
    printf '\n' >&2
    bad "post-cut stapling gate FAILED"
    printf 'One or more .app bundles inside the DMG lack a notarisation ticket.\n' >&2
    printf 'A customer with no internet on first launch will hit Gatekeeper\n' >&2
    printf 'blocking the app (HR015 task #221).\n' >&2
    printf 'Fix: ensure the `staple-apps` Makefile step runs BEFORE `package`\n' >&2
    printf 'and BEFORE the DMG is signed. Then re-cut.\n' >&2
    exit 1
fi

ok "post-cut stapling gate GREEN (all apps + DMG wrapper stapled)"
exit 0
