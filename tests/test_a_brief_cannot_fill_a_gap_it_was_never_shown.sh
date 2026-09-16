#!/usr/bin/env bash
# A BRIEF CANNOT FILL A GAP IT WAS NEVER SHOWN.
# ============================================================================
# WHAT REACHED A CUSTOMER'S PHONE (HR015 #948)
#
# Four daily briefs were delivered as iMessages. One of them told the customer
# about "trips to places like New York in September 2026 and Singapore later
# that year". There are no such trips. The phrase "places like" is the tell:
# the model was generating EXAMPLES and the brief presented them as recall.
#
# WHY THIS IS A DATA-PATH DEFECT AND NOT A PROMPT DEFECT
#
# The brief is written by an agent cron job whose only context is CONTEXT.md,
# written by context-refresh/bin/generate_pwg_context.py and injected verbatim
# into every system prompt by the daemon. Every section of that digest renders
# only when it has content:
#
#     if calendar_by_owner:
#         out.append("## Calendar events by owner")
#
# So a section whose source returned 401, 400 or nothing at all is byte for
# byte identical, in the document the model reads, to a section whose source
# answered and held nothing. The difference WAS measured. It went to _FAILURES,
# to a stderr report and to the process exit code. Measured on origin/main
# before this change: the string "_FAILURES" occurs inside build_digest only in
# its own docstring, and in none of its 36 out.append calls. Positive control,
# same grep, same flags, over main(): one real occurrence, where the failure
# ledger drives the exit code. So the zero is a measurement and not a broken
# predicate.
#
# launchd hears the exit code. The Doctor can read the stderr log. The model
# composing the message hears neither, and it is the only consumer that can act
# on the difference. Told to use only the facts in its context, handed a void
# where a section should be, and asked for three or four sentences about the
# day, it produces the most plausible thing available to it.
#
# A firmer sentence in the cron prompt hides that and fixes none of it, which
# is why #948 says in as many words DO NOT FIX BY PROMPT-TUNING. The fix is to
# put the fact in the document: three states, three renderings.
#
#     items                -> the section renders
#     read OK, zero items  -> "nothing stored"
#     read did not answer  -> "COULD NOT BE READ", with the observed status
#
# WHAT THIS GUARDS, AND THE ONE THING IT DELIBERATELY DOES NOT
#
# It asserts the VERDICT carried by the digest, never a sentence of prose: the
# gap block is found by its heading and its two state tokens, so the copy round
# it can be reworded without this test going green while blind. It does not
# assert that a model behaves well when shown the block; no test in this repo
# can. It asserts the one thing that was missing and is now present: the
# consumer is shown the difference.
#
# EXIT CODES, DELIBERATELY DISTINCT
#   0  every limb passed
#   1  at least one limb failed: a gap is invisible to the brief writer again
#   2  CANNOT-RUN. The digest module could not be imported or driven, so
#      NOTHING was measured. That is not a pass.
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Overridable so the mutation harness below can point every limb at a DIFFERENT
# copy of the module (the pre-fix one from origin/main) without touching the
# working tree. Never `git stash`: it is repo-global across worktrees.
GEN="${OSTLER_DIGEST_MODULE:-${REPO}/context-refresh/bin/generate_pwg_context.py}"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

WORK="$(mktemp -d)"
cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT

# ── Preflight: can we look at all? ──────────────────────────────────────────
#
# A limb that reports FAIL because the module would not import tells the reader
# the defect is back when in truth nothing was examined. Both outcomes print
# identically unless this branch exists, which is the failure this whole file
# is about, committed by the file itself.

command -v python3 >/dev/null 2>&1 || {
    cant "python3 is not on PATH -- the digest module could not be driven"
    echo; exit 2
}

if [ ! -r "${GEN}" ]; then
    cant "digest module unreadable at ${GEN} -- NOTHING was examined"
    echo; exit 2
fi

cat > "${WORK}/drive.py" <<'PY'
"""Drive the shipped digest module against injected graph data.

Scenarios are chosen by argv[1]. Every scenario prints the digest (or the
literal token NONE) on stdout so the bash limbs can assert on the document the
daemon would actually inject.
"""
import importlib.util
import os
import sys

