#!/usr/bin/env bash
# probes/the_recovery_key_reached_the_customer.sh
# ============================================================================
# QUESTION: if this box's keychain can only be opened by a recovery key, was
# that key ever put in front of the customer?
#
# WHY IT EXISTS. MEASURED on archie2, a virgin account on the Mini 16, walking
# the v1.0.68 DMG on 2026-09-05. The install ended
# `DONE status=ok failed_steps=0 errors=0`, every automated probe passed, and
# the customer was never shown a recovery key. Andy, at a keyboard:
# "Finished, but didn't offer to save the recovery key".
#
# NO AUTOMATED WALK COULD HAVE FOUND IT, because the defect is something that
# did NOT happen. This probe exists so that stops being true.
#
# THE THING THE KEY GUARDS. keychain.json stores a verifier and the DEK wrapped
# under the key. The key itself is never stored, correctly -- and that is
# exactly what makes a missed disclosure permanent. `ostler-recovery` ships and
# can never succeed for an install whose key nobody has.
#
# WHY THE SOURCE CANNOT ANSWER THIS AND ONLY THE TRANSCRIPT CAN.
# #1551 fixed both disclosure sites and gates them in CI. But a source gate
# proves a call EXISTS; it cannot prove the call was REACHED. The v1.0.68
# failure was a reachability failure with the code present the whole time:
#
#   install.sh   minted at 14008, revealed at 29498, 15,490 lines apart
#   the GUI      presented the reveal sheet only inside `finished == .ok`
#
# so a run that minted and then failed destroyed the key with both call sites
# intact. That is a RUNTIME property of one install, and the install's own
# transcript is the only place it is written down.
#
# THE INVARIANT, and it is deliberately narrow:
#
#     a run that CREATED recovery_encrypted_key MUST have emitted the
#     disclosure before it ended
#
# THE THREE STATES, and the middle one is the whole design:
#
#   PASS         the keychain was written BY THIS RUN and the transcript
#                carries the disclosure.
#   FAIL         the keychain was written BY THIS RUN and it does not.
#   CANNOT-RUN   the keychain PREDATES this run -- the re-install path. This
#                run took install.sh's "already configured" skip, so it could
#                not disclose anything and demanding that it had would be
#                demanding the impossible. The only way to satisfy such a
#                gate is to print a key nobody knows.
#
# ⚠️ THE CANNOT-RUN ARM IS NOT A LOOPHOLE, IT IS THE POINT. It is also where a
# real customer is stranded: an earlier attempt minted the key, died, and every
# later run skips. So the message says so, loudly, rather than shrugging. A
# stranded box is a finding for a human; it is just not a finding about THIS
# run's code.
#
# THE DISCRIMINATOR IS A CLOCK, not a guess. keychain.json's mtime against the
# transcript's own run header. On archie2 the keychain was 20m 15s OLDER than
# the run that finished clean, which is how the skip was proved rather than
# assumed. Timestamps are compared in UTC on the box, because a `Z` suffix is a
# claim and the walk box is +0800.
# ============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

KEYCHAIN='$HOME/.ostler/security/keychain.json'
TRANSCRIPT='$HOME/.ostler/logs/install.log'

# The disclosure, as install.sh actually writes it. TWO independent markers,
# because the GUI and TTY paths emit different things and a box may have taken
# either. Neither carries the key VALUE -- the marker is matched by NAME only,
# and the bold line is matched by its label, so nothing secret is read, logged
# or compared here.
# ⚠️ UNDECLARED COUPLING, NOW DECLARED. This matches a SUBSTRING of the redacted
# marker format that tests/test_marker_payloads_never_reach_install_log.sh:324
# mandates: the log carries `RECOVERY_KEY value=<redacted:24>`, so grepping
# `RECOVERY_KEY value=` counts the marker and never reads the value. That is the
# right way round, and it is a coincidence unless it is written down. If the
# trace ever becomes `RECOVERY_KEY=<redacted>` this probe silently counts 0 and
# FAILS a correct install. Change one, check the other.
_DISCLOSE_GUI='RECOVERY_KEY value='
_DISCLOSE_TTY='Your recovery key:'

run_probe() {
    box_reachable || probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was inspected, and that is not a pass."

    # ── Does this box even have a recovery block to talk about? ──────────
    _has_kc="$(box_run "test -f ${KEYCHAIN} && echo YES || echo NO")"
    case "$_has_kc" in
        YES) : ;;
        NO)  probe_examined 0 "recovery blocks (no keychain on this box)"
             probe_cannot_run "no ${KEYCHAIN} on ${OSTLER_BOX_HOST:-this machine}. With no keychain there is no recovery block, so there is nothing this probe can be for or against. That is coverage absent, not a clean bill." ;;
        *)   probe_cannot_run "could not determine whether ${KEYCHAIN} exists -- the reader returned '${_has_kc}'. An answer that is neither YES nor NO has established nothing." ;;
    esac

    # Shape only. The key names are read; no value is ever extracted.
    _has_block="$(box_run "python3 -c \"
