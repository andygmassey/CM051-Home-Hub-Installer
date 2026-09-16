#!/usr/bin/env bash
# NO SCRIPT THE CUT ITSELF RUNS MAY SIT ON THE PIPEFAIL SHORT-CIRCUIT BASELINE.
#
# ============================================================================
# WHAT THIS IS FOR
# ============================================================================
#
# tests/test_pipefail_shortcircuit_inversion.sh is a RATCHET. It stops the
# `producer | grep -q` class SPREADING. It has never asked anyone to defuse the
# instances already on the list, and a ratchet baseline is not a backlog: it is
# a list of live landmines.
#
# On 2026-09-07 one went off. scripts/orphan_gate_selftest.sh:122 asserted
# containment with `printf | grep -q` under `set -o pipefail`; the expiry
# ratchet's output crossed the 64KB pipe buffer; `grep -q` exited on the match
# and SIGPIPEd printf; pipefail handed the PIPELINE printf's status; the `!`
# inverted a successful match into a reported failure; the v1.0.75 cut died at
# step 8 having built nothing. That file was row 1 of the baseline at the time.
#
# CM051 #1815 is the generalisation: of the files on that baseline, SEVEN were
# invoked by .github/workflows/cut.yml itself. Six still were when this guard
# was written, and #1815's PR fixed and delisted all six.
#
# THIS FILE EXISTS SO THE INTERSECTION CANNOT REFILL. Emptying a set is not a
# gate on the set. Without this, the next author adds `if ... | grep -q` to
# scripts/provenance_gate.sh, the ratchet accepts it as a NEW row (the ratchet
# only forbids GROWTH of an existing row, and a brand new row is growth it does
# report -- but the reviewer's remedy is "add it to the baseline", which is
# exactly how all seven got there), and the cut carries a landmine again.
#
# ============================================================================
# WHAT IT ASSERTS, AND THE THREE OUTCOMES
# ============================================================================
#
#   rc 0  PASS        no path named by cut.yml appears on the baseline
#   rc 1  FAIL        at least one does, named, with its instance count
#   rc 2  CANNOT-RUN  cut.yml or the baseline is missing or unreadable, or a
#                     positive control did not fire, so nothing was measured
#
# CANNOT-RUN is not PASS. A guard whose corpus vanished has not proved anything,
# and reporting 0 there is how an absence check passes on a dead apparatus.
#
# ============================================================================
# THE CONTROLS, AND WHY THERE ARE THREE
# ============================================================================
#
# The assertion is an ABSENCE ("the intersection is empty"), so every way of
# arriving at an empty answer by accident has to be excluded first:
#
#   CONTROL 1  the path extractor really does find paths in the REAL cut.yml,
#              and finds a value it MUST find. If cut.yml is ever restructured
#              so the extractor reads nothing, this guard would report a clean
#              intersection forever. Non-zero required.
#   CONTROL 2  the baseline reader really does return rows from the REAL
#              baseline, and finds a value it MUST find. Non-zero required.
#   CONTROL 3  the INTERSECTION FUNCTION can return non-empty. Controls 1 and 2
#              can both pass while the comparison itself is broken -- that is
#              precisely what happened to the sibling ratchet, whose `comm`
#              compared './bin/x.sh' against 'bin/x.sh' and agreed only because
#              both sides happened to hold 70 rows. So a COPY of cut.yml in a
#              temp dir is seeded with a path that IS on the baseline, and the
#              function must report it.
#
# CONTROL 3'S SUBJECT IS A COPY, NEVER THE REAL cut.yml. A control that writes
# the thing it hunts into the file it hunts in is not a control, it is the
# defect with a comment above it.
#
# ============================================================================
# macOS /bin/bash 3.2.57 + BSD userland. No `grep -P`, no `sed \b`, no
# associative arrays. British English. " -- ", never an em-dash.
#
# This file obeys the rule it enforces: not one `producer | grep -q` in a
# condition anywhere below. `grep -c` must read to EOF to produce a count, so
# it cannot short-circuit, and unlike the herestring it is POSIX rather than a
# bashism.
# ============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

WF='.github/workflows/cut.yml'
BASELINE='tests/pipefail_shortcircuit_baseline.txt'

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
cannot() {
    printf '\n  CANNOT-RUN  %s\n' "$*"
    printf '\nVERDICT: CANNOT-RUN. Nothing was measured, so this is NOT a pass.\n'
    exit 2
}

