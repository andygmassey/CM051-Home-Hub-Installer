#!/usr/bin/env bash
#
# test_container_engine_liveness_and_recovery.sh
#
# ══════════════════════════════════════════════════════════════════════
# THE DEFECT, MEASURED ON A LIVE BOX 2026-08-23
# ══════════════════════════════════════════════════════════════════════
#
# Andrews-Mac-mini, read over SSH while this test was written, and left
# UNREPAIRED so the state could be measured:
#
#     /opt/homebrew/bin/colima     PRESENT     (installed 21 Aug 19:43)
#     /opt/homebrew/bin/docker     PRESENT
#     /opt/homebrew/bin/limactl    PRESENT
#     /Applications/Docker.app     ABSENT
#     pgrep -f 'limactl|qemu'      0
#     docker info                  rc=1, socket does not exist
#     colima status                "colima is not running"
#     :8044 -> 000   :7878 -> 000  (docker-hosted)
#     :8000 -> 200   :8089 -> 302  (native launchd -- THE CONTROL)
#
# The engine was INSTALLED AND STOPPED. Jetsam killed the Colima VM after
# the installer's unbounded output buffer took the machine to 4.27 GB
# (eight JetsamEvent reports, 16:10 to 17:33). Uptime was 2 days: no reboot
# was involved, the engine died mid-life.
#
# TWO THINGS THAT MUST NEVER RECUR, AND BOTH ARE ASSERTED HERE:
#
# 1. ASKING THE WRONG QUESTION. "Is a runtime installed" returns HEALTHY on
#    that box while the wiki is dark. An earlier diagnosis of this same box
#    said "no container engine installed" -- measured in a shell with no
#    Homebrew on PATH, where every binary was present and simply not found.
#    The classifier must resolve absolute paths and must ask whether a
#    container can RUN.
#
# 2. A SUPERVISOR THAT RUNS ONCE AT LAUNCH. ensure_colima_running() is
#    called once at daemon startup. The daemon's own log carries six colima
#    lines, three start/success pairs, the last at 2026-08-22T09:57:58Z --
#    two seconds after it booted, ~31 hours before the kill. It has
#    `last exit code = (never exited)` since. The only periodic job that
#    touches the runtime is wiki-recompile, whose plist on that box reads
#    StartInterval = 86400. Once a DAY. A daily tick is exactly a day of
#    latency, which is exactly how long the wiki was dark.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
LIB="${REPO_ROOT}/lib/ostler-container-engine.sh"
SUP="${REPO_ROOT}/bin/ostler-engine-supervisor.sh"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0
FAIL=0
cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  Nothing was checked. This is not a passing gate." >&2
    exit 2
}
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]]        || cannot_run "lib/ostler-container-engine.sh not found at ${LIB}"
[[ -f "$SUP" ]]        || cannot_run "bin/ostler-engine-supervisor.sh not found at ${SUP}"
[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at ${INSTALL_SH}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-engine-gate.XXXXXX")" || cannot_run "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

# ── stub factory: build a fake /opt/homebrew-alike prefix ────────────
# The classifier resolves ${OSTLER_ENGINE_BREW_PREFIX}/bin first, so the
# whole four-state matrix can be driven without a real engine.
make_prefix() {
    # make_prefix <name> <have_docker:0|1> <have_colima:0|1> <info_rc> <wiki_state>
    local dir="${WORK}/$1/bin"
    rm -rf "${WORK}/$1"; mkdir -p "$dir"
    if [[ "$2" == "1" ]]; then
        cat > "${dir}/docker" <<STUB
#!/bin/bash
case "\$1" in
  info)
    if [ "$4" -eq 0 ]; then echo "Server Version: 27.0.0"; exit 0; fi
    echo "failed to connect to the docker API at unix:///x/docker.sock" >&2
    exit $4 ;;
  ps)
    [ "$4" -eq 0 ] || exit 1
    printf '%s\n' "$5" ; exit 0 ;;
  start) exit 0 ;;
esac
exit 0
STUB
        chmod +x "${dir}/docker"
    fi
    if [[ "$3" == "1" ]]; then
        printf '#!/bin/bash\nexit 0\n' > "${dir}/colima"
        chmod +x "${dir}/colima"
    fi
    printf '%s' "${WORK}/$1"
}

classify() {
    # classify <prefix> -> prints "state|rc"
    #
    # BOTH prefixes are pointed at the stub. This runner is a developer Mac
    # that really does have Docker Desktop symlinked into /usr/local/bin, so
    # without the second override the "absent" case would find the real
    # client and the matrix would silently lose a state.
    local out rc
    out="$(OSTLER_ENGINE_BREW_PREFIX="$1" OSTLER_ENGINE_ALT_PREFIX="$1" \
           OSTLER_ENGINE_DESKTOP_PATH="${WORK}/no-such-Docker.app" \
           OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 \
           PATH="/usr/bin:/bin" /bin/bash "$LIB" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$(sed -n 's/^state=//p' <<<"$out")" "$rc"
}

