#!/usr/bin/env bash
# ============================================================================
# THE PR-AGE EXEMPTION BLOCK MUST DRAIN, NOT ACCRETE.
#
# scripts/verify_pr_age.sh grew an escape hatch -- pr_exemptions: in
# cut-deferrals.yaml -- so a deliberately-blocked PR need not red the gate. By
# 2026-10-17 that hatch held ~783 rows, every one expired, and the gate spent
# its run re-reding a legacy pile rather than policing new debt. The escape
# hatch had become the backlog it was meant to prevent.
#
# Two mechanisms, tested here, keep it honest:
#
#   AUTO-RETIRE  an exemption whose PR has already merged or closed defers a PR
#                that no longer exists. One `gh pr view --json state` resolves
#                that, the row is dropped from the LIVE count and listed as
#                retireable -- never counted, never a failure.
#
#   LIVE CAP     the count of LIVE rows (unexpired review_by AND a still-open
#                PR) may not exceed pr_exemptions_live_cap. Over the cap is RED:
#                the hatch is accreting faster than it drains.
#
# The cap is monotonic in RESOLVED-OPEN rows only. An unresolved PR state
# (UNKNOWN: unreachable repo, auth gap) is never counted as live, so a
# credential accident can only ever UNDER-count -- it can never manufacture a
# cap breach. Control 4 pins that.
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_pr_age.sh"

pass=0; fail=0
ok()  { printf '  [ok]     %s\n' "$*"; pass=$(( pass + 1 )); }
bad() { printf '  [FAIL]   %s\n' "$*"; fail=$(( fail + 1 )); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# A gh shim answering BOTH calls the gate makes:
#   pr list --repo R ...          -> [] (reachable, zero open PRs, so the per-PR
#                                    sweep can never produce a violation and
#                                    every verdict below is attributable to the
#                                    ledger alone)
#   pr view N --repo R --json ... -> a state keyed off the PR number, and the
#                                    call is logged so control 5 can prove the
#                                    gate only ever views UNEXPIRED, resolvable
#                                    rows (bounded network, not one call per
#                                    row in the whole file).
# `auth ...` is refused (exit 1), reproducing a hosted runner with no
# `gh auth login`, so the gate falls through to ambient auth exactly as in prod.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then exit 1; fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    num="$3"
    printf 'view %s\n' "$num" >> "${GH_VIEW_CALLS}"
    case " ${GH_MERGED:-} " in *" $num "*) echo MERGED; exit 0 ;; esac
    case " ${GH_CLOSED:-} " in *" $num "*) echo CLOSED; exit 0 ;; esac
    echo OPEN; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[]'; exit 0
fi
exit 1
SHIM
chmod +x "${WORK}/bin/gh"

# One repo, so owner_repo_for_short() in the gate can map the SHORT ref name
# (CM051-Home-Hub-Installer#101) to owner/repo for `gh pr view`.
ONE="owner/CM051-Home-Hub-Installer"

# A deferrals file. Portable, fixed sentinel dates -- 2099 is always unexpired,
# 2000 always expired -- so no scenario depends on `date` arithmetic agreeing
# across macOS and Linux.
#   101-104  OPEN,   unexpired  -> 4 LIVE
#   200      MERGED, unexpired  -> retireable, NOT live
#   201      CLOSED, unexpired  -> retireable, NOT live
#   300      OPEN,   EXPIRED    -> not live, and MUST NOT be `gh pr view`ed
#   CM999-Nope#1  unknown repo, unexpired -> UNKNOWN, never live
cat > "${WORK}/deferrals.yaml" <<'YAML'
pr_exemptions_live_cap: 3

pr_exemptions:
  - ref: "CM051-Home-Hub-Installer#101"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#102"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#103"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#104"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#200"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#201"
    reason: "x"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#300"
    reason: "x"
    review_by: 2000-01-01
  - ref: "CM999-Nope#1"
    reason: "x"
    review_by: 2099-01-01
YAML

