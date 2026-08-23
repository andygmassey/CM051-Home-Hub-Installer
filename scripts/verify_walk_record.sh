#!/usr/bin/env bash
#
# verify_walk_record.sh <version>
#
# #844 -- NOTHING BETWEEN "GATES GREEN" AND "CUSTOMER DOWNLOAD" IS A RUNTIME
# PROOF. Measured 2026-08-23 on origin/main, with a control:
#
#   OS003 bin/ pipeline/ gates/ .github/   post_walk_qa  0 hits
#                                          run_box_walk  0 hits
#     CONTROL, same dirs, same grep        verify_must_contain  bin/cut.sh:368
#
#   CM051, every reference to post_walk_qa.sh:
#     scripts/post_walk_qa.sh      its own usage string
#     scripts/box_walk_probes/README.md   documentation
#     ...and nothing else. NOTHING INVOKES IT.
#
# So the chain was:  cut -> gates green -> publish --latest -> customer.
# 14 probes and a four-count verdict existed the whole time and were never
# consulted. That is not a missing test. It is a missing INVOCATION, which is
# why writing another probe would have changed nothing.
#
# The probes cannot run in CI: they need a real, installed, walked box, and a
# box only exists AFTER the DMG is published. That ordering is why this is a
# record-and-gate rather than a call. The cut publishes; a human walks; the
# walk writes evidence; and only then may the customer download be repointed.
#
# WHAT THIS GATE ASSERTS
#   1. a walk record exists for EXACTLY the version being published
#   2. it says CLEAN -- not PARTIAL, not FAILED
#   3. its own counts agree with that verdict (a record claiming CLEAN with
#      fail>0 is a corrupt record, and is refused as loudly as a failure)
#
# EXIT CODES -- CANNOT-RUN IS NOT A PASS AND NOT A FAIL
#   0  a clean walk of this exact version is on record
#   1  a walk was recorded and it was NOT clean          (evidence of badness)
#   2  no record, unreadable record, or version mismatch (absence of evidence)
#   3  usage
#
# 1 and 2 are separated because they call for different actions: 1 means fix
# the box, 2 means go and walk it. A gate that printed one number for both
# would send a tired operator to debug a defect that was never measured.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WALK_DIR="${OSTLER_WALK_RECORD_DIR:-${REPO_ROOT}/walks}"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/verify_walk_record.sh <version e.g. v1.0.42>" >&2
    exit 3
fi

RECORD="${WALK_DIR}/${VERSION}.tsv"

if [[ ! -f "$RECORD" ]]; then
    cat >&2 <<MSG
[walk-gate] NO WALK RECORD for ${VERSION}.

  looked for: ${RECORD}

  This is CANNOT-RUN, not a failure: nobody has measured this build on a real
  box, so nothing is known about it either way. Gates being green says the
  artefact assembled correctly. It says nothing about whether it installs.

  To produce the record:
      scripts/post_walk_qa.sh <box-host> ${VERSION}
  then commit the file it writes.
MSG
    exit 2
fi

field() {
    # Tab-separated key/value. grep -q is deliberately NOT used here: this
    # file's own guard sets pipefail, and `producer | grep -q` lets grep exit
    # on first match, killing the producer with SIGPIPE (141) which pipefail
    # then promotes to the pipeline's status. Read the file directly instead.
    awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$RECORD"
}

REC_VERSION="$(field version)"
VERDICT="$(field verdict)"
N_FAIL="$(field fail)"
N_CANNOT="$(field cannot_run)"
N_BROKEN="$(field broken)"
N_PASS="$(field pass)"

# --- the record must be ABOUT the thing being published ----------------------
# Without this a stale v1.0.38 record, or one copied by hand, would clear the
# gate for a build it never touched. The filename alone is not evidence: files
# get renamed, and the version inside is what the QA run actually measured.
if [[ "$REC_VERSION" != "$VERSION" ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} is a record of '${REC_VERSION:-<no version field>}', not ${VERSION}." >&2
    echo "            A record proves something about the build it was taken on. Walk ${VERSION}." >&2
    exit 2
fi

# --- a malformed record is not a pass ----------------------------------------
for f in verdict pass fail cannot_run broken; do
    v="$(field "$f")"
    if [[ -z "$v" ]]; then
        echo "[walk-gate] REFUSED: ${RECORD} has no '${f}' field. Incomplete record, treated as no record." >&2
        exit 2
    fi
done
for f in pass fail cannot_run broken; do
    v="$(field "$f")"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "[walk-gate] REFUSED: ${RECORD} field '${f}' is '${v}', not a number." >&2
        exit 2
    fi
done

# --- the verdict must agree with the counts ----------------------------------
# A record is a claim plus its evidence. If they disagree, the claim is the
# part to distrust: this is the shape where a summary line says CLEAN because
# a variable was never updated, while the numbers underneath say otherwise.
if [[ "$VERDICT" == "CLEAN" && ( "$N_FAIL" -ne 0 || "$N_CANNOT" -ne 0 || "$N_BROKEN" -ne 0 ) ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} claims CLEAN but reports fail=${N_FAIL} cannot_run=${N_CANNOT} broken=${N_BROKEN}." >&2
    echo "            The verdict and its own counts disagree. Trust the counts." >&2
    exit 1
fi

# --- a walk that measured nothing is not a clean walk ------------------------
if [[ "$N_PASS" -eq 0 ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} records zero passing probes." >&2
    echo "            Nothing was measured. An empty walk and a clean walk print the same verdict; they are not the same thing." >&2
    exit 2
fi

case "$VERDICT" in
    CLEAN)
        echo "[walk-gate] OK: ${VERSION} walked clean on $(field walked_at) -- pass=${N_PASS} fail=0 cannot_run=0 broken=0"
        exit 0
        ;;
    FAILED)
        echo "[walk-gate] REFUSED: the ${VERSION} walk FAILED (fail=${N_FAIL}). Real defects were measured on a real box." >&2
        exit 1
        ;;
    PARTIAL)
        echo "[walk-gate] REFUSED: the ${VERSION} walk was PARTIAL -- cannot_run=${N_CANNOT} broken=${N_BROKEN}." >&2
        echo "            Coverage was lost. Coverage lost is not coverage passed." >&2
        exit 2
        ;;
    *)
        echo "[walk-gate] REFUSED: unknown verdict '${VERDICT}' in ${RECORD}." >&2
        echo "            An unrecognised verdict fails closed; a typo must never read as CLEAN." >&2
        exit 2
        ;;
esac
