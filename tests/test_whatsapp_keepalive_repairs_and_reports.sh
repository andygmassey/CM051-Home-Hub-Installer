#!/bin/bash
#
# test_whatsapp_keepalive_repairs_and_reports.sh
#
# THE DEFECT THIS GUARDS, restated so a future reader does not have to dig:
#
# com.creativemachines.ostler.whatsapp-keepalive ran `ostler-assistant channel
# doctor` twice a day. That command builds its OWN WhatsAppWebChannel, whose
# is_ready() is `self.client.lock().is_some()` on an object that has never
# connected, so it reported UNHEALTHY on 100% of runs on every box. Then
# doctor_channels() returned Ok(()) regardless, so launchctl showed
# `last exit code = 0`. On the box this was caught on: runs=3, exit 0, three
# unhealthy runs in the job's own log, and whatsapp-bundle.log showing that
# same day's messages ingested, 13 chats scanned and 12 dispatched. The
# channel was fine and nothing was keeping it alive.
#
# So this test asserts the three things the fix has to be true about, and it
# asserts them by RUNNING the shipped script, not by grepping it:
#
#   1. IT REMEDIATES. An unhealthy channel gets exactly one daemon restart,
#      and the script reports RECOVERED when that works.
#   2. IT DOES NOT EXIT 0 ON A FAILURE IT COULD NOT FIX. Five outcomes, five
#      distinct exit codes, and the only 0 is a healthy channel.
#   3. IT NEVER TOUCHES THE CUSTOMER'S WHATSAPP SESSION. When the session is
#      gone, ZERO restarts happen and it says so. When no verdict could be
#      reached, ZERO restarts happen and it says so.
#
# HOW THE MEASUREMENT IS MADE HONEST
#
#   * The daemon is a real HTTP server on loopback serving a real /health
#     payload, so the script's own curl + JSON parse are exercised. Nothing
#     is stubbed inside the script.
#   * `launchctl` is a PATH shim that RECORDS every invocation to a file.
#     Every "nothing was restarted" claim below is therefore a COUNT, and
#     case 2 is the positive control that must produce a NON-ZERO count --
#     without it, a shim that silently failed to record would make every
#     absence claim pass for the wrong reason.
#   * The Doctor renderer is imported and called for real, against the state
#     file the script actually wrote. A tile nobody proved renders is the
#     same defect one layer along.
#
# British English throughout. No `timeout` (absent on macOS).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/assistant-agent/ostler-whatsapp-keepalive.sh"
AGENT_DIR="${REPO_ROOT}/vendor/doctor/agent"

FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL [$1]: $2" >&2; FAILURES=$((FAILURES + 1)); }

# A CHECK THAT PRINTS BOTH A FAIL AND A PASS HAS TOLD YOU NOTHING.
# The first draft of this file ran a bare `[ ... ] || fail ...` and then an
# unconditional `pass`, so every broken case printed a red line and a green one
# and the summary was the only honest part of the output. Everything below goes
# through these two, which return non-zero on failure so the caller can skip
# its own pass line.
check_eq() {   # check_eq <id> <expected> <actual> <what>
    if [ "$2" = "$3" ]; then return 0; fi
    fail "$1" "$4: expected '$2', measured '$3'"
    return 1
}

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL [script-missing]: $SCRIPT does not exist" >&2
    exit 1
fi

PYTHON_BIN=""
for cand in "$(command -v python3 2>/dev/null || true)" /usr/bin/python3; do
    [ -n "$cand" ] || continue
    if "$cand" -c 'import json,http.server' >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done
if [ -z "$PYTHON_BIN" ]; then
    # Not a pass and not a fail. Say which check could not run and what it
    # would need.
    echo "CANNOT-RUN: no working python3 with json + http.server. This test" >&2
    echo "            needs one to stand up the stub daemon and to import the" >&2
    echo "            Doctor renderer. Install python3 and re-run." >&2
    exit 0
fi

WORK="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

HEALTH_JSON="${WORK}/health.json"
PORT_FILE="${WORK}/port"
LAUNCHCTL_CALLS="${WORK}/launchctl-calls"
SHIM_DIR="${WORK}/shim"
mkdir -p "$SHIM_DIR"
: > "$LAUNCHCTL_CALLS"

