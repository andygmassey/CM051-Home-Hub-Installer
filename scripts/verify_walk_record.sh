#!/usr/bin/env bash
#
# verify_walk_record.sh <version> <expected-artefact-sha256>
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
#   2. it was taken on EXACTLY the artefact being published, by sha256 (#931)
#   3. it says CLEAN -- not PARTIAL, not FAILED
#   4. its own counts agree with that verdict (a record claiming CLEAN with
#      fail>0 is a corrupt record, and is refused as loudly as a failure)
#   5. the version and the artefact sha were MEASURED off the box, not
#      asserted -- the record's own *_source fields say which, and until #931
#      nothing read them
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
EXPECTED_SHA="${2:-}"

# Lowercase without ${var,,}: this runs on the CUT HOST, which is macOS, and
# macOS ships bash 3.2 where that expansion is a syntax error. #1103 was an
# evening spent on exactly that class.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [[ -z "$VERSION" || -z "$EXPECTED_SHA" ]]; then
    cat >&2 <<'MSG'
usage: scripts/verify_walk_record.sh <version e.g. v1.0.42> <artefact-sha256>

  The sha256 is REQUIRED and it is the sha of the artefact about to be
  published. It is not optional because an optional expected-sha lets a caller
  silently downgrade this gate back to a version-only check -- which is the
  defect (#931) this argument exists to close, one level up.
MSG
    exit 3
fi

# A malformed EXPECTED_SHA is the CALLER's defect, not the record's, so it is a
# usage error (3) and never a refusal (2). Getting this wrong would send an
# operator to re-walk a box because publish_release.sh passed an empty string.
if ! [[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "[walk-gate] USAGE: expected-artefact-sha256 is '${EXPECTED_SHA}', not 64 hex characters." >&2
    echo "            This is the caller's argument, not the walk record. Nothing was measured." >&2
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

# --- the QA exit status is EVIDENCE, and it was being written and never read --
#
# ORM's review of this PR, 2026-08-23 09:16Z. He drove this script through seven
# hand-built records and the seventh was `qa_exit=1 with clean counts` -> rc=0,
# ACCEPTED. He was right, and the measurement was unambiguous:
#
#     grep -c qa_exit scripts/verify_walk_record.sh   0
#     written at scripts/post_walk_qa.sh:223 from "$overall"
#     CONTROL, fields this script DOES read:
#       pass 7 · fail 12 · cannot_run 6 · broken 6 · VERDICT 4 · version 8
#
# A field documented in walks/README.md as part of the format, produced on every
# run, and consumed by nothing. That is this repo's signature defect and I
# shipped a fresh instance of it in the gate built to outlaw it.
#
# WHY IT MATTERS BEYOND TIDINESS, which is ORM's sharper point. post_walk_qa.sh
# folds limbs into `overall` that do NOT move the four probe counts -- the
# CUT-MANIFEST limb is one. So qa_exit is the ONLY field that can carry those
# failures. Today the script is accidentally safe because VERDICT is derived
# from the same `overall` variable, which means **one variable feeds two fields
# and the protection is a coincidence of implementation, not a property of the
# format**. The moment those two derivations diverge, a QA failure is accepted
# as a clean walk. Assert the field itself, not the variable behind it.
#
# Absent qa_exit is CANNOT-RUN (2), not FAIL: an old record predating the field
# is not evidence of badness, it is absence of evidence, and the exit codes of
# this script keep those apart.
QA_EXIT="$(field qa_exit)"
if [[ -z "$QA_EXIT" ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} carries no qa_exit field." >&2
    echo "            post_walk_qa.sh has written it since #978. A record without it" >&2
    echo "            predates the format or was hand-made; either way the QA limbs" >&2
    echo "            that do not move the probe counts are unverifiable here." >&2
    exit 2
fi
if ! [[ "$QA_EXIT" =~ ^[0-9]+$ ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} field 'qa_exit' is '${QA_EXIT}', not a number." >&2
    exit 2
fi
if [[ "$VERDICT" == "CLEAN" && "$QA_EXIT" -ne 0 ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} claims CLEAN but the post-walk QA exited ${QA_EXIT}." >&2
    echo "            The probe counts and the QA verdict are DIFFERENT evidence." >&2
    echo "            QA limbs such as CUT-MANIFEST never move pass/fail/cannot_run/broken," >&2
    echo "            so a clean count set cannot vouch for them. Trust the failure." >&2
    exit 1
fi

# --- a walk that measured nothing is not a clean walk ------------------------
if [[ "$N_PASS" -eq 0 ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} records zero passing probes." >&2
    echo "            Nothing was measured. An empty walk and a clean walk print the same verdict; they are not the same thing." >&2
    exit 2
fi

# ── THE CHECKS BELOW APPLY ONLY TO A *CLEAN* CLAIM (#931) ────────────────────
#
# Scoping matters here and getting it wrong LOSES SIGNAL. Both records in
# walks/ today are FAILED and neither carries an artefact_sha256. Run
# unscoped, the absent-field check fires first and they go 1 -> 2: a walk that
# MEASURED four real defects would start reporting "nothing is known". Evidence
# of badness must outrank absence of evidence, so a FAILED or PARTIAL record
# keeps its own exit code and only a CLEAN claim has to prove which build it is
# talking about. This mirrors the qa_exit and counts checks above, both of which
# are already conditioned on CLEAN.
#
# The body is deliberately NOT indented: it contains here-documents, and an
# indented terminator does not close a <<MSG heredoc.
if [[ "$VERDICT" == "CLEAN" ]]; then
# --- ...AND A VERSION IS NOT AN IDENTIFIER OF A BUILD (#931) ------------------
#
# The check above is necessary and it is NOT sufficient. CFBundleShortVersionString
# read "1.0.50" for ELEVEN distinct assemblies of that cut, and CFBundleVersion
# was frozen at 2500 for seven cuts (#703). So the DMG that was walked and the
# DMG about to be handed to a customer can differ in every byte and still agree
# on every version string in the tree.
#
# post_walk_qa.sh already measures the version off the box with real care --
# the right bundle out of three, two named decoys, a refusal on mismatch. That
# is rigour applied to a quantity that cannot discriminate between builds.
# Measuring the wrong quantity harder buys epistemic status, not discrimination.
#
# A content hash can discriminate, and this is the only pair of values in the
# gate where both sides are one: the sha256 the walk recorded, against the
# sha256 publish_release.sh computed from the file it is about to upload.
#
# Absent field is CANNOT-RUN (2), not FAIL -- the qa_exit precedent below, for
# the same reason: a record predating the field is not evidence of badness, it
# is absence of evidence.
ARTEFACT_SHA="$(field artefact_sha256)"
if [[ -z "$ARTEFACT_SHA" ]]; then
    cat >&2 <<MSG
[walk-gate] REFUSED: ${RECORD} carries no artefact_sha256 field.

  This is CANNOT-RUN, not a failure. The record says a box running ${VERSION}
  was walked; it does not say WHICH BUILD of ${VERSION}, and version strings do
  not distinguish builds of one cut. post_walk_qa.sh has written this field
  since #931. A record without it predates the format.

  Re-walk with a post-#931 scripts/post_walk_qa.sh and commit the new record.
MSG
    exit 2
fi
# --- ...AND THE SHA MUST BE A MEASUREMENT (#931) ------------------------------
#
# An operator-supplied hash compared against the file it was copied from is a
# value checked against itself. The writer records HOW it got the number, and a
# non-measured source is refused here rather than trusted to be noticed.
#
# THIS IS CHECKED BEFORE THE VALUE IS PARSED, DELIBERATELY. When the writer
# could not measure, it records the reason in this field and the value reads
# `unavailable`. Validating the value first would answer a record that says
# "no DMG was on the box" with "that is not 64 hex characters" -- true, useless,
# and pointing at the wrong thing. CANNOT-RUN and ABSENT must not share a
# message, and two different CANNOT-RUNs must not share one either.
ARTEFACT_SHA_SOURCE="$(field artefact_sha256_source)"
if [[ -z "$ARTEFACT_SHA_SOURCE" ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} has artefact_sha256 but no artefact_sha256_source." >&2
    echo "            A hash with no stated provenance cannot be told from one typed in by hand." >&2
    exit 2
fi
case "$ARTEFACT_SHA_SOURCE" in
    measured\(*) : ;;
    *)
        cat >&2 <<MSG
[walk-gate] REFUSED: ${RECORD} says artefact_sha256_source ${ARTEFACT_SHA_SOURCE}.

  Anything that is not measured(...) means the hash is an ASSERTION about the
  walked artefact, not an observation of it -- and an asserted hash compared
  against the artefact it was asserted from always agrees. CANNOT-RUN.
MSG
        exit 2
        ;;
esac

if ! [[ "$ARTEFACT_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} field 'artefact_sha256' is '${ARTEFACT_SHA}', not 64 hex characters." >&2
    echo "            The source field claims it was measured, so this is a corrupt record," >&2
    echo "            not an unmeasured one. An unparseable hash is not a hash." >&2
    exit 2
fi
if [[ "$(lc "$ARTEFACT_SHA")" != "$(lc "$EXPECTED_SHA")" ]]; then
    cat >&2 <<MSG
[walk-gate] REFUSED: ${RECORD} was taken on a DIFFERENT BUILD of ${VERSION}.

  the record was walked on : ${ARTEFACT_SHA}
  about to be published    : ${EXPECTED_SHA}

  Same version, different artefact. This is the version-mismatch refusal above
  one level down: a record proves something about the build it was taken on,
  and this is not that build. Walk the artefact being published.
MSG
    exit 2
fi

# --- AND THE SAME TEST THE VERSION ITSELF HAS NEVER BEEN GIVEN ----------------
#
# 🔴 SEPARABLE HUNK -- this block closes a different, live instance of the same
# defect and can be dropped without affecting the sha binding above.
#
# post_walk_qa.sh has recorded version_source since 2026-08-24. Its own header
# comment tells a reader that anything other than measured(...) means the
# version is an assertion, and it prints "a reader must NOT treat this record's
# version as measured" to the terminal. Measured on this file before the change:
#
#     version_source in verify_walk_record.sh   0
#     CONTROL qa_exit, same file, same shape    7
#
# So the no-installer-on-the-box branch wrote asserted-unverifiable(...) into
# the record and the only automated reader could not tell it from a measured
# one. That is walks/v1.0.42.tsv -- real measurements filed against a version
# the box never ran -- with the writer's guard in place and the reader's absent.
# It is qa_exit's defect exactly, still live, in the field #931 was about to
# imitate; adding artefact_sha256_source next to an unread version_source would
# have established that *_source fields are advisory.
VERSION_SOURCE="$(field version_source)"
if [[ -z "$VERSION_SOURCE" ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} carries no version_source field." >&2
    echo "            Written since 2026-08-24. A record without it predates the format; whether" >&2
    echo "            the box was ever asked its version is unknown. CANNOT-RUN." >&2
    exit 2
fi
case "$VERSION_SOURCE" in
    measured\(*) : ;;
    *)
        cat >&2 <<MSG
[walk-gate] REFUSED: ${RECORD} says version_source ${VERSION_SOURCE}.

  The version in this record was not read off the box. Real probe results are
  filed here against a version nothing confirmed the box was running, which is
  precisely walks/v1.0.42.tsv. Not a failure of the walk -- an unattributable
  one. CANNOT-RUN.
MSG
        exit 2
        ;;
esac
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
