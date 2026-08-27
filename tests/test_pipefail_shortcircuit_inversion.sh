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
#   2  BOTH remedies report the match correctly, and a real POSIX shell shows
#      which is which: the herestring is bash-only, `grep -c` is portable.
#      That distinction is load-bearing -- box_run() ships command TEXT over
#      ssh to a login shell nobody here chooses
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

# --- 2A. REMEDY A -- the herestring, correct under pipefail, BASH ONLY --------
if ( set -o pipefail; grep -q -- '- verify-stapling' <<< "$HAY" ); then
    ok "REMEDY A: 'grep -q PAT <<< \$var' reports the match correctly under pipefail (bash)"
else
    bad "REMEDY A reported NO match on a needle that IS present. The replacement is wrong."
fi

# --- 2B. REMEDY B -- grep -c, correct under pipefail AND portable ------------
# `grep -c` has to consume all input to produce a count, so it cannot exit
# early, so the producer never takes SIGPIPE. That is a POSIX property of -c,
# not a bash one -- which is what makes it the remedy that survives leaving
# this shell.
if ( set -o pipefail; n="$(printf '%s\n' "$HAY" | grep -c -- '- verify-stapling')"; [ "$n" -gt 0 ] ); then
    ok "REMEDY B: '[ \"\$(... | grep -c PAT)\" -gt 0 ]' reports the match correctly under pipefail"
else
    bad "REMEDY B reported NO match on a needle that IS present. grep -c is supposed to be the PORTABLE fix; if this fires, the advice limb 3 prints is wrong."
fi

# --- 2C. THE DISCRIMINATOR: A IS A BASHISM, B IS NOT -------------------------
# This is the whole point. The ratchet's failure message used to name ONLY the
# herestring. This repo executes command TEXT in shells it does not choose:
# scripts/box_walk_probes/lib/probe.sh box_run() runs `ssh HOST "$1"`, naming
# no shell, so the box's LOGIN shell parses it. If that is dash, remedy A is a
# syntax error and the "fix" breaks the probe outright.
#
# 🔴 /bin/sh CANNOT BE THE CONTROL HERE. On macOS /bin/sh IS bash 3.2.57: it
# accepts `<<<` and would pass for the wrong reason -- a control in the wrong
# compartment. So the candidate is PROVED not-bash before it is trusted, and
# if none is found this limb says CANNOT-RUN rather than nothing.
POSIX_SH=""
for _cand in /bin/dash /usr/bin/dash "$(command -v dash 2>/dev/null || true)" /bin/ash /usr/bin/busybox; do
    [ -n "$_cand" ] && [ -x "$_cand" ] || continue
    _v="$("$_cand" -c 'echo "${BASH_VERSION:-}"' 2>/dev/null || true)"
    [ -n "$_v" ] && continue          # reports a BASH_VERSION -> disqualified
    POSIX_SH="$_cand"; break
done

if [ -z "$POSIX_SH" ]; then
    bad "CANNOT-RUN: no non-bash POSIX shell found (tried dash, ash, busybox), so 'remedy A is a bashism, remedy B is portable' is UNMEASURED on this host. /bin/sh was deliberately NOT used: here it is bash $(/bin/sh -c 'echo ${BASH_VERSION:-?}') and would pass for the wrong reason. Install dash, or run this limb on Linux, before trusting the advice limb 3 prints."
