#!/usr/bin/env bash
# ============================================================================
# test_a_failed_hydrate_may_not_fabricate_a_count.sh -- a hydrate step that
# FAILED may not write a count it never measured.                      (#852)
# ============================================================================
#
# THE DEFECT, measured on .228 / v1.0.38 and then read in source.
#
#     ~/.ostler/state/hydrate/browsing.done   status=error rc=124 payload=sent=0
#     ~/.ostler/state/hydrate/people.done     status=error rc=124 payload=sent=0
#
# and on the same box, in the stores those two steps write to:
#
#     safari_history   8,761 points   (the wiki Browsing page renders all of them)
#     people           7,154 points
#
# Two sentinels asserting nothing was delivered, over collections that are
# full. #848 is the same family pointing the other way -- four steps with no
# sentinel at all -- and the shared property is that THE SENTINEL DOES NOT
# DESCRIBE REALITY IN EITHER DIRECTION.
#
# ----------------------------------------------------------------------------
# WHERE THE ZERO COMES FROM, and it is not a race or a rounding
# ----------------------------------------------------------------------------
#
# install.sh, browsing block:
#
#     elif [[ -n "$_HYDRATE_BROWSING_JSON" ]]; then
#         _HYDRATE_BROWSING_SENT="$( ...parse the json... )"     <- ONLY here
#     ...
#     if [[ "${_HYDRATE_BROWSING_RC:-0}" -ne 0 ]]; then
#         _hydrate_sentinel_record_error "browsing" "$_HYDRATE_BROWSING_RC" \
#             "sent=${_HYDRATE_BROWSING_SENT:-0},..."
#
# The assignment lives inside the arm that PARSED A REPLY. gtimeout kills the
# python before it prints, so the kill path never enters that arm, so the
# variable is unset, so `${..._SENT:-0}` yields a shell DEFAULT. `sent=0` was
# not a measurement that came out low. It is the only value that branch could
# ever produce, and it was written into a file whose entire job is to record
# what happened.
#
# EVERY error recorder on origin/main did this. Measured by this file's own
# control (1) against the pristine tree: 7 of 9 call sites, across all six
# sources that had one -- whatsapp, browsing, email_preferences, imessage,
# apple_notes (two call sites) and people. The two that do not are `places`
# and `privacy_backfill`, which pass a literal `ran=1` and never had a counter
# to fabricate. Six of six is a property of the PATTERN, not six
# coincidences, which is why this gate asserts the pattern rather than the two
# sentinels the ticket happened to name.
#
# ----------------------------------------------------------------------------
# AND THE WORK IS NOT ROLLED BACK, so the zero can be false about its own run
# ----------------------------------------------------------------------------
#
# vendor/ostler_fda/pwg_ingest.py::_qdrant_upsert_points chunks the upsert and
# posts each chunk with params={"wait": "true"}, incrementing only on a chunk
# the server ACKED. A SIGTERM part-way through that loop leaves every acked
# chunk permanently in Qdrant. So "killed" and "delivered nothing" are
# genuinely different outcomes, and the sentinel printed them identically.
#
# ⚠️ WHAT THIS TEST DOES **NOT** CLAIM. It does not claim the 8,761 rows on
# .228 were put there by the timed-out install-time step. They may have come
# from the recurring background feed. TNM retracted exactly that inference on
# 2026-08-19 ("I read an install-time hydrate sentinel as a verdict on the
# SOURCE. It is not. It describes ONE 90-SECOND WINDOW during install"). The
# claim here is narrower and provable from source alone: the number in the
# file was never measured by anything.
#
# ----------------------------------------------------------------------------
# THREE STATES, NEVER TWO (the #810 interlock)
# ----------------------------------------------------------------------------
#
# #810 is the mirror: `status=ok` over a zero payload suppressed its own retry
# for seven days. A false SUCCESS and a false FAILURE are the same bug wearing
# different hats, and the cure for both is that "we did not measure" must have
# its own appearance. `unknown` is that appearance. Controls (4) and (5) below
# pin it against the REAL helpers, including the interaction with
# _hydrate_payload_is_all_zero, which must never see `unknown` as a zero.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL="${REPO_ROOT}/install.sh"

PASS=0
FAIL=0
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$INSTALL" ]] || cannot_run "install.sh not found at $INSTALL"

echo "test_a_failed_hydrate_may_not_fabricate_a_count.sh"
echo

# ---------------------------------------------------------------------------
# THE PREDICATE, in one place, used by both the real scan and the anti-vacuity
# control -- so the thing proved to work is the thing that does the work.
#
# Backslash continuations are folded first: every error recorder in install.sh
# puts its payload on the following line, so a line-at-a-time grep would look
# straight past the argument it is meant to be reading. That is not a
# hypothetical failure mode of this predicate, it is THE failure mode: an
# unfolded scan returns zero hits and reads as a clean bill of health.
# ---------------------------------------------------------------------------
fold_continuations() {
    # Join any line ending in a backslash with the one after it.
    awk '{
        line = $0
        while (sub(/\\[ \t]*$/, "", line)) {
            if ((getline nxt) <= 0) break
            sub(/^[ \t]+/, "", nxt)
            line = line " " nxt
        }
        print line
    }' "$1"
}

