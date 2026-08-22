#!/usr/bin/env bash
# ============================================================================
# test_cannot_run_is_a_third_state.sh -- every hydrate step must leave a
# record, and CANNOT-RUN, FAIL and PASS must not print the same.       (#848)
# ============================================================================
#
# THE DEFECT, measured on origin/main.
#
# Thirteen steps run under the hydrate phase. NINE write a `.done` sentinel
# and are therefore inside the freshness/retry machinery. FOUR do not:
#
#     contacts    2,410 cards on a real box
#     calendar
#     email       7,276 messages on a real box
#     dedupe      the only sweep that folds cross-source people together
#
# For those four, the state on disk is an ABSENT FILE, and an absent file is
# indistinguishable from:
#
#     - install.sh never reached this step
#     - this step is not in this version of the installer
#     - the step ran perfectly
#     - the step's interpreter was missing so nothing was attempted
#
# Four outcomes, one appearance, and the last of those four is not
# hypothetical: #851 was a missing python module killing the recurring ingest
# for six sources, and #595 was the promote step deleting the venv that five
# hydrate blocks run under. Both produce exactly this shape.
#
# ----------------------------------------------------------------------------
# WHY A FOURTH RECORDER AND NOT A FLAG ON AN EXISTING ONE
# ----------------------------------------------------------------------------
#
# install.sh already distinguishes:
#
#     status=ok        PASS      the step ran and delivered
#     status=no_data   ran, and THE INPUT WAS NOT THERE (healthy, transient)
#     status=error     FAIL      an attempt was made and it failed, with an rc
#     status=timeout   FAIL      same, killed by its wall-clock cap
#
# CANNOT-RUN is none of those. It has no rc, because nothing ran; inventing
# one would be the same fabrication #852 removes from the counters. And it is
# not no_data, because no_data means "we looked" -- a missing interpreter
# means the thing that does the looking is absent, which is an install defect
# and not a fact about the customer's data.
#
# ⚠️ #810 IS THE REASON THIS MATTERS RATHER THAN BEING TIDY. There, a
# `status=ok` over a zero payload suppressed its own retry for seven days. The
# lesson was not "check for zero"; it was that any two distinct outcomes
# sharing one appearance will eventually be acted on as the wrong one. Three
# states, three appearances, or the next collapse is already written.
#
# ----------------------------------------------------------------------------
# WHAT THIS TEST DELIBERATELY DOES NOT ASSERT
# ----------------------------------------------------------------------------
#
# It does NOT require the four new sources to gate on _hydrate_sentinel_fresh.
# Writing the record and suppressing the retry for seven days are separable,
# and only the first is unambiguously an improvement. Contacts, calendar and
# email are precisely the steps whose RE-RUN rescues a customer who granted
# Full Disk Access late or whose iCloud sync landed after install -- the
# transient this repo's own #711 notes describe. A gate that demanded the skip
# would be demanding a regression.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL="${REPO_ROOT}/install.sh"
DOCTOR_AGENT="${REPO_ROOT}/vendor/doctor/agent"

PASS=0
FAIL=0
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$INSTALL" ]] || cannot_run "install.sh not found at $INSTALL"

echo "test_cannot_run_is_a_third_state.sh"
echo

# ---------------------------------------------------------------------------
# Behavioural half: extract the REAL recorders and run them.
# ---------------------------------------------------------------------------
HARNESS="$(mktemp -d -t thirdstate-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

RECORDERS="_hydrate_sentinel_record _hydrate_sentinel_record_error \
_hydrate_sentinel_record_no_data _hydrate_sentinel_record_cannot_run"

{
    printf '_HYDRATE_SENTINEL_DIR="%s/state"\n' "$HARNESS"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    printf 'gui_step_record_rc() { :; }\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_payload_is_all_zero
    for fn in $RECORDERS; do extract_fn "$fn"; done
} > "$HARNESS/helpers.sh"

