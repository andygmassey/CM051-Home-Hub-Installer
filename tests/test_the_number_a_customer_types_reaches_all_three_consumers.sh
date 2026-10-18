#!/usr/bin/env bash
# THE NUMBER THE CUSTOMER TYPES MUST REACH ALL THREE PLACES USABLE.
#
# THE DEFECT, measured 2026-09-16 on origin/main.
#
#   install.sh:14352 said, in a comment, "E.164 validation rejects them
#   already". There was no E.164 validation. `E.164` had FOUR matches in
#   install.sh and every one was a comment. CONTROL, same file, same command
#   shape: `CHANNEL_WHATSAPP_RECIPIENT` resolved 16 times. The search worked;
#   the validator did not exist. The only check was the leading `+`.
#
#   install.sh.strings.en-GB.sh:1023 showed the customer "+44 7700 900123" --
#   WITH SPACES -- in the same sentence as "no spaces", and the terminal
#   prompt printed the same example under the words "digits only".
#
#   A customer who copied the shape they were shown got a value with spaces,
#   and it went to three consumers:
#
#     pair_phone       digit-filtered on the way out, so pairing WORKED
#     allowed_numbers  verbatim -> the inbound allowlist denied the
#                      customer's own messages to their own assistant
#     delivery.to      verbatim -> the 09:00 brief and 18:00 wrap were
#                      addressed to a malformed recipient, and
#                      best_effort = false turns that into a daily hard
#                      error in cron history rather than a message
#
#   Two of the three broken. The one that worked was the only one that
#   already stripped non-digits. The customer sees an assistant that can be
#   paired and then ignores them, and briefs that never arrive.
#
# WHY THIS TEST RENDERS THE TOML INSTEAD OF GREPPING FOR THE FIX. Board #636
# was a CM051 fix that shipped INERT because the line was present in
# install.sh but sat inside a quoted heredoc, and a source grep passes on
# exactly that defect. So the config emitter is extracted and RUN, and the
# assertions read the TOML a customer would actually get.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no strings catalogue at ${STRINGS}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- extract the config emitter, the same way the sibling suite does ---------
EMITTER="${WORK}/emitter.sh"
awk '
    /^TOMLPREAMBLE$/                         { capture = 1; next }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "$SUBJECT" > "$EMITTER"
if [ ! -s "$EMITTER" ]; then
    echo "CANNOT-RUN: could not extract the TOML emitter from ${SUBJECT}." >&2
    exit 2
fi
if ! bash -n "$EMITTER" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted emitter does not parse; the extraction is wrong." >&2
    exit 2
fi

# --- extract the normaliser, which lives OUTSIDE the emitter -----------------
NORM="${WORK}/norm.sh"
awk '
    /^_ostler_e164_normalise\(\) \{$/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) exit }
' "$SUBJECT" > "$NORM"
if ! /usr/bin/grep -q 'printf' "$NORM"; then
    echo "CANNOT-RUN: could not extract _ostler_e164_normalise from ${SUBJECT}." >&2
    echo "  Scanning nothing must not read as a passing test." >&2
    exit 2
fi
if ! bash -n "$NORM" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted normaliser does not parse." >&2
    exit 2
fi

_render() { # $1 = the value CHANNEL_WHATSAPP_RECIPIENT holds
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_RECIPIENT="$1" \
    USER_TZ="Europe/London" \
    OSTLER_DIR="${WORK}/ostler" \
    bash -c "$(cat "$EMITTER")" 2>&1
}

_norm() { # $1 = raw input; echoes the canonical form, or nothing
    local w="${WORK}/norm_run.sh"
    { cat "$NORM"; printf '_ostler_e164_normalise "$1"\n'; } > "$w"
    bash "$w" "$1" 2>/dev/null
}

printf 'THE NUMBER A CUSTOMER TYPES REACHES ALL THREE CONSUMERS\n\n'

# ── 1. THE VALIDATOR EXISTS AND DISCRIMINATES ────────────────────────────────
echo "-- 1. the normaliser accepts what E.164 allows and refuses what it does not --"
# Every number below is in a fiction / reserved range: Ofcom 07700 900xxx,
# Ofcom 020 7946 0xxx, and the ACMA 5550 xxxx drama block. No real subscriber.
#
# The two BRACKETED cases are a matched pair and neither is decoration.
# "+44 (0)20 ..." is the UK/German letterhead convention where the bracketed
# zero must be DROPPED; "+61 (2) 5550 ..." is a bracketed AREA CODE whose
# digits must be KEPT. A normaliser that strips every parenthesised group
# passes the first and destroys the second, and one that strips only brackets
# passes the second and dials a number that does not exist for the first.
#
# The Australian form is here rather than the obvious North American one for a
# mechanical reason worth stating: .github/scripts/ci-pii-shape-scan.sh matches
# PII by SHAPE, and one of its nine patterns is the +1 NANP shape. A synthetic
# +1 number in an added line is RED exactly like a real one, by design, and
# weakening the pattern to admit a fixture would be the wrong end to fix.
_acc=0; _accfail=""
for pair in \
    "+447700900123|+447700900123" \
    "+44 7700 900123|+447700900123" \
    "+44 (0)20 7946 0018|+442079460018" \
    "+44-7700-900123|+447700900123" \
    "+61 (2) 5550 1234|+61255501234" \
    "  +447700900123|+447700900123" ; do
    _in="${pair%%|*}"; _want="${pair##*|}"
    _got="$(_norm "$_in")"
    if [ "$_got" = "$_want" ]; then _acc=$((_acc+1)); else _accfail="${_accfail} [${_in} -> '${_got}', wanted ${_want}]"; fi
