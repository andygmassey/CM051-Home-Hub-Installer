#!/usr/bin/env bash
# The Homebrew failure must WRITE the log file it tells the customer to attach (W003)
# ==================================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# v1.0.63, walked on a genuinely wiped Mini. Homebrew failed, the install
# aborted ERR-04-HOMEBREW-INSTALL -> ERR-99-INSTALL-ABORT-L10861, and the
# customer was told:
#
#     Full output saved to /tmp/ostler-brew-install.log - attach it
#
# There is no such file. Measured on the box: no /tmp/*brew* match, with a
# control confirming /tmp readable and holding 6 entries.
#
# WHAT WAS ACTUALLY HAPPENING, WHICH IS THE INTERESTING PART
#
# The log is NOT missing. It is written, to a DIFFERENT path:
#
#     install.sh:168    OSTLER_DIAG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ostler-diag-XXXXXX")"
#     install.sh:10778  BREW_INSTALL_LOG="${OSTLER_DIAG_DIR}/brew-install.log"
#
# Two string literals that drifted: a different directory AND a different
# basename. On macOS TMPDIR is /var/folders/<xx>/<yy>/T/, never /tmp, so the
# real log was never going to appear where the message sends the customer.
# Every ERR-04 support report therefore arrives with nothing attached.
#
# WHY THE EXISTING GUARD DID NOT CATCH IT, WHICH IS THE MECHANISM
#
# tests/test_brew_install_fail_loud.sh is 232 lines and asserts entirely by
# grepping install.sh's SOURCE. Its strings arm (:178) is:
#
#     if ! grep -q "^${key}=" "$STRINGS_FILE"; then
#
# It verifies that the message KEY EXISTS. It has no opinion on whether the
# path inside the message is real, and it never runs the installer. So the
# guard covering this exact area is structurally incapable of noticing that a
# message names a file nothing writes -- the literals could drift precisely
# because the only thing watching was checking the claim was PRESENT, never
# that it was TRUE. Same family as #1401.
#
# WHAT THIS TEST ASSERTS
#
#   A   ORIGINAL FAILING INPUT. Drive the REAL failure branch extracted from
#       install.sh with a non-zero BREW_EXIT. The path the customer-facing
#       message NAMES must EXIST, be NON-EMPTY, and carry the Homebrew output.
#       This is the property, and it is deliberately not "a particular path
#       exists": what makes the statement true is that the named file is there.
#   B   POSITIVE CONTROL, MUST BE PRESENT. The private diag log is readable by
#       the extracted block. Without this, A could fail because the harness
#       never wired the block up, and "nothing was published" would be
#       indistinguishable from "the block never ran".
#   C   DECLARED NEGATIVE CONTROL. The source-grep form of this check -- "does
#       install.sh mention the message key?" -- is run and REQUIRED TO PASS on
#       the broken tree. It is in here so the histogram shows, in one run, that
#       the cheap check cannot separate a fixed tree from a broken one.
#   D   THE NAMED PATH IS THE PRIVATE PER-RUN SINK, NOT A FIXED /tmp NAME.
#       Publishing a copy to /tmp/ostler-brew-install.log was the first shape
#       tried and it is FORBIDDEN: #910 (tests/test_diag_sink_per_run.sh) exists
#       to keep diagnostics in a private per-run directory, because a fixed name
#       in a world-writable directory lets another user pre-create our log
#       files. So this arm fails the message-side fix if it ever drifts back
#       into naming a fixed /tmp path.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
STRINGS_FILE="${REPO}/install.sh.strings.en-GB.sh"

FAILURES=0
PASSES=0
fatal() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
pass()  { PASSES=$((PASSES+1)); printf '  PASS  %s\n' "$1"; }
red()   { FAILURES=$((FAILURES+1)); printf '  RED   %s\n' "$1"; }

[[ -f "$INSTALL_SH" ]]   || fatal "install.sh not found at ${INSTALL_SH}"
[[ -f "$STRINGS_FILE" ]] || fatal "strings file not found at ${STRINGS_FILE}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/w003-XXXXXX")" || fatal "could not create a work dir"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Extract the REAL failure branch. Anchors chosen because they exist on BOTH
# the pre-fix and post-fix trees, so this test measures behaviour and not the
# presence of a marker the fix itself introduces.
# ---------------------------------------------------------------------------
awk '
    /if \[\[ \$BREW_EXIT -ne 0 \]\]; then/ { inside = 1 }
    inside { print }
    inside && /fail_with_code "ERR-04-HOMEBREW-INSTALL"/ { print "    fi"; exit }
' "$INSTALL_SH" > "${WORK}/branch.sh"

[[ -s "${WORK}/branch.sh" ]] || fatal "could not extract the BREW_EXIT failure branch from install.sh. This test would be measuring nothing."
grep -q 'ERR-04-HOMEBREW-INSTALL' "${WORK}/branch.sh" || fatal "the extracted branch does not contain ERR-04-HOMEBREW-INSTALL. Extraction is broken, not the code."
bash -n "${WORK}/branch.sh" || fatal "the extracted branch does not parse. Extraction is broken, not the code."
printf 'Harness: extracted the BREW_EXIT failure branch (%s lines) from real install.sh.\n\n' "$(wc -l < "${WORK}/branch.sh" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Drive it. Stubs stand in for the reporting surface only -- the log handling
# under test is the real extracted code.
# ---------------------------------------------------------------------------
DIAG="${WORK}/ostler-diag-fake"
mkdir -p "$DIAG"
MARKER="BREW-FAILURE-OUTPUT-MARKER-$$"
printf 'Homebrew installer output line 1\n%s\nfinal line\n' "$MARKER" > "${DIAG}/brew-install.log"

