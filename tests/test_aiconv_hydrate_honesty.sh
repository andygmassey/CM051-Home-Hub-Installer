#!/usr/bin/env bash
# AI-Conversations hydrate honesty guard (w7-aiconv-honesty)
# ==========================================================
#
# Behavioural test: extracts the real AI-Conversations leg from
# install.sh and EXECUTES it against a fake producer, asserting the
# two honesty fixes hold:
#
#   Defect 1 (sentinel): the 7-day hydrate sentinel must be recorded
#   ONLY when the drain completes (rc 0). A timed-out (124/137) or
#   crashed (any other non-zero rc) drain must NOT record it, so the
#   next install/re-run retries instead of skipping for a week.
#
#   Defect 2 (false promise): MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES
#   says "still loading in the background". That is only honest if a
#   background agent actually exists. The timed-out arm must install
#   and load the self-removing com.ostler.aiconv-resume LaunchAgent
#   (wrapper + plist + launchctl) BEFORE emitting the message, and
#   must fall back to the not-ready message if the agent fails to
#   load.
#
#   The generated resume wrapper itself is also exercised: on a
#   successful resumed drain it writes the sentinel and removes its
#   own agent; on a failed drain it leaves the agent loaded for the
#   next hourly tick; once the sentinel exists it self-removes
#   without invoking the producer.
#
# Scenarios (each runs the REAL leg text, not a copy):
#   A. producer exits 124 (timeout)  -> no sentinel record, agent
#      installed + bootstrapped, TOKEN_BG_CONTINUES emitted
#   B. producer succeeds written=3   -> sentinel written=3, DONE
#      message, NO agent installed
#   C. producer exits 1 (crash)      -> no sentinel, no agent,
#      not-ready message
#   D. producer succeeds written=0   -> sentinel written=0, no-data
#      message, no agent
#   E. resume wrapper (generated in A): success -> sentinel file +
#      self-removal; re-run with sentinel present -> producer NOT
#      invoked again
#   F. resume wrapper: producer crash -> no sentinel, plist kept
#   G. timed-out arm with launchctl refusing to load -> not-ready
#      message instead of the background promise, still no sentinel

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

FAILURES=0
CHECKS=0
fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}
check() {
    # check <description> <command...>
    local desc="$1"; shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then
        echo "ok: $desc"
    else
        fail "$desc"
    fi
}

WORK="$(mktemp -d -t aiconv-honesty.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extract the real leg from install.sh (assignment line through the
# trailing disabled-path comment) and syntax-check the fragment.
# ---------------------------------------------------------------------------
LEG_FILE="$WORK/aiconv_leg.sh"
sed -n '/^OSTLER_AI_CONVERSATIONS_ENABLED=/,/^# (disabled path/p' "$INSTALL" > "$LEG_FILE"

check "leg extraction is non-trivial (>100 lines)" \
    test "$(wc -l < "$LEG_FILE")" -gt 100
check "extracted leg parses standalone (bash -n)" \
    bash -n "$LEG_FILE"
check "extracted leg contains the resume-agent heredoc" \
    grep -q "AICONVRESUME" "$LEG_FILE"

