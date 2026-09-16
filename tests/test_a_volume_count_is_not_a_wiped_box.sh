#!/usr/bin/env bash
# The walk wipe must measure the FILESYSTEM, not only Docker volumes.
#
# WHY THIS EXISTS. MEASURED 2026-09-06 on the walk box. `ttywalk.sh --wipe-stores`
# ran the shipped uninstaller, counted `docker volume ls | grep -c ^ostler_`,
# found zero and printed "WIPE CONFIRMED". At that moment the box held 42M under
# ~/Documents/Ostler across Captures, Conversations, Daily-Briefs, Exports,
# Transcripts and Wiki, and 29 of those files predated the install that was then
# live. The claim was about VOLUMES and it was being read as a claim about the
# BOX.
#
# IT IS NOT A DEFECT IN THE UNINSTALLER. Without --remove-content it asks
# whether to keep the content root; on a non-tty `read` fails and it keeps, which
# is its documented safe default and is correct for a customer. It is wrong for a
# walk, whose whole purpose is a cold box.
#
# WHY IT MATTERS: 4 of the 26 box-walk probes read under that root, two of them
# opening the compiled wiki index. One treats a MISSING index as CANNOT-RUN,
# which is the right third state, and a surviving index disarms exactly that arm.
# Fail-open, which is the direction that ships.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Extract the residue arm: from the content-root binding to the close of the
# refusal branch. Extraction by CONTENT, so a moved block still tests.
ARM="${WORK}/arm.sh"
awk '
    /_CONTENT_ROOT="\$HOME\/Documents\/Ostler"/ { f = 1 }
    f { print; if ($0 ~ /CANNOT-RUN, not a wipe/) { g = 1 } }
    g && /^[[:space:]]*fi[[:space:]]*$/ { exit }
' "$SUBJECT" > "$ARM"

if ! /usr/bin/grep -q '_CONTENT_ROOT=' "$ARM"; then
    echo "CANNOT-RUN: the residue arm was not found in ${SUBJECT}." >&2
    echo "  Scanning nothing must not read as a passing test." >&2
    exit 2
fi
if ! bash -n "$ARM" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted arm does not parse; the extraction is wrong." >&2
    exit 2
fi

# Run the arm against a synthetic HOME. Echoes "<exit>|<output>".
# The arm reads two control flags that ttywalk captures BEFORE the uninstaller
# runs. The test computes them the same way, from the fixture, so the harness
# mirrors the box rather than inventing a state the box cannot be in.
_run() {
    local h="$1" out rc w="${WORK}/run.sh"
    local co=0 cc=0
    [ -d "${h}/.ostler" ] && co=1
    [ -d "${h}/Documents/Ostler" ] && cc=1
    [ $# -ge 2 ] && co="$2"
    [ $# -ge 3 ] && cc="$3"
    { printf '_CTL_OSTLER_BEFORE=%s\n_CTL_CONTENT_BEFORE=%s\n' "$co" "$cc"
      cat "$ARM"; } > "$w"
    out="$(HOME="$h" bash "$w" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

_mkhome() {
    local h="${WORK}/$1"; rm -rf "$h"; mkdir -p "${h}/Documents"; printf '%s' "$h"
}

echo "── a wiped box, with the control satisfied, passes ──"
H="$(_mkhome cold)"
R="$(_run "$H" 1 1)"
case "$R" in
    0\|*) ok "nothing left under either root, and both roots existed before, exits 0" ;;
    *)    bad "a genuinely wiped box exits ${R%%|*}: ${R#*|}" ;;
esac

echo "── THE POSITIVE CONTROL: a zero from the wrong place is not a clean box ──"
# The gate on #1592 asks for a control path the probe must find on a never-wiped
# box. Without it, residue=0 has two causes that print identically: nothing
# survived, or the probe is looking where nothing ever was.
H="$(_mkhome nocontrol)"
R="$(_run "$H" 0 0)"
case "$R" in
    2\|*CANNOT-CONFIRM-WIPE*) ok "neither root existed before the wipe, so the zero is refused as unmeasurable" ;;
    2\|*) bad "exited 2 without naming the missing control: ${R#*|}" ;;
    *)    bad "a box the probe cannot see exits ${R%%|*} and reads as clean" ;;
esac

echo "── the DECLARED keep is allowed ──"
H="$(_mkhome keep)"; mkdir -p "${H}/.ostler"; : > "${H}/.ostler/power.conf"
R="$(_run "$H")"
case "$R" in
    0\|*) ok "power.conf alone under ~/.ostler is the uninstaller's own declared keep and passes" ;;
    *)    bad "the declared keep was treated as residue (exit ${R%%|*}): ${R#*|}" ;;
esac

echo "── an UNDECLARED survivor is refused ──"
H="$(_mkhome dirty)"; mkdir -p "${H}/.ostler/config"; : > "${H}/.ostler/config/.env"
R="$(_run "$H")"
case "$R" in
    2\|*WIPE\ INCOMPLETE\ ON\ DISK*) ok "an undeclared entry under ~/.ostler exits 2 and says WIPE INCOMPLETE" ;;
    2\|*)                            bad "exited 2 but without naming the residue: ${R#*|}" ;;
    *)                               bad "an undeclared survivor exits ${R%%|*}, so the next walk would grade it" ;;
