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
# THE INVARIANT, and it used to be one clause when it needed two:
#
#     a run that CREATED recovery_encrypted_key MUST have emitted the
#     disclosure before it ended
#     AND the box MUST carry something that can redeem what was emitted
#
# 🔴 WHY THE SECOND CLAUSE WAS ADDED, AND WHY ITS ABSENCE WAS WORSE THAN A
# MISSING PROBE. This file measured only whether a key was SHOWN. Whether the
# shipped artefact could ever ACCEPT one back was measured by nothing, and the
# answer was no: passphrase.unlock_with_recovery_key() had zero call sites for
# the whole of v1.0, and the only shipped recovery command, ostler-recovery,
# drives the passkey subsystem this release disables. So a walk could report
# this probe green on a box where the key it had just watched being handed over
# could never be spent. A probe that grades the ceremony and not the capability
# certifies the ceremony.
#
# 🔴 AND THE NOBLOCK ARM USED TO PASS, WHICH IS GREEN-ON-ABSENT-FEATURE. It
# read "the keychain carries NO recovery_encrypted_key, so no key was minted
# and none was owed", and called that a pass. On a v1.0 box that reasoning is
# inverted: setup_passphrase() ALWAYS writes recovery_encrypted_key, so on a
# passphrase-primary install the block's absence does not mean nothing was
# owed, it means the recovery feature did not happen. The probe went green
# precisely where the customer had no recovery path at all. The arm one level
# up already knew better -- a box with no keychain is CANNOT-RUN, "coverage
# absent, not a clean bill" -- and this arm contradicted it. It is now split
# on the one fact that distinguishes the two cases: passkey.json. A
# passkey-primary config legitimately has no passphrase recovery envelope and
# yields CANNOT-RUN; a passphrase-primary one without it is a FAIL.
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