# ---------------------------------------------------------------------------
# Scenario harness
# ---------------------------------------------------------------------------
# new_scenario <name>: builds an isolated tree with a stub launchctl,
# a fake pwg-ai-convo producer, and a runner that sources the leg
# with install.sh's helpers stubbed to capture behaviour.
new_scenario() {
    local name="$1"
    SCEN="$WORK/$name"
    export SCEN
    export OSTLER_DIR="$SCEN/ostler"
    export HOME_DIR="$SCEN/home"
    export LOGS_DIR="$OSTLER_DIR/logs"
    export _HYDRATE_SENTINEL_DIR="$OSTLER_DIR/state/hydrate"
    export SCRIPT_DIR="$SCEN/app"
    export MSGLOG="$SCEN/messages.log"
    export SENTLOG="$SCEN/sentinel-calls.log"
    export PRODUCER_LOG="$SCEN/producer-calls.log"
    export LAUNCHCTL_LOG="$SCEN/launchctl.log"
    export LEG_FILE
    export USER_EMAIL="operator@example.invalid"

    SHIM="$SCEN/shim"
    VENV_BIN_DIR="$OSTLER_DIR/services/cm052/.venv/bin"
    FAKE_BIN="$VENV_BIN_DIR/pwg-ai-convo"
    RESUME_BIN="$OSTLER_DIR/bin/ostler-aiconv-resume"
    RESUME_PLIST="$HOME_DIR/Library/LaunchAgents/com.ostler.aiconv-resume.plist"
    SENTINEL_FILE="$_HYDRATE_SENTINEL_DIR/ai_conversations.done"

    mkdir -p "$OSTLER_DIR" "$HOME_DIR" "$LOGS_DIR" "$_HYDRATE_SENTINEL_DIR" \
             "$SCRIPT_DIR/cm052_ai_conversations" "$SHIM" "$VENV_BIN_DIR"
    touch "$SCRIPT_DIR/cm052_ai_conversations/pyproject.toml"
    : > "$MSGLOG"; : > "$SENTLOG"; : > "$PRODUCER_LOG"; : > "$LAUNCHCTL_LOG"

    # Stub launchctl: logs every call; LAUNCHCTL_FAIL=1 makes
    # bootstrap AND load fail (scenario G).
    cat > "$SHIM/launchctl" <<'SHIMEOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LAUNCHCTL_LOG"
if [ "${LAUNCHCTL_FAIL:-0}" = "1" ]; then
    case "${1:-}" in
        bootstrap|load) exit 1 ;;
    esac
fi
exit 0
SHIMEOF
    chmod 0755 "$SHIM/launchctl"

    # Fake producer honouring the v1.0.3 counts-only contract.
    cat > "$FAKE_BIN" <<'FAKEEOF'
#!/usr/bin/env bash
echo "CALL $*" >> "$PRODUCER_LOG"
case "${FAKE_PRODUCER_MODE:?}" in
    timeout)   exit 124 ;;
    crash)     exit 1 ;;
    success)   echo '{"discovered": 3, "written": 3}' ;;
    nodata)    echo '{"discovered": 0, "written": 0}' ;;
    resume_ok) echo '{"discovered": 5, "written": 5}' ;;
esac
exit 0
FAKEEOF
    chmod 0755 "$FAKE_BIN"

    # Runner: install.sh helper stubs + tokenised MSG_* vars, then
    # sources the extracted leg verbatim.
    cat > "$SCEN/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
set -uo pipefail
HOME="$HOME_DIR"
info() { printf 'INFO:%s\n' "$*" >> "$MSGLOG"; }
ok()   { printf 'OK:%s\n'   "$*" >> "$MSGLOG"; }
warn() { printf 'WARN:%s\n' "$*" >> "$MSGLOG"; }
_hydrate_heartbeat_start() { :; }
_hydrate_heartbeat_stop()  { :; }
_hydrate_sentinel_fresh()  { return 1; }
_hydrate_sentinel_record() { printf 'RECORD:%s:%s\n' "$1" "${2:-}" >> "$SENTLOG"; }
MSG_HYDRATE_AICONV_STARTED="TOKEN_STARTED"
MSG_HYDRATE_AICONV_DONE="TOKEN_DONE_%s"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="TOKEN_NOT_READY"
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="TOKEN_NO_DATA"
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="TOKEN_BG_CONTINUES"
MSG_HYDRATE_AICONV_HEARTBEAT="TOKEN_HEARTBEAT_%s"
PYTHON3_BIN="python3"
OSTLER_AI_CONVERSATIONS_ENABLED="true"
source "$LEG_FILE"
RUNNEREOF
    chmod 0755 "$SCEN/runner.sh"
}

