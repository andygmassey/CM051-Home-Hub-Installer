#!/usr/bin/env bash
# Sanity test for the A7+A8 region-aware consent gates added in
# /tmp/plan_legal_position_implementation_2026-05-02.md.
#
# Asserts:
#   1. install.sh parses (`bash -n`)
#   2. _classify_region function is present and classifies the
#      key codes correctly for each region.
#   3. WhatsApp option 5 is present in the channel wizard menu.
#   4. The Article 9 wording block is present and EU-gated.
#   5. The EU voice-consent gate is present and EU-gated.
#   6. The Phase 3 consent_cli hand-off is present and uses the
#      correct tickbox ids from legal/consent_strings.py.
#   7. Decline path on Article 9 wipes ~/.ostler/ before exit.
#   8. The OSTLER_REGION_OVERRIDE env var is the highest-priority signal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    printf 'FAIL: install.sh not found at %s\n' "$INSTALL_SH" >&2
    exit 1
fi

# 1. Parse check
if ! bash -n "$INSTALL_SH"; then
    printf 'FAIL: install.sh fails bash -n parse check\n' >&2
    exit 1
fi
printf 'PASS: install.sh parses\n'

# 2. Region classifier behaviour.
TMP_FN="$(mktemp)"
awk '
    /^_classify_region\(\) {/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
' "$INSTALL_SH" > "$TMP_FN"

if [[ ! -s "$TMP_FN" ]]; then
    printf 'FAIL: could not extract _classify_region from install.sh\n' >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$TMP_FN"

assert_region() {
    local iso="$1" expected="$2"
    local got
    got=$(_classify_region "$iso")
    if [[ "$got" != "$expected" ]]; then
        printf 'FAIL: _classify_region(%s) = %s, expected %s\n' "$iso" "$got" "$expected" >&2
        exit 1
    fi
}

assert_region "GB" "uk"
assert_region "UK" "uk"
assert_region "US" "us"
assert_region "DE" "eu"
assert_region "FR" "eu"
assert_region "ES" "eu"
assert_region "IS" "eu"     # EEA
assert_region "CH" "eu"     # treat-as-EU
assert_region "NO" "eu"     # EEA
assert_region "JP" "row"
assert_region "ZZ" "row"    # ISO unknown 2-letter
assert_region "" "eu"       # empty -> default-EU policy

rm -f "$TMP_FN"
printf 'PASS: _classify_region returns the right bucket per region\n'

# 3. WhatsApp option 5 is present in the channel wizard menu.
if ! grep -qE '5\.\s+\+\s+WhatsApp' "$INSTALL_SH"; then
    printf 'FAIL: WhatsApp option 5 missing from channel wizard\n' >&2
    exit 1
fi
if ! grep -q 'CHANNEL_WHATSAPP_ENABLED=' "$INSTALL_SH"; then
    printf 'FAIL: CHANNEL_WHATSAPP_ENABLED variable not declared\n' >&2
    exit 1
fi
if ! grep -q 'CHANNEL_WHATSAPP_CONSENT_ACCEPTED' "$INSTALL_SH"; then
    printf 'FAIL: CHANNEL_WHATSAPP_CONSENT_ACCEPTED variable not declared\n' >&2
    exit 1
fi
printf 'PASS: WhatsApp option 5 + tickbox vars present\n'

# 4. Article 9 EU consent screen present and gated on OSTLER_REGION == eu.
if ! grep -qF 'One last thing – what Ostler will look at on your Mac' "$INSTALL_SH"; then
    printf 'FAIL: Article 9 wording block missing\n' >&2
    exit 1
fi
if ! grep -q 'OSTLER_REGION" == "eu"' "$INSTALL_SH"; then
    printf 'FAIL: Article 9 block not gated on OSTLER_REGION == eu\n' >&2
    exit 1
fi
if ! grep -q 'OSTLER_CONSENT_ARTICLE_9_DECISION=' "$INSTALL_SH"; then
    printf 'FAIL: OSTLER_CONSENT_ARTICLE_9_DECISION variable not initialised\n' >&2
    exit 1
fi
printf 'PASS: Article 9 EU screen present and EU-gated\n'

# 5. EU voice gate present.
if ! grep -qF 'Recognising voices on calls' "$INSTALL_SH"; then
    printf 'FAIL: EU voice-consent block missing\n' >&2
    exit 1
fi
if ! grep -q 'OSTLER_CONSENT_VOICE_EU_DECISION=' "$INSTALL_SH"; then
    printf 'FAIL: OSTLER_CONSENT_VOICE_EU_DECISION variable not initialised\n' >&2
    exit 1
fi
printf 'PASS: EU voice consent gate present\n'

# 6. consent_cli hand-off in Phase 3.
# Matches either the legacy in-line form (`--tickbox <id>`) or the
# helper-refactored form (`_consent_cli_record <mode> <id>` -- the
# id appears as a positional arg on its own indented line).
# Audit ref /tmp/silent_fail_audit_2026-05-04.md HIGH-3.
for tickbox in article_9_special_category_consent whatsapp_unofficial_risk voice_speaker_id_eu; do
    if ! grep -qE "(tickbox $tickbox|^[[:space:]]+$tickbox[[:space:]]*\\\\?[[:space:]]*\$)" "$INSTALL_SH"; then
        printf 'FAIL: consent_cli hand-off missing tickbox %s\n' "$tickbox" >&2
        exit 1
    fi
done
if ! grep -q 'ostler_security.consent_cli' "$INSTALL_SH"; then
    printf 'FAIL: install.sh never invokes ostler_security.consent_cli\n' >&2
    exit 1
fi
printf 'PASS: Phase 3 consent_cli hand-off wires all three tickboxes\n'

# 7. Decline path on Article 9 wipes ~/.ostler/.
EU_BLOCK=$(awk '
    /OSTLER_REGION" == "eu"/ { in_block=1; print; next }
    in_block && /^# ── 10c\./ { exit }
    in_block { print }
' "$INSTALL_SH")

if [[ -z "$EU_BLOCK" ]]; then
    printf 'FAIL: could not isolate EU consent block\n' >&2
    exit 1
fi
if ! printf '%s\n' "$EU_BLOCK" | grep -q 'rm -rf "$OSTLER_DIR"'; then
    printf 'FAIL: Article 9 decline path does not wipe ~/.ostler/\n' >&2
    exit 1
fi
if ! printf '%s\n' "$EU_BLOCK" | grep -q 'declined'; then
    printf 'FAIL: declined record not assigned in EU decline branch\n' >&2
    exit 1
fi
printf 'PASS: Article 9 decline path wipes ~/.ostler/ residue\n'

# 8. Manual override is honoured.
if ! grep -q 'OSTLER_REGION_OVERRIDE' "$INSTALL_SH"; then
    printf 'FAIL: OSTLER_REGION_OVERRIDE not honoured\n' >&2
    exit 1
fi
OVERRIDE_LINE=$(grep -n 'OSTLER_REGION_OVERRIDE' "$INSTALL_SH" | head -1 | cut -d: -f1)
CONTACTS_LINE=$(grep -n 'OSTLER_REGION_ISO=$(_country_to_iso "$DETECTED_COUNTRY"' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [[ -z "$OVERRIDE_LINE" || -z "$CONTACTS_LINE" ]]; then
    printf 'FAIL: could not locate priority-chain lines\n' >&2
    exit 1
fi
if (( OVERRIDE_LINE > CONTACTS_LINE )); then
    printf 'FAIL: OSTLER_REGION_OVERRIDE is read AFTER contacts-country (priority bug)\n' >&2
    exit 1
fi
printf 'PASS: OSTLER_REGION_OVERRIDE honoured at top of priority chain\n'

printf '\nAll A7+A8 consent assertions passed (8/8)\n'
