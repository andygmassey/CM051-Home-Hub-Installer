#!/usr/bin/env bash
# Regression guard: no em-dash (U+2014) and no whitespace-bounded "--"
# em-dash surrogate inside ANY install.sh.strings.*.sh catalogue value.
#
# Gap this closes (w3-emdash-lint, 2026-07-07): the existing punctuation
# lint (gui/OstlerInstallerTests/StringsCatalogueEmDashTest.swift) pins
# the rule for install.sh.strings.en-GB.sh + the two JSON catalogues
# ONLY. The de/fr/es/it catalogues (carried on cutb/i18n-emdash-parity,
# joining the cut lineage as a separate product call) and any future
# locale catalogue were ungated. This test scans EVERY file matching
# install.sh.strings.*.sh so a new locale is gated the day it lands,
# with no test edit required.
#
# The locked rule (`feedback_em_dash_rule_scope`): no em-dash (U+2014,
# "\xe2\x80\x94") and no double-hyphen ASCII fallback ("--") used as
# visual punctuation inside any customer-facing string VALUE. En-dash
# with spaces (" \xe2\x80\x93 ", U+2013) is the canonical replacement.
#
# Semantics mirror the Swift test exactly:
#   - only MSG_* assignment VALUES are checked (key names are developer
#     identifiers; shell comment lines are catalogue metadata);
#   - "--" is flagged only when whitespace-bounded on BOTH sides
#     (start/end of value count as boundaries). CLI flag mentions like
#     `--allow-plaintext` have an alphanumeric adjacent to the second
#     `-` and are NOT flagged. `---` (horizontal-rule style) is NOT
#     flagged either (the character after the pair is `-`);
#   - multi-line values are assembled across continuation lines; the
#     embedded newline counts as whitespace for boundary purposes.
#
# Per feedback_silent_bail_regression_test_shape: the test first proves
# the scanner FIRES on a synthetic offender fixture (so a broken glob
# or a broken awk programme cannot pass vacuously), then requires the
# real catalogue set to be non-empty, then scans it.
#
# Exit 0 on clean. Exit 1 on any offender or on scanner self-test fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EMDASH=$'\xe2\x80\x94'   # U+2014

