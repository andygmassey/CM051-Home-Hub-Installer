#!/usr/bin/env bash
# A probe the walk's glob cannot see does not exist, however good it is.
#
# scripts/box_walk_probes/run_box_walk.sh collects its suite with
# "$PROBE_DIR"/*.sh. Its own comment records what that cost:
#
#   "THIS GLOB IS THE WHOLE SUITE. A probe file that is not in PROBE_DIR does
#    not exist as far as a box walk is concerned, however good it is, and
#    nothing anywhere prints the names of files it skipped.
#    people_seed_and_retrieval.sh spent its whole life one level up on exactly
#    that basis: 735 lines, graded exit codes, the only assertion in the estate
#    that semantic people search actually works, and eleven probes reported
#    over the top of it every time."
#
# The runner already refuses a suite of ZERO -- "an empty suite passes every
# assertion it does not make". What it cannot see is a suite of TWENTY-FOUR
# when a twenty-fifth exists one directory up. That is the defect above, and
# after it was found the only thing standing between it and a recurrence was
# that comment.
#
# TWO ARMS, because either alone is bypassable:
#   1. no probe-shaped file lives outside probes/
#   2. the probe count does not fall below a recorded floor
#
# Arm 2 matters because arm 1 passes trivially if someone DELETES probes: zero
# files outside the directory and zero inside it would both be "clean".
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${REPO}/scripts/box_walk_probes"
PROBE_DIR="${ROOT}/probes"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# MEASURED 2026-09-05: 25 probes in probes/, 0 probe-shaped files outside it.
# Was 24; converge_kill_is_recorded took it to 25. The floor RATCHETS UP with
# each addition on purpose -- left at 24 it would let the new probe be deleted
# again without anyone noticing, which is the failure this floor exists to stop.
# Lowering this is a reviewable edit in the same PR as whatever removed a probe.
MIN_PROBES=25

[ -d "$ROOT" ]      || cant "no box_walk_probes tree at ${ROOT}"
[ -d "$PROBE_DIR" ] || cant "no probes/ directory at ${PROBE_DIR}; the walk would refuse the suite and so must this gate"

# A probe is a shell file that names itself with PROBE_NAME=. That is the
# runner's own contract, not a guess about filenames.
_probe_shaped() {
    local dir="$1" f
    while IFS= read -r f; do
        grep -qE '^PROBE_NAME=' "$f" 2>/dev/null && printf '%s\n' "$f"
    done < <(/usr/bin/find "$dir" -name '*.sh' -type f 2>/dev/null | sort)
}

INSIDE="$(_probe_shaped "$PROBE_DIR")"
N_INSIDE="$(printf '%s\n' "$INSIDE" | grep -c . || true)"

# Everything under the tree that is NOT in probes/
OUTSIDE=""
while IFS= read -r f; do
    case "$f" in "${PROBE_DIR}/"*) continue ;; esac
    OUTSIDE="${OUTSIDE}${f}"$'\n'
done < <(_probe_shaped "$ROOT")
N_OUTSIDE="$(printf '%s' "$OUTSIDE" | grep -c . || true)"

echo "── controls ──"
# The finder must be able to SEE a probe outside probes/, or arm 1's zero is
# an empty predicate rather than a clean result.
CTL="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$CTL"' EXIT
mkdir -p "$CTL/probes"
printf '%s\n' '#!/usr/bin/env bash' 'PROBE_NAME="seeded_inside"'  > "$CTL/probes/inside.sh"
printf '%s\n' '#!/usr/bin/env bash' 'PROBE_NAME="seeded_outside"' > "$CTL/stray.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo not a probe'            > "$CTL/helper.sh"

CTL_ALL="$(_probe_shaped "$CTL" | grep -c . || true)"
CTL_STRAY="$(_probe_shaped "$CTL" | grep -cv "/probes/" || true)"
[ "${CTL_ALL:-0}" -eq 2 ] \
    && ok "CONTROL: the finder sees both seeded probes and ignores the non-probe helper" \
    || bad "CONTROL: expected 2 probe-shaped files in the fixture, found ${CTL_ALL}. The finder is broken, so arm 1 below is meaningless."
[ "${CTL_STRAY:-0}" -eq 1 ] \
    && ok "CONTROL: a probe placed OUTSIDE probes/ IS detected" \
    || bad "CONTROL: a seeded stray probe was NOT detected (${CTL_STRAY}). Arm 1 cannot fail."

echo "── subject ──"
printf '  %s probe(s) in probes/, %s probe-shaped file(s) outside it\n' "$N_INSIDE" "$N_OUTSIDE"

if [ "${N_OUTSIDE:-0}" -eq 0 ]; then
    ok "arm 1: no probe-shaped file lives outside the walk's glob"
else
    bad "arm 1: ${N_OUTSIDE} probe-shaped file(s) live OUTSIDE ${PROBE_DIR}:
$(printf '%s' "$OUTSIDE" | sed 's/^/          /')
        run_box_walk.sh globs \"\$PROBE_DIR\"/*.sh, so these never run and nothing
        prints their names. Move them into probes/ or stop them declaring PROBE_NAME."
fi

if [ "${N_INSIDE:-0}" -ge "$MIN_PROBES" ]; then
    ok "arm 2: ${N_INSIDE} probes, at or above the recorded floor of ${MIN_PROBES}"
else
    bad "arm 2: only ${N_INSIDE} probe(s) in ${PROBE_DIR}, below the floor of ${MIN_PROBES}.
        Arm 1 passes trivially on an empty suite, so the count is what stops
        'no probes outside' from meaning 'no probes at all'."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
