#!/usr/bin/env bash
# THE CUSTOMER'S EMAIL PASSWORD NEVER LANDS IN config.toml (CM051 #1976).
#
# Runs the REAL install.sh region, from the email-password store step through
# the config.toml write and its chmod, in a throwaway HOME, under the shipped
# /bin/bash and `set -Eeo pipefail`, and reads the files it leaves on disk:
#
#   A. fresh install with a custom-IMAP password: config.toml does not contain
#      it and carries `password = ""`; ~/.ostler/secrets/email_password holds
#      it byte for byte at mode 0600; the install output does not contain it.
#   B. upgrade (reuse-settings re-run) over an old config.toml holding the
#      password in plain text: the plaintext is moved into the secrets file and
#      gone from config.toml, and the output does not contain it.
#   C. an `enc2:` value in the old config is left where it is (the daemon
#      decrypts it) and no secrets file is invented.
#   D. no email channel any more: a stale secrets file is removed.
#   E. a password with quotes, a backslash, `$(...)` and edge spaces survives
#      byte for byte (the old writer corrupted backslashes into TOML escapes).
#
# RED ON main: SUBJECT=<old install.sh> runs the same arms against that file.
# Where the store step does not exist the region starts at the TOML preamble,
# so arm A fails on the plaintext in config.toml. Exit 0 PASS, 1 FAIL, 2
# CANNOT-RUN.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${SUBJECT:-${REPO}/install.sh}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}"; exit 2; }
[ -x "$BASH_BIN" ] || { echo "CANNOT-RUN: no ${BASH_BIN}"; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

HELPERS="${WORK}/helpers.sh"; REGION="${WORK}/region.sh"
sed -n '/^# BEGIN email-allowlist-helpers/,/^# END email-allowlist-helpers/p' "$SUBJECT" > "$HELPERS"
if /usr/bin/grep -q '^# ── Email password -> ' "$SUBJECT"; then
    start='^# ── Email password -> '
else
    start='^umask_orig=[$][(]umask[)]$'
fi
awk -v s="$start" '
    $0 ~ s && !done                       { cap = 1 }
    cap                                   { print }
    cap && /^chmod 600 "\$ASSISTANT_CONFIG"$/ { cap = 0; done = 1 }
' "$SUBJECT" > "$REGION"
nh="$(wc -l < "$HELPERS" | tr -d ' ')"; nr="$(wc -l < "$REGION" | tr -d ' ')"
echo "examined: ${SUBJECT##*/} helpers=${nh} lines, region=${nr} lines, shell=$("$BASH_BIN" -c 'echo $BASH_VERSION')"
if [ "$nh" -lt 20 ] || [ "$nr" -lt 50 ] || ! "$BASH_BIN" -n "$REGION"; then
    echo "CANNOT-RUN: could not extract a parseable region from ${SUBJECT}"; exit 2
fi

# run_region <case-dir> [env...]: one install of the region in its own HOME.
run_region() {
    local d="$1"; shift
    mkdir -p "${d}/hm/.ostler/secrets" "${d}/hm/.ostler/assistant-config"
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${d}/hm" \
        OSTLER_DIR="${d}/hm/.ostler" SECRETS_DIR="${d}/hm/.ostler/secrets" \
        ASSISTANT_CONFIG="${d}/hm/.ostler/assistant-config/config.toml" \
        CHANNEL_IMESSAGE_ENABLED=false CHANNEL_WHATSAPP_ENABLED=false \
        CHANNEL_EMAIL_APPLE_MAIL_ENABLED=false CHANNEL_EMAIL_USERNAME=assistant@example.invalid \
        CHANNEL_EMAIL_FROM=assistant@example.invalid CHANNEL_EMAIL_IMAP_HOST=imap.example.invalid \
        CHANNEL_EMAIL_SMTP_HOST=smtp.example.invalid CHANNEL_EMAIL_IMAP_PORT=993 \
        CHANNEL_EMAIL_SMTP_PORT=587 CHANNEL_EMAIL_IMAP_FOLDER=INBOX \
        CHANNEL_EMAIL_ALLOWED_SENDERS=owner@example.invalid USER_TZ=Europe/London \
        "$@" "$BASH_BIN" -c '
            info() { echo "[info] $*"; }; warn() { echo "[warn] $*" >&2; }
            fail() { echo "[fail] $*" >&2; exit 1; }; fail_with_code() { echo "[fail] $*" >&2; exit 1; }
            dbg() { :; }; gui_log() { :; }; gui_active() { return 1; }
            . "$1"
            if [ -n "${OLD_CONFIG:-}" ]; then
                _EMAIL_BLOCK_PRESERVED="$(_ostler_existing_email_block "$ASSISTANT_CONFIG")"
            fi
            set -Eeo pipefail  # not -u: the emitter reads installer state set far above this region
            . "$2"
        ' _ "$HELPERS" "$REGION" > "${d}/install.log" 2>&1
    echo $? > "${d}/rc"
}
cfg_of() { printf '%s' "$1/hm/.ostler/assistant-config/config.toml"; }
sec_of() { printf '%s' "$1/hm/.ostler/secrets/email_password"; }
has() { /usr/bin/grep -qF -- "$2" "$1" 2>/dev/null; }
# GNU first: on Linux `stat -f` means FILESYSTEM status and succeeds, so the
# BSD form cannot be tried first. BSD stat has no -c and falls through.
mode_of() { stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1"; }

MARK="synthetic-pw-$$-$RANDOM"

echo "-- A. fresh install with a custom-IMAP password --"
A="${WORK}/A"; run_region "$A" CHANNEL_EMAIL_ENABLED=true CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true CHANNEL_EMAIL_PASSWORD="$MARK"
if [ "$(cat "$A/rc")" != 0 ] || ! has "$(cfg_of "$A")" '[channels.email]'; then
    echo "CANNOT-RUN: arm A did not render a config (rc=$(cat "$A/rc"))"; tail -5 "$A/install.log"; exit 2
fi
if has "$(cfg_of "$A")" "$MARK"; then bad "A: config.toml contains the email password"; else ok "A: config.toml does not contain the email password"; fi
if /usr/bin/grep -qx 'password = ""' "$(cfg_of "$A")"; then ok "A: config.toml carries password = \"\""; else bad "A: no empty password line in config.toml"; fi
if [ -f "$(sec_of "$A")" ] && [ "$(cat "$(sec_of "$A")"; echo x)" = "${MARK}x" ]; then ok "A: secrets file holds the password byte for byte"; else bad "A: secrets file missing or wrong"; fi
if [ "$(mode_of "$(sec_of "$A")" 2>/dev/null)" = 600 ]; then ok "A: secrets file is mode 0600"; else bad "A: secrets file mode is $(mode_of "$(sec_of "$A")" 2>/dev/null)"; fi
if has "$A/install.log" "$MARK"; then bad "A: the install output contains the password"; else ok "A: the install output does not contain the password ($(wc -l < "$A/install.log" | tr -d ' ') lines read)"; fi

echo "-- B. upgrade over an old config holding the password in plain text --"
B="${WORK}/B"; mkdir -p "$B/hm/.ostler/assistant-config"
cat > "$(cfg_of "$B")" <<EOF
schema_version = 2

[channels.email]
enabled = true
custom_imap = true
imap_host = "imap.example.invalid"
username = "assistant@example.invalid"
password = "${MARK}\\"q"
from_address = "assistant@example.invalid"
allowed_senders = ["owner@example.invalid"]

[autonomy]
level = "supervised"
EOF
run_region "$B" OLD_CONFIG=1 CHANNEL_EMAIL_ENABLED=false CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false
if [ "$(cat "$B/rc")" != 0 ] || ! has "$(cfg_of "$B")" '[channels.email]'; then
    bad "B: the re-run did not keep the email block (rc=$(cat "$B/rc"))"; tail -5 "$B/install.log"
else
    if has "$(cfg_of "$B")" "$MARK"; then bad "B: the old plaintext password is still in config.toml"; else ok "B: the old plaintext password is gone from config.toml"; fi
    if /usr/bin/grep -qx 'password = ""' "$(cfg_of "$B")"; then ok "B: the migrated block carries password = \"\""; else bad "B: migrated block has no empty password"; fi
    if has "$(cfg_of "$B")" 'allowed_senders = ["owner@example.invalid"]'; then ok "B: the rest of the customer's block is kept"; else bad "B: migration lost other email settings"; fi
fi
if [ -f "$(sec_of "$B")" ] && [ "$(cat "$(sec_of "$B")"; echo x)" = "${MARK}\"qx" ]; then ok "B: the password moved into the secrets file, un-escaped to what was typed"; else bad "B: the password did not reach the secrets file intact"; fi
if has "$B/install.log" 'Moved the email password out of config.toml'; then ok "B: CONTROL: the captured output is live (the migration notice is in it)"; else bad "B: the migration notice is not in the captured output, so the leak check reads nothing"; fi
if has "$B/install.log" "$MARK"; then bad "B: the install output contains the password"; else ok "B: the install output does not contain the password"; fi

echo "-- C. an enc2: value is left alone --"
C="${WORK}/C"; mkdir -p "$C/hm/.ostler/assistant-config"
printf '[channels.email]\nenabled = true\npassword = "enc2:00aa11bb"\nallowed_senders = []\n' > "$(cfg_of "$C")"
run_region "$C" OLD_CONFIG=1 CHANNEL_EMAIL_ENABLED=false CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false
if has "$(cfg_of "$C")" 'password = "enc2:00aa11bb"'; then ok "C: enc2 ciphertext kept in config.toml"; else bad "C: enc2 ciphertext was rewritten"; fi
if [ -e "$(sec_of "$C")" ]; then bad "C: a secrets file was invented from ciphertext"; else ok "C: no secrets file written for ciphertext"; fi

echo "-- D. no email channel: a stale secrets file is removed --"
D="${WORK}/D"; mkdir -p "$D/hm/.ostler/secrets"; printf 'stale' > "$(sec_of "$D")"
run_region "$D" CHANNEL_EMAIL_ENABLED=false CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false
if [ -e "$(sec_of "$D")" ]; then bad "D: a stale mailbox credential survived the channel being removed"; else ok "D: stale secrets file removed"; fi

echo "-- E. awkward characters survive byte for byte --"
E="${WORK}/E"; AWK=' a"b\c$(id)`x` '
run_region "$E" CHANNEL_EMAIL_ENABLED=true CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true CHANNEL_EMAIL_PASSWORD="$AWK"
if [ "$(cat "$(sec_of "$E")" 2>/dev/null; echo x)" = "${AWK}x" ]; then ok "E: quotes, backslash, \$(...) and edge spaces stored exactly"; else bad "E: awkward password altered in storage"; fi
if has "$(cfg_of "$E")" 'c$(id)'; then bad "E: awkward password reached config.toml"; else ok "E: awkward password absent from config.toml"; fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ]
