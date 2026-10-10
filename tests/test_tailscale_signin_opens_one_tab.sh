#!/usr/bin/env bash
#
# tests/test_tailscale_signin_opens_one_tab.sh
#
# #16 console walk: the Tailscale sign-in opened TWO Safari tabs, every
# time. install.sh opened the login URL with `open -a Safari "$TS_URL"` and
# then UNCONDITIONALLY re-issued the same open 4s later in the background,
# so whenever the first open worked (the normal case) the customer got a
# second, identical tab.
#
# This test extracts the REAL sign-in URL block and the real _ts_open_url
# helper from install.sh and runs them with `open` and `sleep` stubbed on
# PATH. The `open` stub records every invocation and whether it "opened"
# the URL. Two arms:
#
#   A. Safari opens the URL first time (the normal case): the URL must be
#      opened exactly ONCE.
#   B. `open -a Safari` fails: the fallback chain must still open it, and
#      still exactly once (no tab is lost by the fix).
#
# The denominator is printed: every `open` invocation the block made, and
# how many of them opened the URL.
#
# Pure bash. No Safari, no Tailscale, no osascript.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"

# The real _ts_open_url helper (4-space indent in install.sh).
HELPER="$(awk '/^    _ts_open_url\(\) \{/{f=1} f{print} f&&/^    \}/{exit}' "$INSTALL_SH" | sed 's/^    //')"
printf '%s\n' "$HELPER" | grep -q 'Google Chrome' || fail "could not extract _ts_open_url from install.sh"

# The real sign-in URL block: from the `if [[ -n "$TS_URL" ]]; then` that
# surfaces the URL, to its matching `fi` at the same 12-space indent.
BLOCK="$(awk '/^            if \[\[ -n "\$TS_URL" \]\]; then$/{f=1} f{print} f&&/^            fi$/{exit}' "$INSTALL_SH")"
printf '%s\n' "$BLOCK" | grep -q 'MSG_INFO_TAILSCALE_SIGN_IN_URL' || fail "could not extract the sign-in URL block from install.sh"
printf '%s\n' "$BLOCK" | grep -q 'open' || fail "the extracted block opens nothing; extraction is wrong"
echo "PASS: extracted the real _ts_open_url helper and sign-in URL block"

mkdir -p "$WORK/bin"
# `open` stub: logs "<rc> <args>" per call. OPEN_FAIL_SAFARI=1 makes
# `open -a Safari <url>` fail (exit 1) while every other form succeeds.
cat > "$WORK/bin/open" <<'STUB'
#!/usr/bin/env bash
rc=0
if [[ "${OPEN_FAIL_SAFARI:-0}" == "1" && "${1:-}" == "-a" && "${2:-}" == "Safari" ]]; then rc=1; fi
printf '%s %s\n' "$rc" "$*" >> "$OPEN_LOG"
exit "$rc"
STUB
# `sleep` stub: the background re-issue (if any) must not slow the test,
# and must still run, so it is a no-op rather than absent.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/open" "$WORK/bin/sleep"

TS_URL_FIXTURE="https://login.tailscale.com/a/synthetic0000"

run_arm() {
    # run_arm <fail_safari 0|1>; prints "<invocations> <url_opens>"
    local log="$WORK/open.$1.log"
    : > "$log"
    PATH="$WORK/bin:$PATH" OPEN_LOG="$log" OPEN_FAIL_SAFARI="$1" TS_URL="$TS_URL_FIXTURE" \
        HELPER="$HELPER" BLOCK="$BLOCK" bash -c '
            info() { :; }
            MSG_INFO_TAILSCALE_SIGN_IN_URL="sign in at %s"
            eval "$HELPER"
            eval "$BLOCK"
            wait
        ' >/dev/null 2>&1
    local calls opens
    calls="$(grep -c . "$log" || true)"
    opens="$(grep -F -- "$TS_URL_FIXTURE" "$log" | grep -c '^0 ' || true)"
    echo "$calls $opens"
}

status=0
read -r calls opens <<<"$(run_arm 0)"
echo "arm A (Safari opens first time): ${calls} open invocation(s), ${opens} opened the URL"
if [[ "$opens" -ne 1 ]]; then
    echo "FAIL: arm A opened the sign-in URL ${opens} times; the customer gets ${opens} tabs (want 1)"
    status=1
else
    echo "PASS: arm A opened the sign-in URL exactly once"
fi

read -r calls opens <<<"$(run_arm 1)"
echo "arm B (open -a Safari fails): ${calls} open invocation(s), ${opens} opened the URL"
if [[ "$opens" -ne 1 ]]; then
    echo "FAIL: arm B opened the sign-in URL ${opens} times (want 1: the fallback chain must still open it, once)"
    status=1
else
    echo "PASS: arm B: the fallback chain opened the sign-in URL exactly once"
fi

# Control: the stub can see a second open. Opening twice by hand must count 2.
log="$WORK/open.control.log"; : > "$log"
PATH="$WORK/bin:$PATH" OPEN_LOG="$log" bash -c "open -a Safari '$TS_URL_FIXTURE'; open -a Safari '$TS_URL_FIXTURE'"
n="$(grep -F -- "$TS_URL_FIXTURE" "$log" | grep -c '^0 ' || true)"
[[ "$n" -eq 2 ]] || { echo "FAIL: control: two opens counted as ${n}; the counter is blind"; status=1; }
[[ "$n" -eq 2 ]] && echo "PASS: control: the counter sees a second open (2 of 2)"

exit "$status"
