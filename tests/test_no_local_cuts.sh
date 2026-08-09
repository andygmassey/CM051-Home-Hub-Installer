#!/usr/bin/env bash
# tests/test_no_local_cuts.sh -- gate for v1018-D027.
#
# Asserts that `make ship` CANNOT sign/notarise a DMG outside CI.
#
# This gate is negative-control-by-construction: its whole assertion is that a
# command FAILS. It cannot silently always-pass the way a "grep finds the fix"
# assertion can, because a broken guard makes the command succeed and the test
# go red. That property is the point -- per the v1.0.19 contract, a gate with no
# demonstrated RED is not a gate.
#
# It also checks the three notarise entry points directly, so removing the guard
# from `ship` alone does not reopen the hole.
#
# Runs in seconds: `make` stops at the first failing prerequisite, so nothing is
# ever built, signed or uploaded.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

# The guard reads $CI / $GITHUB_ACTIONS. Strip them so this test is meaningful
# when it runs IN CI -- otherwise it would assert nothing there, which is
# precisely where it matters most.
run_local() {
	env -u CI -u GITHUB_ACTIONS -u OSTLER_EMERGENCY_CUT \
	    -u OSTLER_EMERGENCY_REASON -u OSTLER_SHIPPING_LEDGER \
	    make -C "$GUI_DIR" "$@" 2>&1
}

echo "v1018-D027: local cuts must be impossible"

# 1. The headline assertion.
out="$(run_local ship)"; rc=$?
if [ "$rc" -ne 0 ]; then pass "make ship exits non-zero outside CI (rc=$rc)"
else fail "make ship SUCCEEDED outside CI -- local cutting is still possible"; fi

# 2. It must say why, not just die. A refusal nobody understands gets patched out.
if printf '%s' "$out" | grep -q 'v1018-D027'; then
	pass "refusal cites the ledger ID"
else fail "refusal does not cite v1018-D027 -- operator cannot trace it"; fi
if printf '%s' "$out" | grep -qi 'git tag'; then
	pass "refusal tells the operator how to cut properly"
else fail "refusal gives no route forward -- invites working around it"; fi

# 3. Direct entry points must also refuse (defence in depth).
for t in notarise-hub notarise-app notarise-dmg; do
	run_local "$t" >/dev/null 2>&1
	if [ $? -ne 0 ]; then pass "make $t refuses outside CI"
	else fail "make $t SUCCEEDED outside CI -- bypasses the ship guard"; fi
done

# 4. The emergency path must fail closed on an incomplete invocation. Each of
#    these is a way a hurried operator could produce an unrecorded cut.
emerg() { env -u CI -u GITHUB_ACTIONS OSTLER_EMERGENCY_CUT=1 "$@" \
	          make -C "$GUI_DIR" guard-local-cut >/dev/null 2>&1; }

emerg; [ $? -ne 0 ] && pass "emergency without a reason is refused" \
                    || fail "emergency cut allowed with NO reason -- unattributable"

emerg OSTLER_EMERGENCY_REASON=test
[ $? -ne 0 ] && pass "emergency without a ledger path is refused" \
             || fail "emergency cut allowed with NO ledger -- silent hand-cut"

emerg OSTLER_EMERGENCY_REASON=test OSTLER_SHIPPING_LEDGER=/nonexistent/ledger.yaml
[ $? -ne 0 ] && pass "emergency with an unwritable ledger is refused (fails closed)" \
             || fail "emergency cut allowed with unwritable ledger -- no record"

# 5. Positive control: the emergency path must actually WORK when used properly,
#    and must leave a record. A guard that can never be satisfied gets deleted.
tmp_ledger="$(mktemp -t shipping_ledger)"
if env -u CI -u GITHUB_ACTIONS \
       OSTLER_EMERGENCY_CUT=1 \
       OSTLER_EMERGENCY_REASON="gate self-test, not a real cut" \
       OSTLER_SHIPPING_LEDGER="$tmp_ledger" \
       make -C "$GUI_DIR" guard-local-cut >/dev/null 2>&1; then
	pass "properly-formed emergency cut is permitted"
	if grep -q 'emergency_cut:' "$tmp_ledger" && grep -q 'reason:' "$tmp_ledger"; then
		pass "emergency cut wrote an attributable ledger entry"
	else fail "emergency permitted but NOTHING recorded -- the silent hand-cut we are preventing"; fi
else
	fail "properly-formed emergency cut was refused -- guard is unusable, will be removed"
fi
rm -f "$tmp_ledger"

echo ""
if [ "$fails" -eq 0 ]; then echo "v1018-D027: GREEN"; exit 0; fi
echo "v1018-D027: RED ($fails failing)"; exit 1
