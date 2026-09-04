#!/usr/bin/env bash
# ============================================================================
# #616 (step 1): THE WHOLE-RUN CLOSING VERDICT MUST CONSULT failed_steps
#                AND NAME THE STEPS THAT DID NOT COMPLETE
#
# THE INPUT THIS TEST REPLAYS (the v1.0.60 walk, 2026-09-03)
#
# Two hydrate steps were killed by their timeout cap (rc=124), the search index
# came out empty, and the install closed with:
#
#     Ostler finished with no errors raised during the install.
#     #OSTLER DONE status=ok failed_steps=2
#
# The verdict sentence a human reads was derived from _OSTLER_RUN_ERRORS alone --
# the count of err() MESSAGE lines. A `timeout` kill raises no err(), so the
# message tally was a true zero while two STEPS had failed. The customer whose
# index is empty is TOLD IT WENT FINE. That is what disqualified the cut.
#
# THE FIX UNDER TEST. install.sh's closing verdict now ALSO consults
# __OSTLER_FAILED_STEPS and NAMES the steps from __OSTLER_FAILED_STEP_IDS. The
# id-list is appended in lib/progress_emitter.sh at the SINGLE site that
# increments the count (gui_step_end), so word-count(ids) == failed_steps is an
# invariant and the names are the exact ids the STEP_END lines carry -- not a
# second tally (#532), a projection of the same event.
#
# SCOPE, stated honestly: this is step 1 of #616 -- the sentence a HUMAN reads.
# The DONE-marker `status` field a MACHINE reads (#616 step 2,
# ok|completed_with_failures|fail) is a separate sequenced change and is NOT
# under test here; #839 (status=ok means "reached the end") is intact.
#
# WHY EXTRACT-REAL. The verdict block, the ok()/warn()/err()/gui_active()
# primitives, and the emitter are all EXTRACTED from the shipped files and
# executed. Nothing here reimplements the logic, so nothing can pass against a
# copy that has drifted from install.sh.
#
# THE ARMS
#   RED           two steps fail, zero err() -> the sentence must NOT say clean
#                 AND must name both failed ids. The original failing input.
#   GREEN         a clean run -> the reassuring line, and no false accusation.
#                 (Positive control: a fix that reds every install would pass RED
#                 and fail here.)
#   BOTH          err() raised AND a step failed -> both warnings, no clean line.
#   ABORT-NAMES   a run that dies inside a step (gui_done fail over an open step)
#                 names that step, via the same single site (#873 tie-in).
#   SAME-SOURCE   the ids the verdict will name are EXACTLY the ids of the
#                 non-ok STEP_END markers the GUI renders, and clean steps are
#                 excluded. Proves one source, not a re-derivation.
#   ANTI-VACUITY  the PRE-FIX verdict (consults _OSTLER_RUN_ERRORS only), driven
#                 with the RED state, PRINTS the clean line and names nothing.
#                 If it did not, this test could not see the defect it exists for
#                 and every pass above would be vacuous.
#
# Exit: 0 all hold | 1 a rule is broken | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
EMITTER="${HERE}/../lib/progress_emitter.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"

pass=0; fail=0
pass()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note()   { printf '        %s\n' "$1"; }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

for f in "$INSTALL" "$EMITTER" "$STRINGS"; do
    [ -r "$f" ] || cannot "not readable: $f"
done

echo "== #616 step 1: the closing verdict consults failed_steps and names them =="

WORK=""
cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }
trap cleanup EXIT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-616verdict-XXXXXX")" || cannot "could not create a work directory"

