#!/usr/bin/env bash
# A QUIET STEP IS NOT A WEDGED ONE, AND THE HARNESS MUST TELL THEM APART.
#
# WHY THIS EXISTS. MEASURED 2026-09-04, ARTEFACT WALK 6, the first walk ever to
# drive the SIGNED DMG payload. It was killed at step 11 of 40 by ttywalk.sh's
# own stall detector after 20 minutes of marker silence, and 50 minutes of walk
# were thrown away. The install was PERFECTLY HEALTHY. Measured at the moment
# the harness gave up:
#
#     docker compose up -d vane   -- alive, pid 80512
#     free disk 28Gi -> 26Gi over the same window
#
# vane_install is a 3.5 GB image pull, and install.sh ITSELF logs:
#
#     "There is no progress bar for it, so a long silence here is expected and
#      does not mean the install has stalled."
#
# So a fixed log-silence cap does not measure wedged-ness. It measures WHICH
# STEP IS RUNNING, and it would kill every artefact walk at the same place
# forever. The comment it replaced had the diagnosis exactly right -- "a wedged
# install and a slow one look identical from here and the difference matters"
# -- and then resolved the ambiguity by guessing.
#
# TWO INSTRUMENTS I REJECTED, BOTH MEASURED BEFORE SHIPPING:
#
#   unscoped CPU ..... colima's VM daemons burn ~1 CPU-second every 25s on an
#                      IDLE box, i.e. ~48s of noise per 20-minute window.
#                      Everything looks busy, so nothing is ever stalled.
#   descendant CPU ... a docker pull's work happens INSIDE the colima VM, which
#                      is not a descendant of walk_drive.py. Everything looks
#                      idle, so a healthy pull reads as wedged.
#
# Free disk plus a live long-running worker has neither failure: a pull
# consumes disk monotonically, and the worker is the thing doing it.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN is not a pass: an
# unreadable signal means the harness COULD NOT LOOK, which must never be
# spelled the same way as "it looked and saw nothing".
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Extract the decision function and drive it in isolation. It is pure by
# construction -- signal in, verdict out, no box required.
awk '/^_stall_verdict\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$SUBJECT" > "${WORK}/fn.sh"
[ -s "${WORK}/fn.sh" ] || {
    echo "CANNOT-RUN: _stall_verdict was not found in ${SUBJECT}." >&2
    echo "  It was extracted by name; a rename must fail loudly here rather" >&2
    echo "  than silently scanning nothing." >&2
    exit 2; }

_v() {
    { cat "${WORK}/fn.sh"; printf '_stall_verdict "%s" "%s"\n' "$1" "$2"; } > "${WORK}/r.sh"
    bash "${WORK}/r.sh" 2>/dev/null
}

echo "── the three states ──"

r="$(_v "27312488 1" "27400000")"
[ "$r" = "WORKING" ] \
    && ok "a live long-running worker means WORKING even with no disk movement" \
    || bad "a live worker gave '${r}'. This is the measured walk-6 case: docker compose was alive and the walk was killed."

r="$(_v "27312488 0" "27400000")"
[ "$r" = "WORKING" ] \
    && ok "no worker but disk moved 85MB is WORKING" \
    || bad "disk movement of 85MB gave '${r}'"

r="$(_v "27312488 0" "27320000")"
[ "$r" = "STALLED" ] \
    && ok "no worker AND disk moved only 7MB is STALLED -- the detector still fires" \
    || bad "a genuinely wedged box gave '${r}'. The fix has disabled the detector entirely, which is worse than the defect."

echo "── CANNOT-RUN is not a pass and is not a failure ──"

r="$(_v "" "27400000")"
[ "$r" = "CANNOT-RUN" ] \
    && ok "an EMPTY signal is CANNOT-RUN, never STALLED and never WORKING" \
    || bad "an unreadable signal gave '${r}'. Could-not-look must not be spelled the same way as looked-and-saw-nothing."

r="$(_v "garbage 0" "27400000")"
[ "$r" = "CANNOT-RUN" ] \
    && ok "a NON-NUMERIC signal is CANNOT-RUN, not silently coerced to 0" \
    || bad "a non-numeric free value gave '${r}'; a garbage reading must not become a number."

r="$(_v "27312488 0" "")"
[ "$r" = "WORKING" ] \
    && ok "the FIRST sample has no previous value to subtract, so it cannot claim STALLED" \
    || bad "the first sample gave '${r}'. With no baseline there is no delta, and inventing one from an empty string is how a zero denominator reads as a result."

echo "── the detector must still be reachable at all ──"
if grep -q 'STALL_TICKS' "$SUBJECT" && grep -q '_stall_verdict' "$SUBJECT"; then
    ok "the loop still counts silence AND consults the verdict function"
else
    bad "the silence counter or the verdict call is gone; the detector cannot fire."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