run_leg() {
    # run_leg <producer-mode> [extra VAR=val ...]
    local mode="$1"; shift
    env "$@" FAKE_PRODUCER_MODE="$mode" PATH="$SHIM:$PATH" \
        bash "$SCEN/runner.sh"
}

run_wrapper() {
    # run_wrapper <producer-mode>
    local mode="$1"
    env FAKE_PRODUCER_MODE="$mode" PATH="$SHIM:$PATH" \
        bash "$RESUME_BIN"
}

# ---------------------------------------------------------------------------
# Scenario A: timeout (rc 124)
# ---------------------------------------------------------------------------
echo "--- scenario A: producer times out (rc 124) ---"
new_scenario A
check "A: leg exits 0 on timeout" run_leg timeout
check "A: producer was invoked with the v1.0.3 contract flags" \
    grep -q -- "CALL --source all --since-days 365 --json" "$PRODUCER_LOG"
check "A: sentinel NOT recorded on timeout (retry next run)" \
    test ! -s "$SENTLOG"
check "A: background-continues message emitted" \
    grep -q "INFO:TOKEN_BG_CONTINUES" "$MSGLOG"
check "A: resume wrapper generated and executable" \
    test -x "$RESUME_BIN"
check "A: resume LaunchAgent plist written" \
    test -f "$RESUME_PLIST"
check "A: plist carries the hourly StartInterval" \
    grep -q "<integer>3600</integer>" "$RESUME_PLIST"
check "A: plist points at the generated wrapper" \
    grep -q "<string>$RESUME_BIN</string>" "$RESUME_PLIST"
check "A: agent bootstrapped (or loaded) via launchctl" \
    grep -Eq "launchctl (bootstrap|load) .*com\.ostler\.aiconv-resume" "$LAUNCHCTL_LOG"
check "A: wrapper drains with the v1.0.3 contract flags" \
    grep -q -- "--source all --since-days 365 --json" "$RESUME_BIN"
check "A: wrapper parses standalone (bash -n)" \
    bash -n "$RESUME_BIN"

# ---------------------------------------------------------------------------
# Scenario E (continues in A's tree): the generated resume wrapper
# ---------------------------------------------------------------------------
echo "--- scenario E: resume wrapper completes the drain ---"
check "E: wrapper exits 0 on a successful resumed drain" \
    run_wrapper resume_ok
check "E: wrapper recorded the sentinel file" \
    test -f "$SENTINEL_FILE"
check "E: sentinel payload carries the resumed count" \
    grep -q "payload=written=5" "$SENTINEL_FILE"
check "E: sentinel names the ai_conversations source" \
    grep -q "source=ai_conversations" "$SENTINEL_FILE"
check "E: wrapper removed its own plist after completing" \
    test ! -f "$RESUME_PLIST"
check "E: wrapper booted its own agent out" \
    grep -q "launchctl bootout gui/$(id -u)/com.ostler.aiconv-resume" "$LAUNCHCTL_LOG"

PRODUCER_CALLS_BEFORE="$(grep -c '^CALL' "$PRODUCER_LOG")"
check "E: wrapper re-run with sentinel present exits 0" \
    run_wrapper resume_ok
check "E: producer NOT re-invoked once sentinel exists" \
    test "$(grep -c '^CALL' "$PRODUCER_LOG")" -eq "$PRODUCER_CALLS_BEFORE"

# ---------------------------------------------------------------------------
# Scenario B: success (written=3)
# ---------------------------------------------------------------------------
echo "--- scenario B: producer succeeds with written=3 ---"
new_scenario B
check "B: leg exits 0 on success" run_leg success
check "B: sentinel recorded exactly once" \
    test "$(grep -c '^RECORD' "$SENTLOG")" -eq 1
check "B: sentinel payload is written=3" \
    grep -q "RECORD:ai_conversations:written=3" "$SENTLOG"
