#!/usr/bin/env bash
# A missing licence is CANNOT-RUN, never FAIL, and it must be found before
# anything is staged or reset.
#
# WHY THIS EXISTS. MEASURED 2026-09-04 on the first walk of a brand-new macOS
# account. The harness identity-checked, rsynced the whole tree, flattened 15
# payload directories, wrote its config, started the install, and 32 seconds
# later got:
#
#     [fail]  [ERR-02-LICENCE-REQUIRED] Licence check failed: No licence file found.
#
# The product was RIGHT and the harness was late. install.sh reads exactly one
# path -- ${HOME}/.ostler/license/license.json -- and a fresh account has no
# such file, which is the normal state of the cold accounts this harness
# exists to walk.
#
# TWO PROPERTIES, AND THE SECOND IS THE ONE THAT MATTERS MOST:
#
#   1. the check runs BEFORE staging and BEFORE --reset, so a walk that cannot
#      start does not first tear down somebody's box
#   2. every not-present state exits 2 (CANNOT-RUN), never 1 (FAIL). The build
#      under test has not been shown to be bad; the harness was not given what
#      it needs. Conflating those is how a setup gap gets filed as a product
#      defect, and this project has done that before.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── IT MUST PARSE. This is first because nothing below is meaningful if it ──
# does not, and because I shipped a broken parse on 2026-09-04.
#
# The whole RESET body is a SINGLE-QUOTED argument to ssh. One apostrophe
# inside it -- in a COMMENT, in the word "installer's" -- closed the argument,
# and bash then reported the error 400 lines away in unrelated code. The file
# had already been committed and pushed, because the syntax check and the
# commit were separated by `;` rather than `&&`.
if bash -n "$SUBJECT" 2>/dev/null; then
    ok "ttywalk.sh parses (bash -n)"
else
    bad "ttywalk.sh DOES NOT PARSE. Everything below is unmeasurable; fix this first."
    bash -n "$SUBJECT" 2>&1 | sed 's/^/      /' | head -4
    echo
    echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
    exit 1
fi

# No apostrophe may appear in the RESET body. It is a single-quoted ssh
# argument, so an apostrophe is not a typo, it is a quote breakout. bash -n
# catches it only when the quotes fail to rebalance; when they DO rebalance
# the file parses and means something else entirely, which is worse.
# ANY single quote inside the RESET payload BODY is a quote breakout, not
# just prose ones. My first version of this limb looked for apostrophes in
# words like "installer's" and PASSED while `tr -d ' '` sat in the same block.
# That shipped, the ssh payload broke at the tr, and the reset reported
# "no leftover ostler-* containers to remove" while FIVE existed -- a false
# zero that cost walk 7 ten steps. The payload is single-quoted; the only
# legal single quotes are its own delimiters, which are the first and last
# lines and are excluded here.
_reset_body="$(awk '/rule "RESET/{f=1} f{print} f && /^    . 2>&1$/{exit}' "$SUBJECT" | sed '1,2d;$d')"
if [ -n "$_reset_body" ]; then
    _apos="$(printf '%s\n' "$_reset_body" | /usr/bin/grep -c "'" || true)"
    if [ "${_apos:-0}" -eq 0 ]; then
        ok "ZERO single quotes inside the RESET ssh payload body (any one of them closes the argument)"
    else
        bad "${_apos} single quote(s) inside the RESET payload body. Each closes the ssh argument; bash -n only catches it when they fail to rebalance."
        printf '%s\n' "$_reset_body" | /usr/bin/grep -n "'" | sed 's/^/      /' | head -3
    fi
else
    bad "could not extract the RESET body to check it for quote breakouts"
fi