# ── 1. ALL FOUR STATES MUST BE DISTINGUISHABLE ──────────────────────
# Three of them look identical to a naive probe. Each assertion below is
# the control for the others: if any two collapse to the same answer, the
# matrix has a hole and the box that bit us is back in it.

p_absent="$(make_prefix absent 0 0 1 '')"
r="$(classify "$p_absent")"
if [[ "$r" == "absent|1" ]]; then
    pass "state 1/4 ABSENT: nothing installed -> absent, rc=1"
else
    failure "nothing installed classified as '${r}', expected 'absent|1'"
fi

p_stopped="$(make_prefix stopped 1 1 1 '')"
r="$(classify "$p_stopped")"
if [[ "$r" == "installed_stopped|1" ]]; then
    pass "state 2/4 INSTALLED_STOPPED: colima+docker present, docker info fails -> installed_stopped, rc=1 (THE MEASURED STATE)"
else
    failure "THE MEASURED STATE misclassified as '${r}', expected 'installed_stopped|1'. This is the exact shape that shipped a green install onto a dark box."
fi

p_nowiki="$(make_prefix nowiki 1 1 0 'exited')"
r="$(classify "$p_nowiki")"
if [[ "$r" == "running_no_wiki|1" ]]; then
    pass "state 3/4 RUNNING_NO_WIKI: engine answers, container down -> running_no_wiki, rc=1"
else
    failure "engine-up/container-down classified as '${r}', expected 'running_no_wiki|1'"
fi

p_up="$(make_prefix up 1 1 0 'running')"
r="$(classify "$p_up")"
if [[ "$r" == "up|0" ]]; then
    pass "state 4/4 UP: engine answers, container running -> up, rc=0"
else
    failure "a fully healthy box classified as '${r}', expected 'up|0'. A classifier that never says 'up' is an alarm, not a check."
fi

# ── 2. THE PATH TRAP THAT PRODUCED A WRONG DIAGNOSIS ────────────────
# A launchd agent's PATH has no /opt/homebrew/bin. The first read of the
# walk box was taken in exactly such a shell and reported "no container
# engine installed" when everything was installed. The classifier must
# resolve absolute paths itself.
if grep -q 'OSTLER_ENGINE_BREW_PREFIX' "$LIB" && grep -q 'OSTLER_ENGINE_ALT_PREFIX' "$LIB"; then
    pass "the classifier resolves both Homebrew prefixes itself, rather than trusting PATH"
else
    failure "the classifier depends on PATH; under launchd it would report ABSENT on a fully-installed box"
fi
# And prove it: the stopped prefix must still classify correctly with an
# EMPTY PATH.
#
# /bin/bash by ABSOLUTE PATH is load-bearing. The first version of this
# control wrote `bash "$LIB"`, and with PATH="" the harness could not find
# bash at all -- rc=127, no output, and the check reported "the classifier
# lost the engine". That is "nothing looked at" printing exactly like
# "nothing found", inside the very test written to catch a PATH defect.
out="$(OSTLER_ENGINE_BREW_PREFIX="$p_stopped" OSTLER_ENGINE_ALT_PREFIX="$p_stopped" \
       OSTLER_ENGINE_DESKTOP_PATH="${WORK}/no-such-Docker.app" \
       OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 \
       PATH="" /bin/bash "$LIB" 2>/dev/null)"
if grep -q 'state=installed_stopped' <<<"$out"; then
    pass "with an EMPTY PATH the classifier still reports installed_stopped, not absent"
else
    failure "with an empty PATH the classifier lost the engine: ${out}"
fi

# ── 3. THE RECOVERY PATH MUST EXIST AND MUST FIRE ───────────────────
# A card that says "your wiki is down" and cannot bring it back is a nicer
# version of the same outage.
run_sup() {
    # run_sup <prefix> <kickstart_cmd> -> rc; output in $WORK/sup.out
    OSTLER_ENGINE_BREW_PREFIX="$1" \
    OSTLER_ENGINE_ALT_PREFIX="$1" \
    OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 \
    OSTLER_ENGINE_DESKTOP_PATH="${WORK}/no-such-Docker.app" \
    OSTLER_STATE_DIR="${WORK}/state" \
    OSTLER_LOGS_DIR="${WORK}/logs" \
    OSTLER_DIR="${WORK}/ostler" \
    OSTLER_ENGINE_KICKSTART_CMD="$2" \
    OSTLER_ENGINE_RECOVERY_SETTLE_S=5 \
    OSTLER_ENGINE_RECOVERY_COOLDOWN_S=0 \
    PATH="/usr/bin:/bin" \
        bash "$SUP" >"${WORK}/sup.out" 2>&1
    return $?
}