done
if [ "$_acc" -eq 6 ]; then
    ok "6 of 6 human-typed separator forms normalise to canonical E.164"
else
    bad "only ${_acc} of 6 accepted forms normalised:${_accfail}"
fi

_rej=0; _rejfail=""
for bad_in in "447700900123" "07700900123" "+0447700900123" "+44" "+" "" "not a number" "+44770090012345678"; do
    _got="$(_norm "$bad_in")"
    if [ -z "$_got" ]; then _rej=$((_rej+1)); else _rejfail="${_rejfail} [${bad_in} -> '${_got}']"; fi
done
if [ "$_rej" -eq 8 ]; then
    ok "8 of 8 refusals echo NOTHING, so a caller cannot store a half-cleaned value"
else
    bad "only ${_rej} of 8 rejected inputs were refused:${_rejfail}"
fi

# ANTI-VACUITY: a normaliser that refused EVERYTHING would ace the block above
# and fail the block before it. Both directions are asserted, and this states
# that in one line so a future reader does not have to notice it.
if [ "$_acc" -eq 6 ] && [ "$_rej" -eq 8 ]; then
    ok "CONTROL: it discriminates -- it does not accept everything, and does not refuse everything"
fi

# ── 2. ALL THREE CONSUMERS, FROM A RENDERED CONFIG ───────────────────────────
echo "-- 2. a number typed with spaces reaches all three consumers usable --"
SPACED="+44 7700 900123"
OUT="$(_render "$SPACED")"

# CONTROL FIRST. Without the block, every assertion below is vacuously true
# against empty output.
if ! /usr/bin/grep -q '^\[channels\.whatsapp\]$' <<< "$OUT"; then
    bad "CANNOT-CHECK: the render produced no whatsapp block; arm 2 proves nothing"
else
    ok "CONTROL: the render really produced a [channels.whatsapp] block"

    AN="$(printf '%s\n' "$OUT" | /usr/bin/sed -n 's/^allowed_numbers = \["\(.*\)"\]$/\1/p')"
    PP="$(printf '%s\n' "$OUT" | /usr/bin/sed -n 's/^pair_phone = "\(.*\)"$/\1/p')"
    # BOTH jobs, not one. The morning brief and the evening wrap each
    # carry their own delivery.to, and a fix applied to one of them is
    # half a fix. Collect every line, then require them to agree.
    TO_ALL="$(printf '%s\n' "$OUT" | /usr/bin/sed -n 's/^delivery = .*to = "\([^"]*\)".*$/\1/p')"
    TO_N="$(printf '%s\n' "$TO_ALL" | /usr/bin/grep -c . || true)"
    TO="$(printf '%s\n' "$TO_ALL" | sort -u | /usr/bin/grep -c . || true)"
    if [ "${TO_N:-0}" -eq 2 ]; then
        ok "both scheduled jobs (morning brief and evening wrap) carry a delivery address"
    else
        bad "expected 2 delivery.to lines, found ${TO_N}: a brief job is missing"
    fi
    if [ "${TO:-0}" -eq 1 ]; then
        ok "the two jobs agree on the address, so neither was fixed in isolation"
    else
        bad "the two brief jobs disagree about where to deliver: ${TO_ALL}"
    fi
    TO="$(printf '%s\n' "$TO_ALL" | head -1)"

    case "$AN" in
        "+447700900123") ok "allowed_numbers is canonical E.164, so the customer's own messages are allowed" ;;
        *)               bad "allowed_numbers is '${AN}': the inbound allowlist will deny the customer's own messages" ;;
    esac
    case "$PP" in
        "447700900123") ok "pair_phone is digits only, so the pair code still arrives" ;;
        *)              bad "pair_phone is '${PP}': wa-rs hands it to Meta verbatim and the code never arrives" ;;
    esac
    case "$TO" in
        "+447700900123") ok "delivery.to is canonical E.164, so the morning brief and evening wrap can be delivered" ;;
        "")              bad "no whatsapp brief job was emitted at all; the customer was asked for the number and gets nothing" ;;
        *)               bad "delivery.to is '${TO}': briefs go to a malformed address, daily, as a hard cron error" ;;
    esac

    # The three must not have been made equal by making them all wrong the
    # same way: pair_phone genuinely differs from the other two.
    if [ "$PP" != "$AN" ] && [ "+${PP}" = "$AN" ]; then
        ok "CONTROL: the two formats are still DIFFERENT -- E.164 with the plus, pair_phone without"
    else
        bad "CONTROL FAILED: allowed_numbers '${AN}' and pair_phone '${PP}' are not the two distinct formats"
    fi
