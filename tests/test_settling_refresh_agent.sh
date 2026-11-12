#!/usr/bin/env bash
#
# test_settling_refresh_agent.sh
#
# The setup status screen reads settling.json, which the daily full wiki
# compile (hours long) used to be the only writer of. The settling-refresh
# LaunchAgent runs the CM044 `--settling-only` mode every 15 minutes.
#
# Proves, with stubbed launchctl/docker and a temp HOME (no real launchd, no
# real keychain, no real docker):
#   1. INSTALL_SNIPPET.sh renders the plist with StartInterval 900 and the
#      label, loads it with bootout then bootstrap, and stages the tick.
#   2. The tick runs exactly the contract command through docker compose.
#   3. A held wiki-recompile lock, or a held own lock, makes the tick skip
#      with exit 0 and NOT call docker. Controls: no lock calls docker; a
#      stale lock (dead pid) is reclaimed and docker is called.
#   4. A failing compile propagates its exit code (not swallowed).
#   5. The uninstaller's declared label list names the agent.
#
# SETTLING_TEST_ROOT overrides the tree under test (used to show RED on main).
set -uo pipefail

REPO_ROOT="${SETTLING_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SNIPPET="$REPO_ROOT/wiki-recompile/INSTALL_SNIPPET.sh"
LABEL="com.creativemachines.ostler.settling-refresh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
sleeper=""
cleanup() { [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

H="$TMP/home"; STUB="$TMP/stub"; mkdir -p "$H" "$STUB"
cat > "$STUB/launchctl" <<'S'
#!/bin/bash
echo "launchctl $*" >> "$STUB_LOG"
exit 0
S
cat > "$STUB/docker" <<'S'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
exit "${STUB_DOCKER_RC:-0}"
S
chmod +x "$STUB/launchctl" "$STUB/docker"
export STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"

printf '== test_settling_refresh_agent ==\n'

# ── 1. install ───────────────────────────────────────────────────────────────
HOME="$H" PATH="$STUB:$PATH" OSTLER_DIR="$H/.ostler" OSTLER_INSTALL_ROOT="$REPO_ROOT/wiki-recompile" \
    LOGS_DIR="$H/.ostler/logs" bash "$SNIPPET" >"$TMP/install.out" 2>&1
PLIST="$H/Library/LaunchAgents/$LABEL.plist"
# plistlib, not plutil: this test also runs on the ubuntu runner.
plist_get() {  # plist_get <file> <python expr over d>
    python3 -I -c 'import plistlib,sys;d=plistlib.load(open(sys.argv[1],"rb"));print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}
if [ -f "$PLIST" ]; then ok "install renders $LABEL.plist"; else bad "install did not render $PLIST"; fi
if [ -f "$PLIST" ] && [ "$(plist_get "$PLIST" "d['StartInterval']")" = "900" ]; then
    ok "plist StartInterval is 900"
else bad "plist StartInterval is not 900"; fi
if [ -f "$PLIST" ] && [ "$(plist_get "$PLIST" "d['ProgramArguments'][1]")" = "$H/.ostler/bin/settling-refresh-tick.sh" ]; then
    ok "plist runs the staged tick by absolute path"
else bad "plist ProgramArguments does not name the staged tick"; fi
if [ -f "$PLIST" ] && [ "$(plist_get "$PLIST" "d['RunAtLoad']")" = "True" ]; then
    ok "plist RunAtLoad is true (one tick at install bootstrap, so settling.json exists before the screens open)"
else bad "plist RunAtLoad is not true"; fi
if [ -f "$PLIST" ] && ! /usr/bin/grep -q 'OSTLER_\(BIN\|HOME\|LOGS\)' "$PLIST"; then
    ok "no unrendered placeholder left in the plist"
else bad "unrendered placeholder (or no plist)"; fi
if /usr/bin/grep -q "launchctl bootout .*/$LABEL" "$STUB_LOG" && /usr/bin/grep -q "launchctl bootstrap .* $PLIST" "$STUB_LOG"; then
    ok "install boots out then bootstraps the agent"
else bad "launchctl bootout/bootstrap for $LABEL not seen"; fi
TICK="$H/.ostler/bin/settling-refresh-tick.sh"
[ -x "$TICK" ] && ok "tick staged executable" || bad "tick not staged at $TICK"

# ── 2..4. the tick ───────────────────────────────────────────────────────────
run_tick() {  # prints exit code
    : > "$STUB_LOG"
    HOME="$H" PATH="$STUB:$PATH" OSTLER_DIR="$H/.ostler" bash "$TICK" >"$TMP/tick.out" 2>&1
    echo $?
}
docker_calls() { /usr/bin/grep -c '^docker ' "$STUB_LOG" || true; }
mkdir -p "$H/.ostler"

if [ -x "$TICK" ]; then
    rc="$(run_tick)"
    if [ "$rc" = 0 ] && /usr/bin/grep -q '^docker compose --profile compile run --rm -T wiki-compiler python -m compiler.compile --settling-only$' "$STUB_LOG"; then
        ok "CONTROL: no lock -> runs exactly the contract command, exit 0"
    else bad "CONTROL: expected the contract command, got rc=$rc: $(cat "$STUB_LOG")"; fi

    sleep 300 & sleeper=$!
    mkdir -p "$H/.ostler/.wiki-recompile.lock"; echo "$sleeper" > "$H/.ostler/.wiki-recompile.lock/pid"
    rc="$(run_tick)"
    if [ "$rc" = 0 ] && [ "$(docker_calls)" = 0 ] && /usr/bin/grep -q 'skipping' "$TMP/tick.out"; then
        ok "held wiki-recompile lock -> skip, exit 0, logged, docker not called"
    else bad "held wiki-recompile lock: rc=$rc docker_calls=$(docker_calls)"; fi
    rm -rf "$H/.ostler/.wiki-recompile.lock"

    mkdir -p "$H/.ostler/.settling-refresh.lock"; echo "$sleeper" > "$H/.ostler/.settling-refresh.lock/pid"
    rc="$(run_tick)"
    if [ "$rc" = 0 ] && [ "$(docker_calls)" = 0 ] && /usr/bin/grep -q 'skipping' "$TMP/tick.out"; then
        ok "held own lock (no overlap with itself) -> skip, exit 0, docker not called"
    else bad "held own lock: rc=$rc docker_calls=$(docker_calls)"; fi
    rm -rf "$H/.ostler/.settling-refresh.lock"

    kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; dead="$sleeper"; sleeper=""
    mkdir -p "$H/.ostler/.settling-refresh.lock"; echo "$dead" > "$H/.ostler/.settling-refresh.lock/pid"
    rc="$(run_tick)"
    if [ "$rc" = 0 ] && [ "$(docker_calls)" = 1 ]; then
        ok "CONTROL: stale lock (dead pid) is reclaimed and the compile runs"
    else bad "stale lock: rc=$rc docker_calls=$(docker_calls)"; fi

    rc="$(STUB_DOCKER_RC=7 run_tick)"
    if [ "$rc" = 7 ]; then ok "a failing compile propagates its exit code (7)"; else bad "failing compile exit was $rc, not 7"; fi
    [ ! -d "$H/.ostler/.settling-refresh.lock" ] && ok "lock released after a failed run" || bad "lock left behind after a failed run"
else
    bad "no tick to run: lock and command checks cannot run"
fi

# ── 5. uninstall list ────────────────────────────────────────────────────────
if awk '/OSTLER_LAUNCHAGENT_LABELS=\(/{p=1} p&&/^\)/{exit} p' "$REPO_ROOT/install.sh" | /usr/bin/grep -qx "[[:space:]]*$LABEL"; then
    ok "uninstaller's OSTLER_LAUNCHAGENT_LABELS names $LABEL"
else bad "$LABEL missing from OSTLER_LAUNCHAGENT_LABELS"; fi

# ── 6. the walk probe's own self-test (negative controls fire) ───────────────
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/settling_json_refreshes.sh"
if [ -f "$PROBE" ]; then
    out="$(bash "$PROBE" --self-test 2>&1)"; prc=$?
    if [ "$prc" = 1 ] && /usr/bin/grep -q 'each gave FAIL, so this probe returns FAIL on them as it must' <<<"$out"; then
        ok "probe self-test: advancing pair PASSes; stalled, 404 and schema-less pairs FAIL"
    else bad "probe self-test did not show its controls firing (rc=$prc): $out"; fi
else bad "probe settling_json_refreshes.sh missing"; fi

printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
