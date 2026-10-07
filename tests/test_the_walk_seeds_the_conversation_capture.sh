#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_conversation_capture.sh
# ============================================================================
# conversation_capture_end_to_end (v1.0.107 #10) needs two conversations
# submitted through the paired gateway (:8443) before it can measure
# anything. lib/conversation_capture_seed.sh supplies them. This test pins:
#
#   1. IT IS WIRED. The runner sources the lib, calls the apply FLUSH LEFT
#      inside the READ_ONLY gate, and calls the forget below phase 2.
#   2. SEEDED IS EARNED. A stub gateway that mints a pairing code, pairs,
#      and accepts both conversation POSTs reports seeded, with the two
#      job ids read back correctly. MUST-FAIL arms: a /pair that rejects the
#      fresh code, and a second conversation POST that comes back with no
#      job_id, each report failed.
#
# Pure bash + a stubbed curl on PATH. No network, no real Hub. Exit 0 pass.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/conversation_capture_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"

[ -f "$LIB" ] && [ -f "$RUNNER" ] || { echo "CANNOT-RUN: a subject file is missing"; exit 2; }

PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); else printf '  [FAIL] %s %s\n' "$1" "${3:-}"; FAIL=$((FAIL+1)); fi; }
b() { "$@" && echo 0 || echo 1; }

echo "1. wiring"
arm "the runner sources the lib" "$(b grep -q '^\. "\$HERE/lib/conversation_capture_seed.sh"' "$RUNNER")"
apply_line=$(grep -n '^conversation_capture_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)
forget_line=$(grep -n '^conversation_capture_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)
phase2_line=$(grep -n "^printf -- '--- PHASE 2" "$RUNNER" | head -1 | cut -d: -f1)
arm "the apply is called flush left, above phase 2" "$(b [ -n "$apply_line" ] && [ -n "$phase2_line" ] && [ "$apply_line" -lt "$phase2_line" ])" "apply=$apply_line phase2=$phase2_line"
arm "the forget is called below phase 2" "$(b [ -n "$forget_line" ] && [ "$forget_line" -gt "$phase2_line" ])" "forget=$forget_line"
gate=$(awk -v n="$apply_line" 'NR<n && /READ_ONLY/ {l=$0} END{print l}' "$RUNNER")
case "$gate" in *'if [ "$READ_ONLY" -eq 0 ]'*) g=0 ;; *) g=1 ;; esac
arm "the apply sits inside the READ_ONLY gate" "$g" "nearest gate: $gate"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkbox() {
    # $1 = MODE (ok | pair_rejected | second_no_jobid)
    local h="$T/box-$1"
    mkdir -p "$h/.ostler/secrets" "$h/.ostler/walk-seed" "$h/stub"
    echo "fake-admin-token" > "$h/.ostler/secrets/zeroclaw_admin_token"
    cat > "$h/stub/curl" <<'CURLSTUB'
#!/bin/bash
# Records every call and answers by URL (always the last argument) and MODE.
last="${@: -1}"
echo "$last" >> "$CURL_STUB_HOME/.ostler/walk-seed/calls.log"
case "$last" in
    */admin/paircode/new)
        echo '{"pairing_code":"ABC123"}'
        ;;
    */pair)
        if [ "${CURL_STUB_MODE:-ok}" = "pair_rejected" ]; then
            echo '{"paired":false,"error":"invalid code"}'
        else
            echo '{"paired":true,"token":"faketoken1234"}'
        fi
        ;;
    */api/v1/conversation/process)
        n_file="$CURL_STUB_HOME/.ostler/walk-seed/process_calls"
        n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$n_file"
        if [ "$n" -eq 2 ] && [ "${CURL_STUB_MODE:-ok}" = "second_no_jobid" ]; then
            echo '{"error":"synthetic failure"}'
        else
            echo "{\"job_id\":\"synthetic-conv-capture-000${n}\",\"status\":\"accepted\"}"
        fi
        ;;
    *)
        echo '{}'
        ;;
esac
CURLSTUB
    chmod +x "$h/stub/curl"
    echo "$h"
}

run_seed() { # $1 = box home, $2 = mode; prints "<state> <job1> <job2>"
    ( export HOME="$1" PATH="$1/stub:$PATH" CURL_STUB_MODE="$2" CURL_STUB_HOME="$1"
      unset OSTLER_BOX_HOST
      _ccs_box() { bash -c "$1"; }
      . "$LIB"
      _ccs_box() { bash -c "$1"; }
      conversation_capture_seed_apply >/dev/null 2>&1
      echo "$OSTLER_CONVCAP_SEED_STATE ${OSTLER_CONVCAP_JOB_ID_1:-none} ${OSTLER_CONVCAP_JOB_ID_2:-none}" )
}

echo "2. seeded is earned"
H=$(mkbox ok)
read -r state job1 job2 <<<"$(run_seed "$H" ok)"
arm "both conversations accepted reads seeded" "$(b [ "$state" = "seeded" ])" "got $state"
arm "job ids were read back from the two POST responses" "$(b [ "$job1" != "none" ] && [ "$job2" != "none" ] && [ "$job1" != "$job2" ])" "job1=$job1 job2=$job2"
arm "a device token file was minted on the box" "$(b [ -s "$H/.ostler/walk-seed/.convcap-devtoken" ])"
seed_log="$(run_seed "$H" ok 2>&1)"
if printf '%s' "$seed_log" | grep -q faketoken1234; then tokleak=1; else tokleak=0; fi
arm "the minted token never appears in the printed log" "$tokleak"

echo "3. MUST-FAIL arms"
H2=$(mkbox pair_rejected)
read -r state2 _ _ <<<"$(run_seed "$H2" pair_rejected)"
arm "MUST-FAIL: /pair rejecting the fresh code reads failed" "$(b [ "$state2" = "failed" ])" "got $state2"

H3=$(mkbox second_no_jobid)
read -r state3 j1_3 j2_3 <<<"$(run_seed "$H3" second_no_jobid)"
arm "MUST-FAIL: the second conversation POST returning no job_id reads failed" "$(b [ "$state3" = "failed" ])" "got $state3 (job1=$j1_3 job2=$j2_3)"
arm "MUST-FAIL arm still read the first job id back (only the second call was broken)" "$(b [ "$j1_3" != "none" ])" "got job1=$j1_3"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
