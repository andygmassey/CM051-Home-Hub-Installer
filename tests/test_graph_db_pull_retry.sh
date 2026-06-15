#!/usr/bin/env bash
#
# tests/test_graph_db_pull_retry.sh
#
# Cold-VM graph-DB bring-up regression test (TNM 2026-06-15,
# ERR-99-INSTALL-ABORT-L7105 on a fresh-wipe Studio install).
#
# The bug: at the graph_db_start phase the FIRST docker operation was a
# bare `docker compose up -d qdrant oxigraph redis`. On a genuinely
# fresh install the Colima VM has only just cold-booted; the earlier
# "Docker running" gate proves the socket answers but NOT that the
# guest VM network is routable yet. `up -d` pulls the three images from
# the registry on first run, so the bare call coupled the flaky network
# PULL to the bring-up with NO retry. A single cold-VM network blip
# failed under `set -e` -> ERR trap -> the whole install aborted ~90%
# in. The Qdrant readiness loop further down runs AFTER `up`, so it
# never protected the pull.
#
# The fix: at this phase install.sh must, in order,
#   (1) re-confirm the daemon is reachable here-and-now (`docker info`),
#   (2) `docker compose pull qdrant oxigraph redis` inside a bounded
#       retry/backoff loop (so a transient cold-VM pull failure retries
#       instead of aborting), THEN
#   (3) `docker compose up -d qdrant oxigraph redis` (images cached) in
#       a short retry loop,
# and any genuine, repeated failure must be a `fail_with_code`
# ERR-06-GRAPH-DB-* (curated code + actionable recovery), never the bare
# call that produced the synthetic ERR-99.
#
# Per [[feedback-silent-bail-regression-test-shape]], this walks the
# graph_db_start region and refuses the EXACT failure shape: a
# `docker compose up -d qdrant oxigraph redis` with no preceding
# `docker compose pull` of the same services inside a retry loop. A
# future agent reverting to the bare call trips this test in CI in
# seconds instead of at minute-7 of a real cut on a fresh box.

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail_test "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || fail_test "strings file not found at $STRINGS_FILE"

bash -n "$INSTALL_SH" || fail_test "install.sh fails bash -n parse check"
echo "PASS: install.sh parses"

# Narrow to the graph_db_start bring-up region: from the
# "Bring up the data services only at this phase" comment down to the
# success ok-line. This is the block that used to be the bare call.
REGION="$(awk '/Bring up the data services only at this phase/{c=1}
               c{print}
               /MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878/{if(c){print; exit}}' "$INSTALL_SH")"
[[ -n "$REGION" ]] || fail_test "could not locate the graph_db_start bring-up region"

# (1) Daemon re-confirmed reachable at this phase.
grep -q 'docker info' <<<"$REGION" || fail_test "no in-phase 'docker info' daemon readiness re-check"
echo "PASS: in-phase docker-info readiness re-check present"

# (2) The images are PULLED separately, inside a bounded retry loop,
#     BEFORE the bring-up. This is the load-bearing cold-VM fix.
grep -Eq 'docker compose pull[[:space:]]+qdrant[[:space:]]+oxigraph[[:space:]]+redis' <<<"$REGION" \
    || fail_test "no separate 'docker compose pull qdrant oxigraph redis' before up (the cold-VM pull race)"
echo "PASS: explicit docker compose pull of the 3 services present"

# The pull must be retried with backoff, not single-shot.
grep -Eq 'for[[:space:]]+_gdb_attempt[[:space:]]+in' <<<"$REGION" \
    || fail_test "no per-attempt retry loop around the pull"
grep -q '_gdb_backoff' <<<"$REGION" || fail_test "no inter-attempt backoff around the pull"
echo "PASS: bounded pull retry loop with backoff present"

# Ordering: the pull must appear BEFORE the `up -d` of the same services.
PULL_LINE="$(grep -nE 'docker compose pull[[:space:]]+qdrant[[:space:]]+oxigraph[[:space:]]+redis' <<<"$REGION" | head -1 | cut -d: -f1)"
UP_LINE="$(grep -nE 'docker compose up -d qdrant oxigraph redis' <<<"$REGION" | head -1 | cut -d: -f1)"
[[ -n "$PULL_LINE" && -n "$UP_LINE" ]] || fail_test "could not locate both pull and up lines in the region"
(( PULL_LINE < UP_LINE )) || fail_test "pull must precede 'up -d' (pull at $PULL_LINE, up at $UP_LINE)"
echo "PASS: pull precedes bring-up"

# (3) The bring-up itself is retried (images cached -> fast).
grep -Eq 'for[[:space:]]+_gdb_up_attempt[[:space:]]+in' <<<"$REGION" \
    || fail_test "no retry loop around 'docker compose up -d'"
echo "PASS: bring-up retry loop present"

# Failures route through curated ERR-06-GRAPH-DB-* codes, never a bare
# abort that surfaces as the synthetic ERR-99.
for code in ERR-06-GRAPH-DB-DOCKER ERR-06-GRAPH-DB-PULL ERR-06-GRAPH-DB-UP; do
    grep -q "fail_with_code \"${code}\"" <<<"$REGION" \
        || fail_test "missing fail_with_code for ${code} (a genuine failure must be curated, not ERR-99)"
    echo "PASS: fail_with_code present for ${code}"
done

# Strings exist in the catalogue.
for key in MSG_INFO_PULLING_GRAPH_DB_IMAGES MSG_WARN_GRAPH_DB_PULL_RETRY \
           MSG_WARN_GRAPH_DB_UP_RETRY MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY \
           MSG_FAIL_GRAPH_DB_PULL_FAILED MSG_FAIL_GRAPH_DB_UP_FAILED; do
    grep -q "^${key}=" "$STRINGS_FILE" || fail_test "locale catalogue missing key: $key"
    echo "PASS: locale key present: $key"
done

echo "ALL PASS: test_graph_db_pull_retry.sh"
