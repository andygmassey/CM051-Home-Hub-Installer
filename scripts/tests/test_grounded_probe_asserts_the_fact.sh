#!/usr/bin/env bash
# scripts/tests/test_grounded_probe_asserts_the_fact.sh
# ============================================================================
# assistant_answers_grounded is BLOCKING, and until 2026-09-07 it adjudicated
# on FRAME SHAPES ONLY: a pwg_ tool fired, returned OK, the turn completed ->
# grounded. Measured on Archie's seeded v1.0.74 walk: the assistant called
# pwg_people, got OK, and told the customer it had "no explicit information"
# about where she works while the graph served the fact on two endpoints. The
# probe scored it GREEN. A blocking probe that passes a wrong answer is worse
# than none.
#
# The probe now asserts CONTENT on the seeded turn: the reply must carry the
# fixture fact, computed on the box, with only a YES/NO crossing the wire.
# This test locks three things about that change:
#
#   1  THE PROBE'S OWN CONTROL FIRES. --self-test exits 1 without BROKEN and
#      its EXAMINED line names the fixture count, so the eleven fixtures --
#      including Archie's real must-FAIL and the constructed must-PASS --
#      all ran.
#   2  THE PRE-FIX ADJUDICATOR IS THE CONTROL. The function as it stood on
#      origin/main (a340ce91), carried here verbatim because a squash merge
#      orphans its commit, returns `grounded` on Archie's must-FAIL
#      transcript. The fixed one returns `fact_missing` on the same file.
#      That difference is the fix; without this arm a green would not say
#      which adjudicator produced it.
#   3  THE FIXTURE IS LOAD-BEARING. A mutant of the probe with the
#      reply_fact line removed must make the probe's --self-test report
#      CONTROL DID NOT FIRE. Proved landed by diff before its verdict.
#
# Exit: 0 all arms behaved, 1 an arm failed, 2 could not run.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/assistant_answers_grounded.sh"
LIB_DIR="$REPO_ROOT/scripts/box_walk_probes/lib"
RC_FAIL=1; RC_CANNOT_RUN=2

cannot_run() { echo "" >&2; echo "CANNOT-RUN: $1" >&2; echo "  NOTHING was checked. This is not a pass." >&2; exit "$RC_CANNOT_RUN"; }
fail() { echo "FAIL [$1]: $2" >&2; exit "$RC_FAIL"; }
count() { printf '%s\n' "$2" | grep -cF -- "$1"; }

for need in python3 diff sed; do
    command -v "$need" >/dev/null 2>&1 || cannot_run "$need not on PATH"
done
[[ -f "$PROBE" ]] || cannot_run "no probe at $PROBE"
[[ -f "$LIB_DIR/probe.sh" ]] || cannot_run "no probe lib at $LIB_DIR/probe.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/grounded.XXXXXX")" || cannot_run "could not create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# Archie's measured turn 1, minimal variant, plus the on-box verdict the
# client now emits for it. Synthetic fixture person; safe to commit.
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME chunk_reset\nFRAME reply_fact NO\nFRAME done\n' > "$WORK/must_fail"

# ── arm 1: the probe's own control fires ─────────────────────────────────
out="$(/bin/bash "$PROBE" --self-test 2>&1)"; rc=$?
[[ "$rc" -eq 1 ]] || fail arm-1 "--self-test exited ${rc}, expected 1 (a negative control that cannot go red proves nothing): ${out}"
[[ "$(count 'VERDICT: BROKEN' "$out")" -eq 0 ]] || fail arm-1 "--self-test reported BROKEN: ${out}"
[[ "$(count 'EXAMINED: 23 ' "$out")" -eq 1 ]] || fail arm-1 "--self-test did not examine the 23 fixtures and cases this change declares: $(printf '%s\n' "$out" | grep '^EXAMINED')"
[[ "$(count 'fact_missing' "$out")" -ge 1 ]] || fail arm-1 "--self-test's verdict does not name fact_missing, so the seeded fixture was not what fired: ${out}"
echo "PASS [arm-1]: the probe's --self-test fires on 23 fixtures and names fact_missing"

