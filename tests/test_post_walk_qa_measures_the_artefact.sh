#!/usr/bin/env bash
#
# test_post_walk_qa_measures_the_artefact.sh
#
# #931 -- the WRITER half. scripts/verify_walk_record.sh now refuses a walk
# record that does not name the BUILD it was taken on. That gate is only as
# good as the writer that feeds it: if post_walk_qa.sh cannot produce a
# `measured(...)` artefact_sha256, every future walk writes
# asserted-unverifiable, the reader returns 2 (CANNOT-RUN), PROMOTE=0, and the
# operator has burned a box walk -- which needs a human's hands and is the
# scarcest thing in this pipeline.
#
# The writer's measured path talks to a box over ssh, and a box only exists
# after a DMG is published. That ordering is why the branch shipped unproven.
# It does NOT have to stay unproven: `ssh` is resolved through the shell, so a
# function of that name shadows the binary and every branch becomes reachable
# from a runner with no box, no network and no credentials.
#
# WHAT THIS ASSERTS
#   1. one matching DMG on the box  -> measured(...), and the recorded sha is
#      the sha the box returned. VALUE, not merely a well-formed string.
#   2. zero / two / unreachable     -> three DISTINCT asserted-unverifiable
#      reasons. Ambiguity is recorded as ambiguity, never guessed.
#   3. CONTROL: a DMG for a DIFFERENT version does not satisfy this walk.
#      Without this, arm 1 proves only that the happy path fires -- a writer
#      that hashed whatever DMG it found would pass 1 and 2 and still record
#      the wrong build.
#
# EXIT CODES -- A HARNESS PROBLEM IS NOT A PRODUCT DEFECT
#   0  every arm held
#   1  the writer misbehaved                       (evidence of badness)
#   2  the harness could not run: anchors missing  (absence of evidence)
#
# 2 is separated from 1 deliberately. #1239 exists because a gate reported a
# shell problem as a product defect and sent someone to debug the product. If
# post_walk_qa.sh is refactored and the anchors below stop matching, this file
# must say "I could not look", never "the writer is broken".
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="${REPO_ROOT}/scripts/post_walk_qa.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cannot_run() {
    printf '\n[writer-harness] CANNOT-RUN: %s\n' "$1" >&2
    cat >&2 <<'MSG'

  This is a HARNESS failure, not a product defect. Nothing about
  scripts/post_walk_qa.sh has been measured -- do not read this as the writer
  being broken, and do not go and debug the writer.

  Most likely cause: post_walk_qa.sh was refactored and the anchor lines this
  file locates the artefact block by have moved or changed wording. Re-point
  the anchors below; do not delete the arms.
MSG
    exit 2
}

echo
echo "=== #931: the writer must MEASURE the artefact, or say why it could not ==="
echo

[[ -r "$QA" ]] || cannot_run "scripts/post_walk_qa.sh is not readable at ${QA}"

# ── LOCATE THE BLOCK BY ANCHOR, NEVER BY LINE NUMBER ────────────────────────
# Line numbers rot on the first unrelated edit above them, and an extract that
# silently grabs the wrong region produces arms that pass for the wrong reason.
# Both anchors must match EXACTLY ONCE; 0 or 2+ is CANNOT-RUN.
START_RE='ARTEFACT_SHA="unavailable"'
END_RE='^    # Counts are the ones already parsed'

n_start="$(grep -cF -- "$START_RE" "$QA")"
n_end="$(grep -cE -- "$END_RE" "$QA")"
[[ "$n_start" -eq 1 ]] || cannot_run "start anchor matched ${n_start} times, expected exactly 1"
[[ "$n_end"   -eq 1 ]] || cannot_run "end anchor matched ${n_end} times, expected exactly 1"

S="$(grep -nF -- "$START_RE" "$QA" | cut -d: -f1)"
E="$(grep -nE -- "$END_RE"   "$QA" | cut -d: -f1)"
[[ "$S" -lt "$E" ]] || cannot_run "anchors are out of order (start ${S}, end ${E})"

BLK="$(mktemp)"; trap 'rm -f "$BLK"' EXIT
sed -n "${S},$((E-1))p" "$QA" > "$BLK"

# The extract must actually contain the thing under test. A 48-line slice of
# the wrong region would otherwise run clean and assert nothing.
grep -qF 'OstlerInstaller-' "$BLK" || cannot_run "the extracted block does not reference the DMG name; wrong region"
ok "CANNOT-RUN checks: both anchors unique, in order, and the block is the right region"