# run_gate <cap-override-or-empty> -> sets OUT, RC, and VIEW_CALLS file is fresh
run_gate() {
    local cap="$1"
    : > "${WORK}/views"
    local -a env=(
        "PATH=${WORK}/bin:${PATH}"
        "GH_VIEW_CALLS=${WORK}/views"
        "GH_MERGED=200"
        "GH_CLOSED=201"
        "PR_AGE_REPOS=${ONE}"
        "OSTLER_CUT_DEFERRALS=${WORK}/deferrals.yaml"
    )
    [[ -n "$cap" ]] && env+=("PR_AGE_LIVE_CAP=${cap}")
    OUT="$(env "${env[@]}" bash "${GATE}" 2>&1)"
    RC=$?
}

echo "== the PR-age exemption block drains, it does not accrete =="
echo ""

# --- 1. OVER THE CAP -> RED, exit 1, and SAYS why ---------------------------
# 4 live (101-104) over the file's cap of 3.
run_gate ""
if [[ "${RC}" == "1" ]] && grep -q 'exceed the cap of 3' <<< "${OUT}"; then
    ok "1. 4 live exemptions over a cap of 3 -> RED (exit 1), naming the breach"
else
    bad "1. over-cap did not RED as expected (rc=${RC})"
fi

# --- 2. AUTO-RETIRE: merged/closed rows are listed, and NOT counted live ----
# If 200/201 had counted, the ledger would read "6 open", not "4 open".
if grep -q 'live exemptions: 4 open / cap 3' <<< "${OUT}" \
   && grep -q 'RETIREABLE' <<< "${OUT}" \
   && grep -q -- '- CM051-Home-Hub-Installer#200 (MERGED)' <<< "${OUT}" \
   && grep -q -- '- CM051-Home-Hub-Installer#201 (CLOSED)' <<< "${OUT}"; then
    ok "2. merged/closed exemptions are listed RETIREABLE and excluded from the live count"
else
    bad "2. auto-retire did not drop/attribute the merged+closed rows"
fi

# --- 3. UNDER THE CAP -> GREEN. Same file, cap raised to 10. -----------------
# The cap -- not something incidental -- is what drives the verdict: the only
# thing that changed between RED and GREEN is the number.
run_gate "10"
if [[ "${RC}" == "0" ]] \
   && grep -q 'live exemptions: 4 open / cap 10' <<< "${OUT}" \
   && grep -q 'GREEN' <<< "${OUT}"; then
    ok "3. same live set under a cap of 10 -> GREEN (exit 0): the cap drives the verdict"
else
    bad "3. under-cap run did not pass cleanly (rc=${RC})"
fi

# --- 4. FAIL-SAFE: an UNKNOWN state is never counted live -------------------
# CM999-Nope#1 is unexpired but names a repo this run cannot resolve. Were
# UNKNOWN counted as live, the count would be 5; the "4 open" above already
# proves it is not. Here we assert it is surfaced as unresolved, not silently
# dropped, so a credential gap is visible rather than laundered into a pass.
if grep -q '1 unresolved' <<< "${OUT}"; then
    ok "4. an unresolvable exemption is counted 'unresolved', never as a live row"
else
    bad "4. the unresolved exemption was not surfaced"
fi

# --- 5. BOUNDED NETWORK: only UNEXPIRED, resolvable rows are viewed ---------
# 101,102,103,104,200,201 = 6 views. The EXPIRED row (300) and the UNKNOWN-repo
# row (CM999) cost no `gh pr view`. A gate that viewed every row in an 800-row
# file would make 800 calls; this one makes as many as there are live candidates.
views="$(wc -l < "${WORK}/views" | tr -d ' ')"
if [[ "${views}" == "6" ]]; then
    ok "5. exactly 6 'gh pr view' calls -- the expired and unknown-repo rows cost none"
else
    bad "5. expected 6 pr-view calls (unexpired+resolvable only), saw ${views}"
fi

echo ""
echo "== ${pass} passed, ${fail} failed =="
if (( fail > 0 )); then exit 1; fi
exit 0