# Print one line per _hydrate_sentinel_record_error call site.
error_call_sites() {
    fold_continuations "$1" | grep '_hydrate_sentinel_record_error ' | grep -v '^[[:space:]]*#'
}

# Print the call sites that default a payload field to a fabricated 0.
fabricating_call_sites() {
    error_call_sites "$1" | grep ':-0}'
}

# ---------------------------------------------------------------------------
# (0) APPARATUS. A scan that finds no call sites would pass control (1)
#     vacuously. Establish the denominator BEFORE reading the finding.
#
#     The floor is 9, which is what the PRISTINE tree carries -- deliberately
#     not the post-fix count. This control's job is to prove the scan can see,
#     and it must therefore be true on both sides of the change. Counting the
#     sources is control (5) of the #848 test, which is a different question.
# ---------------------------------------------------------------------------
SITE_COUNT="$(error_call_sites "$INSTALL" | grep -c . || true)"
SITE_FLOOR=9
if [[ "${SITE_COUNT:-0}" -ge "$SITE_FLOOR" ]]; then
    pass "(0) denominator: the scan sees ${SITE_COUNT} error-recorder call sites (floor ${SITE_FLOOR})"
else
    failure "(0) DENOMINATOR TOO SMALL: found ${SITE_COUNT} error-recorder call sites, expected >= ${SITE_FLOOR}. Either the folding broke or the recorders were renamed -- control (1) below is measuring nothing."
fi

# ---------------------------------------------------------------------------
# (1) THE DEFECT. No failure sentinel may carry a defaulted-to-zero counter.
#     Offenders are printed BY NAME so the remaining work is in the output,
#     not merely absent from it.
# ---------------------------------------------------------------------------
OFFENDERS="$(fabricating_call_sites "$INSTALL" || true)"
OFFENDER_COUNT="$(printf '%s' "$OFFENDERS" | grep -c . || true)"
if [[ "${OFFENDER_COUNT:-0}" -eq 0 ]]; then
    pass "(1) no failure sentinel defaults a counter to 0 (0 of ${SITE_COUNT} call sites)"
else
    failure "(1) ${OFFENDER_COUNT} of ${SITE_COUNT} failure sentinels write a count nobody measured:"
    printf '%s\n' "$OFFENDERS" | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
# (2) ANTI-VACUITY. The predicate must FIRE on the exact string that shipped.
#     Without this, control (1) going green could mean the regex matches
#     nothing at all -- the shape that let a case-sensitive grep publish
#     family names, and the reason "zero findings" is never self-certifying.
# ---------------------------------------------------------------------------
FIXTURE="$(mktemp -t fabricatedcount-XXXXXX)"
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'SHIPPED'
    if [[ "${_HYDRATE_BROWSING_RC:-0}" -ne 0 ]]; then
        _hydrate_sentinel_record_error "browsing" "$_HYDRATE_BROWSING_RC" \
            "sent=${_HYDRATE_BROWSING_SENT:-0},skipped=${_HYDRATE_BROWSING_SKIPPED:-0}"
    else
        _hydrate_sentinel_record "browsing" "sent=${_HYDRATE_BROWSING_SENT:-0},skipped=${_HYDRATE_BROWSING_SKIPPED:-0}"
    fi
SHIPPED
PLANTED="$(fabricating_call_sites "$FIXTURE" | grep -c . || true)"
if [[ "${PLANTED:-0}" -ge 1 ]]; then
    pass "(2) ANTI-VACUITY: the predicate flags the verbatim v1.0.38 browsing call site"
else
    failure "(2) THE PREDICATE IS BLIND. Handed the exact two lines that shipped rc=124/sent=0, it found nothing. Control (1) proves nothing."
fi

# (2b) ...and it does not flag the SUCCESS recorder in the same fixture. On the
#      success path the parse HAS run, so `:-0` there is a real fallback for an
#      empty parse, not a fabrication. A predicate that cannot tell those apart
#      would demand a change that makes the file less accurate.
SUCCESS_FLAGGED="$(fold_continuations "$FIXTURE" | grep '_hydrate_sentinel_record ' | grep -c ':-0}' || true)"
if [[ "${SUCCESS_FLAGGED:-0}" -ge 1 ]]; then
    pass "(2b) CONTROL: the same fixture DOES contain a success recorder with :-0, and this scan is scoped to the error recorder only"
else
    failure "(2b) the fixture no longer contains the success-path :-0 line, so (2)'s scoping claim is untested"
fi

# ---------------------------------------------------------------------------
# Behavioural half. Extract the REAL helpers and drive them, so this cannot
# pass against a copy of the logic.
# ---------------------------------------------------------------------------
HARNESS="$(mktemp -d -t fabricatedcounth-XXXXXX)"
trap 'rm -f "$FIXTURE"; rm -rf "$HARNESS"' EXIT

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

