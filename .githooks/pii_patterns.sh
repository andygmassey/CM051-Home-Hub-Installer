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
# Email address. Reserved-for-documentation domains (RFC 2606/6761) are
# excused by pii_reserved_placeholder_re, NOT by narrowing this pattern --
# see the polarity note on that function.
[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}
# macOS home directory carrying a username: /Users/<name>
# The trailing slash is OPTIONAL, and that is not cosmetic. This pattern
# required it until 2026-08-16, so `/Users/<name>` at the end of a line or
# before a newline escape was invisible to the whole class. Measured on the
# real shipping ledger: one such occurrence existed, was never reported, and
# was mistaken for the exemption layer working. A name at end-of-line is
# exactly as identifying as one followed by a path.
# Placeholder home dirs are excused by pii_reserved_placeholder_re.
/Users/[a-z0-9._-]+/?
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

# ── The library declares its own expected built-in count ──────────────────
# THE NUMBER OF BUILT-IN PATTERNS THIS LIBRARY INTENDS TO PROVIDE.
# Maintained by hand, one line, next to the block it counts. If you add or
# remove a pattern in pii_builtin_patterns, change this too --
# test_pii_patterns.sh asserts the two agree and fails loudly if they do not,
# so the drift is caught at commit time rather than in production silence.
#
# WHY A DECLARED COUNT AT ALL, WHEN THE LOADER READS THE SAME BLOCK
#
# It looks like a guard comparing a thing to itself, which is a real failure
# shape and worth ruling out explicitly. It is not one, because the two sides
# are properties of different things:
#
#   DECLARED  a static property of the SOURCE. What this file says it has.
#   LOADED    a runtime property of SOURCE + THE GREP + THE LOCALE. What
#             pii_regex_is_valid could actually compile, here, tonight.
#
# They diverge precisely when the environment silently drops a pattern: a BSD
# vs GNU grep disagreement, a busybox grep in a minimal container, a locale
# where a bracket expression will not compile. Same source, fewer patterns, no
# error -- the scan simply narrows and still reports clean on everything the
# surviving patterns do not cover.
#
# That is the worst available failure mode for a PII scanner. It does not
# fail; it NARROWS. And a narrowed scan is indistinguishable from a clean tree
# at the only place anyone looks, which is the exit code.
#
#     A refusal that names nothing is indistinguishable from a refusal that
#     found nothing.  -- and a scan that lost half its patterns is
#     indistinguishable from a tree that had nothing to find.
#
# Measured 2026-08-16: this defect class produced four independent confident
# verdicts from measurements that never ran, in four separate repos, in one
# evening. The one that burnt a release tag called a function that no commit
# anywhere defined, took the resulting 127 as a verdict, and printed its
# refusal over an empty list: "in 0 file(s)".
pii_builtin_expected_count() {
    printf '%s\n' '7'
}

# ── Load + validate the BUILT-INS only ────────────────────────────────────
# Split out from pii_load_patterns so the floor can count built-ins WITHOUT
# customer patterns inflating the total. A customer file with three patterns
# would otherwise mask two dropped built-ins perfectly.
pii_load_builtin_patterns() {
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
}