# ── the stub daemon ───────────────────────────────────────────────────
#
# Re-reads health.json on every request, so a test can flip the channel's
# state mid-run (which is exactly what a successful repair looks like).
cat > "${WORK}/stub_daemon.py" <<'PY'
import http.server, json, os, socketserver, sys, threading
health_path, port_path = sys.argv[1], sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404); self.end_headers(); return
        try:
            with open(health_path, encoding="utf-8") as fh:
                body = fh.read().encode()
        except OSError:
            self.send_response(500); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    with open(port_path, "w") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()
PY

# `disown` after backgrounding: bash 3.2 prints a "Terminated" job-control
# line when the EXIT trap kills a tracked child, which lands in the middle of
# the summary and reads like a failure.
"$PYTHON_BIN" "${WORK}/stub_daemon.py" "$HEALTH_JSON" "$PORT_FILE" &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true

# Wait for the port file rather than sleeping a guessed interval.
for _ in $(seq 1 100); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done
if [ ! -s "$PORT_FILE" ]; then
    echo "CANNOT-RUN: the stub daemon never bound a port." >&2
    exit 0
fi
PORT="$(cat "$PORT_FILE")"
GATEWAY="http://127.0.0.1:${PORT}"

# ── the launchctl shim ────────────────────────────────────────────────
#
# Records every call. `kickstart` flips the stub daemon's payload to healthy
# when RESTART_HEALS=1, which is what a working repair does.
cat > "${SHIM_DIR}/launchctl" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "${LAUNCHCTL_CALLS}"
if [ "\${1:-}" = "kickstart" ] && [ "\${RESTART_HEALS:-0}" = "1" ]; then
    cp "${WORK}/health-ok.json" "${HEALTH_JSON}"
fi
exit "\${LAUNCHCTL_RC:-0}"
SHIM
chmod +x "${SHIM_DIR}/launchctl"

# ── payload fixtures ──────────────────────────────────────────────────
#
# Shaped exactly like the daemon's GET /health: the component key is
# `channel:WhatsApp`, built upstream as format!("channel:{}", ch.name()).
write_health() {
    local status="$1" reason="${2:-}"
    "$PYTHON_BIN" - "$HEALTH_JSON" "$status" "$reason" <<'PY'
import json, sys
path, status, reason = sys.argv[1:4]
doc = {
    "status": "ok" if status == "ok" else "degraded",
    "runtime": {
        "pid": 1234,
        "components": {
            "gateway": {"status": "ok"},
            "channel:WhatsApp": {"status": status, "last_error": reason or None},
        },
    },
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

write_health "ok"
cp "$HEALTH_JSON" "${WORK}/health-ok.json"

# ── harness ───────────────────────────────────────────────────────────

OSTLER_ROOT="${WORK}/ostler"
STATE_FILE="${OSTLER_ROOT}/state/whatsapp_keepalive.json"
PAIR_FILE="${OSTLER_ROOT}/state/whatsapp_pair.json"

reset_box() {
    rm -rf "$OSTLER_ROOT"
    mkdir -p "${OSTLER_ROOT}/state"
    : > "$LAUNCHCTL_CALLS"
}

run_keepalive() {
    PATH="${SHIM_DIR}:${PATH}" \
    OSTLER_DIR="$OSTLER_ROOT" \
    OSTLER_GATEWAY_URL="$GATEWAY" \
    OSTLER_ASSISTANT_LABEL="com.creativemachines.ostler.assistant" \
    OSTLER_KEEPALIVE_PYTHON="$PYTHON_BIN" \
    OSTLER_KEEPALIVE_RECHECK_SECONDS="${RECHECK:-6}" \
    OSTLER_KEEPALIVE_RECHECK_INTERVAL_SECONDS=1 \
    RESTART_HEALS="${RESTART_HEALS:-0}" \
    LAUNCHCTL_RC="${LAUNCHCTL_RC:-0}" \
    bash "$SCRIPT" > "${WORK}/run.log" 2>&1
    echo $?
}

verdict_is() {
    "$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$STATE_FILE" 2>/dev/null
}

kickstart_count() {
    /usr/bin/grep -c '^kickstart' "$LAUNCHCTL_CALLS" 2>/dev/null || true
}

write_pair_file() {
    # offset_secs > 0 => an unexpired code is waiting, i.e. the daemon is
    # asking the customer to re-link. NO CODE VALUE IS EVER REAL HERE.
    "$PYTHON_BIN" - "$PAIR_FILE" "$1" <<'PY'
import json, sys, time
path, offset = sys.argv[1], int(sys.argv[2])
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "code": "TESTCODE",
        "requested_at": int(time.time()),
        "expires_at": int(time.time()) + offset,
        "validity_secs": abs(offset),
    }, fh)
PY
}

