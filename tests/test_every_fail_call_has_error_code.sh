#!/usr/bin/env bash
#
# tests/test_every_fail_call_has_error_code.sh
#
# CX-17 (2026-05-23) regression test. Andy's Studio retest #6 asked
# for stable error codes on every install failure so support can
# triage customer reports quickly. The fix is two-part:
#
#   1. A `fail_with_code <CODE> <MSG>` shell helper (install.sh).
#   2. Every existing `fail "..."` callsite backfilled with a code.
#
# This test pins (2): walks install.sh byte-by-byte refusing any
# bare `fail "..."` invocation. The locked-memory rule
# `feedback_silent_bail_regression_test_shape` requires that for a
# silent-bail axis like this ("a future PR adds an uncoded fail
# back"), the regression test must walk the assembled file refusing
# the EXACT failure shape -- a bare `fail "..."` -- so a future
# regression cannot slip in unnoticed.
#
# The legacy `fail()` shell function itself is allowed to forward
# to the underlying gui_done path; the only bare-`fail` callsite
# in install.sh that is permitted is the one inside `fail_with_code`
# (which is THE legitimate forward). Everything else MUST be
# `fail_with_code "ERR-NN-COMPONENT-SHORTREASON" "..."`.
#
# Code shape (ERR-NN-COMPONENT-SHORTREASON):
#   - ERR-      literal prefix
#   - NN-       2-digit step index (00 reserved for pre-step phases)
#   - COMPONENT short uppercased component (HOMEBREW, DOCKER, ...)
#   - SHORTREASON  optional further qualifier (CLI, RAM-LOW, ...)
#
# Pure bash + standard tools. Exit code 0 on pass, non-zero on fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

failures=0
fail_test() {
    failures=$((failures + 1))
    echo "FAIL: $*" >&2
}

ok() { echo "ok: $*"; }

# ── Test 1: every fail callsite uses fail_with_code ──────────────
#
# Walk install.sh line by line. The legitimate bare `fail` calls
# are:
#   - the function DEFINITION (line `fail()  {`)
#   - the FORWARD inside fail_with_code (`fail "$*"`)
#
# Everything else that matches `[[:space:]]+fail "` (including the
# `|| fail "..."` shape) is a regression and fails this test.

echo "==> Walking install.sh for bare fail callsites..."

