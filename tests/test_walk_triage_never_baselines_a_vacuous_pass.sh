#!/usr/bin/env bash
# test_walk_triage_never_baselines_a_vacuous_pass.sh
# ============================================================================
# A walk record stores no per-probe denominator, so "absent from failed_probe"
# reads as PASSED. For no_person_holds_two_contact_cards on v1.0.111 and
# v1.0.112 that pass examined 1 icloud_contact_uid and 0 merge chances, and
# scripts/walk_regression_triage.sh named it as regression_of, which sent a
# bisect to the wrong window.
#
# The triage now reads scripts/walk_vacuous_baselines.tsv (probe, version,
# why) and treats a listed pass as a non-baseline, and a CANNOT-RUN
# (not_measured_probe) is a non-baseline too.
#
# Synthetic records only, in a temp dir. The vacuous list is injected via
# WALK_TRIAGE_VACUOUS so the real list is never touched.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE="${HERE}/../scripts/walk_regression_triage.sh"
T="$(mktemp -d 2>/dev/null || mktemp -d -t wtv)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/walks"
FAILURES=0
bad() { FAILURES=$((FAILURES+1)); printf '  FAIL [%s]: %s\n' "$1" "$2"; }
ok()  { printf '  ok   [%s]\n' "$1"; }

rec() { # version day verdict [extra rows...]
    local v="$1" d="$2" vd="$3"; shift 3
    { printf 'walked_at\t2026-02-%sT00:00:00Z\nverdict\t%s\n' "$d" "$vd"; for r in "$@"; do printf '%s\n' "$r"; done; } > "$T/walks/$v.tsv"
}
TAB="$(printf '\t')"
P="subject_probe"
# v1.0.1 genuine pass (another probe is the red one), v1.0.2 and v1.0.3 are
# the vacuous passes, v1.0.4 is the red.
rec v1.0.1 01 FAILED "failed_probe${TAB}other_probe"
rec v1.0.2 02 FAILED "failed_probe${TAB}other_probe"
rec v1.0.3 03 FAILED "failed_probe${TAB}other_probe"
rec v1.0.4 04 FAILED "failed_probe${TAB}${P}"
printf '%s\tv1.0.2\t1 uid, 0 merge chances\n%s\tv1.0.3\t1 uid, 0 merge chances\n' "$P" "$P" > "$T/vac.tsv"
: > "$T/none.tsv"
run() { WALK_TRIAGE_REPO="$T" WALK_TRIAGE_WALKS="$T/walks" WALK_TRIAGE_VACUOUS="$1" bash "$TRIAGE" --emit-rows v1.0.4 2>&1; }

OUT="$(run "$T/vac.tsv")"
case "$OUT" in *"regression_of${TAB}${P}${TAB}v1.0.1"*) ok vacuous-skipped-baseline-is-v1.0.1 ;; *) bad vacuous "expected baseline v1.0.1, got: $OUT" ;; esac

# NEGATIVE: with nothing listed, the same records DO baseline at v1.0.3, so the
# skip is caused by the list and not by a broken predicate.
OUT="$(run "$T/none.tsv")"
case "$OUT" in *"regression_of${TAB}${P}${TAB}v1.0.3"*) ok unlisted-pass-is-still-a-baseline ;; *) bad negative "expected baseline v1.0.3 with empty list, got: $OUT" ;; esac

# A CANNOT-RUN (not_measured_probe) is never a baseline.
rec v1.0.3 03 FAILED "failed_probe${TAB}other_probe" "not_measured_probe${TAB}${P}"
OUT="$(run "$T/none.tsv")"
case "$OUT" in *"regression_of${TAB}${P}${TAB}v1.0.2"*) ok cannot-run-is-not-a-baseline ;; *) bad cannot-run "expected baseline v1.0.2 (skipping CANNOT-RUN v1.0.3), got: $OUT" ;; esac

# Every earlier pass vacuous -> NEVER-PASSED, never a invented window.
printf '%s\tv1.0.1\tx\n%s\tv1.0.2\tx\n%s\tv1.0.3\tx\n' "$P" "$P" "$P" > "$T/all.tsv"
OUT="$(run "$T/all.tsv")"
case "$OUT" in *"regression_of${TAB}${P}${TAB}NEVER-PASSED"*) ok all-vacuous-is-never-passed ;; *) bad all-vacuous "expected NEVER-PASSED, got: $OUT" ;; esac

if [ "$FAILURES" -eq 0 ]; then printf 'PASS: 0 failures\n'; exit 0; fi
printf 'FAIL: %d failure(s)\n' "$FAILURES"; exit 1