fi

echo "-- and an already-clean number is passed through untouched --"
OUT_CLEAN="$(_render "+447700900123")"
if /usr/bin/grep -qF 'allowed_numbers = ["+447700900123"]' <<< "$OUT_CLEAN"; then
    ok "normalisation is idempotent on a value the prompt already cleaned"
else
    bad "a clean number was altered by the emitter: $(printf '%s' "$OUT_CLEAN" | /usr/bin/grep allowed_numbers)"
fi

# ── 3. THE COPY THE CUSTOMER READS NO LONGER CONTRADICTS ITSELF ──────────────
echo "-- 3. the example obeys the rule printed beside it --"
HELP="$(/usr/bin/grep -F 'MSG_PROMPT_WHATSAPP_RECIPIENT_HELP=' "$STRINGS" | /usr/bin/grep -v '^[[:space:]]*#')"
if [ -z "$HELP" ]; then
    bad "CANNOT-CHECK: MSG_PROMPT_WHATSAPP_RECIPIENT_HELP did not resolve"
else
    # Pull the example out of the string and hold it to the string's own rule.
    EG="$(printf '%s' "$HELP" | /usr/bin/sed -n 's/.*e\.g\. \(+[^.]*\)\..*/\1/p')"
    if [ -z "$EG" ]; then
        bad "CANNOT-CHECK: no 'e.g. +...' example found in the help string"
    else
        ok "the help string carries an example: ${EG}"
        # It must satisfy the very validator the installer now runs.
        if [ "$(_norm "$EG")" = "$EG" ]; then
            ok "the example the customer is shown is ALREADY canonical, so copying it works"
        else
            bad "the example '${EG}' is not canonical; a customer copying it types a value the installer rewrites"
        fi
        case "$EG" in
            *" "*) bad "the example contains a space while the same sentence says 'no spaces'" ;;
            *)     ok "the example contains no space, so it does not contradict its own sentence" ;;
        esac
    fi
fi

echo "-- and the terminal prompt shows the same shape as the GUI help --"
TERM_EG="$(/usr/bin/grep -F 'echo "  Example: +' "$SUBJECT" | /usr/bin/sed -n 's/.*Example: \(+[0-9 ]*\)".*/\1/p' | head -1)"
if [ -z "$TERM_EG" ]; then
    bad "CANNOT-CHECK: no terminal example line found"
elif [ "$(_norm "$TERM_EG")" = "$TERM_EG" ]; then
    ok "the terminal example (${TERM_EG}) is canonical too, so both surfaces teach the same thing"
else
    bad "the terminal example '${TERM_EG}' is not canonical"
fi

# ── 4. MUTATION ──────────────────────────────────────────────────────────────
echo "-- 4. MUTATION: with the emitter normalisation removed, arm 2 MUST fail --"
MUT="${WORK}/emitter_mutant.sh"
/usr/bin/sed \
  -e 's|_wa_recipient_esc="+${CHANNEL_WHATSAPP_RECIPIENT//\[^0-9\]/}"|_wa_recipient_esc="${CHANNEL_WHATSAPP_RECIPIENT}"|' \
  -e 's|_brief_to="+${CHANNEL_WHATSAPP_RECIPIENT//\[^0-9\]/}"|_brief_to="${CHANNEL_WHATSAPP_RECIPIENT}"|' \
  "$EMITTER" > "$MUT"
_applied="$(/usr/bin/grep -c '_wa_recipient_esc="${CHANNEL_WHATSAPP_RECIPIENT}"' "$MUT" || true)"
_applied2="$(/usr/bin/grep -c '_brief_to="${CHANNEL_WHATSAPP_RECIPIENT}"' "$MUT" || true)"
if [ "${_applied:-0}" -lt 1 ] || [ "${_applied2:-0}" -lt 1 ]; then
    bad "MUTATION DID NOT APPLY (allowed_numbers:${_applied} delivery.to:${_applied2}), so the arm below proves nothing"
else
    ok "the mutant really emits the raw value at both sites (the injection landed)"
    OUT_MUT="$(
        CHANNEL_IMESSAGE_ENABLED=false CHANNEL_EMAIL_ENABLED=false \
        CHANNEL_WHATSAPP_ENABLED=true CHANNEL_WHATSAPP_RECIPIENT="$SPACED" \
        USER_TZ="Europe/London" OSTLER_DIR="${WORK}/ostler_mut" \
        bash -c "$(cat "$MUT")" 2>&1
    )"
    if /usr/bin/grep -qF 'allowed_numbers = ["+44 7700 900123"]' <<< "$OUT_MUT" \
       && /usr/bin/grep -qF 'to = "+44 7700 900123"' <<< "$OUT_MUT"; then
        ok "MUST-FAIL: without the normalisation both consumers get the spaced value, so it is load-bearing"
    else
        bad "the mutant produced a clean value anyway; arm 2 is not testing the normalisation"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
