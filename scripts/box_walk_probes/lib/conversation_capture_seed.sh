# shellcheck shell=bash
# lib/conversation_capture_seed.sh -- two synthetic conversations, through the
# CUSTOMER's own iPhone/Watch path (v1.0.107 #10, conversation_capture_end_to_end,
# CM051 PR #2664).
#
# WHY A SEPARATE SEED FROM lib/conversation_seed.sh. That seed already puts
# one fictional voice note through the conversation pipeline, but
# DELIBERATELY bypasses the HTTP API entirely: it hands a transcript + a
# hand-written metadata.json straight to `pwg-convo process` as a CLI
# subprocess (its own "WHY THE DIRECT CLI" comment gives four measured
# reasons). That is the right choice for what it proves (the pipeline runs at
# all), and the wrong one for what THIS probe proves: whether a paired iPhone
# or Watch, calling the network API it actually calls, gets a working
# conversation out the other end. Nothing before this seed had ever gone
# through that door.
#
# WHAT IT DOES. Mints a device bearer the way the iPhone does, through
# lib/companion_pair.sh (the owner mints a QR token on the loopback admin
# port, then /auth/pair/init + /auth/pair/register on :8443), then POSTs TWO
# synthetic two-speaker transcripts to the SAME gateway's
# /api/v1/conversation/process, same day, same two participants, different
# `type` (conversation vs meeting) so they are two distinct conversations
# rather than one id colliding with itself. Only the POST -- it does not
# poll for completion. Polling is a READ, and it is the measurement
# conversation_capture_end_to_end.sh itself makes (same writer/reader split
# as every other seed in this file).
#
# A WRITER: the runner calls it only when the walk is not read-only (#2564).
#
# THE DEVICE BEARER NEVER CROSSES THE WIRE BACK TO THE ORCHESTRATOR. The
# probe's own read-side calls (status poll, findability check) need the same
# paired device this seed minted -- reusing it beats minting a second one,
# which would itself be an unaccounted write. So the token is written to a
# 0600 file ON THE BOX at mint time, and only ITS PATH (never its value)
# travels back through these exports; the probe hands that path to
# lib/conversation_capture_e2e.py's box half, which reads the file itself,
# already on the box. This is stricter than the admin-token pattern
# probes/pairing_recovers_without_a_repair_storm.sh uses (which never leaves
# the box either, but only because that probe never needs the value off-box).
#
# Exports, for the probe:
#   OSTLER_CONVCAP_SEED_STATE       seeded | failed | skipped-read-only | unrun
#   OSTLER_CONVCAP_JOB_ID_1         the first conversation_id (empty on failure)
#   OSTLER_CONVCAP_JOB_ID_2         the second conversation_id (empty on failure)
#   OSTLER_CONVCAP_DEVICE_TOKEN_FILE  box-side path holding the bearer (NOT the value)
#   OSTLER_CONVCAP_DATE             the date both conversations were seeded under
OSTLER_CONVCAP_SEED_STATE="unrun"
OSTLER_CONVCAP_JOB_ID_1=""
OSTLER_CONVCAP_JOB_ID_2=""
OSTLER_CONVCAP_DEVICE_TOKEN_FILE='$HOME/.ostler/walk-seed/.convcap-devtoken'
OSTLER_CONVCAP_DATE=""
export OSTLER_CONVCAP_SEED_STATE OSTLER_CONVCAP_JOB_ID_1 OSTLER_CONVCAP_JOB_ID_2 OSTLER_CONVCAP_DEVICE_TOKEN_FILE OSTLER_CONVCAP_DATE

_ccs_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

