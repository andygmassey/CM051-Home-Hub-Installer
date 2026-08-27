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

# --- the probe NAMES were being written and never read -----------------------
#
# Exactly the qa_exit defect above, one field family later, and I shipped it.
# #1106 (01a7b06c) taught post_walk_qa.sh to record WHICH probes failed, not
# only how many, and wired a unit test for it. Measured 2026-08-27 on
# origin/main efab6a59, this script read whole (199 lines):
#
#     failed_probe_names_recorded  0   failed_probe        0
#     not_measured_probe           0   broken_probe        0
#     CONTROL, same read: verdict 10        <- the read works, the zeros are real
#
# So the WRITER emits four name families and this script -- the one that gates
# the customer download -- consulted none of them. The unit test guards
# post_walk_qa.sh's SOURCE TEXT. Nothing guarded the RECORD. That is the
# difference between merged and delivered, and this file is where delivered is
# decided.
#
# WHAT ROT LOOKS LIKE, which is why this is not tidiness. section_names() parses
# run_box_walk.sh's console sections by header text and indent. Reword a header
# or change an indent and it returns NOTHING: the record goes back to counts
# with no names, and it does so SILENTLY, looking exactly like a walk with
# nothing to report. #1106 anticipated that and wrote the reconciliation line
# `failed_probe_names_recorded  <n> of <m>` so the mismatch is visible in the
# file. Visible is not enforced. This block enforces it.
#
# THE COUNTS ARE A LEGITIMATE DENOMINATOR, and that was measured rather than
# assumed. run_box_walk.sh:216-229 emits each section with an unconditional
# `for b in $X_LIST; do printf '  %s\n' "$b"; done` -- the full list, no cap, no
# truncation -- so every probe in each class is named. The header is printed
# only when its list is non-empty, so fail=0 correctly yields no section, no
# rows, and `0 of 0`. Same log, same population as pass/fail/cannot_run/broken
# (counts_scope: phase 1 only, for both).
#
# ABSENT IS CANNOT-RUN (2), NOT FAIL, for the same reason qa_exit's is: a record
# written BEFORE its writer cannot carry the field. walks/v1.0.47.tsv is exactly
# that -- walked 2026-08-26T14:17:14Z, ~15h before #1106 landed at
# 2026-08-27T05:14:56Z. Retro-failing it would be punishing a record for the
# date it was taken. Absence of evidence, kept apart from evidence of badness by
# this script's exit codes.
count_rows() {
    # awk, not `grep -c ... | ...`: reads to EOF, so no early-exit SIGPIPE can
    # turn a FOUND into an error under the pipefail this file sets. Same reason
    # field() above is written the way it is.
    awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }' "$RECORD"
}

# 🔴 THE ABSENT BRANCH IS NARROWED ON PURPOSE, AND I GOT THIS WRONG FIRST.
# The first draft exited 2 whenever the field was missing. Running the test
# against the LIVE records showed what that actually does: walks/v1.0.44.tsv and
# walks/v1.0.47.tsv both predate #1106, both carry verdict FAILED, and both went
# from exiting 1 ("the walk FAILED, real defects were measured") to exiting 2
# ("CANNOT-RUN"). That is not a stricter gate, it is a LOSS OF SIGNAL: a
# specific, true, actionable refusal replaced by a generic one. And on a CLEAN
# pre-#1106 record it would newly block a customer download over a field that
# could not have existed when the walk was taken.
#
# So absence only decides anything where it can change an outcome: a record
# claiming CLEAN. If the verdict already refuses, the names cannot rescue or
# worsen it, and the existing exit code is the better answer. Same reasoning the
# verdict-vs-counts arm at the top of this file uses -- it too only bites a
# CLEAN claim.
NAMES_RECONCILED="$(field failed_probe_names_recorded)"
if [[ -z "$NAMES_RECONCILED" ]]; then
    if [[ "$VERDICT" == "CLEAN" ]]; then
        echo "[walk-gate] REFUSED: ${RECORD} claims CLEAN and carries no failed_probe_names_recorded field." >&2
        echo "            post_walk_qa.sh has written it unconditionally since #1106" >&2
        echo "            (01a7b06c, 2026-08-27T05:14:56Z). A record without it predates" >&2
        echo "            that writer or was hand-made, so nothing in it can be checked" >&2
        echo "            against WHICH probes it says ran. CANNOT-RUN, not a failure." >&2
        exit 2
    fi
    echo "[walk-gate] note: ${RECORD} predates #1106 and carries no probe names." >&2
    echo "            Not decided here -- the verdict '${VERDICT}' already governs this record." >&2
