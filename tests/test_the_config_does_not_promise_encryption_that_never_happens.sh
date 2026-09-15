#!/usr/bin/env bash
# THE CUSTOMER'S OWN CONFIG FILE MUST NOT LIE TO THEM ABOUT THEIR PASSWORD.
#
# THE DEFECT, measured 2026-09-16 on origin/main.
#
#   install.sh wrote this into ~/.ostler/assistant-config/config.toml, a file
#   the customer is invited by the same paragraph to open and edit:
#
#       Sensitive fields (e.g. email password) are stored in plaintext until
#       the assistant first runs and encrypts them in place with the `enc2:`
#       ChaCha20-Poly1305 scheme.
#
#   Eleven lines below that sentence it wrote their actual email password, in
#   plain text.
#
#   Nothing encrypts it. Ever. install.sh's own 3.14e block says so from the
#   other direction: the secrets store "auto-migrates legacy enc: values to
#   enc2: on read but does not bootstrap from plaintext". The only route that
#   would have closed it was a proposed `ostler-assistant secrets
#   encrypt-config` step, and `encrypt-config` had exactly ONE match in the
#   whole repo: the comment proposing it. CONTROLS, same file, same command
#   shape: `doctor` 93 matches, `allow-plaintext` 17. The search worked.
#
#   So the customer was told their password protects itself, and made a
#   decision about which password to give us on that basis.
#
# WHAT WAS DONE, and it is the smaller of the two options ON PURPOSE. The
# encryption is a Rust change in ostler-assistant (key derivation lives in
# crates/zeroclaw-config/src/secrets.rs, with no subcommand exposing it), so
# it cannot land in an install.sh PR. It is filed as issue #1976 with file
# and line. What landed here is the truth, in the file the customer reads,
# plus the one mitigation actually available to them today: an app-specific
# password, which is revocable on its own and cannot be used to sign in.
#
# THIS TEST RENDERS THE PREAMBLE AND READS IT. It does not grep install.sh:
# the preamble sits inside a quoted heredoc, and a source grep cannot tell a
# line that ships from a line that is commented out beside it.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# EXTRACT FROM THE `cat <<` LINE, NOT FROM THE CLOSING DELIMITER.
# The sibling suite (tests/test_whatsapp_channel_block.sh) starts its capture
# at /^TOMLPREAMBLE$/, which is the heredoc's CLOSING line, so the preamble
# itself is outside what it extracts. That is fine for a test about the
# whatsapp block and useless for a test about the preamble: the first version
# of this file copied that extraction and rendered a config with no preamble
# in it, which the arm-0 control caught. Start one heredoc earlier.
EMITTER="${WORK}/emitter.sh"
awk '
    /^[[:space:]]*cat <<.TOMLPREAMBLE.$/     { capture = 1 }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "$SUBJECT" > "$EMITTER"
if [ ! -s "$EMITTER" ] || ! bash -n "$EMITTER" 2>/dev/null; then
    echo "CANNOT-RUN: could not extract a parseable TOML emitter from ${SUBJECT}." >&2
    exit 2
fi

# Render the config a customer who gave an email password actually receives.
# The password value is a synthetic marker, never a real credential.
MARKER="synthetic-not-a-real-password-fixture"
OUT="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=true \
    CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true \
    CHANNEL_EMAIL_APPLE_MAIL_ENABLED=false \
    CHANNEL_EMAIL_PASSWORD="$MARKER" \
    CHANNEL_EMAIL_USERNAME="someone@example.invalid" \
    CHANNEL_EMAIL_FROM="someone@example.invalid" \
    CHANNEL_EMAIL_IMAP_HOST="imap.example.invalid" \
    CHANNEL_EMAIL_SMTP_HOST="smtp.example.invalid" \
    CHANNEL_EMAIL_IMAP_PORT=993 CHANNEL_EMAIL_SMTP_PORT=465 \
    CHANNEL_EMAIL_IMAP_FOLDER="INBOX" \
    USER_TZ="Europe/London" \
    OSTLER_DIR="${WORK}/ostler" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

printf 'THE CONFIG DOES NOT PROMISE ENCRYPTION THAT NEVER HAPPENS\n\n'

echo "-- 0. CONTROL: the render really produced the file under test --"
# Two independent controls. The preamble must be there AND the password must
# be there, because the assertion below is about a sentence that sits beside
# a plaintext password. If either is missing this test is aimed at nothing.
if ! /usr/bin/grep -q 'Ostler assistant configuration' <<< "$OUT"; then
    echo "CANNOT-RUN: the rendered config has no preamble." >&2
    exit 2
