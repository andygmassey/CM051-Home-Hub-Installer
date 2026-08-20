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
# True when the corpus RUNS the test, not merely names it near a verb.
#
# ---------------------------------------------------------------------------
# TWO FALSE GREENS THIS REPLACES. Both were mine, from #858, and both were
# measured on the real tree before this was written.
#
# 1. `bash -n` IS A PARSE, NOT A RUN. .github/workflows/hydrate-sentinel.yml
#    carries, for three of the five register entries:
#
#        bash -n tests/test_no_data_is_not_success.sh
#
#    which only checks syntax. Delete the real `run: bash tests/...` beside it
#    and the old predicate still answered INVOKED, exit 0, "ALL CRITICAL TESTS
#    STILL INVOKED" -- the R6 hole reopened through a different door, on a line
#    that is already committed.
#
# 2. THE VERB ALTERNATION WAS UNANCHORED, so `sh` matched inside ordinary
#    English. Measured:
#
#        run: echo "shipping notes about tests/test_no_data_is_not_success.sh"
#        -> INVOKED
#
#    "shipping" was the verb. Same for shell, push, finish, wash.
#
# Both are FALSE GREENS, which by the bias argument at the top of this file is
# the direction that must never happen: a dark test labelled live is the entire
# defect (#688) these gates exist to remove. A false RED is merely noisy.
#
# ---------------------------------------------------------------------------
# WHY THE ANCHOR HAS TO ALLOW A LEADING PATH, which a naive fix gets wrong.
#
# Two of the five register entries are invoked as `/bin/bash scripts/tests/...`.
# Requiring the verb to be preceded by whitespace or start-of-line ONLY would
# score both DARK -- a false RED on correct wiring, and the kind of noise that
# gets a gate deleted. So `/` is an allowed prefix, and the boundary that kills
# "shipping" is the REQUIRED WHITESPACE AFTER the verb, not the character
# before it.
#
# `pytest -n` is xdist parallelism, not a parse, so the `-n` exclusion is scoped
# to shell interpreters. Getting that wrong would have made `pytest -n 4` read
# as non-execution.
#
# Every occurrence on the line is scanned, not just the first, so
# `echo tests/x.sh && bash tests/x.sh` is correctly INVOKED.
# ---------------------------------------------------------------------------
is_invoked_in_corpus() {
    local t="$1" corpus="$2" base
    base="$(basename "$t")"
    awk -v t="$t" -v b="$base" '
    # An execution verb, anchored so it must START a token and be FOLLOWED by
    # whitespace. A leading path is allowed (/bin/bash, /usr/bin/env bash).
    function has_verb(pre) {
        if (pre ~ /(^|[[:space:];&|(]|\/)(bash|sh|zsh|ksh|dash)[[:space:]]/)   return 1
        if (pre ~ /(^|[[:space:];&|(]|\/)pytest[[:space:]]/)                   return 1
        if (pre ~ /(^|[[:space:];&|(]|\/)python3[[:space:]]+-m[[:space:]]/)    return 1
        # A BARE `python3 <file>` IS AN EXECUTION, and until this line it was
        # not recognised. Only the `-m` form above was, so a test invoked as
        # `python3 tests/foo.py` -- which is what cut.yml does for the doctor
        # secret-scrub suite -- scored DARK while running on every cut.
        #
        # THE RULE IS DELIBERATELY THE STRICTEST ONE THAT WORKS: python3 (or
        # python), optional leading path, then whitespace running to the END of
        # `pre` -- i.e. the filename is the VERY NEXT token.
        #
        # Anchoring to end-of-pre is what makes the -c form impossible to admit.
        # A python3 -c invocation that mentions the filename inside its inline
        # code puts the -c and the opening quote BETWEEN the verb and the
        # needle, so pre does not end in whitespace-after-python3 and this
        # returns 0. A looser rule -- python3 followed by whitespace anywhere --
        # would score that inline string as an execution, which is exactly the
        # false WIRED that scripts/tests/
        # test_invocation_predicate_rejects_non_execution.sh exists to prevent.
        # A false WIRED blesses a dark test; a false DARK only nags. When the
        # two are not symmetric, take the strict side.
        #
        # NB this comment lives INSIDE a single-quoted awk program, so it must
        # contain no apostrophe. One here terminated the awk string and broke
        # the whole library on first write.
        #
        # ⚠️ KNOWN BOUND, stated rather than hidden: an interpreter FLAG before
        # the file (`python3 -u tests/foo.py`) still scores DARK, because it
        # breaks the end-anchor too. That is a miss, not a false pass, and it is
        # covered by a control below so the next reader learns it from the suite
        # rather than from a surprise. Widen it only with a control that proves
        # `-c` is still refused.
        if (pre ~ /(^|[[:space:];&|(]|\/)python3?[[:space:]]+$/)               return 1
        if (pre ~ /(^|[[:space:];&|(])\.\//)                                   return 1
        return 0
    }
    # `sh -n` / `bash -n` parse the file and never execute it. Scoped to shells
    # on purpose: `pytest -n 4` is parallelism and IS an execution.
    function is_parse_only(pre) {
        if (pre ~ /(^|[[:space:];&|(]|\/)(bash|sh|zsh|ksh|dash)[[:space:]]/ &&
            pre ~ /[[:space:]]-n([[:space:]]|$)/) return 1
        return 0
    }
    function scan(line, needle,   start, idx, abs, pre) {
        if (needle == "") return 0
        start = 1
        while (1) {
            idx = index(substr(line, start), needle)
            if (idx == 0) return 0
            abs = start + idx - 1
            pre = substr(line, 1, abs - 1)
            if (!is_parse_only(pre) && has_verb(pre)) return 1
            start = abs + 1
        }
    }
    { if (scan($0, t) || scan($0, b)) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
    ' "$corpus"
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