elif ! [[ "$NAMES_RECONCILED" =~ ^([0-9]+)\ of\ ([0-9]+)$ ]]; then
    echo "[walk-gate] REFUSED: ${RECORD} field 'failed_probe_names_recorded' is" >&2
    echo "            '${NAMES_RECONCILED}', not the '<n> of <m>' shape post_walk_qa.sh writes." >&2
    exit 2
fi
# EVERYTHING BELOW IS GUARDED ON THE FIELD BEING PRESENT, for the same reason.
# A pre-#1106 record has no name rows AT ALL, so an unguarded row-count check
# would refuse every one of them -- re-introducing exactly the regression the
# branch above was narrowed to avoid, one check further down. The guard is the
# fix, not a synthetic default: manufacturing a consistent-looking value to feed
# the checks would be fabricating the input rather than measuring it.
if [[ -n "$NAMES_RECONCILED" ]]; then
    NAMED="${BASH_REMATCH[1]}"
    NAMED_OF="${BASH_REMATCH[2]}"

    # The denominator and the `fail` field are BOTH derived from n_fail in
    # post_walk_qa.sh. If they disagree, the record was edited by hand or the
    # two derivations have diverged -- and a record nobody can trust to describe
    # itself cannot vouch for a build. This is the limb with teeth on a CLEAN
    # claim: fail=0 with a '4 of 4' line is a doctored record.
    if [[ "$NAMED_OF" -ne "$N_FAIL" ]]; then
        echo "[walk-gate] REFUSED: ${RECORD} says failed_probe_names_recorded '${NAMES_RECONCILED}'" >&2
        echo "            but the fail count is ${N_FAIL}. One record, two numbers for one fact." >&2
        exit 1
    fi

    # THE ROT DETECTOR. n < m means section_names() stopped matching: the walk
    # found m failures and the record can name n of them. On a FAILED verdict
    # this does not change the outcome and is not meant to -- it changes what
    # SURVIVES the walk, which is #1106's entire point: "a finding with no name
    # is not actionable, including by its own author a week later."
    if [[ "$NAMED" -ne "$NAMED_OF" ]]; then
        echo "[walk-gate] REFUSED: ${RECORD} names ${NAMED} of ${NAMED_OF} failing probes." >&2
        echo "            section_names() in post_walk_qa.sh has stopped matching" >&2
        echo "            run_box_walk.sh's output -- a reworded header or a changed indent." >&2
        echo "            A finding with no name is not actionable, including by its own" >&2
        echo "            author a week later. Fix the parser, re-run the walk." >&2
        exit 1
    fi

    # The reconciliation line and the rows underneath it must also agree: the
    # line could be right while the rows were lost, which is the same blindness
    # wearing a correct-looking summary. This also catches the inverse -- rows
    # present for a class whose count field says zero, i.e. a hand-edited
    # record claiming a cleaner walk than it recorded.
    for pair in "failed_probe:${N_FAIL}" "not_measured_probe:${N_CANNOT}" "broken_probe:${N_BROKEN}"; do
        key="${pair%%:*}"
        want="${pair##*:}"
        got="$(count_rows "$key")"
        if [[ "$got" -ne "$want" ]]; then
            echo "[walk-gate] REFUSED: ${RECORD} carries ${got} '${key}' row(s) but its own" >&2
            echo "            count field says ${want}." >&2
            echo "            run_box_walk.sh names every probe in each class (it loops the" >&2
            echo "            whole list, uncapped), so these cannot legitimately differ." >&2
            exit 1
        fi
    done
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