# ── arm 2: the pre-fix adjudicator is the control ────────────────────────
# Verbatim from origin/main a340ce91, 2026-09-07. It knows no reply_fact.
cat > "$WORK/prefix_adjudicate.sh" <<'FIXTURE'
_GRAPH_TOOL_RE='^FRAME tool_call pwg_'
adjudicate_turn() {
    _t="$1"
    grep -q '^PROBE_FATAL' "$_t" && { echo "fatal"; return; }
    grep -q '^FRAME done$' "$_t" || { echo "incomplete"; return; }
    grep -q '^FRAME tool_call ' "$_t" || { echo "no_tool_call"; return; }
    grep -qE "$_GRAPH_TOOL_RE" "$_t" || { echo "memory_only"; return; }
    grep -q '^FRAME tool_result pwg_.* OK$' "$_t" && { echo "grounded"; return; }
    grep -q '^FRAME tool_result pwg_.* ERR$' "$_t" && { echo "tool_error"; return; }
    grep -q '^FRAME tool_result pwg_.* EMPTY$' "$_t" && { echo "tool_found_nothing"; return; }
    echo "grounded"
}
FIXTURE
pre="$(bash -c '. "$1"; adjudicate_turn "$2"' _ "$WORK/prefix_adjudicate.sh" "$WORK/must_fail")"
[[ "$pre" == "grounded" ]] || cannot_run "the pre-fix control did not return grounded on the must-FAIL transcript (got '${pre}'); the fixture no longer describes the bug"
# The fixed adjudicator, extracted from the live probe.
awk '/^adjudicate_turn\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$PROBE" > "$WORK/fixed_adjudicate.sh"
[[ -s "$WORK/fixed_adjudicate.sh" ]] || cannot_run "could not extract adjudicate_turn from the probe"
post="$(bash -c '_GRAPH_TOOL_RE="^FRAME tool_call pwg_"; . "$1"; adjudicate_turn "$2"' _ "$WORK/fixed_adjudicate.sh" "$WORK/must_fail")"
[[ "$post" == "fact_missing" ]] || fail arm-2 "the fixed adjudicator returned '${post}' on Archie's must-FAIL transcript, expected fact_missing"
echo "PASS [arm-2]: pre-fix adjudicator says grounded, fixed one says fact_missing, on the same measured transcript"

# ── arm 3: the fixture is load-bearing (mutant) ──────────────────────────
mkdir -p "$WORK/mut/probes"; ln -sfn "$LIB_DIR" "$WORK/mut/lib"
# shellcheck disable=SC2016  # the literal $_t text is the subject of the sed
sed -e '/^    grep -q .\^FRAME reply_fact NO\$. "\$_t" && { echo "fact_missing"; return; }$/d' "$PROBE" > "$WORK/mut/probes/assistant_answers_grounded.sh"
changed="$(diff "$PROBE" "$WORK/mut/probes/assistant_answers_grounded.sh" | grep -c '^<')"
[[ "$changed" -eq 1 ]] || cannot_run "mutant did not land: ${changed} removed line(s), wanted 1"
mout="$(/bin/bash "$WORK/mut/probes/assistant_answers_grounded.sh" --self-test 2>&1)"; mrc=$?
if [[ "$mrc" -eq 1 && "$(count 'CONTROL DID NOT FIRE' "$mout")" -eq 0 ]]; then
    fail arm-3 "mutant SURVIVED: with the reply_fact line removed the probe's self-test still fired cleanly, so the seeded fixture is decoration"
fi
echo "PASS [arm-3]: the mutant is caught (self-test rc=${mrc}, CONTROL DID NOT FIRE lines=$(count 'CONTROL DID NOT FIRE' "$mout"))"

echo ""
echo "ALL GROUNDED-PROBE CONTENT-ASSERTION TESTS PASSED"
exit 0
