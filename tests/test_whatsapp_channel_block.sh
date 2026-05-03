#!/usr/bin/env bash
#
# tests/test_whatsapp_channel_block.sh
#
# Locks the WhatsApp channel wiring in install.sh.
#
# Why this test exists:
#
#   install.sh collects WhatsApp risk consent (A7 tickbox) and
#   persists a posture marker, but BEFORE this PR the TOML emitter
#   had no [channels.whatsapp] arm. The customer was told
#   "WhatsApp connector will be enabled (consent recorded)" and
#   ended up with a silently-disabled channel -- the consent
#   ceremony actively misled them. The install-capability audit
#   flagged this as a launch-blocker.
#
#   This test pins the wiring so the consent ceremony stays
#   honest:
#     1. The TOML emitter writes [channels.whatsapp] when
#        CHANNEL_WHATSAPP_ENABLED == true.
#     2. The block is gated specifically on CHANNEL_WHATSAPP_ENABLED
#        (not co-mingled with iMessage / email gates).
#     3. The post-install pair-code link step is documented in
#        the next-steps banner when the channel is on.
#
# Sister tests:
#   - test_consent_a7_a8.sh -- locks the A7 WhatsApp consent ceremony
#   - test_vane_bundle.sh -- locks the compose-layer Vane bundle
#   - test_assistant_config_vane_wiring.sh -- locks the Vane TOML wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── [channels.whatsapp] header is emitted ───────────────────────
if ! grep -q '\[channels\.whatsapp\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [whatsapp-header]: install.sh does not emit [channels.whatsapp] header" >&2
    exit 1
fi
echo "PASS: install.sh emits [channels.whatsapp] header"

# ── enabled = true ──────────────────────────────────────────────
# The block must turn the channel on; emitting the header without
# enabled=true would still leave the channel disabled at runtime
# and re-introduce the deception.
if ! awk '
    /\[channels\.whatsapp\]/                  { in_block = 1; next }
    in_block && /^[[:space:]]*\}/             { in_block = 0 }
    in_block && /enabled = true/              { found = 1 }
    END                                       { exit !found }
' "$INSTALL_SCRIPT"; then
    echo "FAIL [whatsapp-enabled-true]: [channels.whatsapp] block does not contain 'enabled = true'" >&2
    exit 1
fi
echo "PASS: [channels.whatsapp] block sets enabled = true"

# ── Block is gated on CHANNEL_WHATSAPP_ENABLED ──────────────────
# Walk back from the [channels.whatsapp] line to the nearest
# preceding `if [[ ... ]]; then`. That guard must reference
# CHANNEL_WHATSAPP_ENABLED. Anything else (e.g. piggybacking on
# the email gate) would mean the block can fire when WhatsApp
# consent was refused.
GATE_LINE="$(awk '
    /if \[\[/                                 { last_if = $0 }
    /echo "\[channels\.whatsapp\]"/           { print last_if; exit }
' "$INSTALL_SCRIPT")"

if [[ -z "$GATE_LINE" ]]; then
    echo "FAIL [whatsapp-gate-missing]: could not locate the if-guard preceding [channels.whatsapp] echo" >&2
    exit 1
fi

if ! echo "$GATE_LINE" | grep -q 'CHANNEL_WHATSAPP_ENABLED'; then
    echo "FAIL [whatsapp-wrong-gate]: [channels.whatsapp] block is not gated on CHANNEL_WHATSAPP_ENABLED" >&2
    echo "      Found gate: $GATE_LINE" >&2
    exit 1
fi
echo "PASS: [channels.whatsapp] block is gated on CHANNEL_WHATSAPP_ENABLED"

# ── Next-steps banner: pair-code link instructions ──────────────
# The banner must give the customer the concrete phone-side path
# (Settings > Linked Devices > Link with phone number) and the
# Mac-side command (`setup channels --interactive whatsapp`).
# Without both halves the customer is left guessing how to turn
# the consent into a working channel.
if ! grep -q 'Link your WhatsApp account' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-whatsapp-section]: next-steps banner does not surface 'Link your WhatsApp account'" >&2
    exit 1
fi
echo "PASS: next-steps banner has 'Link your WhatsApp account' section"

if ! grep -q 'Linked Devices' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-phone-side]: next-steps banner does not mention WhatsApp 'Linked Devices' path" >&2
    exit 1
fi
echo "PASS: next-steps banner mentions the phone-side 'Linked Devices' path"

if ! grep -q 'setup channels --interactive whatsapp' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-mac-side]: next-steps banner does not give the Mac-side setup command" >&2
    exit 1
fi
echo "PASS: next-steps banner gives the Mac-side setup command"

# ── End-to-end: emitter produces the expected TOML ──────────────
# Sandbox-run the TOML emitter section with CHANNEL_WHATSAPP_ENABLED=true
# (and the other channel vars false) and assert the output has the
# block. Belt-and-braces against a future edit that escapes the
# pattern checks above without the emitter actually firing.
EMITTER="$(mktemp)"
trap 'rm -f "$EMITTER"' EXIT

awk '
    /^TOMLPREAMBLE$/                         { capture = 1; next }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "$INSTALL_SCRIPT" > "$EMITTER"

if [[ ! -s "$EMITTER" ]]; then
    echo "FAIL [emitter-empty]: could not extract TOML emitter body" >&2
    exit 1
fi

OUTPUT="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if ! echo "$OUTPUT" | grep -q '^\[channels\.whatsapp\]$'; then
    echo "FAIL [end-to-end-header]: emitter output missing [channels.whatsapp] header" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter produces [channels.whatsapp] header when CHANNEL_WHATSAPP_ENABLED=true"

if ! echo "$OUTPUT" | grep -q '^enabled = true$'; then
    echo "FAIL [end-to-end-enabled]: emitter output missing 'enabled = true' under whatsapp block" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter writes 'enabled = true' under [channels.whatsapp]"

# Negative case: CHANNEL_WHATSAPP_ENABLED=false should suppress
# the block entirely.
OUTPUT_OFF="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=false \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if echo "$OUTPUT_OFF" | grep -q '\[channels\.whatsapp\]'; then
    echo "FAIL [end-to-end-suppress]: emitter wrote [channels.whatsapp] when CHANNEL_WHATSAPP_ENABLED=false" >&2
    exit 1
fi
echo "PASS: emitter suppresses [channels.whatsapp] when CHANNEL_WHATSAPP_ENABLED=false"

echo ""
echo "ALL WHATSAPP CHANNEL BLOCK TESTS PASSED"
