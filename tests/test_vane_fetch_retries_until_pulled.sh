#!/bin/bash
# WEB SEARCH DOWNLOADS IN THE BACKGROUND AND RETRIES UNTIL IT LANDS (v1.0.118 W5/W8).
#
# v1.0.117, console install: the in-install Vane pull died with "short read:
# expected 237669906 bytes but got 41943040: unexpected EOF", the step closed
# `unmeasured`, and the install said DONE with 0 failed steps while web search
# was missing. A manual retry died at the same 40 MiB on another blob.
#
# install.sh now writes ~/.ostler/bin/ostler-vane-fetch (a quoted heredoc) and
# runs it from a LaunchAgent. This test EXTRACTS THAT HEREDOC FROM install.sh
# (the bytes that ship, not a copy) and drives it against a fake docker that
# fails with the measured short read a set number of times:
#
#   1. fails 3 times then succeeds -> ready after try 4, backoff 60/120/300,
#      and "ready" only after the CREDENTIALLED check answered
#   2. always fails -> exit 75, state=waiting, 8 tries, the short read named
#   3. waits while the install that started it is still running
#   4. pulled and up, but the credential is refused -> NOT ready
#   5. a second run while one holds the lock does not pull again
#   6. the pinned image ref is read from the vane service, not a sibling
#   7. image already local -> up-if-present starts it without pulling
#   CONTROL: the same fake with only 1 try allowed must NOT reach ready, so
#   case 1's green is the retry loop's and not the fake's.
#
# Exit: 0 pass, 1 fail, 2 cannot-run. Runs under /bin/bash 3.2.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

[ -r "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh at ${INSTALL}"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FETCH="${T}/ostler-vane-fetch"
awk '/<<.OSTLER_VANE_FETCH_EOF.$/{on=1; next} /^OSTLER_VANE_FETCH_EOF$/{on=0} on' "$INSTALL" > "$FETCH"
if [ ! -s "$FETCH" ]; then
    echo "FAIL: install.sh carries no ostler-vane-fetch heredoc, so nothing downloads web search in the background"
    exit 1
fi
chmod 755 "$FETCH"
/bin/bash -n "$FETCH" || { echo "FAIL: the shipped fetcher does not parse under /bin/bash"; exit 1; }

# ── fakes ──────────────────────────────────────────────────────────────
mkdir -p "${T}/bin"
cat > "${T}/bin/docker" <<'EOF'
#!/bin/bash
F="${FAKE:?}"
echo "$*" >> "${F}/calls"
case "$1" in
    image) [ -f "${F}/image_present" ] && exit 0; exit 1 ;;
    inspect) if [ -f "${F}/running" ]; then echo true; else echo "Error: No such object: ostler-vane" >&2; exit 1; fi ;;
    compose)
        case " $* " in
            *" pull vane "*)
                n=$(( $(cat "${F}/pull_count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${F}/pull_count"
                if [ "$n" -le "$(cat "${F}/fail_times")" ]; then
                    echo " 1a2b3c4d5e6f Pull complete"
                    echo " 7a8b9c0d1e2f Downloading [====>    ] 41.94MB/237.7MB"
                    echo "failed to copy: short read: expected 237669906 bytes but got 41943040: unexpected EOF" >&2
                    exit 1
                fi
                echo " 1a2b3c4d5e6f Already exists"; echo " 7a8b9c0d1e2f Pull complete"; echo " 9f8e7d6c5b4a Pull complete"
                : > "${F}/image_present"; exit 0 ;;
            *" up -d vane "*) [ -f "${F}/image_present" ] || exit 1; : > "${F}/running"; exit 0 ;;
        esac ;;
esac
exit 0
EOF
cat > "${T}/bin/curl" <<'EOF'
#!/bin/bash
F="${FAKE:?}"
cfg="$(cat)"
want="user = \"ostler:$(cat "${F}/secret")\""
if [ -f "${F}/running" ] && [ "$cfg" = "$want" ] && [ ! -f "${F}/refuse_credential" ]; then printf 200; else printf 401; fi
EOF
cat > "${T}/bin/fakesleep" <<'EOF'
#!/bin/bash
echo "$1" >> "${FAKE:?}/sleeps"
[ -f "${FAKE}/rm_marker_on_sleep" ] && rm -f "${FAKE}/marker"
exit 0
EOF
chmod 755 "${T}/bin/"*

# setup <case> <fail_times>: a fresh fake box
setup() {
    FAKE="${T}/$1"; export FAKE
    rm -rf "$FAKE"; mkdir -p "${FAKE}/hm/.ostler/secrets" "${FAKE}/hm/.ostler/state"
    printf '%s\n' "$2" > "${FAKE}/fail_times"
    printf 'synthetic-pass-word' > "${FAKE}/secret"
    printf 'synthetic-pass-word\n' > "${FAKE}/hm/.ostler/secrets/vane_password"
    cat > "${FAKE}/hm/.ostler/docker-compose.yml" <<'EOF'
services:
  qdrant:
    image: example.invalid/qdrant@sha256:1111
  vane:
    image: example.invalid/vane@sha256:2222  # mirrored
    container_name: ostler-vane
  store-proxy:
    image: example.invalid/nginx@sha256:3333
EOF
}

fetch() {   # runs the shipped fetcher against the current fake box
    HOME="${FAKE}/hm" OSTLER_DIR="${FAKE}/hm/.ostler" \
    OSTLER_VANE_DOCKER="${T}/bin/docker" OSTLER_VANE_CURL="${T}/bin/curl" \
    OSTLER_VANE_FETCH_SLEEP="${T}/bin/fakesleep" OSTLER_VANE_HEALTH_WAIT_S=0 \
    OSTLER_VANE_INSTALL_MARKER="${FAKE}/marker" \
    "$@"
}
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}[,}].*/\1/p" "${FAKE}/hm/.ostler/state/vane-fetch.json" 2>/dev/null; }