fi
if ! /usr/bin/grep -qF "password = \"${MARKER}\"" <<< "$OUT"; then
    echo "CANNOT-RUN: the rendered config carries no plaintext password, so the" >&2
    echo "  sentence under test would have nothing to be a lie about." >&2
    echo "  This is the arm that must not be allowed to pass vacuously." >&2
    exit 2
fi
ok "the rendered config carries BOTH the preamble and a plaintext password field"

echo "-- 1. THE MEASURED DEFECT: no claim that the password encrypts itself --"
# Match on the CLAIM, not on one phrasing of it. Each pattern below is a way
# of asserting a future encryption that does not happen.
LIES=0; LIE_TEXT=""
while IFS= read -r line; do
    case "$line" in
        *"until the assistant first runs and"*) LIES=$((LIES+1)); LIE_TEXT="${LIE_TEXT}|${line}" ;;
        *"encrypts them in place"*)             LIES=$((LIES+1)); LIE_TEXT="${LIE_TEXT}|${line}" ;;
        *"will be encrypted"*)                  LIES=$((LIES+1)); LIE_TEXT="${LIE_TEXT}|${line}" ;;
        *"encrypted on first run"*)             LIES=$((LIES+1)); LIE_TEXT="${LIE_TEXT}|${line}" ;;
    esac
done <<< "$OUT"
if [ "$LIES" -eq 0 ]; then
    ok "the config makes no promise that the password encrypts itself later"
else
    bad "${LIES} line(s) still promise an encryption that never happens:${LIE_TEXT}"
fi

echo "-- 2. and it says what IS true, so the silence is not the fix --"
# Removing the false sentence and saying nothing would leave the customer
# with a plaintext password and no idea. Three things they need.
_said() { /usr/bin/grep -qi "$1" <<< "$OUT"; }
if _said 'plain text' || _said 'plaintext'; then
    ok "it states the password is in plain text"
else
    bad "the false promise went and nothing replaced it; the customer is told nothing"
fi
if _said '0600'; then
    ok "it names the protection that actually exists (mode 0600)"
else
    bad "it does not tell the customer what IS protecting the password"
fi
if _said 'app-specific password'; then
    ok "it names the mitigation available to them today"
else
    bad "the customer is told the risk and given no action they can take"
fi

echo "-- 3. the engineering comments agree with what the customer is told --"
# The two halves of install.sh disagreed for the life of the file: one said
# the daemon encrypts on first run, the other said it cannot bootstrap from
# plaintext. Only one of them could be right.
_bootstrap="$(/usr/bin/grep -c 'does NOT bootstrap from plaintext' "$SUBJECT" || true)"
_issue="$(/usr/bin/grep -c 'issue #1976' "$SUBJECT" || true)"
if [ "${_bootstrap:-0}" -ge 1 ]; then
    ok "install.sh states the daemon does not bootstrap from plaintext"
else
    bad "the constraint that makes this a defect is no longer stated anywhere"
fi
if [ "${_issue:-0}" -ge 2 ]; then
    ok "the follow-up is filed and cited at both sites (${_issue} citations)"
else
    bad "the implementation follow-up is cited ${_issue} time(s); a deferral nobody can find is a deferral nobody does"
fi

echo "-- 4. MUTATION: put the old sentence back and arm 1 MUST fail --"
MUT="${WORK}/emitter_mutant.sh"
/usr/bin/sed 's|^# Your email password is in this file, in plain text, and it STAYS$|# are stored in plaintext until the assistant first runs and encrypts them in place.|' \
    "$EMITTER" > "$MUT"
if [ "$(/usr/bin/grep -c 'until the assistant first runs and encrypts them in place' "$MUT" || true)" -lt 1 ]; then
    bad "MUTATION DID NOT APPLY, so the arm below proves nothing"
else
    ok "the mutant really carries the original claim (the injection landed)"
    OUT_MUT="$(
        CHANNEL_IMESSAGE_ENABLED=false CHANNEL_WHATSAPP_ENABLED=false \
        CHANNEL_EMAIL_ENABLED=false USER_TZ="Europe/London" \
        OSTLER_DIR="${WORK}/ostler_mut" bash -c "$(cat "$MUT")" 2>&1
    )"
    if /usr/bin/grep -q 'until the assistant first runs and' <<< "$OUT_MUT"; then
        ok "MUST-FAIL: the predicate in arm 1 does see the original claim when it is present"
    else
        bad "the predicate could not see the original claim; arm 1 is guarding nothing"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
