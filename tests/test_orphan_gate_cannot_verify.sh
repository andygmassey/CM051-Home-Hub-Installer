#!/usr/bin/env bash
# tests/test_orphan_gate_cannot_verify.sh
# ============================================================================
# The orphan gate must distinguish "I could not look" from "I looked and found
# abandoned work", and must never present the first as the second.
#
# WHY THIS EXISTS
# ---------------
# v1.0.22 (run 31478119136) was the first tag whose preflight passed, so it was
# the first time check-orphans had ever executed in hosted CI. It printed:
#
#   [RED]  CM044: /Users/runner/Developer/CM044-PWG-Personal-Wiki is not a git
#          checkout -- cannot verify
#   ... the same for CM041, CM059, CM031 and the daemon ...
#   == summary: 1 repo(s) checked, 6 orphaned, 101 warning(s) ==
#   ERROR: work exists that is NOT in what you are about to ship.
#
# Six orphaned. In fact: one real finding, and five directories that cannot
# exist on a hosted runner because their defaults are $HOME/Developer and
# $HOME/Documents/Projects -- the operator's Mac. $HOME is /Users/runner there.
#
# Two separate defects, both of the same family as the one the gate polices:
#
#   1. A hard gate encoding an environmental assumption, so check-orphans could
#      not have passed in CI on ANY tag
#      (feedback_dont_invent_environmental_facts_in_hard_gates).
#   2. A verdict reported for something never measured. "cannot verify" was
#      counted as "orphaned" and summed into a total that reads as findings.
#
# The sixth RED was real -- a genuinely unmerged branch -- but the gate reached
# it through a tokenless `gh pr list` that failed and was treated as "no PR".
# A blind instrument returning the right answer is the most dangerous outcome
# available, because it gets believed
# (feedback_validate_the_probe_before_believing_its_answer).
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_no_orphaned_fixes.sh"
fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

echo "orphan gate: cannot-verify is not a finding"

work="$(mktemp -d "${TMPDIR:-/tmp}/orphan-cv.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A real, clean, single-commit repo to stand in for the cut repo, so the run
# has something it CAN check and the outcome turns only on the absent sibling.
real="$work/real"
mkdir -p "$real"
git -C "$real" init -q
git -C "$real" config user.email t@example.invalid
git -C "$real" config user.name  T
: > "$real/f"
git -C "$real" add f
git -C "$real" -c commit.gpgsign=false commit -qm init
git -C "$real" branch -M main
# A remote whose main IS the shipping ref: no orphans by construction.
bare="$work/bare.git"
git init -q --bare "$bare"
git -C "$real" remote add origin "$bare"
git -C "$real" push -q origin main
git -C "$real" fetch -q origin

: > "$work/empty-deferrals.yaml"

# `nonexistent` is the point: a path that is not a git checkout, exactly as
# every sibling default is on a hosted runner.
run_gate() {   # $1 = extra env assignments (may be empty)
	env OSTLER_CUT_DEFERRALS="$work/empty-deferrals.yaml" \
	    OSTLER_ORPHAN_GATE_REPOS="CUT|$real|origin/main|;SIB|$work/nonexistent|origin/main|" \
	    ${1:+$1} \
	    bash "$GATE" 2>&1
}

# -- 1. UNDECLARED unreachable repo: must fail closed ------------------------
out="$(run_gate "")"; rc=$?
if [ "$rc" -ne 0 ]; then
	pass "undeclared unreachable repo fails closed (rc=$rc)"
else
	fail "undeclared unreachable repo PASSED -- a repo nobody looked at read as clean"
fi

# -- 2. ...but it must say CANNOT VERIFY, not 'orphaned' ---------------------
if printf '%s' "$out" | grep -q 'CANNOT VERIFY'; then
	pass "names it CANNOT VERIFY"
else
	fail "does not say CANNOT VERIFY -- the v1.0.22 wording is back"
fi
if printf '%s' "$out" | grep -q 'NOT a finding of orphaned work'; then
	pass "states explicitly that nothing was measured"
else
	fail "does not disclaim the finding -- reads as abandoned work"