printf '\n=== no cut-path script may be a pipefail landmine ===\n\n'

# ---------------------------------------------------------------------------
# THE TWO READERS
# ---------------------------------------------------------------------------

# Every repo-relative script path cut.yml NAMES. Deliberately textual: the job
# calls them through `run:` blocks, `bash x.sh`, `python3 y.py`, make targets
# and bare paths, and there is no structured field that lists them. A textual
# read over-collects rather than under-collects, which is the safe direction
# for a guard whose failure mode is a silently empty set.
cut_paths() {
    /usr/bin/grep -oE '(scripts|tests|bin|gui|vendor|release)/[A-Za-z0-9_./-]+\.(sh|py|yml)' \
        "$1" 2>/dev/null | sort -u
}

# The baseline's data rows are `path<TAB>count`. Comments and blanks are not
# rows. Emitting the PATH only, because that is what the intersection is on.
baseline_paths() {
    /usr/bin/grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | cut -f1 | sort -u
}

# The row for one path, count included, so a failure can name the size of what
# it found rather than only the file.
baseline_row_for() {
    /usr/bin/grep -vE '^[[:space:]]*(#|$)' "$BASELINE" 2>/dev/null \
        | awk -F'\t' -v p="$1" '$1 == p { print $0 }'
}

# THE FUNCTION UNDER TEST. Separated out so control 3 can drive it against a
# KNOWN answer. An untested comparison is the whole reason this file needs a
# third control.
intersection() {
    # $1 = workflow file, $2 = baseline file
    comm -12 <(baseline_paths "$2") <(cut_paths "$1")
}

# ---------------------------------------------------------------------------
# PRECONDITIONS. Absent corpus is CANNOT-RUN, never PASS.
# ---------------------------------------------------------------------------
[ -r "$WF" ]       || cannot "${WF} is missing or unreadable, so the cut's script list could not be built."
[ -r "$BASELINE" ] || cannot "${BASELINE} is missing or unreadable, so there is no landmine list to compare against."

CUT_N="$(cut_paths "$WF" | grep -c .)"
BASE_N="$(baseline_paths "$BASELINE" | grep -c .)"
printf '        EXAMINED: %s path(s) named by %s\n' "$CUT_N" "$WF"
printf '        EXAMINED: %s row(s) on %s\n\n' "$BASE_N" "$BASELINE"

# ---------------------------------------------------------------------------
# CONTROL 1 -- the extractor is not blind
# ---------------------------------------------------------------------------
if [ "$CUT_N" -eq 0 ]; then
    cannot "CONTROL 1: the path extractor read ZERO paths out of ${WF}. A uniform zero from a reader is a broken predicate, not a clean workflow, and every intersection below would be empty for the wrong reason."
fi
# A value it MUST find. stage_and_verify_dmg.sh is the script that mounts and
# verifies the DMG; if cut.yml ever stops naming it the cut has changed shape
# and this guard's scope needs re-deriving by a human, so a miss here is
# CANNOT-RUN rather than a quiet pass.
CTL1='scripts/stage_and_verify_dmg.sh'
if [ "$(cut_paths "$WF" | grep -cxF -- "$CTL1")" -gt 0 ]; then
    ok "CONTROL 1: the extractor finds ${CTL1} in ${WF} (${CUT_N} paths read)"
else
    cannot "CONTROL 1 DID NOT FIRE: the extractor did not find ${CTL1} in ${WF}, though ${CUT_N} other path(s) were read. Either the cut no longer runs it -- in which case this guard's scope must be re-derived by hand -- or the extractor is broken. Investigate the control; do NOT read the intersection below."
fi

# ---------------------------------------------------------------------------
# CONTROL 2 -- the baseline reader is not blind
# ---------------------------------------------------------------------------
if [ "$BASE_N" -eq 0 ]; then
    cannot "CONTROL 2: the baseline reader read ZERO rows out of ${BASELINE}. The file is not empty of comments, so a zero here means the row predicate is broken and the intersection is empty by construction."
fi
# install.sh is the largest row on the baseline and has been on it since the
# file existed. It is deliberately NOT a cut.yml path, so it can never make the
# intersection non-empty by being here.
CTL2='install.sh'
if [ "$(baseline_paths "$BASELINE" | grep -cxF -- "$CTL2")" -gt 0 ]; then
    ok "CONTROL 2: the baseline reader finds ${CTL2} on ${BASELINE} (${BASE_N} rows read)"
