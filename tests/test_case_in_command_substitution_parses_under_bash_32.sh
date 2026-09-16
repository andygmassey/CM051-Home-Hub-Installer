#!/usr/bin/env bash
# Shell tests must RUN TO COMPLETION under /bin/bash 3.2, the cut host's shell.
#
# THE DEFECT, measured on origin/main 2026-09-16.
# tests/test_vendor_only_survives_sync.sh died at its own line 130 under
# /bin/bash 3.2.57 with "command substitution: syntax error near unexpected
# token `newline'". Measured IN PLACE, same directory, same shell: 81
# assertions reached and rc=1 before, 93 and rc=0 after. TWELVE ASSERTIONS HAD
# NEVER RUN, and the ones above the failure printed PASS all the way, so the
# output looked like a suite doing its job.
#
# The cause: 3.2 takes the `)` that closes a `case` PATTERN as the `)` that
# closes an enclosing $( ). The POSIX `(pattern)` form removes the ambiguity.
#
# WHY THIS TEST RUNS FILES RATHER THAN GREPPING FOR THE SHAPE.
# I wrote the grep first. It found the real defect and then accused TWO
# innocent files, because tracking $( ) nesting by eye across quotes, comments
# and case patterns is the same problem the shell itself gets wrong here. Both
# accusations were caught only because the files it named RAN CLEANLY, which is
# the check that actually answers the question. So that is the check.
#
# A gate that cries wolf is worse than no gate: it trains people to skim it.
# This one has no false positives available to it, because its predicate IS the
# thing we care about -- the file finishes, under the shell that matters.
#
# WHY NOT `bash -n`: it PASSES the broken file, under 3.2 and 5.x alike,
# because a command substitution body is parsed lazily when evaluated. The one
# 3.2 gate this repo had is a `bash -n`, and it was green throughout. Arm 3
# pins that, so nobody replaces this with the cheaper check.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0; PASS=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Files whose failure mode was this, and which must stay runnable. Self-hosting
# suites only: each is safe to run and exits non-zero on its own findings.
SUBJECTS="tests/test_vendor_only_survives_sync.sh"

for f in $SUBJECTS; do
    if [ ! -f "$f" ]; then
        echo "  [CANNOT-RUN] $f is missing. This is not a pass: the subject of"
        echo "               the assertion is gone, so nothing was measured."
        exit 2
    fi
    err="$(/bin/bash "$f" 2>&1 >/dev/null | grep -c 'command substitution.*syntax error' || true)"
    if [ "${err:-0}" -eq 0 ]; then
        ok "$f runs under /bin/bash $(/bin/bash --version | head -1 | sed 's/.*version //; s/ .*//') with no command-substitution parse error"
    else
        bad "$f still dies inside a command substitution under /bin/bash 3.2.
         Everything after that point NEVER RUNS while the lines above it still
         print PASS. Write the case pattern as (pattern)."
    fi
done

# CONTROL 1. The predicate must be able to fail, or every PASS above is empty.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
{ printf 'x="$(\n'; printf '\twhile read -r v; do\n'
  printf '\t\tcase "$v" in %s) continue ;; esac\n' "''|'#'*"
  printf '\t\techo "$v"\n\tdone < /dev/null\n'; printf ')"\necho done\n'; } > "$tmp/bad.sh"
if [ "$(/bin/bash "$tmp/bad.sh" 2>&1 >/dev/null | grep -c 'command substitution.*syntax error')" -gt 0 ]; then
    ok "CONTROL: the known-bad shape IS detected by this predicate"
else
    bad "CONTROL FAILED: a file built to contain the exact defect was reported
         clean, so the passes above measure nothing."
fi

# CONTROL 2. The leading-paren form must actually fix it, or the advice is wrong.
sed "s/in ''|'#'\\*)/in (''|'#'*)/" "$tmp/bad.sh" > "$tmp/good.sh"
if [ "$(/bin/bash "$tmp/good.sh" 2>&1 >/dev/null | grep -c 'command substitution.*syntax error')" -eq 0 ]; then
    ok "CONTROL: the (pattern) form the message recommends does fix it"
else
    bad "the recommended fix does not work, so the message sends people nowhere"
fi

# CONTROL 3. Pin that `bash -n` is blind, so this is not replaced by a parse check.
if /bin/bash -n "$tmp/bad.sh" 2>/dev/null; then
    ok "CONTROL: \`bash -n\` PASSES the broken file, which is why this test exists"
else
    bad "\`bash -n\` now rejects it. If that istrue, replace this with a parse check."
fi

printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
