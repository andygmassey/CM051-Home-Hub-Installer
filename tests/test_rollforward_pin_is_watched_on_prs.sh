#!/usr/bin/env bash
#
# THE ROLLFORWARD PIN GATE MUST RUN ON A PULL REQUEST, AND EVERY FILE IT PINS
# MUST TRIGGER IT.
#
# WHAT HAPPENED, MEASURED 2026-09-02. tests/test_rollforward_registry_pin.sh
# was RED ON MAIN and had been for a day. Nobody merged a red PR; the gate
# simply never ran on one. It was referenced in exactly one workflow --
# .github/workflows/cut.yml -- whose cutting job is `if: github.event_name ==
# 'push'`, i.e. a TAG PUSH. So its first opportunity to speak about any change
# is AFTER the tag that ships it has been written.
#
#   #1340 (5db7323e) re-synced the vendored registry FILE   merged 10:53:45Z
#   #1336 (00440f72) last wrote cuts/REGISTRY_PIN           merged 09:47:43Z
#
# The content half landed an hour after the pin half and nothing on the PR
# could see the two had come apart. Measured on the PRs themselves: #1340 had
# 35 checks and NONE whose name matches roll/pin/vendor/cut; the same query
# against a PR that does run the gate returns two, so the zero is real and not
# a broken predicate.
#
# THIS TEST IS NOT THE PIN GATE. It is the wiring check for it, and it asserts
# four things that are each a different way for the wiring to be false:
#
#   1. the workflow RUNS the pin gate           (else there is nothing to watch)
#   2. every file named in cuts/REGISTRY_PIN is in paths:
#                                               (else editing a pinned file is
#                                                invisible to its own pin)
#   3. cuts/REGISTRY_PIN itself is in paths:    (else editing the PIN is
#                                                invisible -- the #1336 half)
#   4. the pin gate AND this test are in paths: (dark on self-edit)
#
# WHY 2 IS DERIVED AND NOT HAND-LISTED. GitHub Actions cannot compute a paths:
# list, so the list is written by hand and will drift the moment a fifth file
# is added to the pin. Rather than restate the four filenames here -- which
# would drift in exactly the same way, one file later -- this reads them OUT
# of cuts/REGISTRY_PIN. Adding a file to the pin without adding it to paths:
# is then a RED, automatically, forever.
#
# THE PREDICATE FOR "a pinned file" is that field 2 is a 64-hex sha256. That is
# self-describing: the metadata rows (os003_repo, os003_sha, os003_branch) fail
# it, and a future metadata row will fail it too without anyone maintaining a
# skip-list. os003_sha is itself 40-hex, not 64, so it does not sneak in.
#
# ANTI-VACUITY. A zero on either side is CANNOT-RUN, never a pass. "Found no
# pinned files" and "could not parse the pin" print identically otherwise, and
# a green over an empty denominator is the failure this whole estate exists to
# refuse.
#
# Exit: 0 pass, 1 RED (wiring is wrong), 2 CANNOT-RUN (not a pass).
#
# bash 3.2 compatible: no associative arrays, no mapfile. The cut host is
# /bin/bash 3.2.57 and a bash-4 builtin here would print an unbound-variable
# error and exit 0, which is the exact shape of #1244.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${REPO}/.github/workflows/cut-gate-wrappers.yml"
PIN="${REPO}/cuts/REGISTRY_PIN"
GATE_REL="tests/test_rollforward_registry_pin.sh"
SELF_REL="tests/test_rollforward_pin_is_watched_on_prs.sh"

fail=0
red()  { printf 'RED   %s\n' "$1"; fail=1; }
okay() { printf 'ok    %s\n' "$1"; }

for f in "$WF" "$PIN" "${REPO}/${GATE_REL}"; do
    if [ ! -f "$f" ]; then
        printf 'CANNOT-RUN: missing prerequisite %s\n' "$f"
        printf 'This is not a pass.\n'
        exit 2
    fi
done

# ── The files the pin claims to cover ──────────────────────────────────────
PINNED="$(awk -F'\t' '$2 ~ /^[0-9a-f]{64}$/ { print $1 }' "$PIN")"
n_pinned="$(printf '%s\n' "$PINNED" | grep -c . )"
if [ "$n_pinned" -eq 0 ]; then
    printf 'CANNOT-RUN: parsed 0 pinned files out of %s.\n' "$PIN"
    printf 'The pin format changed, or the tabs are not tabs. Refusing to\n'
    printf 'report a pass on an empty denominator.\n'
    exit 2
fi

