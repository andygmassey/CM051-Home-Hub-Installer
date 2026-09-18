#!/usr/bin/env bash
# The walk record must say whether the box was SEEDED before the grounded probe asked.
#
# 🔴 WHY. assistant_answers_grounded is red on 17 of the 21 committed walk
# records. An UNSEEDED box and a BROKEN product produce EXACTLY THE SAME RED,
# and until this field existed not one of those 17 could say which it was. So
# every one of those reds has been ambiguous, and the ambiguity is invisible:
# the record looks complete either way.
#
# grounding_seed.sh has ALWAYS set GROUNDING_SEED_STATE to one of five values
# (unrun, seeded, skipped, absent, failed). NOTHING CONSUMED IT, and
# run_box_walk.sh discarded the exit code with `|| true` on top. That is the
# "built with no consumer" failure mode, sitting under the single most-failed
# probe in the corpus.
#
# WHAT THIS ASSERTS is the READER, because that is where a state becomes a
# sentence a person acts on. A field written and never interpreted would be the
# same defect one layer along.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GATE="${REPO}/scripts/verify_walk_record.sh"
# THE FIXTURE IS A REAL COMMITTED RECORD, not a hand-built one. A synthetic
# record has to reproduce every field this gate refuses on, and each one I
# missed produced a refusal that looked like a failure of the thing under test.
# Varying ONE field on a real record means a difference in output can only come
# from that field.
DECLARED="$(awk -F'\t' '!/^#/ && NF>1 {printf "%s ", $1}' "${REPO}/scripts/walk_promote_scope.tsv")"
BASE="${REPO}/walks/v1.0.100.tsv"
[ -f "${BASE}" ] || cant "no committed walk record at ${BASE} to build the fixture from"
# The committed record carries the literal string "unavailable" here, so the
# fixture supplies a well-formed sha on BOTH sides. The gate compares the two;
# it is not the subject of this test and must simply agree.
SHA64="$(printf 'a%.0s' $(seq 1 64))"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Copy the real record, drop any existing seed field, add the one under test.
write_record() {
    local dir="$1" seed="$2"
    mkdir -p "${dir}"
    # Keep only failed probes that walk_promote_scope.tsv DECLARES. An
    # undeclared probe makes the gate exit at its promote-scope refusal, which
    # is line 545, and BOTH advisory blocks live at 583 and 604 -- so the gate
    # would never reach the thing under test. That ordering is pre-existing and
    # is recorded on the board rather than worked around silently; here the
    # fixture simply avoids it. assistant_answers_grounded, the probe this
    # whole field exists to disambiguate, IS declared, so the fixture keeps it.
    awk -F'\t' -v s="${SHA64}" -v decl="${DECLARED}" '
        BEGIN { n_kept = 0; split(decl, d, " "); for (i in d) ok_probe[d[i]] = 1 }
        $1 == "grounding_seed" { next }
        $1 == "artefact_sha256" { printf "%s\t%s\n", $1, s; next }
        $1 == "failed_probe" { if (!($2 in ok_probe)) next; n_kept++; print; next }
        $1 == "fail" { next }
        $1 == "failed_probe_names_recorded" { next }
        { print }
        END { printf "fail\t%d\nfailed_probe_names_recorded\t%d of %d\n", n_kept, n_kept, n_kept }' \
        "${BASE}" > "${dir}/v9.9.9.tsv"
    [ -n "${seed}" ] && printf 'grounding_seed\t%s\n' "${seed}" >> "${dir}/v9.9.9.tsv"
    # the gate keys the filename off the version it is asked about
    sed -i.bak 's/^version\t.*/version\tv9.9.9/' "${dir}/v9.9.9.tsv" && rm -f "${dir}/v9.9.9.tsv.bak"
}

# Returns the gate's combined output for a record carrying $1 as the seed field.
run_with() {
    local seed="$1" d="${TMP}/w$$_${RANDOM}"
    write_record "${d}" "${seed}"
    OSTLER_WALK_RECORD_DIR="${d}" /bin/bash "${GATE}" v9.9.9 "${SHA64}" 2>&1 || true
}

echo "-- the reader must turn each seed state into a DIFFERENT sentence --"

# CONTROL FIRST: the apparatus must be alive before any absence is asserted.
_ctl="$(run_with seeded)"
if printf '%s' "${_ctl}" | grep -q 'grounding_seed'; then
    ok "CONTROL: the gate reaches its advisory block and names the field"
else
    bad "CONTROL: the gate never mentioned the field at all, so every assertion
       below would be vacuous. Output was:
${_ctl}"
    echo; echo "== ${PASS} pass / ${FAIL} fail =="; exit 1
fi

# Each state must produce a DISTINCT reading. Same corpus, same record shape,
# one field varying, so a difference can only come from the field.
assert_says() {
    local seed="$1" want="$2" label="$3" out
    out="$(run_with "${seed}")"
    if printf '%s' "${out}" | grep -qi -- "${want}"; then
        ok "${label}"
    else
        bad "${label} -- did not find '${want}'. Advisory lines were:
$(printf '%s' "${out}" | grep -i grounding_seed || echo '   (none)')"
    fi
}

assert_says "seeded rc=0"  "red here is about the"    "seeded reads as: a red here is about the PRODUCT"
assert_says "skipped rc=1" "UNSEEDED"             "skipped reads as: the probe ran unseeded, a red says nothing"
assert_says "absent rc=1"  "NOT evidence against" "absent reads as: not evidence against the build"
assert_says "failed rc=1"  "NOT evidence against" "failed reads as: not evidence against the build"
assert_says "not-recorded(marker unreadable)" "CANNOT-RUN" \
    "an unreadable marker reads as CANNOT-RUN, not as seeded and not as unseeded"

# THE ABSENCE ARM. An old record predates the field, and that must be SAID
# rather than defaulted. This is the arm that stops a missing field reading as
# a clean one, which is how the other 21 records got here.
_out="$(run_with "")"
if printf '%s' "${_out}" | grep -q 'ABSENT from this record'; then
    ok "a record with NO seed field is reported ABSENT, not assumed seeded"
else
    bad "a record with no seed field did not report the absence, so every
       pre-existing walk record would read as though it had been graded"
fi

# MUST-MISS: the two states must not collapse into one sentence. Without this,
# a reader that printed the same text for everything would pass every arm above.
_a="$(run_with 'seeded rc=0'  | grep -i grounding_seed || true)"
_b="$(run_with 'skipped rc=1' | grep -i grounding_seed || true)"
if [ -n "${_a}" ] && [ "${_a}" != "${_b}" ]; then
    ok "MUST-MISS: seeded and skipped produce DIFFERENT readings, so the field
       is being interpreted rather than echoed"
else
    bad "MUST-MISS: seeded and skipped produced the SAME reading, so the reader
       is echoing the value and not grading it"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[ "${FAIL}" -eq 0 ]
