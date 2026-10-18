#!/usr/bin/env bash
# A CREDENTIAL THAT IS KEPT IN PLAIN TEXT MUST SAY SO WHERE IT IS TYPED.
#
# install.sh writes the collected email password into
# ${OSTLER_DIR}/assistant-config/config.toml in cleartext and nothing ever
# encrypts it (#1976). That fact WAS disclosed -- honestly and in full -- but
# only in the preamble written inside config.toml itself, a file the customer
# has no reason to open. At the moment they actually type the password, the
# prompt said only:
#
#     "Stored locally under ~/.ostler/ ... never sent to Creative Machines."
#
# Every word of that is true, and it reads as reassurance. The omission runs
# in the flattering direction: "stored locally" is what a customer hears as
# "kept safely". Consent to hand over a credential is given at the prompt, so
# that is where the material fact has to be, not in a file downstream.
#
# This is the half-wired failure mode "built but unreachable": the honest
# sentence existed in the tree the whole time and never reached a person.
#
# The arms below check the string a CUSTOMER RENDERS, not the literal in the
# file, because a string can be present and still expand to nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }

SRC=install.sh
STR=install.sh.strings.en-GB.sh

printf '\n=== A STORED SECRET SAYS SO WHERE IT IS TYPED ===\n\n'

# ---------------------------------------------------------------------------
# ARM 1: the PREMISE. The disclosure is only correct while the password really
# is written in cleartext. If that ever changes, this guard must be revisited
# rather than quietly keeping a now-false warning on screen.
# ---------------------------------------------------------------------------
n_clear=$(grep -c 'echo "password = \\"\$(_esc "\$CHANNEL_EMAIL_PASSWORD")\\""' "$SRC" || true)
if [ "$n_clear" -eq 1 ]; then
    ok "premise holds: the email password is still written to config.toml in cleartext"
else
    bad "the cleartext write site moved or changed (found ${n_clear}, expected 1)" \
        "If encryption has landed, the prompt text below must be corrected, not kept."
fi

# ---------------------------------------------------------------------------
# ARM 2: what the customer ACTUALLY RENDERS at the prompt. Source the strings
# file the way install.sh does and read the expanded value, so a variable that
# is present but expands to nothing cannot pass.
# ---------------------------------------------------------------------------
help_text="$(bash -c "set -u; source ./${STR} >/dev/null 2>&1; printf '%s' \"\$MSG_PROMPT_EMAIL_PASSWORD_HELP\"" 2>/dev/null || true)"

if [ -n "$help_text" ]; then
    ok "the prompt help resolves under set -u to a non-empty string ($(printf '%s' "$help_text" | wc -c | tr -d ' ') chars)"
else
    bad "MSG_PROMPT_EMAIL_PASSWORD_HELP renders empty; the customer is told nothing at all"
fi

# The two material facts, checked on the RENDERED text.
if [ "$(printf '%s' "$help_text" | grep -ci 'plain text')" -gt 0 ]; then
    ok "the rendered prompt says the password is kept in PLAIN TEXT"
else
    bad "the prompt does not tell the customer the password is stored in plain text" "$help_text"
fi

if [ "$(printf '%s' "$help_text" | grep -ci 'nothing encrypts it')" -gt 0 ]; then
    ok "and that NOTHING ENCRYPTS IT LATER, which is the part a reader assumes otherwise"
else
    bad "the prompt does not say that nothing encrypts it later" "$help_text"
fi

# ---------------------------------------------------------------------------
# ARM 3: MUST-FAIL. Strip the disclosure back to the old wording and prove the
# arms above go red. Without this they would pass on any string at all.
# ---------------------------------------------------------------------------
old_wording="Password for your self-hosted IMAP/SMTP server. Stored locally under ~/.ostler/, never sent to Creative Machines."
if [ "$(printf '%s' "$old_wording" | grep -ci 'plain text')" -eq 0 ] \
   && [ "$(printf '%s' "$old_wording" | grep -ci 'nothing encrypts it')" -eq 0 ]; then
    ok "MUST-FAIL: the previous wording is rejected by both checks, so they discriminate"
else
    bad "the predicate accepts the very wording this change replaced; it proves nothing"
fi

# ---------------------------------------------------------------------------
# ARM 4: CONTROL ON THE SCOPE, and it is a control of the SAME SHAPE. The
# Disney export password is collected by the same `gui_read ... secret` call
# and is NOT persisted: it is exported for the import and unset afterwards.
# It must therefore NOT be required to carry a storage disclosure, or the rule
# would be "every secret prompt must claim to be stored", which is false and
# would itself mislead.
# ---------------------------------------------------------------------------
disney_unset=$(grep -c 'unset _DISNEY_XLSX_PASSWORD DISNEY_XLSX_PASSWORD' "$SRC" || true)
disney_write=$(grep -c 'password = \\"\$(_esc "\$_DISNEY_XLSX_PASSWORD")' "$SRC" || true)
if [ "$disney_unset" -ge 1 ] && [ "$disney_write" -eq 0 ]; then
    ok "CONTROL: the Disney export password is transient (unset after use, never written), so it is correctly out of scope"
else
    bad "the transient/persisted distinction no longer holds (unset=${disney_unset} write=${disney_write})" \
        "If that secret is now persisted, it needs the same disclosure."
fi

# ---------------------------------------------------------------------------
# ARM 5: the population this rule governs. Exactly one secret is written into
# a config file in cleartext. If a second ever appears, this guard has to grow
# an arm for it rather than silently covering one of two.
# ---------------------------------------------------------------------------
n_pw_writes=$(grep -c '^ *echo "password = ' "$SRC" || true)
if [ "$n_pw_writes" -eq 1 ]; then
    ok "population: exactly 1 cleartext password write in install.sh, and it is the one covered above"
else
    bad "found ${n_pw_writes} cleartext password writes; this guard covers only the email one" \
        "$(grep -n '^ *echo "password = ' "$SRC" || true)"
fi

# ---------------------------------------------------------------------------
# ARM 6: house style. The string ships to customers.
# ---------------------------------------------------------------------------
if [ "$(printf '%s' "$help_text" | grep -c '—')" -eq 0 ]; then
    ok "no em-dash in the customer-facing string"
else
    bad "the string contains an em-dash, which is banned in customer copy"
fi

# A literal backslash-n in a rendered string is a leak, not a line break.
if [ "$(printf '%s' "$help_text" | grep -cF '\n')" -eq 0 ]; then
    ok "no literal backslash-n leaked into the rendered string"
else
    bad "the rendered string contains a literal \\n rather than a newline" "$help_text"
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
