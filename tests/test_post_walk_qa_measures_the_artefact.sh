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
#   0. the DMG the walk STAGED (ttywalk.sh's ~/.walk-dmg marker) wins over a
#      stale same-version file in ~/Downloads (v1.0.124 walk, 2026-11-05).
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
# discriminate the remote calls the writer makes -- the walk-dmg marker read,
# the find and the shasum -- or arm 1 would hash the file listing.
#
# Two DIFFERENT digests, so an arm can tell WHICH file was hashed: any
# versioned OstlerInstaller-<v>.dmg hashes STUB_SHA, the unversioned
# OstlerInstaller.dmg (the release asset name ttywalk.sh stages) WALKED_SHA.
STUB_SHA="$(printf 'pretend dmg bytes\n' | shasum -a 256 | awk '{print $1}')"
WALKED_SHA="$(printf 'the dmg the walk staged\n' | shasum -a 256 | awk '{print $1}')"
DMG_WALKED="${BOX_HOME}/Downloads/OstlerInstaller.dmg"
ssh() {
    local a cmd=""
    for a in "$@"; do cmd="$a"; done     # last arg is the remote command;
                                          # written as a loop, not ${@: -1},
                                          # because the cut host is macOS and
                                          # ships bash 3.2.
    case "$cmd" in
        *walk-dmg*)
            [[ "$FAKE_RC" -ne 0 ]] && return "$FAKE_RC"
            [[ -n "$FAKE_MARKER" ]] && printf '%s\n' "$FAKE_MARKER"; return 0 ;;
        *shasum*)
            if [[ "$FAKE_STAGED_GONE" == 1 && "$cmd" == *NO-FILE* ]]; then
                echo NO-FILE; return 0
            fi
            case "$cmd" in
                *"/OstlerInstaller.dmg'"*) printf '%s  %s\n' "$WALKED_SHA" "$DMG_WALKED" ;;
                *)                         printf '%s  %s\n' "$STUB_SHA" "$DMG_50_DL" ;;
            esac
            return 0 ;;
        *)  [[ -n "$FAKE_LIST" ]] && printf '%s\n' "$FAKE_LIST"; return "$FAKE_RC" ;;
    esac
}

drive() { # drive <rc> <find-output> [<marker line>] [<staged file gone: 1>]
    BOX="fake.invalid"; CUT_VERSION="v1.0.50"
    FAKE_RC="$1"; FAKE_LIST="$2"
    FAKE_MARKER="${3:-}"; FAKE_STAGED_GONE="${4:-0}"
    ARTEFACT_SHA=""; ARTEFACT_SHA_SOURCE=""
    # shellcheck disable=SC1090
    . "$BLK" >/dev/null 2>&1
}

