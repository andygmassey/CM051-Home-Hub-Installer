#!/usr/bin/env bash
# ============================================================================
# THE PR-AGE GATE MUST SAY WHAT IT COULD NOT CHECK -- AND MUST NOT PASS ON IT.
#
# scripts/verify_pr_age.sh sweeps seven repos. When `gh pr list` fails for one
# -- which on a hosted runner is EVERY sibling, because the ship step sets
# GH_TOKEN to the repo-scoped secrets.GITHUB_TOKEN and a repo-scoped token
# cannot list a sibling repo's PRs even under the same owner -- it prints one
# [warn] line and CONTINUES.
#
# MEASURED 2026-08-20, same tree, same hour, same script:
#
#     all 7 repos reachable (operator Mac)  ->  17 over 48h   rc=1
#     CM051 only  (what CI can resolve)     ->   0 over 48h   rc=0
#
# The gate was GREEN in CI while blind to six of seven repos, and nothing in
# its output said so. Its sibling verify_no_orphaned_fixes.sh has printed
# "GREEN, PARTIAL" and "NOT CHECKED IN THIS ENVIRONMENT" since #643. Same
# repo, same cut, two gates, opposite honesty.
#
# THIS WAS ONCE REPORTING-ONLY, ON PURPOSE (#881): the exit code was left
# unchanged, and control 6 below pinned that, because "quietly red a launch
# cut" was called a release decision, not a gate decision, and printing the
# shortfall was the first, safer step. MEASURED 2026-09-12 against the live
# estate that deferral cost: the one repo CI could resolve had 1 unmarked PR
# over 30 days old; the six it could not see had 13 between them. The debt
# accumulated exactly where the gate was blind, while every run said success.
#
# So this is the follow-up #881 named and Archie's own comment deferred:
# an UNDECLARED blind spot is now a FAILURE (exit 3, "CANNOT VERIFY" --
# reusing the code and the wrapper message the total-blindness case already
# had, so gui/Makefile's check-pr-age needs no change to report it correctly).
# A human can still choose a genuinely narrowed run on purpose, by naming the
# repo(s) in PR_AGE_ALLOW_PARTIAL -- the same grammar PR_AGE_REPOS already
# uses. Control 6 below now asserts the OPPOSITE of what it asserted before:
# an undeclared partial run must FAIL, and a declared one must not.
#
# Making the gate actually SEE the siblings in CI (resolving a per-owner token
# the way #643 taught the orphan gate) is the companion fix, wired in cut.yml
# with the existing OSTLER_GH_TOKEN_ANDYGMASSEY secret -- no credential was
# created or rotated for it. See the PR body for what remains unconfirmed.
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_pr_age.sh"

