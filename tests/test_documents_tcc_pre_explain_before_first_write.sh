#!/usr/bin/env bash
# test_documents_tcc_pre_explain_before_first_write.sh
# =====================================================
#
# The launch-blocker this guards: Ostler's bundled python3.11 writes the
# customer's wiki + conversation records under ~/Documents/Ostler, which
# trips the macOS Files-and-Folders consent prompt. A customer who declines
# an unexplained prompt silently loses those writes.
#
# macOS gates that prompt per RESPONSIBLE PROCESS. So the prompt is NOT
# covered by sitting a note next to the installer's own bash write: the
# installer's write (the mkdir) may prompt during setup, but the python3.11
# prompt comes LATER, from python3.11's own launchd jobs (the wiki organise /
# catch-up ingest), possibly the next day. The pre-explanation must therefore
# (a) be emitted during setup, before the installer's own first Documents
# write, and (b) carry copy that is HONEST about the per-process timing and
# names the later python3.11 prompt, with a System Settings remediation.
#
# This test asserts, by source order + copy content (install.sh is not
# runnable in a unit test):
#   1. MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT is DEFINED in the en-GB catalogue and
#      BINDS under `set -u` (a name that does not bind aborts the install).
#   2. install.sh REFERENCES it.
#   3. the reference is emitted BEFORE the installer's own first write under
#      ~/Documents/Ostler (`mkdir -p "$USER_FACING_ROOT"`).
#   4. the COPY matches the shipped mechanism: it names python3.11 (the
#      responsible process the customer actually sees), says the prompt may
#      come later (not an immediate-only promise), and carries the Files and
#      Folders remediation. This is the per-responsible-process correction:
#      the copy must describe the real, later python3.11 prompt, never a false
#      "in a moment" one.
#
# Three states, not two: a file that cannot be read is CANNOT-RUN (exit 2),
# never a silent pass. British English. No em dashes.
#
# Runs on /bin/bash 3.2 (the shipped shell). Uses /usr/bin/grep explicitly
# because the grep on PATH may be ugrep and answer differently.

set -u

GREP=/usr/bin/grep
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
CATALOGUE="${REPO}/install.sh.strings.en-GB.sh"
MSG="MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT"

fail=0

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  This is NOT a pass. A check that could not look has not passed." >&2
    exit 2
}

red() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "ok: $*"; }

[ -f "${INSTALL_SH}" ] || cannot_run "install.sh not found at ${INSTALL_SH}"
[ -f "${CATALOGUE}" ]  || cannot_run "catalogue not found at ${CATALOGUE}"

# ---- 1. defined AND binds under set -u -----------------------------------
if "${GREP}" -qF "${MSG}=" "${CATALOGUE}"; then
    ok "${MSG} is defined in the catalogue"
else
    red "${MSG} is not defined in ${CATALOGUE##*/} (install would abort under set -u)"
fi

# bash is the thing that actually reads the catalogue at install time; ask it,
# not a regex. An empty result means the catalogue does not survive `set -u`.
value="$(/bin/bash -c 'set -u; source "$1" >/dev/null 2>&1; eval "printf %s \"\${$2-}\""' _ "${CATALOGUE}" "${MSG}")"
if [ -n "${value}" ]; then
    ok "${MSG} binds to a non-empty value when the catalogue is sourced"
else
    red "${MSG} does not bind (empty or unbound) when ${CATALOGUE##*/} is sourced under set -u"
fi

# ---- 2. referenced in install.sh -----------------------------------------
ref_line="$("${GREP}" -nF "\$${MSG}" "${INSTALL_SH}" | head -1 | cut -d: -f1)"
if [ -n "${ref_line}" ]; then
    ok "install.sh references \$${MSG} (line ${ref_line})"
else
    red "install.sh never references \$${MSG}; the pre-explanation is dead copy"
fi

# ---- 3. reference is BEFORE the installer's own first Documents write -----
# The installer's own first write under ~/Documents/Ostler is
# `mkdir -p "$USER_FACING_ROOT"`. This is NOT the python3.11 prompt (that is a
# separate, later, per-process event, covered by the copy check below); it is
# the installer's own Documents access, which the note must still precede.
write_line="$("${GREP}" -nF 'mkdir -p "$USER_FACING_ROOT"' "${INSTALL_SH}" | head -1 | cut -d: -f1)"
if [ -z "${write_line}" ]; then
    cannot_run 'could not locate the first `mkdir -p "$USER_FACING_ROOT"` in install.sh; the anchor this test orders against has moved'
fi
ok "installer's own first Documents write (mkdir -p \$USER_FACING_ROOT) is at line ${write_line}"

if [ -n "${ref_line}" ]; then
    if [ "${ref_line}" -lt "${write_line}" ]; then
        ok "pre-explanation (line ${ref_line}) is emitted BEFORE the installer's first Documents write (line ${write_line})"
    else
        red "pre-explanation (line ${ref_line}) is at or AFTER the installer's first Documents write (line ${write_line})"
    fi
fi

# ---- 4. copy matches the per-responsible-process mechanism ---------------
# These assertions are the correction: a prior copy said "In a moment macOS
# will ask", which is false for exactly the python3.11 prompt we are
# explaining (it comes later, from python3.11's own launchd jobs). The copy
# must name python3.11, hedge the timing (so it stays true however macOS
# schedules the prompt), and give the Files and Folders remediation.
if printf '%s' "${value}" | "${GREP}" -qF "python3.11"; then
    ok "copy names python3.11 (the responsible process the customer sees)"
else
    red "copy does not name python3.11; the customer cannot recognise the prompt"
fi

if printf '%s' "${value}" | "${GREP}" -qF "later"; then
    ok "copy acknowledges the prompt may come later (per-process timing is honest)"
else
    red "copy does not acknowledge the later timing; it promises an immediate prompt that python3.11 does not give"
fi

if printf '%s' "${value}" | "${GREP}" -qF "Files and Folders"; then
    ok "copy carries the System Settings > Privacy & Security > Files and Folders remediation"
else
    red "copy carries no Files and Folders remediation for a declined prompt"
fi

if printf '%s' "${value}" | "${GREP}" -qiF "in a moment"; then
    red "copy still claims the prompt appears 'in a moment'; that is false for the later python3.11 prompt"
else
    ok "copy makes no false 'in a moment' immediate-prompt claim"
fi

if [ "${fail}" -ne 0 ]; then
    echo "" >&2
    echo "RED: the Documents pre-explanation is missing, out of order, or does not match the shipped per-process mechanism." >&2
    exit 1
fi

echo ""
echo "ALL DOCUMENTS PRE-EXPLAIN ORDERING + COPY ASSERTIONS PASSED"
exit 0
