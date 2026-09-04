#!/usr/bin/env bash
# Every question the installer asks must declare what happens to its answer.
#
# WHY THIS EXISTS, AND WHY IT IS A RATCHET RATHER THAN A NOTE.
#
# `reuse_settings` sets SKIP_PHASE2=true, which skips the ENTIRE question
# phase and restores answers by `set -a; source config/.env`. So any answer
# that is not written to a durable artefact silently reverts to its default on
# every re-run -- and for a consent-gated feature, the default reads as "no".
#
# THIS CLASS HAS BEEN FOUND THREE TIMES, ONE INSTANCE AT A TIME, OVER MONTHS:
#
#   paired_tokens   regenerated from scratch; fixed with a fill-only restore
#   channels        #619, same file, same truncating redirect. install.sh's own
#                   comment: "config/.env carries 21 keys and NONE of them are
#                   CHANNEL_*"
#   consent         2026-09-04. MEASURED on a finished install where the
#                   customer chose reuse: 0 consent keys in .env (of 19),
#                   consent registry `show` -> null, 3 of 4 conversation feeds
#                   never installed, and the customer told nothing.
#
# Each was found by someone tripping over it. NOBODY EVER ENUMERATED THE SET.
# This test does, and refuses anything new that is not classified -- so the
# FOURTH occurrence is caught when it is written, not months later on a box.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

# ── THE DECLARED CLASSIFICATION ──────────────────────────────────────────
# Every variable the question phase sets must appear in exactly one bucket.
#
#   PERSISTED  its answer survives a reuse run, under this name or another
#   TRANSIENT  a confirmation or a control-flow answer; nothing to carry
#   SECRET     must NEVER be written to a plaintext artefact
#   GAP        a real decision with NO durable home. MEASURED, not assumed.
#              This list may only SHRINK. Adding to it needs a reason in the
#              commit message; a new question defaulting into it is a bug.
PERSISTED="USER_ID USER_NAME ASSISTANT_NAME USER_TZ COUNTRY_CODE
           CHANNEL_CHOICE CHANNEL_IMESSAGE_ALLOWED CHANNEL_WHATSAPP_RECIPIENT
           CHANNEL_EMAIL_APPLE_MAIL_INPUT CHANNEL_EMAIL_CUSTOM_IMAP_INPUT
           CHANNEL_EMAIL_IMAP_HOST CHANNEL_EMAIL_SMTP_HOST CHANNEL_EMAIL_USERNAME"
TRANSIENT="REUSE TZ_CONFIRM CC_CONFIRM RP_CONFIRM PERMS_OK ACK_PASSKEY
           IMPORT_CONFIRM TAKEOUT_CONFIRM FV_CONTINUE MANUAL_PATH CONSENT"
SECRET="RECOVERY_PASSPHRASE CHANNEL_EMAIL_PASSWORD"
#
# ⚠️ CONSENT WAS IN THIS LIST AND WAS WRONG. I put it here on the strength of
# its NAME. Read: it resolves to INSTALL or CANCEL at install.sh:10102 and does
# nothing else -- `break` or `exit 0` -- and it is read nowhere but its own
# normalisation two lines above. It is a type-INSTALL-to-proceed gate, so
# nothing about it needs to survive a re-run. Moved to TRANSIENT and the
# ceiling dropped 10 -> 9, which is the direction this ratchet may move.
#
# The five that DO carry consent all feed an OSTLER_CONSENT_*_DECISION
# variable, and the recorder is guarded on that variable being non-empty. So on
# a reuse run NONE of the five is recorded -- which is exactly what the box
# showed: `ostler-consent show` returned null for every tickbox asked.
GAP="THIRD_PARTY ART9 WA_CONSENT SPOKEN_CAPTURE VOICE ENRICH_CHOICE
     PRESET SAVE_KEYCHAIN TAILSCALE_CONFIRM"

