# pii_patterns.sh -- shared PII regex-pattern layer for the pre-commit guard.
#
# Sourced by .githooks/pre-commit (Check 4.5). Factored into its own file
# so the merge + validation logic is unit-testable in isolation without a
# real git repo or a real commit (see .githooks/test_pii_patterns.sh).
#
# What this provides
# ------------------
# A *regex* PII layer that sits ON TOP OF (never replaces) the scanner's
# built-in defaults. The built-in email + secret + dangerous-path checks in
# pre-commit are unchanged; this file adds a curated set of built-in regex
# patterns AND lets a customer merge in their own patterns via an optional
# `.pii-patterns` file at the repo root.
#
# Customer config file: <repo-root>/.pii-patterns
#   - One POSIX extended regular expression (ERE) per line.
#   - Blank lines and lines beginning with `#` are ignored (comments).
#   - Matched case-insensitively (grep -iE), like the built-ins.
#   - Customer patterns MERGE with the built-in defaults below; they are
#     additive. A customer cannot weaken or remove a built-in default --
#     they can only add coverage. ("override" in the task sense means a
#     customer can supply a broader/site-specific pattern for the same
#     PII class; the built-in still fires independently.)
#   - The file should be gitignored so each dev/customer keeps their own
#     list without committing it.
#
# Safety contract
# ---------------
# A malformed customer regex is SKIPPED with a warning on stderr -- it must
# never crash the scanner or block an unrelated commit. The built-in
# defaults are validated the same way for symmetry, but they are known-good.

# ── Built-in default regex patterns ───────────────────────────────────────
# Conservative, format-based PII patterns that complement the literal
# `.pii-blocklist` and the built-in email/secret regexes in pre-commit.
# These are intentionally narrow to keep false positives low (v1 philosophy:
# false positives are cheaper than false negatives, but a regex layer that
# cries wolf gets disabled, so we keep these tight).
#
# All patterns are POSIX ERE, matched case-insensitively.
pii_builtin_patterns() {
    cat <<'PII_DEFAULTS'
# UK mobile in international form: +44 7xxx xxxxxx (spaces/hyphens optional)
\+44[[:space:]-]?7[0-9]{3}[[:space:]-]?[0-9]{6}
# UK mobile in national form: 07xxx xxxxxx
\b07[0-9]{3}[[:space:]-]?[0-9]{6}\b
# US/intl phone: +1 (xxx) xxx-xxxx style
\+1[[:space:]-]?\(?[0-9]{3}\)?[[:space:]-]?[0-9]{3}[[:space:]-]?[0-9]{4}
# US Social Security Number: xxx-xx-xxxx
\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b
# Apple DSID-looking long numeric id (>= 15 digits, e.g. iCloud DSID)
\b[0-9]{15,}\b
PII_DEFAULTS
}

# ── Regex validation ──────────────────────────────────────────────────────
# Return 0 if $1 compiles as a POSIX ERE, 1 otherwise. Never prints to
# stdout; never aborts the caller. Uses a tiny harmless probe string so the
# only thing that can fail is the regex compile itself.
pii_regex_is_valid() {
    local re="$1"
    # An empty pattern is not useful and would match everything; treat as
    # invalid so it is skipped rather than nuking the scan.
    [ -z "$re" ] && return 1
    # grep returns 2 on a regex-compile error (vs 0 match / 1 no-match).
    # Send both streams to /dev/null; we only care about the exit status.
    printf '%s' 'pii_regex_probe' | grep -iEq -e "$re" >/dev/null 2>&1
    local rc=$?
    [ "$rc" -ge 2 ] && return 1
    return 0
}

# ── Load + merge + validate ───────────────────────────────────────────────
# Emit, one per line on stdout, every VALID regex pattern the scanner
# should use: the built-in defaults first, then any valid customer patterns
# from the given file. Invalid customer patterns are skipped and a warning
# is printed to stderr (never stdout, so the pattern stream stays clean).
#
# Args:
#   $1 -- path to the customer .pii-patterns file (optional / may not exist)
pii_load_patterns() {
    local custom_file="${1:-}"

    # Built-in defaults. These are curated + known-good, but we still run
    # them through the validator so a future typo here degrades gracefully
    # instead of taking down the whole hook.
    local line
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        if pii_regex_is_valid "$line"; then
            printf '%s\n' "$line"
        else
            printf 'pii-patterns: WARNING skipping invalid BUILT-IN regex: %s\n' "$line" >&2
        fi
    done < <(pii_builtin_patterns)

    # Customer patterns (optional).
    [ -n "$custom_file" ] && [ -f "$custom_file" ] || return 0
    while IFS= read -r line; do
        # Trim trailing carriage return (CRLF files) first.
        line="${line%$'\r'}"
        # Trim leading + trailing whitespace so a blank-but-spaced line is
        # treated as empty, not as a regex of literal spaces (which would
        # match almost everything).
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ''|\#*) continue ;;
        esac
        if pii_regex_is_valid "$line"; then
            printf '%s\n' "$line"
        else
            printf 'pii-patterns: WARNING skipping invalid customer regex (in %s): %s\n' \
                "$custom_file" "$line" >&2
        fi
    done < "$custom_file"
}

# ── Scan a set of files against the merged pattern list ────────────────────
# Args:
#   $1 -- newline-separated list of files to scan
#   $2 -- path to the customer .pii-patterns file (optional)
# Output (stdout): for each hit, a block of:
#     pattern '<regex>' matched in:
#       <file>
# Returns 0 always (the caller decides whether any output == failure); the
# point is that scanning never aborts on a single bad input.
pii_scan_files() {
    local files="$1"
    local custom_file="${2:-}"
    local patterns
    patterns="$(pii_load_patterns "$custom_file")"
    [ -n "$patterns" ] || return 0

    local pattern f found
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        found=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ -f "$f" ] || continue
            if grep -l -iE -e "$pattern" "$f" >/dev/null 2>&1; then
                found="$found
    $f"
            fi
        done <<< "$files"
        if [ -n "$found" ]; then
            printf "  pattern '%s' matched in:%s\n" "$pattern" "$found"
        fi
    done <<< "$patterns"
    return 0
}