echo "── the shipped keepalive, run for real against a stub daemon ──"

# ── 1. HEALTHY ────────────────────────────────────────────────────────
reset_box
write_health "ok"
rc="$(run_keepalive)"
ok=0
check_eq "healthy-exit" "0" "$rc" "a healthy channel must exit 0" || ok=1
check_eq "healthy-verdict" "healthy" "$(verdict_is)" "state file verdict" || ok=1
check_eq "healthy-restart" "0" "$(kickstart_count)" "a healthy channel must not be restarted" || ok=1
[ "$ok" = "0" ] && pass "healthy channel: exit 0, verdict healthy, 0 restarts (denominator: 1 run)"

# ── 2. RECOVERED. This is also the POSITIVE CONTROL for the shim ──────
#
# Every "0 restarts" claim in this file is only worth something if the shim
# can record a restart at all. This case must produce a NON-ZERO count.
reset_box
write_health "error" "channel reports not-ready (health_check returned false)"
rc="$(RESTART_HEALS=1 run_keepalive)"
ok=0
check_eq "recovered-exit" "2" "$rc" "a repaired channel must exit 2, never 0" || ok=1
check_eq "recovered-verdict" "recovered" "$(verdict_is)" "state file verdict" || ok=1
n="$(kickstart_count)"
if [ "$n" = "1" ]; then
    pass "POSITIVE CONTROL: the launchctl shim records restarts (1 kickstart on the repair path)"
else
    fail "recovered-restart" "expected exactly 1 kickstart on the repair path, recorded $n. EVERY zero-restart assertion in this file is UNTRUSTWORTHY until this reads 1."
    ok=1
fi
if /usr/bin/grep -q 'kickstart -k gui/[0-9]*/com.creativemachines.ostler.assistant' "$LAUNCHCTL_CALLS"; then
    pass "the restart targets the assistant LaunchAgent, in the user GUI domain"
else
    fail "recovered-target" "the recorded restart is not a kickstart of the assistant label. Recorded: $(cat "$LAUNCHCTL_CALLS")"
    ok=1
fi
[ "$ok" = "0" ] && pass "unhealthy channel repaired: exit 2, verdict recovered, exactly 1 restart"

# ── 3. NEEDS CUSTOMER. The safety assertion. ──────────────────────────
#
# An unexpired pair code next to an unhealthy channel means wa-rs reported
# LoggedOut, the daemon purged the session and is asking to be re-linked.
# Restarting cannot fix that and would churn the code, so NOTHING must happen.
reset_box
write_health "error" "channel reports not-ready (health_check returned false)"
write_pair_file 300
rc="$(run_keepalive)"
ok=0
check_eq "needs-customer-exit" "4" "$rc" "a lost WhatsApp session must exit 4" || ok=1
check_eq "needs-customer-verdict" "needs_customer" "$(verdict_is)" "state file verdict" || ok=1
check_eq "needs-customer-restart" "0" "$(kickstart_count)" "a lost session must NOT be retried" || ok=1
[ "$ok" = "0" ] && pass "lost WhatsApp session: exit 4, verdict needs_customer, 0 restarts (denominator: 1 run)"

# An expired code is NOT a pending re-link, so the repair path must still run.
reset_box
write_health "error" "channel reports not-ready (health_check returned false)"
write_pair_file -300
rc="$(RESTART_HEALS=1 run_keepalive)"
check_eq "expired-code-exit" "2" "$rc" "an EXPIRED pair code must not block the repair" \
    && pass "expired pair code does not block the repair (the discriminator is expiry, not presence)"

# ── 4. STILL UNHEALTHY ────────────────────────────────────────────────
reset_box
write_health "error" "channel reports not-ready (health_check returned false)"
rc="$(RESTART_HEALS=0 run_keepalive)"
ok=0
check_eq "still-unhealthy-exit" "5" "$rc" "a failed repair must exit 5, NEVER 0" || ok=1
check_eq "still-unhealthy-verdict" "still_unhealthy" "$(verdict_is)" "state file verdict" || ok=1
check_eq "still-unhealthy-restart" "1" "$(kickstart_count)" "exactly one repair attempt" || ok=1
[ "$ok" = "0" ] && pass "failed repair: exit 5, verdict still_unhealthy, exactly 1 attempt"

