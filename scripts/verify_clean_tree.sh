#!/usr/bin/env bash
# verify_clean_tree.sh -- PRE-CUT wrong-branch / dirty-tree guard (CM051).
# ============================================================================
#
# THE FOOTGUN THIS PLUGS
# A DMG cut is only reproducible if it is cut from a KNOWN, CLEAN checkout on the
# expected branch. Cuts have started from a stale feature branch, from a detached
# HEAD left by an interrupted rebase, or from a tree with uncommitted local edits
# (a "quick fix" that never got committed and so was never reviewed). Each of
# those silently ships something other than what `origin/<branch>` says shipped.
# This gate is a fast, network-free assertion that the checkout the cut runs from
# is exactly what it claims to be.
#
# ASSERTIONS (fail-closed)
#   1. Working tree is CLEAN -- `git status --porcelain` is empty.
#      Opt-out: ALLOW_DIRTY_CUT=1 downgrades this to a WARN (dev/inspection only).
#   2. HEAD is on a NAMED branch, not detached (a detached HEAD is an interrupted
#      rebase/bisect artefact and is never a reproducible cut point -- HARD FAIL).
#      Branch IDENTITY is advisory by default: real cuts legitimately run from a
#      cut-pin / integration branch (e.g. chore/cut-pin-daemon-hub-...), not
#      always `main`, so a mismatch is a WARN. It becomes a HARD FAIL only when
#      the operator EXPLICITLY sets EXPECTED_CUT_BRANCH to pin a specific branch.
#   3. Worktree footgun (WARN only, never fatal): if this checkout is a git
#      WORKTREE (its `.git` is a file, not a dir) AND OSTLER_ASSISTANT_DIR (used
#      by the provenance gate) also points at a worktree pointer, the provenance
#      gate can misread the daemon checkout. Flagged with the fix hint; does NOT
#      block, because it is an environment shape, not a cut-content defect.
#
# Fast, no network. Standard house style: set -u, info/ok/warn/err, exit 0/1.
#
# Usage:  scripts/verify_clean_tree.sh
# Env:
#   EXPECTED_CUT_BRANCH   if set, the cut MUST run from this exact branch (HARD
#                         FAIL on mismatch). If unset, branch identity is a WARN
#                         only (default advisory branch shown = main).
#   ALLOW_DIRTY_CUT=1     downgrade the dirty-tree FAIL to WARN (dev only)
#   CLEAN_TREE_REPO_DIR   repo to inspect (default: this script's repo; tests)
#   OSTLER_ASSISTANT_DIR  read-only, for the worktree-footgun WARN
#
# Exit 0 = GREEN (clean + on expected branch). Exit 1 = BLOCK.

set -uo pipefail   # NOT -e: we classify every failure ourselves.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${CLEAN_TREE_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
# EXPECTED_CUT_BRANCH is a HARD gate only when the operator explicitly sets it to
# a non-empty value; otherwise branch identity is advisory (WARN) because cuts
# legitimately run from a cut-pin/integration branch, not always `main`.
if [ -n "${EXPECTED_CUT_BRANCH:-}" ]; then EXPECTED_BRANCH_EXPLICIT=1; else EXPECTED_BRANCH_EXPLICIT=0; fi
EXPECTED_CUT_BRANCH="${EXPECTED_CUT_BRANCH:-main}"
ALLOW_DIRTY_CUT="${ALLOW_DIRTY_CUT:-0}"

if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_0=""; fi
info() { printf '        %s\n' "$*"; }
ok()   { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*" >&2; }

FAIL=0

echo "=== Clean-tree pre-cut gate (CM051) ==="
echo "checkout:    ${REPO_DIR}"
if [ "${EXPECTED_BRANCH_EXPLICIT}" -eq 1 ]; then
    echo "expected:    branch '${EXPECTED_CUT_BRANCH}' (HARD -- explicitly pinned)"
else
    echo "expected:    any named branch (identity advisory; set EXPECTED_CUT_BRANCH to pin)"
fi

git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err "${REPO_DIR} is not a git working tree -- cannot assert cut cleanliness."
    exit 1
}
echo

# --- 1. clean working tree -------------------------------------------------
PORCELAIN="$(git -C "${REPO_DIR}" status --porcelain 2>/dev/null)"
if [ -z "${PORCELAIN}" ]; then
    ok "working tree is clean (no uncommitted or untracked changes)"
else
    N="$(printf '%s\n' "${PORCELAIN}" | grep -c '.')"
    if [ "${ALLOW_DIRTY_CUT}" = "1" ]; then
        warn "working tree is DIRTY (${N} change(s)) -- DOWNGRADED by ALLOW_DIRTY_CUT=1"
        info "dev/inspection override; a real cut must run from a clean tree."
    else
        err "working tree is DIRTY (${N} uncommitted/untracked change(s)) -- the cut would ship un-reviewed edits"
        info "commit, stash, or discard the changes below, then re-cut (or set ALLOW_DIRTY_CUT=1 for dev):"
        printf '%s\n' "${PORCELAIN}" | sed 's/^/          /' >&2
        FAIL=1
    fi
fi