# ── The floor ─────────────────────────────────────────────────────────────
# Return 0 if at least as many built-ins loaded as this library declares.
# Otherwise print a diagnostic to stderr NAMING BOTH COUNTS AND EVERY MISSING
# PATTERN, and return 1.
#
# Naming the numbers is the point. "pattern count mismatch" sends the next
# reader to audit the whole library; "declared 7, loaded 5, missing: <these
# two>" sends them to the two lines that matter. A gate that reports only that
# something differed has moved the work rather than done it.
pii_builtin_floor_check() {
    local declared loaded in_source
    declared="$(pii_builtin_expected_count)"

    # How many patterns the SOURCE BLOCK actually holds right now, before any
    # validation. Separating this from `loaded` is what lets the diagnostic
    # name the CAUSE rather than just the shortfall: a bare "declared 7,
    # loaded 5" is true under two completely different faults that want
    # opposite fixes.
    in_source="$(pii_builtin_patterns | grep -cvE '^[[:space:]]*(#|$)' || true)"

    # Deliberately discarding the loader's exit status here: this function's
    # verdict is the COUNT, not the loader's rc, and taking an rc through a
    # pipe reports the last stage's status while looking like it reports the
    # first. Warnings about individual invalid built-ins already went to
    # stderr from the loader; they are re-stated below by name.
    local loaded_list
    loaded_list="$(pii_load_builtin_patterns 2>/dev/null)"
    loaded="$(printf '%s' "$loaded_list" | grep -c . || true)"

    if [ "${loaded:-0}" -ge "${declared:-0}" ]; then
        return 0
    fi

    printf 'pii-patterns: BUILT-IN PATTERN FLOOR BREACHED\n' >&2
    printf '  declared %s built-in pattern(s), source block holds %s, loaded %s.\n' \
        "$declared" "${in_source:-0}" "${loaded:-0}" >&2

    # CAUSE 1: the source block was edited and the declared count was not.
    # A maintenance error, fixed in this file.
    if [ "${in_source:-0}" -lt "${declared:-0}" ]; then
        printf '  CAUSE: the source block itself is short. pii_builtin_patterns holds\n' >&2
        printf '    %s pattern(s) but pii_builtin_expected_count declares %s. Someone\n' \
            "${in_source:-0}" "$declared" >&2
        printf '    removed a pattern without updating the declared count, or added the\n' >&2
        printf '    count ahead of the patterns. Fix whichever is wrong -- do NOT simply\n' >&2
        printf '    lower the declared count to make this pass, which would silently\n' >&2
        printf '    bless the missing coverage.\n' >&2
    fi

    # CAUSE 2: the source has them, but this environment could not compile
    # them. Not a maintenance error -- a portability one, fixed by naming the
    # regexes that failed HERE. This is the fault the floor exists for: same
    # source, different grep or locale, quietly fewer patterns.
    local line named=0
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        case "
$loaded_list" in
            *"
$line"*) continue ;;
        esac
        if [ "$named" -eq 0 ]; then
            printf '  CAUSE: the following built-in(s) are present in the source but did\n' >&2
            printf '    NOT survive validation in this environment (grep flavour, locale):\n' >&2
            named=1
        fi
        printf '      %s\n' "$line" >&2
    done < <(pii_builtin_patterns)

    printf '  A scan missing built-ins does not fail, it NARROWS, and a narrowed\n' >&2
    printf '  scan reports clean on everything it no longer covers. Refusing.\n' >&2
    return 1
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

    pii_load_builtin_patterns

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
# Standards-reserved placeholders. A value in one of these ranges can
# never belong to a real person, so a pattern hit on one is never a leak.
#
# Kept deliberately short and standards-only: this is an allowlist of
# SHAPES that are reserved by a standards body, not a list of values
# somebody judged safe.
#   UK    OFCOM drama range, reserved for fiction
#   US    555-01xx, the NANP fiction range (US and Canada)
#   email RFC 2606 + RFC 6761 documentation domains and TLDs
#   path  placeholder home directory names
#
# THE POLARITY DIFFERS BETWEEN CLASSES, and getting it wrong makes a class
# unusable. Measured 2026-08-15 on CM051.
#
#   PHONE  the pattern MUST fire on the reserved range, because that is what
#          makes the canary provable: the hook's own error message tells you
#          to use 07700 900xxx, so the guard has to detect it. The reserved
#          regex then excuses it, which is why extract-then-filter exists.
#
#   EMAIL  the reserved range is what a CORRECT fixture uses, so it must be
#          excused or the class is unusable. Measured over 485 vendored files
#          in CM051: 90 distinct email-shaped tokens, roughly 57 of them on
#          RFC 2606 or fixture domains. A class that fires on all 90 is about
#          63% false-positive on day one, which is exactly the
#          red-that-carries-no-information this library exists to avoid.
#
# Same "provably fictional" principle, opposite implementations. Phones prove
# fictionality by being IN the reserved range and tripping anyway; emails prove
# it by being in the reserved range and being let through.
#
# Standards-only, deliberately. `.local` is NOT here: RFC 6762 reserves it for
# mDNS, not for documentation, so an address there can be a real internal one.
#
# THE LIST WAS WRONG IN BOTH DIRECTIONS, and both corrections are stated here
# together on purpose. Measured 2026-08-16 when the email class met HR015's
# real tree for the first time. Reading only one of these makes the other look
# like an oversight, which is why they are one finding and not two.
#
#   TOO NARROW -> WIDENED.  `@example\.(com|net|org)` missed `example.co.uk`,
#   `example.se` and `example.ie`. Thirty-six email hits across four files,
#   ZERO of them real: every one was `example.<something>`. RFC 2606 reserves
#   example.com/net/org and the `.example` TLD, and reserves NO ccTLD form, so
#   the strictly-standards reading was correct and unusable. The ccTLD
#   `example.` is the universal documentation convention and no registry sells
#   it as a real mailbox in practice.
#
#   This is a DELIBERATE STEP BEYOND RFC 2606's LETTER. Do not "tighten" it
#   back to the three gTLDs: that reading was already tried, and it produced a
#   class that fired thirty-six times and was right zero times, which is the
#   red-that-carries-no-information failure one paragraph up.
#
#   TOO WIDE -> KEPT, AND NOW EXPLAINED.  `runner` is in the path list and
#   stays. `/Users/runner` is the GitHub-hosted CI home. It identifies nobody,
#   it appears once in a shipping ledger row, and scrubbing it would damage a
#   TRUE RECORD of where something was built. Verified behaviourally rather
#   than by reading: /Users/runner is excused, the operator's own home is
#   REPORTED. The operator's real home directory must never join this list --
#   that value is precisely what the path class exists to catch, and excusing
#   it would be the fail-open shape.
#
# The rule both corrections serve: a reserved entry must be provably fictional
# or provably impersonal. `example.co.uk` is the first; `/Users/runner` is the
# second. Anything that is merely CONVENIENT to excuse does not belong here.
# The PLACEHOLDER home-directory names, as an ERE alternation, in ONE place.
#
# Two consumers read this: pii_reserved_placeholder_re below (which decides
# what the scanner excuses) and bin/scrub-operator-paths.sh (which decides
# what the scrub must leave alone). They MUST agree. A scrub that rewrites a
# name the scanner excuses, or a scanner that reports a name the scrub
# preserves, is the same defect from opposite ends, and duplicating the list
# is how that happens.
#
# `runner` earns its place by being provably impersonal, not by being
# convenient. See the long note above.
pii_placeholder_home_names() {
    printf '%s' 'you|user|username|example|runner|\$\{?USER\}?|<[a-z]+>'
}

pii_reserved_placeholder_re() {
    printf '%s' '(\+?44[[:space:]-]?7700[[:space:]-]?900[0-9]{3}|0?7700[[:space:]-]?900[0-9]{3}|555[[:space:]-]?01[0-9]{2}|@example\.[a-z][a-z.]*$|@([a-z0-9.-]+\.)?(test|example|invalid|localhost)$|^/Users/('"$(pii_placeholder_home_names)"')/?$)'
}

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
            # Extract the ACTUAL matches and drop any that are
            # standards-reserved placeholders, rather than reporting the
            # file on a bare `grep -l`.
            #
            # WHY: the UK-mobile pattern matches 7700 900xxx, which IS the
            # OFCOM range reserved for fiction -- the exact value this
            # hook's own error message tells you to use. So following the
            # advice did not unblock you, and the only way forward was
            # --no-verify. A guard that teaches people to bypass it is
            # worse than one that is slightly too loose.
            #
            # Extract-then-filter rather than a cleverer regex because
            # POSIX ERE has no negative lookahead, and enumerating "7xxx
            # but not 7700" is unreadable and wrong the first time it is
            # edited.
            hits_raw="$(grep -oiE -e "$pattern" "$f" 2>/dev/null || true)"
            if [ -n "$hits_raw" ] \
               && printf '%s\n' "$hits_raw" | grep -qvE "$(pii_reserved_placeholder_re)"; then
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
