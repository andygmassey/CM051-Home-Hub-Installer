#!/usr/bin/env bash
#
# tests/test_an_import_that_stores_preferences_refreshes_the_profile.sh
#
# A new customer's FIRST export import (Spotify, Netflix, a Takeout ...) wrote
# preference rows, but the interest profile that the owner digest and the
# assistant's pwg_preferences tool read is compiled only by the hourly
# editor-frontpage tick. For up to an hour the customer saw "nothing stored".
#
# ostler-import (the IMPORTEOF heredoc in install.sh) must, when its CM019 leg
# reports "Preferences created: N" with N > 0, kickstart the EXISTING
# com.creativemachines.ostler.editor-frontpage job.
#
# LAUNCHD REAPING: ostler-import runs under com.ostler.export-scan, whose plist
# has no AbandonProcessGroup, so launchd kills every process still in the job's
# process group when the job exits. The refresh must therefore leave NO
# background child behind. Every run here is started as its own process-group
# leader (a stand-in for the launchd job); the moment it exits the whole group
# is SIGKILLed, exactly as launchd does, and only then are the kickstarts
# counted. A refresh that depends on a surviving child is lost.
#
# RUNTIME: the heredoc is carved out of install.sh and run against recording
# stubs. launchctl is a stub on PATH (the real one is never called). Synthetic
# data only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
LABEL="com.creativemachines.ostler.editor-frontpage"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); else printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; FAIL=$((FAIL+1)); fi; }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH"; exit 2; }
START="$(/usr/bin/grep -n "cat > \"\$IMPORT_SCRIPT\" <<'IMPORTEOF'" "$INSTALL_SH" | head -1 | cut -d: -f1)"
[ -n "$START" ] || { echo "CANNOT-RUN: the ostler-import heredoc opener is gone"; exit 2; }
END="$(awk -v s="$START" 'NR > s && /^IMPORTEOF$/ { print NR; exit }' "$INSTALL_SH")"
[ -n "$END" ] || { echo "CANNOT-RUN: the ostler-import heredoc terminator is gone"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"; O="$H/.ostler"; BIN="$WORK/bin"
mkdir -p "$O/bin" "$O/config" "$O/services/cm019/.venv/bin" "$BIN"
IMP="$O/bin/ostler-import"
sed -n "$((START + 1)),$((END - 1))p" "$INSTALL_SH" > "$IMP"
chmod +x "$IMP"
CALLS="$WORK/calls.log"; LC="$WORK/launchctl.log"

# CM019 stub: the ingest-dir leg prints the real summary line on stderr.
cat > "$O/services/cm019/.venv/bin/python" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" ingest-dir "*) echo "  Preferences created: \${STUB_PREFS:-0}" >&2 ;;
esac
exit 0
STUB
# launchctl stub: records argv; "print" answers STUB_LC_PRINT_RC (0 = loaded).
# "kickstart" models the job: STUB_LC_HANG=1 hangs like a penalty-boxed job,
# otherwise it recompiles interest_profile.json (what the real tick does).
cat > "$BIN/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$LC"
[ "\${1:-}" = "print" ] && exit "\${STUB_LC_PRINT_RC:-0}"
if [ "\${1:-}" = "kickstart" ]; then
    [ -n "\${STUB_LC_HANG:-}" ] && exec sleep 30
    printf '{"count":%s}\\n' "\$RANDOM" > "$O/preferences/interest_profile.json"
fi
exit 0
STUB
chmod +x "$O/services/cm019/.venv/bin/python" "$BIN/launchctl"

DROP="$WORK/drop/Spotify_Extended_Streaming"; mkdir -p "$DROP"
printf '[]\n' > "$DROP/Streaming_History_Audio_2024.json"

