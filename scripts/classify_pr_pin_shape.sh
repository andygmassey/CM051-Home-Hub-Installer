#!/usr/bin/env bash
#
# classify_pr_pin_shape.sh <base_sha> <head_sha>
#
# Prints exactly one word on stdout: `block` or `report`.
#
#   block   this branch EDITS a cuts/<tag>/cut.env, so it ASSERTS a pin. That
#           assertion is checkable right now, so the caller must check it and
#           fail on a stale pin.
#   report  this branch asserts no pin. A stale pin is expected background, not
#           this branch's defect, so the caller warns and does not block.
#
# ============================================================================
# WHY THIS IS A SCRIPT AND NOT FOUR LINES OF YAML
# ============================================================================
#
# It WAS four lines of YAML, and it shipped with a two-dot diff that classified
# most open PRs as `block`. Nothing could test it, because logic living inside a
# workflow `run:` block is only exercised by opening a pull request -- which is
# exactly when a false red does its damage.
#
# Extracting it is the fix for the CLASS. The dots are the fix for the instance.
#
# ============================================================================
# THE DOTS ARE THE WHOLE CORRECTNESS
# ============================================================================
#
# `pull_request.base.sha` is the base branch TIP at event time, NOT the
# merge-base. Two-dot `git diff A B` therefore reports MAIN'S OWN MOVEMENT since
# the branch point as though this branch had made it.
#
# Measured on PR #496 against main fe9a3d17:
#     two-dot    9 cut.env hits   -> would classify `block`, hard-fail on a pin
#                                    #496 never touched
#     three-dot  0 cut.env hits   -> `report`, which is correct
#
# It would have fired on every PR older than the last cut.env change, which was
# most of the 55 then open. That is the permanent false red the split predicate
# exists to prevent, reintroduced one line below the comment explaining it.
#
# THREE-DOT IS NOT UNIVERSALLY "THE RIGHT ONE". It is right HERE because the
# question is "what did this BRANCH change since it diverged". It is the WRONG
# operator for "has this work landed on main", where it overstates by counting
# things the branch never did. Same operator, opposite correctness, depending on
# the question. Pick it by the question, never by habit.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

# The path shape that means "this branch is asserting a pin".
CUT_ENV_RE='^cuts/.*/cut\.env$'

usage() { echo "usage: $0 <base_sha> <head_sha>" >&2; exit 2; }

classify() {
    local base="$1" head="$2"

    # An unresolvable ref is a broken probe, not a clean `report`. Say so and
    # exit 2: a classifier that cannot see the diff must never quietly choose
    # the non-blocking branch, because that is how a real pin change slips past.
    git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || {
        echo "CANNOT-RUN: base '$base' does not resolve" >&2; return 2; }
    git rev-parse --verify --quiet "${head}^{commit}" >/dev/null || {
        echo "CANNOT-RUN: head '$head' does not resolve" >&2; return 2; }

    local changed
    # THREE dots. See the header. This is the line that was wrong.
    changed="$(git diff --name-only "${base}...${head}" 2>/dev/null)" || {
        echo "CANNOT-RUN: git diff failed for ${base}...${head}" >&2; return 2; }

    if printf '%s\n' "$changed" | grep -qE "$CUT_ENV_RE"; then
        echo block
    else
        echo report
    fi
    return 0
}

# --- self-test ---------------------------------------------------------------
#
# Control (2) is the one Archie's review caught and it is the reason this file
# exists: a branch that touches NO cut.env, on a main that HAS moved cut.env
# since the merge-base. Under two-dot that classified `block`. It must be
# `report`.
if [ "${1:-}" = "--self-test" ]; then
    p=0; f=0
    ok() { printf '  PASS  %s\n' "$1"; p=$((p+1)); }
    no() { printf '  FAIL  %s\n' "$1"; f=$((f+1)); }
    d="$(mktemp -d -t pinshape-XXXXXX)"; trap 'rm -rf "$d"' EXIT
    (
      cd "$d"
      git init -q .; git config user.email t@t; git config user.name t
      mkdir -p cuts/v1.0.30
      printf 'CM051=aaa\n' > cuts/v1.0.30/cut.env
      printf 'echo hi\n' > install.sh
      git add -A; git commit -qm base
      git branch fork                      # <- merge-base for both branches

      # main moves ON ITS OWN and edits a cut.env. This is the confounder.
      mkdir -p cuts/v1.0.32
      printf 'CM051=bbb\n' > cuts/v1.0.32/cut.env
      git add -A; git commit -qm "main moves cut.env after the fork"

      # branch A: touches ONLY install.sh
      git checkout -q -b only-install fork
      printf 'echo changed\n' > install.sh
      git add -A; git commit -qm "install.sh only"

      # branch B: touches a cut.env
      git checkout -q -b asserts-pin fork
      printf 'CM051=ccc\n' > cuts/v1.0.30/cut.env
      git add -A; git commit -qm "re-point the pin"
      git checkout -q master 2>/dev/null || git checkout -q main
    ) >/dev/null 2>&1

    cd "$d" || exit 2
    MAIN="$(git rev-parse HEAD)"
    ONLY_INSTALL="$(git rev-parse only-install)"
    ASSERTS="$(git rev-parse asserts-pin)"

    r="$(classify "$MAIN" "$ONLY_INSTALL")"
    [ "$r" = "report" ] \
      && ok "(1) branch touching only install.sh -> report" \
      || no "(1) expected report, got '$r'"

    # THE REGRESSION CONTROL. Same branch, and main HAS moved cut.env since the
    # merge-base. Two-dot returns 'block' here. Three-dot must return 'report'.
    two_dot_hits="$(git diff --name-only "$MAIN" "$ONLY_INSTALL" | grep -cE "$CUT_ENV_RE" || true)"
    if [ "$two_dot_hits" -ge 1 ] && [ "$r" = "report" ]; then
        ok "(2) main moved cut.env since the fork (two-dot sees $two_dot_hits) and it is STILL report"
    elif [ "$two_dot_hits" -lt 1 ]; then
        no "(2) FIXTURE BROKEN: two-dot sees no cut.env, so this proves nothing"
    else
        no "(2) REGRESSION: main's own cut.env move classified this branch as '$r'"
    fi

    r="$(classify "$MAIN" "$ASSERTS")"
    [ "$r" = "block" ] \
      && ok "(3) branch that DOES edit a cut.env -> block" \
      || no "(3) expected block, got '$r'"

    classify "deadbeefdeadbeef" "$MAIN" >/dev/null 2>&1
    [ $? -eq 2 ] \
      && ok "(4) unresolvable base -> CANNOT-RUN exit 2, never a silent 'report'" \
      || no "(4) an unresolvable base did not produce exit 2"

    echo
    echo "=== $p passed / $f failed ==="
    [ "$f" -eq 0 ]; exit $?
fi

[ $# -eq 2 ] || usage
classify "$1" "$2"
exit $?