# A MISSING CANNOT-RUN RECORDER IS THE FINDING, NOT AN APPARATUS FAULT -- so
# it goes RED and the run CONTINUES. Bailing out here would hide the
# population control below, which is the other half of #848 and reports its
# own, separate finding. A test that stops at the first defect measures one
# thing and leaves the rest looking clean.
MISSING=""
for fn in _hydrate_sentinel_fresh _hydrate_payload_is_all_zero \
          _hydrate_sentinel_record _hydrate_sentinel_record_error \
          _hydrate_sentinel_record_no_data; do
    grep -q "^${fn}() {" "$HARNESS/helpers.sh" || MISSING="${MISSING} ${fn}"
done
[[ -z "$MISSING" ]] \
    || cannot_run "could not extract:${MISSING}. This test drives the REAL helpers and refuses to run against a copy."
bash -n "$HARNESS/helpers.sh" || cannot_run "extracted helpers do not parse"

HAVE_CANNOT_RUN=1
if grep -q '^_hydrate_sentinel_record_cannot_run() {' "$HARNESS/helpers.sh"; then
    pass "(1) install.sh defines a CANNOT-RUN recorder alongside the other three"
else
    HAVE_CANNOT_RUN=0
    failure "(1) THERE IS NO CANNOT-RUN RECORDER. install.sh has no _hydrate_sentinel_record_cannot_run, so a step whose interpreter is missing leaves an absent file -- byte-identical to a step that was never reached, and to one that ran perfectly."
fi

in_harness() { bash -c "source '$HARNESS/helpers.sh'; $1"; }

status_of() {
    in_harness "$1; grep '^status=' \"\$_HYDRATE_SENTINEL_DIR/$2.done\"" 2>/dev/null \
        | head -n 1 | cut -d= -f2
}

if [[ "$HAVE_CANNOT_RUN" -eq 0 ]]; then
    failure "(2-4) NOT CHECKED, which is not a pass: the four-state and reader controls all drive the recorder that control (1) just reported missing."
fi

# ---------------------------------------------------------------------------
# (2) FOUR RECORDERS, FOUR DISTINCT STATUS STRINGS. Asserted as a SET SIZE,
#     not as four separate equality checks: the property that matters is that
#     no two collapse onto each other, and a set is the only thing that says
#     that in one predicate.
# ---------------------------------------------------------------------------
if [[ "$HAVE_CANNOT_RUN" -eq 1 ]]; then
S_OK="$(status_of '_hydrate_sentinel_record s1 "imported=41"' s1)"
S_ND="$(status_of '_hydrate_sentinel_record_no_data s2 "no_calendar_accounts"' s2)"
S_CR="$(status_of '_hydrate_sentinel_record_cannot_run s3 "pipeline_venv_missing"' s3)"
S_ER="$(status_of '_hydrate_sentinel_record_error s4 1 "imported=0"' s4)"
S_TO="$(status_of '_hydrate_sentinel_record_error s5 124 "sent=unknown"' s5)"

DISTINCT="$(printf '%s\n%s\n%s\n%s\n' "$S_OK" "$S_ND" "$S_CR" "$S_ER" | sort -u | grep -c . || true)"
if [[ "${DISTINCT:-0}" -eq 4 ]]; then
    pass "(2) PASS / no-input / CANNOT-RUN / FAIL are four distinct statuses (${S_OK} / ${S_ND} / ${S_CR} / ${S_ER})"
else
    failure "(2) STATES COLLAPSED: ok=${S_OK:-<none>} no_data=${S_ND:-<none>} cannot_run=${S_CR:-<none>} error=${S_ER:-<none>} -> only ${DISTINCT} distinct values"
fi

if [[ "$S_CR" == "cannot_run" ]]; then
    pass "(2b) the CANNOT-RUN status string is 'cannot_run'"
else
    failure "(2b) expected status=cannot_run, got '${S_CR:-<none>}'"
fi

if [[ "$S_TO" == "timeout" && "$S_ER" == "error" ]]; then
    pass "(2c) a killed run (rc=124) stays distinguishable from a crash (rc=1): timeout vs error"