pass=0; fail=0; cannot=0
ok()     { printf '  [ok]     %s\n' "$*"; pass=$(( pass + 1 )); }
bad()    { printf '  [FAIL]   %s\n' "$*"; fail=$(( fail + 1 )); }
cannot() { printf '  [CANNOT] %s\n' "$*"; cannot=$(( cannot + 1 )); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# A gh shim. REACHABLE is a newline-separated list of repos it will answer for;
# every other repo exits 1, which is exactly what a repo-scoped token produces.
# An answered repo returns [] -- zero PRs -- so no scenario here can generate a
# violation by accident and every rc below is attributable to the patch alone.
#
# `auth token -u <owner>` is answered (refused) FIRST and BEFORE the call is
# logged: the fixed gate now calls this once per repo, resolving a per-owner
# credential (see token_for_owner() in the gate). Logging it would inflate the
# call count in assertion 0 for a reason that has nothing to do with the
# scenario being tested. Refusing it (exit 1, no output) reproduces exactly
# what a hosted runner does -- there is no `gh auth login` there -- so the
# gate falls through to its ambient GH_TOKEN, unchanged from before this
# function existed.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then exit 1; fi
repo=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$repo" >> "${GH_SHIM_CALLS}"
while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    if [[ "$r" == "$repo" ]]; then printf '[]'; exit 0; fi
done <<< "${GH_SHIM_REACHABLE}"
exit 1
SHIM
chmod +x "${WORK}/bin/gh"

: > "${WORK}/empty-deferrals.yaml"

THREE="owner/CM051-Home-Hub-Installer
owner/CM044-PWG-Personal-Wiki
owner/HR015-Gaming-PC"

# run_gate <reachable-list> <script> -> writes $OUT, sets $RC
run_gate() {
    local reachable="$1" script="$2"
    : > "${WORK}/calls"
    OUT="$(PATH="${WORK}/bin:${PATH}" \
           GH_SHIM_REACHABLE="${reachable}" \
           GH_SHIM_CALLS="${WORK}/calls" \
           PR_AGE_REPOS="${THREE}" \
           OSTLER_CUT_DEFERRALS="${WORK}/empty-deferrals.yaml" \
           bash "${script}" 2>&1)"
    RC=$?
}

echo "== the PR-age gate declares what it could not check =="
echo ""

# --- 0. ANTI-VACUITY: the shim must actually be the gh that ran -------------
run_gate "owner/CM051-Home-Hub-Installer" "${GATE}"
if [[ "$(wc -l < "${WORK}/calls" | tr -d ' ')" == "3" ]]; then
    ok "0. the shim intercepted all 3 gh calls -- results below are attributable"
else
    bad "0. shim saw $(wc -l < "${WORK}/calls" | tr -d ' ') calls, expected 3 -- every verdict below is unattributable"
fi

PARTIAL_OUT="${OUT}"; PARTIAL_RC="${RC}"

# --- 1. an UNDECLARED partial run is LABELLED RED, never GREEN --------------
# Nobody named these repos in PR_AGE_ALLOW_PARTIAL, so this is the accident-
# of-credentials shape, not a decision -- it can never read as GREEN.
if grep -q 'VERDICT: RED, PARTIAL' <<< "${PARTIAL_OUT}" \
   && grep -q 'NOT DECLARED' <<< "${PARTIAL_OUT}"; then
    ok "1. undeclared partial run prints 'VERDICT: RED, PARTIAL ... NOT DECLARED'"
else
    bad "1. undeclared partial run did NOT print the RED/NOT-DECLARED verdict"
fi

# --- 2. it NAMES the repos it could not read --------------------------------
if grep -q 'NOT CHECKED IN THIS ENVIRONMENT' <<< "${PARTIAL_OUT}" \
   && grep -q -- '- owner/CM044-PWG-Personal-Wiki' <<< "${PARTIAL_OUT}" \
   && grep -q -- '- owner/HR015-Gaming-PC' <<< "${PARTIAL_OUT}"; then
    ok "2. both unreachable repos are named, not just counted"
else
    bad "2. unreachable repos were not named"
fi

# --- 3. the DENOMINATOR is in the headline ----------------------------------
# "1 repo(s) checked" cannot distinguish one-of-one from one-of-seven.
if grep -q '1 of 3 repo(s) checked' <<< "${PARTIAL_OUT}"; then
    ok "3. headline carries the denominator ('1 of 3'), not the numerator alone"
else
    bad "3. headline still reports a bare numerator"
fi

# --- 4. a COMPLETE run must NOT claim to be partial (the other direction) ----
run_gate "${THREE}" "${GATE}"
COMPLETE_OUT="${OUT}"; COMPLETE_RC="${RC}"
if grep -q 'VERDICT: GREEN -- all 3 repo(s) checked' <<< "${COMPLETE_OUT}" \
   && ! grep -q 'PARTIAL' <<< "${COMPLETE_OUT}" \
   && ! grep -q 'NOT CHECKED IN THIS ENVIRONMENT' <<< "${COMPLETE_OUT}"; then
    ok "4. a complete run says GREEN and never says PARTIAL"
else
    bad "4. complete run mislabelled (a gate that always cries PARTIAL gets ignored)"
fi

# --- 5. DEMONSTRATED RED against the PRE-FIX script -------------------------
# Not "the fixed one passes" -- the prior artefact must be shown to fail.
#
# THE BASELINE MUST BE AN IMMUTABLE COMMIT, NEVER A MOVING REF.
#
# This control originally read `origin/main`. That WAS the pre-fix state while
# #881 was open, and became the POST-fix state the instant #881 merged. The
# control then loaded the FIXED script, correctly observed it distinguishing
# partial from complete, and reported "this patch fixes nothing". It went red
# at 5eece4c -- the merge commit of the very fix it was written to defend --
# and stayed red through 5d2e1b1 and be31bfc. Last green was 8651a54, the
# commit before the merge.
#
# So this was not a flake and not a regression in verify_pr_age.sh. A control
# whose baseline moves when the fix lands inverts ON MERGE, by construction.
# The pin below is the whole fix.
#
# cac9299 is the last commit to touch scripts/verify_pr_age.sh BEFORE #881.
# NEVER advance it. It is a historical fact about what the defect looked like,
# not a pointer to current state. If verify_pr_age.sh is rewritten again, the
# new anti-vacuity proof needs its OWN pinned baseline, not this one moved.
PREFIX_REF="cac9299"

# Reachability first. fetch-depth: 0 in cut-gate-wrappers.yml is load-bearing
# for exactly this line, and its comment says so. A shallow clone cannot see
# cac9299, and that must be CANNOT-RUN rather than a silent pass.
BASE="$(git -C "${REPO_ROOT}" show "${PREFIX_REF}:scripts/verify_pr_age.sh" 2>/dev/null)"
if [[ -z "${BASE}" ]]; then
    cannot "5. ${PREFIX_REF}:scripts/verify_pr_age.sh unreachable (shallow clone?) -- pre-fix comparison NOT performed"
else
    # A CONTROL ON THE CONTROL. If the pinned blob is byte-identical to the
    # current script then the pin is aimed at the wrong commit, or the fix has
    # been reverted. Either way assertion 5 below would pass for a reason that
    # has nothing to do with the pre-fix script failing, so refuse instead.
    if [[ "${BASE}" == "$(cat "${GATE}")" ]]; then
        bad "5a. pinned baseline ${PREFIX_REF} is IDENTICAL to the current gate -- the pin is wrong or the fix was reverted. Assertion 5 cannot mean anything."
    else
        ok "5a. pinned baseline ${PREFIX_REF} differs from the current gate, so the comparison is meaningful"
    fi

    printf '%s' "${BASE}" > "${WORK}/prefix-gate.sh"
    run_gate "owner/CM051-Home-Hub-Installer" "${WORK}/prefix-gate.sh"
    if grep -q 'PARTIAL\|NOT CHECKED IN THIS ENVIRONMENT\|1 of 3' <<< "${OUT}"; then
        bad "5. pre-fix script at ${PREFIX_REF} ALREADY distinguished partial from complete -- this patch fixes nothing"
    else
        ok "5. DEMONSTRATED RED: pre-fix script at ${PREFIX_REF} reported a 2-of-3-blind run with no partiality marker"
    fi
fi

# --- 6. THE GUARD: an unreachable repo must fail the gate, where it used to
# pass. NEW pinned baseline, per the instruction on PREFIX_REF above -- a
# rewritten gate needs its OWN anti-vacuity proof, not the old one moved.
#
# 5eece4c0 is #881's own merge commit: the gate that FIRST printed "GREEN,
# PARTIAL" and "NOT CHECKED IN THIS ENVIRONMENT" -- correct reporting -- but
# left the exit code at 0 on purpose (see the header). That is the immediate
# pre-this-fix state, distinct from cac9299 above (which predates #881
# entirely and printed no partiality marker at all). Two different defects,
# two different pinned baselines.
MAKES_PARTIAL_RED_REF="5eece4c0"
BASE2="$(git -C "${REPO_ROOT}" show "${MAKES_PARTIAL_RED_REF}:scripts/verify_pr_age.sh" 2>/dev/null)"
if [[ -z "${BASE2}" ]]; then
    cannot "6. ${MAKES_PARTIAL_RED_REF}:scripts/verify_pr_age.sh unreachable (shallow clone?) -- guard NOT demonstrated"
else
    if [[ "${BASE2}" == "$(cat "${GATE}")" ]]; then
        bad "6a. pinned baseline ${MAKES_PARTIAL_RED_REF} is IDENTICAL to the current gate -- the pin is wrong or the fix was reverted"
    else
        ok "6a. pinned baseline ${MAKES_PARTIAL_RED_REF} differs from the current gate, so the comparison is meaningful"
    fi

    printf '%s' "${BASE2}" > "${WORK}/prefix2-gate.sh"
    run_gate "owner/CM051-Home-Hub-Installer" "${WORK}/prefix2-gate.sh"
    PREFIX_PARTIAL_RC="${RC}"

    # THE PROOF THE TASK ASKS FOR: same scenario (2 of 3 repos unreachable, 0
    # violations among what was checked), run against BOTH scripts. The old
    # one must have PASSED (rc=0, the defect); the new one must FAIL (rc!=0).
    if [[ "${PREFIX_PARTIAL_RC}" == "0" ]]; then
        ok "6b. DEMONSTRATED RED: pre-fix gate (${MAKES_PARTIAL_RED_REF}) exits 0 on a 2-of-3-blind, zero-violation run -- the defect this PR fixes"
    else
        bad "6b. pre-fix gate (${MAKES_PARTIAL_RED_REF}) did NOT exit 0 on the partial scenario (rc=${PREFIX_PARTIAL_RC}) -- control invalid, assertion 6c proves nothing"
    fi

    if [[ "${PARTIAL_RC}" != "0" && "${PARTIAL_RC}" == "3" ]]; then
        ok "6c. the FIX: same scenario now exits 3 (CANNOT VERIFY) where it previously exited 0 -- it now fails where it used to pass"
    else
        bad "6c. fixed gate did not fail closed on the undeclared partial run (rc=${PARTIAL_RC}, expected 3)"
    fi
fi

# --- 6d. a genuinely DECLARED narrowing is still allowed to pass ------------
# The fix must not become a blanket ban on partial runs -- only on UNDECLARED
# ones. Naming the exact unreachable repos in PR_AGE_ALLOW_PARTIAL is the
# escape hatch, same grammar PR_AGE_REPOS already uses (see the gate's USAGE).
: > "${WORK}/calls"
DECLARED_OUT="$(PATH="${WORK}/bin:${PATH}" \
       GH_SHIM_REACHABLE="owner/CM051-Home-Hub-Installer" \
       GH_SHIM_CALLS="${WORK}/calls" \
       PR_AGE_REPOS="${THREE}" \
       PR_AGE_ALLOW_PARTIAL="owner/CM044-PWG-Personal-Wiki,owner/HR015-Gaming-PC" \
       OSTLER_CUT_DEFERRALS="${WORK}/empty-deferrals.yaml" \
       bash "${GATE}" 2>&1)"
DECLARED_RC=$?
if [[ "${DECLARED_RC}" == "0" ]] \
   && grep -q 'PARTIAL (DECLARED)' <<< "${DECLARED_OUT}" \
   && grep -q -- '- owner/CM044-PWG-Personal-Wiki (declared in PR_AGE_ALLOW_PARTIAL)' <<< "${DECLARED_OUT}"; then
    ok "6d. naming both unreachable repos in PR_AGE_ALLOW_PARTIAL passes (rc=0), and says so"
else
    bad "6d. a deliberately narrowed run did not pass (rc=${DECLARED_RC}) or did not label itself DECLARED"
fi

# --- 6e. a PARTIAL declaration is not a BLANKET one -------------------------
# Naming only one of the two unreachable repos must still fail on the other --
# the escape hatch is per-repo, not "any narrowing forgives every gap".
: > "${WORK}/calls"
HALF_OUT="$(PATH="${WORK}/bin:${PATH}" \
       GH_SHIM_REACHABLE="owner/CM051-Home-Hub-Installer" \
       GH_SHIM_CALLS="${WORK}/calls" \
       PR_AGE_REPOS="${THREE}" \
       PR_AGE_ALLOW_PARTIAL="owner/CM044-PWG-Personal-Wiki" \
       OSTLER_CUT_DEFERRALS="${WORK}/empty-deferrals.yaml" \
       bash "${GATE}" 2>&1)"
HALF_RC=$?
if [[ "${HALF_RC}" == "3" ]] \
   && grep -q -- '- owner/HR015-Gaming-PC$' <<< "${HALF_OUT}"; then
    ok "6e. declaring only ONE of two unreachable repos still fails, naming the undeclared one"
else
    bad "6e. a partial declaration incorrectly forgave a repo nobody named (rc=${HALF_RC})"
fi

# --- 7. fail-closed on TOTAL blindness is preserved -------------------------
run_gate "owner/nothing-resolves" "${GATE}"
if [[ "${RC}" == "3" ]] && grep -q 'CANNOT VERIFY' <<< "${OUT}"; then
    ok "7. zero reachable repos still exits 3 (CANNOT VERIFY), not 0"
else
    bad "7. total blindness no longer fails closed (rc=${RC})"
fi

echo ""
echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="
if (( fail > 0 )); then exit 1; fi
if (( cannot > 0 )); then exit 2; fi
exit 0