esac

echo "── THE MEASURED DEFECT: the content root must actually be removed ──"
H="$(_mkhome content)"
mkdir -p "${H}/Documents/Ostler/Wiki" "${H}/Documents/Ostler/Transcripts"
: > "${H}/Documents/Ostler/Wiki/index.md"
: > "${H}/Documents/Ostler/Transcripts/carried-over.md"
R="$(_run "$H")"
if [ -e "${H}/Documents/Ostler" ]; then
    bad "the content root SURVIVED the wipe; this is the defect measured on the box"
elif [ "${R%%|*}" != "0" ]; then
    bad "the content root went but the arm exited ${R%%|*}: ${R#*|}"
else
    ok "the content root and its carried-over wiki index are removed, and the arm exits 0"
fi

echo "── SAFETY: an unexpected HOME refuses, it does not guess ──"
# A POSITIVE CONTROL ON THE GUARD, and the first version of this limb was not
# one. It pointed HOME at a path where the content root did not exist, so
# nothing was deleted whether the guard fired or not; a mutant that deleted the
# guard outright survived it. An empty HOME is the case the guard is actually
# for: it makes the root "/Documents/Ostler", which is not this account and
# must never be touched. The observable is the REFUSAL, not the survival of a
# file that was never at risk.
R="$(_run "")"
case "$R" in
    2\|*REFUSING\ to\ remove\ an\ unexpected\ content\ root*)
        ok "an empty HOME makes the root /Documents/Ostler and the arm refuses, exit 2" ;;
    2\|*) bad "exited 2 without naming the refusal: ${R#*|}" ;;
    *)     bad "an empty HOME exits ${R%%|*} and would have run rm -rf on /Documents/Ostler" ;;
esac

echo "── SEVEN HOME shapes, because one refusal is not a guard ──"
# TNM drove the guard across seven HOME values on the merged version and found
# HOME=/ yields //Documents/Ostler, which the original pattern ACCEPTED. Their
# reading: pathological, not dangerous, mine to take or leave. Taken. Nothing
# lives at /Documents on a Mac, but a guard that accepts a root nobody owns is
# one symlink from being interesting, and the fix was one character.
#
# Each case says which side of the line it is on, so a future widening of the
# pattern has to break a NAMED expectation rather than a single example.
while IFS='|' read -r _h _want _why; do
    [ -n "$_h$_want" ] || continue
    _r="$(_run "$_h" 1 1)"
    _got="${_r%%|*}"
    if [ "$_want" = "refuse" ]; then
        if [ "$_got" = "2" ]; then ok "HOME='${_h}' is refused (${_why})"
        else bad "HOME='${_h}' exited ${_got}, expected a refusal (${_why})"; fi
    else
        if [ "$_got" = "0" ]; then ok "HOME='${_h}' is accepted (${_why})"
        else bad "HOME='${_h}' exited ${_got}, expected acceptance (${_why})"; fi
    fi
done <<'CASES'
|refuse|empty HOME, root becomes /Documents/Ostler
/|refuse|HOME=/ gives //Documents/Ostler, TNM's finding
relative/path|refuse|not absolute
/Users|accept|a valid SHAPE even though nobody lives there; the guard checks the shape of the root, not whether HOME is a real home, and pretending otherwise would be a check it does not perform
CASES
# ...and the ACCEPT side, which must use a real directory or the arm proves
# only that a missing tree exits 0 for the wrong reason.
_H="$(_mkhome sevenok)"; mkdir -p "${_H}/Documents/Ostler"; : > "${_H}/Documents/Ostler/x"
_r="$(_run "$_H" 1 1)"
case "$_r" in
    0\|*) ok "a normal absolute HOME is accepted and its content root removed" ;;
    *)    bad "a normal HOME exited ${_r%%|*}; the guard is now too strict" ;;
esac

echo "── the CLAIM cannot be printed without the filesystem counts ──"
# The regression this test exists to prevent is the CLAIM, not the deletion:
# "WIPE CONFIRMED" must not be reachable from a Docker count alone.
# Anchor on the EMITTING statement, not on any occurrence. A comment that
# quotes the string satisfies a loose grep, and this file carries such a
# comment 60 lines above the echo -- the same trap it documents at the
# uninstaller call site. Found by this limb failing against correct code.
_claim="$(/usr/bin/grep -n 'echo "WIPE CONFIRMED' "$SUBJECT" | head -1 | cut -d: -f1)"
if [ -z "$_claim" ]; then
    bad "no WIPE CONFIRMED line found; this test can no longer see its subject"
elif sed -n "$((_claim)),$((_claim+1))p" "$SUBJECT" | /usr/bin/grep -q 'undeclared entries under ~/.ostler'; then
    ok "the WIPE CONFIRMED claim states the filesystem counts it is standing on"
else
    bad "WIPE CONFIRMED is printed without naming what was measured on disk"
