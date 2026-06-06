#!/usr/bin/env bash
#
# tests/test_tailscale_daemon_gate.sh
#
# #644: the tailscale_connect sign-in flow must be GATED on tailscaled
# actually being up. On the .136 relaunch the daemon was down, yet the
# step still entered "Waiting for you to sign in (up to 3 minutes)" --
# a structurally doomed wait (no daemon -> no `up` URL -> no `ip`) that
# burned the full timeout (382s) before continuing.
#
# This test extracts the real `_ts_daemon_up` helper from install.sh and
# checks its discriminator against a stub `tailscale` CLI in three
# states:
#   - daemon DOWN: status prints "failed to connect to local Tailscale
#     service" -> _ts_daemon_up is false (so the wait is skipped)
#   - daemon UP, logged in: status prints a normal status -> true
#   - daemon UP, logged out: status prints "Logged out." -> true
#     (a logged-out-but-running daemon must NOT be misread as down)
#
# It also asserts, by static inspection, that the sign-in wait is
# actually wrapped in the `_ts_daemon_up` gate and that the trailing
# timeout warning is gated on TS_SIGNIN_ATTEMPTED.
#
# Pure bash. No real tailscale required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
STRINGS="${SCRIPT_DIR}/../install.sh.strings.en-GB.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"
echo "PASS: install.sh parses"

# Extract the real _ts_daemon_up helper.
HELPER="$(awk '/^    _ts_daemon_up\(\) \{/{f=1} f{print} f&&/^    \}/{exit}' "$INSTALL_SH")"
printf '%s\n' "$HELPER" | grep -q 'failed to connect' \
    || fail "could not extract _ts_daemon_up from install.sh"
# Strip the leading indentation so it defines cleanly here.
HELPER="$(printf '%s\n' "$HELPER" | sed 's/^    //')"
eval "$HELPER"
echo "PASS: extracted the real _ts_daemon_up helper"

# Stub tailscale CLI: its behaviour is driven by $TS_FAKE_STATE.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
# Only the `status` subcommand matters here; ignore --socket=... args.
for a in "$@"; do [[ "$a" == "status" ]] && SUB="status"; done
if [[ "${SUB:-}" == "status" ]]; then
    case "${TS_FAKE_STATE:-down}" in
        down)
            echo "failed to connect to local Tailscale service; is Tailscale running?" >&2
            exit 1 ;;
        up_loggedin)
            echo "100.64.0.1   ostler-hub   user@   macOS   -"
            exit 0 ;;
        up_loggedout)
            echo "Logged out."
            exit 1 ;;   # logged-out daemon returns non-zero but IS up
    esac
fi
exit 0
STUB
chmod +x "$WORK/bin/tailscale"
TS_CLI="$WORK/bin/tailscale"
TS_SOCK="$WORK/sock"   # value irrelevant; the stub ignores it

# daemon DOWN -> must read as down (gate skips the wait)
export TS_FAKE_STATE=down
if _ts_daemon_up; then
    fail "daemon DOWN wrongly read as up -- the doomed-wait gate would NOT trigger"
else
    echo "PASS: daemon down -> _ts_daemon_up false (wait is skipped)"
fi

# daemon UP, logged in -> up
export TS_FAKE_STATE=up_loggedin
_ts_daemon_up || fail "daemon up (logged in) wrongly read as down"
echo "PASS: daemon up, logged in -> _ts_daemon_up true"

# daemon UP, logged out -> still up (must not be misread as down)
export TS_FAKE_STATE=up_loggedout
_ts_daemon_up || fail "daemon up but logged out wrongly read as down (would skip a valid sign-in)"
echo "PASS: daemon up, logged out -> _ts_daemon_up true"

# ── static structure assertions ──────────────────────────────────────
grep -q 'if _ts_daemon_up; then' "$INSTALL_SH" \
    || fail "sign-in flow is not wrapped in an _ts_daemon_up gate"
echo "PASS: sign-in flow is gated on _ts_daemon_up"

grep -q 'elif \[\[ "${TS_SIGNIN_ATTEMPTED:-0}" == 1 \]\]; then' "$INSTALL_SH" \
    || fail "trailing timeout warning is not gated on TS_SIGNIN_ATTEMPTED"
echo "PASS: timeout warning only fires when sign-in was actually attempted"

grep -q 'launchctl kickstart -k' "$INSTALL_SH" \
    || fail "missing kickstart fallback for the relaunch daemon-start case"
echo "PASS: kickstart fallback present for relaunch daemon recovery"

grep -q '\.signin_skip' "$INSTALL_SH" \
    || fail "missing skip-sentinel poll in the sign-in wait"
echo "PASS: sign-in wait polls the skip sentinel"

grep -qE '^MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS=' "$STRINGS" \
    || fail "missing string MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS"
echo "PASS: set-up-later string is defined"

echo ""
echo "ALL PASS: test_tailscale_daemon_gate.sh"