# The bash heredoc below runs ON THE BOX (or locally when OSTLER_BOX_HOST is
# unset) and does the admin-mint + /pair + two POSTs in one remote round
# trip, the same shape as owner_employer_seed_apply's single _oes_box call.
# It prints machine-parseable lines only; the device bearer itself is never
# echoed verbatim, only its length, so a transcript of this step cannot leak
# a live credential (CLAUDE.md security rule 2).
conversation_capture_seed_apply() {
    printf '%s\n' "--- CONVERSATION CAPTURE SEED: two synthetic conversations through the paired gateway (:8443) ---"
    # PAIRS THE WAY THE iPHONE DOES (lib/companion_pair.sh): the owner mints a
    # QR token on the loopback admin port, then /auth/pair/init + register on
    # :8443. The legacy 6-digit POST :8443/pair this used to take is refused
    # there by ostler-assistant #492/#501.
    declare -F companion_pair_box_snippet >/dev/null \
        || . "$(dirname "${BASH_SOURCE[0]}")/companion_pair.sh"
    local out
    out="$(_ccs_box "set -u
GW=\${OSTLER_CONVCAP_GATEWAY:-https://127.0.0.1:8443}
[ -r \$HOME/.ostler/secrets/zeroclaw_admin_token ] || { echo 'CCS no-admin-token'; exit 2; }
$(companion_pair_box_snippet '$GW' 0)
TOKEN=\$CP_TOKEN
[ -n \"\$TOKEN\" ] || { echo \"CCS pair-rejected \$(printf '%s' \"\$CP_JSON\" | head -c 200)\"; exit 2; }
echo \"CCS token-len=\${#TOKEN}\"
mkdir -p \"\$HOME/.ostler/walk-seed\" || { echo 'CCS no-token-dir'; exit 2; }
( umask 077; printf '%s' \"\$TOKEN\" > \"\$HOME/.ostler/walk-seed/.convcap-devtoken\" )
echo \"CCS devtoken-file:\$HOME/.ostler/walk-seed/.convcap-devtoken\"
DATE=\$(date -u +%Y-%m-%d)
TRANSCRIPT1='Alice Example: Morning. Did the roof quote come back?\\nBob Example: Yes, two trades can do it. I will send the quote by Friday.\\nAlice Example: Great, let us start the week after.'
TRANSCRIPT2='Alice Example: Can you do the site visit Tuesday?\\nBob Example: Yes, morning works. I will bring the ladder.'
post_one() {
    local transcript=\"\$1\" type=\"\$2\"
    local payload
    payload=\$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({\"transcript\": sys.argv[1], \"metadata\": {\"participants\": [\"Alice Example\", \"Bob Example\"], \"date\": sys.argv[2], \"type\": sys.argv[3], \"started_at\": sys.argv[2]+\"T09:00:00Z\", \"ended_at\": sys.argv[2]+\"T09:20:00Z\"}}))' \"\$transcript\" \"\$DATE\" \"\$type\")
    curl -sk --noproxy '*' -m 20 -X POST -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' --data-binary \"\$payload\" \"\$GW/api/v1/conversation/process\"
}
R1=\$(post_one \"\$TRANSCRIPT1\" conversation)
J1=\$(printf '%s' \"\$R1\" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"job_id\",\"\"))' 2>/dev/null)
echo \"CCS job1=\${J1:-none} resp1=\${R1:0:140}\"
R2=\$(post_one \"\$TRANSCRIPT2\" meeting)
J2=\$(printf '%s' \"\$R2\" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"job_id\",\"\"))' 2>/dev/null)
echo \"CCS job2=\${J2:-none} resp2=\${R2:0:140}\"
echo \"CCS date=\$DATE\"
[ -n \"\$J1\" ] && [ -n \"\$J2\" ] && echo 'CCS both-accepted'
" 2>&1)"
    # The device bearer itself never appears in $out: the remote script wrote
    # it straight to a 0600 file and echoed only that PATH ("CCS
    # devtoken-file:<path>", not a secret). Defence in depth against a future
    # edit that echoes a header verbatim: redact any literal "Bearer <value>".
    printf '%s\n' "$out" | sed -e 's/Bearer [A-Za-z0-9._-]\{1,\}/Bearer ***REDACTED***/' | sed 's/^/    /'

    OSTLER_CONVCAP_JOB_ID_1="$(printf '%s\n' "$out" | sed -n 's/^CCS job1=\([^ ]*\).*/\1/p' | head -1)"
    OSTLER_CONVCAP_JOB_ID_2="$(printf '%s\n' "$out" | sed -n 's/^CCS job2=\([^ ]*\).*/\1/p' | head -1)"
    OSTLER_CONVCAP_DATE="$(printf '%s\n' "$out" | sed -n 's/^CCS date=\(.*\)/\1/p' | head -1)"
    local devtoken_file
    devtoken_file="$(printf '%s\n' "$out" | sed -n 's/^CCS devtoken-file:\(.*\)/\1/p' | head -1)"
    [ -n "$devtoken_file" ] && OSTLER_CONVCAP_DEVICE_TOKEN_FILE="$devtoken_file"
    [ "${OSTLER_CONVCAP_JOB_ID_1:-none}" = "none" ] && OSTLER_CONVCAP_JOB_ID_1=""
    [ "${OSTLER_CONVCAP_JOB_ID_2:-none}" = "none" ] && OSTLER_CONVCAP_JOB_ID_2=""
    if printf '%s\n' "$out" | grep -q 'CCS both-accepted' && [ -n "$OSTLER_CONVCAP_JOB_ID_1" ] && [ -n "$OSTLER_CONVCAP_JOB_ID_2" ]; then
        OSTLER_CONVCAP_SEED_STATE="seeded"
    else
        OSTLER_CONVCAP_SEED_STATE="failed"
    fi
    export OSTLER_CONVCAP_SEED_STATE OSTLER_CONVCAP_JOB_ID_1 OSTLER_CONVCAP_JOB_ID_2 OSTLER_CONVCAP_DEVICE_TOKEN_FILE OSTLER_CONVCAP_DATE
    printf '  conversation capture seed: %s (job1=%s job2=%s)\n\n' "$OSTLER_CONVCAP_SEED_STATE" "${OSTLER_CONVCAP_JOB_ID_1:-none}" "${OSTLER_CONVCAP_JOB_ID_2:-none}"
    [ "$OSTLER_CONVCAP_SEED_STATE" = "seeded" ]
}

# conversation_capture_seed_forget -- remove the two synthetic conversations
# again. Every measurement was taken before this runs, so it changes no
# verdict. Deletes the Conversations-folder artefacts it created (matched by
# conversation_id in frontmatter, never by a guessed path) and the two
# processing-state directories, printing the count before and after exactly
# like every other seed's forget.
conversation_capture_seed_forget() {
    [ "$OSTLER_CONVCAP_SEED_STATE" = "seeded" ] || [ "$OSTLER_CONVCAP_SEED_STATE" = "failed" ] || return 0
    if [ "${OSTLER_CONVCAP_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- CONVERSATION CAPTURE SEED: kept on the box (OSTLER_CONVCAP_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- CONVERSATION CAPTURE SEED: removing the two synthetic conversations ---\n'
    local out
    out="$(_ccs_box "set -u
ROOT=\$HOME/Documents/Ostler/Conversations
PROC=\$HOME/.pwg/processing
rm -f \"\$HOME/.ostler/walk-seed/.convcap-devtoken\"
before=0
for id in '${OSTLER_CONVCAP_JOB_ID_1:-}' '${OSTLER_CONVCAP_JOB_ID_2:-}'; do
    [ -n \"\$id\" ] || continue
    for f in \"\$ROOT\"/*/*/summary.md; do
        [ -f \"\$f\" ] || continue
        grep -q \"conversation_id: \\\"\$id\\\"\" \"\$f\" 2>/dev/null && before=\$((before+1))
    done
done
echo \"CCS forget-before=\$before\"
for id in '${OSTLER_CONVCAP_JOB_ID_1:-}' '${OSTLER_CONVCAP_JOB_ID_2:-}'; do
    [ -n \"\$id\" ] || continue
    for f in \"\$ROOT\"/*/*/summary.md; do
        [ -f \"\$f\" ] || continue
        if grep -q \"conversation_id: \\\"\$id\\\"\" \"\$f\" 2>/dev/null; then
            rm -rf \"\$(dirname \"\$f\")\"
        fi
    done
    rm -rf \"\$PROC/\$id\"
done
after=0
for id in '${OSTLER_CONVCAP_JOB_ID_1:-}' '${OSTLER_CONVCAP_JOB_ID_2:-}'; do
    [ -n \"\$id\" ] || continue
    for f in \"\$ROOT\"/*/*/summary.md; do
        [ -f \"\$f\" ] || continue
        grep -q \"conversation_id: \\\"\$id\\\"\" \"\$f\" 2>/dev/null && after=\$((after+1))
    done
done
echo \"CCS forget-after=\$after\"" 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    if ! printf '%s\n' "$out" | grep -q '^CCS forget-after=0$'; then
        printf '  Left on the box: a synthetic conversation folder may still be present.\n'
        printf '  No verdict changes; remove it by hand on any box that is not a throwaway.\n'
    fi
    printf '  Left on the box, by design, same as pairing_recovers_without_a_repair_storm.sh:\n'
    printf '  the device pairing token this seed minted. There is no known revoke route;\n'
    printf '  a walk box is reset between walks.\n\n'
    return 0
}
