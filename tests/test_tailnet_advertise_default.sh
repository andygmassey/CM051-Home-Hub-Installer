#!/usr/bin/env bash
# tests/test_tailnet_advertise_default.sh
# ============================================================================
# Once Tailscale is connected, the installer must set
#   [gateway] companion_advertise_tailnet = true
# in ~/.ostler/assistant-config/config.toml, so the pairing QR carries the
# tailnet address. Absent or unconnected: the key is left alone (default false).
# The helper must never fail the install.
#
# RED on origin/main: install.sh has no _ostler_tailnet_advertise_default, so
# the extraction below is empty and the first assertion fails.
#
# Synthetic fixtures only. OSTLER_DIR and HOME point at a mktemp directory and
# launchctl is a stub on PATH, so nothing on this machine is read or changed.
# No pipe into grep -q anywhere (SIGPIPE on the producer reads as a miss).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}" "${WORK}/bin"

# 1. The helper exists in install.sh and is extracted by its exact shape.
HELPER="${WORK}/helper.sh"
sed -n '/^            _ostler_tailnet_advertise_default() {$/,/^            }$/p' "$INSTALL" \
    | sed 's/^            //' > "$HELPER"
if [[ -s "$HELPER" ]]; then
    pass "helper defined in install.sh"
else
    fail "helper _ostler_tailnet_advertise_default not defined in install.sh"
fi

# 2. It is called inside the Tailscale-connected branch, not before it.
CALL_LINE="$(grep -n '^            _ostler_tailnet_advertise_default || true$' "$INSTALL" | head -1 | cut -d: -f1)"
GATE_LINE="$(grep -n '^        if \[\[ -n "\$OSTLER_TAILSCALE_IP" \]\]; then$' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$CALL_LINE" && -n "$GATE_LINE" && "$CALL_LINE" -gt "$GATE_LINE" ]]; then
    pass "called after the OSTLER_TAILSCALE_IP success gate (call :${CALL_LINE}, gate :${GATE_LINE})"
else
    fail "helper call not found inside the Tailscale success branch (call='${CALL_LINE}' gate='${GATE_LINE}')"
fi

# stub launchctl: records calls; 'print' succeeds only when LOADED=1
cat > "${WORK}/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG}"
if [[ "$1" == "print" ]]; then [[ "${LOADED:-0}" == 1 ]]; exit $?; fi
exit 0
STUB
chmod 0755 "${WORK}/bin/launchctl"
export STUB_LOG="${WORK}/launchctl.log"

CFG_DIR="${WORK}/ostler/assistant-config"
CFG="${CFG_DIR}/config.toml"

fixture_cfg() {
    mkdir -p "$CFG_DIR"
    cat > "$CFG" <<'TOML'
[gateway]
port = 8000
paired_tokens = ["tok-a"]

[channels]
enabled = true
TOML
    chmod 0600 "$CFG"
}

run_helper() {
    # $1 = tailscale ip ("" for absent). Extra env passes through.
    : > "$STUB_LOG"
    (
        export HOME="$FAKE_HOME" OSTLER_DIR="${WORK}/ostler" PATH="${WORK}/bin:$PATH"
        export OSTLER_TAILSCALE_IP="$1"
        set +e
        # shellcheck source=/dev/null
        source "$HELPER"
        _ostler_tailnet_advertise_default || true
    )
    echo "rc=$?"
}

# 3. Connected + [gateway] present without the key: key set, rest preserved.
fixture_cfg
rc_out="$(run_helper 100.64.0.9)"
if grep -q '^companion_advertise_tailnet = true$' "$CFG" \
   && grep -q '^port = 8000$' "$CFG" && grep -q '^paired_tokens = \["tok-a"\]$' "$CFG" \
   && [[ "$rc_out" == "rc=0" ]]; then
    pass "connected: key set under [gateway], other lines preserved, rc 0"
else
    fail "connected: key not set or lines lost ($rc_out)"; cat "$CFG"
fi
MODE="$(stat -f %Lp "$CFG" 2>/dev/null || stat -c %a "$CFG")"
if [[ "$MODE" == "600" ]]; then pass "mode 0600 preserved"; else fail "mode changed to ${MODE}"; fi

# 4. Idempotent: second run leaves the file byte-identical.
before="$(cat "$CFG"; echo x)"
run_helper 100.64.0.9 >/dev/null
after="$(cat "$CFG"; echo x)"
if [[ "$before" == "$after" ]]; then pass "idempotent: second run byte-identical"; else fail "second run changed the file"; fi

# 5. Existing key = false is flipped to true, not duplicated.
fixture_cfg
sed -i.bak 's/^port = 8000$/port = 8000\ncompanion_advertise_tailnet = false/' "$CFG" && rm -f "${CFG}.bak"
run_helper 100.64.0.9 >/dev/null
COUNT="$(grep -c '^companion_advertise_tailnet' "$CFG")"
if [[ "$COUNT" == "1" ]] && grep -q '^companion_advertise_tailnet = true$' "$CFG"; then
    pass "existing false flipped to true, no duplicate key"
else
    fail "existing false: count=${COUNT}"; cat "$CFG"
fi

# 6. Not connected: file untouched, launchctl never called.
fixture_cfg
before="$(cat "$CFG"; echo x)"
rc_out="$(run_helper "")"
after="$(cat "$CFG"; echo x)"
if [[ "$before" == "$after" && "$rc_out" == "rc=0" ]]; then
    pass "not connected: config untouched, rc 0"
else
    fail "not connected: config changed or rc!=0 ($rc_out)"
fi

# 7. Config missing: rc 0, nothing created.
rm -rf "${WORK}/ostler"
rc_out="$(run_helper 100.64.0.9)"
if [[ "$rc_out" == "rc=0" && ! -e "$CFG" ]]; then
    pass "config missing: rc 0, nothing created"
else
    fail "config missing: ($rc_out) or file created"
fi

# 8. Kickstart only when the agent is already loaded.
fixture_cfg
: > "$STUB_LOG"
LOADED=0 run_helper 100.64.0.9 >/dev/null
if grep -q '^kickstart' "$STUB_LOG"; then fail "kickstart fired while agent not loaded"; else pass "not loaded: no kickstart"; fi
fixture_cfg
LOADED=1 run_helper 100.64.0.9 >/dev/null
if grep -q '^kickstart -k gui/.*com.creativemachines.ostler.assistant' "$STUB_LOG"; then
    pass "loaded: kickstart -k on the assistant label"
else
    fail "loaded: no kickstart recorded"; cat "$STUB_LOG"
fi

if [[ "$FAILS" -eq 0 ]]; then
    echo "ALL PASS"
    exit 0
fi
echo "${FAILS} FAILED"
exit 1