_declared() {
    local v="$1" b
    for b in $PERSISTED $TRANSIENT $SECRET $GAP; do
        [ "$b" = "$v" ] && return 0
    done
    return 1
}

# ── Enumerate what the file ACTUALLY asks ────────────────────────────────
# Read from install.sh, never from a copied list: a hand-maintained roster
# drifts and the gate goes on checking the old set while reporting success.
# 🔴 NO `mapfile`. macos-14's /bin/bash is 3.2 and mapfile is a bash-4 builtin,
# so the first version of this test died with "mapfile: command not found" and
# then three "QVARS: unbound variable" errors -- on CI, having measured nothing.
# It passed locally because this machine's bash is 5.x from Homebrew. The
# installer ships for the shell the CUSTOMER has, and this gate must run on the
# shell CI has; a newline-delimited string plus a read loop works on both.
#
# Not `for v in $QVARS` either: that relies on word splitting, which zsh does
# not do for an unquoted variable, so the same list would silently become ONE
# element under a different shell.
QVARS_RAW="$(grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*="\$\(gui_read' "$SUBJECT" \
             | grep -oE '[A-Z_][A-Z0-9_]*' | sort -u | grep -vE '^_$')"
QVAR_COUNT="$(printf '%s\n' "$QVARS_RAW" | grep -c .)"

if [ "${QVAR_COUNT:-0}" -lt 20 ]; then
    echo "CANNOT-RUN: only ${QVAR_COUNT:-0} question variables found; the gui_read" >&2
    echo "  assignment shape has probably changed. A shrunken denominator must" >&2
    echo "  not read as a clean tree." >&2
    exit 2
fi
ok "enumerated ${QVAR_COUNT} question variable(s) from install.sh itself"

undeclared=""
while IFS= read -r v; do
    [ -n "$v" ] || continue
    _declared "$v" || undeclared="${undeclared}${undeclared:+ }${v}"
done <<EOF_QVARS
${QVARS_RAW}
EOF_QVARS
if [ -z "$undeclared" ]; then
    ok "every question variable is classified (persisted / transient / secret / gap)"
else
    bad "UNDECLARED question variable(s): ${undeclared}"
    bad "  A new question must say what happens to its answer. If it is not"
    bad "  persisted, a reuse run silently reverts it to its default -- which"
    bad "  for a consent gate reads as a refusal. Classify it, and if it is a"
    bad "  GAP, say why in the commit message."
fi

# ── The ratchet: the GAP list may only shrink ────────────────────────────
gap_n=0; for v in $GAP; do gap_n=$((gap_n+1)); done
CEILING=9
if [ "$gap_n" -le "$CEILING" ]; then
    ok "unpersisted-decision backlog is ${gap_n} (ceiling ${CEILING}, may only DECREASE)"
else
    bad "the GAP list grew to ${gap_n} against a ceiling of ${CEILING}. Do not raise it."
fi

# ── CONTROL: a variable in NO bucket must be caught ──────────────────────
# Proves the predicate can fail. Without this the check above passes whenever
# the buckets happen to be supersets, and would keep passing if enumeration
# silently returned nothing.
if _declared ZZQ_NEVER_A_REAL_QUESTION_VARIABLE; then
    bad "CONTROL: a fabricated name was reported as declared -- the buckets match too loosely"
else
    ok "CONTROL: a fabricated variable name is correctly reported as undeclared"
fi

# ── CONTROL: every declared name must still be a real question ───────────
# A bucket entry for a question that no longer exists is dead weight that
# makes the ceiling look tighter than it is.
stale=""
for v in $GAP; do
    printf '%s\n' "$QVARS_RAW" | grep -qx "$v" || stale="${stale}${stale:+ }${v}"
done
if [ -z "$stale" ]; then
    ok "every GAP entry is still a question install.sh actually asks"
else
    bad "GAP lists variable(s) install.sh no longer asks: ${stale}. Remove them; a stale entry flatters the ceiling."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