# --- 2. on the expected branch (not detached) ------------------------------
BRANCH="$(git -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
HEAD_SHA="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?')"
if [ -z "${BRANCH}" ]; then
    # A DETACHED HEAD AT A TAG IS THE MOST REPRODUCIBLE CUT POINT THERE IS.
    #
    # This arm used to refuse every detached HEAD. That was written for a LOCAL
    # cut on a developer machine, where detached usually IS an interrupted
    # rebase. In CI it is the normal and correct shape: cut.yml triggers on a
    # tag push, and actions/checkout on a tag produces a detached HEAD BY
    # DEFINITION -- a tag is not a branch. So the gate could never pass on the
    # cut path, and nobody saw it because the orphan gate above it always
    # failed first. Measured on run 33074389084, 2026-08-27: the DMG built,
    # signed, notarised and stapled, and THEN this refused it.
    #
    # The refusal also had its own reasoning backwards. It called a detached
    # HEAD "non-reproducible". A tag is fixed; a BRANCH is the ref that moves.
    # Re-running a cut from a named branch a week later can produce a different
    # tree. Re-running it from a tag cannot.
    #
    # THREE OUTCOMES, not two. The interrupted-rebase case it was built for is
    # still refused -- that is a detached HEAD at NO tag.
    TAG_AT_HEAD="$(git -C "${REPO_DIR}" describe --exact-match --tags HEAD 2>/dev/null || true)"
    if [ -n "${TAG_AT_HEAD}" ]; then
        ok "HEAD is detached at TAG '${TAG_AT_HEAD}' (${HEAD_SHA}) -- a tag is a FIXED cut point"
        info "a tag cannot move; a branch can. This is stricter than a named branch, not looser."
    elif [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_SHA:-}" ] \
         && [ "${GITHUB_SHA}" = "$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || echo '')" ]; then
        # FALLBACK, and it says which evidence it used. A shallow checkout can
        # fetch the tagged COMMIT without the tag OBJECT, so `describe` finds
        # nothing even though the ref really is a tag. Accepting on CI metadata
        # is weaker than reading a tag object, so it is reported as such rather
        # than folded into the line above.
        ok "HEAD is detached at ${HEAD_SHA}, which CI declares is tag '${GITHUB_REF_NAME:-<unnamed>}'"
        info "established from CI metadata (GITHUB_REF_TYPE + GITHUB_SHA), NOT from a local tag object;"
        info "the tag object is absent from this shallow checkout, which is expected, not a fault."
    else
        err "HEAD is DETACHED (at ${HEAD_SHA}) and is NOT at a tag -- a cut must run from a named branch or a tag"
        info "a detached HEAD at no tag is a non-reproducible cut point (often an interrupted rebase/bisect artefact);"
        info "'git checkout <cut-branch>' and re-cut."
        FAIL=1
    fi
elif [ "${BRANCH}" != "${EXPECTED_CUT_BRANCH}" ]; then
    if [ "${EXPECTED_BRANCH_EXPLICIT}" -eq 1 ]; then
        err "on branch '${BRANCH}' but the cut was pinned to '${EXPECTED_CUT_BRANCH}' (at ${HEAD_SHA})"
        info "check out the pinned cut branch, or unset EXPECTED_CUT_BRANCH to make branch identity advisory."
        FAIL=1
    else
        warn "on branch '${BRANCH}' (at ${HEAD_SHA}) -- branch identity is advisory (no EXPECTED_CUT_BRANCH set)"
        info "cuts legitimately run from a cut-pin/integration branch (e.g. chore/cut-pin-daemon-hub-...), not always 'main'."
        info "to HARD-enforce a specific branch, export EXPECTED_CUT_BRANCH=<branch>."
    fi
else
    ok "on expected branch '${BRANCH}' (at ${HEAD_SHA})"
fi

# --- 3. worktree-pointer footgun (WARN only) -------------------------------
# When this checkout is a git worktree, its `.git` is a FILE (`gitdir: ...`),
# not a directory. If OSTLER_ASSISTANT_DIR also points at a worktree pointer,
# the provenance gate (which shells `git -C "$OSTLER_ASSISTANT_DIR"`) can misread
# the daemon checkout. ORM flagged this; it is an env shape, not a cut defect.
if [ -f "${REPO_DIR}/.git" ]; then
    warn "this checkout is a git WORKTREE (.git is a pointer file, not a dir)"
    if [ -n "${OSTLER_ASSISTANT_DIR:-}" ] && [ -f "${OSTLER_ASSISTANT_DIR}/.git" ]; then
        warn "OSTLER_ASSISTANT_DIR also points at a worktree pointer: ${OSTLER_ASSISTANT_DIR}/.git"
        info "the provenance gate can misread a worktree-pointer daemon checkout."
        info "fix hint: point OSTLER_ASSISTANT_DIR at a NORMAL clone (its own .git DIRECTORY), not a worktree."
    else
        info "(informational only -- provenance gate reads OSTLER_ASSISTANT_DIR; ensure that is a normal clone.)"
    fi
fi

# --- verdict ---------------------------------------------------------------
echo
echo "=== Verdict ==="
if [ "${FAIL}" -eq 0 ]; then
    echo "  ${C_G}CLEAN-TREE GREEN${C_0} -- clean checkout on the expected branch. Safe to cut."
    exit 0
else
    echo "  ${C_R}CLEAN-TREE RED${C_0} -- wrong branch and/or dirty tree. DO NOT CUT."
    exit 1
fi
