#!/usr/bin/env bash
# CX-18 regression guard (Studio retest #13, 2026-05-23):
# Q20 "Ready to install?" body must NOT duplicate the headline + MUST
# render INSTALL as bold + terms as a clickable link.
#
# The bug shape caught in retest #13:
#   QUESTION 20
#   Ready to install?
#
#   Ready to install. By clicking Install Ostler, you confirm you accept the terms.
#                ^^^ duplicate of the headline. "terms" plain text. "INSTALL" plain text.
#
# Fix shape (this file refuses regressions):
#   - body MUST NOT contain the literal substring "Ready to install" (the
#     headline phrase). The body should be the new "Please type INSTALL
#     to confirm..." copy.
#   - body composition MUST include an INSTALL run for the bold token
#     (consent_install_body_install_token) so the SwiftUI renderer can
#     mark it stronglyEmphasized.
#   - body composition MUST include a terms run for the link
#     (consent_install_terms_link_label) AND a URL for it
#     (consent_install_terms_url).
#   - the catalogue MUST live in ViewCopy.json (Rule 0.9: customer
#     strings catalogue-keyed from day one).
#
# Walk: JSON parse of ViewCopy.json + byte assertions on each composed
# run. Failure modes are spelled out as concrete asserts, not a generic
# "looks ok" pass.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse the EXACT shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VIEWCOPY="${REPO_ROOT}/gui/OstlerInstaller/Resources/ViewCopy.json"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
SWIFT_VIEW="${REPO_ROOT}/gui/OstlerInstaller/Views/OnboardingQuestionView.swift"

for f in "$VIEWCOPY" "$STRINGS" "$SWIFT_VIEW"; do
    if [[ ! -f "$f" ]]; then
        printf 'FAIL: required file missing: %s\n' "$f" >&2
        exit 1
    fi
done

# Read the five composed body runs out of ViewCopy.json.
# python3 is in the macOS base image; no third-party deps.
read_key() {
    local key="$1"
    python3 -c "
import json, sys
d = json.load(open('$VIEWCOPY'))
node = d
for part in '$key'.split('.'):
    if not isinstance(node, dict) or part not in node:
        sys.stderr.write('FAIL: ViewCopy.json key not found: $key\n')
        sys.exit(2)
    node = node[part]
if not isinstance(node, str):
    sys.stderr.write('FAIL: ViewCopy.json key is not a string: $key\n')
    sys.exit(2)
sys.stdout.write(node)
"
}

PREFIX="$(read_key 'onboarding_question.consent_install_body_prefix')"
INSTALL_TOKEN="$(read_key 'onboarding_question.consent_install_body_install_token')"
MIDDLE="$(read_key 'onboarding_question.consent_install_body_middle')"
LINK_LABEL="$(read_key 'onboarding_question.consent_install_terms_link_label')"
SUFFIX="$(read_key 'onboarding_question.consent_install_body_suffix')"
TERMS_URL="$(read_key 'onboarding_question.consent_install_terms_url')"

# Composed body = the five runs concatenated, as the customer reads them.
COMPOSED="${PREFIX}${INSTALL_TOKEN}${MIDDLE}${LINK_LABEL}${SUFFIX}"

printf 'Q20 composed body: %s\n' "$COMPOSED"

# Assertion 1: composed body MUST NOT contain the duplicated-headline phrase.
# The headline is the Q20 prompt title "Ready to install?". The retest #13
# regression literally repeated "Ready to install" in the body. Refuse it.
if [[ "$COMPOSED" == *"Ready to install"* ]]; then
    printf 'FAIL: Q20 composed body still contains the duplicated headline phrase "Ready to install": %s\n' \
        "$COMPOSED" >&2
    exit 1
fi
printf 'PASS: Q20 body does not duplicate the "Ready to install" headline\n'

# Assertion 2: the install_token MUST be the literal string "INSTALL".
# The SwiftUI renderer marks this run as .stronglyEmphasized (bold). If
# the token is empty or anything other than "INSTALL" the visual emphasis
# would land on the wrong word.
if [[ "$INSTALL_TOKEN" != "INSTALL" ]]; then
    printf 'FAIL: consent_install_body_install_token must be exactly "INSTALL", got %q\n' \
        "$INSTALL_TOKEN" >&2
    exit 1
