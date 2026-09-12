#!/usr/bin/env bash
# A BROKEN PROBE MUST NEVER BE INVISIBLE TO THE SCOPED PROMOTE ADJUDICATION.
#
# WHAT THIS CAUGHT. scripts/verify_walk_record.sh's scoped promote adjudication
# built its non-pass list from an awk matching failed_probe and not_measured_probe
# rows only:
#
#     awk -F'\t' '$1=="failed_probe" || $1=="not_measured_probe" {print $2}' "$RECORD"
#
# broken_probe rows -- written by the BROKEN_NAMES loop in
# scripts/post_walk_qa.sh -- were never read.
#
# A probe goes BROKEN when it fails its own negative control -- it measured
# NOTHING, in either direction, and phase 2 of the box walk skips it. That is
# the most serious state the suite has, worse than a plain failure, because a
# broken probe cannot even be trusted to say what it is broken ABOUT.
#
# So a record could carry a broken probe ALONGSIDE a failed_probe that the
# operator's scope file (scripts/walk_promote_scope.tsv) declares advisory.
# _adjudicate_scoped's "blocking" set was built only from the named list it
# was handed -- the failed_probe/not_measured_probe rows -- so the broken
# probe never entered the function, blocking stayed empty, and the gate
# printed "walk-gate OK: every ARTEFACT-OWNED probe passed" and exited 0,
# about a probe nobody had looked at.
#
# WHAT IS ASSERTED HERE, four arms:
#   A  THE DEFECT: fail=1 (advisory-scoped) + broken=1 must still REFUSE,
#      never reach "every ARTEFACT-OWNED probe passed" / exit 0.
#   B  CONTROL: the identical record WITHOUT the broken probe still passes --
#      proves arm A's refusal is caused by the broken probe, not by anything
#      else in the fixture.
#   C  a record whose `broken` count exceeds its named broken_probe rows
#      refuses as CANNOT-RUN: an unnamed broken probe cannot be checked.
#   D  a broken-only record (no failed/not-measured probes at all) already
#      refuses via the existing "record names no probes" fallback -- this
#      pins that the fix does not have to touch that path to stay safe.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${REPO}/scripts/verify_walk_record.sh"
SCOPE="${REPO}/scripts/walk_promote_scope.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$GATE" ]  || { echo "CANNOT-RUN: no gate at ${GATE}" >&2; exit 2; }
[ -f "$SCOPE" ] || { echo "CANNOT-RUN: no scope file at ${SCOPE}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Same synthetic-sha discipline as test_promote_scope_refuses_on_the_artefact.sh:
# hex-with-letters so no run of 15+ digits trips ci-pii-shape-scan's shape test.
SHA="$(printf '0123456789abcdef%.0s' 1 2 3 4)"

# Build a record. $1 dir, $2 failed-csv (may be empty), $3 broken-csv (may be
# empty), $4 broken COUNT to write in the `broken` field (defaults to the
# number of names in $3; pass a different number to test the completeness
# check in arm C).
_rec() {
    local d="$1" failed="$2" broken="$3" broken_count="${4:-}" nf=0 nb_named=0 p
    for p in ${failed//,/ };  do nf=$((nf+1)); done
    for p in ${broken//,/ }; do nb_named=$((nb_named+1)); done
    [ -n "$broken_count" ] || broken_count="$nb_named"
    mkdir -p "${d}/walks"
    {
        printf 'version\tv9.9.9\n'
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'artefact_sha256\t%s\n' "$SHA"
        printf 'artefact_sha256_source\tmeasured(shasum -a 256 on the walked box)\n'
        printf 'walked_at\t2026-09-05T00:00:00Z\n'
        printf 'pass\t%d\n' $((24-nf-nb_named))
        printf 'fail\t%d\n' "$nf"
        printf 'cannot_run\t0\n'
        printf 'broken\t%d\n' "$broken_count"
        printf 'verdict\tFAILED\n'
        printf 'qa_exit\t1\n'
        printf 'failed_probe_names_recorded\t%d of %d\n' "$nf" "$nf"
        for p in ${failed//,/ };  do printf 'failed_probe\t%s\n' "$p"; done
        for p in ${broken//,/ }; do printf 'broken_probe\t%s\n' "$p"; done
    } > "${d}/walks/v9.9.9.tsv"
}

# Run the gate against a record dir. Echoes "<rc>|<output>".
_run() {
    local d="$1"
    local out rc
    out="$(OSTLER_WALK_RECORD_DIR="${d}/walks" OSTLER_PROMOTE_SCOPE="$SCOPE" bash "$GATE" v9.9.9 "$SHA" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "── A. THE DEFECT: an advisory-scoped failure PLUS a broken probe must still refuse ──"
# usage_journal_producers is declared advisory in walk_promote_scope.tsv, so on
# its own (arm B below) it lets the promote through. a_fixture_probe_never_seen
# is not in the scope file at all -- and must not need to be, because a broken
# probe bypasses the scope file entirely: it is never a candidate for advisory.
D="${WORK}/a"; _rec "$D" "usage_journal_producers" "a_fixture_probe_never_seen"
R="$(_run "$D")"
case "$R" in
    2\|*BROKEN*a_fixture_probe_never_seen*)
        # rc=2, not 1: a broken probe measured nothing, the same category as a
        # not-measured one, so it takes the CANNOT-RUN exit code the function
        # already uses when blk_failed is empty -- consistent with the existing
        # "coverage lost is not coverage passed" rule for not_measured_probe.
        ok "the broken probe is NAMED and the promote refuses (rc=2, CANNOT-RUN)" ;;
    0\|*"every ARTEFACT-OWNED probe passed"*)
        bad "PASSED with the broken probe unmentioned -- this is the exact hole: an advisory-scoped failure hid a broken probe from the adjudication" ;;
    0\|*)
        bad "the gate exited 0 with a broken probe on the record; output: $(printf '%s' "${R#*|}" | head -3 | tr '\n' ' ')" ;;
    *)
        bad "unexpected rc=${R%%|*}: $(printf '%s' "${R#*|}" | head -3 | tr '\n' ' ')" ;;
esac

echo
echo "── B. CONTROL: the identical record WITHOUT the broken probe still passes ──"
# Proves arm A's refusal is caused by the broken probe and not by something
# else in the fixture (a malformed row, a missing field, and so on).
D="${WORK}/b"; _rec "$D" "usage_journal_producers" ""
R="$(_run "$D")"
case "$R" in
    0\|*"every ARTEFACT-OWNED probe passed"*)
        ok "CONTROL: with no broken probe, the identical advisory-only record still passes" ;;
    *)
        bad "CONTROL FAILED: the fixture itself does not pass without a broken probe -- rc=${R%%|*}, so arm A proves nothing. output: $(printf '%s' "${R#*|}" | head -3 | tr '\n' ' ')" ;;
esac

echo
echo "── C. an unnamed broken probe (count exceeds named rows) is CANNOT-RUN ──"
D="${WORK}/c"; _rec "$D" "usage_journal_producers" "a_fixture_probe_never_seen" 2
R="$(_run "$D")"
case "$R" in
    2\|*broken=2*)
        ok "broken=2 with only 1 named row refuses as CANNOT-RUN, naming the count" ;;
    0\|*)
        bad "an incomplete broken-probe list PASSED -- an unnamed broken probe went unchecked" ;;
    *)
        bad "unexpected rc=${R%%|*}: $(printf '%s' "${R#*|}" | head -3 | tr '\n' ' ')" ;;
esac

echo
echo "── D. a broken-ONLY record (no failed/not-measured probes) already refuses ──"
# This path never reaches _adjudicate_scoped at all -- the caller's _NONPASS
# list is empty and VERDICT=FAILED forces the pre-existing unscoped refusal.
# Pinned here so the fix above is never mistaken for the ONLY thing standing
# between a broken-only record and a false green.
D="${WORK}/d"; _rec "$D" "" "a_fixture_probe_never_seen"
R="$(_run "$D")"
case "$R" in
    1\|*)
        ok "a broken-only record refuses (rc=1) via the existing unscoped fallback" ;;
    0\|*)
        bad "a broken-only record PASSED the gate" ;;
    *)
        bad "unexpected rc=${R%%|*}: $(printf '%s' "${R#*|}" | head -3 | tr '\n' ' ')" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
