#!/bin/bash
# #664 -- an AppleEvent to Messages must never be able to hang the install.
#
# THE DEFECT. `osascript -e 'tell application "Messages" to count of accounts'`
# raises a TCC "wants to control Messages" prompt whenever the Automation grant
# is absent, which on a wiped box is always. osascript then BLOCKS until a human
# clicks. Unattended, nobody ever does. Found on Andy's v1.0.36 walk, inside
# step 35 (hydrate_imessage), where the install simply stopped.
#
# WHY `|| true` DID NOT SAVE IT, and why a source grep for `|| true` would have
# reported this file clean: `|| true` swallows a FAILURE. This call does not
# fail. It blocks. The two look identical in a diff and behave nothing alike.
#
# WHY THIS TEST IS PARTLY BEHAVIOURAL. A grep can prove the deadline is spelled
# at the call sites; only running it proves the deadline is ENFORCED. The
# watchdog half is where the sibling defect #783 lived -- that one sent a single
# SIGTERM, never confirmed death, and exited, so an unresponsive payload
# outlived its own enforcer. So check 3 runs the real helper against a real
# process that ignores SIGTERM, and requires it to die anyway.
#
# Exit codes are tri-state: 0 pass, 1 real failure, 2 CANNOT RUN.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }

[[ -r "$INSTALL_SH" ]] || cannot "install.sh not readable at $INSTALL_SH"
[[ -r "$STRINGS" ]]    || cannot "strings catalogue not readable at $STRINGS"

echo "== #664: the iMessage Automation probe cannot hang =="

# ── 1. the population, built from the CODE ────────────────────────
# Every osascript call that targets Messages, found by searching, not
# by remembering. If a third site is ever added this count moves and
# the check below fails until it is deadlined too -- which is the
# point. My own hand-built populations have been wrong twice this
# week; the file is the authority.
# NOT `mapfile`: macOS ships bash 3.2, which does not have it. The
# customers' shell is the one that has to run this, not ours.
PROBE_LINES=()
while IFS= read -r _l; do
    [[ -n "$_l" ]] && PROBE_LINES+=("$_l")
done < <(grep -n "tell application \"Messages\"" "$INSTALL_SH" | cut -d: -f1)
if [[ "${#PROBE_LINES[@]}" -eq 0 ]]; then
    bad "found ZERO Messages AppleEvent sites -- the search is broken, not the code"
else
    ok "found ${#PROBE_LINES[@]} Messages AppleEvent site(s) to check"
fi

# ── 2. every one of them is deadlined ─────────────────────────────
# Anchored on the emitter: the deadline call must appear within the 3
# lines ABOVE each osascript, which is where the wrapper sits given
# the line-continuation style used at both sites. A wider window would
# pass on an unrelated deadline elsewhere in the block.
undeadlined=0
for ln in "${PROBE_LINES[@]}"; do
    lo=$(( ln - 3 )); [[ "$lo" -lt 1 ]] && lo=1
    window="$(sed -n "${lo},${ln}p" "$INSTALL_SH")"
    if [[ -z "$window" ]]; then
        bad "line $ln: empty window -- refusing to pass on nothing"
        undeadlined=$((undeadlined + 1))
        continue
    fi
    # HERESTRING, NOT A PIPE. `printf ... | grep -q` under `set -o pipefail`
    # reports a SUCCESSFUL match as a FAILURE: grep -q exits the instant it
    # matches, printf dies EPIPE, and pipefail takes printf's status. See
    # tests/test_pipefail_shortcircuit_inversion.sh (#895).
    if grep -q '_ostler_run_with_deadline' <<< "$window"; then
        ok "line $ln: deadlined"
    else
        bad "line $ln: osascript to Messages with NO deadline -- this can hang forever"
        undeadlined=$((undeadlined + 1))
    fi
done
[[ "$undeadlined" -eq 0 ]] && ok "all Messages AppleEvent sites are deadlined"

# ── 3. BEHAVIOURAL: the deadline is enforced, not merely spelled ──
# Extract the real helper from install.sh and run it. The payload
# TRAPS AND IGNORES SIGTERM, so a watchdog that sends one signal and
# walks away (the #783 defect) hangs here and this test times out
# rather than passing. Only a watchdog that verifies death and
# escalates to SIGKILL gets to 124.
helper_src="$(sed -n '/^_ostler_run_with_deadline() {/,/^}/p' "$INSTALL_SH")"
if [[ -z "$helper_src" ]]; then
    bad "could not extract _ostler_run_with_deadline from install.sh"
