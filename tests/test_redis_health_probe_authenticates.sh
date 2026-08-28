#!/bin/bash
# #550 -- install.sh's Redis health probe must work in BOTH store states.
#
# WHY THIS EXISTS. Redis has exactly two clients on a customer Hub:
#   1. vendor/doctor/agent/status_collector.py  _check_redis
#   2. install.sh's own probe, the one this tests
# The second is `docker exec ... redis-cli ping`, NOT a curl, so the
# store-caller gate (which is curl-shaped) cannot see it. Under requirepass it
# was answered "NOAUTH Authentication required.", `grep -q PONG` failed, and a
# perfectly healthy store reported as down -- which
# gui/OstlerInstaller/Views/InstallCompleteView.swift:63 turns into a warning
# on the customer's completion screen, because it greps the install log for
# "Redis healthy".
#
# THE TRAP THIS PINS. Sending AUTH to a store with NO password configured is an
# ERROR, not a no-op:
#     ERR AUTH <password> called without any password configured for the
#     default user
# so "just always authenticate" breaks every box that has not flipped, and a
# rollback with it. The probe tries keyless FIRST and escalates only on NOAUTH.
#
# Exit: 0 PASS  1 FAIL  3 CANNOT-RUN (never conflated with PASS)
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || { echo "CANNOT-RUN: no docker"; exit 3; }
docker info >/dev/null 2>&1        || { echo "CANNOT-RUN: docker daemon not reachable"; exit 3; }

# The digest install.sh pins for the store, read from the file rather than
# copied here: a test that pins its own image stops testing what ships.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$(grep -oE 'valkey/valkey@sha256:[0-9a-f]{64}' "$HERE/install.sh" | head -1)"
[ -n "$IMG" ] || { echo "CANNOT-RUN: no valkey digest found in install.sh"; exit 3; }

PW="test-only-$(openssl rand -hex 8)"
OPEN=ostler-test-redis-open
AUTH=ostler-test-redis-auth
cleanup() { docker rm -f "$OPEN" "$AUTH" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker run -d --name "$OPEN" "$IMG" valkey-server                     >/dev/null 2>&1 \
  || { echo "CANNOT-RUN: could not start the keyless store"; exit 3; }
docker run -d --name "$AUTH" "$IMG" valkey-server --requirepass "$PW" >/dev/null 2>&1 \
  || { echo "CANNOT-RUN: could not start the requirepass store"; exit 3; }
sleep 3

# Verify the two stores really are in the states the arms assume. A test whose
# fixture is not in the assumed state measures nothing.
docker exec "$OPEN" redis-cli ping 2>/dev/null | grep -q PONG \
  || { echo "CANNOT-RUN: the 'keyless' store did not answer PONG"; exit 3; }
docker exec "$AUTH" redis-cli ping 2>/dev/null | grep -q NOAUTH \
  || { echo "CANNOT-RUN: the 'requirepass' store answered without NOAUTH"; exit 3; }

# The probe under test, lifted verbatim in shape from install.sh.
probe() {
    local _ct="$1" _r
    _r="$(docker exec "$_ct" redis-cli ping 2>/dev/null | head -1)"
    if [[ "$_r" == *PONG* ]]; then printf 'PONG\n'; return 0; fi
    if [[ "$_r" == *NOAUTH* ]]; then
        [[ -n "${REDIS_PASSWORD:-}" ]] || return 1
        printf '%s' "$REDIS_PASSWORD" | docker exec -i "$_ct" \
            sh -c 'REDISCLI_AUTH="$(cat)" exec redis-cli ping' 2>/dev/null | head -1
        return 0
    fi
    return 1
}
healthy() { probe "$1" | grep -q PONG; }

REDIS_PASSWORD=""   healthy "$OPEN" && ok "keyless store, no password set"        || no "keyless store, no password set"
REDIS_PASSWORD="$PW" healthy "$OPEN" && ok "keyless store, password set -- AUTH is NOT sent" || no "keyless store, password set"
REDIS_PASSWORD="$PW" healthy "$AUTH" && ok "requirepass store, correct password"  || no "requirepass store, correct password"
REDIS_PASSWORD="a2-wrong" healthy "$AUTH" && no "requirepass store, WRONG password was accepted -- the predicate cannot fail" || ok "PROVED RED: wrong password is not healthy"
REDIS_PASSWORD=""   healthy "$AUTH" && no "requirepass store with NO password read as healthy" || ok "PROVED RED: requirepass + no password is not healthy"
REDIS_PASSWORD="$PW" healthy "ostler-test-redis-absent" && no "an absent container read as healthy" || ok "PROVED RED: absent container is not healthy"

# The credential must never reach any argv, on either side.
#
# 🔴 COMMENTS STRIPPED FIRST. The first version of this arm went RED on the
# COMMENT above the probe -- the sentence explaining why `redis-cli -a "$PW"`
# must not be used matched a predicate hunting for `redis-cli -a`. A predicate
# keyed on a NAME conflates MENTIONING with DOING, and the most likely place to
# mention a hazard is the note explaining that you avoided it.
if sed 's/#.*//' "$HERE/install.sh" \
   | grep -qE 'redis-cli[^|]*[[:space:]]-a[[:space:]]|docker exec[^|]*-e[[:space:]]+REDISCLI_AUTH='; then
    no "a Redis credential is passed on a command line -- ps -axww publishes it to every account"
else
    ok "no Redis credential on any argv (stdin only)"
fi

# ORDERING, asserted statically. config/.env is TRUNCATED by a `cat >` that
# writes a keyless REDIS_URL; the Redis auth block replaces that line. If the
# two are ever reordered the credential is silently wiped and both clients fall
# back to keyless against a store that now demands a password -- a working
# install reporting itself broken, with no error naming the cause.
_trunc="$(grep -n 'cat > "${CONFIG_DIR}/.env"' "$HERE/install.sh" | head -1 | cut -d: -f1)"
_auth="$(grep -n 'OSTLER_REDIS_AUTH_ENFORCE:-1' "$HERE/install.sh" | head -1 | cut -d: -f1)"
if [ -z "$_trunc" ] || [ -z "$_auth" ]; then
    echo "CANNOT-RUN: could not locate both the config/.env truncation and the Redis auth block"
    exit 3
elif [ "$_auth" -gt "$_trunc" ]; then
    ok "the Redis auth block runs AFTER config/.env is truncated (:$_trunc -> :$_auth)"
else
    no "the Redis auth block runs BEFORE the config/.env truncation (:$_auth then :$_trunc) -- the credential is wiped"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL REDIS HEALTH PROBE CONTROLS PASSED"
