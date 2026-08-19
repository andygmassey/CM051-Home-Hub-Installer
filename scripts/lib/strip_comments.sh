#!/usr/bin/env bash
# strip_comments.sh
# ============================================================================
# ONE comment-stripper, shared by every gate that must count INVOCATIONS
# rather than name mentions.
#
# WHY IT IS A LIBRARY AND NOT A ONE-LINER IN EACH GATE
#
# #857 stripped comments with `sed 's/#.*$//'`. Archie flagged at merge that it
# also truncates at a `#` INSIDE A QUOTED STRING, so a runner line like
#
#     run: echo "a#b" && bash scripts/tests/test_thing.sh
#
# loses everything from the `#` onward, including the invocation. #858 then
# copied the same one-liner into verify_critical_tests_stay_invoked.sh, so by
# the time anyone fixed it there were two copies to fix. Hence one function,
# sourced by both.
#
# ---------------------------------------------------------------------------
# THE BIAS ARGUMENT, which is the reason this is written the way it is.
#
# These gates ask: does the test's name appear in the comment-stripped runner
# text? So the two ways to be wrong are NOT symmetric.
#
#   STRIP TOO MUCH  -> a real invocation is deleted -> the test scores DARK
#                      -> FALSE RED. Noisy, but nothing bad ships.
#
#   STRIP TOO LITTLE -> a comment survives -> a mere mention scores WIRED
#                      -> FALSE GREEN. A dark test is labelled live, which is
#                      the entire defect (#688) these gates exist to remove.
#
# So the fix must never trade a false RED for a false GREEN. A naive
# quote-aware strip does exactly that: on a line with an UNBALANCED quote, e.g.
#
#     echo "unclosed    # bash scripts/tests/test_thing.sh
#
# quote-tracking believes the `#` is inside a string, keeps the tail, and a
# comment becomes an invocation. That is strictly worse than the bug it fixes.
#
# THE RULE HERE, therefore:
#   - Cut at the first `#` found OUTSIDE quotes. Scanning stops there, because
#     everything after it is a comment and its quotes are prose, not syntax.
#     (Without stopping, an apostrophe in "don't" would reopen a quote and
#     poison the balance check for the rest of the line.)
#   - If no such `#` exists AND the line ends inside an unterminated quote, the
#     quote analysis is untrustworthy. FALL BACK to the old aggressive cut at
#     the first `#` anywhere. Ambiguity resolves toward stripping more.
#   - Otherwise keep the line whole.
#
# Handles shell and YAML (`#` to end of line) and Python (same character).
# Backslash escapes are honoured outside single quotes, where they do not
# apply.
# ============================================================================

# ---------------------------------------------------------------------------
# WHY AN INVOCATION PREDICATE LIVES HERE TOO, and it is not scope creep.
#
# Making the stripper quote-aware WEAKENS any gate whose predicate is a bare
# substring search, and my own dogfood caught it. Unwiring a test like this:
#
#     run: echo "disabled  # was scripts/tests/test_thing.sh"
#
# used to score DARK only because the blunt stripper truncated at the `#`. The
# `#` is inside quotes, so the correct stripper keeps the line, and a plain
# substring match then reads a quoted echo string as an invocation. The blunt
# stripper was accidentally covering for a weak predicate.
#
# So the two must change together. #858 already had the right answer -- require
# an EXECUTION VERB on the same line -- and that pattern is reproduced here
# VERBATIM rather than reinvented, so the two gates cannot drift into
# disagreeing about what "invoked" means.
# ---------------------------------------------------------------------------

# is_invoked_in_corpus <test-path> <corpus-file>
# True when the corpus carries the test's path or basename on a line that ALSO
# carries an execution verb before it. `[^#]*` between the two is a second
# comment guard for any `#` the stripper deliberately left in place.
is_invoked_in_corpus() {
    local t="$1" corpus="$2" base
    base="$(basename "$t")"
    grep -E "(bash|sh|pytest|python3 -m|\./)[^#]*($(printf '%s' "$t" | sed 's/[.[\*^$/]/\\&/g')|$(printf '%s' "$base" | sed 's/[.[\*^$/]/\\&/g'))" \
        "$corpus" >/dev/null 2>&1
}

# strip_comments_file <path>
# Writes the comment-stripped contents of <path> to stdout, one line in, one
# line out, so line counts are preserved for anything that cares.
strip_comments_file() {
    awk '
    BEGIN {
        SQ = sprintf("%c", 39)   # single quote
        DQ = sprintf("%c", 34)   # double quote
        BS = sprintf("%c", 92)   # backslash
    }
    {
        line = $0
        n = length(line)
        in_s = 0            # inside single quotes
        in_d = 0            # inside double quotes
        cut_outside = 0     # first # seen OUTSIDE any quote (1-based)
        cut_any = 0         # first # seen ANYWHERE, the conservative fallback

        for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (c == "#" && cut_any == 0) cut_any = i

            if (in_s) {
                # No escapes inside single quotes. Only another SQ closes it.
                if (c == SQ) in_s = 0
                continue
            }
            if (in_d) {
                if (c == BS) { i++; continue }
                if (c == DQ) in_d = 0
                continue
            }
            if (c == BS) { i++; continue }
            if (c == SQ) { in_s = 1; continue }
            if (c == DQ) { in_d = 1; continue }
            if (c == "#") { cut_outside = i; break }
        }

        if (cut_outside > 0) {
            print substr(line, 1, cut_outside - 1)
        } else if (in_s || in_d) {
            # Unbalanced quotes: analysis untrustworthy, strip conservatively.
            if (cut_any > 0) print substr(line, 1, cut_any - 1)
            else             print line
        } else {
            print line
        }
    }
    ' "$1"
}