check "B: done message emitted with the count" \
    grep -q "OK:TOKEN_DONE_3" "$MSGLOG"
check "B: no resume agent installed on success" \
    test ! -e "$RESUME_BIN" -a ! -e "$RESUME_PLIST"

# ---------------------------------------------------------------------------
# Scenario C: crash (rc 1, not a timeout)
# ---------------------------------------------------------------------------
echo "--- scenario C: producer crashes (rc 1) ---"
new_scenario C
check "C: leg exits 0 on producer crash" run_leg crash
check "C: sentinel NOT recorded on crash (retry next run)" \
    test ! -s "$SENTLOG"
check "C: not-ready message emitted (no false background promise)" \
    grep -q "INFO:TOKEN_NOT_READY" "$MSGLOG"
check "C: background-continues NOT emitted on crash" \
    bash -c '! grep -q "TOKEN_BG_CONTINUES" "$MSGLOG"'
check "C: no resume agent installed on crash" \
    test ! -e "$RESUME_BIN" -a ! -e "$RESUME_PLIST"

# ---------------------------------------------------------------------------
# Scenario D: clean zero-count run
# ---------------------------------------------------------------------------
echo "--- scenario D: producer succeeds with written=0 ---"
new_scenario D
check "D: leg exits 0 on clean empty drain" run_leg nodata
check "D: sentinel recorded for a completed zero-count drain" \
    grep -q "RECORD:ai_conversations:written=0" "$SENTLOG"
check "D: no-data message emitted" \
    grep -q "INFO:TOKEN_NO_DATA" "$MSGLOG"
check "D: no resume agent installed on clean empty drain" \
    test ! -e "$RESUME_BIN" -a ! -e "$RESUME_PLIST"

# ---------------------------------------------------------------------------
# Scenario F: resume wrapper drain fails -> agent stays for next tick
# ---------------------------------------------------------------------------
echo "--- scenario F: resume wrapper drain fails ---"
new_scenario F
run_leg timeout >/dev/null 2>&1 || true   # generate wrapper + plist
check "F precondition: wrapper + plist exist after timeout" \
    test -x "$RESUME_BIN" -a -f "$RESUME_PLIST"
check "F: wrapper exits 0 on failed resumed drain" \
    run_wrapper crash
check "F: no sentinel after failed resumed drain" \
    test ! -f "$SENTINEL_FILE"
check "F: plist kept so launchd retries next hour" \
    test -f "$RESUME_PLIST"

# ---------------------------------------------------------------------------
# Scenario G: timeout but the agent cannot be loaded
# ---------------------------------------------------------------------------
echo "--- scenario G: timeout with launchctl refusing to load ---"
new_scenario G
check "G: leg exits 0 when agent fails to load" \
    run_leg timeout LAUNCHCTL_FAIL=1
check "G: background promise NOT made when no agent is running" \
    bash -c '! grep -q "TOKEN_BG_CONTINUES" "$MSGLOG"'
check "G: not-ready message emitted instead" \
    grep -q "INFO:TOKEN_NOT_READY" "$MSGLOG"
check "G: still no sentinel (retry next run)" \
    test ! -s "$SENTLOG"

# ---------------------------------------------------------------------------
# Structural belt-and-braces on the shipped install.sh
# ---------------------------------------------------------------------------
echo "--- structural checks on install.sh ---"
check "install.sh parses (bash -n)" bash -n "$INSTALL"
check "uninstall cleanup unloads com.ostler.aiconv-resume" \
    grep -q "com.ostler.aiconv-resume" <(sed -n '/Stopping services/,/ostler-remotecapture/p' "$INSTALL")

echo ""
echo "checks run: $CHECKS, failures: $FAILURES"
if [ "$FAILURES" -gt 0 ]; then
    echo "aiconv hydrate honesty guard: FAIL" >&2
    exit 1
fi
echo "aiconv hydrate honesty guard: PASS"