else
    failure "(2c) rc=124 gave '${S_TO:-<none>}' and rc=1 gave '${S_ER:-<none>}' -- the two failure shapes have collapsed"
fi

# (2d) A cannot_run record carries NO rc. Inventing one would be the same
#      fabrication #852 removes from the counters: nothing ran, so there is no
#      exit code to report.
if in_harness '_hydrate_sentinel_record_cannot_run s6 "fda_not_granted"
               cat "$_HYDRATE_SENTINEL_DIR/s6.done"' 2>/dev/null | grep -q '^rc='; then
    failure "(2d) the cannot_run record invented an rc for a run that never happened"
else
    pass "(2d) the cannot_run record carries no rc, because nothing ran to produce one"
fi

# (2e) ...and it carries the REASON, or it is a state with no content.
if in_harness '_hydrate_sentinel_record_cannot_run s7 "email_ingest_venv_missing"
               cat "$_HYDRATE_SENTINEL_DIR/s7.done"' 2>/dev/null \
   | grep -q '^detail=email_ingest_venv_missing'; then
    pass "(2e) the cannot_run record names WHY it could not run"
else
    failure "(2e) the cannot_run record lost its detail= reason"
fi

# ---------------------------------------------------------------------------
# (3) ONLY 'ok' IS FRESH. cannot_run must not suppress the retry -- the whole
#     point is that the next run looks again once the missing venv is back.
# ---------------------------------------------------------------------------
fresh_rc() { in_harness "$1; _hydrate_sentinel_fresh $2; echo \$?" 2>/dev/null | tail -n 1; }
F_OK="$(fresh_rc '_hydrate_sentinel_record f1 "imported=41"' f1)"
F_CR="$(fresh_rc '_hydrate_sentinel_record_cannot_run f2 "pipeline_venv_missing"' f2)"
F_ND="$(fresh_rc '_hydrate_sentinel_record_no_data f3 "no_calendar_accounts"' f3)"
F_ER="$(fresh_rc '_hydrate_sentinel_record_error f4 1 "imported=0"' f4)"
if [[ "$F_OK" == "0" && "$F_CR" == "1" && "$F_ND" == "1" && "$F_ER" == "1" ]]; then
    pass "(3) only a PASS is fresh; cannot_run, no_data and error all retry"
else
    failure "(3) freshness is wrong: ok=$F_OK cannot_run=$F_CR no_data=$F_ND error=$F_ER (want 0/1/1/1)"
fi

# ---------------------------------------------------------------------------
# (4) THE READER. install.sh is the writer; nothing is proved by a writer
#     alone. The vendored Doctor rule must treat cannot_run as a problem and
#     NOT absorb it into the healthy path -- that is the fail-safe direction
#     its own docstring promises, and a promise in a docstring is not a test.
#
#     Skipped-with-a-failure, not skipped-silently, if the tree is absent:
#     "the reader was not checked" and "the reader is fine" must not print
#     the same either.
# ---------------------------------------------------------------------------
if [[ -f "${DOCTOR_AGENT}/diagnostic_rules.py" ]] && command -v python3 >/dev/null 2>&1; then
    READER_OUT="$(cd "$DOCTOR_AGENT" && python3 -c '
import sys
sys.path.insert(0, ".")
from diagnostic_rules import check_hydrate_ingest, HYDRATE_STATUSES_HEALTHY
from status_collector import HydrateMarkerInfo

class Snap:
    hydrate_markers = [
        HydrateMarkerInfo(source="contacts", status="cannot_run", rc=None,
                          payload="", detail="pipeline_venv_missing"),
        HydrateMarkerInfo(source="people", status="ok", rc=0, payload="sent=7154"),
        HydrateMarkerInfo(source="browsing", status="timeout", rc=124,
                          payload="sent=unknown,collection_points=8761"),
    ]