fi

echo "-- THE EMPTY SKELETON THE SHIPPED UNINSTALLER LEAVES BEHIND --"
# MEASURED 2026-09-09T17:16:52Z on the v1.0.82 walk box, where this ABORTED THE
# WALK. install.sh:22341 creates ~/.ostler/data/knowledge-staging on every
# install, unconditionally. The shipped uninstaller preserves it by design
# (install.sh:21724-21741). The check then counted it as residue and refused,
# saying "The next walk would be grading carried-over content" about a tree that
# held zero files and zero bytes, on a box whose docker volume list was empty.
# So the wipe had worked and the check said it had not.
H="$(_mkhome skeleton)"
mkdir -p "${H}/.ostler/data/knowledge-staging"
: > "${H}/.ostler/power.conf"
R="$(_run "$H")"
# Exit 0 and NO refusal text. The extracted arm stops at the refusal branch, so
# it cannot print the WIPE CONFIRMED line that lives below the cut; asserting on
# that text here would be an assertion that can never pass. The source-side
# check that CONFIRMED names its counts is the last arm in this file.
case "$R" in
    0\|*WIPE\ INCOMPLETE*) bad "exit 0 but the refusal text was printed anyway: ${R#*|}" ;;
    0\|*)                  ok "an EMPTY data/knowledge-staging beside power.conf is not residue: exit 0, no refusal" ;;
    *)                     bad "the empty skeleton still aborts the walk (exit ${R%%|*}): ${R#*|}" ;;
esac

echo "-- MUST-FAIL: one file anywhere under it is still residue --"
# The arm above alone cannot tell a working check from an absent one. This is
# the other side, and it is deliberately DEEP: the old check looked only at
# maxdepth 1, so a file three levels down was invisible to it. The new one must
# see it.
H="$(_mkhome skeleton_dirty)"
mkdir -p "${H}/.ostler/data/knowledge-staging"
: > "${H}/.ostler/power.conf"
: > "${H}/.ostler/data/knowledge-staging/carried-over.md"
R="$(_run "$H")"
case "$R" in
    2\|*WIPE\ INCOMPLETE\ ON\ DISK*) ok "ONE file inside the skeleton is still residue: exit 2, WIPE INCOMPLETE" ;;
    2\|*)                             bad "exited 2 without naming it: ${R#*|}" ;;
    *)                                bad "a carried-over file exits ${R%%|*} and the next walk would grade it" ;;
esac

echo "-- and the refusal NAMES the file, or it is not actionable --"
case "$R" in
    *carried-over.md*) ok "the refusal names the surviving file, so a reader can act on it" ;;
    *)                 bad "the refusal did not name what it found: ${R#*|}" ;;
esac

echo "-- A DEEP power.conf IS NOT THE DECLARED KEEP --"
# The keep is excluded by its EXACT PATH, not by name. A file called power.conf
# buried deeper is residue like any other, and excluding it by name would have
# opened exactly that hole when the maxdepth went away.
H="$(_mkhome deep_powerconf)"
mkdir -p "${H}/.ostler/data"
: > "${H}/.ostler/data/power.conf"
R="$(_run "$H")"
case "$R" in
    2\|*WIPE\ INCOMPLETE\ ON\ DISK*) ok "a power.conf BELOW the top level is residue, not the declared keep" ;;
    *)                                bad "a deep power.conf was treated as the declared keep (exit ${R%%|*}): ${R#*|}" ;;
esac

echo "-- MUTATION: with the old entry-counting predicate, the skeleton arm MUST fail --"
# A test that passes against both the fix and the defect is not a test. This
# rebuilds the arm with the ORIGINAL predicate and requires the empty skeleton
# to abort, which is the behaviour that stopped the v1.0.82 walk.
MUT="${WORK}/arm_mutant.sh"
sed 's|-mindepth 1 -type f ! -path "\$HOME/\.ostler/power\.conf"|-mindepth 1 -maxdepth 1 ! -name power.conf|g' "$ARM" > "$MUT"
if [ "$(/usr/bin/grep -c -- '-maxdepth 1 ! -name power.conf' "$MUT")" -lt 1 ]; then
    bad "MUTATION DID NOT APPLY, so the arm below proves nothing"
else
    ok "the mutant really carries the old entry-counting predicate (the injection landed)"
    H="$(_mkhome skeleton_mut)"
    mkdir -p "${H}/.ostler/data/knowledge-staging"
    : > "${H}/.ostler/power.conf"
    _w="${WORK}/run_mut.sh"
    { printf '_CTL_OSTLER_BEFORE=1\n_CTL_CONTENT_BEFORE=1\n'; cat "$MUT"; } > "$_w"
    _out="$(HOME="$H" bash "$_w" 2>&1)"; _rc=$?
    if [ "$_rc" -eq 2 ]; then
        ok "MUST-FAIL: the old predicate aborts on the empty skeleton, so the fix is load-bearing"
    else
        bad "the old predicate ALSO passed the empty skeleton (exit ${_rc}); this test would not have caught the defect"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