# shellcheck disable=SC2016
{
    printf '%s\n' 'set -uo pipefail'
    # Source the REAL strings file. Stubbing these was a fixture encoding the
    # fix rather than the property: with hand-written %s-form messages the
    # pre-fix tree produced "no path named at all" instead of the actual
    # customer-visible defect, which is a WRONG path being named. The strings
    # are half the defect -- they must come from the tree under test.
    printf '. "%s"\n' "$STRINGS_FILE" 
    printf '%s\n' 'BREW_EXIT=1'
    printf 'BREW_INSTALL_LOG="%s/brew-install.log"\n' "$DIAG"
    printf 'OSTLER_DIAG_DIR="%s"\n' "$DIAG"
    printf '%s\n' 'warn() { printf "WARN: %s\n" "$*" >>"$SHOWN_TO_CUSTOMER"; }'
    printf '%s\n' 'fail_with_code() { printf "FAIL: %s\n" "$2" >>"$SHOWN_TO_CUSTOMER"; exit 4; }'
    printf 'SHOWN_TO_CUSTOMER="%s/shown.txt"\n' "$WORK"
    printf '%s\n' ': > "$SHOWN_TO_CUSTOMER"'
    cat "${WORK}/branch.sh"
} > "${WORK}/drive.sh"

bash "${WORK}/drive.sh" >"${WORK}/stdout.txt" 2>"${WORK}/stderr.txt"
DRIVE_RC=$?
SHOWN="${WORK}/shown.txt"

if [[ ! -s "$SHOWN" ]]; then
    fatal "the extracted branch produced no customer-visible output (rc=${DRIVE_RC}). It did not run; every assertion below would be measuring the harness. stderr: $(head -3 "${WORK}/stderr.txt" 2>/dev/null)"
fi

# --- B: positive control, first, because A is meaningless without it --------
if grep -qF "$MARKER" "$SHOWN"; then
    pass "B  positive control: the branch ran and read the real private diag log (marker surfaced)"
else
    red  "B  positive control: the marker from the private diag log never reached the customer surface -- the harness did not wire the block up, so A/D below are not trustworthy"
fi

# --- A + D: the named path, and what kind of path it is ---------------------
# Take the path the customer was actually shown. Deriving it from the output
# rather than hardcoding it is the whole point: the property is "the installer
# names a file that is there", not "one specific string is present".
NAMED="$(grep -oE '/[A-Za-z0-9_./-]*brew-install\.log' "$SHOWN" | sort -u)"
NAMED_N="$(printf '%s\n' "$NAMED" | grep -c . || true)"

if [[ -z "$NAMED" ]]; then
    red "A  the customer output names NO log path at all -- there is nothing for a support request to attach"
    red "D  cannot classify a path that was never named"
else
    A_BAD=0
    while IFS= read -r pth; do
        [[ -z "$pth" ]] && continue
        if [[ ! -f "$pth" ]]; then
            red "A  the customer is told the log is at ${pth}, and no such file exists. This is W003."
            A_BAD=1
        elif [[ ! -s "$pth" ]]; then
            red "A  ${pth} exists but is EMPTY -- an empty attachment is the same support outcome as no attachment"
            A_BAD=1
        elif ! grep -qF "$MARKER" "$pth"; then
            red "A  ${pth} exists and is non-empty but does not carry the Homebrew output"
            A_BAD=1
        fi
    done <<< "$NAMED"
    [[ $A_BAD -eq 0 ]] && pass "A  every log path shown to the customer (${NAMED_N}) exists, is non-empty, and carries the Homebrew output"

    D_BAD=0
    while IFS= read -r pth; do
        [[ -z "$pth" ]] && continue
        case "$pth" in
            /tmp/ostler-*) red "D  the customer is pointed at the FIXED path ${pth}. #910 forbids a fixed name in a world-writable directory -- another user can pre-create our log files there. The fix belongs in the message, not the filesystem."; D_BAD=1 ;;
        esac
    done <<< "$NAMED"
    [[ $D_BAD -eq 0 ]] && pass "D  the named path is the private per-run diag sink, not a fixed /tmp name (#910 respected)"
fi

# --- C: declared negative control ------------------------------------------
if grep -q "^MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED=" "$STRINGS_FILE"; then
    pass "C  NEGATIVE CONTROL (expected to pass on the BROKEN tree): the message key exists. This is what test_brew_install_fail_loud.sh checks, and it cannot tell a fixed tree from a broken one."
else
    red  "C  negative control did not behave as declared -- the message key is missing entirely, which changes what this test is measuring"
fi

printf '\n'
printf 'CONCLUSION HISTOGRAM\n'
printf '  PASS : %d\n' "$PASSES"
printf '  RED  : %d\n' "$FAILURES"
printf '  TOTAL: %d\n' "$((PASSES + FAILURES))"

[[ $FAILURES -eq 0 ]] || exit 1
exit 0