# ── 5. BOUNDED. The second fire of the day must not restart again. ────
#
# Re-run against the state the previous case just wrote, which already
# records a repair. The cap is 1 per rolling 24h.
: > "$LAUNCHCTL_CALLS"
rc="$(RESTART_HEALS=0 run_keepalive)"
ok=0
check_eq "capped-exit" "5" "$rc" "the capped run must still exit 5" || ok=1
check_eq "capped-restart" "0" "$(kickstart_count)" "the repair cap must stop a second restart" || ok=1
[ "$ok" = "0" ] && pass "bounded: second fire with the cap reached does 0 restarts (denominator: 1 run)"

# ── 5b. THE RESTART ITSELF FAILING ────────────────────────────────────
#
# A distinct customer-facing outcome with its own copy, and an untested branch
# until this case existed. It also guards a specific trap: restart_assistant
# pipes launchctl into sed, and in a pipeline `$?` belongs to the LAST command.
# Only `set -o pipefail` makes launchctl's non-zero survive that pipe. Drop
# pipefail and this case goes green while the script reports a repair that
# never happened.
reset_box
write_health "error" "channel reports not-ready (health_check returned false)"
rc="$(LAUNCHCTL_RC=1 RESTART_HEALS=0 run_keepalive)"
ok=0
check_eq "restart-failed-exit" "5" "$rc" "a failed restart must exit 5" || ok=1
check_eq "restart-failed-verdict" "still_unhealthy" "$(verdict_is)" "state file verdict" || ok=1
check_eq "restart-failed-attempt" "1" "$(kickstart_count)" "the restart was attempted once" || ok=1
if ! /usr/bin/grep -q 'did not succeed' "${WORK}/run.log"; then
    fail "restart-failed-says-so" "the log does not say the restart failed: $(tail -3 "${WORK}/run.log")"
    ok=1
fi
[ "$ok" = "0" ] && pass "launchctl refuses the restart: exit 5, verdict still_unhealthy, and it says the restart failed rather than claiming a repair"

# ── 6. CANNOT-RUN. No verdict is not a failure verdict. ───────────────
reset_box
DEAD_GATEWAY="http://127.0.0.1:1"
rc="$(PATH="${SHIM_DIR}:${PATH}" OSTLER_DIR="$OSTLER_ROOT" \
      OSTLER_GATEWAY_URL="$DEAD_GATEWAY" \
      OSTLER_KEEPALIVE_PYTHON="$PYTHON_BIN" \
      bash "$SCRIPT" >"${WORK}/run.log" 2>&1; echo $?)"
ok=0
check_eq "cannot-run-exit" "3" "$rc" "an unreachable daemon must exit 3 (CANNOT-RUN)" || ok=1
check_eq "cannot-run-verdict" "cannot_run" "$(verdict_is)" "state file verdict" || ok=1
check_eq "cannot-run-restart" "0" "$(kickstart_count)" "an unmeasured channel must NOT be restarted" || ok=1
if ! /usr/bin/grep -q 'CANNOT-RUN' "${WORK}/run.log"; then
    fail "cannot-run-says-so" "the log does not contain CANNOT-RUN: $(cat "${WORK}/run.log")"
    ok=1
fi
[ "$ok" = "0" ] && pass "unreachable daemon: exit 3, verdict cannot_run, 0 restarts, says CANNOT-RUN"

# A daemon that is up but registers NO WhatsApp component is also CANNOT-RUN,
# not unhealthy. Restarting a box where the customer simply never enabled
# WhatsApp would be a twice-daily outage for no reason at all.
reset_box
"$PYTHON_BIN" - "$HEALTH_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"status": "ok", "runtime": {"components": {"gateway": {"status": "ok"}}}}, fh)
PY
rc="$(run_keepalive)"
ok=0
check_eq "absent-exit" "3" "$rc" "an unregistered channel must exit 3" || ok=1
check_eq "absent-restart" "0" "$(kickstart_count)" "an unregistered channel must not be restarted" || ok=1
[ "$ok" = "0" ] && pass "WhatsApp not enabled on this install: exit 3, 0 restarts"

# ── 6b. AN INTERPRETER THAT DOES NOT RUN IS NOT AN INTERPRETER ────────
#
# On a Mac with no Command Line Tools, /usr/bin/python3 EXISTS, is executable,
# and does not run: it is an Apple stub that prompts instead. install.sh records
# that trap. A `[ -x ]` test accepts it, every later parse then fails, and the
# script would report CANNOT-RUN against a daemon that answered perfectly.
#
# resolve_python defends by RUNNING each candidate. That is asserted against
# the REAL function, extracted from the shipped script by its own delimiters --
# never a copy, because a copy drifts and then tests itself.
echo "── the interpreter probe, driven against the real function ──"
FN="${WORK}/resolve_python.inc"
awk '/^resolve_python\(\) \{$/,/^\}$/' "$SCRIPT" > "$FN"
_fl="$(wc -l < "$FN" | tr -d ' ')"
if [ "$_fl" -lt 10 ]; then
    echo "CANNOT-RUN: could not extract resolve_python (${_fl} lines); its delimiters moved." >&2
    echo "            The interpreter probe was NOT measured." >&2
