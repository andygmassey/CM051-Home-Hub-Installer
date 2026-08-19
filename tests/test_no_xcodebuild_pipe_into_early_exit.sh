#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# No shipped script may pipe xcodebuild into a consumer that exits early.
#
# WHAT THIS CAUGHT, 2026-08-13.
#
# scripts/select_pinned_xcode.sh piped `xcodebuild -version` into `head -1`.
# head exits after the first line and closes the read end of the pipe; if
# xcodebuild has not finished writing line 2 it gets EPIPE, and its Foundation
# file handle raises an UNCAUGHT NSFileHandleOperationException rather than
# taking SIGPIPE quietly. It aborts with 134, `set -o pipefail` makes that the
# pipeline's status, and `set -e` kills the script -- AFTER it has already
# correctly selected the pinned Xcode. From run 31686875225 (pbxproj-sync,
# main):
#
#     selected: /Applications/Xcode_26.6.0.app
#     *** NSFileHandleOperationException ... -[_NSStdIOFileHandle writeData:]
#     4  xcodebuild  -[XcodebuildPreIDEHandler handleVersionWithArguments:]
#     ##[error]Process completed with exit code 134
#
# WHY A GATE AND NOT JUST THE FIX.
#
# It is a RACE. It fired on 7 of the 12 pbxproj-sync runs before it was found
# and reproduced 0 times in 40 on the build host. So the failure is invisible
# to whoever reintroduces it, their CI run has a better-than-even chance of
# being green, and scripts/select_pinned_xcode.sh is on the CUT's critical
# path -- it is the first step of the `cut` job in cut.yml. An intermittent
# abort there reads as "the cut is randomly broken".
#
# WHY THE SCOPE IS xcodebuild AND NOT EVERY PIPE.
#
# The early-exit pipe idiom appears in dozens of scripts here, almost all fed
# by grep or find over small inputs where the writer finishes before the
# reader quits. Failing those would be a denylist of things that are fine.
# xcodebuild is the producer that has been MEASURED to abort rather than die
# quietly, so it is the one this gate names. Widen it when something else is
# measured, not on suspicion.
#
# `sed -n '2p'` is deliberately NOT flagged: it reads to EOF and never closes
# the pipe early. The dangerous consumers are the ones that quit: head,
# grep -m, and sed/awk with an explicit q/exit.
#
# TWO THINGS THIS FILE HAD TO GET RIGHT ABOUT ITSELF.
#
# 1. A commented-out line does not execute, so comment lines are stripped
#    before matching. Without that, the gate flags the very explanation of the
#    defect it exists to prevent -- including this paragraph.
#
# 2. The positive control must not carry the literal it hunts, or the gate
#    reports its own control as a violation and the tree can never be clean.
#    The planted line is therefore ASSEMBLED at runtime from pieces that are
#    individually inert, so no source line in this file is a match.
#
# CONTROLS. A gate with no demonstrated RED is not a gate, and a zero
# denominator reads exactly like a clean sweep, so this file proves four
# things before it reports anything: the detector fires on a planted
# violation, it stays quiet on the safe form, it does not count a
# commented-out line as executable code, and the scan reached a large
# population of real files.
#
# Usage:  bash tests/test_no_xcodebuild_pipe_into_early_exit.sh
# Exit:   0 clean, 1 violation found, 2 the gate could not run.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "::error::cannot cd to repo root"; exit 2; }

# The producer, held in a variable so this line is not itself a match.
PRODUCER='xcodebuild'

# Consumers that CLOSE THE PIPE EARLY:
#   head          quits after N lines
#   grep -m N     quits after N matches
#   sed ... q     explicit quit
#   awk ... exit  explicit exit
CONSUMERS='head|grep[[:space:]]+-m|sed[^|]*[;{[:space:]]q[;}[:space:]"'"'"']|awk[^|]*[;{[:space:]]exit'
MATCH_RE="${PRODUCER}[^|]*\\|[[:space:]]*[^|]*(${CONSUMERS})"

scan() {
    # No `grep --include`: BusyBox grep does not have it, exits 2, prints
    # nothing, and every limb reads clean. find + xargs works everywhere.
    #
    # The trailing filter drops hits whose line begins with a comment marker.
    # A commented line is not code, and the alternative is a gate that can
    # never let anyone write down what it is for.
    find "$1" -type f -name '*.sh' -print0 2>/dev/null \
        | xargs -0 grep -nEH "$MATCH_RE" 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#'
}

