#!/usr/bin/env bash
# meetings_index_lists_meetings_not_holidays -- after a recompile, does Meetings/index.md list a timed meeting
# with an attendee and leave out a public holiday? (#2525, CM044 meeting_pages._event_kind)
#
# WALK_WRITES: seeds two synthetic Meeting nodes into Oxigraph (a holiday: no time, no attendee;
# a meeting: timed, with an attendee), runs the installed wiki-recompile tick (the Phase 1 baseline),
# reads the served index, then DELETES the seed, recompiles and reads again. The undo is verified by a
# triple count before and after. Judged from presence/absence of two invented titles; no real title,
# name or date leaves the box.
# NEGATIVE CONTROL (self-test): the same judge told to EXPECT the holiday must FAIL on a correct index.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk_fixture_122b2.sh"

PROBE_NAME="meetings_index_lists_meetings_not_holidays"
PROBE_QUESTION="seed a synthetic holiday and a synthetic timed meeting with an attendee, recompile the wiki: is the meeting in Meetings/index.md and the holiday absent?"

WIKI_DIR_EXPR='${OSTLER_WIKI_DIR:-$HOME/Documents/Ostler/Wiki}'
TICK_WAIT_NOTE="the recompile tick takes several minutes on a populated box"

_fixture_index() { # a synthetic index: good | holiday-listed
    printf -- '---\ntitle: Meetings\ntype: index\n---\n\n# Meetings\n\n- [Walkfixture Planning Review](x.md)\n'
    [ "$1" = "holiday-listed" ] && printf -- '- [Walkfixture Bank Holiday](h.md)\n'
    return 0
}

self_test() {
    local f s
    f="$(mktemp)"; trap 'rm -f "$f"' EXIT
    _fixture_index good > "$f"
    s="$(wf_judge judge_meetings "$f" 0 | cut -f1)"
    [ "$s" = "ok" ] || probe_pass "SELF-TEST BROKEN: a correct index judged '$s', expected ok."
    _fixture_index holiday-listed > "$f"
    s="$(wf_judge judge_meetings "$f" 0 | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an index listing the holiday judged '$s', expected FAIL."
    _fixture_index good > "$f"
    s="$(wf_judge judge_meetings "$f" 1 | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a probe variant that EXPECTS the holiday passed a correct index ('$s')."
    printf -- '---\ntitle: Meetings\ntype: index\n---\n\n# Meetings\n' > "$f"
    s="$(wf_judge judge_meetings "$f" 0 | cut -f1)"
    [ "$s" = "FAIL" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an index with no meeting judged '$s', expected FAIL."
    : > "$f"
    s="$(wf_judge judge_meetings "$f" 0 | cut -f1)"
    [ "$s" = "CANNOT" ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an empty index judged '$s', expected CANNOT (could-not-look must not read as 'holiday absent')."
    probe_examined 5 "synthetic index shapes"
    probe_fail "negative control behaved correctly (passed a correct index, failed a listed holiday, failed the holiday-expected variant, failed a missing meeting, refused an empty index)"
}

_forget_and_verify() { # prints "<fixture-after> <total-after>"
    wf_stage_and_run meetings forget >/dev/null
    local c; c="$(wf_stage_and_run meetings count)"
    printf '%s %s' "$(wf_json_field "$c" fixture)" "$(wf_json_field "$c" total)"
}

_recompile() { # sets PROBE_TICK_RC and PROBE_INDEX_FRESH (call it bare: a $(...) would lose them)
    local t0 t1
    t0="$(box_run 'date +%s')"
    PROBE_TICK_RC="$(box_run "export PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH; \$HOME/.ostler/bin/wiki-recompile-tick.sh >\$HOME/.ostler/walk-seed/fixture-122b2/tick.log 2>&1; echo rc=\$?" | tail -n 1)"
    t1="$(box_run "stat -f %m \"${WIKI_DIR_EXPR}/Meetings/index.md\"")"
    PROBE_INDEX_FRESH=0
    case "$t0$t1" in *[!0-9]*|"") ;; *) [ "$t1" -ge "$t0" ] && PROBE_INDEX_FRESH=1 ;; esac
}

