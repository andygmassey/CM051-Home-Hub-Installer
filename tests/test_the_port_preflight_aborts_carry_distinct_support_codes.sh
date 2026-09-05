#!/usr/bin/env bash
# The two port-preflight aborts must each carry a DISTINCT support code.
#
# WHY THIS EXISTS. CM051 #1498 swapped two bare `fail` calls for
# `fail_with_code`, giving the customer something stable to quote at support
# when an install stops on a port collision. That is the single most likely
# way an install stops on a Mac that already runs something.
#
# 🔴 AND #1498 SHIPPED WITHOUT A TEST THAT COULD SEE IT. The test it shipped
# alongside, test_port_preflight_covers_published.sh, returns 16 pass / 0 fail
# against the PRE-FIX tree at 03b50c6b. It tests preflight COVERAGE and the
# bind probe; nothing in it looks at which function the abort calls. WIRED IS
# NOT FAILING. This file is the gate that discriminates the change, written
# after the v1.0.68 BOM row that cited the wrong one was refuted.
#
# THE TWO CODES ARE DISTINCT ON PURPOSE. "We saw a collision" and "we could not
# tell" are different facts with different next steps for the customer, and
# collapsing them onto one code is how a CANNOT-RUN gets triaged as a FAIL.
# A single shared code passes a naive "is there a code" check, so DISTINCTNESS
# is asserted separately and is its own arm.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

CODE_HELD="ERR-06-PORTS-HELD"
CODE_CANT="ERR-06-PORT-PREFLIGHT-CANNOT-RUN"
MSG_HELD='$MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT'
MSG_CANT='$MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT'

# -F throughout. A '$' in these patterns is a LITERAL dollar, and BSD grep
# reads a bare '$' mid-pattern as an anchor, which matches nothing.
_calls_with_code() {  # <file> <message-var> -> the code, or empty
    /usr/bin/grep -F -- "$2" "$1" \
        | /usr/bin/grep -F 'fail_with_code' \
        | /usr/bin/sed -n 's/.*fail_with_code[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}
_bare_fail() {  # <file> <message-var> -> count of BARE `fail "<msg>"` sites
    /usr/bin/grep -F -- "$2" "$1" | /usr/bin/grep -cE '(^|[[:space:]])fail[[:space:]]+"' || true
}

_arms() {  # <file> <label>; sets ARM_HELD / ARM_CANT
    ARM_HELD="$(_calls_with_code "$1" "$MSG_HELD")"
    ARM_CANT="$(_calls_with_code "$1" "$MSG_CANT")"
}

echo "── subject: this tree ──"
_arms "$SUBJECT"

[ "$ARM_HELD" = "$CODE_HELD" ] \
    && ok "the ports-held abort carries ${CODE_HELD}" \
    || bad "the ports-held abort carries '${ARM_HELD:-<no code>}', expected ${CODE_HELD}"

[ "$ARM_CANT" = "$CODE_CANT" ] \
    && ok "the cannot-run abort carries ${CODE_CANT}" \
    || bad "the cannot-run abort carries '${ARM_CANT:-<no code>}', expected ${CODE_CANT}"

# THE ARM A SHARED CODE WOULD SURVIVE WITHOUT. Both sites having "a code" is
# not the property; having DIFFERENT codes is.
if [ -n "$ARM_HELD" ] && [ "$ARM_HELD" = "$ARM_CANT" ]; then
    bad "both aborts share the code '${ARM_HELD}'. A collision and a could-not-tell are different facts."
else
    ok "the two codes are DISTINCT, so a CANNOT-RUN cannot be triaged as a collision"
fi

# Neither site may ALSO have a bare `fail` form left behind.
n="$(_bare_fail "$SUBJECT" "$MSG_HELD")"; m="$(_bare_fail "$SUBJECT" "$MSG_CANT")"
[ "$n" -eq 0 ] && [ "$m" -eq 0 ] \
    && ok "no bare 'fail \"...\"' remains at either site (held=${n} cant=${m})" \
    || bad "a bare fail survives: held=${n} cant=${m}. A second uncoded path is the defect returning."

# #1439's class: the helper must be BOUND before these top-level calls run.
# 🔴 A MISSING DEFINITION OR A MISSING CALL SITE IS A FAIL, NOT A CANNOT-RUN.
# An earlier draft exited 2 for both, and MUTATION TESTING is what caught it:
# reverting one site to a bare `fail` made this file report CANNOT-RUN for a
# real regression, and a CANNOT-RUN gets triaged as an environment problem
# while a FAIL gets triaged as a defect. CANNOT-RUN is reserved for the
# apparatus failing (unreadable install.sh, unreadable control blob), never
# for the subject being broken -- which is the whole point of the third state.
def_ln="$(/usr/bin/grep -n '^fail_with_code()' "$SUBJECT" | head -1 | cut -d: -f1)"
use_ln="$(/usr/bin/grep -n -F -- "$CODE_HELD" "$SUBJECT" | head -1 | cut -d: -f1)"
if [ -z "$def_ln" ]; then
    bad "fail_with_code has no top-level definition in install.sh, yet the aborts call it. That is the #1439 class: a call against a name bash has not bound."
elif [ -z "$use_ln" ]; then
    bad "no call site carries ${CODE_HELD} at all, so there is no ordering to check and the coded abort is gone."
elif [ "$def_ln" -lt "$use_ln" ]; then
    ok "fail_with_code is DEFINED (:${def_ln}) before it is CALLED (:${use_ln})"
else
    bad "fail_with_code is called at :${use_ln} but defined at :${def_ln}. install.sh is linear."
fi

# ── NEGATIVE CONTROL, pinned to the tree that SHIPPED the uncoded aborts ──
# 03b50c6b is the v1.0.67 pin: the artefact that was published, installed and
# walked four times with both aborts bare. Pinned to a fixed sha, never a
# branch: a control that reads origin/main inverts the moment a fix merges.
_CONTROL_SHA="03b50c6b"
echo "── negative control: ${_CONTROL_SHA} (the v1.0.67 pin) ──"
CTL="$(mktemp)" || { echo "CANNOT-RUN: no temp file" >&2; exit 2; }
trap 'rm -f "$CTL"' EXIT
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$CTL" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

# CONTROL ON THE CONTROL, FIRST. If the pre-fix tree does not even contain the
# two messages then a missing CODE below would be indistinguishable from a
# missing SITE, and the control would prove nothing about #1498.
c_held="$(/usr/bin/grep -cF -- "$MSG_HELD" "$CTL")"
c_cant="$(/usr/bin/grep -cF -- "$MSG_CANT" "$CTL")"
[ "$c_held" -ge 1 ] && [ "$c_cant" -ge 1 ] \
    && ok "CONTROL ON THE CONTROL: both abort sites EXIST at ${_CONTROL_SHA} (held=${c_held} cant=${c_cant}), so a missing code is about the code" \
    || bad "the abort sites are absent at ${_CONTROL_SHA} (held=${c_held} cant=${c_cant}); this control cannot speak to #1498"

_arms "$CTL"
[ -z "$ARM_HELD" ] && [ -z "$ARM_CANT" ] \
    && ok "control ${_CONTROL_SHA}: NEITHER abort carries a code, reproducing what v1.0.67 shipped" \
    || bad "control ${_CONTROL_SHA} already carries codes (held='${ARM_HELD}' cant='${ARM_CANT}'); this harness is not measuring #1498"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