import json,os,sys
p=os.path.expanduser('~/.ostler/security/keychain.json')
try:
    d=json.load(open(p))
except Exception as e:
    print('UNREADABLE'); sys.exit(0)
print('BLOCK' if 'recovery_encrypted_key' in d else 'NOBLOCK')
\"")"
    case "$_has_block" in
        BLOCK)   : ;;
        NOBLOCK) probe_examined 1 "keychains (no recovery block in it)"
                 probe_pass "the keychain on this box carries NO recovery_encrypted_key, so no key was minted and none was owed. The invariant is not violated because it does not apply." ;;
        UNREADABLE) probe_cannot_run "${KEYCHAIN} exists but could not be parsed as JSON. Nothing about the recovery block was established." ;;
        *)       probe_cannot_run "the keychain reader returned '${_has_block}', which is neither BLOCK nor NOBLOCK. Nothing was measured." ;;
    esac

    # ── THE DISCRIMINATOR: did THIS run create that keychain? ────────────
    # Both stamps in UTC, taken on the box. A `Z` suffix written by someone
    # else is a claim; these are measured.
    _kc_epoch="$(box_run "/usr/bin/stat -f %m ${KEYCHAIN} 2>/dev/null")"
    _run_epoch="$(box_run "head -20 ${TRANSCRIPT} 2>/dev/null | sed -n 's/.*install.sh run \\([0-9T:-]*Z\\).*/\\1/p' | head -1 | xargs -I{} date -j -u -f '%Y-%m-%dT%H:%M:%SZ' {} +%s 2>/dev/null")"

    case "$_kc_epoch" in ''|*[!0-9]*) probe_cannot_run "could not read an mtime for ${KEYCHAIN} (got '${_kc_epoch}'). Without it there is no way to tell a run that MINTED the key from one that skipped, and those want opposite verdicts." ;; esac
    case "$_run_epoch" in ''|*[!0-9]*) probe_cannot_run "could not read this run's start stamp out of ${TRANSCRIPT} (got '${_run_epoch}'). The keychain's age cannot be compared against a run whose start is unknown." ;; esac

    _delta=$(( _kc_epoch - _run_epoch ))

    # ── Did the disclosure reach the transcript? ─────────────────────────
    _gui="$(box_run "grep -acF '${_DISCLOSE_GUI}' ${TRANSCRIPT} 2>/dev/null || echo 0")"
    _tty="$(box_run "grep -acF '${_DISCLOSE_TTY}' ${TRANSCRIPT} 2>/dev/null || echo 0")"
    case "$_gui" in ''|*[!0-9]*) _gui=0 ;; esac
    case "$_tty" in ''|*[!0-9]*) _tty=0 ;; esac
    _seen=$(( _gui + _tty ))

    # ANTI-VACUITY: a zero from a transcript nothing can read is not a zero.
    _lines="$(box_run "grep -ac . ${TRANSCRIPT} 2>/dev/null || echo 0")"
    case "$_lines" in ''|*[!0-9]*) _lines=0 ;; esac
    if [ "$_lines" -eq 0 ]; then
        probe_cannot_run "${TRANSCRIPT} read as 0 lines on ${OSTLER_BOX_HOST:-this machine}. A disclosure count taken from an unreadable transcript is not a measurement."
    fi

    probe_examined "$_lines" "transcript lines searched for the disclosure"

    # 🔴 A KEYCHAIN THE RUN ITSELF WROTE CANNOT PREDATE THAT RUN, so a negative
    # delta is either parse granularity -- a second or two -- or evidence the
    # keychain came from somewhere else. Sixty seconds is far wider than the
    # first and squarely inside the second, and TNM drove the boundary out of
    # this function directly:
    #
    #     delta   verdict (seen=0, block=BLOCK)
    #        -1   fail-minted-not-disclosed
    #       -59   fail-minted-not-disclosed
    #       -60   fail-minted-not-disclosed      <- FALSE RED
    #       -61   cannot-run-skip
    #
    # The false red lands on this sequence: an install mints the key and
    # DISCLOSES IT CORRECTLY, a second install starts within the minute -- a
    # walk retry, or a customer double-clicking twice -- takes the
    # already-configured skip and correctly discloses nothing, and this probe
    # reports THIS RUN CREATED THE KEY AND NEVER DISCLOSED IT on a box where
    # the key was handed over sixty seconds earlier.
    #
    # So the window is split rather than widened or narrowed. Beyond -60 the
    # keychain is plainly older and the run plainly skipped. Inside it the
    # probe does not know, and saying so is the only honest verdict available.
    if [ "$_delta" -lt -60 ]; then
        probe_cannot_run "THE KEYCHAIN PREDATES THIS RUN by $(( -_delta )) second(s), so this install took install.sh's already-configured skip and could not have disclosed anything -- demanding that it had would be demanding a key nobody knows. THIS RUN'S code is not implicated and no verdict is offered on it. ⚠️ BUT THE BOX MAY BE STRANDED: the key was minted by an EARLIER run, and if THAT run never disclosed it, nothing ever will -- the keychain persists and every later run skips. Read the earlier transcript if one survives; ostler-recovery cannot succeed here otherwise. (disclosure markers in this run's transcript: gui=${_gui} tty=${_tty})"
    fi

    if [ "$_delta" -lt -5 ]; then
        probe_cannot_run "THE KEYCHAIN IS ${_delta}s OLDER THAN THIS RUN, which is more than clock and parse granularity can explain and less than a confident skip. A keychain a run wrote itself cannot predate it, so this one came from somewhere else -- most likely an install in the previous minute, which is exactly what a walk retry or a double-click produces. This probe CANNOT tell a run that minted-and-missed from a run that correctly skipped a key disclosed moments ago, and guessing would put a red on a box where the customer HAS the key. (disclosure markers in this run: gui=${_gui} tty=${_tty}; searched ${_lines} lines)"
    fi

    if [ "$_seen" -gt 0 ]; then
        probe_pass "this run MINTED the recovery block (keychain written ${_delta}s after the run began) AND disclosed it: ${_gui} structured marker(s) and ${_tty} rendered line(s) in ${_lines} transcript lines. No key value was read or compared."
    fi

    probe_fail "🔴 THIS RUN CREATED recovery_encrypted_key AND NEVER DISCLOSED THE KEY. The keychain was written ${_delta}s after this run began, so this is the minting run and it was the only run that could ever hand the key over: the key is deliberately never stored, the keychain IS, and every later install takes the already-configured skip and emits nothing. Searched ${_lines} transcript lines and found 0 structured markers and 0 rendered lines. ostler-recovery ships on this box and can never succeed for it. This is the v1.0.68 defect (#1540) and it is customer-permanent, not a papercut."
}

