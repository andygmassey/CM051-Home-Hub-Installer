#!/usr/bin/env bash
#
# tests/test_tailscale_signin_never_aborts.sh
#
# v1.0.124 install-abort: a tester's install died in step tailscale_signin
# (DONE ERR-99-INSTALL-ABORT-tailscale_signin) after the first "still waiting"
# tick, with the tailscale CLI wedged mid-login. The sign-in wait must NEVER
# abort the install: on a hung, failing or empty tailscale, or an unbound
# variable inside the block, it finishes unpaired and the install carries on.
#
# Extracts the REAL helper + sign-in block from install.sh and runs it under
# /bin/bash with the installer's own `set -Eeuo pipefail` and an armed ERR
# trap. RED/GREEN: INSTALL_SH=<unfixed install.sh> must FAIL this test.
# Mutants (guard removed / bound removed) must also FAIL, checked in-test.
# Pure bash; tailscale and open are stubs. No real browser, no keychain.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-${SCRIPT_DIR}/../install.sh}"
WORK="$(mktemp -d)"
TAG="fakets-$$-${RANDOM}"
trap 'pkill -f -- "$TAG" 2>/dev/null; rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

awk '/^    _ts_daemon_up\(\) \{$/{f=1} f{print} f&&/^    \}$/{exit}' "$INSTALL_SH" > "$WORK/daemon_up.sh"
awk '/^    _ts_bounded\(\) \{$/{f=1} f{print} f&&/^    \}$/{exit}' "$INSTALL_SH" > "$WORK/helper.sh"
awk '/^        # #644 (gate|idempotency)/{f=1} f{print} f&&/^        eval "\$_ts_saved_err_trap"/{exit}' "$INSTALL_SH" > "$WORK/region.full.sh"
# The unfixed block has no restore line: take through the elif's closing fi.
grep -q '_ts_saved_err_trap=' "$INSTALL_SH" || \
    awk '/^        # #644 (gate|idempotency)/{f=1} f{print} f&&/^        fi$/&&seen{exit} f&&/MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED/{seen=1}' "$INSTALL_SH" > "$WORK/region.full.sh"
grep -q 'TS_UP_PID=\$!' "$WORK/region.full.sh" || fail "could not extract the sign-in block"
echo "PASS: extracted sign-in block ($(wc -l < "$WORK/region.full.sh") lines) and helper ($(wc -l < "$WORK/helper.sh") lines)"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tailscale" <<STUB
#!/usr/bin/env bash
# $TAG
case "\$FAKE_MODE" in
  hang)  sleep 300 ;;
  fail)  for a in "\$@"; do [[ "\$a" == up ]] && { echo "To authenticate, visit: https://login.tailscale.com/a/xyz"; sleep 300; }; done; echo "NeedsLogin" ; exit 1 ;;
  skip)  for a in "\$@"; do [[ "\$a" == up ]] && { : > "\$SKIPFILE"; sleep 300; }; done; exit 1 ;;
  empty) for a in "\$@"; do [[ "\$a" == up ]] && sleep 300; done; exit 0 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/open"
chmod +x "$WORK/bin/tailscale" "$WORK/bin/open"

# run_case <name> <mode> <region file> [unset a message var: 1]
run_case() {
    local name="$1" mode="$2" region="$3" unbound="${4:-0}"
    cat > "$WORK/h-$name.sh" <<H
set -Eeuo pipefail
trap 'echo "ERRTRAP rc=\$? line=\$LINENO" >&2; exit 97' ERR
export PATH="$WORK/bin:\$PATH" FAKE_MODE=$mode OSTLER_TS_URL_WAIT=2 OSTLER_TS_SIGNIN_WAIT=${SIGNIN_WAIT:-4} SKIPFILE="$WORK/st-$name/.signin_skip" OSTLER_TS_CALL_TIMEOUT=1
info(){ :; }; warn(){ :; }
TS_CLI="$WORK/bin/tailscale"; TS_SOCK="$WORK/sock"; TS_STATE_DIR="$WORK/st-$name"; mkdir -p "\$TS_STATE_DIR"
LOGS_DIR="$WORK"; OSTLER_TAILSCALE_IP=""
source "$WORK/daemon_up.sh"
_ts_open_url() { return 1; }
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN=a; MSG_INFO_TAILSCALE_SIGN_IN_URL="u %s"; MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3=w
MSG_INFO_TAILSCALE_STILL_WAITING="s %s"; MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS=l
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN=t; MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED=r
[[ "$unbound" == 1 ]] && unset MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3
[[ -f "$WORK/helper.sh" ]] && source "$WORK/helper.sh"
source "$region"
case "\$-" in *e*u*|*u*e*) ;; *) echo "OPTS_NOT_RESTORED \$-" >&2; exit 96;; esac
trap -p ERR | grep -q ERRTRAP || { echo "ERR_TRAP_NOT_RESTORED" >&2; exit 95; }
echo REGION_COMPLETED
H
    /bin/bash "$WORK/h-$name.sh" > "$WORK/out-$name" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 120 ]]; do sleep 0.5; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "HUNG>60s" >> "$WORK/out-$name"; return 124; fi
    wait "$pid"; return $?
}

