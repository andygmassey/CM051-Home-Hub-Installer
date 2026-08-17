#!/usr/bin/env bash
#
# test_assistant_config_no_tmp.sh
#
# THE DEFECT THIS EXISTS FOR, MEASURED ON A REAL BOX, NOT IMAGINED.
# .219 running v1.0.33, 2026-08-17, ~/.ostler/assistant-config/config.toml:
#
#     session_path = "/tmp/ostler-prelaunch-3992/state/whatsapp-session.db"
#
# The assistant config is written PRE-FDA, while _ostler_set_paths still has
# OSTLER_DIR bound to the /tmp/ostler-prelaunch-<pid> staging tree. The config
# FILE is promoted onto ~/.ostler/ afterwards; the VALUES inside it are not. So
# the shipped config pointed the customer's WhatsApp Web device credentials at
# a directory macOS purges on reboot and on periodic cleanup. The device link
# dies, the customer has to re-pair, and the daemon keeps printing
# "Channels: imessage, whatsapp" as though the channel were healthy.
#
# WHY A SECOND GATE AND NOT AN EDIT TO THE FIRST ONE.
# test_launchd_plist_no_tmp.sh already guards this exact root cause -- for the
# two ollama LaunchAgent plists (#177). It did not catch this one because it is
# keyed to those plists BY NAME. A gate keyed to a name does not cover a class.
# This one covers the whole assistant config, every key, not just session_path,
# so the next pre-FDA-tainted value is caught by a gate that already exists.
#
# THE SHAPE, and it is deliberately the same as its sibling:
# rather than grep the source for a suspicious-looking interpolation, this
# RENDERS the actual `{ ... } > "$ASSISTANT_CONFIG"` block out of install.sh
# with OSTLER_DIR deliberately POISONED to a prelaunch path -- the exact
# pre-FDA condition -- and asserts nothing prelaunch-tainted survives into the
# rendered TOML.
#
# Grepping the source would assert a FORMATTING choice. Rendering asserts the
# DEFECT. A future refactor that reaches the same bad value by a different
# spelling still fails here.
#
# PROVED-RED-BY: control 5 below, which re-renders the block with the fix
# reverted and requires the predicate to FIRE. Without that control this file
# could pass forever while measuring nothing.
#
# Every zero carries a positive control: an extraction that silently produced
# nothing would otherwise report "no /tmp found" and exit 0, which is the
# false-PASS this whole class of gate exists to prevent.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

