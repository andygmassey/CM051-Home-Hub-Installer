#!/usr/bin/env bash
# test_data_step_background_handoff.sh -- BUG-037.
#
# The install-time conversation data-step used to run the FULL
# per-conversation LLM enrichment SYNCHRONOUSLY (~6 qwen calls x ~250
# conversations) = hours of blocking grind with a static bar, looking
# identical to a hung install. The Andy-agreed fix: a bounded LIGHT first
# pass so the installer reaches Pair-QR in seconds, then hand the rest of
# the backlog to the iMessage body-feed LaunchAgent (already installed) to
# drain over hours, surfaced by the wiki "still settling in" panel.
#
# Structural checks assert install.sh carries:
#   1. a --max-sessions cap on the synchronous iMessage pass,
#   2. a backgrounded pass + per-conversation heartbeat (no frozen bar),
#   3. a per-pass timeout (a stuck qwen call cannot hang the installer),
#   4. the "filling in over the next few hours" hand-off copy,
#   5. the hydration_progress.json seed for the ready-now channels,
# plus the locale strings exist.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
STRINGS_SH="${HERE}/../install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: light first pass is bounded =="
grep -q -- '--max-sessions "\$_CONV_MAX"' "$INSTALL_SH" \
    && ok "synchronous iMessage pass is capped with --max-sessions" \
    || bad "synchronous pass is not capped -- it would grind for hours"
grep -q 'OSTLER_DATA_STEP_MAX_CONVOS' "$INSTALL_SH" \
    && ok "cap is operator-overridable via OSTLER_DATA_STEP_MAX_CONVOS" \
    || bad "no OSTLER_DATA_STEP_MAX_CONVOS override"

echo "== structural: backgrounded + heartbeat (no frozen bar) =="
grep -q ') >"\$_CONV_LOG" 2>&1 &' "$INSTALL_SH" \
    && ok "conversation pass is backgrounded (& after the log redirect)" \
    || bad "conversation pass is not backgrounded -- heartbeat cannot run"
grep -q 'while kill -0 "\$_CONV_PID" 2>/dev/null; do' "$INSTALL_SH" \
    && ok "heartbeat loop polls the conversation pid with kill -0" \
    || bad "heartbeat poll loop missing"
grep -q 'MSG_INFO_DATA_STEP_CONV_HEARTBEAT' "$INSTALL_SH" \
    && ok "heartbeat emits a (locale-driven) liveness line" \
    || bad "heartbeat liveness call missing"
grep -q 'if wait "\$_CONV_PID"; then' "$INSTALL_SH" \
    && ok "child reaped via wait in an errexit-safe if-condition" \
    || bad "wait/reap of the conversation child missing"

echo "== structural: per-pass timeout =="
grep -q 'OSTLER_DATA_STEP_CONV_TIMEOUT' "$INSTALL_SH" \
    && grep -q 'kill "\$_CONV_PID"' "$INSTALL_SH" \
    && ok "a stuck pass is killed after the timeout (resumes in background)" \
    || bad "no per-pass timeout -- a stuck qwen call could hang the install"

echo "== structural: hand-off copy + progress seed =="
grep -q 'MSG_INFO_DATA_STEP_CONV_BACKGROUND' "$INSTALL_SH" \
    && ok "installer tells the user the rest fills in in the background" \
    || bad "no background hand-off message"
grep -q 'hydration_progress.json' "$INSTALL_SH" \
    && grep -q 'OSTLER_HYDRATION_PROGRESS_FILE' "$INSTALL_SH" \
    && ok "data-step seeds the per-channel hydration_progress.json signal" \
    || bad "hydration_progress.json seed missing"

echo "== strings: BUG-037 copy is present + plain (no jargon) =="
grep -q 'MSG_INFO_DATA_STEP_CONV_BACKGROUND=' "$STRINGS_SH" \
    && grep -q 'MSG_INFO_DATA_STEP_CONV_HEARTBEAT=' "$STRINGS_SH" \
    && grep -q 'MSG_WARN_DATA_STEP_CONV_TIMEOUT=' "$STRINGS_SH" \
    && ok "new data-step strings defined in en-GB catalogue" \
    || bad "new data-step strings missing from en-GB catalogue"

echo "== bash -n parses clean =="
bash -n "$INSTALL_SH" && ok "install.sh parses" || bad "install.sh syntax error"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
