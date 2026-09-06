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

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
