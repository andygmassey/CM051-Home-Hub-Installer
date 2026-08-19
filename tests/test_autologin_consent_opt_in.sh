#!/usr/bin/env bash
# Pins the two properties of the reboot self-heal auto-login step that are
# security-load-bearing and were both wrong when the step first landed
# (PR #452):
#
#   A. THE COPY DOES NOT OVERCLAIM. The step stores the customer's login
#      password at /etc/kcpassword, scrambled with a fixed, publicly
#      documented cipher, on a Mac that is known to have FileVault OFF (the
#      fdesetup guard is what makes that certain). The original copy called
#      that "the macOS auto-login keystore" and said the password "is never
#      shown or written to any log". The first is a place that does not
#      exist and borrows Keychain's reputation; the second was a blanket
#      claim across surfaces nobody had measured. Both are pinned dead here.
#
#   B. THE GATE IS OPT-IN, AND A BARE ENTER DECLINES. The original gate was
#      `gui_read ... text "Y"` plus `[[ "$_consent" =~ ^[Nn] ]] -> decline`,
#      i.e. decline-matching: EVERY answer that was not an explicit no
#      enabled the feature, including the empty string. The empty string is
#      reachable in the shipping GUI -- gui_read's OSTLER_GUI branch returns
#      the GUI's line verbatim and only substitutes default_value on EOF,
#      and OnboardingQuestionView.validate() accepts an empty `.text` answer
#      whenever the prompt carries a default. So clearing the field and
#      pressing Continue enabled it. Now the default is "N" and the case is
#      affirmative-only.
#
# Section B drives the REAL gate: the case block is extracted from install.sh
# by line range and executed, rather than grepped for. A grep would pass on a
# gate that compiles and decides backwards.
#
# Every absence assertion below is paired with a positive control that MUST
# match, printed with its result, so a wrong predicate or a dead probe shows
# up as a failure rather than a green tick over nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=1; }

for f in "$INSTALL_SH" "$STRINGS" "$EMITTER"; do
    [[ -f "$f" ]] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 1; }
done

bash -n "$INSTALL_SH"
bash -n "$STRINGS"
pass "install.sh and the en-GB catalogue parse"

# ── A. Copy assertions ─────────────────────────────────────────────
# Pull just the AUTOLOGIN block out of the catalogue. grep -F throughout:
# BSD grep reads a bare `$` as an anchor mid-pattern, so any literal pattern
# carrying one silently matches nothing.
AUTOLOGIN_COPY="$(mktemp)"
trap 'rm -f "$AUTOLOGIN_COPY"' EXIT
awk '/^MSG_[A-Z_]*AUTOLOGIN/ {p=1} p {print} /^MSG_WARN_AUTOLOGIN_FILEVAULT=/ {p=0}' \
    "$STRINGS" > "$AUTOLOGIN_COPY"

COPY_LINES="$(wc -l < "$AUTOLOGIN_COPY" | tr -d ' ')"
if [[ "$COPY_LINES" -lt 10 ]]; then
    fail "extracted only ${COPY_LINES} lines of AUTOLOGIN copy -- the extractor is broken, so every assertion below would pass against nothing"
else
    pass "extracted ${COPY_LINES} lines of AUTOLOGIN copy to assert against (denominator is non-zero)"
fi

# A1. Banned places. "keystore" / "keychain" cannot appear in this copy at
# all: neither is where the password goes, and both borrow the reputation of
# something that actually protects secrets.
for banned in keystore keychain; do
    if grep -iqF "$banned" "$AUTOLOGIN_COPY"; then
        fail "AUTOLOGIN copy claims '${banned}'. The password goes to /etc/kcpassword, obfuscated with a fixed public cipher -- say that instead"
    else
        pass "AUTOLOGIN copy does not claim '${banned}'"
    fi
done
# CONTROL for A1: the same predicate, against a word that MUST be there. If
# this fails, the -iqF probe is broken and the two passes above mean nothing.
if grep -iqF "kcpassword" "$AUTOLOGIN_COPY"; then
    pass "CONTROL: the grep -iqF predicate finds 'kcpassword', which must be present"
else
    fail "CONTROL FAILED: grep -iqF cannot find 'kcpassword' in the AUTOLOGIN copy -- the two 'not present' results above are meaningless"
fi

# A2. No blanket never-logged claim. A narrow, measured statement about the
# install log is allowed and is what the copy carries; "any log" is not.
if grep -iqF "any log" "$AUTOLOGIN_COPY"; then
    fail "AUTOLOGIN copy makes a blanket 'any log' claim. Only surfaces that were actually measured may be named"
else
    pass "AUTOLOGIN copy makes no blanket 'any log' claim"
fi

# A3. The load-bearing disclosures are PRESENT. Absence assertions alone
# would pass on an empty string, so pin the shape that has to be there.
assert_reason_has() {
    if grep -iqF "$1" "$AUTOLOGIN_COPY"; then
        pass "AUTOLOGIN copy discloses: ${1}"
    else
        fail "AUTOLOGIN copy no longer discloses '${1}' -- the customer is typing a login password and has to be told this"
    fi
}
assert_reason_has "/etc/kcpassword"
assert_reason_has "not encryption"
assert_reason_has "administrator account"
assert_reason_has "publicly documented"
assert_reason_has "FileVault"

# A4. The prompt itself advertises the opt-in default.
if grep -qF '[y/N]' "$STRINGS"; then
    pass "consent prompt advertises the [y/N] opt-in default"
else
    fail "consent prompt no longer carries [y/N]"
