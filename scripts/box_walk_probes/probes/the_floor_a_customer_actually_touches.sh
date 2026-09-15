#!/usr/bin/env bash
# THE FLOOR. Five surfaces, each one something Andy found broken BY HAND in the
# week of 2026-09-08, and each one missed by every gate this project had.
#
# WHY THIS EXISTS. Every other check asks about an ARTEFACT: does the file exist,
# does the pattern appear, did the test pass. None asked whether a PERSON got
# what they wanted. So /doctor returned 500 on every load for three builds while
# /api/v1/sources answered 200 and every gate stayed green, and ostler-unlock
# shipped in the DMG while the customer got "command not found".
#
# THE RULE FOR ANYTHING ADDED HERE: the subject of the assertion is a PERSON or
# THE THING THEY SEE. If the subject is a file, it does not belong in this file.
#
# THREE OUTCOMES, NEVER TWO. A surface that could not be reached is CANNOT-RUN,
# which is NOT a pass. A zero that could not be measured must never read as green.
set -u

HOST="${OSTLER_FLOOR_HOST:-127.0.0.1}"
DOCTOR_PORT="${DOCTOR_PORT:-8089}"
WIKI_PORT="${OSTLER_WIKI_PORT:-8044}"
PASS=0; FAIL=0; CANT=0
ok(){   printf 'PASS        %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf 'FAIL        %s\n' "$1"; FAIL=$((FAIL+1)); }
cant(){ printf 'CANNOT-RUN  %s\n' "$1"; CANT=$((CANT+1)); }

# curl WITHOUT 2>/dev/null: a usage error must not read as an absent surface.
fetch(){ curl -s --noproxy '*' --max-time "${2:-10}" "$1"; }
code(){  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time "${2:-10}" "$1"; }

echo "=== THE FLOOR, ${HOST} ==="

# POSITIVE CONTROL FIRST. If the Doctor answers nothing at all, every check below
# would report a defect that is really an unreachable box. Prove the instrument
# can see SOMETHING before believing any of its zeros.
CONTROL="$(code "http://${HOST}:${DOCTOR_PORT}/api/v1/sources")"
if [ "${CONTROL}" != "200" ]; then
    cant "control: /api/v1/sources answered ${CONTROL}, not 200. The box is not serving, so nothing below is measurable."
    printf '\nFLOOR: CANNOT-RUN (control failed)  pass=%d fail=%d cannot-run=%d\n' "$PASS" "$FAIL" "$CANT"
    exit 2
fi

# F1  THE DOCTOR PAGE ITSELF, not the endpoint behind it.
#     v1.0.98 returned 21 bytes of "Internal Server Error" here for three builds.
F1_CODE="$(code "http://${HOST}:${DOCTOR_PORT}/doctor")"
F1_BODY="$(fetch "http://${HOST}:${DOCTOR_PORT}/doctor")"
F1_BYTES="${#F1_BODY}"
if [ "${F1_CODE}" != "200" ]; then
    bad "F1 doctor page: HTTP ${F1_CODE}, ${F1_BYTES} bytes. A customer sees an error page."
elif ! printf '%s' "${F1_BODY}" | /usr/bin/grep -qi '<table'; then
    bad "F1 doctor page: 200 but no table in ${F1_BYTES} bytes. The page loads and shows the customer nothing."
else
    ok "F1 doctor page: 200, ${F1_BYTES} bytes, renders a table."
fi

# F2  THE WIKI, WITH THE CREDENTIAL THE CUSTOMER WAS GIVEN.
#     A 401 here is CORRECT: the wiki is a loopback listener holding the
#     customer's whole life and it should refuse an uncredentialled caller.
#     The real question is whether the credential they were handed WORKS.
#     An earlier version of this probe treated the 401 as the defect. It was
#     wrong, and it would have sent someone to "fix" a working security control.
F2_UNAUTH="$(code "http://${HOST}:${WIKI_PORT}/")"
F2_SECRET="${OSTLER_WIKI_PASSWORD_FILE:-${HOME}/.ostler/secrets/wiki_password}"
if [ "${F2_UNAUTH}" = "000" ]; then
    cant "F2 wiki: no answer on ${WIKI_PORT}. Not serving is not the same as refusing; unmeasured."
elif [ "${F2_UNAUTH}" != "401" ]; then
    bad "F2 wiki: answered ${F2_UNAUTH} with NO credential. It should refuse one."
elif [ ! -r "${F2_SECRET}" ]; then
    bad "F2 wiki: refuses correctly, but the customer's credential file is missing or unreadable. They can never get in."
else
    F2_PW="$(cat "${F2_SECRET}")"
    F2_CODE="$(curl -s -o /tmp/ostler_floor_wiki.$$ -w '%{http_code}' --noproxy '*' --max-time 12 -u "ostler:${F2_PW}" "http://${HOST}:${WIKI_PORT}/")"
    F2_BYTES="$(wc -c < /tmp/ostler_floor_wiki.$$ 2>/dev/null | tr -d ' ')"
    F2_CSS="$(/usr/bin/grep -c -i '<link' /tmp/ostler_floor_wiki.$$ 2>/dev/null || echo 0)"
    rm -f /tmp/ostler_floor_wiki.$$
    if [ "${F2_CODE}" != "200" ]; then
        bad "F2 wiki: the credential the customer was given is REFUSED (HTTP ${F2_CODE})."
    elif [ "${F2_CSS}" -lt 1 ]; then
        bad "F2 wiki: 200 and ${F2_BYTES} bytes but no stylesheet link. The customer sees unstyled markup."
    else
        ok "F2 wiki: refuses without a credential, opens with the customer's own, ${F2_BYTES} bytes, ${F2_CSS} stylesheet link(s)."
    fi
fi

# F3  THE FRONT PAGE. ZERO INTERESTS IS A FAILURE, not an empty state.
#     "0 interests inferred so far" survived three builds and two claimed fixes.
FP="$(fetch "http://${HOST}:${DOCTOR_PORT}/api/v1/sources" 5)"
if [ -z "${FP}" ]; then
    cant "F3 front page: no answer to read interests from."
else
    N="$(printf '%s' "${FP}" | python3 -c '
import sys,json
try: rows=json.load(sys.stdin).get("sources") or []
except Exception: print("ERR"); raise SystemExit
print(sum(1 for r in rows if isinstance(r,dict) and (r.get("item_count") or 0)>0))
' 2>&1)"
    case "${N}" in
      ERR|"") cant "F3 front page: sources payload would not parse." ;;
      0)      bad  "F3 front page: 0 of the declared sources report any items. The customer opens Ostler and it knows nothing." ;;
      *)      ok   "F3 front page: ${N} source(s) report items." ;;
    esac
