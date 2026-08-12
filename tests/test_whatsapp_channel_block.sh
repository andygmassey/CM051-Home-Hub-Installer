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

# ═══════════════════════════════════════════════════════════════
# WEB-MODE BACKEND SELECTOR (2026-08-12)
# ═══════════════════════════════════════════════════════════════
#
# Andy ruled WhatsApp non-negotiable for v1. The root cause was two
# layers deep. The daemon shipped without the `whatsapp-web` feature
# (ostler-assistant #304), AND install.sh wrote `enabled = true` with
# NO backend selector, which is inert: the daemon picks its WhatsApp
# backend by which credentials are present, and with neither
# `session_path` nor the Cloud API trio it logs
#
#     WhatsApp channel enabled but not configured
#
# and never registers in the cron-delivery registry. Every customer
# install since the block landed recorded a consent yes for a channel
# that could not run.
#
# These assertions REUSE the $EMITTER extracted above and read the
# TOML it actually produces. Grepping install.sh for the line would
# not do: board #636 is a CM051 fix that shipped INERT because the
# line was present in install.sh but sat inside a quoted heredoc, and
# a source grep passes on exactly that defect.

WA_TMP="$(mktemp -d)"
trap 'rm -f "$EMITTER"; rm -rf "$WA_TMP"' EXIT

OUTPUT_WEB="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_RECIPIENT="+447700900123" \
    OSTLER_DIR="${WA_TMP}/.ostler" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

# CONTROL: the render must have produced the block at all, or every
# assertion below is vacuously true against empty output.
if ! echo "$OUTPUT_WEB" | grep -q '^\[channels\.whatsapp\]$'; then
    echo "FAIL [web-render-control]: the parameterised render produced no whatsapp block" >&2
    echo "Output was:" >&2
    echo "$OUTPUT_WEB" >&2
    exit 1
fi

# ── session_path present, absolute, outside Caches ──────────────
if ! echo "$OUTPUT_WEB" | grep -qE '^session_path = "'; then
    echo "FAIL [whatsapp-session-path]: emitted TOML has no session_path." >&2
    echo "  Without it the daemon refuses the channel at startup and the customer's" >&2
    echo "  recorded consent buys them nothing. Output was:" >&2
    echo "$OUTPUT_WEB" >&2
    exit 1
fi
WA_SP="$(echo "$OUTPUT_WEB" | sed -n 's/^session_path = "\(.*\)"$/\1/p')"
if [[ "$WA_SP" != /* ]]; then
    echo "FAIL [whatsapp-session-path-abs]: session_path is not absolute: ${WA_SP}" >&2
    exit 1
fi
if [[ "$WA_SP" == *"/Caches/"* ]]; then
    echo "FAIL [whatsapp-session-path-caches]: session_path is under Caches, which the OS purges." >&2
    echo "  A purged session silently unlinks the customer's WhatsApp." >&2
    exit 1
fi
echo "PASS: emitted TOML carries an absolute session_path outside Caches"

# ── the parent directory is created by the block ────────────────
# wa-rs opens the file through RusqliteStore and will not mkdir for it.
if [[ ! -d "$(dirname "$WA_SP")" ]]; then
    echo "FAIL [whatsapp-session-dir]: $(dirname "$WA_SP") was not created by the block" >&2
    exit 1
fi
echo "PASS: the session directory is created by the block itself"

# ── pair_phone is DIGITS ONLY ───────────────────────────────────
# The most likely silent failure in this change: reusing the E.164
# value. wa-rs receives pair_phone verbatim as
# PairCodeOptions.phone_number (whatsapp_web.rs, `phone.clone()`), so
# a stored "+" reaches Meta unchanged and the pair code never arrives.
# Only the internal bot_phone identity is digit-filtered.
if ! echo "$OUTPUT_WEB" | grep -qE '^pair_phone = "'; then
    echo "FAIL [whatsapp-pair-phone]: emitted TOML has no pair_phone." >&2
    echo "  wa-rs then falls back to QR, and a QR printed to daemon stderr on a" >&2
    echo "  headless Hub is not a surface a customer can use." >&2
    exit 1
fi
WA_PP="$(echo "$OUTPUT_WEB" | sed -n 's/^pair_phone = "\(.*\)"$/\1/p')"
if [[ ! "$WA_PP" =~ ^[0-9]+$ ]]; then
    echo "FAIL [whatsapp-pair-phone-digits]: pair_phone must be digits only, got: ${WA_PP}" >&2
    exit 1
fi
if [[ "$WA_PP" != "447700900123" ]]; then
    echo "FAIL [whatsapp-pair-phone-value]: expected 447700900123, got ${WA_PP}" >&2
    exit 1
fi
echo "PASS: pair_phone is digits only and derived from the wizard number"

# ── allowed_numbers KEEPS its E.164 plus ────────────────────────
# CONTROL for the assertion above. If a future edit applied the
# digit-strip to both fields this test would still pass on pair_phone
# while the inbound allowlist silently stopped matching. The two
# fields want different formats and both are asserted.
if ! echo "$OUTPUT_WEB" | grep -qF 'allowed_numbers = ["+447700900123"]'; then
    echo "FAIL [whatsapp-allowed-numbers-e164]: allowed_numbers lost its E.164 form." >&2
    echo "  pair_phone is digits-only; allowed_numbers is E.164 WITH the plus." >&2
    echo "$OUTPUT_WEB" >&2
    exit 1
fi
echo "PASS: allowed_numbers keeps E.164 while pair_phone is digits only"

# ── consent without a number still yields a usable config ───────
# A customer who consents but declines to give a number must still get
# a working Web-mode backend and pair by QR. session_path must not
# depend on the recipient, and pair_phone must not be invented.
OUTPUT_NORECIP="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_RECIPIENT="" \
    OSTLER_DIR="${WA_TMP}/.ostler-norecip" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"
if ! echo "$OUTPUT_NORECIP" | grep -qE '^session_path = "'; then
    echo "FAIL [whatsapp-no-recipient-session]: session_path must not depend on the recipient" >&2
    exit 1
fi
if echo "$OUTPUT_NORECIP" | grep -qE '^pair_phone = '; then
    echo "FAIL [whatsapp-no-recipient-pair]: pair_phone emitted with no number to pair" >&2
    exit 1
fi
echo "PASS: consent without a number still yields a Web-mode config, without a bogus pair_phone"

echo ""
echo "ALL WHATSAPP CHANNEL BLOCK TESTS PASSED"