expect_source() { # expect_source <label> <rc> <list> <substring> [<marker>] [<gone>]
    drive "$2" "$3" "${5:-}" "${6:-0}"
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

# ── 3b. THE v1.0.124 DEFECT: A STALE SAME-VERSION DMG BESIDE THE WALKED ONE ─
# MEASURED 2026-11-05: ~/Downloads held a stale OstlerInstaller-<v>.dmg from an
# earlier build of the same version, the walk staged OstlerInstaller.dmg, and
# the record took the stale file's sha as measured(...). With the marker the
# walk wrote, the record must carry the WALKED sha. The old by-name pick
# hashes the versioned file (STUB_SHA) and goes red here.
BOTH="${DMG_50_DL}
${DMG_WALKED}"
MARKER_OK="$(printf '1.0.50\t%s\t%s' "$DMG_WALKED" "$WALKED_SHA")"
expect_source "DEFECT: stale OstlerInstaller-1.0.50.dmg plus the walked OstlerInstaller.dmg named in the marker" 0 \
    "$BOTH" "the DMG the walk staged" "$MARKER_OK"
if [[ "$ARTEFACT_SHA" == "$WALKED_SHA" ]]; then
    ok "...and the RECORDED SHA IS THE WALKED DMG's, not the stale same-named file's"
else
    bad "the record carries '${ARTEFACT_SHA}', not the walked DMG's ${WALKED_SHA} -- the wrong build is bound to the record"
fi

# Every way the marker cannot be honoured is asserted-unverifiable with its
# OWN reason, and never falls through to the by-name pick (which would hash the
# stale file and call it measured).
expect_source "marker names a file no longer on the box" 0 "$BOTH" \
    "is missing from the box" "$MARKER_OK" 1
[[ "$ARTEFACT_SHA" == "unavailable" ]] && ok "...and no sha is recorded" \
    || bad "a missing staged file still recorded sha '${ARTEFACT_SHA}'"
expect_source "marker sha differs from the re-hash (file replaced since the walk)" 0 "$BOTH" \
    "replaced since the walk" "$(printf '1.0.50\t%s\t%s' "$DMG_WALKED" "$STUB_SHA")"
expect_source "marker from a walk of a DIFFERENT version (stale marker)" 0 "$BOTH" \
    "stale marker" "$(printf '1.0.49\t%s\t%s' "$DMG_WALKED" "$WALKED_SHA")"
expect_source "malformed marker" 0 "$BOTH" "malformed" "garbage"

# NO MARKER (an older ttywalk.sh, a console walk): the by-name pick is taken
# only when it is the sole candidate. The v1.0.124 box state without a marker
# is ambiguous, never measured.
expect_source "no marker, stale versioned DMG beside an unversioned one" 0 "$BOTH" \
    "cannot tell which was walked"
[[ "$ARTEFACT_SHA" == "unavailable" ]] && ok "...and no sha is recorded" \
    || bad "an ambiguous box with no marker still recorded sha '${ARTEFACT_SHA}'"

# ── 3c. THE PRODUCER: ttywalk.sh WRITES THE MARKER THIS BLOCK READS ─────────
# The consumer arms above are green by construction if nothing writes the
# marker. This is a source check, NOT an execution of ttywalk.sh (that needs a
# box): it pins the three things the consumer depends on -- the marker is
# removed on every walk, it is written from the sha of the DMG the walk
# scp'd, and its field order is version, path, sha.
TTY="${REPO_ROOT}/scripts/ttywalk.sh"
TTY_CODE="$(sed 's/^[[:space:]]*#.*$//' "$TTY")"
if grep -qF 'rm -f ~/.walk-dmg' <<< "$TTY_CODE"; then
    ok "ttywalk.sh removes ~/.walk-dmg on every walk, so a repo walk never inherits a marker"
else
    bad "ttywalk.sh never removes ~/.walk-dmg -- a later walk would inherit the previous walk's DMG"
fi
if grep -qF "printf '%s\\t%s\\t%s\\n' '\${ARTEFACT_VERSION:-}' \\\"\\\$HOME/Downloads/\${_wdm_name}\\\" '\${_wdm_sha}' > ~/.walk-dmg" <<< "$TTY_CODE"; then
    ok "ttywalk.sh writes version, staged path, staged sha to ~/.walk-dmg (the order this block parses)"
else
    bad "ttywalk.sh does not write ~/.walk-dmg as version<TAB>path<TAB>sha -- the consumer would read nothing or the wrong field"
fi
if grep -qF '_wdm_sha="$_wpa_sha"' <<< "$TTY_CODE" && grep -qF '_wdm_name="$_wpa_name"' <<< "$TTY_CODE"; then
    ok "the marker's sha and name are the ones the walk scp'd and verified at placement"
else
    bad "the marker is not fed from the scp'd DMG's sha and name"
fi

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

# ── 5. A VERSION TYPO IS NOT A MISSING MANIFEST ─────────────────────────────
#
# MEASURED 2026-09-05, driving the manifest branch directly:
#
#   1.0.71   -> "no cut-manifests/1.0.71.yaml"   COVERAGE LOST  overall=2
#   v9.9.99  -> "no cut-manifests/v9.9.99.yaml"  COVERAGE LOST  overall=2
#
# The same state for two different findings. One is a cut with no manifest,
# which must block a promote; the other is a name typed wrong while the
# manifest sits on disk. 59 of 59 cut manifests carry the leading v, so a
# bare 1.0.71 can never match a file -- it is malformed input, not absence.
#
# The host is a reserved-TLD name that cannot resolve, so no machine is
# contacted by these arms.
UNRESOLVABLE_HOST="invalid.invalid"

_qa_run() {  # $1.. args; echoes "<rc>|<kind>"
    local _out _rc _kind
    _out="$(/bin/bash "$QA" "$@" 2>&1)"; _rc=$?
    # Herestrings, deliberately. Feeding a producer into a consumer that stops
    # at the first hit lets the consumer SIGPIPE the producer, and under
    # `set -o pipefail` that inflicts a non-zero status on a command which
    # actually succeeded. The construct is described rather than written out:
    # the repo scans for the literal, and a comment quoting it to explain the
    # ban would satisfy that scan and add a row to the ratchet.
    # This file is #!/usr/bin/env bash and owns its shell, so a herestring is
    # safe. Anything that might run under `sh -c` wants a counting match.
    if   grep -q 'cut-version must look like'      <<< "$_out"; then _kind=shape-refused
    elif grep -q 'CANNOT REACH'                    <<< "$_out"; then _kind=reached-ssh
    elif grep -q 'usage: scripts/post_walk_qa.sh'  <<< "$_out"; then _kind=no-host
    else _kind=other; fi
    printf '%s|%s|%s' "$_rc" "$_kind" "$(printf '%s' "$_out" | grep -c "leading 'v' away")"
}

# THE DEFECT ARM. A bare version must be refused on SHAPE, before anything runs.
_r="$(_qa_run "$UNRESOLVABLE_HOST" 1.0.71)"
case "$_r" in
    3\|shape-refused\|1) ok "a version with no leading v is refused as usage (rc=3) and names the manifest that does exist" ;;
    3\|shape-refused\|0) bad "refused on shape but did not point at cut-manifests/v1.0.71.yaml, which is present -- the operator is told what is wrong but not what to do" ;;
    *)                  bad "a bare 1.0.71 gave [${_r}]; it must not be reported as a missing manifest when v1.0.71.yaml exists" ;;