else
    STUB_DIR="${WORK}/stubpy"
    mkdir -p "$STUB_DIR"
    # Same shape as the Apple stub: present, executable, does not run.
    printf '#!/bin/bash\necho "xcode-select: note: no developer tools were found" >&2\nexit 1\n' > "${STUB_DIR}/stub"
    chmod +x "${STUB_DIR}/stub"

    probe() {   # $1..$n = candidates, in order. Prints the one chosen, or nothing.
        bash -c '
            OSTLER_KEEPALIVE_PYTHON="$1"
            OSTLER_DIR="$2"
            '"$(cat "$FN")"'
            resolve_python || true
        ' _ "$1" "$2" 2>/dev/null
    }

    ok=0
    # A stub offered first must NOT be chosen, even though it is executable.
    chosen="$(probe "${STUB_DIR}/stub" "${WORK}/no-such-ostler-dir")"
    if [ "$chosen" = "${STUB_DIR}/stub" ]; then
        fail "stub-python-chosen" "resolve_python selected a stub that does not run. A [ -x ] test would do this; running the candidate is the whole point."
        ok=1
    fi
    # POSITIVE CONTROL: a REAL interpreter offered first MUST be chosen, or the
    # arm above passes because the function returns nothing for everything.
    chosen_ok="$(probe "$PYTHON_BIN" "${WORK}/no-such-ostler-dir")"
    if [ "$chosen_ok" != "$PYTHON_BIN" ]; then
        fail "stub-python-control" "resolve_python did not select a REAL interpreter (${PYTHON_BIN}), it returned '${chosen_ok}'. It rejects everything, so the stub arm above proves nothing."
        ok=1
    fi
    [ "$ok" = "0" ] && pass "resolve_python rejects a present-but-non-running python3 and selects a real one (control: the real interpreter IS selected)"

    # And the CANNOT-RUN branch itself: no candidate resolves at all.
    # /usr/bin/python3 is hard-coded as the last resort, so this arm is only
    # reachable on a box where that one does not run either. Say which, rather
    # than skipping silently.
    if /usr/bin/python3 -c 'import json,sys' >/dev/null 2>&1; then
        echo "CANNOT-RUN: the no-interpreter-anywhere branch cannot be reached here," >&2
        echo "            because /usr/bin/python3 on this host runs. What resolve_python" >&2
        echo "            does when EVERY candidate fails was NOT measured. To measure it," >&2
        echo "            run on a Mac with no Command Line Tools installed." >&2
    else
        chosen_none="$(probe "${STUB_DIR}/stub" "${WORK}/no-such-ostler-dir")"
        [ -z "$chosen_none" ] \
            && pass "with no working candidate anywhere, resolve_python selects nothing" \
            || fail "no-python-branch" "resolve_python returned '${chosen_none}' with no working candidate"
    fi
fi

# ── 7. THE SESSION STORE IS NEVER TOUCHED ─────────────────────────────
#
# Asserted over EVERY launchctl call this test provoked, and over the script
# itself for the destructive verbs a repair must never reach for.
if /usr/bin/grep -qiE 'bootout|unload|remove' "$LAUNCHCTL_CALLS"; then
    fail "destructive-launchctl" "the keepalive issued a destructive launchctl verb: $(cat "$LAUNCHCTL_CALLS")"
else
    pass "no bootout/unload/remove was ever issued"
fi
if /usr/bin/grep -nE '(^|[^a-z])rm[[:space:]]+-[rf]*[[:space:]]*.*(session|whatsapp_pair|wa-rs)' "$SCRIPT"; then
    fail "session-delete" "the keepalive script contains something that deletes WhatsApp session state"
else
    pass "the script contains no deletion of WhatsApp session state"
fi