# ── ORDERING: the preflight must precede staging AND reset ───────────────
_line() { /usr/bin/grep -n "$1" "$SUBJECT" | head -1 | cut -d: -f1; }
pyp="$(_line 'rule "BUNDLED-PYTHON PREFLIGHT')"
sud="$(_line 'rule "SUDO PREFLIGHT')"
pre="$(_line 'rule "LICENCE PREFLIGHT')"
rst="$(_line 'rule "RESET')"
stg="$(_line 'rule "STAGE"')"
if [ -z "$pyp" ] || [ -z "$sud" ] || [ -z "$pre" ] || [ -z "$rst" ] || [ -z "$stg" ]; then
    echo "CANNOT-RUN: could not locate all five section rules (python=${pyp:-?} sudo=${sud:-?} licence=${pre:-?} reset=${rst:-?} stage=${stg:-?})." >&2
    echo "  A missing landmark means the ordering was not measured, which is not a pass." >&2
    exit 2
fi
if [ "$pre" -lt "$rst" ] && [ "$pre" -lt "$stg" ]; then
    ok "the licence preflight (line ${pre}) precedes both RESET (${rst}) and STAGE (${stg})"
else
    bad "the licence preflight is at ${pre}, RESET at ${rst}, STAGE at ${stg}. A walk that cannot start must not first tear a box down."
fi
if [ "$pyp" -lt "$rst" ] && [ "$pyp" -lt "$stg" ]; then
    ok "the bundled-python preflight (line ${pyp}) precedes both RESET (${rst}) and STAGE (${stg})"
else
    bad "the bundled-python preflight is at ${pyp}, RESET at ${rst}, STAGE at ${stg}."
fi

# ── BEHAVIOUR: extract the real case block and run it per state ──────────
# Executed, not grepped: the property is which EXIT CODE each state produces,
# and no pattern over the source can tell 2 from 1.
_case="$(awk '
    /^case "\$lic_state" in$/ { f=1 }
    f { print }
    f && /^esac$/ { exit }
' "$SUBJECT")"
if [ -z "$_case" ]; then
    echo "CANNOT-RUN: the lic_state case block was not found in ${SUBJECT}." >&2
    exit 2
fi

_state_exit() {
    local st="$1" r="${WORK}/s"; rm -rf "$r"; mkdir -p "$r"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'say() { printf "%s\n" "$*"; }'
        printf '%s\n' 'HOST="probe@example-host.invalid"'
        printf 'lic_state=%s\n' "$(printf '%q' "$st")"
        printf '%s\n' "$_case"
        # Reached only when the case falls through, i.e. the walk continues.
        printf '%s\n' 'exit 0'
    } > "${r}/run.sh"
    bash "${r}/run.sh" >"${r}/out" 2>"${r}/err"
    printf '%s' "$?"
}

_r="$(_state_exit 'present 447 bytes')"
[ "$_r" = "0" ] \
    && ok "a PRESENT licence lets the walk continue (exit ${_r})" \
    || bad "a present licence stopped the walk with exit ${_r}. The guard is refusing a box that is ready."

for _st in absent empty unreadable; do
    _r="$(_state_exit "$_st")"
    case "$_r" in
        2) ok "state '${_st}' exits 2 CANNOT-RUN, so a setup gap is not recorded as a build verdict" ;;
        1) bad "state '${_st}' exits 1 FAIL. The build has not been shown to be bad; this is how a setup gap gets filed as a product defect." ;;
        0) bad "state '${_st}' exits 0 and the walk would PROCEED, then die 30 seconds later at ERR-02-LICENCE-REQUIRED. That is the defect this guard exists to remove." ;;
        *) bad "state '${_st}' exited ${_r}, which is not one of the three documented states" ;;
    esac
done

# ── The three refusals must not print the same thing ─────────────────────
# "absent", "empty" and "unreadable" are different findings and the operator
# acts differently on each. A guard that collapses them tells the truth about
# the exit code and lies about the cause.
_msg() {
    local st="$1" r="${WORK}/m"; rm -rf "$r"; mkdir -p "$r"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'say() { printf "%s\n" "$*"; }'
        printf '%s\n' 'HOST="probe@example-host.invalid"'
        printf 'lic_state=%s\n' "$(printf '%q' "$st")"
        printf '%s\n' "$_case"
        printf '%s\n' 'exit 0'
    } > "${r}/run.sh"
    bash "${r}/run.sh" 2>&1 | head -1
}
m_absent="$(_msg absent)"; m_empty="$(_msg empty)"; m_unread="$(_msg unreadable)"
if [ "$m_absent" != "$m_empty" ] && [ "$m_empty" != "$m_unread" ] && [ "$m_absent" != "$m_unread" ]; then
    ok "absent / empty / unreadable each report a DIFFERENT cause, not one collapsed message"