echo "== 1. three short reads, then the pull lands =="
setup c1 3
fetch /bin/bash "$FETCH" run; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit ${rc}, expected 0"
[ "$(field state)" = ready ] && ok "state=ready" || bad "state=$(field state), expected ready"
[ "$(field attempt)" = 4 ] && ok "ready on try 4" || bad "attempt=$(field attempt), expected 4"
[ "$(tr '\n' ' ' < "${FAKE}/sleeps" 2>/dev/null)" = "60 120 300 " ] && ok "backoff 60 120 300 between tries" \
    || bad "sleeps were '$(tr '\n' ' ' < "${FAKE}/sleeps" 2>/dev/null)'"
grep -q 'up -d vane' "${FAKE}/calls" && ok "started the container after the pull" || bad "never ran up -d vane"
grep -q 'short read' "${FAKE}/hm/.ostler/logs/vane-fetch.log" && ok "each failed try is logged with docker's own error" \
    || bad "the log does not carry the short read"

echo "== CONTROL: one try only, same fake, must NOT reach ready =="
setup c1ctl 3
fetch env OSTLER_VANE_FETCH_MAX_TRIES=1 /bin/bash "$FETCH" run; rc=$?
[ "$rc" -eq 75 ] && [ "$(field state)" != ready ] && ok "with no retries the same fake stays not-ready (rc=75, state=$(field state)), so case 1 is the loop's work" \
    || bad "control reached state=$(field state) rc=${rc} without retrying: the fake cannot fail"

echo "== 2. it never lands =="
setup c2 always_999
printf '999\n' > "${FAKE}/fail_times"
fetch /bin/bash "$FETCH" run; rc=$?
[ "$rc" -eq 75 ] && ok "exit 75 (not ready yet, launchd tries again)" || bad "exit ${rc}, expected 75"
[ "$(field state)" = waiting ] && ok "state=waiting" || bad "state=$(field state), expected waiting"
[ "$(field attempt)" = 8 ] && [ "$(cat "${FAKE}/pull_count")" = 8 ] && ok "8 tries, bounded" || bad "attempt=$(field attempt) pulls=$(cat "${FAKE}/pull_count")"
[ "$(wc -l < "${FAKE}/sleeps" | tr -d ' ')" = 7 ] && ok "7 backoff waits" || bad "$(wc -l < "${FAKE}/sleeps") waits"
_total=0; while read -r s; do _total=$((_total + s)); done < "${FAKE}/sleeps"
[ "$_total" -ge 3600 ] && [ "$_total" -le 9000 ] && ok "backoff totals ${_total}s (about 1-2.5 h of waiting per run)" || bad "backoff totals ${_total}s"
field last_error | grep -q 'short read' && ok "last_error names the short read" || bad "last_error='$(field last_error)'"
grep -q 'up -d vane' "${FAKE}/calls" && bad "started a container that never pulled" || ok "never claimed or started what it did not pull"

