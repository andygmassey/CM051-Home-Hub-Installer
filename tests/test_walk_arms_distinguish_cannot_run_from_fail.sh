#!/usr/bin/env bash
# Box-walk arms 1-4 must not report "could not measure" as "measured and bad".
#
# THE DEFECT. Each arm ran its tool with output to /dev/null and branched on the
# exit code alone:
#
#     codesign --verify ... 2>/dev/null && say PASS "rc=0" || say FAIL "rc=1"
#     xcrun stapler validate ... >/dev/null 2>&1 && say PASS || say FAIL "not stapled"
#     find "$MP" -name install.sh > list; [ $N -ge 1 ] || say FAIL "none found"
#
# So ANY reason for a non-zero rc printed as a specific claim about the DMG.
# Measured on a walk whose attach failed, so $APP was never there:
#
#     FAIL     rc=1
#     FAIL     not stapled
#     FAIL     none found
#
# Three confident wrong verdicts reading as an unsigned, unnotarised image with
# no installer in it. Nothing had been measured, and every arm threw away the
# line that said "No such file or directory".
#
# A false cut-blocker is this estate's expensive failure. Arm 7 already had the
# shape: separate unreadable from bad, print the denominator.
#
# WHAT THIS TEST DOES. It extracts arms 1-4 and runs them against an absent
# target (every arm must say CANNOT, none may say FAIL) and against a present
# but unsigned bundle (the signing arms must say FAIL, none may say CANNOT),
# then requires the old collapse-to-FAIL shape to be gone from the script.
#
# Runs in the macos-latest job: codesign, xcrun and spctl are all present there,
# and bash is 3.2, so nothing here uses bash 4 constructs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WALK="$REPO_ROOT/scripts/walk_dmg.sh"
FAILED=0

fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$WALK" ]]; then
    echo "FAIL [walk-missing]: $WALK not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT"' EXIT

# ---- 1. the collapsing shape must be gone --------------------------------
# These run FIRST and read the script as text, so a revert reports the actual
# regression. When they ran last, reverting killed the extraction at step 2 and
# the test exited "could not locate the arms block" -- true, fails closed, but
# it never names what broke.
if grep -qE 'codesign --verify --deep --strict "\$APP" 2>/dev/null && say "PASS"' "$WALK"; then
    fail "old-shape-codesign" "arm 1 still pipes stderr to /dev/null and branches on rc alone"
else
    pass "arm 1 no longer discards the message that discriminates"
fi
if grep -qE 'stapler validate "\$APP" >/dev/null 2>&1 && say "PASS"' "$WALK"; then
    fail "old-shape-stapler" "arm 2 still reports any non-zero rc as 'not stapled'"
else
    pass "arm 2 no longer reports every non-zero rc as 'not stapled'"
fi
if grep -qE '\[ "\$N" -ge 1 \] && say "PASS" "  \$N present" \|\| say "FAIL" "  none found"' "$WALK"; then
    fail "old-shape-find" "arm 4 still reports an unreadable mountpoint as 'none found'"
else
    pass "arm 4 distinguishes an empty image from an unreadable one"
fi

# ---- extract arms 1-4 ------------------------------------------------------
A=$(grep -n '^why() {' "$WALK" | head -1 | cut -d: -f1)
B=$(grep -n '^# Arms 5 and 6 check EVERY install.sh' "$WALK" | head -1 | cut -d: -f1)
if [[ -z "$A" || -z "$B" ]]; then
    echo "FAIL [no-arms]: could not locate the arms 1-4 block (why() at '$A', arm-5 comment at '$B'). NOT a pass." >&2
    exit 2
fi
HARNESS="$WORKROOT/arms.sh"
{
    echo 'say() { printf "%-6s %s\n" "$1" "$2"; }'
    sed -n "${A},$((B-1))p" "$WALK"
} > "$HARNESS"
if [[ ! -s "$HARNESS" ]]; then
    echo "FAIL [empty-extract]: extracted 0 bytes -- every assertion below would see no output and could read as a pass. NOT a pass." >&2
    exit 2
fi
bash -n "$HARNESS" || { echo "FAIL [harness-syntax]: extracted arms do not parse." >&2; exit 2; }
pass "extracted arms 1-4 ($(wc -l < "$HARNESS" | tr -d ' ') lines) and they parse"

run_arms() { # $1 APP, $2 MP -> verdict lines only
    local w; w="$(mktemp -d)"
    APP="$1" MP="$2" WORK="$w" bash "$HARNESS" 2>&1 | grep -E '^(PASS|FAIL|CANNOT)'
    rm -rf "$w"
}

# ---- 2. absent target: every arm must say CANNOT, none may say FAIL --------
OUT="$(run_arms "$WORKROOT/nope/OstlerInstaller.app" "$WORKROOT/nope")"
N_CANNOT=$(printf '%s\n' "$OUT" | grep -c '^CANNOT')
N_FAIL=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
if [[ "$N_CANNOT" -eq 4 && "$N_FAIL" -eq 0 ]]; then
    pass "an attach that never happened reports 4 CANNOT and 0 FAIL"
else
    fail "absent-reads-as-broken" "absent target gave $N_CANNOT CANNOT and $N_FAIL FAIL; expected 4 and 0. A failed attach would print as a broken DMG."
    printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

# ---- 3. present but unsigned: the signing arms must FAIL, not CANNOT ------
UNS="$WORKROOT/unsigned"
mkdir -p "$UNS/OstlerInstaller.app/Contents/MacOS"
printf '#!/bin/sh\n' > "$UNS/OstlerInstaller.app/Contents/MacOS/x"
OUT2="$(run_arms "$UNS/OstlerInstaller.app" "$UNS")"
N_CANNOT2=$(printf '%s\n' "$OUT2" | grep -c '^CANNOT')
N_FAIL2=$(printf '%s\n' "$OUT2" | grep -c '^FAIL')
if [[ "$N_FAIL2" -ge 3 && "$N_CANNOT2" -eq 0 ]]; then
    pass "a real unsigned bundle reports FAIL ($N_FAIL2 arms), never CANNOT"
else
    fail "broken-reads-as-unmeasurable" "unsigned bundle gave $N_FAIL2 FAIL and $N_CANNOT2 CANNOT; expected >=3 FAIL and 0 CANNOT. Forgiving a real defect is worse than the bug being fixed."
    printf '%s\n' "$OUT2" | sed 's/^/      /' >&2
fi

# ---- 4. a FAIL must name the cause, not just an rc ------------------------
# Herestring, not a pipe: under pipefail, `printf | grep -q` returns
# NON-ZERO on a match when printf is still writing. This repo ratchets
# against that construct and caught this very line.
if grep -q 'bundle format unrecognized' <<< "$OUT2"; then
    pass "the codesign FAIL prints the reason codesign gave"
else
    fail "fail-without-cause" "no arm printed codesign's reason; a FAIL that names no cause sends the reader back to the tool"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo
echo "ALL WALK ARM THREE-STATE TESTS PASSED"
