#!/usr/bin/env bash
#
# tests/test_detection_not_timer.sh
#
# auth-UX A-5: the permission choreography advances on DETECTED STATE,
# never on a fixed timer. lib/permission_queue.sh already covers the
# serial daemon queue (tests/test_permission_queue.sh); this suite locks
# the REMAINING former sleep-then-probe-once sites in install.sh:
#
#   * _ostler_poll_until -- the bounded poll helper: exits the instant
#     the detect function succeeds, times out at the bound, never wedges
#     on a zero cadence.
#   * the four post-modal FDA re-probes (installer early, installer late
#     assist, installer late recovery, daemon legacy) call the poll
#     helper -- no fixed `sleep 2` + one-shot probe remains.
#   * the daemon bootstrap grace period polls _imessage_daemon_fda_listed
#     (the daemon's row appearing in the TCC FDA table) instead of a
#     fixed sleep.
#   * every System Settings stale-list refresh (#279 / #572) settles by
#     detecting process exit (_ostler_wait_settings_closed), not a
#     fixed second.
#
# The unit half injects MOCK detect functions, so it runs with zero
# macOS prompts and zero real sleeps. What it CANNOT prove: that the
# real TCC prompts land one at a time on a clean box -- that is the
# box-walk's job.
#
# British English throughout. Bash 3.2 compatible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ── Extract _ostler_poll_until from install.sh ─────────────────────────────
# The helper is deliberately inline in install.sh (tarball installs may lack
# lib/), so extract the top-level function body and eval it here. A failed
# extraction is itself a test failure -- the helper must exist.
POLL_FN_SRC="$(sed -n '/^_ostler_poll_until() {$/,/^}$/p' "$INSTALL_SH")"
if [[ -z "$POLL_FN_SRC" ]]; then
    fail "_ostler_poll_until not found at top level in install.sh"
    echo "RESULT: FAILED" >&2
    exit 1
fi
eval "$POLL_FN_SRC"

# ── Unit: poll helper gates on state, not time ─────────────────────────────
DETECT_CALLS=0
DETECT_FLIP_AT=0
mock_detect() {
    DETECT_CALLS=$((DETECT_CALLS + 1))
    [[ "$DETECT_FLIP_AT" -gt 0 && "$DETECT_CALLS" -ge "$DETECT_FLIP_AT" ]]
}

# 1. Already-granted state advances immediately: one detect call, rc 0.
DETECT_CALLS=0; DETECT_FLIP_AT=1
if _ostler_poll_until mock_detect 5 0 && [[ "$DETECT_CALLS" -eq 1 ]]; then
    pass "already-granted state advances on the FIRST detect call"
else
    fail "expected immediate advance (rc=0, 1 call); got calls=$DETECT_CALLS"
fi

# 2. A grant that lands mid-poll is honoured the cycle it appears.
DETECT_CALLS=0; DETECT_FLIP_AT=3
if _ostler_poll_until mock_detect 10 0 && [[ "$DETECT_CALLS" -eq 3 ]]; then
    pass "late-landing grant honoured the cycle it appears (3 detect calls)"
else
    fail "expected advance at flip (rc=0, 3 calls); got calls=$DETECT_CALLS"
fi

# 3. Never-granted state hits the bounded timeout (rc 1), does not wedge --
#    zero cadence must still consume the bound (poll-count degradation).
DETECT_CALLS=0; DETECT_FLIP_AT=0
if _ostler_poll_until mock_detect 3 0; then
    fail "never-granted state returned success"
else
    if [[ "$DETECT_CALLS" -ge 3 && "$DETECT_CALLS" -le 5 ]]; then
        pass "never-granted state times out at the bound (rc=1, bounded calls)"
    else
        fail "timeout produced unexpected call count: $DETECT_CALLS"
    fi
fi

# ── Structural: the old fixed-sleep one-shot re-probes are gone ────────────
# The three tried/succeeded counter blocks each followed a `sleep 2`; their
# variable names are the cheapest honest fingerprint of the old shape.
for gone in FDA_REPROBE_TRIED FDA_RECOVER_TRIED _fda_early_retried; do
    if grep -q "$gone" "$INSTALL_SH"; then
        fail "legacy one-shot re-probe fingerprint '$gone' still present"
    else
        pass "legacy one-shot re-probe '$gone' removed"
    fi
done

# The four re-probe sites call the poll helper with their detect functions.
count_calls() { grep -c "_ostler_poll_until $1" "$INSTALL_SH" || true; }
[[ "$(count_calls _fda_early_regrant_detect)" -eq 1 ]] \
    && pass "early installer FDA re-probe polls _fda_early_regrant_detect" \
    || fail "early installer FDA re-probe does not poll (expected exactly 1 site)"
[[ "$(count_calls _fda_regrant_detect)" -eq 2 ]] \
    && pass "late assist + recovery FDA re-probes poll _fda_regrant_detect" \
    || fail "late installer FDA re-probes do not poll (expected exactly 2 sites)"
[[ "$(count_calls _permq_daemon_fda_detect)" -eq 1 ]] \
    && pass "daemon legacy FDA re-probe polls _permq_daemon_fda_detect" \
    || fail "daemon legacy FDA re-probe does not poll (expected exactly 1 site)"

# ── Structural: grace period is detection-based ────────────────────────────
grep -q '^_imessage_daemon_fda_listed() {$' "$INSTALL_SH" \
    && pass "_imessage_daemon_fda_listed probe defined" \
    || fail "_imessage_daemon_fda_listed probe missing"
[[ "$(count_calls _imessage_daemon_fda_listed)" -eq 2 ]] \
    && pass "daemon bootstrap grace period polls the TCC listed-row probe (both arms)" \
    || fail "grace period does not poll _imessage_daemon_fda_listed (expected 2 arms)"

# The listed-row probe must be row-PRESENCE (COUNT), not the granted check --
# a denied-but-listed row is exactly what makes the pane toggle available.
if sed -n '/^_imessage_daemon_fda_listed() {$/,/^}$/p' "$INSTALL_SH" \
        | grep -q 'SELECT COUNT(\*)'; then
    pass "listed-row probe queries row presence, not auth_value"
else
    fail "listed-row probe does not query row presence"
fi

# ── Structural: System Settings refresh settles by detection ───────────────
# Every `killall "System Preferences"` must be followed by the detection
# settle, never a bare `sleep 1`, before the pane reopen.
KILLALL_TOTAL=$(grep -c 'killall "System Preferences"' "$INSTALL_SH" || true)
SETTLED=$(grep -A2 'killall "System Preferences"' "$INSTALL_SH" \
    | grep -c '_ostler_wait_settings_closed' || true)
if [[ "$KILLALL_TOTAL" -ge 5 && "$SETTLED" -eq "$KILLALL_TOTAL" ]]; then
    pass "all ${KILLALL_TOTAL} System Settings refreshes settle by process-exit detection"
else
    fail "System Settings refresh not fully detection-settled (killall=$KILLALL_TOTAL settled=$SETTLED)"
fi

# ── Result ──────────────────────────────────────────────────────────────────
if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAILED" >&2
    exit 1
fi
echo "RESULT: PASSED"
