#!/usr/bin/env bash
# cut.yml relaxes OSTLER_CUT_IN_PROGRESS on a workflow_dispatch so a candidate can
# be built while self-declared BLOCKING rows are open. THAT IS SAFE ONLY BECAUSE A
# DISPATCH CANNOT PUBLISH. The moment a dispatch gains a publishing path, the
# relaxation becomes a hole through which a cut with known open blockers reaches a
# customer. A comment cannot enforce that. This test does.
#
# 🔴 THE FIRST VERSION OF THIS TEST WAS THE DEFECT IT EXISTS TO PREVENT. It
# counted publishers with 'softprops/action-gh-release|gh release create|upload'.
# THIS REPO DOES NOT PUBLISH THAT WAY. That pattern matched exactly ONE line in
# cut.yml, line 140, which is a COMMENT listing patterns, and matched NEITHER real
# publisher. Archie proved it rather than inferring it: he injected an UNGUARDED
# `gh release create` step into cut.yml and this test still reported 6 pass / 0
# fail, "every publish is covered". It did not catch the exact hole it was written
# for. A probe keyed to a shape the subject does not use returns a confident pass.
#
# THE COUNT COMPARISON WAS ALSO WRONG IN PRINCIPLE, not just in its pattern: 4 of
# the 19 push-guards it counted were the relaxation lines themselves, so the
# relaxation inflated the very number meant to constrain it. This version asserts
# PER STEP that each real publisher carries its own push gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${HERE}/.github/workflows/cut.yml"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
[ -r "$W" ] || { printf '  [FAIL] CANNOT-RUN: cannot read %s\n' "$W"; exit 2; }

# The shapes THIS repo actually publishes through, per verify_dispatch_cannot_ship.py.
PUBLISH_RE='scripts/publish_release\.sh|make[^#]*publish-appcast'

# Non-comment invocation lines only. A comment naming a publisher is not a publisher.
mapfile -t PUB_LINES < <(/usr/bin/grep -nE "$PUBLISH_RE" "$W" | /usr/bin/awk -F: '{n=$1; $1=""; sub(/^:/,""); t=$0; sub(/^[ \t]+/,"",t); if (substr(t,1,1) != "#") print n}')

if [ "${#PUB_LINES[@]}" -eq 0 ]; then
	bad "found 0 publisher invocations. A zero here means the probe stopped matching, NOT that publishing vanished -- which is exactly how the previous version of this test passed while blind."
else
	ok "found ${#PUB_LINES[@]} real publisher invocation(s), comments excluded"
fi

# PER STEP: each publisher's own nearest preceding `if:` must carry the push gate.
# 🔴 AND THE FIRST ATTEMPT AT *THIS* VERSION WAS ALSO WRONG, caught by the same
# mutant. It took the last `if:` ANYWHERE above the publisher, which belongs to
# whatever step came before -- so an injected unguarded publisher inherited its
# NEIGHBOUR's push gate and reported "push-gated". The guard search must be
# bounded to the publisher's OWN step, from its `- name:` line forward.
for L in "${PUB_LINES[@]}"; do
	start="$(/usr/bin/grep -nE '^      - name:' "$W" | /usr/bin/awk -F: -v l="$L" '$1 < l {n=$1} END {print n+0}')"
	if [ "$start" -eq 0 ]; then
		bad "line ${L} has no enclosing step; cannot attribute a guard to it"
		continue
	fi
	guard="$(/usr/bin/sed -n "${start},${L}p" "$W" | /usr/bin/grep -E '^        if:' | /usr/bin/tail -1)"
	name="$(/usr/bin/sed -n "${start}p" "$W" | /usr/bin/sed 's/^ *- name: //')"
	case "$guard" in
		*"github.event_name == 'push'"*) ok "push-gated: ${name:0:58}" ;;
		*) bad "NOT push-gated, reachable on a dispatch: line ${L}, step '${name:0:48}', guard '${guard}'" ;;
	esac
done

# CONTROL, in-band: the comment at line ~140 names publisher shapes and must NOT be
# counted. If the comment-stripping breaks, this count rises and the arm above
# starts grading prose.
cmt=$(/usr/bin/grep -cE "^ *#.*($PUBLISH_RE)" "$W" || true)
if [ "$cmt" -gt 0 ]; then
	ok "CONTROL: ${cmt} COMMENT line(s) also name a publisher and were correctly excluded"
else
	bad "CONTROL FAILED: no commented publisher found, so the exclusion is untested by this run"
fi

# The enforcers the relaxation leans on must exist and stay wired.
for f in scripts/verify_dispatch_cannot_ship.py tests/test_cut_dispatch_is_dry.sh; do
	[ -f "${HERE}/${f}" ] && ok "enforcer present: ${f}" || bad "enforcer MISSING: ${f}"
done
/usr/bin/grep -q 'test_cut_dispatch_is_dry.sh' "$W" \
	&& ok "cut.yml still invokes test_cut_dispatch_is_dry.sh" \
	|| bad "cut.yml no longer invokes the dispatch-is-dry test: the relaxation is unheld"

# NEGATIVE CONTROL: the greps must be able to return zero.
/usr/bin/grep -q 'zzz_not_in_this_workflow_control' "$W" \
	&& bad "the negative control matched, so these greps match anything" \
	|| ok "CONTROL: a fabricated token is absent, so the greps can return zero"

printf '\n== %d pass / %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