# _decide -- THE ONE DECISION FUNCTION, used by run_probe AND self_test.
#
# 🔴 UNTIL THIS FIX, self_test drove its OWN local _decide, and run_probe's
# real adjudication was a separately written chain of `if` statements reaching
# probe_pass/probe_fail/probe_cannot_run directly. The two never touched. A
# regression that flipped run_probe's real chain left the self-test output
# byte identical, because the negative control never executed that code. See
# tests/test_a_probes_self_test_must_drive_its_own_decision.sh, which mutates
# this function and requires the self-test to go BROKEN.
#
# _decide <delta> <markers-seen> <has-block> <has-passkey> <redeemable>
#   -> verdict word:
#   cannot-run-passkey-primary  no recovery envelope AND passkey.json present,
#                               so this box is on the other subsystem and the
#                               passphrase recovery path does not apply
#   fail-no-recovery-envelope   no recovery envelope and NO passkey.json: a
#                               passphrase-primary install with no way back in
#   fail-not-redeemable         a recovery envelope exists and nothing on this
#                               box can open one
#   cannot-run-redeemer-unknown the redemption check itself did not produce a
#                               usable answer, so redeemability is unmeasured
#   cannot-run-skip             keychain predates this run by more than 60s
#   cannot-run-ambiguous        keychain predates this run by 6-60s (retry window)
#   pass-disclosed              this run minted the key, disclosed it, and the
#                               box can redeem one
#   fail-minted-not-disclosed   this run minted the key and did NOT disclose it
#
# ORDER MATTERS AND IS ARGUED, NOT INHERITED.
#
# Redeemability is adjudicated BEFORE the delta arms, because it is not a fact
# about who minted the key. "This box holds a recovery envelope and ships
# nothing that can open one" is a defect of the artefact under test whether the
# envelope was written eight seconds ago or last month, and a CANNOT-RUN about
# THIS run's disclosure must not swallow it. The old order would have let a
# re-install walk return CANNOT-RUN on a box with no redeemer at all.
_decide() {
    # $1 delta, $2 markers seen, $3 has-block, $4 has-passkey, $5 redeemable
    _d="$1"; _s="$2"; _b="$3"; _p="${4:-NOPASSKEY}"; _r="${5:-UNKNOWN}"
    if [ "$_b" = "NOBLOCK" ]; then
        [ "$_p" = "PASSKEY" ] && { printf 'cannot-run-passkey-primary'; return; }
        printf 'fail-no-recovery-envelope'; return
    fi
    [ "$_r" = "NOREDEEMER" ] && { printf 'fail-not-redeemable'; return; }
    [ "$_r" = "UNKNOWN" ]    && { printf 'cannot-run-redeemer-unknown'; return; }
    [ "$_d" -lt -60 ] && { printf 'cannot-run-skip'; return; }
    [ "$_d" -lt -5 ]  && { printf 'cannot-run-ambiguous'; return; }
    [ "$_s" -gt 0 ] && { printf 'pass-disclosed'; return; }
    printf 'fail-minted-not-disclosed'
}

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
        BLOCK|NOBLOCK) : ;;
        UNREADABLE) probe_cannot_run "${KEYCHAIN} exists but could not be parsed as JSON. Nothing about the recovery block was established." ;;
        *)       probe_cannot_run "the keychain reader returned '${_has_block}', which is neither BLOCK nor NOBLOCK. Nothing was measured." ;;
    esac

    # Which subsystem is this box on? It is the ONLY thing that makes a
    # missing recovery envelope innocent, so it is read rather than assumed.
    _has_pk="$(box_run "test -f \$HOME/.ostler/security/passkey.json && echo PASSKEY || echo NOPASSKEY")"
    case "$_has_pk" in
        PASSKEY|NOPASSKEY) : ;;
        *) probe_cannot_run "could not determine whether passkey.json exists (reader returned '${_has_pk}'). Without it, a box with no recovery envelope cannot be told apart from one that legitimately has none, and those want opposite verdicts." ;;
    esac

    if [ "$_has_block" = "NOBLOCK" ]; then
        probe_examined 1 "keychains (no recovery envelope in it)"
        _v="$(_decide 0 0 NOBLOCK "$_has_pk" UNKNOWN)"
        case "$_v" in
            cannot-run-passkey-primary)
                probe_cannot_run "this box carries passkey.json and no recovery_encrypted_key, so it is on the passkey subsystem and the passphrase recovery envelope does not apply to it. NOTHING about the passphrase recovery path was measured here. That is coverage absent, not a clean bill." ;;
            *)
                probe_fail "🔴 THIS IS A PASSPHRASE-PRIMARY INSTALL WITH NO RECOVERY ENVELOPE. keychain.json exists, passkey.json does not, and the keychain carries no recovery_encrypted_key. setup_passphrase() writes that envelope on every run it completes, so its absence is not 'nothing was owed' -- it is the recovery feature not happening. This customer has exactly one secret standing between them and their data, and no second one. This arm used to PASS and that is how it stayed invisible." ;;
        esac
    fi

    # ── CAN ANYTHING ON THIS BOX ACTUALLY REDEEM A KEY? ──────────────────
    #
    # The half of "reached the customer" that nothing measured. A key handed
    # over and a key that can be spent are different facts, and for the whole
    # of v1.0 the second one was false while the first was true.
    #
    # ⛔ NO SECRET IS READ, TYPED, LOGGED OR COMPARED. The measurement is a
    # DELIBERATELY WRONG key of the right shape. A box whose redeemer is
    # present, importable, pointed at this keychain and able to reach
    # unlock_with_recovery_key answers "Incorrect recovery key" and exits 1.
    # That string cannot be produced without having loaded THIS box's
    # keychain.json and verified against its recovery_verification hash, so a
    # rejection is a positive proof of reachability, not an absence.
    #
    # WHAT THE OTHER OUTCOMES MEAN, and they are distinguishable on purpose:
    #   rc 127 / no such file   the redeemer is not installed at all
    #   rc 2                    it ran and found no config or no envelope
    #   rc 3 / traceback        it ran and broke
    # None of those is "the key was wrong", and none of them may read as one.
    # ONE round trip, and a PER-RUN mktemp sink rather than a fixed path.
    # bash ABORTS a command whose redirection cannot be opened, so a fixed
    # sink in a directory that happens not to exist would turn "the redeemer
    # ran and rejected the key" into an unexplained non-zero. Same class as
    # #910, and the reason that gate exists.
    _redeem_out="$(box_run "
        _e=\$(mktemp -t ostler-probe-redeem) || exit 90
        printf 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GG\\n' \
          | \$HOME/.ostler/.venv/bin/ostler-unlock --recovery-key --secret-file - \
              >/dev/null 2>\"\$_e\"
        _rc=\$?
        _m=\$(grep -ac 'Incorrect recovery key' \"\$_e\" 2>/dev/null || echo 0)
        rm -f \"\$_e\"
        printf 'rc=%s msg=%s\\n' \"\$_rc\" \"\$_m\"
    ")"
    _redeem_rc="$(printf '%s' "$_redeem_out" | sed -n 's/.*rc=\([0-9-]*\).*/\1/p' | head -1)"
    _redeem_msg="$(printf '%s' "$_redeem_out" | sed -n 's/.*msg=\([0-9]*\).*/\1/p' | head -1)"
    case "$_redeem_rc" in ''|*[!0-9]*) _redeem_rc=-1 ;; esac
    case "$_redeem_msg" in ''|*[!0-9]*) _redeem_msg=0 ;; esac

    if [ "$_redeem_rc" -eq 1 ] && [ "$_redeem_msg" -gt 0 ]; then
        _redeemable=REDEEMABLE
    elif [ "$_redeem_rc" -eq 127 ] || [ "$_redeem_rc" -eq 126 ]; then
        _redeemable=NOREDEEMER
    elif [ "$_redeem_rc" -eq 2 ]; then
        _redeemable=NOREDEEMER
    else
        _redeemable=UNKNOWN
    fi

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
    #
    # 🔴 THIS DISPATCH NOW CALLS _decide, THE SAME FUNCTION self_test DRIVES.
    # It used to be written out here as its own if-chain, a second copy of the
    # logic self_test exercised in isolation, so a regression to THIS chain
    # (for instance flipping the `-gt 0` on disclosure count) left the
    # self-test's verdict untouched. See tests/... mutation guard.
    _verdict="$(_decide "$_delta" "$_seen" "$_has_block" "$_has_pk" "$_redeemable")"
    case "$_verdict" in
        fail-not-redeemable)
            probe_fail "🔴 THIS BOX HOLDS A RECOVERY ENVELOPE AND SHIPS NOTHING THAT CAN OPEN ONE. A deliberately wrong recovery key was offered to ~/.ostler/.venv/bin/ostler-unlock and the run came back rc=${_redeem_rc} with ${_redeem_msg} rejection message(s); a working redeemer answers rc=1 and 'Incorrect recovery key', which it can only do by loading THIS keychain and verifying against it. So the key the customer was shown cannot be spent on the machine that showed it. No key value was used: the probe offered a wrong one on purpose."
            ;;
        cannot-run-redeemer-unknown)
            probe_cannot_run "the redemption check did not produce a usable answer (rc=${_redeem_rc}, rejection messages=${_redeem_msg}). Neither 'a wrong key is correctly rejected' nor 'nothing can redeem' was established, so whether this box's recovery key can be spent is UNMEASURED. Disclosure was not adjudicated either, because a disclosed key that cannot be redeemed is not a pass."
            ;;
        cannot-run-skip)
            probe_cannot_run "THE KEYCHAIN PREDATES THIS RUN by $(( -_delta )) second(s), so this install took install.sh's already-configured skip and could not have disclosed anything -- demanding that it had would be demanding a key nobody knows. THIS RUN'S code is not implicated and no verdict is offered on it. ⚠️ BUT THE BOX MAY BE STRANDED: the key was minted by an EARLIER run, and if THAT run never disclosed it, nothing ever will -- the keychain persists and every later run skips. Read the earlier transcript if one survives; ostler-recovery cannot succeed here otherwise. (disclosure markers in this run's transcript: gui=${_gui} tty=${_tty})"
            ;;
        cannot-run-ambiguous)
            probe_cannot_run "THE KEYCHAIN IS ${_delta}s OLDER THAN THIS RUN, which is more than clock and parse granularity can explain and less than a confident skip. A keychain a run wrote itself cannot predate it, so this one came from somewhere else -- most likely an install in the previous minute, which is exactly what a walk retry or a double-click produces. This probe CANNOT tell a run that minted-and-missed from a run that correctly skipped a key disclosed moments ago, and guessing would put a red on a box where the customer HAS the key. (disclosure markers in this run: gui=${_gui} tty=${_tty}; searched ${_lines} lines)"
            ;;
        pass-disclosed)
            probe_pass "this run MINTED the recovery block (keychain written ${_delta}s after the run began), disclosed it (${_gui} structured marker(s) and ${_tty} rendered line(s) in ${_lines} transcript lines), AND this box can redeem one: a deliberately wrong key was rejected by ostler-unlock with rc=1 and 'Incorrect recovery key', which requires having loaded this keychain. No key value was read or compared."
            ;;
        fail-minted-not-disclosed)
            probe_fail "🔴 THIS RUN CREATED recovery_encrypted_key AND NEVER DISCLOSED THE KEY. The keychain was written ${_delta}s after this run began, so this is the minting run and it was the only run that could ever hand the key over: the key is deliberately never stored, the keychain IS, and every later install takes the already-configured skip and emits nothing. Searched ${_lines} transcript lines and found 0 structured markers and 0 rendered lines. The redeemer on this box works, which makes it worse, not better: a key that could have been spent was never handed over. This is the v1.0.68 defect (#1540) and it is customer-permanent, not a papercut."
            ;;
        *)
            probe_cannot_run "internal: _decide returned an unrecognised verdict '${_verdict}' for delta=${_delta} seen=${_seen} block=${_has_block}. Nothing was adjudicated."
            ;;
    esac
}

