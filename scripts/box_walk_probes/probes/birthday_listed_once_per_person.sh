#!/usr/bin/env bash
# birthday_listed_once_per_person -- is a person who lives on two nodes (a survivor and a merged-in second
# card, one with two display names) listed exactly ONCE in the birthdays, and named exactly once in the
# birthday section of the morning brief?
#
# WALK_WRITES: seeds one synthetic Person across two nodes into Oxigraph, runs an UNDELIVERED copy of the
# morning-brief job (POST/DELETE /api/cron, delivery 'none' read back before it can fire), then DELETES the
# seed. The undo is verified by a triple count before and after. Judged from counts only; the invented
# surname never matches a real person and no brief sentence leaves the box.
#
# Why not the contact_cards_fixture cast: a cold-walk box seeds it only when the graph holds no real
# icloud_contact_uid, and no cast person holds two cards (no_person_holds_two_contact_cards, BLOCKING,
# would FAIL one). The duplicate shape is made here instead, in the store, under a fixture namespace.
#
# THREE MEASUREMENTS, each with its own control:
#   RAW     rows people_birthdays' own SPARQL returns for the fixture BEFORE its per-URI dedupe. Must be >= 2,
#           else a served count of 1 proves nothing (CANNOT, never PASS). This is the live control: the
#           duplicate is really there for the dedupe to remove.
#   SERVED  entries for the fixture person in /api/v1/people/birthdays?days=14 (the list the brief reads). Must be 1.
#   BRIEF   times the person is named in the birthday lines of the undelivered brief. Must be 1; 0 is CANNOT.
# NEGATIVE CONTROL (self-test): the judges must FAIL a count of 2 and refuse a vacuous 1.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk_fixture_122b2.sh"

PROBE_NAME="birthday_listed_once_per_person"
PROBE_QUESTION="seed one person on two nodes with a birthday today: is the person served once in the birthdays and named once in an undelivered morning brief?"

self_test() {
    local f s
    f="$(mktemp)"; trap 'rm -f "$f"' EXIT
    s="$(wf_judge judge_birthday 1 4 | cut -f1)"
    [ "$s" = "ok" ] || probe_pass "SELF-TEST BROKEN: 1 served over 4 raw rows judged '$s', expected ok."
    s="$(wf_judge judge_birthday 2 4 | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: 2 served over 4 raw rows judged '$s', expected FAIL (the dedupe-bypassed shape)."
    s="$(wf_judge judge_birthday 1 1 | cut -f1)"
    [ "$s" = "CANNOT" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: 1 served over 1 raw row judged '$s', expected CANNOT (vacuous: nothing to dedupe)."
    s="$(wf_judge judge_birthday 0 4 | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: 0 served judged '$s', expected FAIL."
    s="$(wf_judge judge_birthday None 4 | cut -f1)"
    [ "$s" = "CANNOT" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unreadable served count judged '$s', expected CANNOT."
    printf 'Your day\nBirthdays: Walkfixture Quillfeather today\n' > "$f"
    s="$(wf_judge judge_brief_birthday "$f" | cut -f1)"
    [ "$s" = "ok" ] || probe_pass "SELF-TEST BROKEN: a brief naming the person once judged '$s', expected ok."
    printf 'Birthdays: Walkfixture Quillfeather and Wally Quillfeather today\n' > "$f"
    s="$(wf_judge judge_brief_birthday "$f" | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a brief naming the person twice judged '$s', expected FAIL."
    printf 'Your day\nNothing on today\n' > "$f"
    s="$(wf_judge judge_brief_birthday "$f" | cut -f1)"
    [ "$s" = "CANNOT" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a brief that omits the birthday judged '$s', expected CANNOT."
    probe_examined 9 "synthetic judge inputs"
    probe_fail "negative control behaved correctly (passed one-of-four, failed two, refused a vacuous one, failed none, refused an unreadable count, passed a once-named brief, failed a twice-named brief, refused a brief that omits the birthday)"
}

run_probe() {
    local before b_fix b_tot c a_fix a_tot raw served http bj bst bdetail rst rdetail
    box_reachable || probe_cannot_run "the box is unreachable (OSTLER_BOX_HOST='${OSTLER_BOX_HOST:-unset}')"
    before="$(wf_stage_and_run bday count)"
    b_fix="$(wf_json_field "$before" fixture)"; b_tot="$(wf_json_field "$before" total)"
    case "$b_fix" in ''|*[!0-9]*) probe_cannot_run "could not count the store before seeding (the box said: ${before:-nothing})" ;; esac
    [ "$b_fix" = "0" ] || { wf_stage_and_run bday forget >/dev/null; probe_note "removed ${b_fix} stale fixture triple(s) from an earlier run"; before="$(wf_stage_and_run bday count)"; b_tot="$(wf_json_field "$before" total)"; }
    probe_note "BEFORE: fixture triples 0, store total ${b_tot}"

    if [ "$(wf_stage_and_run bday seed)" != "seeded" ]; then
        wf_stage_and_run bday forget >/dev/null; wf_cleanup_stage
        probe_cannot_run "the seed did not apply"
    fi
    probe_note "SEEDED: fixture triples $(wf_json_field "$(wf_stage_and_run bday count)" fixture)"
    raw="$(wf_stage_and_run bday raw)"
    c="$(wf_stage_and_run bday served)"; served="$(wf_json_field "$c" served)"; http="$(wf_json_field "$c" http)"
    case "$raw" in ''|*[!0-9]*) raw=None ;; esac
    case "$served" in ''|*[!0-9]*) served=None ;; esac
    rst="$(wf_judge judge_birthday "$served" "$raw")"; rdetail="${rst#*$'\t'}"; rst="${rst%%$'\t'*}"
    probe_note "RAW rows (before dedupe): ${raw}; SERVED entries (HTTP ${http:-?}): ${served}"

    probe_note "running an undelivered copy of the morning-brief job (about 3 to 10 minutes)"
    bj="$(wf_stage_and_run bday brief)"
    bst="$(wf_json_field "$bj" state)"; bdetail="$(wf_json_field "$bj" detail)"
    [ -n "$bst" ] || { bst=CANNOT; bdetail="the brief step returned nothing (the box said: ${bj:-nothing})"; }
    probe_note "BRIEF: run='$(wf_json_field "$bj" run)', named in birthday lines: $(wf_json_field "$bj" named)"

    wf_stage_and_run bday forget >/dev/null
    c="$(wf_stage_and_run bday count)"; a_fix="$(wf_json_field "$c" fixture)"; a_tot="$(wf_json_field "$c" total)"
    wf_cleanup_stage
    probe_note "UNDO: fixture triples ${a_fix:-?}, store total ${a_tot:-?} (before ${b_tot})"

    probe_examined 1 "synthetic person on 2 nodes (raw rows ${raw}, served ${served}, brief named $(wf_json_field "$bj" named))"
    [ "$a_fix" = "0" ] || probe_fail "UNDO FAILED: ${a_fix:-?} fixture triple(s) remain after forget; the store holds synthetic data"
    case "$rst" in
        FAIL) probe_fail "$rdetail" ;;
        CANNOT) probe_cannot_run "$rdetail" ;;
    esac
    case "$bst" in
        FAIL) probe_fail "brief: $bdetail" ;;
        CANNOT) probe_cannot_run "served list is clean (${rdetail}) but the brief could not be measured: ${bdetail}" ;;
    esac
    probe_pass "${rdetail}; brief ${bdetail}"
}

probe_main "$@"