fi
printf 'PASS: install_token is exactly INSTALL (renders bold via .stronglyEmphasized)\n'

# Assertion 3: the link_label MUST be a non-empty string.
# Rendered as an underlined Oxblood link in the SwiftUI view; an empty
# label would mean no clickable affordance at all.
if [[ -z "$LINK_LABEL" ]]; then
    printf 'FAIL: consent_install_terms_link_label is empty -- terms link would have no clickable text\n' >&2
    exit 1
fi
printf 'PASS: link_label is non-empty (%q)\n' "$LINK_LABEL"

# Assertion 4: the terms URL MUST be an https:// URL pointing at ostler.ai.
# Anything else (http, missing scheme, third-party host) would be a
# regression -- the link is the customer's legal-acceptance contract.
if [[ "$TERMS_URL" != https://ostler.ai/* ]]; then
    printf 'FAIL: consent_install_terms_url must be https://ostler.ai/..., got %q\n' \
        "$TERMS_URL" >&2
    exit 1
fi
printf 'PASS: terms_url is %q\n' "$TERMS_URL"

# Assertion 5: install.sh-side MSG_PROMPT_CONSENT_INSTALL_HELP (the TTY
# fallback) must also not duplicate the headline. TTY installers read
# this string directly without the SwiftUI runs.
TTY_HELP="$(awk -F'=' '/^MSG_PROMPT_CONSENT_INSTALL_HELP=/ { sub(/^"/, "", $2); sub(/"$/, "", $2); print $2; exit }' "$STRINGS")"
if [[ -z "$TTY_HELP" ]]; then
    printf 'FAIL: could not extract MSG_PROMPT_CONSENT_INSTALL_HELP from %s\n' "$STRINGS" >&2
    exit 1
fi
if [[ "$TTY_HELP" == *"Ready to install"* ]]; then
    printf 'FAIL: TTY-side MSG_PROMPT_CONSENT_INSTALL_HELP still duplicates the "Ready to install" headline: %q\n' \
        "$TTY_HELP" >&2
    exit 1
fi
printf 'PASS: TTY MSG_PROMPT_CONSENT_INSTALL_HELP also does not duplicate headline\n'

# Assertion 6: the SwiftUI consentInstallBody() renderer MUST be
# composing the five-run shape. If a future refactor reverts to the
# old prefix+link+suffix three-run shape, the bold INSTALL emphasis is
# lost. Walk the source file for the five ViewCopy lookups.
REQUIRED_KEYS=(
    "onboarding_question.consent_install_body_prefix"
    "onboarding_question.consent_install_body_install_token"
    "onboarding_question.consent_install_body_middle"
    "onboarding_question.consent_install_terms_link_label"
    "onboarding_question.consent_install_body_suffix"
)
MISSING=0
for key in "${REQUIRED_KEYS[@]}"; do
    if ! grep -q -F "\"$key\"" "$SWIFT_VIEW"; then
        printf 'FAIL: OnboardingQuestionView.swift no longer references ViewCopy key %s\n' "$key" >&2
        MISSING=$((MISSING + 1))
    fi
done
if (( MISSING > 0 )); then
    printf 'FAIL: SwiftUI renderer is missing %d of the 5 consent_install body runs\n' "$MISSING" >&2
    exit 1
fi
printf 'PASS: SwiftUI consentInstallBody() composes all 5 runs (prefix + bold token + middle + link + suffix)\n'

# Assertion 7: the SwiftUI renderer MUST mark the install_token run
# .stronglyEmphasized (bold) -- otherwise the bold styling is silently
# lost.
if ! grep -q "inlinePresentationIntent.*stronglyEmphasized" "$SWIFT_VIEW"; then
    printf 'FAIL: SwiftUI renderer does not mark any run .stronglyEmphasized; bold INSTALL emphasis is missing\n' >&2
    exit 1
fi
printf 'PASS: SwiftUI renderer marks at least one run .stronglyEmphasized (bold)\n'

printf '\nALL Q20 CONSENT-INSTALL BODY SHAPE TESTS PASSED\n'