# ── EXTRACT THE REAL VERDICT BLOCK (anchored, not reimplemented). ───────
awk '
    /^# CLOSING VERDICT \(#616\):/ { grab = 1 }
    grab && /^if \[\[/             { emit = 1 }
    emit                          { print }
    emit && /^fi$/                { exit }
' "$INSTALL" > "${WORK}/verdict.sh"
[ -s "${WORK}/verdict.sh" ] || cannot "verdict block not found (anchor '# CLOSING VERDICT (#616):' + if..fi). It moved or was renamed; every verdict below would be about the wrong code."
grep -q '__OSTLER_FAILED_STEPS' "${WORK}/verdict.sh" || cannot "the extracted verdict block does NOT reference __OSTLER_FAILED_STEPS. Either the anchor caught the wrong region, or the fix under test is absent."
grep -q 'MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS' "${WORK}/verdict.sh" || cannot "the extracted verdict block does NOT reference the failed-steps message. The fix is absent or the block was renamed."
note "extracted the real verdict block ($(wc -l < "${WORK}/verdict.sh" | tr -d ' ') lines)"

# ── EXTRACT THE REAL PRIMITIVES (main-body ok/warn/err/gui_active). ─────
{
  grep -m1 '^gui_active()' "$INSTALL"
  grep -m1 '^ok()'         "$INSTALL"
  grep -m1 '^warn()'       "$INSTALL"
  grep -m1 '^err()'        "$INSTALL"
} > "${WORK}/prims.sh"
_have="$(grep -c '() ' "${WORK}/prims.sh" || true)"
[ "${_have:-0}" -eq 4 ] || cannot "expected 4 primitives (gui_active/ok/warn/err), extracted ${_have:-0}. They moved or were renamed."
note "extracted gui_active() + ok() + warn() + err() from install.sh main body"

# ── THE PRE-FIX VERDICT, for the anti-vacuity limb. Consults the message
#    counter ONLY, exactly as install.sh did before #616. ────────────────
cat > "${WORK}/verdict_prefix.sh" <<'PREFIX'
if [[ "${_OSTLER_RUN_ERRORS:-0}" -gt 0 ]]; then
    warn "$(printf "$MSG_WARN_INSTALL_FINISHED_WITH_ERRORS" "${_OSTLER_RUN_ERRORS:-0}")"
    warn "$MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE"
else
    ok "$MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED"
fi
PREFIX

# A run harness: sources the real emitter + strings + primitives, runs a driver
# snippet (inherited function) to shape state via the REAL emitter, then runs a
# chosen verdict file. Echoes only what reached stdout (the install.log stream).
_run() {
    # _run <driver-fn> <verdict-file>
    local driver="$1" verdict="$2"
    (
      set +u
      . "$EMITTER"
      . "$STRINGS"
      . "${WORK}/prims.sh"
      _OSTLER_RUN_ERRORS=0
      "$driver"
      . "$verdict"
    ) 2>/dev/null
}

# Drivers shape state through the REAL emitter only -- no hand-set counters.
drive_two_failed() {
    gui_step_begin hydrate_browsing "Browsing"; gui_step_record_rc 124; gui_step_end timeout
    gui_step_begin hydrate_people   "People";   gui_step_record_rc 3;   gui_step_end error
}
drive_clean() {
    gui_step_begin config "Config"; gui_step_end
    gui_step_begin models "Models"; gui_step_end
}
drive_error_and_failed() {
    err "a real error line"
    gui_step_begin hydrate_email "Email"; gui_step_record_rc 124; gui_step_end timeout
}

CLEAN_FRAGMENT='no errors raised'
NAMED_FRAGMENT='did not complete cleanly'
ERR_FRAGMENT='error(s) were raised'

# ── RED: two failed steps, zero err(). ─────────────────────────────────
out="$(_run drive_two_failed "${WORK}/verdict.sh")"
if grep -qF "$CLEAN_FRAGMENT" <<< "$out"; then
    bad "THE DEFECT IS PRESENT: two failed steps still printed the clean '${CLEAN_FRAGMENT}' line. This is the v1.0.60 verdict."
else
    pass "two failed steps do NOT print the reassuring clean line"
fi
if grep -qF "$NAMED_FRAGMENT" <<< "$out" && grep -q 'hydrate_browsing' <<< "$out" && grep -q 'hydrate_people' <<< "$out"; then
    pass "the verdict NAMES both failed steps (hydrate_browsing, hydrate_people)"
else
    bad "the verdict did not name the two failed steps. Got: $(grep -i 'step' <<< "$out" | head -1 || printf '(no step line)')"
fi

# ── GREEN: a clean run. ────────────────────────────────────────────────
out="$(_run drive_clean "${WORK}/verdict.sh")"
if grep -qF "$CLEAN_FRAGMENT" <<< "$out"; then
    pass "a clean run prints the reassuring '${CLEAN_FRAGMENT}' line"
else
    bad "REGRESSION: a clean run did NOT print the reassuring line. This fix would red every healthy install. Got: $(printf '%s' "$out" | head -1)"
fi
if grep -qF "$NAMED_FRAGMENT" <<< "$out"; then
    bad "a clean run falsely reported failed steps -- the accusation fires on zero. Got: $(grep -i 'step' <<< "$out" | head -1)"
else
    pass "a clean run makes no false failed-step accusation"
fi

# ── BOTH: err() raised AND a step failed. ──────────────────────────────
out="$(_run drive_error_and_failed "${WORK}/verdict.sh")"
if grep -qF "$ERR_FRAGMENT" <<< "$out" && grep -qF "$NAMED_FRAGMENT" <<< "$out"; then
    pass "a run with BOTH an error and a failed step reports BOTH, and names the step (hydrate_email)"
else
    bad "the both-kinds run did not report both. err_line=$(grep -qF "$ERR_FRAGMENT" <<< "$out" && echo yes || echo no) step_line=$(grep -qF "$NAMED_FRAGMENT" <<< "$out" && echo yes || echo no)"
fi
if grep -qF "$CLEAN_FRAGMENT" <<< "$out"; then
    bad "the both-kinds run ALSO printed the clean line -- the reassuring line must never coexist with trouble."
else
    pass "the both-kinds run does not print the clean line"
fi

# ── ABORT-NAMES: a run that dies inside a step names that step (#873). ──
out="$( (
    set +u
    . "$EMITTER"; . "$STRINGS"; . "${WORK}/prims.sh"
    _OSTLER_RUN_ERRORS=0
    gui_step_begin licence_check "Licence"   # opened, never closed
    gui_done fail >/dev/null 2>&1             # abort: closes the open step as error
    printf 'IDS=[%s] COUNT=%s\n' "${__OSTLER_FAILED_STEP_IDS}" "${__OSTLER_FAILED_STEPS}"
    . "${WORK}/verdict.sh"
) 2>/dev/null )"
if grep -q 'IDS=\[licence_check\] COUNT=1' <<< "$out"; then
    pass "an abort inside a step feeds the single id-list source (licence_check, count=1)"
