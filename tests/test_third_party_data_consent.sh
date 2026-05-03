#!/usr/bin/env bash
# Sanity test for the third-party-data acknowledgement screen added
# in /tmp/tnm_brief_three_caveats_2026-05-03.md § Caveat 1 (Piece 2).
#
# The screen is region-agnostic. Mirrors Article 9's decline behaviour
# (rm -rf ~/.ostler/ + exit). The wording itself is verified
# byte-for-byte by HR015's `make check-consent-wording` target;
# this test only asserts the wiring in install.sh.
#
# Asserts:
#   1. install.sh still parses (`bash -n`).
#   2. The third-party-data section header is present.
#   3. The new screen renders region-agnostically (i.e. it lives
#      OUTSIDE the EU branch's `if [[ "$OSTLER_REGION" == "eu" ]]`
#      block but BEFORE "Final install confirmation").
#   4. Decline path runs `rm -rf "$OSTLER_DIR"` and exits 0.
#   5. Phase 3 consent_cli persists the
#      `third_party_data_personal_records` tickbox using the
#      OSTLER_CONSENT_THIRD_PARTY_DECISION variable.
#
# Sister test for the existing region-aware consent gates lives in
# tests/test_consent_a7_a8.sh and is independent of this file.

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

# 2. Section header present
if ! grep -q '^# ── 10b\.5 Third-party-data acknowledgement (every region)' "$INSTALL_SH"; then
    printf 'FAIL: third-party-data section header not found\n' >&2
    exit 1
fi
printf 'PASS: third-party-data section header present\n'

# 3. Region-agnostic placement: the third-party section header must
#    appear AFTER the EU branch's closing `fi` and BEFORE the final
#    install confirmation. Extract line numbers, compare order.
HEADER_3RD=$(grep -n '^# ── 10b\.5 Third-party-data' "$INSTALL_SH" | cut -d: -f1 | head -1)
HEADER_FINAL=$(grep -n '^# ── 10c\. Final install confirmation' "$INSTALL_SH" | cut -d: -f1 | head -1)
HEADER_REGION=$(grep -n '^# ── 10\. Consent' "$INSTALL_SH" | cut -d: -f1 | head -1)

if [[ -z "$HEADER_3RD" || -z "$HEADER_FINAL" || -z "$HEADER_REGION" ]]; then
    printf 'FAIL: could not locate one of the three section headers\n' >&2
    exit 1
fi

if (( HEADER_REGION >= HEADER_3RD )); then
    printf 'FAIL: third-party section (%s) must come AFTER region-consent section (%s)\n' \
        "$HEADER_3RD" "$HEADER_REGION" >&2
    exit 1
fi
if (( HEADER_3RD >= HEADER_FINAL )); then
    printf 'FAIL: third-party section (%s) must come BEFORE final install confirmation (%s)\n' \
        "$HEADER_3RD" "$HEADER_FINAL" >&2
    exit 1
fi
printf 'PASS: third-party section is between region consent and final confirmation\n'

# Confirm the new screen is NOT inside the EU-only branch by checking
# the `fi` that closes the EU branch falls between the WhatsApp/voice
# block and our new section. The EU branch closes at the first `fi`
# at column 0 after the voice gate.
EU_BRANCH_CLOSE=$(awk '
    /^if \[\[ "\$OSTLER_REGION" == "eu" \]\]; then$/ { in_eu=1 }
    in_eu && /^fi$/ { print NR; exit }
' "$INSTALL_SH")

if [[ -z "$EU_BRANCH_CLOSE" ]]; then
    printf 'FAIL: could not locate the EU branch closing fi\n' >&2
    exit 1
fi
if (( EU_BRANCH_CLOSE >= HEADER_3RD )); then
    printf 'FAIL: EU branch close (%s) must come BEFORE third-party section (%s); section appears EU-gated\n' \
        "$EU_BRANCH_CLOSE" "$HEADER_3RD" >&2
    exit 1
fi
printf 'PASS: third-party section sits OUTSIDE the EU-only branch (region-agnostic)\n'

# 4. Decline path runs `rm -rf "$OSTLER_DIR"` and exits 0.
#    Extract the third-party block (header to next `# ── 10c` line)
#    and verify the decline branch.
TMP_BLOCK="$(mktemp)"
trap 'rm -f "$TMP_BLOCK"' EXIT
awk -v start="$HEADER_3RD" -v end="$HEADER_FINAL" 'NR >= start && NR < end' "$INSTALL_SH" > "$TMP_BLOCK"

if ! grep -q 'OSTLER_CONSENT_THIRD_PARTY_DECISION="declined"' "$TMP_BLOCK"; then
    printf 'FAIL: third-party block missing decline-decision assignment\n' >&2
    exit 1
fi
if ! grep -q 'rm -rf "\$OSTLER_DIR"' "$TMP_BLOCK"; then
    printf 'FAIL: third-party block missing rm -rf $OSTLER_DIR on decline\n' >&2
    exit 1
fi
if ! grep -q '^[[:space:]]*exit 0$' "$TMP_BLOCK"; then
    printf 'FAIL: third-party decline does not exit 0\n' >&2
    exit 1
fi
printf 'PASS: decline path wipes $OSTLER_DIR and exits 0\n'

# 5. Phase 3 consent_cli persistence: the tickbox id must match the
#    Python source of truth (legal/consent_strings.py) and the
#    decision env var must thread through correctly.
if ! grep -q -- '--tickbox third_party_data_personal_records' "$INSTALL_SH"; then
    printf 'FAIL: install.sh does not record the third-party tickbox via consent_cli\n' >&2
    exit 1
fi
if ! grep -q -- '--decision "$OSTLER_CONSENT_THIRD_PARTY_DECISION"' "$INSTALL_SH"; then
    printf 'FAIL: install.sh consent_cli call does not use OSTLER_CONSENT_THIRD_PARTY_DECISION\n' >&2
    exit 1
fi
printf 'PASS: Phase 3 consent_cli wires the third-party tickbox id and decision env var\n'

printf '\nALL THIRD-PARTY-DATA CONSENT TESTS PASSED\n'