SCRIPT = os.environ["OSTLER_DIGEST_MODULE"]

spec = importlib.util.spec_from_file_location("gen_under_test", SCRIPT)
if spec is None or spec.loader is None:
    print("CANNOT-RUN: no import spec for %s" % SCRIPT, file=sys.stderr)
    sys.exit(97)
gen = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(gen)
except Exception as exc:  # noqa: BLE001 -- any import failure is CANNOT-RUN
    print("CANNOT-RUN: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(97)

for required in ("build_digest", "_note_failure", "_get_json", "_sparql_select"):
    if not hasattr(gen, required):
        print("CANNOT-RUN: module has no %s" % required, file=sys.stderr)
        sys.exit(97)

PEOPLE = {
    "recent_meetings": [
        {"name": "Sam Patel", "organisation": "Acme Ltd",
         "last_contact": "2026-09-10"},
    ],
    "birthdays": [],
}


def _hub(mapping, failing=()):
    """Return a _get_json stand-in.

    Paths in ``failing`` record a measured failure exactly the way the real
    reader does, then return None. Paths in ``mapping`` return data. Anything
    else returns None WITHOUT recording a failure, which is the honest shape of
    "the source answered and held nothing".
    """
    def fake(path):
        for prefix in failing:
            if path.startswith(prefix):
                gen._note_failure("GET %s -> HTTP 401" % path)
                return None
        for prefix, payload in mapping.items():
            if path.startswith(prefix):
                return payload
        return None
    return fake


scenario = sys.argv[1]

if scenario == "one-failed-one-empty":
    # People has content. Preferences (coach/recent) REFUSED. Calendar and the
    # user-asserted store answered and held nothing.
    gen._get_json = _hub({"/api/v1/suggestions": PEOPLE},
                         failing=("/api/v1/coach/recent",))
    gen._sparql_select = lambda sparql: []
    out = gen.build_digest()

elif scenario == "all-sections-full":
    gen._get_json = _hub({
        "/api/v1/suggestions": PEOPLE,
        "/api/v1/timeline": {"items": [
            {"kind": "meeting", "summary": "Quarterly review",
             "date": "2026-09-12"},
        ]},
        "/api/v1/coach/recent": {"observations": [
            {"tip": "Prefers short written updates"},
        ]},
    })
    gen._sparql_select = lambda sparql: [
        {"text": "Mary is your spouse", "name": "Mary Jones",
         "rel": "spouse", "created": "2026-06-16T09:00:00Z"},
        {"calendarOwner": "Mary Jones", "summary": "Flight to the coast",
         "start": "2026-10-04T07:15:00Z", "calendarType": "personal"},
        {"orgName": "Acme Ltd", "role": "client"},
    ]
    out = gen.build_digest()

elif scenario == "oversized-with-a-gap":
    # Enough user-asserted facts to blow MAX_CHARS, plus one refused read. The
    # gap block must survive the clip, which cuts from the END.
    gen._get_json = _hub({"/api/v1/suggestions": PEOPLE},
                         failing=("/api/v1/coach/recent",))
    gen._sparql_select = lambda sparql: [
        {"text": "Synthetic standing fact number %03d, padded so the digest "
                 "exceeds the prompt budget and has to be clipped" % i}
        for i in range(gen.MAX_USER_ASSERTED)
    ]
    out = gen.build_digest()

else:
    print("CANNOT-RUN: unknown scenario %s" % scenario, file=sys.stderr)
    sys.exit(97)

print(out if out is not None else "NONE")
PY

drive() {
    OSTLER_DIGEST_MODULE="${GEN}" python3 "${WORK}/drive.py" "$1" 2>"${WORK}/drive.err"
}

# A CANNOT-RUN from the driver must never be scored as a limb result.
drive_or_cant() {
    local scenario="$1" outfile="$2"
    drive "${scenario}" > "${outfile}"
    local rc=$?
    if [ "${rc}" -eq 97 ]; then
        cant "scenario ${scenario}: $(cat "${WORK}/drive.err")"
        return 2
    fi
    if [ "${rc}" -ne 0 ]; then
        cant "scenario ${scenario}: driver exited ${rc}: $(cat "${WORK}/drive.err")"
        return 2
    fi
    return 0
}

echo "== a brief cannot fill a gap it was never shown (HR015 #948) =="
echo "   module under test: ${GEN}"
echo

# ── Limb 1: PREMISE. The fixture really does build a digest. ────────────────
#
# Checked FIRST and asserted on CONTENT, because limbs 2 and 3 both look for
# the ABSENCE of a defect inside a document. If the document were empty they
# would pass for the wrong reason, which is a zero denominator reading as
# success.

if drive_or_cant "one-failed-one-empty" "${WORK}/mixed.md"; then
    if [ "$(cat "${WORK}/mixed.md")" != "NONE" ] \
       && grep -q "Sam Patel" "${WORK}/mixed.md"; then
        ok "premise: the mixed fixture built a digest and it carries the populated section"
    else
        bad "premise: the mixed fixture produced no usable digest, so limbs 2-4 would be vacuous"
    fi
fi

# ── Limb 2: THE DEFECT. A refused read is named in the digest. ──────────────

if [ -s "${WORK}/mixed.md" ]; then
    if grep -q "COULD NOT BE READ" "${WORK}/mixed.md"; then
        ok "a refused read is declared in the digest as COULD NOT BE READ"
    else
        bad "a refused read left NO trace in the digest: the brief writer cannot tell 'we could not look' from 'there is nothing there', which is how 'places like New York' reached a customer"
    fi
    if grep -q "coach/recent" "${WORK}/mixed.md"; then
        ok "the declaration names the route that refused, not just that something did"
    else
        bad "the digest declares a gap without naming what caused it, so no reader can act on it"
    fi
fi

# ── Limb 3: CONTROL of the same shape. An empty-but-read section is ─────────
#            declared DIFFERENTLY, not as unreadable.
#
# Without this, a predicate that scored every absent section COULD NOT BE READ
# would pass limb 2 while telling the model it is blind to data that is simply
# not there. That is the same defect pointed the other way.

if [ -s "${WORK}/mixed.md" ]; then
    if grep -q "nothing stored" "${WORK}/mixed.md"; then
        ok "control: a section that answered and held nothing is declared 'nothing stored'"
    else
        bad "control: an empty-but-readable section is not declared at all, so the model still meets a silent void"
    fi
    if grep -q "Calendar events by owner: nothing stored" "${WORK}/mixed.md" \
       && ! grep -q "Calendar events by owner: COULD NOT BE READ" "${WORK}/mixed.md"; then
        ok "the two states are told apart on the same document: the empty calendar is not reported as unreadable"
    else
        bad "the two states are conflated: an empty section and a refused one render the same way"
    fi
fi

# ── Limb 4: the gap block is DATA-DRIVEN, not boilerplate. ──────────────────
#
# A block printed unconditionally would pass limbs 2 and 3 on any input and
# assert nothing at all.

if drive_or_cant "all-sections-full" "${WORK}/full.md"; then
    if [ "$(cat "${WORK}/full.md")" != "NONE" ] && grep -q "Sam Patel" "${WORK}/full.md"; then
        if grep -q "What is not in this digest" "${WORK}/full.md"; then
            bad "the gap block rendered on a digest with no gaps, so it is boilerplate and limbs 2-3 prove nothing"
        else
            ok "anti-vacuity: no gap block when every section produced content"
        fi
    else
        cant "the all-sections-full fixture did not build a digest, so limb 4 measured nothing"
    fi
fi

# ── Limb 5: the block survives the MAX_CHARS clip. ──────────────────────────
#
# build_digest clips from the END. A gap block placed after the content would
# be the first thing a busy graph deletes, so the honesty would go missing on
# exactly the installs with the most to say. Green-while-blind, seasonally.

if drive_or_cant "oversized-with-a-gap" "${WORK}/big.md"; then
    if grep -q "digest truncated to fit the prompt budget" "${WORK}/big.md"; then
        if grep -q "COULD NOT BE READ" "${WORK}/big.md"; then
            ok "the gap declaration survives the MAX_CHARS clip on an oversized digest"
        else
            bad "the clip removed the gap declaration: on a busy graph the brief writer is blind again"
        fi
    else
        cant "the oversized fixture did not exceed MAX_CHARS, so the clip was never exercised"
    fi
fi

# ── Limb 6: the shipped entry point, end to end, on the real file. ──────────
#
# Limbs 1-5 drive build_digest in-process. This one runs the artefact the
# LaunchAgent runs, against a box where nothing answers, and asserts on the
# FILE the daemon injects. Consumer-side: the subject is the document that
# becomes the customer's message, not a function's return value.

STALEDIR="${WORK}/stale"
mkdir -p "${STALEDIR}"
cat > "${STALEDIR}/CONTEXT.md" <<'PRIOR'
# Personal Context

Baseline awareness of the people, meetings, and preferences that matter to the
person you assist.
_Last updated: 2026-09-01 08:00 UTC._

## People you interact with most

- Sam Patel (Acme Ltd)
PRIOR

run_dead_box() {
    ZEROCLAW_WORKSPACE_DIR="$1" \
    OSTLER_ICAL_BASE_URL="http://127.0.0.1:1" \
    OXIGRAPH_URL="http://127.0.0.1:1" \
    OSTLER_SERVICE_TOKEN="synthetic-token-not-a-real-credential" \
    no_proxy='*' NO_PROXY='*' \
        python3 "${GEN}" >/dev/null 2>&1
}

run_dead_box "${WORK}/stale"
rc=$?
if [ "${rc}" -ne 2 ]; then
    cant "the shipped script exited ${rc} on a dead box, expected 2 (nothing produced); limb 6 measured nothing"
elif [ ! -f "${STALEDIR}/CONTEXT.md" ]; then
    bad "the prior digest was deleted on a failed refresh: a stale digest beats no digest and that rule is not being changed"
elif grep -q "NOT REFRESHED" "${STALEDIR}/CONTEXT.md" \
     && grep -q "Sam Patel" "${STALEDIR}/CONTEXT.md"; then
    ok "a digest that could not be refreshed is KEPT and stamped NOT REFRESHED in the file the daemon injects"
else
    bad "the prior digest was left claiming to be current: the brief recites facts of unknown age as today's news"
fi

# ── Limb 7: stamping is idempotent. ────────────────────────────────────────
#
# This runs hourly. A banner that appended rather than replaced would add a
# paragraph an hour until the MAX_CHARS clip ate the customer's actual data.

if [ -f "${STALEDIR}/CONTEXT.md" ]; then
    run_dead_box "${WORK}/stale"
    banners="$(grep -c 'ostler:context-refresh-status -->' "${STALEDIR}/CONTEXT.md")"
    # One open marker and one close marker after two runs, never four.
    if [ "${banners}" = "2" ]; then
        ok "a second failed refresh replaces the stamp rather than stacking a second one"
    else
        bad "stamps accumulate: ${banners} marker(s) after two failed refreshes, expected 2"
    fi
fi

# ── Limb 8: ABSENCE CONTROL. Nothing is invented where there was nothing. ──
#
# The fix must not create a CONTEXT.md on a box that never had one. An absent
# digest on a fully dark box is asserted on purpose by
# context-refresh/tests/test_context_digest_auth.py and by
# tests/test_context_refresh_wired.sh, and manufacturing a file here would be a
# fresh defect of the same family as the one being fixed.

FRESHDIR="${WORK}/fresh"
mkdir -p "${FRESHDIR}"
run_dead_box "${WORK}/fresh"
rc=$?
if [ "${rc}" -ne 2 ]; then
    cant "the shipped script exited ${rc} on a dead box with no prior digest; limb 8 measured nothing"
elif [ -f "${FRESHDIR}/CONTEXT.md" ]; then
    bad "a CONTEXT.md was manufactured on a box where no source answered and none existed before"
else
    ok "absence control: no digest is invented where none existed and nothing answered"
fi

echo
echo "PASS=${PASS} FAIL=${FAIL} CANNOT-RUN=${CANT}"

# ── Mutation harness ───────────────────────────────────────────────────────
#
# Two mutants, and they fail in OPPOSITE directions on purpose.
#
#   MUTANT A reinstates the defect by running every limb against the pre-fix
#   module materialised from origin/main with `git show`. The suite must go
#   RED. A guard that cannot be made to fail is not a guard.
#
#   MUTANT B blinds the suite's own scanner by pointing it at a module that
#   cannot be imported. The suite must REFUSE (exit 2), not pass. A scanner
#   that reports "no defect found" when it could not look is the exact shape
#   of the bug under test.

if [ "${SELF_TEST}" -eq 1 ]; then
    echo
    echo "== self-test: mutants =="
    SELF_PASS=0; SELF_FAIL=0; SELF_CANT=0

    PREFIX_DIR="${WORK}/prefix"
    mkdir -p "${PREFIX_DIR}"
    if git -C "${REPO}" show \
        "${OSTLER_PREFIX_REF:-origin/main}:context-refresh/bin/generate_pwg_context.py" \
        > "${PREFIX_DIR}/generate_pwg_context.py" 2>/dev/null \
       && [ -s "${PREFIX_DIR}/generate_pwg_context.py" ]; then
        set +e
        OSTLER_DIGEST_MODULE="${PREFIX_DIR}/generate_pwg_context.py" \
            bash "${BASH_SOURCE[0]}" > "${WORK}/mutantA.out" 2>&1
        mrc=$?
        set -e
        if [ "${mrc}" -eq 1 ]; then
            SELF_PASS=$((SELF_PASS+1))
            echo "  [PASS] MUTANT A: the pre-fix digest module makes this suite FAIL (exit 1)"
            grep -E '^\s+\[FAIL\]' "${WORK}/mutantA.out" | sed 's/^/         /'
        else
            SELF_FAIL=$((SELF_FAIL+1))
            echo "  [FAIL] MUTANT A: the pre-fix module exited ${mrc}, expected 1. This guard does not detect the defect it was written for."
            tail -20 "${WORK}/mutantA.out" | sed 's/^/         /'
        fi
    else
        # The pre-fix copy is unavailable (shallow clone, no origin/main). That
        # is CANNOT-RUN for the mutant, not a mutant that passed, and it gets
        # its own exit code below so nobody can read "the mutant was not run"
        # as "the guard was proved".
        echo "  [CANNOT-RUN] MUTANT A: could not materialise ${OSTLER_PREFIX_REF:-origin/main} copy of the digest module -- the guard was NOT proved"
        SELF_CANT=$((SELF_CANT+1))
    fi

    set +e
    OSTLER_DIGEST_MODULE="${WORK}/no-such-module.py" \
        bash "${BASH_SOURCE[0]}" > "${WORK}/mutantB.out" 2>&1
    brc=$?
    set -e
    if [ "${brc}" -eq 2 ]; then
        SELF_PASS=$((SELF_PASS+1))
        echo "  [PASS] MUTANT B: a suite that cannot read the module REFUSES (exit 2) rather than passing"
    else
        SELF_FAIL=$((SELF_FAIL+1))
        echo "  [FAIL] MUTANT B: a blinded suite exited ${brc}, expected 2 CANNOT-RUN"
    fi

    echo
    echo "SELF-TEST PASS=${SELF_PASS} FAIL=${SELF_FAIL} CANNOT-RUN=${SELF_CANT}"
    [ "${SELF_FAIL}" -eq 0 ] || exit 1
    [ "${SELF_CANT}" -eq 0 ] || exit 2
fi

# CANNOT-RUN is not FAIL and is not PASS: it gets its own exit code so a run
# that examined nothing can never be read as a clean one.
if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
if [ "${PASS}" -eq 0 ] || [ "${CANT}" -gt 0 ]; then
    exit 2
fi
exit 0
