#!/usr/bin/env bash
# The wiki password is never written to install.log.
# ============================================================================
#
# THE DEFECT, measured on a walk box 2026-09-24: ~/.ostler/logs/install.log held
# the wiki password in cleartext, once, in the final summary line
# MSG_INFO_WIKI_SIGN_IN. install.sh tees ALL of stdout into install.log
# (`exec > >(tee -a "${INSTALL_LOG}")` near the top), so any line that prints
# the password to stdout lands in a log file that support bundles and Doctor
# read.
#
# WHAT THIS PROVES, two ways:
#   A. STRUCTURE: every non-comment install.sh line that expands WIKI_PASSWORD
#      is one of the known SAFE uses: the seed call, the htpasswd hash, the
#      curl credential, the pbcopy pipe, or a print sent to fd 9 (the ORIGINAL
#      stderr, saved before the tee, so never logged). Anything else fails.
#   B. EXECUTION: the final-summary block is run with a synthetic password,
#      stdout teed into a fake install.log exactly as install.sh does, and the
#      password must be ABSENT from that log while the withheld line is
#      PRESENT (so an empty log cannot pass).
#
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${1:-${REPO_ROOT}/install.sh}"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
cannot_run() { echo "CANNOT-RUN: $1" >&2; exit 2; }
[[ -f "$INSTALL_SH" ]] || cannot_run "no install.sh at $INSTALL_SH"
[[ -f "$STRINGS" ]] || cannot_run "no strings file at $STRINGS"

echo "A. every expansion of WIKI_PASSWORD is a known safe use"
USES="$(grep -n 'WIKI_PASSWORD' "$INSTALL_SH" | grep -v -E '^[0-9]+:[[:space:]]*#')"
N="$(printf '%s\n' "$USES" | grep -c .)"
[[ "$N" -ge 4 ]] || cannot_run "found only $N uses of WIKI_PASSWORD; this test no longer knows the file"
UNSAFE="$(printf '%s\n' "$USES" | grep -v -E \
    -e '_seed_wiki_password WIKI_PASSWORD$' \
    -e 'openssl passwd -apr1 "\$\{WIKI_PASSWORD\}"' \
    -e '-u "ostler:\$\{WIKI_PASSWORD\}"' \
    -e "printf '%s' \"\\$\\{WIKI_PASSWORD\\}\" \\| pbcopy" \
    -e '>&9$' \
    -e 'MSG_INFO_WIKI_PASSWORD_ON_DISK' || true)"
if [[ -z "$UNSAFE" ]]; then
    ok "all $N expansions are safe uses"
else
    bad "a line prints WIKI_PASSWORD somewhere stdout (and so install.log) can see it: $(printf '%s' "$UNSAFE" | cut -d: -f1 | tr '\n' ' ')"
fi

echo "B. the final summary, executed with its stdout teed like install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The summary lines from the sign-in comment to the on-disk line.
awk '
    /THE PASSWORD ITSELF NEVER GOES TO STDOUT/ { f = 1 }
    /MSG_INFO_WIKI_SIGN_IN" "ostler" "\$\{WIKI_PASSWORD\}"\)"$/ && !f { f = 1 }
    f { print }
    f && /MSG_INFO_WIKI_SIGN_IN/ && /WIKI_PASSWORD/ { n++ }
    f && n && /^fi$/ { exit }
    f && n && /MSG_INFO_WIKI_SIGN_IN" "ostler" "\$\{WIKI_PASSWORD\}"\)"$/ { exit }
' "$INSTALL_SH" > "${WORK}/block.sh"
grep -q 'WIKI_PASSWORD' "${WORK}/block.sh" || cannot_run "could not extract the sign-in block from install.sh"
SYN="synthetic-wiki-pw-4f2e"
LOG="${WORK}/install.log"
(
    set +u
    . "$STRINGS"
    BOLD=""; NC=""; WIKI_PASSWORD="$SYN"; OSTLER_GUI=0
    exec 9>"${WORK}/fd9.out"
    exec > >(tee -a "$LOG") 2>&1
    . "${WORK}/block.sh"
)
sleep 1
if grep -q "$SYN" "$LOG"; then
    bad "the password reached the teed install.log"
else
    ok "the password is absent from the teed install.log"
fi
if grep -q "ostler" "$LOG"; then
    ok "control: the sign-in line itself IS in the log, so the log was written"
else
    bad "control: nothing reached the log, so the absence above proves nothing"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[[ $FAIL -eq 0 ]]