# A stand-in for a launchd job: run argv as the leader of a new process group,
# and when the leader exits report how many processes it left in the group
# (SURVIVORS=n on stdout) and then SIGKILL the group, as launchd does.
cat > "$WORK/asjob.py" <<'PYEOF'
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[1:], start_new_session=True)
rc = p.wait()
out = subprocess.run(["ps", "-axo", "pid=,pgid="], capture_output=True, text=True).stdout
n = sum(1 for l in out.splitlines() if len(l.split()) == 2 and int(l.split()[1]) == p.pid and int(l.split()[0]) != p.pid)
try:
    os.killpg(p.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
print("SURVIVORS=%d" % n)
sys.exit(rc)
PYEOF
imp() {  # imp ENV=VAL... : one ostler-import run as a launchd-style job (group killed on exit)
    env -u USER_NAME HOME="$H" PATH="$BIN:$PATH" "$@" /usr/bin/python3 -I "$WORK/asjob.py" "$IMP" "$WORK/drop" >"$WORK/out.$$.log" 2>&1
    local rc=$?
    SURV="$(sed -n 's/^SURVIVORS=//p' "$WORK/out.$$.log" | tail -1)"
    return $rc
}
kicks() { { /usr/bin/grep -c "^kickstart .*${LABEL}\$" "$LC" 2>/dev/null || true; } | head -1; }
reset() { : > "$LC"; rm -rf "$O/state" "$O/preferences"; mkdir -p "$O/preferences"; }
PROFILE="$O/preferences/interest_profile.json"

echo "1. an import that stored preferences refreshes the profile, and launchd cannot reap it"
reset; imp STUB_PREFS=42; sleep 1
n="$(kicks)"
arm "Preferences created: 42 -> one kickstart recorded after the job's process group was killed" "$([ "$n" = 1 ] && echo 0 || echo 1)" "kickstarts=$n; launchctl calls: $(tr '\n' '|' < "$LC")"
/usr/bin/grep -q "^kickstart -k gui/[0-9]*/${LABEL}\$" "$LC"
arm "and it is 'kickstart -k' on the gui/<uid> domain (launchd owns the compile)" $? "$(tr '\n' '|' < "$LC")"
arm "ostler-import leaves no process behind in the job's group" "$([ "${SURV:-x}" = 0 ] && echo 0 || echo 1)" "survivors=${SURV:-unknown}"

echo "2. an import that stored nothing does not"
reset; imp STUB_PREFS=0; sleep 1
n="$(kicks)"
arm "Preferences created: 0 -> no kickstart" "$([ "$n" = 0 ] && echo 0 || echo 1)" "kickstarts=$n"

echo "3. importers finishing together"
reset
( imp STUB_PREFS=7 ) & ( imp STUB_PREFS=9 ) & ( imp STUB_PREFS=3 ) &
wait; sleep 1
n="$(kicks)"
arm "three concurrent imports with preferences -> every one asks launchd (the last restart sees all rows)" "$([ "$n" = 3 ] && echo 0 || echo 1)" "kickstarts=$n"

echo "4. no agent loaded (first install, before the agent exists) is not an error"
reset; imp STUB_PREFS=5 STUB_LC_PRINT_RC=113; rc=$?; sleep 1
n="$(kicks)"
arm "label not loaded -> no kickstart and ostler-import exits 0" "$([ "$n" = 0 ] && [ "$rc" = 0 ] && echo 0 || echo 1)" "kickstarts=$n rc=$rc"

echo "5. a hung kickstart (penalty-boxed job) is bounded and leaves nothing behind"
reset; t0=$(date +%s); imp STUB_PREFS=5 STUB_LC_HANG=1; rc=$?; t1=$(date +%s)
arm "import returns within 15s with rc 0 and no survivor in the group" "$([ $((t1 - t0)) -le 15 ] && [ "$rc" = 0 ] && [ "${SURV:-x}" = 0 ] && echo 0 || echo 1)" "took $((t1 - t0))s rc=$rc survivors=${SURV:-unknown}"

echo "6. consumer side: the profile the digest reads changes after an import"
reset; printf '{"count":0}\n' > "$PROFILE"; before="$(cksum < "$PROFILE")"
imp STUB_PREFS=42; sleep 1
after="$(cksum < "$PROFILE")"
arm "interest_profile.json differs after an import that stored preferences" "$([ "$before" != "$after" ] && echo 0 || echo 1)" "before=$before after=$after"
printf '{"count":0}\n' > "$PROFILE"; before="$(cksum < "$PROFILE")"
imp STUB_PREFS=0; sleep 1
after="$(cksum < "$PROFILE")"
arm "control: unchanged after an import that stored nothing" "$([ "$before" = "$after" ] && echo 0 || echo 1)" "before=$before after=$after"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