check() { # <name> <mode> <region> [unbound]  -> 0 if the block completed cleanly
    run_case "$@"; local rc=$?
    pkill -f -- "$WORK/bin/tailscale" 2>/dev/null   # orphaned fakes from the previous case
    grep -q REGION_COMPLETED "$WORK/out-$1" && [[ $rc -eq 0 ]]
}

# Skip arm (#3344): the GUI writes .signin_skip during the URL poll; the bounded wait must
# end within a tick (60s window, must finish well under it) and not be cleared before the loop.
SIGNIN_WAIT=60; t0=$SECONDS
check skip skip "$WORK/region.full.sh" || fail "skip: block did not complete: $(tr '\n' ' ' < "$WORK/out-skip" | cut -c1-200)"
[[ $((SECONDS - t0)) -lt 30 ]] || fail "skip: sentinel written but the wait ran $((SECONDS - t0))s of a 60s window"
echo "PASS: skip: .signin_skip written during the URL poll ended the wait in $((SECONDS - t0))s"
SIGNIN_WAIT=4
for spec in "hang:hang:0" "fail:fail:0" "empty:empty:0" "unbound:fail:1"; do
    IFS=: read -r n m u <<< "$spec"
    check "$n" "$m" "$WORK/region.full.sh" "$u" || fail "$n: sign-in block did not complete under -Eeuo: $(tr '\n' ' ' < "$WORK/out-$n" | cut -c1-200)"
    echo "PASS: $n: block finished, shell options and ERR trap intact"
done

# Mutants: each must turn at least one case red, or the cases prove nothing.
mutant() { # <label> <sed expr> <name> <mode> [unbound]
    sed "$2" "$WORK/region.full.sh" > "$WORK/mut-$1.sh"
    cmp -s "$WORK/mut-$1.sh" "$WORK/region.full.sh" && fail "mutant $1 did not apply"
    if check "m$1" "$4" "$WORK/mut-$1.sh" "${5:-0}"; then fail "mutant $1 SURVIVED (case $3 stayed green)"; fi
    echo "PASS: mutant $1 killed by case $3"
}
if grep -q '_ts_saved_opts=' "$WORK/region.full.sh"; then
    mutant noguard 's/set +eu  # restored.*$/:/' unbound fail 1
    mutant nobound 's/_ts_bounded "\${OSTLER_TS_CALL_TIMEOUT:-8}" //g' hang hang
fi
# Skip mutant: dropping the in-loop sentinel check must turn the skip arm red.
sed 's/if \[\[ -f "\$TS_SKIP_SENTINEL" \]\]; then/if false; then/' "$WORK/region.full.sh" > "$WORK/mut-noskip.sh"
cmp -s "$WORK/mut-noskip.sh" "$WORK/region.full.sh" && fail "mutant noskip did not apply"
SIGNIN_WAIT=60; t0=$SECONDS; check mnoskip skip "$WORK/mut-noskip.sh"; [[ $((SECONDS - t0)) -ge 30 ]] || fail "mutant noskip SURVIVED"
SIGNIN_WAIT=4; echo "PASS: mutant noskip killed (wait ran the full window)"
echo "ALL PASS"
