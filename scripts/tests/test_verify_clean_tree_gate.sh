#!/usr/bin/env bash
# ============================================================================
# test_verify_clean_tree_gate.sh -- prove the clean-tree gate FIRES.
#
# Per feedback_gate_must_prove_it_fires_not_just_compile: prove the gate REJECTS
# a dirty tree / wrong branch / detached HEAD, not just that it compiles. Builds
# a pristine throwaway git repo and drives the gate through CLEAN_TREE_REPO_DIR
# so the assertions never depend on the state of the real worktree.
# ============================================================================
set -uo pipefail    # NOT -e: run all cases even when one fails.

# Local git ops only, but keep the proxy out of the way (house rule).
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_clean_tree.sh"
MAKEFILE="${REPO_ROOT}/gui/Makefile"
RELEASE_SH="${REPO_ROOT}/release.sh"

[[ -x "${GATE}" ]] || chmod +x "${GATE}"

TMP="$(mktemp -d -t verify_clean_tree_gate_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# ----- pristine fixture repo on branch `main` -------------------------------
REPO="${TMP}/repo"
mkdir -p "${REPO}"
git init -q "${REPO}"
git -C "${REPO}" symbolic-ref HEAD refs/heads/main
git -C "${REPO}" config user.email "test@example.com"
git -C "${REPO}" config user.name  "Clean Tree Test"
git -C "${REPO}" config commit.gpgsign false
echo "hello" > "${REPO}/file.txt"
git -C "${REPO}" add file.txt
git -C "${REPO}" commit -q -m "initial"

PASS=0; FAIL=0
LAST_CAPTURE=""
run_case() { # name expected_rc  [env assignments...] -- run gate against ${REPO}
  local name="$1" exp="$2"; shift 2
  local cap="${TMP}/out.$$.${RANDOM}"
  printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${exp}"
  env CLEAN_TREE_REPO_DIR="${REPO}" "$@" "${GATE}" >"${cap}" 2>&1
  local rc=$?
  sed 's/^/  | /' "${cap}"
  LAST_CAPTURE="${cap}"
  if [[ "${rc}" -eq "${exp}" ]]; then
    printf 'PASS: %s (rc=%s)\n' "${name}" "${rc}"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s got rc=%s, expected %s\n' "${name}" "${rc}" "${exp}" >&2; FAIL=$((FAIL+1))
  fi
}
assert_contains() { # name needle
  if grep -qF -- "$2" "${LAST_CAPTURE}"; then
    printf 'PASS: %s\n' "$1"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (output missing %q)\n' "$1" "$2" >&2; FAIL=$((FAIL+1))
  fi
}

# --- CASE 1: clean + on main -> GREEN (rc 0) --------------------------------
run_case "clean checkout on expected branch main" 0
assert_contains "case 1 reports clean tree" "working tree is clean"
assert_contains "case 1 reports expected branch" "on expected branch 'main'"

# --- CASE 2: dirty (untracked junk) -> RED (rc 1) ---------------------------
touch "${REPO}/a-junk-file"
run_case "dirty tree (untracked a-junk-file)" 1
assert_contains "case 2 reports dirty tree" "working tree is DIRTY"
assert_contains "case 2 lists the junk file" "a-junk-file"

# --- CASE 3: dirty BUT ALLOW_DIRTY_CUT=1 -> WARN, GREEN (rc 0) ---------------
run_case "dirty but ALLOW_DIRTY_CUT=1 downgrades to WARN" 0 ALLOW_DIRTY_CUT=1
assert_contains "case 3 downgrades to WARN" "DOWNGRADED by ALLOW_DIRTY_CUT=1"
rm -f "${REPO}/a-junk-file"   # clean up

