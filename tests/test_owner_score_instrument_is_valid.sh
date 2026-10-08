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
