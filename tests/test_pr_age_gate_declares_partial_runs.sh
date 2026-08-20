#!/usr/bin/env bash
# ============================================================================
# THE PR-AGE GATE MUST SAY WHAT IT COULD NOT CHECK.
#
# scripts/verify_pr_age.sh sweeps seven repos. When `gh pr list` fails for one
# -- which on a hosted runner is EVERY sibling, because the ship step sets
# GH_TOKEN to the repo-scoped secrets.GITHUB_TOKEN and a repo-scoped token
# cannot list a sibling repo's PRs even under the same owner -- it prints one
# [warn] line and CONTINUES. Its exit logic fails closed only when NOTHING
# resolved:
#
#     if (( checked == 0 )); then ... exit 3
#
# So one reachable repo is enough to pass, however many were unreadable.
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
# THIS FIX CHANGES REPORTING ONLY -- NOT PASS/FAIL. Control 6 pins that,
# because a gate change that quietly reds a launch cut is a release decision,
# not a gate decision.
#
# Making the gate actually SEE the siblings (resolving OSTLER_GH_TOKEN_<ACCOUNT>
# the way #643 taught the orphan gate) is deliberately NOT in this change. That
# turns the gate red with 17 real rows and is Archie's to sequence.
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
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'SHIM'
#!/usr/bin/env bash
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

# --- 1. a partial run is LABELLED partial -----------------------------------
if grep -q 'VERDICT: GREEN, PARTIAL' <<< "${PARTIAL_OUT}"; then
    ok "1. partial run prints 'VERDICT: GREEN, PARTIAL'"
else
    bad "1. partial run did NOT print a PARTIAL verdict"
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
# Not "the fixed one passes" -- the prior artefact must be shown to fail. If
# origin/main is not fetchable this is CANNOT-RUN, never a silent skip.
BASE="$(git -C "${REPO_ROOT}" show origin/main:scripts/verify_pr_age.sh 2>/dev/null)"
if [[ -z "${BASE}" ]]; then
    cannot "5. origin/main:scripts/verify_pr_age.sh unavailable -- pre-fix comparison NOT performed"
else
    printf '%s' "${BASE}" > "${WORK}/prefix-gate.sh"
    run_gate "owner/CM051-Home-Hub-Installer" "${WORK}/prefix-gate.sh"
    if grep -q 'PARTIAL\|NOT CHECKED IN THIS ENVIRONMENT\|1 of 3' <<< "${OUT}"; then
        bad "5. pre-fix script ALREADY distinguished partial from complete -- this patch fixes nothing"
    else
        ok "5. DEMONSTRATED RED: pre-fix script reported a 2-of-3-blind run with no partiality marker"
    fi
fi

# --- 6. PASS/FAIL IS UNCHANGED ----------------------------------------------
# The whole claim that this can land mid-cut rests on this control.
if [[ "${PARTIAL_RC}" == "0" && "${COMPLETE_RC}" == "0" ]]; then
    ok "6. reporting-only: rc unchanged (partial=0, complete=0) -- cannot red a cut"
else
    bad "6. rc changed (partial=${PARTIAL_RC}, complete=${COMPLETE_RC}) -- this is no longer reporting-only"
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
