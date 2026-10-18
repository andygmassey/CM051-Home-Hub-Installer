#!/bin/bash
# install.sh regenerates config.toml on EVERY DMG run. The installer never asks
# about Telegram, so a [channels.telegram] block written by ostler-telegram-setup
# must be carried across the regeneration verbatim, or a re-run silently turns
# Telegram off (Archie, CM051 #2980 review).
#
# 1. the lift helper, extracted from install.sh, returns the block verbatim
#    (and nothing when absent);
# 2. install.sh calls it BEFORE the truncating `{ ... } > "$ASSISTANT_CONFIG"`
#    and on every run, not only the reuse path;
# 3. the regeneration block itself, run for real against a stubbed
#    environment, writes the preserved block into the new config.toml.
# Exit 0 pass, 1 fail, 2 cannot run.
set -u
cd "$(dirname "$0")/.." || exit 2
INSTALL_SH=install.sh
fails=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fails=$((fails+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

sed -n '/^# BEGIN telegram-config-helpers/,/^# END telegram-config-helpers/p' "$INSTALL_SH" > "$T/h.sh"
if [ ! -s "$T/h.sh" ]; then
    bad "install.sh has no telegram-config-helpers block (no lift helper at all)"
else
    # shellcheck disable=SC1090
    . "$T/h.sh"
    cat > "$T/cfg.toml" <<'TOML'
schema_version = 2

[channels.imessage]
enabled = true

[channels.telegram]
# Set by ostler-telegram-setup.
enabled = true
bot_token = ""
allowed_users = ["4242"]

[channels.email]
enabled = false
TOML
    got="$(_ostler_existing_telegram_block "$T/cfg.toml")"
    want='[channels.telegram]
# Set by ostler-telegram-setup.
enabled = true
bot_token = ""
allowed_users = ["4242"]
'
    [ "$got" = "$(printf '%s' "$want")" ] && ok "helper lifts the block verbatim, stops at the next table" \
        || { bad "helper output differs"; printf '%s\n---\n' "$got"; }
    printf 'schema_version = 2\n[channels.imessage]\nenabled = true\n' > "$T/none.toml"
    [ -z "$(_ostler_existing_telegram_block "$T/none.toml")" ] && ok "absent block -> nothing" || bad "absent block printed something"
    [ -z "$(_ostler_existing_telegram_block "$T/missing.toml")" ] && ok "missing file -> nothing" || bad "missing file printed something"
fi

# 2. ordering: lifted before the truncating redirect, on every run
open_line="$(grep -n '^{$' "$INSTALL_SH" | awk -F: -v c="$(grep -n '^} > "\$ASSISTANT_CONFIG"$' "$INSTALL_SH" | cut -d: -f1)" '$1<c{l=$1} END{print l}')"
lift_line="$(grep -n '_TELEGRAM_BLOCK_PRESERVED="$(_ostler_existing_telegram_block "$ASSISTANT_CONFIG")"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
emit_line="$(grep -n 'printf .%s\\n. "\$_TELEGRAM_BLOCK_PRESERVED"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
close_line="$(grep -n '^} > "\$ASSISTANT_CONFIG"$' "$INSTALL_SH" | cut -d: -f1)"
if [ -z "$lift_line" ] || [ -z "$emit_line" ] || [ -z "$open_line" ] || [ -z "$close_line" ]; then
    bad "lift ($lift_line) or emit ($emit_line) site missing, or block bounds not found ($open_line..$close_line)"
else
    [ "$lift_line" -lt "$open_line" ] && ok "lift (:$lift_line) runs before the truncating redirect (:$open_line)" || bad "lift at :$lift_line is not before :$open_line"
    { [ "$emit_line" -gt "$open_line" ] && [ "$emit_line" -lt "$close_line" ]; } && ok "emit (:$emit_line) is inside the regeneration block" || bad "emit at :$emit_line outside :$open_line..:$close_line"
    # not gated on the reuse path: the installer never asks about Telegram
    ctx="$(sed -n "$((lift_line-4)),${lift_line}p" "$INSTALL_SH")"
    if printf '%s' "$ctx" | grep -q 'SKIP_PHASE2'; then bad "lift is gated on SKIP_PHASE2; a full re-run would still drop Telegram"; else ok "lift is not gated on the reuse path"; fi
fi

# 3. run the real regeneration block against a stubbed environment
if [ -n "${close_line:-}" ] && [ -n "${open_line:-}" ]; then
    {
        echo 'set +u'
        sed -n '/^# BEGIN telegram-config-helpers/,/^# END telegram-config-helpers/p' "$INSTALL_SH"
        echo '_esc() { printf "%s" "$1"; }'
        echo 'dbg() { :; }; info() { :; }; warn() { :; }; ok() { :; }'
        echo "ASSISTANT_CONFIG='$T/regen.toml'"
        [ -n "${lift_line:-}" ] && sed -n "${lift_line}p" "$INSTALL_SH"
        sed -n "${open_line},${close_line}p" "$INSTALL_SH"
    } > "$T/run.sh"
    [ -f "$T/cfg.toml" ] || printf '[channels.telegram]\nenabled = true\nbot_token = ""\nallowed_users = ["4242"]\n' > "$T/cfg.toml"
    cp "$T/cfg.toml" "$T/regen.toml"
    bash "$T/run.sh" >/dev/null 2>"$T/run.err"
    if grep -q '^allowed_users = \["4242"\]$' "$T/regen.toml" && grep -q '^\[channels.telegram\]$' "$T/regen.toml"; then
        ok "real regeneration block keeps [channels.telegram] with the owner id"
    else
        bad "real regeneration block dropped [channels.telegram] (stderr: $(head -c 300 "$T/run.err"))"
    fi
    n="$(grep -c '^\[channels.telegram\]$' "$T/regen.toml")"
    [ "$n" = "1" ] && ok "exactly one [channels.telegram] table" || bad "$n [channels.telegram] tables"
fi

echo "$fails failed"
[ "$fails" -eq 0 ]
