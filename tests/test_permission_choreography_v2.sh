#!/usr/bin/env bash
#
# tests/test_permission_choreography_v2.sh
#
# Locks the structural wiring of the choreography-v2 daemon permission flow
# (docs/PERMISSION_CHOREOGRAPHY_v2.md) in install.sh + the strings catalogue.
#
# This is a STRUCTURAL test (grep + bash -n), like test_daemon_fda_serialisation.
# The behavioural proof that the queue gates on STATE not TIME lives in
# tests/test_permission_queue.sh. The proof that the real macOS prompts appear
# one at a time in the right order is the clean-box BOX-WALK -- neither test can
# stand in for it.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
QUEUE_LIB="${REPO_ROOT}/lib/permission_queue.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ── 1. The queue lib exists and is sourced by install.sh ───────────────────
[[ -f "$QUEUE_LIB" ]] && pass "lib/permission_queue.sh present" \
    || fail "lib/permission_queue.sh missing"
grep -q 'permission_queue.sh' "$INSTALL_SH" \
    && pass "install.sh sources permission_queue.sh" \
    || fail "install.sh does not source permission_queue.sh"

# ── 2. Both daemon TCC detection probes are defined ────────────────────────
for fn in _imessage_daemon_fda_granted _imessage_daemon_automation_granted; do
    grep -q "^${fn}() {" "$INSTALL_SH" \
        && pass "probe ${fn} defined" \
        || fail "probe ${fn} missing"
done

# The Automation probe must query the AppleEvents service (the daemon's
# "control Messages" TCC scope), not the FDA service.
grep -q "kTCCServiceAppleEvents" "$INSTALL_SH" \
    && pass "automation probe queries kTCCServiceAppleEvents" \
    || fail "automation probe does not query kTCCServiceAppleEvents"

# ── 3. The queue runner is defined and CALLED ──────────────────────────────
grep -q '_ostler_run_daemon_permission_queue() {' "$INSTALL_SH" \
    && pass "_ostler_run_daemon_permission_queue defined" \
    || fail "_ostler_run_daemon_permission_queue not defined"
grep -q 'if _ostler_run_daemon_permission_queue; then' "$INSTALL_SH" \
    && pass "_ostler_run_daemon_permission_queue is called" \
    || fail "_ostler_run_daemon_permission_queue never called"

# ── 4. The queue is invoked BEFORE the legacy FDA assist modal ─────────────
# Detection-of-completion must run first; the legacy single-modal is the
# fallback only.
QUEUE_CALL_LINE=$(awk '/if _ostler_run_daemon_permission_queue; then/{print NR; exit}' "$INSTALL_SH")
LEGACY_MODAL_LINE=$(awk '/MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING/{print NR; exit}' "$INSTALL_SH")
if [[ -n "$QUEUE_CALL_LINE" && -n "$LEGACY_MODAL_LINE" && "$QUEUE_CALL_LINE" -lt "$LEGACY_MODAL_LINE" ]]; then
    pass "queue (line $QUEUE_CALL_LINE) runs before the legacy modal (line $LEGACY_MODAL_LINE)"
else
    fail "queue must run before the legacy modal (queue=$QUEUE_CALL_LINE legacy=$LEGACY_MODAL_LINE)"
fi

# ── 5. Legacy modal is guarded so it never double-shows ────────────────────
grep -q 'DAEMON_PERMS_SHOWN_EARLY' "$INSTALL_SH" \
    && pass "legacy modal guarded by DAEMON_PERMS_SHOWN_EARLY" \
    || fail "DAEMON_PERMS_SHOWN_EARLY guard missing"

# ── 6. The daemon-side FDA gate env is referenced (directive #3) ───────────
grep -q 'OSTLER_ASSISTANT_DEFER_TCC_UNTIL_FDA' "$INSTALL_SH" \
    && pass "install.sh references the daemon-side FDA gate (OSTLER_ASSISTANT_DEFER_TCC_UNTIL_FDA)" \
    || fail "daemon-side FDA gate not referenced"

# ── 7. New catalogue strings present (Rule 0.9: no literal English) ────────
for key in MSG_PROMPT_PERMQ_DONE_BUTTON \
           MSG_PROMPT_PERMQ_SKIP_BUTTON \
           MSG_PROMPT_ASSISTANT_AUTOMATION_TITLE \
           MSG_PROMPT_ASSISTANT_AUTOMATION_LINE1 \
           MSG_PROMPT_ASSISTANT_AUTOMATION_LINE2 \
           MSG_INFO_PERMQ_DAEMON_SUMMARY; do
    grep -q "^${key}=" "$STRINGS" || fail "catalogue missing $key"
done
[[ "$FAILED" -eq 0 ]] && pass "choreography-v2 catalogue strings present"

# ── 8. Syntax-clean ────────────────────────────────────────────────────────
bash -n "$INSTALL_SH" || fail "bash -n install.sh failed"
bash -n "$QUEUE_LIB" || fail "bash -n lib/permission_queue.sh failed"
[[ "$FAILED" -eq 0 ]] && pass "bash -n clean"

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