else
    bad "two or more refusal messages are identical, so the operator cannot tell which state they are in"
fi

# ── CONTROL ON THE HARNESS ITSELF ────────────────────────────────────────
# Every limb above would also pass against a case block that exits 2 for
# EVERYTHING, including a present licence. The present-licence limb is what
# rules that out, so assert here that the extracted block really does contain
# more than one outcome -- otherwise the four limbs are one limb, four times.
_arms="$(printf '%s' "$_case" | /usr/bin/grep -cE '^\s{4}[a-z*][a-z*]*\)')"
[ "${_arms:-0}" -ge 4 ] \
    && ok "CONTROL: the extracted block carries ${_arms} distinct arms, so the limbs above are not one outcome measured four times" \
    || bad "the extracted block has only ${_arms:-0} arm(s); the state limbs cannot be independent"

# ── BUNDLED-PYTHON PREFLIGHT: absence must REFUSE, not reroute ───────────
# The defect it guards is not a missing file, it is a missing file that
# changes which INTERPRETER PATH install.sh takes. A walk on the dev-mode
# branch produces a red that says nothing about the build, which is worse
# than no walk: it looks like evidence.
_py_block="$(awk '
    /^BUNDLED_PY_LOCAL=/ { f=1 }
    f { print }
    f && /^fi$/ { exit }
' "$SUBJECT")"
if [ -z "$_py_block" ]; then
    echo "CANNOT-RUN: the bundled-python preflight block was not found in ${SUBJECT}." >&2
    exit 2
fi

_py_exit() {
    local root="$1" r="${WORK}/p"; rm -rf "$r"; mkdir -p "$r"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'say() { printf "%s\n" "$*"; }'
        printf 'REPO_ROOT=%s\n' "$(printf '%q' "$root")"
        printf '%s\n' "$_py_block"
        printf '%s\n' 'exit 0'
    } > "${r}/run.sh"
    bash "${r}/run.sh" >/dev/null 2>&1
    printf '%s' "$?"
}

_absent_root="${WORK}/noroot"; mkdir -p "$_absent_root"
_r="$(_py_exit "$_absent_root")"
[ "$_r" = "2" ] \
    && ok "an ABSENT bundled interpreter exits 2 CANNOT-RUN, so the walk cannot silently reroute to the dev branch" \
    || bad "an absent bundled interpreter exited ${_r}. 0 would walk the wrong code path; 1 would blame the build for the harness."

# PRESENT arm, so the limb above is not the only outcome the block can produce.
# A real executable, because the guard tests -x and a plain file would make
# this pass for the wrong reason.
_present_root="${WORK}/withpy"; mkdir -p "${_present_root}/python/bin"
printf '#!/bin/sh\necho "Python 3.11.15"\n' > "${_present_root}/python/bin/python3.11"
chmod +x "${_present_root}/python/bin/python3.11"
_r="$(_py_exit "$_present_root")"
[ "$_r" = "0" ] \
    && ok "CONTROL: a PRESENT bundled interpreter lets the walk continue (exit 0), so the limb above is a measurement" \
    || bad "a present bundled interpreter exited ${_r}; the guard refuses a tree that is ready."

# NON-EXECUTABLE arm. The DMG ships it +x; a copy that lost the bit would
# make install.sh take the dev branch just as surely as absence, and this
# guard tests -x for exactly that reason.
_noexec_root="${WORK}/noexec"; mkdir -p "${_noexec_root}/python/bin"
printf '#!/bin/sh\necho hi\n' > "${_noexec_root}/python/bin/python3.11"
chmod 644 "${_noexec_root}/python/bin/python3.11"
_r="$(_py_exit "$_noexec_root")"
[ "$_r" = "2" ] \
    && ok "a PRESENT but NON-EXECUTABLE interpreter also refuses, matching install.sh's own -x test" \
    || bad "a non-executable interpreter exited ${_r}; install.sh tests -x, so presence alone is not enough."

