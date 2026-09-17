#!/usr/bin/env bash
#
# test_download_currency_gate_is_wired.sh
#
# scripts/verify_customer_download_is_current.sh answers CM051 #2107: is the
# build customers download the newest build that earned it? The answer is
# worthless if nothing asks.
#
# THIS REPO HAS SHIPPED THAT EXACT FAILURE TWICE AND BOTH ARE NAMED IN THE TREE:
#   #449   scripts/run_all_cut_gates.sh, invoked by nothing
#   #1322  scripts/verify_must_contain_has_box_verdict.sh, 137 lines, zero call
#          sites, found by grepping for its own name and getting zero
# and the gate this one sits beside, scripts/verify_customer_download_path.sh,
# was #886: shipped, then invoked by nothing until a workflow was written for it.
#
# So this test asserts the INVOCATION, not the behaviour. The behaviour is
# proven by the mutation step in the workflow itself, which runs both red arms
# on the runner before the real run.
#
# Exit: 0 wired | 1 not wired | 2 CANNOT-RUN

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_REL='scripts/verify_customer_download_is_current.sh'
WF_REL='.github/workflows/customer-download-path.yml'
GATE="${ROOT}/${GATE_REL}"
WF="${ROOT}/${WF_REL}"

rc=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; rc=1; }
cant(){ printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

[[ -r "$GATE" ]] || cant "no ${GATE_REL}"
[[ -r "$WF"   ]] || cant "no ${WF_REL}"

# 1. executable, because a workflow step that runs `bash <file>` would still
#    work on a non-executable file and hide the bit rotting away.
[[ -x "$GATE" ]] && ok "${GATE_REL} is executable" || bad "${GATE_REL} is not executable"

# 2. THE INVOCATION. Counted, and the count must be >= 1 in a run: context.
#    Anchored on the basename so a path change inside the workflow still
#    matches, and deliberately NOT anchored on the whole command line, which
#    would make this test fail on a harmless reformat.
n_inv="$(/usr/bin/grep -c 'verify_customer_download_is_current\.sh' "$WF" || true)"
if [[ "${n_inv:-0}" -ge 1 ]]; then
    ok "${WF_REL} names the gate ${n_inv} time(s)"
else
    bad "${WF_REL} does NOT name ${GATE_REL}. The gate is dark: it can answer #2107 and nothing asks it."
fi

# 3. THE TRIGGER THAT MAKES THE ANSWER MOVE. The expected version is derived
#    from the walk records, so a landing walk record is the event that changes
#    it. Without this path the workflow is armed for the wrong events -- which
#    is precisely how the neighbouring gate stayed green for 59 versions: its
#    only source of an expectation was a human typing into workflow_dispatch.
if /usr/bin/grep -qE "^ *- 'walks/\*\*'" "$WF"; then
    ok "${WF_REL} re-runs when a walk record lands (walks/** in the trigger paths)"
else
    bad "${WF_REL} has no walks/** trigger path. A new walk record would change the expected version and nothing would re-measure."
fi

# 4. SELF-PROOF: this test must FAIL when the invocation is removed.
#    A wiring test that passes on an unwired tree is the same defect it exists
#    to catch, one level up. Run against a COPY; the real tree is untouched.
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "${TD}/.github/workflows" "${TD}/scripts" "${TD}/tests"
/usr/bin/sed '/verify_customer_download_is_current\.sh/d' "$WF" > "${TD}/${WF_REL}"
cp "$GATE" "${TD}/${GATE_REL}"
cp "${BASH_SOURCE[0]}" "${TD}/tests/$(basename "${BASH_SOURCE[0]}")"
mut_out="$(/bin/bash "${TD}/tests/$(basename "${BASH_SOURCE[0]}")" 2>&1)"; mut_rc=$?
if [[ "$mut_rc" -eq 1 ]] && printf '%s' "$mut_out" | /usr/bin/grep -q 'does NOT name'; then
    ok "self-proof: with the invocation deleted this test returns 1 and says why"
else
    bad "self-proof FAILED: a tree with the invocation deleted scored rc=${mut_rc}. This test cannot detect the thing it exists to detect."
    printf '%s\n' "$mut_out" | /usr/bin/sed 's/^/       | /' >&2
fi

if [[ $rc -eq 0 ]]; then
    printf 'PASS: the download-currency gate is invoked, triggered by walk records, and this test can prove its own absence.\n'
else
    printf 'FAIL: see above.\n' >&2
fi
exit $rc
