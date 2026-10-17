#!/usr/bin/env bash
# tests/test_owner_score_instrument_is_valid.sh
#
# VALIDATE THE CHECK BEFORE GRADING ANYTHING AGAINST IT (Lane 17).
# scripts/owner_score/ is the 80-question owner-knowledge score. A score is only
# worth reading if the instrument has been seen to give 100% to known-good
# answers and ~0% to blank, shuffled (wrong-person), "I don't know", echoed and
# shotgun answers, to refuse when its questions or graders are edited, and to
# keep the held-back 20 out of its output. All of that is asserted in
# scripts/owner_score/test_owner_score.py; this wrapper makes it a named,
# wired test, then proves the walk probe's adjudicator can go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

python3 -I "$HERE/scripts/owner_score/test_owner_score.py" || fail=1
python3 -I -W ignore "$HERE/scripts/owner_score/test_context_swap.py" || fail=1

# the persona seed and its exact purge, against the REAL Oxigraph engine (pyoxigraph).
# Exit 77 is CANNOT-RUN, and CANNOT-RUN is not a pass: it fails here.
"${OSTLER_PYTHON:-python3}" -I -W ignore "$HERE/scripts/owner_score/test_seed_persona.py"
rc=$?
if [ "$rc" -eq 77 ]; then
    echo "FAIL: CANNOT-RUN the seed/purge proof (pip install pyoxigraph, or set OSTLER_PYTHON to a python that has it)"; fail=1
elif [ "$rc" -ne 0 ]; then
    fail=1
fi

# the 80Q runs LAST in the walk, and the probe is a declared writer that does not
# use the retired --no-verbatim flag
PROBE="$HERE/scripts/box_walk_probes/probes/owner_knowledge_score.sh"
RUNNER="$HERE/scripts/box_walk_probes/run_box_walk.sh"
grep -q '^# WALK_WRITES:' "$PROBE" || { echo "FAIL: owner_knowledge_score does not declare WALK_WRITES"; fail=1; }
grep -q -- '--no-verbatim' "$PROBE" && { echo "FAIL: the probe still passes --no-verbatim"; fail=1; }
_pin="$(grep -n '^PROBES="$(pin_last owner_knowledge_score)"' "$RUNNER" | head -1 | cut -d: -f1)"
_promo="$(grep -n 'probe order now:' "$RUNNER" | head -1 | cut -d: -f1)"
_loop="$(grep -n '^export OSTLER_WALK_READ_ONLY=' "$RUNNER" | head -1 | cut -d: -f1)"
if [ -z "$_pin" ] || [ -z "$_promo" ] || [ -z "$_loop" ] || [ "$_pin" -le "$_promo" ] || [ "$_pin" -ge "$_loop" ]; then
    echo "FAIL: pin_last owner_knowledge_score is not between the promotion block ($_promo) and the probe loop's export ($_loop): $_pin"; fail=1
fi
(
    set +u
    HERE_W="$HERE/scripts/box_walk_probes"
    . "$HERE_W/lib/promote_order.sh"
    PROBES="$(ls "$HERE_W"/probes/*.sh | LC_ALL=C sort | tr '\n' ' ')"
    _c="$(printf '%s\n' $PROBES | grep -n 'owner_knowledge_score' | cut -d: -f1)"
    _n="$(printf '%s\n' $PROBES | wc -l | tr -d ' ')"
    [ "$_c" -lt "$_n" ] || { echo "CONTROL BROKEN: owner_knowledge_score is already last under the C sort, so the pin proves nothing"; exit 1; }
    PROBES="$(promote_order "owner_knowledge_score assistant_answers_grounded")"
    PROBES="$(pin_last owner_knowledge_score)"
    [ "$(basename "$(printf '%s\n' $PROBES | tail -1)" .sh)" = "owner_knowledge_score" ] || { echo "FAIL: owner_knowledge_score is not the last probe after promotion + pin"; exit 1; }
    [ "$(printf '%s\n' $PROBES | wc -l | tr -d ' ')" = "$_n" ] || { echo "FAIL: pin_last added or dropped a probe"; exit 1; }
) || fail=1

# the committed question files regenerate byte-for-byte from their builder, so
# a hand edit that skipped the builder (and the re-lock) is caught
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$HERE"/scripts/owner_score/*.py "$HERE"/scripts/owner_score/persona.json "$tmp"/
( cd "$tmp" && python3 -I build_questions.py >/dev/null ) || fail=1
for f in questions_visible.jsonl questions_heldout.jsonl; do
    cmp -s "$tmp/$f" "$HERE/scripts/owner_score/$f" || { echo "FAIL: $f does not match build_questions.py output"; fail=1; }
done

# the probe's own negative controls: --self-test must come back FAIL (rc 1) by design
bash "$HERE/scripts/box_walk_probes/probes/owner_knowledge_score.sh" --self-test >/dev/null 2>&1
[ $? -eq 1 ] || { echo "FAIL: owner_knowledge_score --self-test did not return its expected control FAIL"; fail=1; }

# the wrapper refuses a changed check with exit 3 (copy the tree, soften a grader)
cp -R "$HERE/scripts/owner_score" "$tmp/os" && rm -rf "$tmp/os/__pycache__"
echo "# softer" >> "$tmp/os/grading.py"
python3 -I "$tmp/os/owner_score.py" --print-checksum >/dev/null 2>&1
[ $? -eq 3 ] || { echo "FAIL: an edited grader was not refused with exit 3"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: owner-score instrument validated"
exit "$fail"
