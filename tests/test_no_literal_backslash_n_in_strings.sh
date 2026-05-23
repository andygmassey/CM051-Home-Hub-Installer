#!/usr/bin/env bash
# Regression guard: no literal "\n" escape sequences inside customer-rendered
# string catalogue VALUES.
#
# bash does NOT interpret \n inside ordinary double-quoted strings, so a
# string like "para one.\n\npara two" renders the four characters \, n, \, n
# verbatim to the customer — not two paragraph breaks. The fix landed in
# PR #151 by replacing \n\n with real LF newlines inside the value. The
# regression caught in Studio retest 2026-05-23 (CX-16, A3) was the same
# pattern resurfacing in MSG_PROMPT_CONSENT_THIRD_PARTY_HELP +
# MSG_PROMPT_EXPORTS_ACK_HELP + MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP +
# MSG_PROMPT_IMESSAGE_ALLOWED_HELP.
#
# This test walks every customer-rendered MSG_* string in every
# *.strings.en-GB.sh file byte-by-byte and refuses any value containing
# the literal two-character sequence backslash-n. Paragraph breaks must
# use real LF (either a multi-line double-quoted value, or $'...' quoting
# which DOES interpret \n).
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse the exact failure shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9 catalogue)
#
# Exit 0 on clean. Exit 1 on any leaked \n literal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CATALOGUES=()
while IFS= read -r -d '' f; do
    CATALOGUES+=("$f")
done < <(find "$REPO_ROOT" -maxdepth 3 -type f -name '*.strings.en-GB.sh' -print0)

if [[ ${#CATALOGUES[@]} -eq 0 ]]; then
    printf 'FAIL: no *.strings.en-GB.sh catalogues found under %s\n' "$REPO_ROOT" >&2
    exit 1
fi

printf 'Scanning %d catalogue(s) for literal \\n inside MSG_* values...\n' "${#CATALOGUES[@]}"

LEAKS=0
for cat in "${CATALOGUES[@]}"; do
    # Walk MSG_*= assignments. The value can span multiple physical lines
    # (a real-LF multi-line string), so we collect lines from the opening
    # MSG_*=" through the closing " before checking the assembled value
    # for the literal two-character \n sequence.
    rel="${cat#${REPO_ROOT}/}"
    # awk state machine: in_msg=1 while inside a MSG_* double-quoted value.
    # Accumulates the raw value (no shell interpretation -- we want the bytes
    # as they sit on disk) and prints any value containing the literal \n.
    leaked=$(awk -v file="$rel" '
        BEGIN { in_msg=0; key=""; value=""; start_ln=0 }
        function escape_count(s,    n, i, prev_bs) {
            # Counts trailing backslashes before the closing quote so we
            # know if a \" inside the value is escaping the quote or
            # ending the string. (Catalogue does not use \" but be safe.)
            n=0
            for (i=length(s); i>=1; i--) {
                if (substr(s, i, 1) == "\\") n++
                else break
            }
            return n
        }
        {
            line=$0
            if (!in_msg) {
                # Look for the start of a MSG_*= double-quoted value.
                if (match(line, /^[[:space:]]*MSG_[A-Z0-9_]*="/)) {
                    in_msg=1
                    start_ln=NR
                    # Extract key
                    eq=index(line, "=")
                    key=substr(line, 1, eq-1)
                    sub(/^[[:space:]]+/, "", key)
                    # Strip everything up to and including the first "
                    value=substr(line, eq+2)
                    # Check if the same line also closes the value.
                    # A double-quoted bash string ends on the next "
                    # that is not escaped. The catalogue rule is no
                    # escaped quotes inside values; so the first " ends it.
                    if (index(value, "\"") > 0) {
                        close_pos=index(value, "\"")
                        body=substr(value, 1, close_pos-1)
                        if (index(body, "\\n") > 0) {
                            printf("%s:%d  %s  ->  %s\n", file, start_ln, key, body)
                        }
                        in_msg=0
                        value=""
                        key=""
                    }
                }
                next
            }
            # Continuation of a multi-line value.
            if (index(line, "\"") > 0) {
                close_pos=index(line, "\"")
                tail=substr(line, 1, close_pos-1)
                value=value "\n" tail
                if (index(value, "\\n") > 0) {
                    printf("%s:%d  %s  ->  (multi-line) %s\n", file, start_ln, key, value)
                }
                in_msg=0
                value=""
                key=""
            } else {
                value=value "\n" line
            }
        }
    ' "$cat") || true
    if [[ -n "$leaked" ]]; then
        printf '\nFAIL: literal \\n leak(s) in %s:\n%s\n' "$rel" "$leaked" >&2
        LEAKS=$((LEAKS + 1))
    fi
done

if [[ $LEAKS -gt 0 ]]; then
    printf '\nFAIL: %d catalogue(s) contain literal \\n in customer strings.\n' "$LEAKS" >&2
    printf 'Fix: replace \\n\\n with real LF (close the quote, newline, reopen on next line),\n' >&2
    printf 'or use $'\''...'\'' quoting which interprets escape sequences.\n' >&2
    exit 1
fi

printf 'PASS: no literal \\n sequences inside MSG_* values.\n'
exit 0
