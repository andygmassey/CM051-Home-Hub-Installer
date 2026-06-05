#!/usr/bin/env bash
#
# tests/test_colima_start_retry.sh
#
# Regression test for the CX-80 (task #509, v1.0.1) Colima cold-start
# self-heal.
#
# What it guards
# --------------
# The lima hostagent that backs Colima forwards the guest Docker socket
# port asynchronously after `colima start` returns. On a cold first
# boot the port-discovery can race, so `colima start` either exits
# non-zero or exits 0 with the socket still unforwarded -- the next
# `docker info` then cannot reach the daemon. The pre-fix single-shot
# `colima start || fallback` had no retry, so one transient miss dropped
# the customer straight to the Docker Desktop fallback / hard fail even
# though a plain retry recovers it.
#
# This test walks install.sh's text and asserts the bounded retry loop
# with backoff + per-attempt logging + in-loop docker-info readiness
# re-check exists around `colima start`, per the silent-bail
# regression-test discipline, so a future edit that removes the retry
# trips this test.
#
# Pure bash + standard tools. Exit 0 on pass, non-zero on fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail_test "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || fail_test "strings file not found at $STRINGS_FILE"

bash -n "$INSTALL_SH" || fail_test "install.sh fails bash -n parse check"
echo "PASS: install.sh parses"

# Narrow to the cold-start retry region: from the "Starting Colima"
# info line up to the Docker-Desktop fallback warn.
REGION="$(awk '/MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME/{c=1}
               c{print}
               /MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP/{if(c){exit}}' "$INSTALL_SH")"
[[ -n "$REGION" ]] || fail_test "could not locate the Colima cold-start region"

grep -q 'COLIMA_START_MAX_ATTEMPTS=' <<<"$REGION" || fail_test "no bounded attempt cap (COLIMA_START_MAX_ATTEMPTS)"
grep -q 'COLIMA_START_BACKOFF=' <<<"$REGION" || fail_test "no inter-attempt backoff (COLIMA_START_BACKOFF)"
grep -Eq 'for[[:space:]]+colima_attempt[[:space:]]+in' <<<"$REGION" || fail_test "no per-attempt retry loop"
echo "PASS: bounded retry loop with backoff present"

# The success condition inside the loop must re-check docker readiness,
# not just trust `colima start`'s exit code (the whole point of CX-80).
grep -Eq 'colima start .*&&[[:space:]]*\\?[[:space:]]*$' <<<"$REGION" \
    || grep -Eq 'colima start .*\\$' <<<"$REGION" \
    || fail_test "colima start success not chained to a readiness check"
grep -q 'docker info' <<<"$REGION" || fail_test "no in-loop 'docker info' readiness re-check"
echo "PASS: in-loop docker-info readiness re-check present"

# Between attempts the half-started instance must be cleared so the next
# start re-runs port-discovery from a clean state.
grep -q 'colima stop' <<<"$REGION" || fail_test "no 'colima stop' between attempts to clear a half-started instance"
echo "PASS: half-started instance cleared between attempts"

# Per-attempt logging must surface (so a stuck retry is visible).
grep -q 'MSG_INFO_COLIMA_START_ATTEMPT' <<<"$REGION" || fail_test "no per-attempt info log"
grep -q 'MSG_WARN_COLIMA_START_RETRY' <<<"$REGION" || fail_test "no retry warn log"
echo "PASS: per-attempt logging present"

# The fallback / hard-fail must still exist AFTER the retries are spent.
grep -q 'colima_started' <<<"$REGION" || fail_test "no colima_started success flag gating the fallback"
grep -q 'ERR-06-DOCKER-COLIMA-FAIL\|MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP' "$INSTALL_SH" \
    || fail_test "the Docker Desktop fallback / hard-fail was lost"
echo "PASS: fallback preserved after retries exhausted"

# Strings exist in the catalogue.
for key in MSG_INFO_COLIMA_START_ATTEMPT MSG_WARN_COLIMA_START_RETRY; do
    grep -q "^${key}=" "$STRINGS_FILE" || fail_test "locale catalogue missing key: $key"
    echo "PASS: locale key present: $key"
done

echo "ALL PASS: test_colima_start_retry.sh"