# ── 8. THE SIGNAL REACHES A PERSON ────────────────────────────────────
#
# The state file is only half the fix. Render the real Doctor tile against
# each verdict the script can write, and require the customer-facing words to
# come out. A verdict that renders to nothing is a log entry with extra steps.
echo "── the Doctor tile, rendered for real ──"
if ! "$PYTHON_BIN" - "$AGENT_DIR" "$OSTLER_ROOT" <<'PY'
import json, os, pathlib, sys, time
agent_dir, ostler_root = sys.argv[1], sys.argv[2]
sys.path.insert(0, agent_dir)
os.environ["OSTLER_HOME"] = ostler_root
state = pathlib.Path(ostler_root) / "state" / "whatsapp_keepalive.json"
state.parent.mkdir(parents=True, exist_ok=True)

try:
    from dashboard_components import render_whatsapp_keepalive
except Exception as exc:
    print(f"CANNOT-RUN: could not import the Doctor renderer ({exc!r}).")
    print("            It needs the doctor agent's own dependencies on sys.path.")
    raise SystemExit(64)

failures = 0

# Absent marker renders nothing, rather than an empty header.
if state.exists():
    state.unlink()
if render_whatsapp_keepalive() != "":
    print("FAIL [tile-absent]: a missing verdict must render nothing")
    failures += 1
else:
    print("PASS: no verdict renders no tile")

# Each verdict must reach the page, and must reach it with its OWN words.
expected = {
    "healthy": "WhatsApp is connected",
    "recovered": "WhatsApp was reconnected",
    "needs_customer": "WhatsApp needs linking again",
    "still_unhealthy": "WhatsApp is not connected",
    "cannot_run": "WhatsApp connection not checked",
}
for verdict, words in expected.items():
    state.write_text(json.dumps({
        "verdict": verdict, "detail": "d",
        "checked_at": int(time.time()), "repairs_last_24h": 1,
    }), encoding="utf-8")
    html = render_whatsapp_keepalive()
    if words not in html:
        print(f"FAIL [tile-{verdict}]: rendered tile does not say {words!r}")
        failures += 1
    elif "whatsappKeepaliveSection" not in html:
        print(f"FAIL [tile-{verdict}]: rendered tile has no section id")
        failures += 1
    else:
        print(f"PASS: verdict {verdict} renders as {words!r}")

# The one verdict that asks something of the customer must say who can fix it
# and must point at the page that already exists for it.
state.write_text(json.dumps({
    "verdict": "needs_customer", "detail": "d",
    "checked_at": int(time.time()), "repairs_last_24h": 0,
}), encoding="utf-8")
html = render_whatsapp_keepalive()
if "Only you can link it again" not in html:
    print("FAIL [tile-needs-customer-copy]: the tile does not tell the customer that only they can fix it")
    failures += 1
elif "/whatsapp-pair" not in html:
    print("FAIL [tile-needs-customer-link]: the tile does not link the existing Link WhatsApp page")
    failures += 1
else:
    print("PASS: needs_customer says only the customer can fix it, and links the existing pairing page")

# A verdict the writer could never emit must not be rendered verbatim.
state.write_text(json.dumps({
    "verdict": "<script>x</script>", "detail": "d",
    "checked_at": 0, "repairs_last_24h": 0,
}), encoding="utf-8")
if render_whatsapp_keepalive() != "":
    print("FAIL [tile-unknown-verdict]: an unrecognised verdict must render nothing")
    failures += 1
else:
    print("PASS: an unrecognised verdict renders nothing")

raise SystemExit(1 if failures else 0)
PY
then
    rc=$?
    if [ "$rc" = "64" ]; then
        echo "CANNOT-RUN: the Doctor renderer could not be imported here. Install" >&2
        echo "            vendor/doctor/agent/requirements.txt and re-run. The tile" >&2
        echo "            half of this test has NOT been measured." >&2
    else
        fail "doctor-tile" "the Doctor tile did not render the keepalive verdict"
    fi
fi

