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
#   2. The tick passes only the compiler's own flags after the wiki-compiler
#      service name. The expected argv is DERIVED from the image ENTRYPOINT in
#      tests/fixtures/wiki_compiler_entrypoint.json (CM044 fcfdff68), not typed
#      in: the docker stub runs ENTRYPOINT + the tick's tail through a simulated
#      compiler parser, so a tail that repeats `python -m compiler` is rejected
#      with exit 2 exactly as the real container does. Negative control: the
#      simulator must reject the old argv. CANNOT-RUN here: a real container
#      run (the 131 walk on the Mini16 is the real proof).
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
FX="$REPO_ROOT/tests/fixtures/wiki_compiler_entrypoint.json"
cat > "$STUB/docker" <<'S'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
if [ -n "${STUB_DOCKER_RC:-}" ]; then exit "$STUB_DOCKER_RC"; fi
# `docker compose ... run --rm -T wiki-compiler <tail>`: the container runs the
# image ENTRYPOINT followed by <tail>. Everything after the service name is <tail>.
[ "${1:-}" = compose ] || exit 0
seen=0; tail=()
for a in "$@"; do
    if [ "$seen" = 1 ]; then tail+=("$a"); elif [ "$a" = wiki-compiler ]; then seen=1; fi
done
[ "$seen" = 1 ] || { echo "stub: no wiki-compiler service in argv" >&2; exit 125; }
exec python3 -I "$STUB/compiler_sim.py" "$FIXTURE" "${tail[@]}"
S
# The compiler's argparse, as far as the tail is concerned: a token that is not
# a known flag (or a flag's value) is "unrecognized". Entrypoint and flags come
# from the fixture, never from the expected string.
cat > "$STUB/compiler_sim.py" <<'S'
import json, sys
fx = json.load(open(sys.argv[1], encoding="utf-8"))
argv = fx["entrypoint"] + sys.argv[2:]          # what the container executes
rest = argv[len(fx["entrypoint"]):]             # what compile.main() parses
unknown, i = [], 0
while i < len(rest):
    a = rest[i]
    if a in fx["flags"]:
        i += 1 + fx["flags"][a]
        continue
    unknown.append(a); i += 1
if unknown:
    sys.stderr.write("error: unrecognized arguments: " + " ".join(unknown) + "\n")
    sys.exit(2)
print("compiler accepted: " + " ".join(rest))
S
# The compose tail of the one logged compose call must be non-empty and made of
# the compiler's own flags (and their values) only.
TAIL_CHECK="$STUB/tail_check.py"
cat > "$TAIL_CHECK" <<'S'
import json, sys
fx = json.load(open(sys.argv[1], encoding="utf-8"))
lines = [l.split() for l in open(sys.argv[2], encoding="utf-8") if l.startswith("docker compose ")]
if len(lines) != 1 or "wiki-compiler" not in lines[0]:
    print("expected exactly one compose call naming wiki-compiler"); sys.exit(1)
tail = lines[0][lines[0].index("wiki-compiler") + 1:]
if not tail:
    print("empty tail after the service name"); sys.exit(1)
i = 0
while i < len(tail):
    if tail[i] not in fx["flags"]:
        print("token after the service is not a compiler flag: " + tail[i]); sys.exit(1)
    i += 1 + fx["flags"][tail[i]]
print("tail is compiler flags only: " + " ".join(tail))
S
chmod +x "$STUB/launchctl" "$STUB/docker"
export STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"
export FIXTURE="$FX" STUB

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

# Pinned entrypoint binds to the image digest in the provenance table.
if python3 -I -c '
import json, sys
fx = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2], encoding="utf-8") if l.startswith("wiki-compiler\t")]
sys.exit(0 if any(r[1] == fx["_image_digest"] and r[2] == fx["_commit"] for r in rows) else 1)
' "$FX" "$REPO_ROOT/scripts/wiki_image_provenance.tsv"; then
    ok "entrypoint fixture binds to the pinned wiki-compiler digest and CM044 commit"
else bad "entrypoint fixture does not match scripts/wiki_image_provenance.tsv"; fi

# A CM044 re-pin changes the digest install.sh ships. The fixture must follow it,
# or the recorded ENTRYPOINT outlives the image it describes. Read from install.sh
# itself (the shipped compose), not from the provenance table.
if python3 -I -c '
import json, re, sys
fx = json.load(open(sys.argv[1], encoding="utf-8"))
pins = re.findall(r"ghcr\.io/creativemachines-ai/ostler-wiki-compiler@(sha256:[0-9a-f]{64})", open(sys.argv[2], encoding="utf-8").read())
sys.exit(0 if len(pins) == 1 and pins[0] == fx["_image_digest"] else 1)
' "$FX" "$REPO_ROOT/install.sh"; then
    ok "entrypoint fixture digest equals the ostler-wiki-compiler digest pinned in install.sh"
else bad "entrypoint fixture digest does not match the install.sh pin (re-pin without a fixture refresh?)"; fi

# Negative control: the simulated container must REJECT the old tail
# (`python -m compiler.compile ...`), or the checks below prove nothing.
python3 -I "$STUB/compiler_sim.py" "$FX" python -m compiler.compile --settling-only >/dev/null 2>"$TMP/neg.err"; neg_rc=$?
if [ "$neg_rc" = 2 ] && /usr/bin/grep -q 'unrecognized arguments' "$TMP/neg.err"; then
    ok "CONTROL: simulated container rejects a tail that repeats the entrypoint (exit 2)"
else bad "CONTROL: simulated container did not reject the repeated entrypoint (rc=$neg_rc)"; fi

if [ -x "$TICK" ]; then
    rc="$(run_tick)"
    tail_msg="$(python3 -I "$TAIL_CHECK" "$FX" "$STUB_LOG" 2>&1)"; tail_rc=$?
    if [ "$rc" = 0 ] && [ "$tail_rc" = 0 ]; then
        ok "tick: exit 0 and the compose tail is compiler flags only ($tail_msg)"
    else bad "tick: rc=$rc tail_rc=$tail_rc: $tail_msg | log: $(cat "$STUB_LOG") | tick: $(cat "$TMP/tick.out")"; fi

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