else
    if "$POSIX_SH" -c 'grep -c x <<< "xyz"' >/dev/null 2>&1; then
        bad "DISCRIMINATOR: ${POSIX_SH} ACCEPTED a herestring, so it is not the POSIX control this limb needs and the bashism claim is unproven here."
    else
        ok "DISCRIMINATOR: ${POSIX_SH} REJECTS 'grep -q PAT <<< \$var' -- remedy A is a bashism, exactly as limb 3 says"
    fi
    # The other half. Without it the limb above only proves dash is fussy, not
    # that grep -c is the answer.
    if "$POSIX_SH" -c 'n=$(printf "%s\n" "xyz" | grep -c x); [ "$n" -gt 0 ]' >/dev/null 2>&1; then
        ok "DISCRIMINATOR: ${POSIX_SH} ACCEPTS the grep -c remedy -- remedy B is the one that survives box_run's ssh branch"
    else
        bad "DISCRIMINATOR: ${POSIX_SH} rejected the grep -c remedy too. Limb 3 would then be advising something that works in NEITHER shell."
    fi
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
    # `sed 's#^\./##'` IS LOAD-BEARING, AND ITS ABSENCE VOIDED THE WHOLE
    # COMPARISON BELOW. `grep -r PATTERN .` emits './bin/x.sh'; the baseline
    # file stores 'bin/x.sh'. The two sets therefore shared NOT ONE ROW, and
    # the ratchet agreed only because both happened to contain 70 of them.
    # The `comm` that names the offending files runs ONLY on the failure
    # path, so nobody ever saw it print all 70.
    for f in $(grep -rlE "$CONSTRUCT" --include='*.sh' --include='*.yml' "$root" 2>/dev/null | grep -v '/\.git/' | sed 's#^\./##' | sort); do
        # FROZEN ARTEFACTS ARE NOT LIVE SHELL. tests/fixtures/ holds code kept
        # DELIBERATELY BROKEN so a control can be proved to go red against it
        # -- see tests/fixtures/verify_customer_download_path.prefix. Counting
        # one would demand a "fix" that destroys the only thing it is for, and
        # would inflate the ceiling so a real regression could hide under it.
        #
        # Until now the only thing keeping such a file out was that I dropped
        # the .sh extension off that fixture by hand, so the *.sh glob missed
        # it. A convention recorded in one comment in one other file is not a
        # guard: the next author names their fixture *.sh and it is back.
        case "$f" in
            tests/fixtures/*|*/tests/fixtures/*) continue ;;
        esac
        grep -qE 'set -o pipefail|set -[a-z]+o[a-z]* pipefail' "$f" 2>/dev/null && echo "$f"
    done
}

# Rows in the scan that the baseline does not list, and vice versa. Split out
# as functions so limb 4 can drive them against a KNOWN answer -- an untested
# comparison is exactly what shipped here.
baseline_rows() { grep -vE '^[[:space:]]*(#|$)' "$1" | sort; }
rows_added()    { comm -13 <(baseline_rows "$1") <(printf '%s\n' "$2" | grep -v '^$' | sort); }
rows_removed()  { comm -23 <(baseline_rows "$1") <(printf '%s\n' "$2" | grep -v '^$' | sort); }
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

# Discriminator 3: tests/fixtures/ is FROZEN, DELIBERATELY-BROKEN code, kept so
# a control can be proved to go red against it. Counting one would demand a
# "fix" that destroys the only thing the file is for, and would raise the
# ceiling so a real regression could hide under it. This is seeded as a *.sh
# ON PURPOSE -- the exclusion must hold on the extension the next author will
# actually reach for, not on the naming dodge that happens to work today.
mkdir -p "$CTL_DIR/tests/fixtures"
cat > "$CTL_DIR/tests/fixtures/frozen_prefix_gate.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
if printf 'needle\n' | grep -q needle; then echo found; fi
FIXTURE

CTL_POP="$(population_in "$CTL_DIR")"
if grep -qF 'tests/fixtures/frozen_prefix_gate.sh' <<< "$CTL_POP"; then
    bad "DISCRIMINATOR FAILED: the scanner reported a file under tests/fixtures/. Frozen broken artefacts are not live shell -- counting one inflates the ceiling and its only possible 'fix' destroys the fixture."
else
    ok "DISCRIMINATOR: tests/fixtures/ is frozen artefact, not live shell, not reported"
fi
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

# --- 4. THE COMPARISON ITSELF, DRIVEN AGAINST A KNOWN ANSWER -----------------
# This limb exists because the comparison below shipped BROKEN and green.
#
# `grep -r PAT .` emits './bin/x.sh'. The baseline stores 'bin/x.sh'. The two
# sets were therefore DISJOINT -- not one row in common -- and the ratchet
# reported "70 instances, baseline 70, exact" because it compared only the
# CARDINALITIES. The `comm` that names offending files runs solely on the
# failure path, which had never executed, so the first person to add a 71st
# instance would have been handed all 71 files as "NEW".
#
# The lesson generalises past this file: A COUNT IS A LOSSY SUMMARY OF A SET,
# and every way this ratchet can rot leaves the count intact. So assert the
# SETS match, and prove the assertion can tell a matching pair from a
# non-matching one before trusting it.
SD="$(mktemp -d)"
trap 'rm -rf "$SD"' EXIT
printf 'a/one.sh\na/two.sh\n' > "$SD/base.txt"

got="$(rows_added "$SD/base.txt" "$(printf 'a/one.sh\na/two.sh\na/three.sh\n')")"
if [ "$got" = "a/three.sh" ]; then
    ok "COMPARISON: one added row is named, and only it"
else
    bad "COMPARISON: expected exactly 'a/three.sh', got: ${got//$'\n'/ }. The ratchet's failure message cannot be trusted to name the right files."
fi

got="$(rows_removed "$SD/base.txt" "$(printf 'a/one.sh\n')")"
if [ "$got" = "a/two.sh" ]; then
    ok "COMPARISON: one delisted row is named, and only it"
else
    bad "COMPARISON: expected exactly 'a/two.sh', got: ${got//$'\n'/ }"
fi

# THE PRE-FIX SHAPE, REPRODUCED DELIBERATELY. Same two files, written in the
# other path form: every row reads as both added and removed, while the counts
# agree perfectly. If this ever stops being 2-and-2, the strip has been removed
# and the comparison is void again.
n_add="$(rows_added   "$SD/base.txt" "$(printf './a/one.sh\n./a/two.sh\n')" | grep -c . || true)"
n_rem="$(rows_removed "$SD/base.txt" "$(printf './a/one.sh\n./a/two.sh\n')" | grep -c . || true)"
if [ "$n_add" -eq 2 ] && [ "$n_rem" -eq 2 ]; then
    ok "PRE-FIX SHAPE: a './'-prefixed population is fully disjoint from the baseline (2 added, 2 removed) while the COUNTS agree -- exactly the green this file used to report"
else
    bad "PRE-FIX SHAPE: expected 2 added / 2 removed, got ${n_add}/${n_rem}. This limb can no longer demonstrate the defect it was written for, so the ok above proves less than it claims."
fi
rm -rf "$SD"; trap - EXIT

# And the live population must be in the baseline's form, or limb 3's verdict
# is about two sets that can never intersect. Herestring, not a pipe: this file
# is itself in the baseline and must not add to it.
if grep -q '^\./' <<< "$POP"; then
    bad "population rows carry a './' prefix the baseline does not. The set comparison below is comparing disjoint sets and can only ever agree by cardinality."
else
    ok "population rows are repo-relative, the same form the baseline stores"
fi

if [ ! -f "$BASELINE_FILE" ]; then
    bad "${BASELINE_FILE} is missing, so there is nothing to ratchet against and 'no new instances' would be unfounded"
else
    BASE_N="$(grep -vcE '^[[:space:]]*(#|$)' "$BASELINE_FILE" || true)"

    # COMPARE THE SETS, NOT THE COUNTS. A count is a lossy summary of a set,
    # and every way this ratchet can rot leaves the count intact: fix one
    # instance and introduce another, delete an instance file and add one
    # elsewhere, or -- as actually happened -- write the two sides in
    # different path forms so they agree on 70 while sharing nothing.
    ADDED="$(rows_added "$BASELINE_FILE" "$POP")"
    REMOVED="$(rows_removed "$BASELINE_FILE" "$POP")"

    if [ -n "$ADDED" ]; then
        bad "ratchet: NEW instances, not listed in ${BASELINE_FILE} (${POP_N} found, baseline ${BASE_N}):"
        sed 's/^/          /' <<< "$ADDED"
        # TWO REMEDIES, AND WHICH IS CORRECT DEPENDS ON WHICH SHELL RUNS THE
        # STRING. This used to name only the herestring -- a bashism, and so
        # wrong advice for every site whose text is executed elsewhere. This
        # repo has those: scripts/box_walk_probes/lib/probe.sh box_run() sends
        # "$1" to `ssh HOST "$1"`, naming no shell, so the BOX'S LOGIN SHELL
        # parses it. Handing a herestring to a dash login shell is a syntax
        # error, not a fix. Proved by limb 2C.
        printf '          TWO REMEDIES -- pick by WHICH SHELL EXECUTES THE STRING:\n'
        printf '            bash you control  grep -q PAT <<< "$var"            no pipe, so no SIGPIPE\n'
        printf '            any POSIX shell   [ "$(... | grep -c PAT)" -gt 0 ]  grep -c must read to EOF\n'
        printf '          If the text runs remotely or via `sh -c` -- box_run(), ssh, a login shell\n'
        printf '          you do not choose -- the herestring is a BASHISM. Use grep -c.\n'
        printf '          Never `... | grep -q`: it exits on first match and SIGPIPEs the producer.\n'
    else
        ok "ratchet: no new instances -- every one of the ${POP_N} found is already baselined"
    fi

    if [ -n "$REMOVED" ]; then
        # Two causes, two different remedies, so name which is which rather
        # than handing back one undifferentiated list.
        fixed=""; gone=""
        while IFS= read -r row; do
            [ -n "$row" ] || continue
            if [ -e "$row" ]; then fixed="${fixed}${row}"$'\n'; else gone="${gone}${row}"$'\n'; fi
        done <<< "$REMOVED"
        bad "ratchet: ${BASELINE_FILE} lists rows the scan does NOT find. That is slack the next regression hides in. Delist them."
        [ -n "$fixed" ] && { printf '          CONSTRUCT FIXED (or now excluded), file still present:\n'; sed 's/^/            /' <<< "${fixed%$'\n'}"; }
        [ -n "$gone" ]  && { printf '          FILE NO LONGER EXISTS:\n'; sed 's/^/            /' <<< "${gone%$'\n'}"; }
    else
        ok "no baseline rot: all ${BASE_N} baselined rows were found by this scan"
    fi
fi

finish