# ── SUDO PREFLIGHT: WARN, do not refuse, and say it BEFORE 25 minutes ────
# Unlike the licence and the interpreter, a walk without sudo still produces
# real evidence -- 14 of 41 steps, measured -- so refusing would throw away a
# useful run. What is unacceptable is learning the limit at minute 25 from a
# red that names a symlink.
if [ "$sud" -lt "$rst" ] && [ "$sud" -lt "$stg" ]; then
    ok "the sudo preflight (line ${sud}) precedes both RESET (${rst}) and STAGE (${stg})"
else
    bad "the sudo preflight is at ${sud}, RESET at ${rst}, STAGE at ${stg}."
fi

_sudo_block="$(awk '/^rule "SUDO PREFLIGHT/{f=1} f{print} f&&/^fi$/{exit}' "$SUBJECT")"
if [ -z "$_sudo_block" ]; then
    echo "CANNOT-RUN: the sudo preflight block was not found in ${SUBJECT}." >&2
    exit 2
fi

# SSH is stubbed so BOTH branches run without a box. `true` stands in for a
# host with passwordless sudo, `false` for one without.
_sudo_run() {
    local stub="$1" r="${WORK}/su"; rm -rf "$r"; mkdir -p "$r"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'say() { printf "%s\n" "$*"; }'
        printf '%s\n' 'rule() { printf -- "---- %s ----\n" "$*"; }'
        printf '%s\n' 'HOST="probe@example-host.invalid"'
        printf 'SSH=(%s)\n' "$stub"
        printf '%s\n' "$_sudo_block"
        printf '%s\n' 'exit 0'
    } > "${r}/run.sh"
    bash "${r}/run.sh" 2>&1
    printf 'RC=%s' "$?"
}

_out="$(_sudo_run false)"
case "$_out" in
    *"NO PASSWORDLESS SUDO"*RC=0) ok "no sudo: WARNS and continues (rc 0), so a partial walk is still collected" ;;
    *RC=0)                        bad "no sudo: continued but printed no warning. The next run learns this at minute 25." ;;
    *)                            bad "no sudo: refused. A walk without sudo still yields 14 of 41 steps of real evidence." ;;
esac

# CONTROL: with sudo available it must NOT print the warning. Without this the
# limb above would pass against a block that warns unconditionally.
_out="$(_sudo_run true)"
case "$_out" in
    *"NO PASSWORDLESS SUDO"*) bad "CONTROL FAILED: the warning fires even when sudo IS available, so it says nothing" ;;
    *RC=0)                    ok "CONTROL: with passwordless sudo the warning is silent, so it is a measurement" ;;
    *)                        bad "CONTROL FAILED: available sudo gave an unexpected result" ;;
esac

# The remedy must name a sudoers drop-in, not "run as root". An operator who
# cannot act on the warning is being told off, not helped.
# Both tokens must be present, checked INDEPENDENTLY. The first version of
# this limb was a single glob, *sudoers.d*NOPASSWD*, which silently asserted
# an ORDER that the remedy line does not have -- it writes NOPASSWD first and
# the path second. It failed for a reason that had nothing to do with the
# property, which is the whole hazard of a glob standing in for two facts.
_has_dropin=0; _has_nopass=0
case "$_sudo_block" in *sudoers.d*) _has_dropin=1 ;; esac
case "$_sudo_block" in *NOPASSWD*)  _has_nopass=1 ;; esac
if [ "$_has_dropin" -eq 1 ] && [ "$_has_nopass" -eq 1 ]; then
    ok "the warning carries an actionable remedy (a scoped sudoers drop-in with NOPASSWD)"
else
    bad "the remedy is incomplete: sudoers.d=${_has_dropin} NOPASSWD=${_has_nopass}. An operator who cannot act on a warning is being told off, not helped."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