self_test() {
    # Drives the DECISION, not the box. Four arms over the three states plus the
    # one that must not collapse into another.
    _decide() {
        # $1 delta, $2 markers seen, $3 has-block -> the verdict word
        _d="$1"; _s="$2"; _b="$3"
        [ "$_b" = "NOBLOCK" ] && { printf 'pass-not-applicable'; return; }
        [ "$_d" -lt -60 ] && { printf 'cannot-run-skip'; return; }
        [ "$_d" -lt -5 ]  && { printf 'cannot-run-ambiguous'; return; }
        [ "$_s" -gt 0 ] && { printf 'pass-disclosed'; return; }
        printf 'fail-minted-not-disclosed'
    }
    fails=0
    _t() { got="$(_decide "$1" "$2" "$3")"; if [ "$got" = "$4" ]; then printf 'arm OK: delta=%s seen=%s block=%s -> %s\n' "$1" "$2" "$3" "$got"; else printf 'arm BROKEN: delta=%s seen=%s block=%s -> %s, wanted %s\n' "$1" "$2" "$3" "$got" "$4"; fails=$((fails+1)); fi; }

    _t   5  2 BLOCK   pass-disclosed
    _t   5  0 BLOCK   fail-minted-not-disclosed
    _t -1215 0 BLOCK  cannot-run-skip
    _t   5  0 NOBLOCK pass-not-applicable
    # BOUNDARY ARMS. The suite drove 5 and -1215 and nothing between them, and
    # the whole false-red lives in that gap. Pin both sides of both edges.
    _t  -1  0 BLOCK   fail-minted-not-disclosed
    _t -40  0 BLOCK   cannot-run-ambiguous
    _t -59  0 BLOCK   cannot-run-ambiguous
    _t -61  0 BLOCK   cannot-run-skip
    # ARM 5, the one that matters: the skip and the miss must NOT collapse.
    # They are the two runs of the archie2 walk and they want opposite verdicts.
    a="$(_decide -1215 0 BLOCK)"; b="$(_decide 5 0 BLOCK)"
    if [ "$a" = "$b" ]; then printf 'arm BROKEN: skip and miss collapse onto %s\n' "$a"; fails=$((fails+1)); else printf 'arm OK: skip (%s) and miss (%s) do not collapse\n' "$a" "$b"; fi

    # INVERTED ON PURPOSE, same as usage_journal_producers.sh: --self-test must
    # come back FAIL when the control behaved correctly, because that is what
    # proves this probe can go red at all.
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 9 "self-test arms (disclosed / minted-and-missed / skip-path / no-block / two ambiguous-window arms / two boundary arms / the first two do not collapse)"
    probe_fail "negative control behaved correctly on all 9 arms: a disclosing run PASSes; a minting run with no disclosure FAILs; a keychain 1215s older is CANNOT-RUN skip; a box with no recovery block passes as not-applicable; -1 still FAILs while -40 and -59 are CANNOT-RUN ambiguous and -61 is a confident skip, which pins BOTH edges of the window TNM found untested; and the skip and the miss reach different verdicts"
}

probe_main "$@"
