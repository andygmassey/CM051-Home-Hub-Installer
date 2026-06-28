#!/usr/bin/env bash
#
# tests/test_permission_queue.sh
#
# Behavioural unit test for lib/permission_queue.sh -- the serial,
# completion-detected permission queue (docs/PERMISSION_CHOREOGRAPHY_v2.md).
#
# These tests inject MOCK detect_fn / interact_fn so they run with zero macOS
# prompts and zero real sleeps (PERMQ_POLL_SECS=0). They prove the LOGIC of the
# choreography:
#
#   * the loop gates on STATE (detect_fn), not on a timer
#   * a step exits the instant the state flips to granted
#   * Skip and the Done backstop advance without a poll-confirmed grant
#   * steps run strictly one at a time (step 2 untouched until step 1 resolves)
#
# What these tests CANNOT prove (and must NOT be read as proving): that the real
# macOS TCC prompts appear one at a time in the right position on a clean box.
# That is the box-walk's job. See the design doc, sections 9-10.
#
# British English throughout. Bash 3.2 compatible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO_ROOT}/lib/permission_queue.sh"

# Never sleep in tests; the gate is state, not time, so a zero cadence must
# still produce correct results.
export PERMQ_POLL_SECS=0
export PERMQ_MAX_POLLS=50

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# shellcheck source=/dev/null
source "$LIB"

# ── Mock machinery ─────────────────────────────────────────────────────────
# Counters are globals the mocks increment so each test can assert call counts
# and ordering. Reset before every case.
DETECT_CALLS=0
INTERACT_CALLS=0
# DETECT_FLIP_AT: detect returns "granted" once DETECT_CALLS reaches this.
DETECT_FLIP_AT=0
# INTERACT_RETURN: what interact echoes ("wait" | "skip" | "done").
INTERACT_RETURN="wait"
# ORDER_TRACE: appended to by the second-step mocks to prove sequencing.
ORDER_TRACE=()

reset_mocks() {
    DETECT_CALLS=0
    INTERACT_CALLS=0
    DETECT_FLIP_AT=0
    INTERACT_RETURN="wait"
    ORDER_TRACE=()
    PERMQ_LAST_RESULT=""
    PERMQ_STEP_ORDER=()
}

# detect_fn contract: RETURN 0 when granted, non-zero otherwise. Runs in the
# current shell, so the counter increments persist (the whole reason the driver
# uses exit codes, not command substitution).
mock_detect() {
    DETECT_CALLS=$((DETECT_CALLS + 1))
    if [[ "$DETECT_FLIP_AT" -gt 0 && "$DETECT_CALLS" -ge "$DETECT_FLIP_AT" ]]; then
        return 0
    fi
    return 1
}

# interact_fn contract: set the global PERMQ_ACT. Runs in the current shell.
mock_interact() {
    INTERACT_CALLS=$((INTERACT_CALLS + 1))
    PERMQ_ACT="$INTERACT_RETURN"
}

# ── Test 1: gates on STATE, exits on the flip (not on a timer) ─────────────
# detect returns not-granted twice, then granted on the 3rd poll. interact
# always says "wait" (the user does nothing; the card just keeps timing out).
# The step MUST exit "granted" exactly when the state flips -- proving the loop
# waits on detect_fn, not on any elapsed time.
reset_mocks
DETECT_FLIP_AT=3
INTERACT_RETURN="wait"
permq_run_step "fda" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "granted" ]]; then
    pass "state flip is detected and ends the step (result=granted)"
else
    fail "expected granted on state flip, got '$PERMQ_LAST_RESULT'"
fi
# detect must have been polled at least until the flip (>=3). If the loop were
# time-based it could exit early/late independent of detect.
if [[ "$DETECT_CALLS" -ge 3 ]]; then
    pass "loop polled the real state until it flipped (detect calls=$DETECT_CALLS)"
else
    fail "loop did not poll state to the flip point (detect calls=$DETECT_CALLS, expected >=3)"
fi

# ── Test 2: already-granted advances immediately, no card shown ────────────
# If the permission is already granted, the step must not raise a card at all.
reset_mocks
DETECT_FLIP_AT=1   # granted on the very first poll
permq_run_step "fda" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "granted" && "$INTERACT_CALLS" -eq 0 ]]; then
    pass "already-granted advances with no card raised (interact calls=0)"
else
    fail "already-granted should not raise a card (result=$PERMQ_LAST_RESULT interact=$INTERACT_CALLS)"
fi

# ── Test 3: Skip advances without a grant ──────────────────────────────────
reset_mocks
DETECT_FLIP_AT=0          # never granted
INTERACT_RETURN="skip"
permq_run_step "automation" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "skipped" ]]; then
    pass "user Skip advances the queue without a grant"
