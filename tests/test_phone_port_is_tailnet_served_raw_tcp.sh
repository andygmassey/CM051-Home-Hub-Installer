#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_phone_port_is_tailnet_served_raw_tcp.sh
#
# v1.0.108, wow-moment #10: the phone works away from home. The QR now carries
# hub_tailnet_addr (ostler-assistant, companion_advertise_tailnet default ON),
# so the Hub's companion port 8443 must be reachable on the tailnet IP. That is
# what `tailscale serve --bg --tcp=8443 tcp://localhost:8443` does.
#
# THE TWO WAYS THIS GOES WRONG IN SILENCE
#   * a TLS-TERMINATING serve (--https, --tls-terminated-tcp) answers with
#     Tailscale's certificate, the app's SPKI pin does not match, and every
#     off-LAN connection fails closed with no installer-side symptom;
#   * a serve nobody removes outlives the uninstall.
#
# WHAT THIS RUNS (behaviour, not a grep of the flag): the installer's serve loop
# and the uninstaller's _u_tailscale_unserve are EXTRACTED from install.sh and
# executed against a stub `tailscale` that records every call and models serve
# state. Controls: a stub that fails must produce a warn and not abort; the
# loop must still serve 8089; a TLS flag anywhere in the 8443 call is a FAIL.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"
[[ -f "$INSTALL_SH" && -f "$STRINGS" ]] || { echo "CANNOT-RUN: install.sh or its strings file missing (exit 2)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 needed to make a unix socket (exit 2)" >&2; exit 2; }

_fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

W="$(mktemp -d /tmp/pp.XXXXXX)" || { echo "CANNOT-RUN: mktemp (exit 2)" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

# ── Extract the installer's serve loop ─────────────────────────────────────
awk '/^            for _ts_port in /{f=1} f{print} /^            unset _ts_port$/{if(f) exit}' "$INSTALL_SH" > "$W/loop.sh"
if [[ "$(wc -l < "$W/loop.sh")" -lt 5 ]] || ! grep -q 'unset _ts_port' "$W/loop.sh"; then
    echo "CANNOT-RUN: could not extract the serve loop from install.sh (exit 2)" >&2; exit 2
fi
# ── Extract the uninstaller helper ─────────────────────────────────────────
awk '/^_u_tailscale_unserve\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$INSTALL_SH" > "$W/unserve.sh"
if ! grep -q '_u_tailscale_unserve' "$W/unserve.sh" || [[ "$(wc -l < "$W/unserve.sh")" -lt 5 ]]; then
    bad "install.sh defines no _u_tailscale_unserve (the uninstaller does not remove the 8443 forward)"
    UNSERVE_MISSING=1
fi

# Stub tailscale: records argv, models serve state in $W/state, FAIL_ON makes a port fail.
cat > "$W/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
args=" $* "
for p in $FAIL_ON; do case "$args" in *"--tcp=$p "*) exit 1 ;; esac; done
case "$args" in
  *" serve "*" off "*) p="${args#*--tcp=}"; p="${p%% *}"; grep -vx "$p" "$STUB_STATE" > "$STUB_STATE.n" 2>/dev/null; mv "$STUB_STATE.n" "$STUB_STATE" 2>/dev/null; touch "$STUB_STATE" ;;
  *" serve "*) p="${args#*--tcp=}"; p="${p%% *}"; grep -qx "$p" "$STUB_STATE" 2>/dev/null || echo "$p" >> "$STUB_STATE" ;;
esac
exit 0
STUB
chmod +x "$W/tailscale"
export STUB_LOG="$W/calls.log" STUB_STATE="$W/state"

run_loop() { # $1 = FAIL_ON list
    : > "$STUB_LOG"
    FAIL_ON="$1" bash -c '
        info() { echo "INFO: $*"; }; warn() { echo "WARN: $*"; }
        . "'"$STRINGS"'"
        TS_CLI="'"$W"'/tailscale"; TS_SOCK="'"$W"'/sock"
        . "'"$W"'/loop.sh"
    '
}

echo "installer serve loop"
: > "$STUB_STATE"
out="$(run_loop "")"
if grep -qx -- "--socket=$W/sock serve --bg --tcp=8443 tcp://localhost:8443" "$STUB_LOG"; then
    ok "1 8443 is served as raw TCP passthrough: serve --bg --tcp=8443 tcp://localhost:8443"
else bad "1 no raw-TCP passthrough call for 8443; calls: $(tr '\n' '|' < "$STUB_LOG")"; fi
if [ "$(grep -E -- '8443' "$STUB_LOG" | grep -Ec -- '--https|--tls-terminated|--http=|https\+insecure|https://')" -gt 0 ]; then
    bad "2 the 8443 serve terminates TLS, which breaks the app's SPKI pin"
else ok "2 the 8443 serve call carries no TLS-terminating flag"; fi
grep -q -- '--tcp=8089 ' "$STUB_LOG" && ok "3 8089 is still served" || bad "3 8089 is no longer served"
if grep -q "^INFO: .*8443" <<< "$out"; then ok "4 the 8443 serve is logged"; else bad "4 no INFO line names 8443; output: $out"; fi
run_loop "" >/dev/null
if [[ "$(grep -cx 8443 "$STUB_STATE")" -eq 1 ]]; then ok "5 idempotent: running it twice leaves ONE 8443 forward"; else bad "5 re-run stacked forwards: $(tr '\n' ' ' < "$STUB_STATE")"; fi
out="$(run_loop "8443")"
if grep -q "^WARN: .*8443" <<< "$out" && grep -q -- '--tcp=8089 ' "$STUB_LOG"; then
    ok "6 control: a failing 8443 serve warns and does not abort the loop"
else bad "6 a failing 8443 serve was silent or aborted: $out"; fi

echo "uninstaller"
if [[ -z "${UNSERVE_MISSING:-}" ]]; then
    mkdir -p "$W/home/.ostler/tailscale"
    python3 - "$W/home/.ostler/tailscale/tailscaled.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])
PY
    echo 8443 > "$STUB_STATE"; echo 8089 >> "$STUB_STATE"; : > "$STUB_LOG"
    out="$(HOME="$W/home" OSTLER_DIR="$W/home/.ostler" PATH="$W:$PATH" FAIL_ON="" bash -c ". '$W/unserve.sh'; _u_tailscale_unserve")"
    if grep -q -- 'serve --tcp=8443 off' "$STUB_LOG" && ! grep -qx 8443 "$STUB_STATE"; then ok "7 the uninstaller removes the 8443 forward"; else bad "7 uninstall left the 8443 forward; calls: $(tr '\n' '|' < "$STUB_LOG")"; fi
    grep -qx 8089 "$STUB_STATE" && ok "8 it removes only 8443 (8089 untouched)" || bad "8 it also removed 8089"
    grep -q "Removed the tailnet forward for port 8443" <<< "$out" && ok "9 the removal is logged" || bad "9 the removal printed nothing"
    out="$(HOME="$W/none" OSTLER_DIR="$W/none/.ostler" PATH="$W:$PATH" bash -c ". '$W/unserve.sh'; _u_tailscale_unserve; echo rc=\$?")"
    grep -q 'rc=0' <<< "$out" && ok "10 control: no Tailscale daemon is a logged no-op, rc 0" || bad "10 no-daemon case failed: $out"
fi

echo "$(( _fails )) failed"
[[ $_fails -eq 0 ]]
