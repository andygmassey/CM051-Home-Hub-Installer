#!/usr/bin/env bash
# tests/test_a_test_cannot_reach_the_real_walk_store.sh
# ============================================================================
# The walk store (~/.ostler/walks, or $OSTLER_WALK_STORE) is where the early
# pass and the run_box_walk.sh promotion read "the previous walk". A test that
# wrote a fake v9.9.9 record into the REAL store made a real walk's early pass
# read it and fail to run. This test proves no walk-record test can do that.
#
# HOW: a SENTINEL home stands in for the real one. It holds a populated
# .ostler/walks. Each target test runs with HOME pointing at it and with
# OSTLER_WALK_STORE / OSTLER_UNDER_TEST UNSET (the worst case: a test that does
# no isolation of its own). Afterwards every file under the sentinel .ostler
# tree must be byte-identical and no file may have appeared. The real ~/.ostler
# is never read or written; HOME is never the real one when a target runs.
#
# CONTROLS (each proves the detector can fire, a different way):
#   1. a stub that writes into $HOME/.ostler/walks must be CAUGHT;
#   2. record_walk.sh given a fixture version (v9.9.9) with the store defaulted
#      to $HOME must leave the sentinel untouched (this is the arm that is red
#      on the old code: there the copy lands in the sentinel store).
#
# Red on the old code: copy this file into a checkout of origin/main and run it
# there (REPO_UNDER_TEST defaults to the checkout holding the file).
#
# EXIT 0 pass, 1 a leak or failed control, 2 CANNOT-RUN. BASH 3.2.
# ============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_UNDER_TEST:-$(cd "$HERE/.." && pwd)}"
[ -f "${REPO}/scripts/record_walk.sh" ] || { echo "CANNOT-RUN: no scripts/record_walk.sh under ${REPO}"; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no scratch dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

SENT="${WORK}/sentinel-home"
_reset_sentinel() {
    rm -rf "$SENT"; mkdir -p "$SENT/.ostler/walks"
    printf 'walked_at\t2026-10-01T00:00:00Z\nverdict\tCLEAN\n' > "$SENT/.ostler/walks/v1.0.100-20261001T000000Z.tsv"
    : > "$SENT/.ostler/walks/v1.0.100-20261001T000000Z.log"
}
_snap() { ( cd "$SENT/.ostler" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done ); }
_guard() {   # label; compares snapshot to $BEFORE
    local after; after="$(_snap)"
    if [ "$after" = "$BEFORE" ]; then ok "$1: sentinel store untouched"; return 0; fi
    bad "$1: sentinel store CHANGED: $(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$after") | grep '^[<>]' | tr '\n' ' ')"
    return 1
}

printf -- '--- control 1: the detector fires on a deliberate write ---\n'
_reset_sentinel; BEFORE="$(_snap)"
HOME="$SENT" bash -c 'mkdir -p "$HOME/.ostler/walks"; echo x > "$HOME/.ostler/walks/v9.9.9-20260101T000000Z.tsv"'
if [ "$(_snap)" != "$BEFORE" ]; then ok "control: a write into \$HOME/.ostler/walks changes the snapshot"; else bad "control: the snapshot cannot see a write, so every PASS below is meaningless"; fi

printf -- '--- control 2: record_walk.sh with a fixture version and the store defaulted to HOME ---\n'
_reset_sentinel; BEFORE="$(_snap)"
R="${WORK}/rw"; mkdir -p "$R/rec"
cat > "$R/qa.sh" <<QAEOF
#!/bin/sh
sleep 1
printf 'version\t%s\nwalked_at\t2026-10-10T08:00:00Z\nverdict\tFAILED\n' "\$2" > "$R/rec/\$2.tsv"
exit 1
QAEOF
chmod +x "$R/qa.sh"
( cd "$R" && env -u OSTLER_WALK_STORE -u OSTLER_UNDER_TEST HOME="$SENT" OSTLER_POST_WALK_QA="$R/qa.sh" OSTLER_WALK_RECORD_DIR="$R/rec" \
    bash "${REPO}/scripts/record_walk.sh" --host fake.invalid --version v9.9.9 --walk-verdict 1 ) > "$R/out.txt" 2>&1
[ -f "$R/rec/v9.9.9.tsv" ] && ok "control: the stub writer ran and the repo-side record exists (the copy step was reached)" || bad "control: the recorder never reached the copy step: $(tail -n 3 "$R/out.txt" | tr '\n' ' ')"
_guard "record_walk.sh --version v9.9.9, store defaulted to HOME"

printf -- '--- the walk-record tests, run with HOME = the sentinel and no isolation env ---\n'
TARGETS="
scripts/tests/test_the_early_pass_rechecks_last_walks_failures.sh
tests/test_a_completed_walk_records_itself.sh
tests/test_a_pairing_reader_runs_before_the_pairing_mutator.sh
tests/test_a_writing_probe_declares_it_and_is_never_promoted.sh
tests/test_a_broken_probe_blocks_the_promote.sh
tests/test_post_walk_qa_measures_the_artefact.sh
tests/test_walk_record_gates_customer_download.sh
tests/test_the_walk_record_says_whether_the_stores_are_history.sh
tests/test_walk_record_names_the_failing_probes.sh
tests/test_a_walk_record_names_the_instrument_that_graded_it.sh
"
N=0
for t in $TARGETS; do
    if [ ! -f "${REPO}/${t}" ]; then bad "${t} is absent under ${REPO}, so it cannot be checked"; continue; fi
    N=$((N + 1))
    _reset_sentinel; BEFORE="$(_snap)"
    ( cd "$REPO" && env -u OSTLER_WALK_STORE -u OSTLER_UNDER_TEST -u OSTLER_WALK_RECORD_DIR HOME="$SENT" \
        perl -e 'alarm 600; exec @ARGV' bash "$t" ) > "${WORK}/t.out" 2>&1
    rc=$?
    _guard "${t##*/} (exit ${rc})"
done
[ "$N" -ge 8 ] && ok "denominator: ${N} walk-record tests examined" || bad "denominator: only ${N} tests examined"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