{
    printf '_HYDRATE_SENTINEL_DIR="%s/state"\n' "$HARNESS"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    printf 'gui_step_record_rc() { :; }\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
    extract_fn _hydrate_payload_is_all_zero
} > "$HARNESS/helpers.sh"

for fn in _hydrate_sentinel_fresh _hydrate_sentinel_record \
          _hydrate_sentinel_record_error _hydrate_payload_is_all_zero; do
    grep -q "^${fn}() {" "$HARNESS/helpers.sh" \
        || cannot_run "could not extract $fn from install.sh; this test drives the REAL helpers and refuses to run against a copy"
done
bash -n "$HARNESS/helpers.sh" || cannot_run "extracted helpers do not parse"

in_harness() { bash -c "source '$HARNESS/helpers.sh'; $1"; }

# ---------------------------------------------------------------------------
# (3) An `unknown` counter still records the failure honestly: the status is
#     `timeout` for rc 124, the rc survives, and the payload says unknown.
# ---------------------------------------------------------------------------
OUT="$(in_harness '_hydrate_sentinel_record_error browsing 124 "sent=unknown,skipped=unknown,collection_points=8761"
                   cat "$_HYDRATE_SENTINEL_DIR/browsing.done"' 2>/dev/null)"
# Herestrings, not `printf | grep -q`. Under `pipefail` a short-circuiting
# consumer can invert the verdict of the whole pipeline, which is the defect
# tests/pipefail_shortcircuit_baseline.txt exists to keep out.
if grep -q '^status=timeout' <<< "$OUT" \
   && grep -q '^rc=124' <<< "$OUT" \
   && grep -q 'sent=unknown' <<< "$OUT"; then
    pass "(3) a killed step records status=timeout, rc=124 and sent=unknown -- the failure is kept, the invented number is not"
else
    failure "(3) the unknown-counter record lost its status, rc or payload: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# (4) It is still NOT fresh, so the source retries. The whole point of #711
#     survives the change -- an honest failure must not become a quiet one.
# ---------------------------------------------------------------------------
RC="$(in_harness '_hydrate_sentinel_record_error people 124 "sent=unknown"
                  _hydrate_sentinel_fresh people; echo $?' 2>/dev/null | tail -n 1)"
if [[ "$RC" == "1" ]]; then
    pass "(4) an unknown-counter failure is NOT fresh, so the next run retries"
else
    failure "(4) an unknown-counter failure read as fresh (rc=$RC) -- it would suppress its own retry for 7 days"
fi

# ---------------------------------------------------------------------------
# (5) THE #810 INTERLOCK. _hydrate_payload_is_all_zero must not read `unknown`
#     as a zero. If it did, an unmeasured run could be silently reclassified
#     as no_data on the success path -- swapping one false statement for
#     another. Both directions asserted, because a predicate that answers the
#     same way to everything is not a predicate.
# ---------------------------------------------------------------------------
RC="$(in_harness '_hydrate_payload_is_all_zero "sent=unknown,skipped=unknown"; echo $?' 2>/dev/null | tail -n 1)"
if [[ "$RC" == "1" ]]; then
    pass "(5) 'unknown' is not scored as a zero counter"
else
    failure "(5) _hydrate_payload_is_all_zero treated an unmeasured payload as all-zero (rc=$RC)"
fi

RC="$(in_harness '_hydrate_payload_is_all_zero "sent=0,skipped=0"; echo $?' 2>/dev/null | tail -n 1)"
if [[ "$RC" == "0" ]]; then
    pass "(5b) CONTROL: a genuinely all-zero payload IS still scored as all-zero, so (5) is not measuring a dead predicate"
else
    failure "(5b) the all-zero predicate no longer fires on sent=0,skipped=0 (rc=$RC) -- control (5) says nothing"
fi

# ---------------------------------------------------------------------------
# (6) `collection_points` must not be mistaken for `sent`. A post-kill store
#     count answers "did the work land", which is the question #852 asks, but
#     it counts the WHOLE collection including earlier runs and the background
#     feed. Reporting it as this run's output would put two populations in one
#     number -- the settling-panel numerator mistake, again.
# ---------------------------------------------------------------------------
if grep -q '_hydrate_qdrant_points' "$INSTALL"; then
    SENT_AS_POINTS="$(error_call_sites "$INSTALL" | grep -c 'sent=\$(_hydrate_qdrant_points' || true)"
    if [[ "${SENT_AS_POINTS:-0}" -eq 0 ]]; then
        pass "(6) the post-kill store count is reported under its own key, never as 'sent'"
    else
        failure "(6) a store-wide point count is being written as this run's 'sent' count -- two populations, one number"
    fi
else
    failure "(6) _hydrate_qdrant_points is absent, so a killed Qdrant-backed step still records nothing about whether the work landed"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
