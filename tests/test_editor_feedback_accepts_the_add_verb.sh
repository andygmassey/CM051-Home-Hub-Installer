#!/usr/bin/env bash
# "Tell Ostler what you're into" must reach the store, and the next compile
# must see it.
#
# WHAT WAS BROKEN. CM059 PR #24 renders a masthead input on the Front Page
# that POSTs {action:'add', subject} to the Doctor's
# POST /api/v1/editor/feedback. The Doctor's vendor/doctor/agent/
# editor_feedback.py had an action allowlist of three card verbs plus their UI
# labels, "add" was not among them, and validate_payload demanded a card_id
# that a masthead control has no concept of. A customer typing an interest and
# pressing Add got HTTP 400 and a "not saved" line. Nothing underneath was
# missing: CorrectionStore.add has always existed and
# interest_profile.apply_corrections has always folded the "add" bucket into
# every compile.
#
# WHAT THIS ASSERTS, AND WHY IT IS NOT "the route returned 200". The last
# assertion runs the compile the pipeline's next full recompile runs, reading
# corrections from the exact store the POST just wrote to, and requires the
# subject to come out the other side. A row in a JSON file is not the promise
# the button makes; appearing on the Front Page is.
#
# It also holds the line that makes any of it meaningful: a refusal must be a
# refusal. record_feedback never raises for the ordinary bad-input cases, it
# returns {"ok": False, "error": ...}, and the route used to turn that into
# {"status": "recorded"} with HTTP 200 -- a refusal wearing a success's
# clothes, which is the very defect this whole endpoint was written to kill.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="${REPO}/vendor/doctor/agent"
EDITOR_HOME="${REPO}/vendor/cm059_editor"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

echo "== the Front Page add verb reaches the store and survives the next compile =="

PY="${OSTLER_TEST_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || {
    echo "  [CANNOT-RUN] no python3 on PATH. NOTHING was examined."; exit 2; }
if ! "$PY" -c 'import fastapi, uvicorn, httpx, qrcode' ; then
    echo "  [CANNOT-RUN] the Doctor's runtime deps (fastapi uvicorn httpx qrcode)"
    echo "               are not importable by ${PY}. NOTHING was examined."
    exit 2
fi

TMP="$(mktemp -d)"
DOCTOR_PID=""
cleanup() {
    [ -n "$DOCTOR_PID" ] && kill "$DOCTOR_PID" 2>/dev/null
    wait "$DOCTOR_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

PORT="$("$PY" - <<'PYEOF'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PYEOF
)"

mkdir -p "${TMP}/editor"
STORE="${TMP}/editor/interest_corrections.json"

(
  cd "$AGENT" || exit 1
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  no_proxy='*' NO_PROXY='*' \
  DOCTOR_PORT="$PORT" \
  OSTLER_EDITOR_HOME="$EDITOR_HOME" \
  OSTLER_EDITOR_DIR="${TMP}/editor" \
  exec "$PY" web_ui.py
) > "${TMP}/doctor.log" 2>&1 &
DOCTOR_PID=$!

BASE="http://127.0.0.1:${PORT}"
ready=0
for _ in $(seq 1 100); do
    if curl -s --noproxy '*' -o /dev/null -m 2 "${BASE}/doctor/api/health"; then
        ready=1; break
    fi
    "$PY" -c 'import time; time.sleep(0.3)'
done
if [ "$ready" -ne 1 ]; then
    echo "  [CANNOT-RUN] the Doctor did not come up on ${BASE}. NOTHING was examined."
    cat "${TMP}/doctor.log"
    exit 2
fi

BODY=""
post() {
    local name="$1" want="$2" payload="$3"
    local out status
    out="$(curl -s --noproxy '*' -m 15 -X POST \
           -H 'Content-Type: application/json' -d "$payload" \
           -w '\n%{http_code}' "${BASE}/api/v1/editor/feedback")"
    status="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
    if [ "$status" = "$want" ]; then
        ok "${name}: HTTP ${status}"
    else
        bad "${name}: expected HTTP ${want}, got ${status} -- body[0:200]: ${BODY:0:200}"
    fi
}

# Deliberately impersonal and clearly synthetic. A fixture on this endpoint
# writes to a preferences store; it must never carry a real person's interests.
SUBJECT="Nineteenth century canal locks"
ABSENT="Something nobody ever added"

