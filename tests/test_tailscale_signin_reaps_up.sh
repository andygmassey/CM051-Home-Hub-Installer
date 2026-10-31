#!/usr/bin/env bash
#
# tests/test_tailscale_signin_reaps_up.sh
#
# v1.0.121 BLOCKING: tailscale_signin backgrounded `tailscale up` and never
# killed it, so a skipped or timed-out sign-in left an orphan (ppid 1) for
# the life of the box. This extracts the REAL launch-to-reap region from
# install.sh, runs it against a fake `tailscale` that blocks forever, and
# asserts nothing survives: timeout case, skip case, plus a success control
# (an IP appears: no kill attempted by the reap branch).
#
# Pure bash. No real tailscale, no real browser (open is stubbed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
TAG="fakets-$$-${RANDOM}"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

REGION="$(awk '/up --hostname=ostler-hub/{f=1} f{print} f&&/wait "\$TS_UP_PID"/{exit}' "$INSTALL_SH")"
grep -q 'TS_UP_PID=\$!' <<< "$REGION" || fail "could not extract launch region (no TS_UP_PID capture)"
grep -q 'wait "\$TS_UP_PID"' <<< "$REGION" || fail "launch region has no reap of TS_UP_PID"
printf '%s\n' "$REGION" > "$WORK/region.sh"
echo "PASS: extracted the real launch-to-reap region ($(wc -l < "$WORK/region.sh") lines)"

mkdir -p "$WORK/bin"
# Fake tailscale: `up` blocks forever (the unique tag is in argv so the
# survivor check can find it); `ip` prints $FAKE_IP when set.
cat > "$WORK/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        ip) [[ -n "${FAKE_IP:-}" ]] && echo "$FAKE_IP"; exit 0 ;;
        up) while :; do sleep 1; done ;;
    esac
done
exit 0
STUB
chmod +x "$WORK/bin/tailscale"

survivors() { pgrep -f -- "$TAG" 2>/dev/null | grep -v -x "$$" || true; }

# run_case <name> <skip 0|1> <fake_ip>
run_case() {
    local name="$1" skip="$2" ip="$3"
    local state="$WORK/state-$name"; mkdir -p "$state"
    [[ "$skip" == 1 ]] && : > "$state/.signin_skip"
    (
        TS_CLI="$WORK/bin/tailscale"; TS_SOCK="$WORK/sock-$TAG"
        TS_UP_LOG="$WORK/up-$name.log"; TS_STATE_DIR="$state"
        TS_SKIP_SENTINEL="$state/.signin_skip"
        OSTLER_TAILSCALE_IP=""; TS_URL=""; TS_URL_WAIT=0; TS_WAIT=0; TS_NEXT_TICK=30
        OSTLER_TS_URL_WAIT=2; OSTLER_TS_SIGNIN_WAIT=3
        export FAKE_IP="$ip"
        info() { :; }; _ts_open_url() { :; }; open() { :; }
        MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS=x; MSG_INFO_TAILSCALE_STILL_WAITING=x
        MSG_INFO_TAILSCALE_SIGN_IN_URL=x; MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3=x
        # The fake carries the tag in argv via the socket path.
        # shellcheck disable=SC1091
        source "$WORK/region.sh"
        echo "$OSTLER_TAILSCALE_IP" > "$WORK/ip-$name"
    ) || fail "$name: region exited non-zero"
}

run_case timeout 0 ""
S="$(survivors)"
[[ -z "$S" ]] || fail "timeout: surviving processes carry the fake in argv: $S"
echo "PASS: timeout: 0 surviving processes with the fake in argv"

run_case skip 1 ""
S="$(survivors)"
[[ -z "$S" ]] || fail "skip: surviving processes carry the fake in argv: $S"
echo "PASS: skip: 0 surviving processes with the fake in argv"

# Success control: an IP is available at once, so the loop exits with an IP
# and the reap branch must not run (assert the IP survives to the caller).
run_case success 0 "100.64.0.9"
[[ "$(cat "$WORK/ip-success")" == "100.64.0.9" ]] || fail "success: IP not carried out"
echo "PASS: success path unchanged (IP carried out)"
# Success leaves `up` to finish on its own (unchanged); clear this test's own
# fake by its unique tag so the control below starts from a clean slate.
pkill -f -- "$TAG" 2>/dev/null || true; sleep 1
[[ -z "$(survivors)" ]] || fail "could not clear the success-case fake"

# The control that proves the survivor check can see a survivor: launch one
# on purpose and require the predicate to find it, then kill that own pid.
( exec "$WORK/bin/tailscale" --socket="$WORK/sock-$TAG" up ) & CPID=$!
sleep 1
[[ -n "$(survivors)" ]] || { kill "$CPID" 2>/dev/null; fail "control: survivor predicate is blind"; }
kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
echo "PASS: control: survivor predicate sees a live fake"
echo "ALL PASS"