run_probe() {
    local before b_fix b_tot after a_fix a_tot rc idx f st detail ctl_st
    box_reachable || probe_cannot_run "the box is unreachable (OSTLER_BOX_HOST='${OSTLER_BOX_HOST:-unset}')"
    before="$(wf_stage_and_run meetings count)"
    b_fix="$(wf_json_field "$before" fixture)"; b_tot="$(wf_json_field "$before" total)"
    case "$b_fix" in ''|*[!0-9]*) probe_cannot_run "could not count the store before seeding (the box said: ${before:-nothing})" ;; esac
    [ "$b_fix" = "0" ] || { wf_stage_and_run meetings forget >/dev/null; probe_note "removed ${b_fix} stale fixture triple(s) from an earlier run"; before="$(wf_stage_and_run meetings count)"; b_tot="$(wf_json_field "$before" total)"; }
    probe_note "BEFORE: fixture triples 0, store total ${b_tot}"

    [ "$(wf_stage_and_run meetings seed)" = "seeded" ] || { _forget_and_verify >/dev/null; probe_cannot_run "the seed did not apply"; }
    probe_note "SEEDED: fixture triples $(wf_json_field "$(wf_stage_and_run meetings count)" fixture)"
    probe_note "recompiling (${TICK_WAIT_NOTE})"
    _recompile; rc="$PROBE_TICK_RC"
    f="$(mktemp)"; trap 'rm -f "$f"' EXIT
    box_run "cat \"${WIKI_DIR_EXPR}/Meetings/index.md\"" > "$f"
    local fresh="$PROBE_INDEX_FRESH"
    st="$(wf_judge judge_meetings "$f" 0)"; detail="${st#*$'\t'}"; st="${st%%$'\t'*}"
    ctl_st="$(wf_judge judge_meetings "$f" 1 | cut -f1)"

    # UNDO: delete the seed, recompile, and prove both the graph and the index went back.
    after="$(_forget_and_verify)"; a_fix="${after% *}"; a_tot="${after#* }"
    probe_note "UNDO: fixture triples ${a_fix:-?}, store total ${a_tot:-?} (before ${b_tot})"
    _recompile
    box_run "cat \"${WIKI_DIR_EXPR}/Meetings/index.md\"" > "$f"
    local gone=0; /usr/bin/grep -q "Walkfixture" "$f" || gone=1
    wf_cleanup_stage

    probe_examined 2 "synthetic calendar entries (1 holiday, 1 timed meeting with an attendee), index read after $rc"
    probe_note "index rewritten by this recompile: $([ "$fresh" = 1 ] && echo yes || echo NO)"
    probe_note "NEGATIVE CONTROL on the live index (expects the holiday): ${ctl_st}"
    [ "$a_fix" = "0" ] || probe_fail "UNDO FAILED: ${a_fix:-?} fixture triple(s) remain after forget; the store holds synthetic data"
    [ "$gone" = 1 ] || probe_fail "UNDO NOT REFLECTED: the index still names a fixture entry after the seed was deleted and the wiki recompiled"
    [ "$fresh" = 1 ] || probe_cannot_run "the recompile did not rewrite Meetings/index.md (tick said ${rc}); a stale index cannot prove anything"
    [ "$ctl_st" = "FAIL" ] || probe_fail "NEGATIVE CONTROL DID NOT FIRE on the live index: expecting the holiday gave '${ctl_st}'"
    case "$st" in
        ok) probe_pass "$detail" ;;
        CANNOT) probe_cannot_run "$detail" ;;
        *) probe_fail "$detail" ;;
    esac
}

probe_main "$@"