else
    probe_out="$(
        eval "$helper_src"
        start=$(date +%s)
        _ostler_run_with_deadline 2 bash -c 'trap "" TERM; sleep 60' >/dev/null 2>&1
        rc=$?
        end=$(date +%s)
        printf '%s %s' "$rc" "$(( end - start ))"
    )"
    probe_rc="${probe_out%% *}"; probe_elapsed="${probe_out##* }"
    if [[ "$probe_rc" == "124" ]]; then
        ok "a SIGTERM-ignoring payload is still killed, rc=124 (took ${probe_elapsed}s)"
    else
        bad "expected rc=124 from the deadline, got rc=${probe_rc} after ${probe_elapsed}s"
    fi
    # The deadline must actually BOUND the wait, not just eventually fire.
    if [[ "$probe_elapsed" -le 10 ]]; then
        ok "deadline bounded the wait to ${probe_elapsed}s against a 60s payload"
    else
        bad "deadline took ${probe_elapsed}s to stop a 60s payload -- not a bound"
    fi
fi

# ── 4. ANTI-VACUITY: the check can still see an undeadlined site ───
# Checks 1+2 pass on the fixed file. That is exactly when a predicate
# quietly stops working, so prove it goes RED on a seeded defect. A
# gate never shown failing is a gate with no evidence it can fail.
fixture="$(mktemp)"
{
    echo '#!/bin/bash'
    echo '# seeded, undeadlined -- the pre-fix shape'
    echo "        osascript -e 'tell application \"Messages\" to count of accounts' \\"
    echo '            >/dev/null 2>&1 || true'
} > "$fixture"
seeded_ln="$(grep -n "tell application \"Messages\"" "$fixture" | cut -d: -f1)"
seeded_lo=$(( seeded_ln - 3 )); [[ "$seeded_lo" -lt 1 ]] && seeded_lo=1
# HERESTRING, NOT A PIPE -- and note the producer here is `sed`, not `printf`.
# The class is the SHORT-CIRCUITING CONSUMER, whatever feeds it. Left as a
# pipe this was the worst instance in the file: a missed match lands on `ok`,
# so the one limb whose whole job is to prove the predicate CAN go red would
# have been the limb that failed silently open.
seeded_window="$(sed -n "${seeded_lo},${seeded_ln}p" "$fixture")"
if grep -q '_ostler_run_with_deadline' <<< "$seeded_window"; then
    bad "anti-vacuity: predicate passed a SEEDED undeadlined probe -- it is blind"
else
    ok "anti-vacuity: predicate goes RED on a seeded undeadlined probe"
fi
rm -f "$fixture"

# ── 5. the timeout branch is a distinct, honest state ─────────────
# A probe nobody answered is NOT a denial: the customer may simply
# have walked away and may grant it later. Recording tcc-denied would
# be an assumption dressed as an observation.
# 🔴 READ THE CODE, NOT THE PROSE ABOUT IT. The first version of this
# check grepped a 4-line window and matched the word "tcc-denied"
# inside the explanatory COMMENT that says a timeout must NOT be
# recorded as tcc-denied -- so it failed a correct implementation for
# describing itself. Same error shape as a gate matching its own
# comment instead of the emitter. Strip comments, then assert on the
# assignment that actually executes.
tb="$(sed -n '/_imessage_probe_rc" -eq 124/,/^        else$/p' "$INSTALL_SH" \
      | grep -vE '^[[:space:]]*#' || true)"
if [[ -z "$tb" ]]; then
    bad "no rc=124 branch at the authoritative probe -- a timeout is being misread"
# HERESTRINGS, NOT PIPES -- and this pair is the dangerous direction. As a
# pipe, the tcc-denied arm is a FALSE PASS: if the inversion fires, the branch
# that is supposed to CATCH a timeout being misrecorded as tcc-denied simply
# does not fire, and the check falls through and reports the honest outcome.
# The guard against a dishonest status would itself have been dishonest.
elif grep -q 'IMESSAGE_TCC_STATUS="tcc-denied"' <<< "$tb"; then
    bad "a timed-out probe is recorded as tcc-denied -- that is an assumption, not an observation"
elif grep -q 'IMESSAGE_TCC_STATUS="check-failed"' <<< "$tb"; then
    ok "a timed-out probe records check-failed, so the daemon re-probes and it self-heals"
else
    bad "rc=124 branch records neither check-failed nor tcc-denied"
fi

# ── 6. the customer is told, in a localised string ────────────────
# CM051 rule: no hardcoded user-facing English. The warn must come
# from the catalogue, and the catalogue must define it.
if grep -q 'warn "\$MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT"' "$INSTALL_SH"; then
    ok "timeout surfaces a warn to the customer"
else
    bad "timeout is silent -- the customer loses iMessage with no explanation"
fi
if grep -q '^MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT=' "$STRINGS"; then
    ok "MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT is defined in the catalogue"
else
    bad "MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT missing -- the warn would print a literal var name"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