self_test() {
    # Drives the DECISION, not the box. Four arms over the three states plus the
    # one that must not collapse into another.
    #
    # 🔴 _decide IS DEFINED ONCE, ABOVE run_probe, AND SHARED. This function
    # used to define its own local copy here, so a regression to run_probe's
    # separately-written if-chain left this self-test's output byte identical.
    # run_probe now calls this exact function to adjudicate a live box; a
    # mutation to it breaks BOTH in the same commit. See
    # tests/test_a_probes_self_test_must_drive_its_own_decision.sh.
    fails=0
    _t() { got="$(_decide "$1" "$2" "$3" "$4" "$5")"; if [ "$got" = "$6" ]; then printf 'arm OK: delta=%s seen=%s block=%s passkey=%s redeem=%s -> %s\n' "$1" "$2" "$3" "$4" "$5" "$got"; else printf 'arm BROKEN: delta=%s seen=%s block=%s passkey=%s redeem=%s -> %s, wanted %s\n' "$1" "$2" "$3" "$4" "$5" "$got" "$6"; fails=$((fails+1)); fi; }

    _t   5  2 BLOCK   NOPASSKEY REDEEMABLE pass-disclosed
    _t   5  0 BLOCK   NOPASSKEY REDEEMABLE fail-minted-not-disclosed
    _t -1215 0 BLOCK  NOPASSKEY REDEEMABLE cannot-run-skip
    # BOUNDARY ARMS. The suite drove 5 and -1215 and nothing between them, and
    # the whole false-red lives in that gap. Pin both sides of both edges.
    _t  -1  0 BLOCK   NOPASSKEY REDEEMABLE fail-minted-not-disclosed
    _t -40  0 BLOCK   NOPASSKEY REDEEMABLE cannot-run-ambiguous
    _t -59  0 BLOCK   NOPASSKEY REDEEMABLE cannot-run-ambiguous
    _t -61  0 BLOCK   NOPASSKEY REDEEMABLE cannot-run-skip
    # THE NOBLOCK SPLIT. These two arms used to be one, and it returned PASS.
    # A passphrase-primary box with no recovery envelope is the feature not
    # happening; only a passkey-primary box is legitimately exempt.
    _t   5  0 NOBLOCK PASSKEY   REDEEMABLE cannot-run-passkey-primary
    _t   5  0 NOBLOCK NOPASSKEY REDEEMABLE fail-no-recovery-envelope
    # THE REDEEMABILITY ARMS. A disclosed key on a box that cannot spend it
    # must NOT reach pass-disclosed, which is exactly what shipped.
    _t   5  2 BLOCK   NOPASSKEY NOREDEEMER fail-not-redeemable
    _t   5  2 BLOCK   NOPASSKEY UNKNOWN    cannot-run-redeemer-unknown
    # AND IT MUST OUTRANK THE SKIP ARM. "This box cannot redeem" is a property
    # of the artefact, not of who minted, so a re-install walk must not bury it
    # under a CANNOT-RUN about a disclosure this run was never able to make.
    _t -1215 0 BLOCK  NOPASSKEY NOREDEEMER fail-not-redeemable
    # ARM: the skip and the miss must NOT collapse. They are the two runs of
    # the archie2 walk and they want opposite verdicts.
    a="$(_decide -1215 0 BLOCK NOPASSKEY REDEEMABLE)"; b="$(_decide 5 0 BLOCK NOPASSKEY REDEEMABLE)"
    if [ "$a" = "$b" ]; then printf 'arm BROKEN: skip and miss collapse onto %s\n' "$a"; fails=$((fails+1)); else printf 'arm OK: skip (%s) and miss (%s) do not collapse\n' "$a" "$b"; fi
    # ARM: the two NOBLOCK cases must NOT collapse either. Collapsing them is
    # precisely the defect being removed, and it collapsed onto a PASS.
    c="$(_decide 5 0 NOBLOCK PASSKEY REDEEMABLE)"; d="$(_decide 5 0 NOBLOCK NOPASSKEY REDEEMABLE)"
    if [ "$c" = "$d" ]; then printf 'arm BROKEN: the two no-envelope cases collapse onto %s\n' "$c"; fails=$((fails+1)); else printf 'arm OK: passkey-primary (%s) and passphrase-primary-with-no-envelope (%s) do not collapse\n' "$c" "$d"; fi

    # INVERTED ON PURPOSE, same as usage_journal_producers.sh: --self-test must
    # come back FAIL when the control behaved correctly, because that is what
    # proves this probe can go red at all.
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 14 "self-test arms (disclosed / minted-and-missed / skip-path / two ambiguous-window arms / two boundary arms / passkey-primary no-envelope / passphrase-primary no-envelope / no-redeemer / unknown-redeemer / no-redeemer outranks skip / skip and miss do not collapse / the two no-envelope cases do not collapse)"
    probe_fail "negative control behaved correctly on all 14 arms: a disclosing run on a redeemable box PASSes; a minting run with no disclosure FAILs; a keychain 1215s older is CANNOT-RUN skip; -1 still FAILs while -40 and -59 are CANNOT-RUN ambiguous and -61 is a confident skip, which pins BOTH edges of the window TNM found untested; a box with no recovery envelope is CANNOT-RUN only when passkey.json says it is on the other subsystem and FAILs otherwise, where it used to PASS; a box that cannot redeem FAILs even when the key was disclosed, and even on the skip path; an unmeasurable redeemer is CANNOT-RUN, not a pass; and neither the skip-versus-miss pair nor the two no-envelope cases collapse onto one verdict"
}

probe_main "$@"
