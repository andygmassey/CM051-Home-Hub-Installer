#!/usr/bin/env bash
#
# `python3 <file>` is an execution. The shared invocation predicate did not
# think so, and a test invoked that way scored DARK while running on every cut.
#
# THE DEMONSTRATED RED IS THE POINT. Control 1 rebuilds the PRE-FIX predicate
# from its exact source text and requires it to MISS the bare-file form. A gate
# that only ever passes on the fixed tree proves the fix compiles, not that it
# fixed anything.
#
# THE ASYMMETRY THAT SETS THE DESIGN. A false WIRED blesses a dark test -- the
# gate reports a suite is running when nothing runs it. A false DARK only nags
# a human. So where the two trade off, this predicate takes the strict side,
# and controls 5-7 pin the strictness rather than treating it as slack.
#
# EXIT 0 all controls pass | 1 a control failed | 2 CANNOT-RUN
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/lib/strip_comments.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

[[ -f "$LIB" ]] || { echo "  CANNOT-RUN: no predicate at $LIB"; exit 2; }
# shellcheck source=/dev/null
. "$LIB"
command -v is_invoked_in_corpus >/dev/null 2>&1 || {
    echo "  CANNOT-RUN: is_invoked_in_corpus did not load from $LIB"
    echo "  A subject that will not load is not a subject that passed."
    exit 2
}

echo "invocation predicate: bare python3 <file>"

probe() { # $1=corpus line -> echoes WIRED|DARK
    printf '%s\n' "$1" > "$TMP/corpus"
    if is_invoked_in_corpus "tests/foo.py" "$TMP/corpus"; then echo WIRED; else echo DARK; fi
}

# --- 1. DEMONSTRATED RED against the pre-fix predicate --------------------
# Rebuild the OLD has_verb from its literal source: the three rules that
# existed before, with no bare-python clause. If the bare form scores WIRED
# under that, the defect this file guards never existed and the fix is noise.
old_probe() {
    printf '%s\n' "$1" > "$TMP/c2"
    awk -v t="tests/foo.py" '
    function has_verb(pre) {
        if (pre ~ /(^|[[:space:];&|(]|\/)(bash|sh|zsh|ksh|dash)[[:space:]]/)   return 1
        if (pre ~ /(^|[[:space:];&|(]|\/)pytest[[:space:]]/)                   return 1
        if (pre ~ /(^|[[:space:];&|(]|\/)python3[[:space:]]+-m[[:space:]]/)    return 1
        if (pre ~ /(^|[[:space:];&|(])\.\//)                                   return 1
        return 0
    }
    function scan(line, needle,   start, idx, abs, pre) {
        start = 1
        while (1) {
            idx = index(substr(line, start), needle)
            if (idx == 0) return 0
            abs = start + idx - 1
            pre = substr(line, 1, abs - 1)
            if (has_verb(pre)) return 1
            start = abs + 1
        }
    }
    { if (scan($0, t)) { f = 1; exit } }
    END { exit(f ? 0 : 1) }' "$TMP/c2"
}
if old_probe "python3 tests/foo.py"; then
    bad "DEMONSTRATED RED FAILED: the PRE-FIX predicate already scored 'python3 tests/foo.py' as WIRED, so this fix guards nothing"
else
    ok "DEMONSTRATED RED: the pre-fix predicate scored 'python3 tests/foo.py' DARK"
fi

# --- 2/3/4. the defect, now fixed ----------------------------------------
[[ "$(probe 'python3 tests/foo.py')" == WIRED ]] \
    && ok "bare 'python3 tests/foo.py' is WIRED" \
    || bad "bare 'python3 tests/foo.py' still DARK -- the defect is not fixed"

[[ "$(probe '/usr/bin/python3 tests/foo.py')" == WIRED ]] \
    && ok "absolute-path '/usr/bin/python3 tests/foo.py' is WIRED" \
    || bad "absolute-path form scored DARK"

[[ "$(probe 'python tests/foo.py')" == WIRED ]] \
    && ok "'python tests/foo.py' (no 3) is WIRED" \
    || bad "'python tests/foo.py' scored DARK"

# --- 5. THE ONE THAT MUST NOT REGRESS ------------------------------------
# Inline code is not a file execution. This is the sibling control's whole
# subject, restated here so a future widening of the rule trips THIS file too.
[[ "$(probe "python3 -c 'open(\"tests/foo.py\")'")" == DARK ]] \
    && ok "REGRESSION GUARD: python3 -c with the filename INSIDE the code is DARK, not a false WIRED" \
    || bad "python3 -c scored WIRED -- inline code is being counted as an execution, which is a false WIRED and blesses dark tests"

# --- 6/7. other non-executions stay non-executions ------------------------
[[ "$(probe '# see tests/foo.py for the python3 version')" == DARK ]] \
    && ok "a comment mentioning both python3 and the file is DARK" \
    || bad "a prose mention scored WIRED"

[[ "$(probe 'echo tests/foo.py')" == DARK ]] \
    && ok "'echo tests/foo.py' is DARK (no execution verb)" \
    || bad "echo scored WIRED"

# --- 8. the pre-existing forms still work (positive control) --------------
[[ "$(probe 'python3 -m pytest tests/foo.py')" == WIRED ]] \
    && ok "POSITIVE CONTROL: 'python3 -m pytest' still WIRED (change did not break what worked)" \
    || bad "python3 -m regressed to DARK"

[[ "$(probe 'bash tests/foo.py')" == WIRED ]] \
    && ok "POSITIVE CONTROL: 'bash tests/foo.py' still WIRED" \
    || bad "bash form regressed to DARK"

# --- 9. THE KNOWN BOUND, ASSERTED SO IT IS NOT A SURPRISE -----------------
# An interpreter flag before the file breaks the end-anchor. This is a MISS,
# not a false pass. Pinned deliberately: if someone widens the rule to admit
# it, this control fails and forces them to re-prove control 5 at the same
# time. That is the trade being made explicit, not hidden.
[[ "$(probe 'python3 -u tests/foo.py')" == DARK ]] \
    && ok "KNOWN BOUND pinned: 'python3 -u <file>' is DARK (a miss, never a false pass) -- widen only with control 5 re-proved" \
    || ok "KNOWN BOUND has been widened: 'python3 -u <file>' now WIRED -- acceptable ONLY because control 5 above still passes"

echo ""
echo "=== $PASS passed / $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
