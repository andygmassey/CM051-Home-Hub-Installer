#!/usr/bin/env bash
# Founder ruling 2026-11-12: ingest ALL history by default; the installer does
# not ask "extend mail history?". Asserts (1) no gui_read with key
# mail_extend_history and no MSG_PROMPT_MAIL_EXTEND_HISTORY_* anywhere,
# (2) the EFFECTIVE defaults for mail, Safari and browser are all-history
# (18250), evaluated from install.sh's own default lines, not grepped prose.
# Settling/counting rules for Safari and browser follow later.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$HERE/install.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"

# 1. prompt gone (comment lines excluded)
if grep -vE '^[[:space:]]*#' "$INSTALL_SH" | grep -q 'mail_extend_history'; then
    fail "install.sh still has a mail_extend_history gui_read"
fi
echo "PASS: no mail_extend_history prompt in install.sh"
leftover="$(grep -lE 'MSG_PROMPT_MAIL_EXTEND_HISTORY' "$HERE"/install.sh "$HERE"/install.sh.strings.*.sh "$HERE"/l10n/provenance.json 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "MSG_PROMPT_MAIL_EXTEND_HISTORY_* still present in: $leftover"
echo "PASS: no MSG_PROMPT_MAIL_EXTEND_HISTORY_* strings left"

# 2. effective defaults: run the real default-assignment lines with the vars unset
lines="$(grep -E '^[[:space:]]*: "\$\{OSTLER_(MAIL|SAFARI|BROWSER)_BACKFILL_DAYS:=[0-9]+\}"[[:space:]]*$' "$INSTALL_SH")"
n="$(printf '%s\n' "$lines" | grep -c .)"
[[ "$n" -eq 3 ]] || fail "expected exactly 3 default-assignment lines (mail, safari, browser), found $n"
out="$(env -u OSTLER_MAIL_BACKFILL_DAYS -u OSTLER_SAFARI_BACKFILL_DAYS -u OSTLER_BROWSER_BACKFILL_DAYS \
    bash -c "$lines"$'\n''echo "$OSTLER_MAIL_BACKFILL_DAYS $OSTLER_SAFARI_BACKFILL_DAYS $OSTLER_BROWSER_BACKFILL_DAYS"')"
[[ "$out" == "18250 18250 18250" ]] || fail "effective defaults (mail safari browser) = '$out', want '18250 18250 18250'"
echo "PASS: effective defaults mail/safari/browser = $out"
# pass-through fallbacks must agree
if grep -E 'OSTLER_(SAFARI|BROWSER|MAIL)_BACKFILL_DAYS:-1825\}' "$INSTALL_SH" | grep -q .; then
    fail "a :-1825 fallback remains for mail/safari/browser"
fi
echo "PASS: no :-1825 fallback remains"
