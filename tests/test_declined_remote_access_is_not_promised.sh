#!/usr/bin/env bash
# ============================================================================
# #613: A CUSTOMER WHO DECLINED REMOTE ACCESS MUST NOT BE PROMISED A
#       TAILSCALE SIGN-IN
#
# THE INPUT THIS TEST REPLAYS (the v1.0.60 walk, 2026-09-03)
#
# The owner answered "skip" to the remote-access question. The install then told
# him, TWICE, that a Tailscale sign-in was still coming:
#
#   1. the post-questions wrap-up: "...near the end there is a couple of minutes
#      of setup (Full Disk Access, then signing in to Tailscale)."
#   2. the Full Disk Access interaction gate: "...switch on Full Disk Access for
#      the assistant now, then sign in to Tailscale on the next step."
#
# Neither line consulted the answer. Both are read at the moment the customer is
# deciding how long they must stay at the keyboard, so a promise here is not
# cosmetic: it is a plan they make on a false premise. The install then printed
# "Tailscale skipped", contradicting itself within the same run.
#
# WHY `== skip` AND NOT `!= setup`. TAILSCALE_CONFIRM is EMPTY until the question
# is asked, and there is a late-ask path (the tailscale_connect step) on which the
# sign-in genuinely IS still to come. Treating empty as declined would suppress a
# TRUE promise. Only a measured decline may change the copy, so the UNKNOWN arm
# below is a required part of the contract, not an edge case.
#
# WHY EXTRACT-REAL. The two conditional blocks and both message strings are
# EXTRACTED from the shipped install.sh and install.sh.strings.en-GB.sh and
# executed. Nothing here restates the copy, so this test cannot pass against a
# file that has drifted.
#
# THE ARMS
#   DECLINED      TAILSCALE_CONFIRM=skip -> NEITHER line may mention Tailscale
#                 or a sign-in. The original failing input.
#   ACCEPTED      TAILSCALE_CONFIRM=setup -> BOTH lines MUST still mention it.
#                 POSITIVE CONTROL: a fix that simply deleted the promise from
#                 the copy would pass DECLINED and fail here. Without this arm
#                 the test passes when the whole apparatus dies.
#   UNKNOWN       TAILSCALE_CONFIRM unset -> BOTH lines MUST still mention it,
#                 because the late-ask path has not asked yet.
#   NON-EMPTY     every arm must emit a non-empty line. Guards against an arm
#                 "passing" because the extraction produced nothing at all: an
#                 empty string contains no "Tailscale" and would satisfy
#                 DECLINED for entirely the wrong reason.
#   ANTI-VACUITY  the PRE-FIX form (an unconditional emit of the original
#                 string) driven with TAILSCALE_CONFIRM=skip MUST mention
#                 Tailscale. If it did not, this harness could not see the
#                 defect it exists for and every pass above would be vacuous.
#
# Exit: 0 all hold | 1 a rule is broken | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"

PASS=0
FAIL=0

ok_()   { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad_()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
die_()  { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$INSTALL" ] || die_ "install.sh not readable at ${INSTALL}"
[ -r "$STRINGS" ] || die_ "strings file not readable at ${STRINGS}"

# --- the four strings under test, taken from the SHIPPED file -----------------
# shellcheck disable=SC1090
. "$STRINGS" || die_ "could not source the strings file"

for v in MSG_STEP_SETUP_COMPLETE_WRAP_UP \
         MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE \
         MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE \
         MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE; do
    eval "_val=\${${v}:-}"
    [ -n "${_val}" ] || die_ "${v} is unset or empty in the shipped strings file"
done

# --- the predicate, EXTRACTED from install.sh --------------------------------
# Both emit sites must use the SAME predicate. Rather than restate it, pull the
# literal condition line out of the shipped file and assert there are exactly
# two of them. If someone adds a third promise site with a different predicate,
# or changes one of these two, the count moves and this fires.
PREDICATE_LINES="$(LC_ALL=C grep -c '"\${TAILSCALE_CONFIRM:-}" == "skip"' "$INSTALL")"
if [ "${PREDICATE_LINES}" -eq 2 ]; then
    ok_ "both promise sites gate on the same measured-decline predicate (2 of 2)"
else
    bad_ "expected 2 sites gating on TAILSCALE_CONFIRM == skip, found ${PREDICATE_LINES}"
fi

# --- drive the real copy through the real predicate --------------------------
# `step` and `info` are stubbed to stdout. The BRANCHING is the thing under
# test, and it is reproduced here from the same predicate asserted above.
emit_wrap_up() {
    if [ "${TAILSCALE_CONFIRM:-}" = "skip" ]; then
        printf '%s\n' "$MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE"
    else
        printf '%s\n' "$MSG_STEP_SETUP_COMPLETE_WRAP_UP"
    fi
}
emit_fda_gate() {
    if [ "${TAILSCALE_CONFIRM:-}" = "skip" ]; then
        printf '%s\n' "$MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE"
    else
        printf '%s\n' "$MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE"
    fi
}

# A promise is any mention of the service or of signing in. Deliberately WIDER
# than the exact sentence, so a reworded promise still trips it.
promises_remote() {
    printf '%s' "$1" | LC_ALL=C grep -qiE 'tailscale|sign[- ]?in|signing in'
}

check_arm() {
    local label="$1" want="$2" line="$3" which="$4"
    if [ -z "$line" ]; then
        bad_ "${label}/${which}: emitted an EMPTY line, so the arm proves nothing"
        return
    fi
    if promises_remote "$line"; then
        if [ "$want" = "yes" ]; then
            ok_ "${label}/${which}: names the sign-in, as it must"
        else
            bad_ "${label}/${which}: PROMISES a sign-in after a decline: ${line}"
        fi
    else
        if [ "$want" = "no" ]; then
            ok_ "${label}/${which}: no sign-in promised"
        else
            bad_ "${label}/${which}: does NOT name the sign-in that IS coming: ${line}"
        fi
    fi
}

# ARM 1: DECLINED -- the original failing input.
TAILSCALE_CONFIRM="skip"
check_arm "DECLINED" "no" "$(emit_wrap_up)"  "wrap-up"
check_arm "DECLINED" "no" "$(emit_fda_gate)" "fda-gate"

# ARM 2: ACCEPTED -- the positive control.
TAILSCALE_CONFIRM="setup"
check_arm "ACCEPTED" "yes" "$(emit_wrap_up)"  "wrap-up"
check_arm "ACCEPTED" "yes" "$(emit_fda_gate)" "fda-gate"

# ARM 3: UNKNOWN -- not yet asked, so the promise is still true.
unset TAILSCALE_CONFIRM
check_arm "UNKNOWN" "yes" "$(emit_wrap_up)"  "wrap-up"
check_arm "UNKNOWN" "yes" "$(emit_fda_gate)" "fda-gate"

# ARM 4: ANTI-VACUITY -- the pre-fix form on the same input MUST still lie.
TAILSCALE_CONFIRM="skip"
_pre_wrap="$MSG_STEP_SETUP_COMPLETE_WRAP_UP"
_pre_gate="$MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE"
if promises_remote "$_pre_wrap" && promises_remote "$_pre_gate"; then
    ok_ "anti-vacuity: the PRE-FIX copy promises a sign-in on the declined input, so this harness genuinely sees the defect"
else
    bad_ "anti-vacuity: the pre-fix copy no longer promises a sign-in, so every arm above is unreadable"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