else
    cannot "CONTROL 2 DID NOT FIRE: ${CTL2} is not among the ${BASE_N} row(s) read from ${BASELINE}. Either the row format changed or the reader is broken. Investigate the control; do NOT read the intersection below."
fi

# ---------------------------------------------------------------------------
# CONTROL 3 -- the INTERSECTION can return non-empty
# ---------------------------------------------------------------------------
# Controls 1 and 2 prove both readers see. They do not prove the comparison
# between them works: the sibling ratchet's `comm` once compared './bin/x.sh'
# against 'bin/x.sh' and the two sets shared NOT ONE ROW while the verdict read
# clean. So the function is driven against a known answer.
#
# THE SEED GOES INTO A COPY. Writing a baselined path into the real cut.yml to
# test the guard would be the defect, not a proof of it.
CTL_DIR="$(mktemp -d)" || cannot "could not create a temp dir, so control 3 could not be built."
trap 'rm -rf "$CTL_DIR"' EXIT

SEED="$(baseline_paths "$BASELINE" | /usr/bin/grep -E '^(scripts|tests|bin)/' | head -1)"
if [ -z "$SEED" ]; then
    cannot "CONTROL 3: no baseline row under scripts/, tests/ or bin/ to seed with, so the intersection function is UNTESTED and its empty answer means nothing."
fi
cp "$WF" "$CTL_DIR/cut.yml" || cannot "could not copy ${WF} for control 3."
printf '          run: bash %s   # CONTROL 3 SEED, temp copy only\n' "$SEED" >> "$CTL_DIR/cut.yml"

CTL3="$(intersection "$CTL_DIR/cut.yml" "$BASELINE")"
if [ "$(printf '%s\n' "$CTL3" | grep -cxF -- "$SEED")" -gt 0 ]; then
    ok "CONTROL 3: the intersection function reports a seeded baselined path (${SEED}) when a COPY of cut.yml names it"
else
    cannot "CONTROL 3 DID NOT FIRE: a copy of cut.yml naming ${SEED} -- which IS on the baseline -- produced an intersection that does not contain it. The comparison is broken, so the empty verdict below is meaningless. Investigate the control."
fi

# The other half of control 3: the seeded copy is the ONLY reason it appeared.
# Without this, a function that returns every baseline row would also pass above.
if [ "$(intersection "$WF" "$BASELINE" | grep -cxF -- "$SEED")" -eq 0 ]; then
    ok "CONTROL 3b: the same path is NOT reported against the real ${WF}, so control 3 measured the seed and not a blanket match"
else
    bad "CONTROL 3b: ${SEED} is reported against the REAL ${WF} too. Either it is a genuine finding (see the verdict below) or the function matches indiscriminately."
fi

# ---------------------------------------------------------------------------
# THE ASSERTION
# ---------------------------------------------------------------------------
HITS="$(intersection "$WF" "$BASELINE")"
HITS_N="$(printf '%s\n' "$HITS" | grep -c . )"

printf '\n        INTERSECTION: %s file(s) named by the cut AND carrying a baselined landmine\n\n' "$HITS_N"

if [ "$HITS_N" -eq 0 ]; then
    ok "no script .github/workflows/cut.yml names is on the pipefail short-circuit baseline"
else
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        bad "${p} is invoked by the cut AND carries $(baseline_row_for "$p" | cut -f2) baselined pipefail short-circuit instance(s)"
    done <<< "$HITS"
    printf '\n'
    printf '  Each of these fires only when its own output crosses the 64KB pipe\n'
    printf '  buffer, so it is invisible until some unrelated change makes it\n'
    printf '  wordier. That is exactly how scripts/orphan_gate_selftest.sh:122\n'
    printf '  stayed green for weeks and then killed the v1.0.75 cut.\n\n'
    printf '  REMEDY, and it is the one the class gate proves portable:\n'
    printf '      [ "$(printf %%s "$x" | grep -c PAT)" -gt 0 ]\n'
    printf '  NOT the herestring `grep -q PAT <<< "$x"` -- that is a bashism and\n'
    printf '  dies on box_run()'"'"'s ssh branch, where the box chooses the shell.\n'
    printf '  Then DELIST the file from %s in the same change.\n\n' "$BASELINE"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    printf 'VERDICT: PASS\n'
    exit 0
fi
printf 'VERDICT: FAIL\n'
exit 1