findings = check_hydrate_ingest(Snap())
by_source = {f["title"].split()[0]: f["severity"] for f in findings}
print("cannot_run_absorbed_as_healthy=%s" % ("cannot_run" in HYDRATE_STATUSES_HEALTHY))
print("contacts=%s" % by_source.get("contacts", "NO_FINDING"))
print("people=%s" % by_source.get("people", "NO_FINDING"))
print("browsing=%s" % by_source.get("browsing", "NO_FINDING"))
' 2>&1)"
    if printf '%s' "$READER_OUT" | grep -q '^contacts=warning' \
       && printf '%s' "$READER_OUT" | grep -q '^cannot_run_absorbed_as_healthy=False'; then
        pass "(4) the shipped Doctor rule surfaces cannot_run as a warning rather than absorbing it into the healthy path"
    else
        failure "(4) the Doctor reader mishandles cannot_run: $(printf '%s' "$READER_OUT" | tr '\n' ' ')"
    fi

    # (4b) CONTROL, on the other side. A healthy PASS must produce NO finding,
    #      and a payload of `sent=unknown` must not be scored as "brought
    #      nothing in". Without this, (4) could be passing because the rule
    #      warns about everything.
    if printf '%s' "$READER_OUT" | grep -q '^people=NO_FINDING' \
       && printf '%s' "$READER_OUT" | grep -q '^browsing=warning'; then
        pass "(4b) CONTROL: a healthy source produces no finding, and 'sent=unknown' is not read as an empty import"
    else
        failure "(4b) the reader's other arms are wrong, so (4) says nothing: $(printf '%s' "$READER_OUT" | tr '\n' ' ')"
    fi
else
    failure "(4) THE READER WAS NOT CHECKED. vendor/doctor/agent or python3 is absent, so nothing here proves the shipped Doctor does anything sensible with a cannot_run marker."
fi
fi   # HAVE_CANNOT_RUN

# ---------------------------------------------------------------------------
# (5) POPULATION. All THIRTEEN hydrate steps must record something. Named
#     individually so a source that goes dark is visible in the output rather
#     than merely missing from a total.
# ---------------------------------------------------------------------------
echo
echo "  -- hydrate sentinel coverage --"
ALL_SOURCES="contacts calendar email whatsapp browsing email_preferences \
imessage apple_notes people dedupe places privacy_backfill ai_conversations"
COVERED=0
UNCOVERED=""
for src in $ALL_SOURCES; do
    if grep -Eq "_hydrate_sentinel_record(_error|_no_data|_cannot_run)? +\"${src}\"" "$INSTALL"; then
        echo "     recorded   $src"
        COVERED=$((COVERED + 1))
    else
        echo "     BLIND      $src   <- runs with no .done sentinel (#848)"
        UNCOVERED="${UNCOVERED} ${src}"
    fi
done
echo
COVERAGE_FLOOR=13
if [[ "$COVERED" -ge "$COVERAGE_FLOOR" ]]; then
    pass "(5) every hydrate step records a sentinel (${COVERED} of 13, floor ${COVERAGE_FLOOR})"
else
    failure "(5) ${COVERED} of 13 hydrate steps record a sentinel. Blind:${UNCOVERED}"
fi

# ---------------------------------------------------------------------------
# (6) ANTI-VACUITY for (5). The population scan must go RED when a source
#     genuinely has no recorder. Proved by running the same predicate over a
#     doctored copy with every `contacts` recorder deleted -- not by trusting
#     that a grep which found thirteen things could also fail to find one.
# ---------------------------------------------------------------------------
DOCTORED="${HARNESS}/install_no_contacts.sh"
grep -v '_hydrate_sentinel_record[a-z_]* "contacts"' "$INSTALL" > "$DOCTORED"
if grep -Eq '_hydrate_sentinel_record(_error|_no_data|_cannot_run)? +"contacts"' "$DOCTORED"; then
    failure "(6) ANTI-VACUITY BROKEN: the doctored copy still contains a contacts recorder, so nothing was removed and this control tests nothing"
else
    pass "(6) ANTI-VACUITY: with every contacts recorder stripped, the population predicate reports contacts BLIND"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