# scan_catalogue <file> <label>
# Prints one line per offender: "<label>:<line>  <key>  <reason>"
# Returns 0 always; caller counts output lines.
scan_catalogue() {
    local file="$1" label="$2"
    awk -v file="$label" -v emdash="${EMDASH}" '
        BEGIN { in_msg=0; key=""; value=""; start_ln=0 }
        function flag_check(body) {
            if (index(body, emdash) > 0) {
                printf("%s:%d  %s  em-dash U+2014 in value\n", file, start_ln, key)
            }
            # Whitespace-bounded "--" (visual em-dash surrogate).
            # Boundaries: start/end of the assembled value, or any
            # [[:space:]] char (\n from continuation lines included).
            # `---` is not matched: the char after the pair is `-`.
            # CLI flags (`--allow-plaintext`) are not matched: the char
            # after the pair is alphanumeric.
            if (match(body, /(^|[[:space:]])--([[:space:]]|$)/)) {
                printf("%s:%d  %s  whitespace-bounded \"--\" em-dash surrogate in value\n", file, start_ln, key)
            }
        }
        {
            line=$0
            if (!in_msg) {
                # Shell comment / blank / non-assignment lines are
                # catalogue metadata, not customer copy: skip.
                if (match(line, /^[[:space:]]*MSG_[A-Za-z0-9_]*="/)) {
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
    ' "$file"
}

# ── Scanner self-test (non-vacuous guard) ────────────────────────────
# Prove the scanner fires on known offenders and stays quiet on the
# whitelisted shapes before trusting it on the real catalogues.
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "${SELFTEST_DIR}"' EXIT

FIXTURE="${SELFTEST_DIR}/install.sh.strings.zz-ZZ.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf '# comment with an em-dash %s and a bare -- surrogate: both exempt\n' "${EMDASH}"
    printf 'MSG_BAD_EMDASH="value with %s inside"\n' "${EMDASH}"
    printf 'MSG_BAD_SURROGATE="click Install -- this step waits"\n'
    printf 'MSG_BAD_SURROGATE_AT_END="trailing surrogate --"\n'
    printf 'MSG_OK_CLI_FLAG="run with --allow-plaintext to continue"\n'
    printf 'MSG_OK_TRIPLE="a rule --- is not a surrogate"\n'
    printf 'MSG_OK_ENDASH="spaced en-dash \xe2\x80\x93 is the canonical fix"\n'
} > "${FIXTURE}"

selftest_out="$(scan_catalogue "${FIXTURE}" "selftest")"
selftest_hits=0
[[ -n "${selftest_out}" ]] && selftest_hits=$(printf '%s\n' "${selftest_out}" | wc -l | tr -d ' ')

if [[ "${selftest_hits}" -ne 3 ]]; then
    printf 'FAIL: scanner self-test expected exactly 3 offenders, got %s:\n%s\n' \
        "${selftest_hits}" "${selftest_out}" >&2
    printf 'The lint machinery itself is broken; fix the test before trusting a PASS.\n' >&2
    exit 1
fi
if printf '%s\n' "${selftest_out}" | grep -q "MSG_OK_"; then
    printf 'FAIL: scanner self-test flagged a whitelisted shape:\n%s\n' "${selftest_out}" >&2
    exit 1
fi

# ── Collect the real catalogues ──────────────────────────────────────
# All locales, current and future: install.sh.strings.*.sh anywhere in
# the shipping tree. Prune .git, sibling worktrees under .claude, and
# vendored trees (other repos own their own lint).
CATALOGUES=()
while IFS= read -r -d '' f; do
    CATALOGUES+=("$f")
done < <(find "$REPO_ROOT" -maxdepth 3 \
            \( -name .git -o -name .claude -o -name vendor -o -name node_modules \) -prune -o \
            -type f -name 'install.sh.strings.*.sh' -print0 | sort -z)

if [[ ${#CATALOGUES[@]} -eq 0 ]]; then
    printf 'FAIL: no install.sh.strings.*.sh catalogues found under %s\n' "$REPO_ROOT" >&2
    exit 1
fi

has_engb=0
for cat in "${CATALOGUES[@]}"; do
    [[ "$(basename "$cat")" == "install.sh.strings.en-GB.sh" ]] && has_engb=1
done
if [[ ${has_engb} -ne 1 ]]; then
    printf 'FAIL: catalogue glob did not find install.sh.strings.en-GB.sh -- glob or layout broke.\n' >&2
    exit 1
fi

printf 'Scanner self-test OK. Scanning %d catalogue(s) for em-dash / "--" surrogates in MSG_* values...\n' "${#CATALOGUES[@]}"

# ── Scan ─────────────────────────────────────────────────────────────
FAILED=0
for cat in "${CATALOGUES[@]}"; do
    rel="${cat#"${REPO_ROOT}"/}"
    offenders="$(scan_catalogue "$cat" "$rel")"
    if [[ -n "$offenders" ]]; then
        printf '\nFAIL: em-dash rule violation(s) in %s:\n%s\n' "$rel" "$offenders" >&2
        FAILED=$((FAILED + 1))
    else
        printf '  OK  %s\n' "$rel"
    fi
done

if [[ $FAILED -gt 0 ]]; then
    printf '\nFAIL: %d catalogue(s) violate the em-dash rule.\n' "$FAILED" >&2
    printf 'Fix: replace with spaced en-dash " \xe2\x80\x93 " (U+2013). Punctuation only, do not retranslate.\n' >&2
    printf 'CLI flag mentions like "--allow-plaintext" are fine and are not flagged.\n' >&2
    exit 1
fi

printf 'PASS: no em-dash (U+2014) or whitespace-bounded "--" surrogates in any locale catalogue.\n'
exit 0