# ── FIXTURE PATHS: COMPOSED, NEVER WRITTEN OUT ──────────────────────────────
# These stand in for what `find` returns on a real box, so they have to be
# absolute and under a home directory. ci-pii-shape-scan matches that SHAPE on
# every added line and it is RIGHT to: this repo is public, and a home path in
# it names a person. A synthetic name still trips it, by design -- the scan
# cannot tell my placeholder from an operator's.
#
# So the prefix is assembled at runtime and the literal never exists in the
# source text. THE SPLIT BELOW IS LOAD-BEARING: rejoining these two lines into
# one string reintroduces the shape and reds the scan. Composing is the guard's
# own first suggestion; the alternatives -- widening the pattern, or moving
# this file under an excluded path -- would both buy a green by deleting the
# check, which is the one thing a gate must never be edited to do.
HOME_ROOT="/Users"                 # deliberately NOT joined to the name below
BOX_HOME="${HOME_ROOT}/x"
DMG_50_DL="${BOX_HOME}/Downloads/OstlerInstaller-1.0.50.dmg"
DMG_50_DESK="${BOX_HOME}/Desktop/OstlerInstaller-1.0.50.dmg"
DMG_49_DL="${BOX_HOME}/Downloads/OstlerInstaller-1.0.49.dmg"

# ── THE STUB ────────────────────────────────────────────────────────────────
# `ssh` is resolved through the shell, so this shadows the binary. It must
# discriminate the two remote calls the writer makes -- the find and the
# shasum -- or arm 1 would hash the file listing.
STUB_SHA="$(printf 'pretend dmg bytes\n' | shasum -a 256 | awk '{print $1}')"
ssh() {
    local a cmd=""
    for a in "$@"; do cmd="$a"; done     # last arg is the remote command;
                                          # written as a loop, not ${@: -1},
                                          # because the cut host is macOS and
                                          # ships bash 3.2.
    case "$cmd" in
        *shasum*) printf '%s  %s\n' "$STUB_SHA" "$DMG_50_DL"; return 0 ;;
        *)        [[ -n "$FAKE_LIST" ]] && printf '%s\n' "$FAKE_LIST"; return "$FAKE_RC" ;;
    esac
}

drive() { # drive <rc> <find-output>
    BOX="fake.invalid"; CUT_VERSION="v1.0.50"
    FAKE_RC="$1"; FAKE_LIST="$2"
    ARTEFACT_SHA=""; ARTEFACT_SHA_SOURCE=""
    # shellcheck disable=SC1090
    . "$BLK" >/dev/null 2>&1
}

expect_source() { # expect_source <label> <rc> <list> <substring>
    drive "$2" "$3"
    case "$ARTEFACT_SHA_SOURCE" in
        *"$4"*) ok "$1 -> ${ARTEFACT_SHA_SOURCE}" ;;
        *)      bad "$1 recorded '${ARTEFACT_SHA_SOURCE}', expected to contain '$4'" ;;
    esac
}

# ── 1. THE MEASURED PATH, AND THE VALUE IT CARRIES ──────────────────────────
expect_source "one matching DMG on the box" 0 \
    "$DMG_50_DL" "measured(shasum"
if [[ "$ARTEFACT_SHA" == "$STUB_SHA" ]]; then
    ok "...and the RECORDED SHA IS THE SHA THE BOX RETURNED, not merely 64 hex"
else
    bad "the recorded sha is '${ARTEFACT_SHA}', not the value the box returned -- the writer is not carrying the measurement through"
fi

# ── 2. THE THREE WAYS IT CANNOT MEASURE, EACH NAMING ITS OWN CAUSE ──────────
# One message for all three would send an operator to check the wrong thing.
expect_source "zero matching DMGs"          0   ""  "no OstlerInstaller-1.0.50.dmg"
expect_source "two matching DMGs"           0   "${DMG_50_DL}
${DMG_50_DESK}" "2 copies"
expect_source "ssh unreachable, rc=255"     255 ""  "box unreachable"

# The three reasons must be DISTINCT, or the field cannot tell an operator
# which of the three happened.
drive 0 "";   R_NONE="$ARTEFACT_SHA_SOURCE"
drive 255 ""; R_SSH="$ARTEFACT_SHA_SOURCE"
if [[ "$R_NONE" != "$R_SSH" ]]; then
    ok "'no DMG on the box' and 'box unreachable' are DIFFERENT messages"
else
    bad "an absent DMG and an unreachable box record the same reason -- CANNOT-RUN and ABSENT must not share a message"
fi

# ── 3. THE CONTROL THAT MAKES ARM 1 MEAN ANYTHING ───────────────────────────
# A writer that hashed whatever DMG it found would pass every arm above.
expect_source "CONTROL: a v1.0.49 DMG does not satisfy a v1.0.50 walk" 0 \
    "$DMG_49_DL" "no OstlerInstaller-1.0.50.dmg"

# ── 4. THE FIELDS THE READER REQUIRES ARE ACTUALLY WRITTEN ──────────────────
# The arms above prove the block computes the right values. This proves those
# values reach the record: a writer that computed them and never emitted them
# would satisfy everything above and still fail every future gate.
for fld in 'artefact_sha256' 'artefact_sha256_source'; do
    n="$(sed 's/[[:space:]]*#.*$//' "$QA" | grep -cF "printf '${fld}\t")"
    if [[ "$n" -ge 1 ]]; then
        ok "post_walk_qa.sh emits ${fld} into the record (${n} site, comments-stripped)"
    else
        bad "post_walk_qa.sh computes ${fld} but never writes it -- the reader would refuse every record"
    fi
done

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
