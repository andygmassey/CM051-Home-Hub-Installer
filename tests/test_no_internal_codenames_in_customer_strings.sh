#!/usr/bin/env bash
# Regression guard: no internal CM[0-9]{3} project code names inside
# customer-rendered string catalogue VALUES.
#
# "CM048", "CM024", "CM041", etc. are internal Creative Machines project
# identifiers. They are useful in code, comments, env-var names, key
# names, directory paths, and developer --help output, but they MUST
# NOT appear in any string that the customer sees rendered in the GUI
# or the spinner status / step heading / info / warn / fail output.
#
# Trigger: 2026-05-23 Studio retest CX-16 surfaced "(CM048)" in the
# step heading "Setting up conversation processing pipeline (CM048)"
# and "Installing CM048 pipeline into venv..." in the spinner status.
# Andy: "CM048 is an internal code name and MUST NEVER appear in
# customer copy."
#
# This test walks every MSG_* assignment in every *.strings.en-GB.sh
# catalogue and refuses any VALUE containing the case-sensitive
# substring CM followed by exactly three digits. Key NAMES are allowed
# to keep the codename (they are developer identifiers).
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse the exact failure shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9 catalogue)
#
# Exit 0 on clean. Exit 1 on any leaked codename.

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

printf 'Scanning %d catalogue(s) for CM[0-9]{3} in MSG_* values...\n' "${#CATALOGUES[@]}"

LEAKS=0
for cat in "${CATALOGUES[@]}"; do
    rel="${cat#${REPO_ROOT}/}"
    # awk state machine: in_msg=1 while inside a MSG_* double-quoted value.
    # Accumulates the raw value across line continuations and flags any
    # occurrence of CM followed by exactly three digits in the assembled value.
    leaked=$(awk -v file="$rel" '
        BEGIN { in_msg=0; key=""; value=""; start_ln=0 }
        function flag_check(body) {
            if (match(body, /CM[0-9][0-9][0-9]/)) {
                printf("%s:%d  %s  ->  %s\n", file, start_ln, key, body)
            }
        }
        {
            line=$0
            if (!in_msg) {
                if (match(line, /^[[:space:]]*MSG_[A-Z0-9_]*="/)) {
                    in_msg=1
                    start_ln=NR
                    eq=index(line, "=")
                    key=substr(line, 1, eq-1)
                    sub(/^[[:space:]]+/, "", key)
                    value=substr(line, eq+2)
                    if (index(value, "\"") > 0) {
                        close_pos=index(value, "\"")
                        body=substr(value, 1, close_pos-1)
                        flag_check(body)
                        in_msg=0; value=""; key=""
                    } else {
                        # Continues on next line; seed accumulator.
                        value=value
                    }
                }
                next
            }
            if (index(line, "\"") > 0) {
                close_pos=index(line, "\"")
                tail=substr(line, 1, close_pos-1)
                value=value "\n" tail
                flag_check(value)
                in_msg=0; value=""; key=""
            } else {
                value=value "\n" line
            }
        }
    ' "$cat") || true
    if [[ -n "$leaked" ]]; then
        printf '\nFAIL: internal codename leak(s) in %s:\n%s\n' "$rel" "$leaked" >&2
        LEAKS=$((LEAKS + 1))
    fi
done

if [[ $LEAKS -gt 0 ]]; then
    printf '\nFAIL: %d catalogue(s) expose internal CM[0-9]{3} codenames in customer strings.\n' "$LEAKS" >&2
    printf 'Fix: rename the codename to layperson-friendly framing inside the VALUE.\n' >&2
    printf 'Key names can keep the codename (they are developer identifiers).\n' >&2
    exit 1
fi

printf 'PASS: no internal CM[0-9]{3} codenames in MSG_* values.\n'
exit 0
