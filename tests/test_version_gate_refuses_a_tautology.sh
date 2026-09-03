#!/usr/bin/env bash
# A gate must not grade a comparison it cannot lose (#171).
#
# THE DEFECT, MEASURED. TNM, 2026-09-03, run 33729085116: the v1.0.61 dry run
# graded v1.0.60 and reported SUCCESS.
#
# THE MECHANISM, at the line. .github/workflows/cut.yml resolves CUT_VERSION:
#     push          -> CUT_VERSION="${GITHUB_REF_NAME}"          (independent)
#     anything else -> CUT_VERSION from gui/OstlerInstaller/Info.plist
#                      CFBundleShortVersionString, `cut -d. -f1-3`
# and then hands it to tests/test_installer_version_matches_the_cut.sh, which
# compares it against THAT SAME FIELD.
#
#   3-part version (1.0.62): v1.0.62 vs 1.0.62  -- UNFAILABLE
#   4-part hotfix (1.0.13.1): v1.0.13 vs 1.0.13.1 -- FALSE RED on a good tree
#
# Two-sided: blind to the defect it exists for, and able to accuse a correct
# hotfix. Sound only on a TAG PUSH, where the tag is an independent claim.
#
# THE FIX GRADED HERE: the gate demands CUT_VERSION_SOURCE and reports
# CANNOT-RUN (exit 2) unless the expected value came from somewhere OTHER than
# its own subject. This file proves it refuses the tautology AND -- the arm
# that matters -- that it still CATCHES A REAL MISMATCH when the source is
# independent. A refusal that refuses everything would be worse than the
# tautology it replaced.
#
# rc=2 from this file means the harness could not set itself up.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/tests/test_installer_version_matches_the_cut.sh"
PLIST="${REPO_ROOT}/gui/OstlerInstaller/Info.plist"
WF="${REPO_ROOT}/.github/workflows/cut.yml"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }

[ -f "$GATE" ]  || cannot "gate-missing"  "$GATE not found -- nothing was checked."
[ -f "$PLIST" ] || cannot "plist-missing" "$PLIST not found -- the gate's subject is absent."
[ -f "$WF" ]    || cannot "wf-missing"    "$WF not found -- the caller half is unverifiable."
command -v python3 >/dev/null 2>&1 || cannot "no-python3" "python3 is not on PATH."

# PREMISE: read the version the gate will read, with the gate's own parser.
REAL="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$PLIST" 2>/dev/null)"
[ -n "$REAL" ] || cannot "premise" "could not read CFBundleShortVersionString; the arms below would compare against nothing."

rc=0
run_gate() { # $1 source, $2 version -> prints rc
    local out
    out="$(CUT_VERSION_SOURCE="$1" bash "$GATE" "$2" 2>&1)"; local r=$?
    printf '%s' "$r"
}
check() {
    local label="$1" got="$2" want="$3" why="$4"
    if [ "$got" = "$want" ]; then
        printf 'ok   %-44s -> rc=%s\n' "$label" "$got"
    else
        rc=1
        printf 'FAIL %-44s -> rc=%s, expected %s\n' "$label" "$got" "$want"
        printf '     %s\n' "$why"
    fi
}

check "source=plist is CANNOT-RUN" \
      "$(run_gate plist "v${REAL}")" 2 \
      "THE DEFECT. The expected value came from the gate's own subject, so a
     pass means nothing. Must be 2 (CANNOT-RUN), never 0."

check "source unset is CANNOT-RUN" \
      "$(CUT_VERSION_SOURCE="" bash "$GATE" "v${REAL}" >/dev/null 2>&1; echo $?)" 2 \
      "Unstated provenance is not assumed innocent. A caller that does not say
     is a caller we cannot vouch for."

check "source=tag + matching version PASSES" \
      "$(run_gate tag "v${REAL}")" 0 \
      "CONTROL. If the refusal also blocked the sound path, the gate would be
     dead on the ONE event where it works, and the v1.0.39 defect would ship
     again unseen."

# The real-mismatch arm. Build a version that is definitely not the plist's.
WRONG_MAJOR="$(printf '%s' "$REAL" | cut -d. -f1)"
WRONG="v$((WRONG_MAJOR + 9)).0.0"
check "source=tag + WRONG version still FAILS" \
      "$(run_gate tag "$WRONG")" 1 \
      "THE ARM THAT MATTERS MOST. The whole point of the gate is to catch a
     stamped version that is not the version being cut. If the provenance
     check swallowed this, I would have replaced an unfailable gate with an
     unfailable gate."

# ── The caller half. A gate that demands a variable nobody sets is dark. ──
if ! /usr/bin/grep -q 'CUT_VERSION_SOURCE=' "$WF"; then
    rc=1
    printf 'FAIL %-44s\n' "cut.yml exports CUT_VERSION_SOURCE"
    printf '     The gate now REQUIRES this variable. If cut.yml does not set it,\n'
    printf '     every cut reports CANNOT-RUN and the check is dark -- honest, but\n'
    printf '     useless. The two halves ship together or not at all.\n'
else
    n_tag="$(/usr/bin/grep -c 'CUT_VERSION_SOURCE="tag"' "$WF")"
    n_pl="$(/usr/bin/grep -c 'CUT_VERSION_SOURCE="plist"' "$WF")"
    if [ "$n_tag" -ge 1 ] && [ "$n_pl" -ge 1 ]; then
        printf 'ok   %-44s -> tag:%s plist:%s\n' "cut.yml sets BOTH provenances" "$n_tag" "$n_pl"
    else
        rc=1
        printf 'FAIL %-44s -> tag:%s plist:%s\n' "cut.yml sets BOTH provenances" "$n_tag" "$n_pl"
        printf '     Both branches must declare. One-sided labelling would let the\n'
        printf '     unlabelled branch fall through to the unset case forever.\n'
    fi
fi

if [ "$rc" -eq 0 ]; then
    echo "PASS: tests/test_version_gate_refuses_a_tautology.sh (5 arms, plist version ${REAL})"
fi
exit "$rc"
