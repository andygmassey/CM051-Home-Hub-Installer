#!/usr/bin/env bash
# UNDER `set -o pipefail`, PIPING INTO A SHORT-CIRCUITING CONSUMER INVERTS A
# SUCCESSFUL MATCH INTO A REPORTED FAILURE.
#
# ============================================================================
# WHAT WAS BROKEN, AND HOW IT SURFACED
# ============================================================================
#
# appcast-ship-wiring went RED on CM051 #890, on this step:
#
#     Control A goes RED when a prerequisite is dropped (a swap, count unchanged)
#
# Its own output NAMED the dropped prerequisite:
#
#     MISSING -- ship: no longer names these, so the cut no longer runs them:
#       - verify-stapling
#
# and the very next lines were:
#
#     .../<step>.sh: line 17: printf: write error: Broken pipe
#     The failure did not NAME the dropped prerequisite.
#
# Line 17 was:
#
#     if ! printf '%s\n' "$out" | grep -q -- '- verify-stapling'; then
#
# THE MECHANISM. `grep -q` exits 0 the instant it matches. That closes the
# pipe while `printf` is still writing, so printf dies with EPIPE. `pipefail`
# makes the PIPELINE's status the rightmost NON-ZERO status, which is now
# printf's. The `!` inverts it, and a SUCCESSFUL match is reported as a failed
# one.
#
# It is a race, not a constant: it fires only when the consumer exits before
# the producer finishes writing. Small output and printf completes first, and
# everything looks fine. That is why this was green on main and red on one PR,
# and it is why "it passed on the re-run" is not evidence that it is fixed.
#
# WORSE THAN THE ONE THAT FIRED. The same file had the construct at line 182
# guarding "did the mutation actually apply":
#
#     if grep '^ship:' "$MUT/Makefile" | grep -q 'verify-stapling'; then
#         echo "MUTATION DID NOT APPLY"; exit 1
#     fi
#
# There the inversion is a FALSE PASS. If the mutation silently failed to
# apply, grep -q MATCHES, the pipeline reads non-zero, the condition is FALSE,
# and the guard against a vacuous proof is itself vacuous.
#
# ============================================================================
# WHAT THIS TEST ASSERTS
# ============================================================================
#
#   1  the OLD construct really does invert (positive control on the premise)
#   2  the herestring replacement reports the match correctly
#   3  repo-wide: the scanner finds a SEEDED instance and rejects two lookalikes
#      that cannot invert, and the population is not growing
#
# 1 and 2 would pass forever against a file nobody uses. Limb 3 is what binds
# this to the tree.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

printf '\n=== pipefail + short-circuiting consumer ===\n\n'

# A match at the START, then enough trailing output that the producer is still
# writing when the consumer exits. The size is what makes the race reliable.
build_haystack() {
    printf -- '- verify-stapling\n'
    local i
    for i in $(seq 1 200000); do echo "filler $i padding padding padding padding"; done
}
HAY="$(build_haystack)"

# Ground truth, computed WITHOUT either construct under test.
OCC="$(grep -c -- '- verify-stapling' <<< "$HAY")"
if [ "$OCC" -eq 1 ]; then
    ok "ground truth: the needle occurs exactly once in the haystack"
else
    bad "haystack is malformed: expected 1 occurrence, got ${OCC}. Limbs 1 and 2 are void."
    finish
fi

# --- 1. POSITIVE CONTROL ON THE PREMISE --------------------------------------
if ( set -o pipefail; printf '%s\n' "$HAY" | grep -q -- '- verify-stapling' ) 2>/dev/null; then
    bad "POSITIVE CONTROL: the OLD construct did NOT invert here. This file can no longer tell the fix from the bug, so limb 2 proves nothing. Investigate before trusting any green from it."
else
    ok "POSITIVE CONTROL: 'printf | grep -q' under pipefail reports FAILURE on a needle that IS present"
fi

# --- 2. the replacement is correct -------------------------------------------
if ( set -o pipefail; grep -q -- '- verify-stapling' <<< "$HAY" ); then
    ok "FIXED: 'grep -q PAT <<< \$var' reports the match correctly under pipefail"
else
    bad "the herestring reported NO match on a needle that IS present. The replacement is wrong."
fi

# --- 3. REPO-WIDE, WITH A POSITIVE CONTROL AND A RATCHET ---------------------
# TNM's correction, and they were right: this started as a FILE fix for the
# file the symptom appeared in. The pattern is a CLASS. Scoped to one workflow,
# limb 3 would have reported CM051 clean while 70 other files carried it.
#
# POSITIVE CONTROL, AND WHY IT IS SYNTHETIC.
#
# This limb first named tests/test_imessage_probe_cannot_hang.sh -- a real
# instance, merged in #891. That was wrong for the same reason #893 was wrong
# this morning: A CONTROL WHOSE SUBJECT ANOTHER OPEN PR IS REMOVING INVERTS ON
# MERGE. TNM's #896 fixes all four instances in that exact file. The moment it
# lands, "the scanner did not see a known instance" would fire -- reporting the
# scanner blind when what actually happened is that the bug was FIXED.
#
# So the control is seeded, in a temp dir, by this file. Nobody will ever
# "fix" it, because it exists to be found. Two negative fixtures sit beside it
# so a blanket matcher cannot pass: one has the construct but no pipefail (the
# pipeline status is then grep's own, and nothing inverts), one uses `grep -c`
# (which must consume all input to count, so it cannot short-circuit).
#
# RATCHET, NOT A BIG BANG. Most of the population will never fire: the
# inversion needs the producer still writing when the consumer exits, so a
# short producer is safe in practice. That is a reason to stop the count
# GROWING, not to rewrite every file on the eve of a cut. Ratcheting BOTH ways
# means a fix that forgets to lower the baseline is also caught, so the number
# cannot rot in either direction.
CONSTRUCT='^[[:space:]]*(if|elif|while)[[:space:]].*\|[[:space:]]*(grep [^|]*-q|grep [^|]*-m1|head( |$)|read )'
BASELINE_FILE='tests/pipefail_shortcircuit_baseline.txt'