# --- CASE 4: wrong branch, EXPECTED_CUT_BRANCH EXPLICITLY pinned -> RED (rc 1) -
# Branch identity hard-fails ONLY when the operator explicitly pins the branch.
git -C "${REPO}" checkout -q -b feature/experiment
run_case "on feature branch, EXPECTED_CUT_BRANCH=main explicitly pinned" 1 EXPECTED_CUT_BRANCH=main
assert_contains "case 4 names actual vs pinned branch" "pinned to 'main'"
git -C "${REPO}" checkout -q main

# --- CASE 4b: wrong branch, NO explicit expectation -> WARN, GREEN (rc 0) ------
# A real cut runs from a cut-pin/integration branch; with no EXPECTED_CUT_BRANCH
# set, branch identity is advisory (WARN) and must NOT block the cut. This is the
# fix that stops the gate false-failing every real cut (cut-pin branch != main).
git -C "${REPO}" checkout -q feature/experiment
run_case "on feature branch, no EXPECTED_CUT_BRANCH -> advisory WARN, not fatal" 0
assert_contains "case 4b treats branch identity as advisory" "branch identity is advisory"
git -C "${REPO}" checkout -q main

# --- CASE 5: EXPECTED_CUT_BRANCH is configurable -> GREEN on feature ---------
git -C "${REPO}" checkout -q feature/experiment
run_case "configurable expected branch matches" 0 EXPECTED_CUT_BRANCH=feature/experiment
assert_contains "case 5 accepts the configured branch" "on expected branch 'feature/experiment'"
git -C "${REPO}" checkout -q main

# --- CASE 6: detached HEAD -> RED (rc 1) ------------------------------------
DET_SHA="$(git -C "${REPO}" rev-parse HEAD)"
git -C "${REPO}" checkout -q "${DET_SHA}"
run_case "detached HEAD (interrupted-rebase shape)" 1
assert_contains "case 6 detects detached HEAD" "HEAD is DETACHED"
git -C "${REPO}" checkout -q main

# --- CASE 6b: detached AT A TAG -> GREEN (the CI tag-push shape) -------------
# THE CONTROL FOR CASE 6. Case 6 alone cannot tell "refuses detached" from
# "refuses everything detached including the shape the cut actually uses".
# These two arms differ in EXACTLY ONE fact -- whether a tag points at HEAD --
# so together they prove the predicate discriminates rather than blanket-denies.
# Measured 2026-08-27: cut run 33074389084 built, signed, notarised and stapled
# a DMG and was then refused here, because a tag push always detaches.
git -C "${REPO}" tag -f archie-clean-tree-probe "${DET_SHA}" >/dev/null 2>&1
git -C "${REPO}" checkout -q "${DET_SHA}"
run_case "detached HEAD AT A TAG (the shape every tag-triggered cut has)" 0
assert_contains "case 6b accepts a tag as a fixed cut point" "detached at TAG"
git -C "${REPO}" checkout -q main
git -C "${REPO}" tag -d archie-clean-tree-probe >/dev/null 2>&1

# --- CASE 7: Makefile + release.sh wire-in (silent no-op guard) --------------
printf '\n=== CASE: gui/Makefile + release.sh wire the gate in ===\n'
mk_hits="$(grep -c 'check-clean-tree' "${MAKEFILE}")"
printf '  gui/Makefile mentions check-clean-tree %d time(s)\n' "${mk_hits}"
if [[ "${mk_hits}" -ge 3 ]] && grep -qE '^package:.*check-clean-tree' "${MAKEFILE}"; then
  printf 'PASS: Makefile wire-in (phony + target + package prereq)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: expected >=3 mentions incl a package: prereq\n' >&2; FAIL=$((FAIL+1))
fi
if grep -q 'verify_clean_tree.sh' "${RELEASE_SH}"; then
  printf 'PASS: release.sh runs the clean-tree preflight\n'; PASS=$((PASS+1))
else
  printf 'FAIL: release.sh does not wire verify_clean_tree.sh\n' >&2; FAIL=$((FAIL+1))
fi

printf '\n============================================================\n'
printf 'Clean-tree-gate self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