fi
if printf '%s' "$out" | grep -q 'CANNOT-VERIFY, not orphaned work'; then
	pass "summary separates cannot-verify from real findings"
else
	fail "summary lumps cannot-verify in with orphaned work"
fi

# -- 3. DECLARED unreachable repo: proceeds, but says so loudly --------------
out2="$(run_gate "OSTLER_ORPHAN_GATE_SKIP=SIB")"; rc2=$?
if [ "$rc2" -eq 0 ]; then
	pass "declared-unverifiable repo does not block the cut"
else
	fail "declaring a repo unverifiable still blocks (rc=$rc2) -- no route forward"
fi
if printf '%s' "$out2" | grep -q 'NOT CHECKED IN THIS ENVIRONMENT: SIB'; then
	pass "names the unchecked repo by label"
else
	fail "unchecked repo is not named -- coverage gap is invisible"
fi
if printf '%s' "$out2" | grep -q 'GREEN, PARTIAL'; then
	pass "green is qualified as PARTIAL when coverage is incomplete"
else
	fail "reports unqualified GREEN while a repo went unexamined"
fi
# The exact failure mode being prevented: a declared skip quietly becoming a
# full clean bill. The word GREEN alone must never appear unqualified here.
if printf '%s' "$out2" | grep -qE '^GREEN: every written fix'; then
	fail "unqualified 'GREEN: every written fix' printed despite 1 repo unchecked"
else
	pass "does not claim every fix was checked when one repo was not"
fi

# -- 4. positive control: all repos reachable -> plain GREEN -----------------
out3="$(env OSTLER_CUT_DEFERRALS="$work/empty-deferrals.yaml" \
            OSTLER_ORPHAN_GATE_REPOS="CUT|$real|origin/main|" \
            bash "$GATE" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ] && printf '%s' "$out3" | grep -qE '^GREEN: every written fix'; then
	pass "control: fully-checked clean run still reports plain GREEN"
else
	fail "control: a clean fully-checked run no longer passes (rc=$rc3) -- gate is unusable"
fi
# Match the BLOCK HEADER, not the bare phrase: the summary line always carries
# "N NOT CHECKED" including at zero, so grepping "NOT CHECKED" alone matches a
# correct run. Caught by this control on first execution.
if printf '%s' "$out3" | grep -q 'NOT CHECKED IN THIS ENVIRONMENT'; then
	fail "control: reports unchecked repos when every repo was checked"
else
	pass "control: no spurious NOT CHECKED on a complete run"
fi

# -- 5. gh_as must not clobber an ambient token ------------------------------
# The v1.0.22 mechanism exactly: `GH_TOKEN="$tok" gh ...` with an empty $tok
# exports GH_TOKEN as "", which means UNAUTHENTICATED, not "inherit". So the
# assignment meant to add credentials stripped the ones already present.
probe="$(
	# shellcheck disable=SC2016
	cat <<'SH'
gh() { printf 'GH_TOKEN=[%s]\n' "${GH_TOKEN-UNSET}"; }
SH
)"
got_empty="$(
	eval "$probe"
	# Mirror gh_as's body rather than sourcing the gate, which would run it.
	gh_as() { local t="$1"; shift; if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi; }
	GH_TOKEN=ambient-token gh_as "" pr list
)"
if [ "$got_empty" = "GH_TOKEN=[ambient-token]" ]; then
	pass "empty per-owner token leaves the ambient GH_TOKEN intact"
else
	fail "empty token clobbers ambient credentials -- got '$got_empty'"
fi
got_explicit="$(
	eval "$probe"
	gh_as() { local t="$1"; shift; if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi; }
	GH_TOKEN=ambient-token gh_as owner-token pr list
)"
if [ "$got_explicit" = "GH_TOKEN=[owner-token]" ]; then
	pass "an explicit per-owner token still wins over the ambient one"
else
	fail "per-owner token no longer overrides ambient -- got '$got_explicit'"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "orphan gate cannot-verify: GREEN"; exit 0; fi
echo "orphan gate cannot-verify: RED ($fails failing)"; exit 1