else
    fail "expected skipped, got '$PERMQ_LAST_RESULT'"
fi

# ── Test 4: Done backstop when the grant cannot be polled ──────────────────
# detect never confirms (models an ask whose TCC row we cannot read on this
# macOS). The user taps Done -> the step resolves as done_unverified (the
# explicit-Done backstop), NOT an infinite loop.
reset_mocks
DETECT_FLIP_AT=0
INTERACT_RETURN="done"
permq_run_step "automation" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "done_unverified" ]]; then
    pass "user Done is honoured as a backstop when state cannot be confirmed"
else
    fail "expected done_unverified, got '$PERMQ_LAST_RESULT'"
fi

# ── Test 5: Done that IS confirmed reads back as a clean grant ─────────────
# The user taps Done and the state has in fact flipped -> granted, not
# done_unverified (trust-but-verify).
reset_mocks
DETECT_FLIP_AT=2   # not granted on first poll, granted on the verify re-read
INTERACT_RETURN="done"
permq_run_step "fda" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "granted" ]]; then
    pass "Done with a confirmed state reads back as a clean grant"
else
    fail "expected granted on confirmed Done, got '$PERMQ_LAST_RESULT'"
fi

# ── Test 6: one step at a time -- step 2 untouched until step 1 resolves ────
# Two steps. Step 1's mocks record "s1-detect"/"s1-interact"; step 2's record
# "s2-*". Step 1 resolves only after the user Skips it. We then assert that NO
# step-2 function was called before step 1's resolution -- i.e. the first
# step-2 trace entry comes AFTER step 1's last entry.
reset_mocks
# Step 1 never grants and is resolved by the user tapping Skip. Step 2 is
# already granted. The mocks append to ORDER_TRACE so we can prove step 2's
# functions are not touched until step 1 has resolved.
s1_detect()   { ORDER_TRACE+=("s1-detect"); return 1; }
s1_interact() { ORDER_TRACE+=("s1-interact"); PERMQ_ACT="skip"; }
s2_detect()   { ORDER_TRACE+=("s2-detect"); return 0; }
# shellcheck disable=SC2034  # PERMQ_ACT is read by the driver, not here
s2_interact() { ORDER_TRACE+=("s2-interact"); PERMQ_ACT="wait"; }

permq_run \
    "step1" s1_detect s1_interact \
    "step2" s2_detect s2_interact

# Find the index of the first s2-* entry and the last s1-* entry.
first_s2=-1
last_s1=-1
idx=0
for e in "${ORDER_TRACE[@]}"; do
    case "$e" in
        s1-*) last_s1=$idx ;;
        s2-*) [[ "$first_s2" -lt 0 ]] && first_s2=$idx ;;
    esac
    idx=$((idx + 1))
done
if [[ "$first_s2" -gt "$last_s1" ]]; then
    pass "strict one-at-a-time: step 2 not touched until step 1 resolved (last_s1=$last_s1 first_s2=$first_s2)"
else
    fail "step 2 ran before step 1 resolved (trace: ${ORDER_TRACE[*]})"
fi

# Both steps recorded in the audit trail, in order.
if [[ "${PERMQ_STEP_ORDER[0]}" == "step1:skipped" && "${PERMQ_STEP_ORDER[1]}" == "step2:granted" ]]; then
    pass "audit trail records both steps in order (${PERMQ_STEP_ORDER[*]})"
else
    fail "audit trail wrong: ${PERMQ_STEP_ORDER[*]}"
fi

# permq_step_result helper resolves a labelled outcome.
if [[ "$(permq_step_result step2)" == "granted" && "$(permq_step_result absentlabel)" == "absent" ]]; then
    pass "permq_step_result resolves labelled outcomes"
else
    fail "permq_step_result returned wrong value"
fi

# ── Test 7: safety ceiling cannot wedge the install ────────────────────────
# detect never grants, user never acts (interact always "wait"). The loop must
# bail at PERMQ_MAX_POLLS with result=timeout, never spin forever.
reset_mocks
DETECT_FLIP_AT=0
INTERACT_RETURN="wait"
export PERMQ_MAX_POLLS=5
permq_run_step "fda" mock_detect mock_interact || true
if [[ "$PERMQ_LAST_RESULT" == "timeout" && "$DETECT_CALLS" -le 6 ]]; then
    pass "safety ceiling bounds the wait (result=timeout after $DETECT_CALLS polls)"
else
    fail "safety ceiling not honoured (result=$PERMQ_LAST_RESULT calls=$DETECT_CALLS)"
fi
export PERMQ_MAX_POLLS=50

# ── Syntax cleanliness ─────────────────────────────────────────────────────
bash -n "$LIB" || fail "bash -n lib/permission_queue.sh failed"

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