echo "== 3. waits for the install that started it =="
setup c3 0
sleep 300 & holder=$!
printf 'pid=%s\n' "$holder" > "${FAKE}/marker"
: > "${FAKE}/rm_marker_on_sleep"
fetch /bin/bash "$FETCH" run; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$(head -n 1 "${FAKE}/sleeps" 2>/dev/null)" = 30 ] && ok "deferred (polled every 30 s) while the install marker's pid was alive" \
    || bad "did not defer: sleeps='$(tr '\n' ' ' < "${FAKE}/sleeps" 2>/dev/null)'"
[ "$rc" -eq 0 ] && [ "$(field state)" = ready ] && ok "then pulled and reached ready" || bad "rc=${rc} state=$(field state)"
setup c3b 0
printf 'pid=999999\n' > "${FAKE}/marker"
fetch /bin/bash "$FETCH" run
[ ! -s "${FAKE}/sleeps" ] && ok "a dead install's leftover marker does not hold it back" || bad "waited on a dead pid"

echo "== 4. pulled, but :3000 refuses the install's own credential =="
setup c4 0
: > "${FAKE}/refuse_credential"
fetch env OSTLER_VANE_FETCH_MAX_TRIES=2 /bin/bash "$FETCH" run; rc=$?
[ "$(field state)" != ready ] && ok "not ready while the credentialled check fails (state=$(field state))" || bad "wrote ready without a credentialled answer"
[ "$rc" -ne 0 ] && ok "exit ${rc}, not 0" || bad "exit 0 without a credentialled answer"

echo "== 5. one run at a time =="
setup c5 0
sleep 300 & holder=$!
mkdir -p "${FAKE}/hm/.ostler/state/vane-fetch.lock"; printf '%s\n' "$holder" > "${FAKE}/hm/.ostler/state/vane-fetch.lock/pid"
fetch /bin/bash "$FETCH" run; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc" -eq 0 ] && [ ! -f "${FAKE}/pull_count" ] && ok "a live lock holder is left alone; no second pull" || bad "rc=${rc} pulls=$(cat "${FAKE}/pull_count" 2>/dev/null)"
setup c5b 0
mkdir -p "${FAKE}/hm/.ostler/state/vane-fetch.lock"; printf '999999\n' > "${FAKE}/hm/.ostler/state/vane-fetch.lock/pid"
fetch /bin/bash "$FETCH" run
[ "$(field state)" = ready ] && ok "a dead holder's stale lock is taken over" || bad "stale lock blocked it (state=$(field state))"

echo "== 6. the pinned ref is the vane service's =="
setup c6 0
ref="$(fetch /bin/bash "$FETCH" image-ref)"
[ "$ref" = "example.invalid/vane@sha256:2222" ] && ok "image-ref=${ref}" || bad "image-ref='${ref}'"

echo "== 7. image already local: start it, no pull =="
setup c7 0
: > "${FAKE}/image_present"
fetch /bin/bash "$FETCH" up-if-present; rc=$?
[ "$rc" -eq 0 ] && [ "$(field state)" = ready ] && ok "up-if-present -> ready" || bad "rc=${rc} state=$(field state)"
grep -q 'pull vane' "${FAKE}/calls" && bad "pulled an image that was already local" || ok "no pull"
setup c7b 0
fetch /bin/bash "$FETCH" up-if-present; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'up -d vane' "${FAKE}/calls" && ok "absent image: up-if-present declines in seconds, starts nothing" || bad "rc=${rc}"

echo
echo "== ${pass} pass / ${fail} fail =="
[ "$fail" -eq 0 ]