fi
if grep -qF '[Y/n]' "$AUTOLOGIN_COPY"; then
    fail "consent prompt still advertises [Y/n] -- a security-weakening step must not default to yes"
else
    pass "consent prompt does not advertise [Y/n]"
fi

# ── B. Behavioural: drive the real gate ────────────────────────────
# Locate the gate by content, not by a hard-coded line number.
GATE_START="$(grep -nF '_consent="$(gui_read "$MSG_PROMPT_AUTOLOGIN_CONSENT"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "${GATE_START:-}" ]]; then
    printf 'FAIL: could not find the auto-login consent gate in install.sh\n' >&2
    exit 1
fi
# Back up to `local _consent`, forward to the closing `esac`.
while [[ "$(sed -n "${GATE_START}p" "$INSTALL_SH" | sed 's/^[[:space:]]*//')" != "local _consent" ]]; do
    GATE_START=$((GATE_START - 1))
    [[ "$GATE_START" -gt 0 ]] || { printf 'FAIL: no `local _consent` above the gate\n' >&2; exit 1; }
done
# Bounded forward search. An UNBOUNDED walk to the next `esac` is the bug that
# makes this kind of extractor lie: if the gate is ever rewritten back into an
# `if`, the walk sails past it and latches onto some unrelated `case` hundreds
# of lines downstream, then "successfully" executes 500 lines of install.sh.
# The gate is ten lines; anything beyond 30 means the affirmative-only case is
# gone, which is itself the regression.
GATE_END="$GATE_START"
GATE_LIMIT=$((GATE_START + 30))
while [[ "$(sed -n "${GATE_END}p" "$INSTALL_SH" | sed 's/^[[:space:]]*//')" != "esac" ]]; do
    GATE_END=$((GATE_END + 1))
    if [[ "$GATE_END" -gt "$GATE_LIMIT" ]]; then
        printf 'FAIL: no closing `esac` within 30 lines of `local _consent` (searched %s-%s). The consent gate is no longer an affirmative-only case block, so an unrecognised or empty answer is not provably a decline.\n' \
            "$GATE_START" "$GATE_LIMIT" >&2
        exit 1
    fi
done
pass "located the consent gate at install.sh lines ${GATE_START}-${GATE_END}"

GATE_FN="$(mktemp)"
{
    echo 'gate() {'
    sed -n "${GATE_START},${GATE_END}p" "$INSTALL_SH"
    echo '    return 9'   # only reachable if the gate let us through
    echo '}'
} > "$GATE_FN"
bash -n "$GATE_FN" || { printf 'FAIL: extracted gate does not parse\n' >&2; exit 1; }

# Real strings, real gui_read.
# shellcheck disable=SC1090
. "$STRINGS"
# shellcheck disable=SC1090
. "$EMITTER"
# shellcheck disable=SC1090
. "$GATE_FN"
_explain="(help copy)"
_reason="(help copy)"
info() { :; }

EMPTY="$(mktemp)"; printf '\n' > "$EMPTY"
EOFF="$(mktemp)";  : > "$EOFF"
YES="$(mktemp)";   printf 'y\n' > "$YES"
YESU="$(mktemp)";  printf 'Y\n' > "$YESU"
NO="$(mktemp)";    printf 'n\n' > "$NO"
JUNK="$(mktemp)";  printf 'sure\n' > "$JUNK"
trap 'rm -f "$AUTOLOGIN_COPY" "$GATE_FN" "$EMPTY" "$EOFF" "$YES" "$YESU" "$NO" "$JUNK"' EXIT

# drive <mode:tty|gui> <payload-file> -> echoes PROCEED or DECLINE
drive() {
    local mode="$1" payload="$2" rc=0
    if [[ "$mode" == tty ]]; then
        unset OSTLER_GUI OSTLER_GUI_FD || true
        gate < "$payload" >/dev/null 2>&1 || rc=$?
    else
        OSTLER_GUI=1 OSTLER_GUI_FD=4
        export OSTLER_GUI OSTLER_GUI_FD
        exec 4< "$payload"
        gate >/dev/null 2>&1 || rc=$?
        exec 4<&-
        unset OSTLER_GUI OSTLER_GUI_FD
    fi
    [[ "$rc" -eq 9 ]] && echo PROCEED || echo DECLINE
}

expect() { # expect <label> <mode> <payload> <PROCEED|DECLINE>
    local got
    got="$(drive "$2" "$3")"
    if [[ "$got" == "$4" ]]; then
        pass "gate: $1 -> $4"
    else
        fail "gate: $1 -> $got, expected $4"
    fi
}

# The regression this file exists for: a bare Enter must NOT enable it.
expect "TTY, bare Enter (default N substituted)"      tty "$EMPTY" DECLINE
expect "GUI, field cleared -> empty line, no default" gui "$EMPTY" DECLINE
expect "GUI, pipe closed -> EOF, default N"           gui "$EOFF"  DECLINE
expect "TTY, explicit n"                              tty "$NO"    DECLINE
expect "TTY, unrecognised answer 'sure'"              tty "$JUNK"  DECLINE
# POSITIVE CONTROLS. Without these the five DECLINEs above would also pass on
# a gate that is broken shut, or on a harness that cannot invoke the gate.
expect "CONTROL: TTY, explicit y -- must proceed"     tty "$YES"   PROCEED
expect "CONTROL: TTY, explicit Y -- must proceed"     tty "$YESU"  PROCEED

if [[ "$FAILED" -ne 0 ]]; then
    printf '\ntest_autologin_consent_opt_in: FAILED\n' >&2
    exit 1
fi
printf '\ntest_autologin_consent_opt_in: all assertions passed\n'