else
    bad "the abort path did not append the open step's id. Got: $(grep '^IDS=' <<< "$out" || printf '(none)')"
fi
if grep -q 'licence_check' <<< "$out" && ! grep -qF "$CLEAN_FRAGMENT" <<< "$out"; then
    pass "the verdict after an abort names the step and does not say clean"
else
    bad "the post-abort verdict did not name licence_check or falsely said clean."
fi

# ── SAME-SOURCE: the named ids ARE the non-ok STEP_END ids the GUI reads. ─
markers="${WORK}/markers.txt"
( set +u
  . "$EMITTER"; . "$STRINGS"; . "${WORK}/prims.sh"
  exec 9>"$markers"
  export OSTLER_GUI=1 OSTLER_MARKER_FD=9
  gui_step_begin s_alpha "Alpha"; gui_step_record_rc 124; gui_step_end timeout
  gui_step_begin s_clean "Clean"; gui_step_end                 # an ok step in the middle
  gui_step_begin s_gamma "Gamma"; gui_step_record_rc 5;   gui_step_end error
  printf '%s' "${__OSTLER_FAILED_STEP_IDS}" > "${WORK}/idlist.txt"
  printf '%s' "${__OSTLER_FAILED_STEPS}"    > "${WORK}/count.txt"
) 2>/dev/null
# The ids of the STEP_END markers whose status is NOT ok, from the GUI wire.
nonok="$(awk -F'\t' '
    /STEP_END/ {
        id=""; st="";
        for (i=1;i<=NF;i++) { if ($i ~ /^id=/) id=substr($i,4); if ($i ~ /^status=/) st=substr($i,8) }
        if (st != "ok") printf "%s ", id
    }' "$markers" | sed 's/ *$//')"
idlist="$(cat "${WORK}/idlist.txt")"
count="$(cat "${WORK}/count.txt")"
wc_ids="$(printf '%s' "$idlist" | wc -w | tr -d ' ')"
if [ "$idlist" = "$nonok" ] && [ "$idlist" = "s_alpha s_gamma" ]; then
    pass "the id-list equals the non-ok STEP_END ids the GUI renders (s_alpha s_gamma); the clean step is excluded"
else
    bad "id-list and STEP_END non-ok ids disagree. idlist=[$idlist] step_end_nonok=[$nonok]"
fi
if [ "${wc_ids}" = "${count}" ] && [ "${count}" = "2" ]; then
    pass "invariant holds: word-count(ids)=${wc_ids} == __OSTLER_FAILED_STEPS=${count}"
else
    bad "invariant BROKEN: word-count(ids)=${wc_ids} vs __OSTLER_FAILED_STEPS=${count} -- a second tally has drifted."
fi

# ── ANTI-VACUITY: the pre-fix verdict, on the RED state, must LIE. ──────
out="$(_run drive_two_failed "${WORK}/verdict_prefix.sh")"
if grep -qF "$CLEAN_FRAGMENT" <<< "$out"; then
    pass "anti-vacuity: the PRE-FIX verdict prints '${CLEAN_FRAGMENT}' over two failed steps, so this harness genuinely sees the defect"
else
    bad "ANTI-VACUITY FAILED: the pre-fix verdict did NOT print the clean line over the RED state. The passes above prove nothing -- the harness is not exercising the defect."
fi
if grep -qF "$NAMED_FRAGMENT" <<< "$out"; then
    bad "ANTI-VACUITY FAILED: the pre-fix verdict named failed steps, which it cannot do -- the extraction or state is wrong."
else
    pass "anti-vacuity: the pre-fix verdict names no step, confirming the naming is the fix's own contribution"
fi

finish
