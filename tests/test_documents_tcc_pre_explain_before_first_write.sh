#!/usr/bin/env bash
# test_documents_tcc_pre_explain_before_first_write.sh
# =====================================================
#
# The launch-blocker this guards: during install, Ostler's bundled
# interpreter first writes under ~/Documents/Ostler, which trips the bare
# macOS Files-and-Folders consent prompt (it can read as coming from
# "python3.11"). A customer who declines an unexplained prompt silently
# loses the wiki + conversation-record writes. install.sh must PRE-EXPLAIN
# that prompt BEFORE the first write happens.
#
# This test asserts, by source order (install.sh is not runnable in a unit
# test), that:
#   1. MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT is DEFINED in the en-GB catalogue
#      and BINDS when the catalogue is sourced under `set -u` (a name that
#      does not bind would abort the customer's install, not pre-explain).
#   2. install.sh REFERENCES it.
#   3. the reference appears BEFORE the first `mkdir -p "$USER_FACING_ROOT"`
#      -- the installer's first write under ~/Documents/Ostler, and so the
#      first thing that can trip the prompt.
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
bound="$(/bin/bash -c 'set -u; source "$1" >/dev/null 2>&1; eval "printf %s \"\${$2-}\""' _ "${CATALOGUE}" "${MSG}")"
if [ -n "${bound}" ]; then
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

# ---- 3. reference is BEFORE the first Documents write --------------------
# The first write under ~/Documents/Ostler is `mkdir -p "$USER_FACING_ROOT"`.
write_line="$("${GREP}" -nF 'mkdir -p "$USER_FACING_ROOT"' "${INSTALL_SH}" | head -1 | cut -d: -f1)"
if [ -z "${write_line}" ]; then
    cannot_run 'could not locate the first `mkdir -p "$USER_FACING_ROOT"` in install.sh; the anchor this test orders against has moved'
fi
ok "first Documents write (mkdir -p \$USER_FACING_ROOT) is at line ${write_line}"

if [ -n "${ref_line}" ]; then
    if [ "${ref_line}" -lt "${write_line}" ]; then
        ok "pre-explanation (line ${ref_line}) is emitted BEFORE the first Documents write (line ${write_line})"
    else
        red "pre-explanation (line ${ref_line}) is at or AFTER the first Documents write (line ${write_line}); the macOS prompt would appear unexplained"
    fi
fi

if [ "${fail}" -ne 0 ]; then
    echo "" >&2
    echo "RED: the Documents pre-explanation is missing or out of order." >&2
    exit 1
fi

echo ""
echo "ALL DOCUMENTS PRE-EXPLAIN ORDERING ASSERTIONS PASSED"
exit 0