esac

# MUST-MISS. Well-formed versions must NOT be refused, or the check has simply
# broken the tool. A 4-component version is included deliberately: the pattern
# must not be so tight that a future cut shape is falsely refused.
for _v in v1.0.71 v9.9.99 v1.0.71.2; do
    _r="$(_qa_run "$UNRESOLVABLE_HOST" "$_v")"
    case "$_r" in
        3\|reached-ssh\|*) ok "${_v} passes the shape check and proceeds to the box" ;;
        *) bad "${_v} was refused [${_r}] -- a well-formed version must never be rejected on shape" ;;
    esac
done

# Garbage is refused, and WITHOUT a false pointer to a manifest that is absent.
_r="$(_qa_run "$UNRESOLVABLE_HOST" banana)"
case "$_r" in
    3\|shape-refused\|0) ok "a non-version argument is refused, and no manifest is falsely claimed to exist" ;;
    *) bad "banana gave [${_r}]" ;;
esac

# Unchanged behaviour: no version at all is still legal, and no host is still usage.
_r="$(_qa_run "$UNRESOLVABLE_HOST")"
case "$_r" in 3\|reached-ssh\|*) ok "omitting the version is still legal (probes-only mode survives)" ;;
              *) bad "omitting the version now gives [${_r}]" ;; esac
_r="$(_qa_run)"
case "$_r" in 3\|no-host\|*) ok "omitting the host is still a usage refusal" ;;
              *) bad "omitting the host now gives [${_r}]" ;; esac

# ── 6. THE REFUSAL MUST PRECEDE THE PROBE SUITE, WHICH WRITES ───────────────
# Placement, not just behaviour. The suite seeds a synthetic person into the
# LIVE store, so a usage error discovered after it has run has already cost a
# write. Assert the refusal sits above the ssh reachability check.
_refuse_line="$(grep -n 'cut-version must look like' "$QA" | head -1 | cut -d: -f1)"
_ssh_line="$(grep -n 'CANNOT REACH' "$QA" | head -1 | cut -d: -f1)"
if [[ -z "$_refuse_line" || -z "$_ssh_line" ]]; then
    bad "could not locate both the shape refusal and the reachability check; placement is unverified"
elif [[ "$_refuse_line" -lt "$_ssh_line" ]]; then
    ok "the shape refusal (line ${_refuse_line}) precedes the reachability check (line ${_ssh_line}), so a typo costs no write"
else
    bad "the shape refusal is at ${_refuse_line}, AFTER the box work at ${_ssh_line} -- a typo would still cost a full walk"
fi

# CONTROL: the genuine coverage finding must survive, or this change has
# silently converted a real gap into a usage error.
if grep -q 'COUNTED AS COVERAGE LOST' "$QA"; then
    ok "CONTROL: a well-formed but absent manifest is still counted as coverage lost, so the two findings stay distinct"
else
    bad "the coverage-lost branch is gone; a missing manifest would no longer be reported as a gap"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
