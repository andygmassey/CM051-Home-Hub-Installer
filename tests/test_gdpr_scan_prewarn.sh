#!/usr/bin/env bash
# Regression guard (CX-18, 2026-05-23):
# install.sh MUST emit MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING BEFORE
# the find-scan that triggers Downloads / Desktop / Documents
# macOS folder-access prompts.
#
# Studio retest #13 (2026-05-23): customer hit three unannounced
# macOS folder-access prompts back-to-back during the GDPR scan
# with no on-screen explanation of why their Mac suddenly wanted
# permission to read all three folders. CX-18 fix adds a structured
# info line before the find-scan so the Log drawer + GUI spinner
# caption explain what is about to happen.
#
# Per locked memory feedback_silent_bail_regression_test_shape:
# byte-walk install.sh asserting the prewarn line appears BEFORE
# the GDPR scan block. A happy-path test ("does install.sh emit
# the new key somewhere?") would pass even if a future refactor
# moved the prewarn line AFTER the scan (defeating the entire
# point). Pin the ORDER, not just the presence.
#
# Per Rule 0.9 (feedback_customer_strings_extractable_from_day_one):
# the prewarn string must be a catalogue key, not an inline literal.
# Walk the catalogue too.
#
# Exit 0 on clean. Exit 1 on order violation, missing emit, or
# missing catalogue key.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_SH="${REPO_ROOT}/install.sh"
CATALOGUE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    printf 'FAIL: install.sh not found at %s\n' "$INSTALL_SH" >&2
    exit 1
fi
if [[ ! -f "$CATALOGUE" ]]; then
    printf 'FAIL: install.sh.strings.en-GB.sh not found at %s\n' "$CATALOGUE" >&2
    exit 1
fi

KEY="MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING"

# 1. Catalogue presence (Rule 0.9).
if ! grep -q "^${KEY}=" "$CATALOGUE"; then
    printf 'FAIL: catalogue key %s is missing from install.sh.strings.en-GB.sh\n' "$KEY" >&2
    printf '      Per Rule 0.9 the prewarn string must be catalogue-keyed (extractable from day one).\n' >&2
    printf '      Add a line of the form:\n' >&2
    printf '        %s="..."\n' "$KEY" >&2
    exit 1
fi

# 2. install.sh emits the key (presence).
if ! grep -q "\$${KEY}" "$INSTALL_SH"; then
    printf 'FAIL: install.sh does not reference $%s\n' "$KEY" >&2
    printf '      Studio retest #13 fix requires the prewarn line BEFORE the GDPR find-scan.\n' >&2
    exit 1
fi

# 3. ORDER: the prewarn line must appear BEFORE the GDPR scan
# block. The scan block is anchored by either the existing
# `MSG_INFO_SCANNING_GDPR_DATA_EXPORTS` gui_log line OR by the
# `for search_dir in` loop that runs the find-scan. We check the
# earliest of those two anchors.
EMIT_LINE=$(grep -n "\$${KEY}" "$INSTALL_SH" | head -1 | cut -d: -f1)
SCAN_LINE=$(grep -nE 'MSG_INFO_SCANNING_GDPR_DATA_EXPORTS|^for search_dir in' "$INSTALL_SH" | head -1 | cut -d: -f1)

if [[ -z "$EMIT_LINE" ]] || [[ -z "$SCAN_LINE" ]]; then
    printf 'FAIL: could not locate emit-line (%s) or scan-anchor (%s) inside install.sh\n' \
        "${EMIT_LINE:-MISSING}" "${SCAN_LINE:-MISSING}" >&2
    exit 1
fi

if (( EMIT_LINE >= SCAN_LINE )); then
    printf 'FAIL: $%s emit at line %d appears AT or AFTER the GDPR scan anchor at line %d\n' \
        "$KEY" "$EMIT_LINE" "$SCAN_LINE" >&2
    printf '      The CX-18 fix requires the prewarn copy to appear BEFORE the find-scan.\n' >&2
    printf '      A regression that moves the emit below the scan defeats the entire fix\n' >&2
    printf '      (customer sees folder-access popups before the explainer copy).\n' >&2
    exit 1
fi

printf 'PASS: $%s emitted at line %d, BEFORE GDPR scan anchor at line %d.\n' \
    "$KEY" "$EMIT_LINE" "$SCAN_LINE"
exit 0