# ── 9. THE TILE IS ACTUALLY WIRED INTO THE PAGE ───────────────────────
#
# A renderer nobody calls is not wired, and "the function exists" is not the
# claim being made here. Mutation-tested: deleting the interpolation from the
# dashboard body must red this block.
#
# Checked statically because the behavioural gate for this
# (tests/test_the_doctor_dashboard_actually_renders.sh) needs fastapi, and is
# CANNOT-RUN on a box without it -- which is exactly the box where a silently
# unwired tile would ship. A check that only runs where the defect cannot hide
# is not a check.
#
# EVERY assertion below is paired with the SAME assertion against an existing,
# known-wired section. If the control ever fails, the predicate has stopped
# being able to find a wired tile at all and every verdict here is void.
echo "── the tile is wired into the dashboard, not merely defined ──"
WEB_UI="${AGENT_DIR}/web_ui.py"
wiring_ok=0
for pair in "whatsapp_keepalive:SUBJECT" "reminders_runtime:CONTROL"; do
    name="${pair%%:*}"
    role="${pair##*:}"
    miss=""
    /usr/bin/grep -q "    render_${name}," "$WEB_UI" || miss="$miss imported-from-dashboard_components"
    /usr/bin/grep -q "${name}_section = render_${name}()" "$WEB_UI" || miss="$miss called-in-render_dashboard"
    /usr/bin/grep -qF "{${name}_section}" "$WEB_UI" || miss="$miss interpolated-into-the-page-body"
    if [ -n "$miss" ]; then
        if [ "$role" = "CONTROL" ]; then
            fail "wiring-control" "the CONTROL section ${name} is not wired either, so this predicate cannot detect wiring and every verdict in this block is void. Missing:$miss"
        else
            fail "wiring-${name}" "render_${name} is not wired into the dashboard. Missing:$miss"
        fi
        wiring_ok=1
    elif [ "$role" = "CONTROL" ]; then
        pass "POSITIVE CONTROL: the wiring predicate finds the known-wired ${name} tile (3 of 3)"
    fi
done
[ "$wiring_ok" = "0" ] && pass "the keepalive tile is imported, called and interpolated into the dashboard body"

# ── 10. THE CUSTOMER ACTUALLY GETS IT ─────────────────────────────────
#
# Everything above tests the script in isolation. This runs the SHIPPED
# INSTALL_SNIPPET.sh end to end in a sandbox and checks what lands on the
# customer's disk: an executable runner, and a plist with every placeholder
# substituted that launchd would accept.
#
# An UNSUBSTITUTED PLACEHOLDER is the specific way this could ship broken and
# look fine in review. The plist would still be valid XML, still load, and
# exec a literal "OSTLER_KEEPALIVE_SCRIPT_VALUE" twice a day forever.
echo "── the shipped installer snippet, run end to end ──"
SNIPPET="${REPO_ROOT}/assistant-agent/INSTALL_SNIPPET.sh"
if [ ! -f "$SNIPPET" ]; then
    fail "snippet-missing" "$SNIPPET does not exist"