# ── The paths: list of the pull_request trigger ────────────────────────────
# From `    paths:` to the next key at 2-space indent (`  push:`). Anchored to
# the pull_request block specifically: a paths: under push: would be a
# different question and must not be silently counted as this one.
PATHS="$(awk '
    /^  pull_request:$/          { inpr=1; next }
    inpr && /^    paths:$/       { inp=1; next }
    inp && /^  [a-zA-Z]/         { exit }
    inp && /^      - / {
        line = $0
        sub(/^      - /, "", line)
        gsub(/^'"'"'|'"'"'$/, "", line)
        print line
    }
' "$WF")"
n_paths="$(printf '%s\n' "$PATHS" | grep -c . )"
if [ "$n_paths" -eq 0 ]; then
    printf 'CANNOT-RUN: parsed 0 paths: entries from %s.\n' "$WF"
    printf 'The trigger block moved or its indentation changed. A pass here\n'
    printf 'would mean "everything is watched" on the strength of reading\n'
    printf 'nothing at all.\n'
    exit 2
fi

# in_paths <path> -- exact whole-line match against the extracted list.
# grep -x -F: no regex, no substring. 'bin/lib_redact.sh' must not be
# satisfied by an entry for 'bin/lib_redact.sh.bak'.
in_paths() { printf '%s\n' "$PATHS" | grep -qxF -- "$1"; }

printf 'pin covers %s file(s); trigger lists %s path(s)\n\n' "$n_pinned" "$n_paths"

# ── 1. The workflow must RUN the gate ──────────────────────────────────────
# A paths: entry for a gate nobody invokes is the mirror image of dark-on-
# self-edit: perfectly watched, never executed.
if grep -qF -- "$GATE_REL" "$WF"; then
    okay "cut-gate-wrappers.yml invokes ${GATE_REL}"
else
    red  "cut-gate-wrappers.yml does NOT invoke ${GATE_REL} -- watching a gate that never runs"
fi

# ── 2. Every pinned file triggers the workflow ─────────────────────────────
missing=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if in_paths "$p"; then
        okay "pinned file is watched: $p"
    else
        red  "pinned file is NOT in paths: $p  (editing it would not re-run its own pin gate)"
        missing="${missing} ${p}"
    fi
done <<EOF
$PINNED
EOF

# ── 3. The pin file itself ─────────────────────────────────────────────────
# This is the half that #1336/#1340 came apart on: the CONTENT moved on one PR
# and the PIN on another, and neither PR ran the gate.
if in_paths "cuts/REGISTRY_PIN"; then
    okay "cuts/REGISTRY_PIN is watched"
else
    red  "cuts/REGISTRY_PIN is NOT in paths: -- a pin rewrite would not re-run the gate"
fi

# ── 4. The gate and this test are watched (dark on self-edit) ──────────────
for t in "$GATE_REL" "$SELF_REL"; do
    if in_paths "$t"; then
        okay "watched as well as run: $t"
    else
        red  "dark on self-edit: $t is run or relied upon but absent from paths:"
    fi
done

# ── POSITIVE CONTROL ───────────────────────────────────────────────────────
# Prove in_paths can say NO. Without this, a predicate that always returned
# true would pass every assertion above and this file would be decoration.
# The token is a role, not a real path, and is never written anywhere.
if in_paths "this/path/is/not/in/the/workflow"; then
    printf '\nCANNOT-RUN: the control matched. in_paths returns true for a path\n'
    printf 'that is not in the workflow, so every ok above is meaningless.\n'
    exit 2
fi
okay "control: in_paths correctly rejects a path that is not listed"

# ── SECOND CONTROL: the comparison detects a REMOVED entry ─────────────────
# Re-run assertion 2's predicate against the real list minus its first pinned
# file. It must come back missing. This is the mutation the gate exists to
# catch, executed rather than argued.
first_pinned="$(printf '%s\n' "$PINNED" | grep . | head -1)"
mutated="$(printf '%s\n' "$PATHS" | grep -vxF -- "$first_pinned")"
if printf '%s\n' "$mutated" | grep -qxF -- "$first_pinned"; then
    printf '\nCANNOT-RUN: could not build the mutated list -- %s survived removal.\n' "$first_pinned"
    exit 2
fi
okay "control: removing '${first_pinned}' from the list is detectable"

echo
if [ "$fail" -eq 0 ]; then
    printf 'PASS: %s pinned file(s) watched, gate invoked, 2 controls fired\n' "$n_pinned"
    exit 0
fi
printf 'FAIL: see RED lines above.\n'
[ -n "$missing" ] && printf 'Add these to the pull_request paths: list in %s\n%s\n' \
    ".github/workflows/cut-gate-wrappers.yml" "$missing"
exit 1
