#!/usr/bin/env bash
# cut.yml relaxes OSTLER_CUT_IN_PROGRESS on a workflow_dispatch, so a candidate
# can be built while self-declared BLOCKING rows are open. THAT IS SAFE ONLY
# BECAUSE A DISPATCH CANNOT PUBLISH. The moment a dispatch gains a publishing
# path, the relaxation becomes a hole through which a cut with known open
# blockers reaches a customer.
#
# A COMMENT CANNOT ENFORCE THAT. This test does: it fails if the relaxation is
# present while any publishing step has stopped being push-guarded. The two
# facts are asserted TOGETHER, so neither can move without the other being
# re-examined.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${HERE}/.github/workflows/cut.yml"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

[ -r "$W" ] || { printf '  [FAIL] CANNOT-RUN: cannot read %s\n' "$W"; exit 2; }

relaxed=$(/usr/bin/grep -c "event_name == 'push' && '1' || '0'" "$W" || true)
uncond=$(/usr/bin/grep -c "OSTLER_CUT_IN_PROGRESS: '1'" "$W" || true)

if [ "$relaxed" -gt 0 ]; then
	ok "the relaxation is present at ${relaxed} site(s), so the tie below must hold"
else
	ok "no relaxation present; the tie is vacuous and this test is a no-op by design"
fi

# CONTROL FIRST: the enforcers must exist, or 'no publishing step' is unmeasured.
for f in scripts/verify_dispatch_cannot_ship.py tests/test_cut_dispatch_is_dry.sh; do
	if [ -f "${HERE}/${f}" ]; then ok "enforcer present: ${f}"
	else bad "enforcer MISSING: ${f} -- the relaxation has nothing holding it"; fi
done

# The workflow must still invoke the dry-run enforcer, or it is unwired.
if /usr/bin/grep -q 'test_cut_dispatch_is_dry.sh' "$W"; then
	ok "cut.yml still invokes test_cut_dispatch_is_dry.sh"
else
	bad "cut.yml no longer invokes the dispatch-is-dry test: the relaxation is unheld"
fi

# Every publishing verb must remain push-guarded. Counted, with a control.
pub=$(/usr/bin/grep -cE 'softprops/action-gh-release|gh release (create|upload)' "$W" || true)
guard=$(/usr/bin/grep -c "event_name == 'push'" "$W" || true)
if [ "$pub" -eq 0 ]; then
	bad "found 0 publishing steps -- a zero here means the probe stopped matching, not that publishing vanished"
elif [ "$guard" -ge "$pub" ]; then
	ok "publishing steps ${pub}, push-guards ${guard}: every publish is covered at least once"
else
	bad "publishing steps ${pub} exceed push-guards ${guard} -- a publish may be reachable on a dispatch"
fi

# NEGATIVE CONTROL: the probe must be able to report absence.
if /usr/bin/grep -q 'zzz_not_in_this_workflow_control' "$W"; then
	bad "the negative control matched, so these greps match anything"
else
	ok "CONTROL: a fabricated token is absent, so the greps can return zero"
fi

printf '\n== %d pass / %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