else
    # `fakehome`, not `home`: the operator-PII shape scan flags any
    # any Linux-style home-directory literal, and a sandbox HOME directory
    # named that way trips it on every path built from it. Renaming the
    # directory is the fix; weakening the pattern is not.
    SANDBOX="${WORK}/install"
    mkdir -p "${SANDBOX}/fakehome/Library/LaunchAgents" \
             "${SANDBOX}/ostler/OstlerAssistant.app/Contents/MacOS"
    printf '#!/bin/bash\nexit 0\n' > "${SANDBOX}/ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
    chmod +x "${SANDBOX}/ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"

    ( HOME="${SANDBOX}/fakehome" \
      PATH="${SHIM_DIR}:${PATH}" \
      OSTLER_INSTALL_ROOT="${REPO_ROOT}/assistant-agent" \
      OSTLER_DIR="${SANDBOX}/ostler" \
      LOGS_DIR="${SANDBOX}/ostler/logs" \
      ASSISTANT_CONFIG_DIR="${SANDBOX}/ostler/assistant-config" \
      INSTALL_WHATSAPP_KEEPALIVE=true \
      OSTLER_ASSISTANT_DEFER_START=true \
      bash "$SNIPPET" ) > "${WORK}/install.log" 2>&1
    snippet_rc=$?

    RENDERED="${SANDBOX}/fakehome/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist"
    INSTALLED_RUNNER="${SANDBOX}/ostler/bin/ostler-whatsapp-keepalive.sh"

    if [ "$snippet_rc" -ne 0 ]; then
        fail "snippet-rc" "INSTALL_SNIPPET.sh exited ${snippet_rc}: $(tail -5 "${WORK}/install.log")"
    elif [ ! -f "$RENDERED" ]; then
        fail "snippet-no-plist" "no keepalive plist was rendered: $(tail -5 "${WORK}/install.log")"
    else
        ok=0
        if [ ! -x "$INSTALLED_RUNNER" ]; then
            fail "snippet-runner" "the runner was not installed executable at ${INSTALLED_RUNNER}"
            ok=1
        fi
        # POSITIVE CONTROL for the placeholder sweep: the UNRENDERED source
        # must trip it. Without this, a sweep whose pattern matched nothing
        # would call every plist clean, including a wholly unsubstituted one.
        src_left="$(/usr/bin/grep -c 'OSTLER_KEEPALIVE_SCRIPT_VALUE\|OSTLER_ARTEFACT_ROOT_VALUE\|OSTLER_GATEWAY_URL_VALUE\|OSTLER_ASSISTANT_LABEL_VALUE\|OSTLER_LOGS\|OSTLER_HOME' \
                    "${REPO_ROOT}/assistant-agent/launchd/com.creativemachines.ostler.whatsapp-keepalive.plist" || true)"
        if [ "$src_left" -gt 0 ]; then
            pass "POSITIVE CONTROL: the placeholder sweep finds ${src_left} unrendered token(s) in the SOURCE plist"
        else
            fail "placeholder-control" "the placeholder sweep found 0 tokens in the UNRENDERED source plist, so it cannot detect an unsubstituted one and the verdict below is void"
            ok=1
        fi
        left="$(/usr/bin/grep -c 'OSTLER_KEEPALIVE_SCRIPT_VALUE\|OSTLER_ARTEFACT_ROOT_VALUE\|OSTLER_GATEWAY_URL_VALUE\|OSTLER_ASSISTANT_LABEL_VALUE\|OSTLER_LOGS/\|<string>OSTLER_HOME</string>' "$RENDERED" || true)"
        if [ "$left" != "0" ]; then
            fail "snippet-placeholders" "${left} placeholder(s) survived into the rendered plist: $(/usr/bin/grep -n 'OSTLER_[A-Z_]*_VALUE\|OSTLER_LOGS/\|<string>OSTLER_HOME</string>' "$RENDERED")"
            ok=1
        fi
        if command -v plutil >/dev/null 2>&1; then
            if ! plutil -lint "$RENDERED" >/dev/null; then
                fail "snippet-plutil" "the rendered keepalive plist fails plutil -lint"
                ok=1
            fi
        else
            echo "CANNOT-RUN: plutil is absent, so the rendered plist was NOT validated." >&2
        fi
        # The rendered ProgramArguments must name the file that was installed.
        if ! /usr/bin/grep -qF "<string>${INSTALLED_RUNNER}</string>" "$RENDERED"; then
            fail "snippet-target" "the rendered plist does not exec the runner that was installed"
            ok=1
        fi
        [ "$ok" = "0" ] && pass "install end to end: runner installed executable, plist rendered with 0 placeholders left, plutil-valid, execs the installed runner"
    fi

    # And the refusal: no runner means no LaunchAgent, rather than an inert one.
    SANDBOX2="${WORK}/install-norunner"
    mkdir -p "${SANDBOX2}/fakehome/Library/LaunchAgents" \
             "${SANDBOX2}/ostler/OstlerAssistant.app/Contents/MacOS" \
             "${SANDBOX2}/agent/launchd"
    printf '#!/bin/bash\nexit 0\n' > "${SANDBOX2}/ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
    chmod +x "${SANDBOX2}/ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
    cp "${REPO_ROOT}/assistant-agent/launchd/"*.plist "${SANDBOX2}/agent/launchd/"
    cp "$SNIPPET" "${SANDBOX2}/agent/INSTALL_SNIPPET.sh"
    ( HOME="${SANDBOX2}/fakehome" PATH="${SHIM_DIR}:${PATH}" \
      OSTLER_INSTALL_ROOT="${SANDBOX2}/agent" \
      OSTLER_DIR="${SANDBOX2}/ostler" LOGS_DIR="${SANDBOX2}/ostler/logs" \
      ASSISTANT_CONFIG_DIR="${SANDBOX2}/ostler/assistant-config" \
      INSTALL_WHATSAPP_KEEPALIVE=true OSTLER_ASSISTANT_DEFER_START=true \
      bash "${SANDBOX2}/agent/INSTALL_SNIPPET.sh" ) > "${WORK}/install2.log" 2>&1
    if [ -f "${SANDBOX2}/fakehome/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist" ]; then
        fail "snippet-inert-agent" "the snippet registered the keepalive LaunchAgent with no runner staged, which ships a job that cannot exec"
    else
        pass "no runner staged: the keepalive LaunchAgent is refused rather than registered inert"
    fi
fi

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: ${FAILURES} assertion(s) failed" >&2
    exit 1
fi
echo "OK: the keepalive measures the running daemon, repairs once, refuses to"
echo "    retry what only the customer can fix, never exits 0 on an unfixed"
echo "    failure, and its verdict reaches the Doctor page."