rm -rf "${WORK}/state" "${WORK}/logs"
run_sup "$p_stopped" "echo KICKSTART_CALLED; exit 0"; rc=$?
if grep -q 'KICKSTART_CALLED' "${WORK}/sup.out"; then
    pass "on installed_stopped the supervisor ATTEMPTS recovery (it did not merely report)"
else
    failure "the supervisor never attempted recovery on the measured state: $(cat "${WORK}/sup.out")"
fi
if [[ "$rc" -eq 1 ]]; then
    pass "recovery that did not bring the engine back exits 1, not 0"
else
    failure "the supervisor exited ${rc} after a failed recovery; a persisting outage must not read as success"
fi

# NEGATIVE CONTROL: a healthy box must NOT be restarted. A supervisor that
# kickstarts the daemon on every tick is a worse outage than the one it
# was built for.
rm -rf "${WORK}/state" "${WORK}/logs"
run_sup "$p_up" "echo KICKSTART_CALLED; exit 0"; rc=$?
if grep -q 'KICKSTART_CALLED' "${WORK}/sup.out"; then
    failure "NEGATIVE CONTROL FAILED: the supervisor restarted the daemon on a HEALTHY box"
elif [[ "$rc" -eq 0 ]]; then
    pass "negative control: a healthy box triggers no restart and exits 0"
else
    failure "a healthy box exited ${rc}"
fi

# The recovery must go through the FDA holder, NOT `colima start` directly.
# install.sh deleted the bare com.ostler.colima LaunchAgent precisely
# because a launchd agent has no FDA and Colima then cannot mount
# ~/Documents, killing the wiki's bind-mount on every reboot.
SUP_CODE="${WORK}/sup.code.sh"
sed 's/#.*//' "$SUP" > "$SUP_CODE"
if grep -q 'launchctl kickstart -k' "$SUP_CODE"; then
    pass "recovery restarts the FDA-holding daemon via launchctl kickstart -k"
else
    failure "no 'launchctl kickstart -k' in the supervisor; recovery would not re-run ensure_colima_running()"
fi
if grep -qE '(^|[^-])colima[[:space:]]+start' "$SUP_CODE"; then
    failure "the supervisor runs 'colima start' itself. A launchd agent has NO Full Disk Access, so Colima cannot mount ~/Documents and the wiki bind-mount fails -- that is the bug the bare com.ostler.colima agent was deleted to fix."
else
    pass "the supervisor never runs 'colima start' itself, so it cannot reintroduce the FDA-less start"
fi

# Thrash guard: a supervisor with no attempt budget is a second outage.
if grep -q 'RECOVERY_MAX_ATTEMPTS' "$SUP_CODE" && grep -q 'RECOVERY_COOLDOWN_S' "$SUP_CODE"; then
    pass "recovery is rationed by both an attempt budget and a cooldown"
else
    failure "the supervisor has no attempt budget or no cooldown; it would restart the daemon forever"
fi

# ── 4. IT MUST BE PERIODIC, AND FASTER THAN THE THING THAT FAILED ───
# wiki-recompile on the walk box: StartInterval = 86400. That is the
# latency that produced "dead for about a day".
CODE="${WORK}/install.code.sh"
sed 's/#.*//' "$INSTALL_SH" > "$CODE"
if grep -q 'com.ostler.engine-supervisor' "$CODE"; then
    pass "install.sh schedules com.ostler.engine-supervisor"
else
    failure "install.sh does not schedule any engine supervisor; nothing would check the runtime between daemon restarts"
fi
SUP_INTERVAL="$(grep -A2 'com.ostler.engine-supervisor' "$CODE" | grep -A1 StartInterval | grep -oE '[0-9]+' | head -1)"
if [[ -z "${SUP_INTERVAL:-}" ]]; then
    SUP_INTERVAL="$(awk '/engine-supervisor/,/\/plist/' "$CODE" | grep -A1 'StartInterval' | grep -oE '^ *<integer>[0-9]+' | grep -oE '[0-9]+' | head -1)"
fi
if [[ -n "${SUP_INTERVAL:-}" ]] && (( SUP_INTERVAL > 0 && SUP_INTERVAL <= 900 )); then
    pass "the supervisor ticks every ${SUP_INTERVAL}s (the job that failed us ticked every 86400s)"
else
    failure "the supervisor's StartInterval is '${SUP_INTERVAL:-unset}'; it must be a positive value at most 900s, or it reproduces the day-long latency"
fi

# ── 5. anti-vacuity ─────────────────────────────────────────────────
DOCTORED="${WORK}/doctored.sh"
printf 'colima start\n' > "$DOCTORED"
if grep -qE '(^|[^-])colima[[:space:]]+start' "$DOCTORED"; then
    pass "anti-vacuity: the FDA-less-start predicate fires on a file that contains it"
else
    failure "anti-vacuity: the FDA-less-start predicate cannot match even a file containing 'colima start'"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