fi

# F4  THE RECOVERY COMMAND, BY BARE NAME, THE WAY A CUSTOMER TYPES IT.
#     Only an INTERACTIVE LOGIN shell sources .zshrc. A probe using `zsh -lc`
#     passes while the customer still gets "command not found".
if ! command -v zsh >/dev/null 2>&1; then
    cant "F4 recovery: no zsh on this host to test the customer's shell."
else
    OUT="$(printf 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF\n' | zsh -ilc 'ostler-unlock --recovery-key --secret-file /dev/stdin' 2>&1)"
    RC=$?
    if printf '%s' "${OUT}" | /usr/bin/grep -qi 'command not found'; then
        bad "F4 recovery: 'ostler-unlock' is not on the customer's PATH. It is in the DMG and they cannot run it."
    elif printf '%s' "${OUT}" | /usr/bin/grep -qi 'incorrect recovery key'; then
        ok  "F4 recovery: found by name, and refused a deliberately wrong key."
    else
        bad "F4 recovery: reachable but did not refuse a wrong key (rc=${RC}). A redeemer that accepts anything is worse than none."
    fi
fi

# F5  THE SOURCES TABLE THE CUSTOMER READS. Blanks are a failure: a source that
#     has not run must SAY so. item_count of None renders as a blank.
if [ -n "${FP:-}" ]; then
    BLANKS="$(printf '%s' "${FP}" | python3 -c '
import sys,json
try: rows=json.load(sys.stdin).get("sources") or []
except Exception: print("ERR"); raise SystemExit
print(sum(1 for r in rows if isinstance(r,dict) and r.get("item_count") is None and not (r.get("status") or "")))
' 2>&1)"
    case "${BLANKS}" in
      ERR|"") cant "F5 sources table: payload would not parse." ;;
      0)      ok   "F5 sources table: every row carries a count or says what it is doing." ;;
      *)      bad  "F5 sources table: ${BLANKS} row(s) show the customer a blank with no count and no status." ;;
    esac
else
    cant "F5 sources table: nothing to read."
fi

printf '\nFLOOR: pass=%d fail=%d cannot-run=%d\n' "$PASS" "$FAIL" "$CANT"
[ "$FAIL" -eq 0 ] && [ "$CANT" -eq 0 ] && { echo "FLOOR GREEN 5/5"; exit 0; }
[ "$FAIL" -gt 0 ] && { echo "FLOOR RED"; exit 1; }
echo "FLOOR INCOMPLETE -- cannot-run is not a pass"; exit 2