PASS=0
FAILED=0
ok()      { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
failure() { printf '  FAIL  %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /' >&2; FAILED=$((FAILED+1)); }

echo "test_assistant_config_no_tmp"
echo

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: install.sh missing at $INSTALL_SH" >&2
    exit 2
fi

SANDBOX="$(mktemp -d -t asstcfg_XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# --------------------------------------------------------------------------
# Extract the emit block BY PATTERN, never by line number. Line numbers in a
# 20k-line install.sh rot within days, and a gate that extracts the wrong
# range still exits 0.
#
#   opens:  a line that is exactly `{`
#   closes: `} > "$ASSISTANT_CONFIG"`
# --------------------------------------------------------------------------
CLOSE_LN="$(grep -nE '^\} > "\$ASSISTANT_CONFIG"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "${CLOSE_LN:-}" ]]; then
    failure "could not find the '} > \"\$ASSISTANT_CONFIG\"' closer -- the emit block was renamed or restructured, and this gate is now measuring nothing"
    echo; echo "  $PASS passed, $FAILED failed"; exit 1
fi
OPEN_LN="$(awk -v c="$CLOSE_LN" 'NR<c && /^\{[[:space:]]*$/ {n=NR} END{print n}' "$INSTALL_SH")"
if [[ -z "${OPEN_LN:-}" ]] || [[ "$OPEN_LN" -ge "$CLOSE_LN" ]]; then
    failure "could not find the opening '{' above line $CLOSE_LN"
    echo; echo "  $PASS passed, $FAILED failed"; exit 1
fi

BLOCK="$SANDBOX/block.sh"
sed -n "$((OPEN_LN+1)),$((CLOSE_LN-1))p" "$INSTALL_SH" > "$BLOCK"
BLOCK_LINES="$(grep -c . "$BLOCK")"

if [[ "$BLOCK_LINES" -lt 50 ]]; then
    failure "extracted only $BLOCK_LINES lines from the emit block (lines $OPEN_LN..$CLOSE_LN) -- too small to be the real block"
else
    ok "extracted the assistant-config emit block, $BLOCK_LINES lines (install.sh:$OPEN_LN..$CLOSE_LN)"
fi

# --------------------------------------------------------------------------
# Render it under the exact pre-FDA condition.
#
# OSTLER_DIR poisoned to a prelaunch path INSIDE the sandbox: the block runs
# one real command, `mkdir -p "${OSTLER_DIR}/state"`, and it must not touch
# anything outside the sandbox.
#
# set +u on purpose. The block reads dozens of wizard answers that only exist
# mid-install. Unset ones render empty, which is fine: this gate asserts what
# the PATH values are, not that the wizard ran.
#
# CHANNEL_WHATSAPP_ENABLED MUST BE SET, and this is not incidental. The whole
# [channels.whatsapp] section sits behind `if [[ "$CHANNEL_WHATSAPP_ENABLED"
# == true ]]`. The first run of this gate left it unset, rendered 39 lines with
# no WhatsApp section at all, and reported "no /tmp/ostler-prelaunch path
# survives" -- a clean result from a render that had never reached the line
# carrying the defect. The positive controls below caught it. Anything that
# gates a section this file claims to cover has to be turned ON here, or the
# coverage is imaginary.
# --------------------------------------------------------------------------
render() {
    local block="$1" out="$2"
    (
        set +u
        OSTLER_DIR="$SANDBOX/tmp/ostler-prelaunch-9999"
        OSTLER_FINAL_DIR="$SANDBOX/home/.ostler"
        LOGS_DIR="$OSTLER_DIR/logs"
        DATA_DIR="$OSTLER_DIR/data"
        CONFIG_DIR="$OSTLER_DIR/config"
        HOME="$SANDBOX/home"
        # Synthetic, never a real number: the value only has to satisfy the
        # E.164 shape the emit path expects.
        CHANNEL_WHATSAPP_ENABLED=true
        CHANNEL_WHATSAPP_RECIPIENT="+10000000000"
        mkdir -p "$OSTLER_DIR" "$OSTLER_FINAL_DIR"
        # shellcheck disable=SC1090
        source "$block"
    ) > "$out" 2>"$out.err"
}

RENDERED="$SANDBOX/rendered.toml"
render "$BLOCK" "$RENDERED"

# --- POSITIVE CONTROLS. Without these a silently-empty render false-PASSes ---
if [[ "$(grep -c . "$RENDERED")" -lt 20 ]]; then
    failure "the rendered config is $(grep -c . "$RENDERED") lines -- the render produced nothing to inspect, so a clean result would mean nothing" "$(head -20 "$RENDERED.err")"
else
    ok "render produced $(grep -c . "$RENDERED") lines of TOML (positive control)"
fi

if [[ "$(grep -cF '[channels.whatsapp]' "$RENDERED")" -lt 1 ]]; then
    failure "rendered config has no [channels.whatsapp] section -- extraction or render is wrong" "$(head -30 "$RENDERED")"
else
    ok "rendered config contains [channels.whatsapp] (positive control)"
fi

if [[ "$(grep -cE '^session_path' "$RENDERED")" -lt 1 ]]; then
    failure "rendered config has no session_path line -- the key this defect lives on is absent, so its absence of /tmp proves nothing" "$(grep -A12 -F '[channels.whatsapp]' "$RENDERED" | head -20)"
else
    ok "rendered config contains a session_path line (positive control)"
fi

# --------------------------------------------------------------------------
# THE ASSERTION. Class-wide: no prelaunch-tainted value anywhere in the config,
# not merely on the one key that happened to be broken.
# --------------------------------------------------------------------------
taint="$(grep -cF 'ostler-prelaunch' "$RENDERED")"
if [[ "$taint" -gt 0 ]]; then
    failure "$taint line(s) in the shipped assistant config carry a /tmp/ostler-prelaunch path. /tmp is purged by macOS, so whatever these point at dies on reboot" \
            "$(grep -nF 'ostler-prelaunch' "$RENDERED")"
else
    ok "no /tmp/ostler-prelaunch path survives into the rendered config"
fi

# And the specific key resolves under the FINAL dir, not merely 'not /tmp'.
sp="$(grep -E '^session_path' "$RENDERED" | head -1 | sed -E 's/^session_path[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
if [[ "$sp" == "$SANDBOX/home/.ostler/"* ]]; then
    ok "session_path resolves under OSTLER_FINAL_DIR ($sp)"
else
    failure "session_path is '$sp', which is not under the final dir '$SANDBOX/home/.ostler'"
fi

# --------------------------------------------------------------------------
# 5. PROVE RED. Re-render with the fix reverted. If this does NOT trip the
#    predicate above, the predicate is decoration and every PASS above is
#    worthless.
# --------------------------------------------------------------------------
BROKEN="$SANDBOX/block_broken.sh"
sed 's|_wa_session_path_esc="${OSTLER_FINAL_DIR}/state/whatsapp-session.db"|_wa_session_path_esc="${OSTLER_DIR}/state/whatsapp-session.db"|' "$BLOCK" > "$BROKEN"

if ! cmp -s "$BLOCK" "$BROKEN"; then
    BROKEN_OUT="$SANDBOX/rendered_broken.toml"
    render "$BROKEN" "$BROKEN_OUT"
    if [[ "$(grep -cF 'ostler-prelaunch' "$BROKEN_OUT")" -gt 0 ]]; then
        ok "PROVED RED: reverting the fix puts a /tmp/ostler-prelaunch path back into the config and this gate sees it"
    else
        failure "reverting the fix did NOT reintroduce a prelaunch path -- this gate cannot detect the defect it was written for"
    fi
else
    failure "could not construct the broken variant (the fixed line was not found by the reverting sed) -- the PROVE-RED control is dead and this gate is unproven"
fi

echo
echo "  $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
echo "ALL ASSISTANT-CONFIG NO-TMP CONTROLS PASSED"
