#!/usr/bin/env bash
#
# tests/test_email_allowlist_installer.sh  (v1.0.107 #10)
#
# The installer must ASK who may email the assistant, pre-fill the owner's own
# address, require at least one full address, and write the answer to
# [channels.email] allowed_senders. It used to write the literal
# `allowed_senders = []`, which the daemon reads as "answer no one", so the
# custom-IMAP email channel shipped inert.
#
# Also pinned: the config that holds the mailbox password is written under
# umask 0077 and chmod 600, and the password is never printed anywhere but into
# that file.
#
# Every structural assertion is run twice: on install.sh (must pass) and on a
# mutant with the old behaviour restored (must FAIL), so the check is known to
# be able to go red. Exit 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: install.sh not found"; exit 2; }
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok:   $*"; }

# ---- 1. behaviour of the helper block, extracted from install.sh -----------
helpers="$(mktemp)"; trap 'rm -f "$helpers" "${mut:-}"' EXIT
sed -n '/^# BEGIN email-allowlist-helpers/,/^# END email-allowlist-helpers/p' "$INSTALL_SH" > "$helpers"
n="$(wc -l < "$helpers" | tr -d ' ')"
[ "$n" -gt 20 ] || { echo "CANNOT-RUN: helper block not found in install.sh ($n lines)"; exit 2; }
echo "examined: helper block, $n lines"
# shellcheck disable=SC1090
. "$helpers"

check_norm() { # <label> <input> <want_ok_list> <want_bad_list> <want_rc>
    local rc
    _email_allowlist_normalise "$2"; rc=$?
    if [ "$_EMAIL_ALLOWED_OK" = "$3" ] && [ "$_EMAIL_ALLOWED_BAD" = "$4" ] && [ "$rc" = "$5" ]; then
        pass "$1"
    else
        fail "$1: ok='$_EMAIL_ALLOWED_OK' bad='$_EMAIL_ALLOWED_BAD' rc=$rc (want ok='$3' bad='$4' rc=$5)"
    fi
}
check_norm "one address kept, lower-cased"       "Owner@Example.TEST"                     "owner@example.test" "" 0
check_norm "comma, semicolon, space separated"   "a@example.test; b@example.test c@example.test" "a@example.test,b@example.test,c@example.test" "" 0
check_norm "duplicates collapse"                 "a@example.test, A@example.test"         "a@example.test" "" 0
check_norm "empty answer is refused"             ""                                       "" "" 1
check_norm "whitespace-only answer is refused"   "  ,  "                                   "" "" 1
check_norm "wildcard is refused"                 "*"                                      "" "*" 1
check_norm "domain entries are refused"          "@example.test, example.test"            "" "@example.test,example.test" 1
check_norm "bad entry dropped, good one kept"    "nonsense, me@example.test"              "me@example.test" "nonsense" 0
check_norm "quote injection is refused"          'a"@example.test'                        "" 'a"@example.test' 1

toml="$(_email_allowlist_toml_items "a@example.test,b@example.test")"
[ "$toml" = '"a@example.test", "b@example.test"' ] && pass "toml items" || fail "toml items: $toml"
[ -z "$(_email_allowlist_toml_items "")" ] && pass "empty list renders nothing (written as [], deny-all)" || fail "empty list rendered something"

cfg="$(mktemp)"
printf '[channels.imessage]\nenabled = true\n\n[channels.email]\nenabled = true\nusername = "u@example.test"\nallowed_senders = ["o@example.test"]\n\n[autonomy]\nx = 1\n' > "$cfg"
blk="$(_ostler_existing_email_block "$cfg")"
case "$blk" in
    *'allowed_senders = ["o@example.test"]'*) pass "existing email block lifted for a reuse re-run" ;;
    *) fail "existing block not lifted: $blk" ;;
esac
case "$blk" in *autonomy*|*imessage*) fail "block lifted too much: $blk" ;; *) pass "block stops at the next section" ;; esac
rm -f "$cfg"