bare_fail_count=0
while IFS=: read -r line_num text; do
    # Strip leading whitespace for the next match.
    trimmed="${text#"${text%%[![:space:]]*}"}"

    # Skip comment lines -- documentation examples like
    # `# legacy fail "..." call` are not regressions.
    if [[ "$trimmed" =~ ^# ]]; then
        continue
    fi

    # Allowlisted shapes:
    #   `fail()  {`             function definition
    #   `fail "$*"`             forward inside fail_with_code
    if [[ "$trimmed" =~ ^fail\(\) ]]; then
        continue
    fi
    if [[ "$trimmed" == 'fail "$*"' ]]; then
        continue
    fi

    fail_test "install.sh line ${line_num}: bare \`fail \"...\"\` callsite found. CX-17 (2026-05-23) requires every fail call to be \`fail_with_code \"ERR-NN-COMPONENT-SHORTREASON\" \"...\"\` so the failure banner + auto-copied support log carry a stable error code. Convert this site to fail_with_code. Line: ${text}"
    bare_fail_count=$((bare_fail_count + 1))
done < <(grep -nE '(^|[[:space:]]\|\|[[:space:]]|[[:space:]])fail "' "$INSTALL_SH")

if (( bare_fail_count == 0 )); then
    ok "no bare \`fail \"...\"\` callsites in install.sh"
fi

# ── Test 2: every fail_with_code uses ERR-NN-* shape ─────────────
#
# A typo at the callsite (`fail_with_code "ERR17DOCTOR" "..."`)
# would render as a malformed code on the banner -- not a regression
# the linter catches (only the test will).

echo "==> Walking install.sh for malformed error codes..."

malformed_count=0
while IFS=: read -r line_num text; do
    # Skip comment lines -- documentation examples like
    # `# fail_with_code "ERR-NN-FOO-BAR" "..."` are not regressions.
    trimmed="${text#"${text%%[![:space:]]*}"}"
    if [[ "$trimmed" =~ ^# ]]; then
        continue
    fi
    # Pull the code out -- it is the first quoted argument.
    code="$(echo "$text" | sed -E 's/.*fail_with_code "([^"]*)".*/\1/')"
    if [[ "$code" == "$text" ]]; then
        # No quoted code found -- shouldn't happen if the grep matched.
        continue
    fi
    # Required shape: ERR-NN-X{1,}[-X{1,}]*
    #   ERR-  literal
    #   NN-   2 digits then dash
    #   then 1+ uppercase / digit / dash segments
    if [[ ! "$code" =~ ^ERR-[0-9]{2}-[A-Z0-9]+(-[A-Z0-9]+)*$ ]]; then
        fail_test "install.sh line ${line_num}: malformed error code '${code}'. Expected shape ERR-NN-COMPONENT-SHORTREASON (e.g. ERR-17-DOCTOR-MISSING). NN is the 2-digit step index in StepCatalog.canonicalOrder (00 for pre-step phases). Component / shortreason are uppercase A-Z 0-9 segments joined by hyphens. Line: ${text}"
        malformed_count=$((malformed_count + 1))
    fi
done < <(grep -n 'fail_with_code "' "$INSTALL_SH")

if (( malformed_count == 0 )); then
    ok "every fail_with_code code matches the ERR-NN-* shape"
fi

# ── Test 3: at least 1 fail_with_code callsite exists ────────────
#
# Belt-and-braces: a future refactor that accidentally deletes every
# call (without deleting the bare-`fail` ban) would silently turn
# this test green. Pin a lower bound. If you intentionally remove
# every callsite at some future point, edit this bound + add a
# rationale comment.

fail_with_code_count="$(grep -cE 'fail_with_code "ERR-' "$INSTALL_SH" || true)"
echo "==> fail_with_code callsites: ${fail_with_code_count}"
if (( fail_with_code_count < 10 )); then
    fail_test "install.sh has only ${fail_with_code_count} fail_with_code callsites. CX-17 (2026-05-23) backfilled ~25 callsites; a number this low usually means a recent PR replaced fail_with_code with bare fail or deleted callsites without justification. Re-add codes."
else
    ok "${fail_with_code_count} fail_with_code callsites present"
fi

# ── Test 4: gui_done attaches the code in lib/progress_emitter.sh ──
#
# The wire-shape contract: when fail_with_code fires, the DONE
# marker MUST carry `code=ERR-NN-...`. A regression that removed
# the `code=` keyword from gui_done would leave the Swift side
# parsing a code-less DONE and the banner would render the plain
# heading instead of the code-aware one.

EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"
if [[ ! -f "$EMITTER" ]]; then
    fail_test "lib/progress_emitter.sh not found at $EMITTER"
elif ! grep -qE 'gui_emit DONE "status=\$status" "code=\$\{OSTLER_LAST_ERROR_CODE\}"' "$EMITTER"; then
    fail_test "lib/progress_emitter.sh gui_done does not attach the code= keyword on the DONE marker when OSTLER_LAST_ERROR_CODE is set. The Swift side relies on this to surface the code on the failure banner. Expected: gui_emit DONE \"status=\$status\" \"code=\${OSTLER_LAST_ERROR_CODE}\""
else
    ok "lib/progress_emitter.sh gui_done attaches code= keyword"
fi

# ── Result ─────────────────────────────────────────────────────────

if (( failures > 0 )); then
    echo
    echo "FAIL: ${failures} regression(s) found." >&2
    exit 1
fi

echo
echo "PASS: every install.sh fail callsite uses fail_with_code with a well-formed ERR-NN-* code."
exit 0
