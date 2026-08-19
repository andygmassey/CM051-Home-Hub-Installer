#!/usr/bin/env bash
# verify_new_tests_are_wired.sh
# ============================================================================
# A TEST ADDED BY THIS CHANGE MUST BE INVOKED BY THIS CHANGE.
#
# WHY THIS EXISTS, and it is not the same job as verify_test_wiring.sh.
#
# The estate keeps discovering test suites that exist, pass, and are run by
# NOTHING. Four in a single day on 2026-08-19: the doctor-proxy-paths gate, the
# BOM gate, 704 of ostler_fda's 705, and the egress probe's own attribution
# controls. That is not four lapses. It is one property of the repo:
#
#   WRITING a test and RUNNING a test are separate acts, and only the first
#   one is enforced by anything. You can add a file, commit it, and CI stays
#   green, because CI runs what it is told to run and nothing ever compares
#   the set of test FILES to the set of test INVOCATIONS.
#
# There is already a gate for the standing population, tests/TEST_WIRING.tsv +
# verify_test_wiring.sh. It does not stop this, for two measured reasons:
#
#   IT COUNTS MENTIONS, NOT INVOCATIONS. Its own source says so: "The check
#   below is a substring search over the whole file, and a comment is part of
#   the file. So a test scored WIRED if any workflow merely NAMED it."
#   Documenting a dark test marks it live.
#
#   IT IS A RATCHET WITH A GRANDFATHER CLAUSE. It fails when the unwired set
#   GROWS, which legitimised the ~128 already unwired as the accepted baseline
#   instead of burning them down.
#
# So the standing gate cannot stop the bleeding, and fixing the backlog is a
# long job. THIS gate is deliberately the other shape: it looks only at the
# DIFF. It does not care about the 124 already dark. It makes it impossible for
# a NEW one to be born, today, without touching that backlog at all.
#
# ---------------------------------------------------------------------------
# INVOKED, NOT MENTIONED. This is the entire correctness argument.
#
# Every candidate runner file is COMMENT-STRIPPED before it is searched. A test
# named in a comment, a TODO, a post-mortem or a heredoc of prose does not
# count. That is the exact defect this gate refuses to inherit, so it is done
# here at the predicate and proved by a control that plants a comment mention
# and requires it to FAIL.
#
# Exit codes, deliberately distinct:
#   0  every test file added or renamed by this change is invoked by it
#   1  at least one NEW test is dark. Wire it or delete it.
#   3  CANNOT-RUN. No merge-base, not a git tree, no runners found. NOTHING was
#      checked, which is not a pass.
# ============================================================================

set -uo pipefail

RC_OK=0
RC_DARK=1
RC_CANNOT_RUN=3

BASE_REF="${OSTLER_WIRING_BASE:-origin/main}"

cannot_run() {
    echo "" >&2
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was checked. This is not a pass." >&2
    exit "$RC_CANNOT_RUN"
}

git rev-parse --git-dir >/dev/null 2>&1 || cannot_run "not inside a git work tree"

# THREE-DOT. The question is "what does this change ADD", which is the diff
# from the MERGE BASE, not from the current tip of main. A two-dot diff also
# reports files main gained while this branch was open, and would demand the
# author wire somebody else's test.
MB="$(git merge-base "$BASE_REF" HEAD 2>/dev/null)"
[ -n "$MB" ] || cannot_run "no merge-base between $BASE_REF and HEAD; cannot tell what this change added"

# Added (A) or Renamed (R). A renamed test is a new path and its old invocation,
# if any, now points at nothing.
ADDED="$(git diff --diff-filter=AR --name-only "$MB"...HEAD 2>/dev/null \
         | grep -E '(^|/)tests?/.*/?test_[^/]*\.(sh|py)$' || true)"

if [ -z "$ADDED" ]; then
    echo "PASS: this change adds no test files, so none can be dark."
    exit "$RC_OK"
fi

# ---------------------------------------------------------------------------
# Where an invocation can legitimately live: CI workflows, and any shell or
# python runner in the tree (a test invoked BY a wired runner is wired).
# ---------------------------------------------------------------------------
RUNNERS="$(git ls-files \
           | grep -E '^\.github/workflows/.*\.ya?ml$|\.sh$|\.py$|^Makefile$|/Makefile$' || true)"
RUNNER_N="$(printf '%s' "$RUNNERS" | grep -c . )"
[ "${RUNNER_N:-0}" -gt 0 ] || cannot_run "no workflow or runner files found to search; every test would score dark for want of anywhere to look"

# COMMENT-STRIPPED corpus. Built once. `#` to end of line for both YAML and
# shell; python comments share the character. This is the line that makes the
# gate count invocations rather than mentions.
CORPUS="$(mktemp -t newtestwiring_XXXXXX)"
trap 'rm -f "$CORPUS"' EXIT
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    sed 's/#.*$//' "$f"
done <<EOF >"$CORPUS"
$RUNNERS
EOF

DARK=""
CHECKED=0
while IFS= read -r t; do
    [ -n "$t" ] || continue
    CHECKED=$((CHECKED + 1))
    base="$(basename "$t")"
    # The path OR the bare basename, in comment-stripped runner text. A test is
    # commonly invoked by full path from a workflow and by basename from a
    # sibling runner, so both count -- but only outside comments.
    if grep -qF -e "$t" -e "$base" "$CORPUS" 2>/dev/null; then
        printf '  WIRED  %s\n' "$t"
    else
        printf '  DARK   %s\n' "$t"
        DARK="${DARK}    ${t}
"
    fi
done <<EOF
$ADDED
EOF

echo ""
echo "test files added or renamed by this change: ${CHECKED}"
echo "runner files searched (comments stripped):  ${RUNNER_N}"
echo ""

if [ -n "$DARK" ]; then
    echo "FAIL: this change adds test file(s) that NOTHING invokes:" >&2
    printf '%s' "$DARK" >&2
    echo "" >&2
    echo "  A test nobody runs is not coverage, it is a green light with no bulb" >&2
    echo "  behind it. Wire each file above into a workflow or a runner that CI" >&2
    echo "  actually executes, or delete it." >&2
    echo "" >&2
    echo "  NAMING IT IN A COMMENT WILL NOT SATISFY THIS GATE. Runner files are" >&2
    echo "  comment-stripped before they are searched, precisely because the" >&2
    echo "  standing wiring gate scores a test WIRED when a workflow merely" >&2
    echo "  mentions it." >&2
    exit "$RC_DARK"
fi

echo "PASS: all ${CHECKED} test file(s) added by this change are invoked by it."
exit "$RC_OK"