# Only files that ALSO set pipefail can invert. Without it the pipeline status
# is the LAST command's, which is grep's own verdict, and nothing is wrong.
# `grep -c` is deliberately NOT in CONSTRUCT: it must consume all input to
# count, so it cannot short-circuit.
population_in() {
    local root="$1" f
    for f in $(grep -rlE "$CONSTRUCT" --include='*.sh' --include='*.yml' "$root" 2>/dev/null | grep -v '/\.git/' | sort); do
        grep -qE 'set -o pipefail|set -[a-z]+o[a-z]* pipefail' "$f" 2>/dev/null && echo "$f"
    done
}
population() { population_in .; }
POP="$(population)"
POP_N="$(printf '%s\n' "$POP" | grep -c . || true)"
printf '        population examined: %s files (construct in a condition AND pipefail set)\n' "$POP_N"

CTL_DIR="$(mktemp -d)"
trap 'rm -rf "$CTL_DIR"' EXIT

# The seeded instance the scanner MUST find.
cat > "$CTL_DIR/seeded_instance.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
if printf 'needle\n' | grep -q needle; then echo found; fi
FIXTURE

# Discriminator 1: same construct, NO pipefail. Without it the pipeline status
# is grep's own verdict and nothing inverts, so this must NOT be reported.
cat > "$CTL_DIR/no_pipefail.sh" <<'FIXTURE'
#!/usr/bin/env bash
if printf 'needle\n' | grep -q needle; then echo found; fi
FIXTURE

# Discriminator 2: pipefail set, but `grep -c` must read all input to count,
# so it cannot short-circuit. Must NOT be reported.
cat > "$CTL_DIR/grep_c_is_safe.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
if [ "$(printf 'needle\n' | grep -c needle)" -gt 0 ]; then echo found; fi
FIXTURE

CTL_POP="$(population_in "$CTL_DIR")"
if grep -qF 'seeded_instance.sh' <<< "$CTL_POP"; then
    ok "POSITIVE CONTROL: the scanner finds a seeded instance it MUST find"
else
    bad "POSITIVE CONTROL FAILED: the scanner did NOT find a file it was handed, carrying the construct AND pipefail. The scanner is blind and the ratchet below is void."
fi
if grep -qF 'no_pipefail.sh' <<< "$CTL_POP"; then
    bad "DISCRIMINATOR FAILED: the scanner reported a file with NO pipefail. It is matching the construct alone, so the population is inflated and the baseline is meaningless."
else
    ok "DISCRIMINATOR: no pipefail, not reported"
fi
if grep -qF 'grep_c_is_safe.sh' <<< "$CTL_POP"; then
    bad "DISCRIMINATOR FAILED: the scanner reported 'grep -c', which cannot short-circuit. CONSTRUCT is over-broad."
else
    ok "DISCRIMINATOR: 'grep -c' cannot short-circuit, not reported"
fi
rm -rf "$CTL_DIR"; trap - EXIT

if [ ! -f "$BASELINE_FILE" ]; then
    bad "${BASELINE_FILE} is missing, so there is nothing to ratchet against and 'no new instances' would be unfounded"
else
    BASE_N="$(grep -vcE '^[[:space:]]*(#|$)' "$BASELINE_FILE" || true)"
    if [ "$POP_N" -gt "$BASE_N" ]; then
        bad "ratchet: ${POP_N} instances vs baseline ${BASE_N}. NEW:"
        comm -13 <(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" | sort) <(printf '%s\n' "$POP" | sort) | sed 's/^/          /'
        printf '          Use a herestring: grep -q PAT <<< "$var", never printf | grep -q.\n'
    elif [ "$POP_N" -lt "$BASE_N" ]; then
        bad "ratchet: ${POP_N} instances, baseline still ${BASE_N}. Instances were FIXED without lowering the baseline, so the ratchet has slack and the next regression hides in it. Regenerate ${BASELINE_FILE}."
    else
        ok "ratchet: ${POP_N} instances, baseline ${BASE_N}, exact"
    fi

    # A baseline row naming a file that no longer exists is slack the counts
    # above cannot see: delete one instance file, add one elsewhere, and the
    # total is unchanged.
    ROTTED=""
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        [ -e "$row" ] || ROTTED="${ROTTED}${row}"$'\n'
    done < <(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE")
    if [ -n "$ROTTED" ]; then
        bad "baseline rot: these rows name files that no longer exist, so the count can stay level while the set changes underneath it:"
        printf '%s' "$ROTTED" | sed 's/^/          /'
    else
        ok "no baseline rot: every one of the ${BASE_N} rows still names a real file"
    fi
fi

finish