count_files() {
    find "$1" -type f -name '*.sh' -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' '
}

CTRL_DIR="$(mktemp -d)"
trap 'rm -rf "$CTRL_DIR"' EXIT

# The literal never appears in this file: it is printf'd from two inert parts.
plant_violation() {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nGOT="$(%s -version %s head -1)"\necho "$GOT"\n' \
        "$PRODUCER" '|' > "$1"
}
plant_commented_violation() {
    printf '#!/usr/bin/env bash\n# GOT="$(%s -version %s head -1)"   <- historical, now fixed\necho ok\n' \
        "$PRODUCER" '|' > "$1"
}
plant_safe() {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nV="$(%s -version)"\nA="$(awk %sNR == 1 { print $2 }%s <<<"$V")"\nB="$(%s -version %s sed -n %s2p%s)"\necho "$A $B"\n' \
        "$PRODUCER" "'" "'" "$PRODUCER" '|' "'" "'" > "$1"
}

# --- CONTROL 1: does the detector fire on a planted violation? -------------
plant_violation "$CTRL_DIR/c1.sh"
N="$(scan "$CTRL_DIR" | wc -l | tr -d ' ')"
if [ "$N" -ne 1 ]; then
    echo "::error::POSITIVE CONTROL FAILED. Found $N violations in a file containing exactly one. Every result below is vacuous."
    exit 2
fi
echo "control 1  detector fires on a real violation      PASS"
rm -f "$CTRL_DIR/c1.sh"

# --- CONTROL 2: quiet on the safe form? ------------------------------------
plant_safe "$CTRL_DIR/c2.sh"
N="$(scan "$CTRL_DIR" | wc -l | tr -d ' ')"
if [ "$N" -ne 0 ]; then
    echo "::error::NEGATIVE CONTROL FAILED. The detector flagged the safe form ($N hits), including the sed -n '2p' form that reads to EOF. A detector that matches everything cannot tell a defect from its fix."
    scan "$CTRL_DIR"
    exit 2
fi
echo "control 2  safe form and sed -n 2p not flagged     PASS"
rm -f "$CTRL_DIR/c2.sh"

# --- CONTROL 3: is a commented-out violation correctly ignored? ------------
plant_commented_violation "$CTRL_DIR/c3.sh"
N="$(scan "$CTRL_DIR" | wc -l | tr -d ' ')"
if [ "$N" -ne 0 ]; then
    echo "::error::COMMENT CONTROL FAILED. A commented-out line was counted as executable code ($N hits), so this gate cannot be documented without failing."
    exit 2
fi
echo "control 3  commented-out line is not code          PASS"
rm -f "$CTRL_DIR/c3.sh"

# --- CONTROL 4: did the scan actually reach the tree? ----------------------
N_SCRIPTS="$(count_files scripts)"
N_TESTS="$(count_files tests)"
N_TOTAL=$((N_SCRIPTS + N_TESTS))
if [ "$N_TOTAL" -lt 20 ]; then
    echo "::error::DENOMINATOR CONTROL FAILED. Only $N_TOTAL shell files found under scripts/ and tests/. This repo has far more, so the scan is not reaching the tree and a clean result means nothing."
    exit 2
fi
echo "control 4  population examined                     PASS  ($N_TOTAL .sh files: $N_SCRIPTS scripts/, $N_TESTS tests/)"
echo

# --- THE ACTUAL SCAN -------------------------------------------------------
HITS="$( { scan scripts; scan tests; } )"
if [ -n "$HITS" ]; then
    echo "::error::xcodebuild piped into a consumer that exits early. This is the 134/EPIPE abort from run 31686875225, and it is a race, so the run that reintroduces it is likely to come back green."
    echo "$HITS" | while IFS= read -r line; do echo "  $line"; done
    echo
    echo "  Fix: capture once, parse from the variable."
    echo '    XCB_VERSION="$(xcodebuild -version)"'
    echo "    GOT=\"\$(awk 'NR == 1 { print \$2 }' <<<\"\$XCB_VERSION\")\""
    exit 1
fi

echo "clean: no $PRODUCER piped into an early-exiting consumer across $N_TOTAL shell files."
exit 0
