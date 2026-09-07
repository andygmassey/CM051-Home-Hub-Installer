#!/usr/bin/env bash
# An unrecorded consent decision must not read as a refusal in silence.
#
# WHY. MEASURED on the Mini 16, 2026-09-04, on a finished v1.0.63 install where
# the customer chose "use previous answers":
#
#     PROMPT markers in the whole run   imessage_automation_incoming_ack,
#                                       reuse_settings, tailscale_confirm
#     "consent_third_party" occurrences 0        <- never asked
#     consent registry, show --tickbox  null     <- nothing recorded
#     CONSENT keys in config/.env       0 of 19  (CONTROL: ^USER_ID= is 1)
#     conversation feeds installed      1 of 4
#
# The loop is self-perpetuating: reuse sets SKIP_PHASE2, so the consent
# questions never execute, so the variable stays empty, so the recorder -- which
# is guarded on the variable being NON-EMPTY -- writes nothing, so the NEXT
# reuse has nothing to restore. Meanwhile three feeds gated on `== accepted`
# never install and the customer is told nothing.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no strings file" >&2; exit 2; }

# Drive the REAL function, extracted from the real file. A reimplementation
# here would test this test, which is the fixture-encodes-the-fix trap.
_fn="$(awk '/^_ostler_consent_state\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "$SUBJECT")"
[ -n "$_fn" ] || { echo "CANNOT-RUN: could not extract _ostler_consent_state from install.sh" >&2; exit 2; }
eval "$_fn"

# ── In-memory answers are honoured verbatim ──────────────────────────────
[ "$(_ostler_consent_state third_party_data_personal_records accepted)" = "accepted" ] \
    && ok "an in-memory 'accepted' is reported as accepted" \
    || bad "an in-memory 'accepted' was not honoured"
[ "$(_ostler_consent_state third_party_data_personal_records declined)" = "declined" ] \
    && ok "an in-memory 'declined' is reported as declined" \
    || bad "an in-memory 'declined' was not honoured"

# ── THE DEFECT ITSELF: empty must be unknown, NEVER declined ─────────────
# OSTLER_PYTHON unset, so the registry cannot be consulted: exactly the state a
# reuse run is in before anything has ever been recorded.
OSTLER_PYTHON=""
got="$(_ostler_consent_state third_party_data_personal_records "")"
if [ "$got" = "unknown" ]; then
    ok "an EMPTY decision with no registry reports 'unknown', not 'declined'"
elif [ "$got" = "declined" ]; then
    bad "an empty decision reported 'declined' -- that is the defect: never-asked is being read as a refusal"
else
    bad "an empty decision reported '$got'"
fi

# ── CONTROL, AND IT IS THE ONE THAT MATTERS ──────────────────────────────
# unknown must NEVER be upgraded to accepted. A restore that guesses "yes"
# would pass a naive test and be far worse than the bug: it would turn on a
# privacy-gated feature the customer never agreed to.
if [ "$(_ostler_consent_state third_party_data_personal_records "")" != "accepted" ]; then
    ok "CONTROL: unknown is never upgraded to accepted"
else
    bad "CONTROL FAILED: an unrecorded decision became 'accepted'. That is worse than the defect."
fi

# ── A refusal from the registry must still not become 'declined' ─────────
# `check` exits non-zero for declined AND for absent alike, so it cannot tell
# them apart. Reporting 'declined' off a non-zero would invent a refusal.
OSTLER_PYTHON="/usr/bin/false"
got="$(_ostler_consent_state third_party_data_personal_records "")"
[ "$got" = "unknown" ] \
    && ok "a non-zero registry check reports 'unknown', because it cannot distinguish declined from absent" \
    || bad "a non-zero registry check reported '$got'"

# ── The guards must consult the resolver, not the raw variable ───────────
n_raw="$(grep -c 'OSTLER_CONSENT_THIRD_PARTY_DECISION" == "accepted"' "$SUBJECT")"
if [ "$n_raw" -eq 0 ]; then
    ok "no guard still tests the raw variable for == accepted"
else
    bad "${n_raw} guard(s) still read the raw variable, so they cannot see 'unknown'"
fi

# ── The customer is actually told ────────────────────────────────────────
for k in MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY; do
    grep -q "^${k}=" "$STRINGS" \
        && ok "string ${k} is declared in the catalogue" \
        || bad "string ${k} is used by install.sh and MISSING from the catalogue"
done
n_warn="$(grep -c '_ostler_warn_consent_unknown ' "$SUBJECT")"
[ "$n_warn" -ge 2 ] \
    && ok "the unknown state is announced at ${n_warn} site(s), not swallowed" \
    || bad "only ${n_warn} announcement site(s); an unknown that is not said out loud is the original defect"

# ── The step-count and the guard must read ONE value ─────────────────────
# MEASURED on my own first fix: the TOTAL_STEPS decrement still read the RAW
# variable while the guard read the resolver. On a reuse run where the resolver
# restores `accepted` from the registry, the step RUNS while its slot has
# already been subtracted -- the denominator shrinking mid-run, which is
# v1061-D005 filed against this installer. A gated step must decide once.
# ORDER-INDEPENDENT ON PURPOSE. The first version of this line required
# TOTAL_STEPS to appear BEFORE the variable, and the real code writes
# `[[ ... $VAR ... ]] && TOTAL_STEPS=...` -- variable first. So the mutation
# that reinstated the defect walked straight past it. Match the LINE, not an
# assumed word order.
n_raw_steps="$(grep -cE 'TOTAL_STEPS' "$SUBJECT" | head -1 >/dev/null; grep -E 'TOTAL_STEPS' "$SUBJECT" | grep -cE 'OSTLER_CONSENT_THIRD_PARTY_DECISION')"
if [ "$n_raw_steps" -eq 0 ]; then
    ok "no TOTAL_STEPS decrement reads the raw consent variable"
else
    bad "${n_raw_steps} step-count line(s) read the RAW variable while the guard reads the resolver -- the denominator and the behaviour can disagree"
fi

# Every gated feed must resolve BEFORE it decrements, or the two can diverge.
for feed in TP_EMAIL TP_IMSG; do
    res_at="$(grep -n "_OSTLER_CONSENT_${feed}=" "$SUBJECT" | head -1 | cut -d: -f1)"
    dec_at="$(grep -n "_OSTLER_CONSENT_${feed}\" != \"accepted\"" "$SUBJECT" | head -1 | cut -d: -f1)"
    if [ -n "$res_at" ] && [ -n "$dec_at" ] && [ "$res_at" -lt "$dec_at" ]; then
        ok "${feed}: resolved (line ${res_at}) BEFORE its step-count decrement (line ${dec_at})"
    else
        bad "${feed}: resolve/decrement ordering is wrong or unfindable (resolve=${res_at:-none} decrement=${dec_at:-none})"
    fi
done

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