echo
echo "-- the add verb, with no card_id, which is the shape the masthead sends --"
post "an add with a subject is ACCEPTED" 200 \
     "{\"action\":\"add\",\"subject\":\"${SUBJECT}\",\"domain\":\"History\"}"
case "$BODY" in
    *'"status":"recorded"'*) ok "the answer says recorded" ;;
    *) bad "the 200 body does not say recorded: ${BODY:0:200}" ;;
esac
case "$BODY" in
    *"${SUBJECT}"*) ok "the answer names the subject it stored" ;;
    *) bad "the answer does not name the subject: ${BODY:0:200}" ;;
esac

echo
echo "-- what the store holds now --"
if [ -f "$STORE" ]; then
    ok "the correction store exists at the path the editor resolves"
else
    bad "no correction store was written at ${STORE}"
fi
if "$PY" - "$STORE" "$SUBJECT" <<'PYEOF'
import json, sys
store = json.load(open(sys.argv[1]))
entries = store.get("add", [])
sys.exit(0 if any(e.get("subject") == sys.argv[2] for e in entries) else 1)
PYEOF
then ok "the subject is in the store's add bucket"
else bad "the subject never reached the store's add bucket"
fi

echo
echo "-- THE CONSUMER-SIDE PROOF: the next full compile surfaces it --"
# compile_profile is what interest_profile.build_from_live calls on the
# pipeline's next full recompile, reading corrections from this very store. An
# empty raws list stands in for "nothing else was inferred this run", so the
# subject can only appear if the correction alone put it there.
compile_out="$(cd "$EDITOR_HOME" && OSTLER_EDITOR_DIR="${TMP}/editor" "$PY" - \
    "$STORE" <<'PYEOF'
import json, sys
from compiler import corrections as corr_mod
from compiler import interest_profile as ip
corrections = corr_mod.load_corrections(sys.argv[1])
profile = ip.compile_profile([], corrections=corrections)
subjects = [i["subject"] for b in profile["domains"] for i in b["interests"]]
print(json.dumps(subjects))
PYEOF
)"
rc=$?
if [ "$rc" -ne 0 ]; then
    bad "the compile itself failed (rc=${rc}) -- this is CANNOT-TELL, not a pass: ${compile_out:0:200}"
else
    case "$compile_out" in
        *"${SUBJECT}"*) ok "the added subject appears in the compiled profile" ;;
        *) bad "the compiled profile does not carry the added subject: ${compile_out:0:300}" ;;
    esac
    # The control for the assertion above. If compile_profile surfaced
    # anything handed to it, or if the comparison could not fail, the check
    # would pass for a reason that has nothing to do with the write.
    case "$compile_out" in
        *"${ABSENT}"*) bad "the compiled profile carries a subject nobody added -- the check cannot fail" ;;
        *) ok "a subject nobody added is absent (the check can fail)" ;;
    esac
fi

echo
echo "-- the refusals, which must stay refusals --"
post "an add with no subject is REFUSED" 400 '{"action":"add"}'
case "$BODY" in
    *subject*) ok "the refusal names the missing subject" ;;
    *) bad "the 400 does not name the missing field: ${BODY:0:200}" ;;
esac
post "an add with a whitespace subject is REFUSED" 400 \
     '{"action":"add","subject":"   "}'
post "a genuinely unknown verb is still REFUSED" 400 \
     '{"action":"teleport","card_id":"card_1"}'
# The silent-failure line. record_feedback answers {"ok": False} here rather
# than raising, and a 200 "recorded" for it is the defect this file exists to
# kill.
post "a correction verb with nothing to apply to is REFUSED, not recorded" 400 \
     '{"action":"weaken","card_id":"card_no_such"}'
case "$BODY" in
    *'"status":"recorded"'*) bad "🔴 a refused correction reported itself recorded" ;;
    *) ok "the refusal does not report itself recorded" ;;
esac

echo
echo "-- the three card verbs must still work (the regression control) --"
post "a strengthen with a card_id and an interest_id is ACCEPTED" 200 \
     '{"action":"Spot on","card_id":"card_1","interest_id":"int_canals"}'
post "a second add, via the add_interest alias, is ACCEPTED with no card_id" 200 \
     "{\"action\":\"add_interest\",\"subject\":\"${SUBJECT} II\"}"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "GREEN"