# ---- 2. structural assertions, run on install.sh and on a mutant -----------
structural() { # <file> -> prints failures, returns count
    local f="$1" bad=0
    if grep -Fq 'echo "allowed_senders = []"' "$f"; then echo "  hardcoded allowed_senders = [] is back"; bad=$((bad + 1)); fi
    grep -Fq '"email_allowed_senders"' "$f" || { echo "  no email_allowed_senders prompt"; bad=$((bad + 1)); }
    grep -Fq '${USER_EMAIL:-}' "$f" && grep -F 'email_allowed_senders' "$f" | grep -Fq 'USER_EMAIL' \
        || { echo "  prompt is not pre-filled from USER_EMAIL"; bad=$((bad + 1)); }
    grep -Fq 'allowed_senders = [$(_email_allowlist_toml_items "$CHANNEL_EMAIL_ALLOWED_SENDERS")]' "$f" \
        || { echo "  writer does not emit the customer's answer"; bad=$((bad + 1)); }
    grep -Fq 'MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS' "$f" \
        || { echo "  no at-least-one-address refusal"; bad=$((bad + 1)); }
    # umask 0077 before the config redirect, chmod 600 right after it
    local u r c
    u="$(grep -n '^umask 0077$' "$f" | tail -1 | cut -d: -f1)"
    r="$(grep -n '^} > "\$ASSISTANT_CONFIG"$' "$f" | tail -1 | cut -d: -f1)"
    c="$(grep -n '^chmod 600 "\$ASSISTANT_CONFIG"$' "$f" | tail -1 | cut -d: -f1)"
    if [ -z "$u" ] || [ -z "$r" ] || [ -z "$c" ] || [ "$u" -ge "$r" ] || [ "$c" -le "$r" ] || [ $((c - r)) -gt 2 ]; then
        echo "  config not written under umask 0077 then chmod 600 (umask=$u redirect=$r chmod=$c)"; bad=$((bad + 1))
    fi
    # the password may be assigned, compared, written to the TOML and unset; never printed or logged
    local leaks
    leaks="$(grep -n 'CHANNEL_EMAIL_PASSWORD' "$f" | grep -v '^[0-9]*:[[:space:]]*#' \
        | grep -Ev 'CHANNEL_EMAIL_PASSWORD=|== "\$_email_confirm_input"|echo "password = |unset CHANNEL_EMAIL_PASSWORD' || true)"
    if [ -n "$leaks" ]; then echo "  password referenced where it may be printed: $leaks"; bad=$((bad + 1)); fi
    # no command-substitution or log call may carry the password
    if grep -nE '(dbg|info|warn|ok|log|printf|echo)[^|]*CHANNEL_EMAIL_PASSWORD' "$f" | grep -v 'echo "password = ' | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
        echo "  a log/print line carries CHANNEL_EMAIL_PASSWORD"; bad=$((bad + 1))
    fi
    return "$bad"
}
out="$(structural "$INSTALL_SH")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "install.sh passes every structural assertion"; else fail "install.sh structure ($rc):"; printf '%s\n' "$out"; fi

mut="$(mktemp)"
# mutant 1: the old hardcode comes back
sed 's|echo "allowed_senders = \[\$(_email_allowlist_toml_items "\$CHANNEL_EMAIL_ALLOWED_SENDERS")\]"|echo "allowed_senders = []"|' "$INSTALL_SH" > "$mut"
if cmp -s "$mut" "$INSTALL_SH"; then fail "control: mutant 1 did not apply"; else
    if structural "$mut" >/dev/null; then fail "control: structural let the hardcoded [] through"; else pass "control: hardcoded [] is caught"; fi
fi
# mutant 2: the password is logged
sed 's|^unset CHANNEL_EMAIL_PASSWORD _EMAIL_BLOCK_PRESERVED$|dbg "pw=$CHANNEL_EMAIL_PASSWORD"; unset CHANNEL_EMAIL_PASSWORD|' "$INSTALL_SH" > "$mut"
if cmp -s "$mut" "$INSTALL_SH"; then fail "control: mutant 2 did not apply"; else
    if structural "$mut" >/dev/null; then fail "control: structural let a password log through"; else pass "control: a password log line is caught"; fi
fi
# mutant 3: the chmod goes missing
grep -v '^chmod 600 "\$ASSISTANT_CONFIG"$' "$INSTALL_SH" > "$mut"
if structural "$mut" >/dev/null; then fail "control: structural let a missing chmod through"; else pass "control: a missing chmod 600 is caught"; fi

echo "failures: $fails"
[ "$fails" -eq 0 ]
