#!/usr/bin/env bash
# tests/test_the_os003_pointer_cannot_rot.sh
# ============================================================================
# CM051 #1038. CLAUDE.md is read first by every agent and it said, in bold, to
# read a DIRECTORY as canonical release truth. A directory is a fact that
# moves, so the file that states "a file read first must not carry facts that
# move" was breaking its own rule.
#
# WHAT WAS MEASURED, 2026-09-17, on the operator's machine:
#
#   ~/Documents/Projects/OS003 - Ostler Release   (the path CLAUDE.md named)
#       HEAD c634e0bb, a STRICT ANCESTOR of origin/main, 41 commits behind
#       53 cut directories, against 70 in the current tree
#       1,607 iCloud-EVICTED files
#   ~/Developer/OS003-Ostler-Release               (the path it names now)
#       0 behind, 0 evicted, 70 cuts
#
# Seventeen cuts invisible, and every grep of the evicted tree able to return a
# FALSE ZERO that reads as real absence.
#
# TWO HALVES, AND THEY FAIL IN OPPOSITE DIRECTIONS:
#
#   ARM A  THE POINTER. CLAUDE.md declares exactly one machine-readable
#          OS003_CHECKOUT line, names the checker, and no longer sends anyone
#          at the evicted tree. Each of those is asserted with a control on the
#          same corpus, so an absence cannot be a blind reader.
#
#   ARM B  THE CHECKER CAN ACTUALLY SAY RED. Synthetic git repositories, built
#          here, drive the REAL script: current, stale, ancient-ref, not-a-repo,
#          no-origin-main, no-rule-line, two-rule-lines. Each asserts a SPECIFIC
#          exit code AND a specific string, because a script that exits 1 for
#          the wrong reason is a gate that has never been watched to fail.
#
# EVICTION IS PLATFORM-SPLIT, ON PURPOSE AND NOT AS AN ESCAPE HATCH. macOS
# marks an evicted file `dataless` and BSD `find -flags` reads it; GNU find has
# no `-flags` at all. On a host with the instrument this suite requires the
# script to run the limb and pass its own positive control. On a host without
# it, the suite requires the script to report CANNOT-RUN, because a freshness
# verdict that cannot see eviction is not a verdict. Both are assertions; the
# difference is which one is true here, and the suite prints which it took.
#
# Exit codes: 0 every arm passed / 1 an arm failed / 2 could not run.
# British English throughout. No em dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER_REL="scripts/verify_os003_pointer.sh"
CHECKER="${REPO_ROOT}/${CHECKER_REL}"
CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
EVICTED_PATH_FRAGMENT='Documents/Projects/OS003'

fails=0
arms=0
cannot_run() {
    printf 'CANNOT-RUN: %s\n' "$1" >&2
    printf '            Nothing was examined. This is not a pass.\n' >&2
    exit 2
}
ok()  { arms=$(( arms + 1 )); printf '  PASS  %s\n' "$1"; }
bad() { arms=$(( arms + 1 )); fails=$(( fails + 1 )); printf '  FAIL  %s\n' "$1"; }

[ -r "$CHECKER" ]   || cannot_run "checker not readable: ${CHECKER}"
[ -r "$CLAUDE_MD" ] || cannot_run "CLAUDE.md not readable: ${CLAUDE_MD}"
command -v git >/dev/null 2>&1 || cannot_run "no git on PATH"

WORK="$(mktemp -d)" || cannot_run "could not make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

echo "=== the OS003 pointer cannot rot silently (CM051 #1038) ==="
echo "    checker: ${CHECKER_REL}"
echo "    shell:   ${BASH_VERSION}"
echo

# ===========================================================================
# ARM A: THE POINTER ITSELF
# ===========================================================================

n_rule="$(grep -c '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$CLAUDE_MD")"
if [ "${n_rule:-0}" -eq 1 ]; then
    ok "CLAUDE.md declares exactly ONE OS003_CHECKOUT line (the checker resolves it, so the rule and the checker cannot drift apart)"
else
    bad "CLAUDE.md declares ${n_rule:-0} OS003_CHECKOUT lines, expected exactly 1. Zero leaves the checker guarding nothing; two gives it two answers and it would silently take the first."
fi

n_evicted_ref="$(grep -c "$EVICTED_PATH_FRAGMENT" "$CLAUDE_MD")"
n_current_ref="$(grep -c 'OS003-Ostler-Release' "$CLAUDE_MD")"
if [ "${n_current_ref:-0}" -lt 1 ]; then
    bad "POSITIVE CONTROL FAILED: CLAUDE.md does not mention OS003-Ostler-Release at all (${n_current_ref:-0} hits), so a zero on the evicted path below would be a statement about this grep rather than about the file."
else
    ok "POSITIVE CONTROL: the same grep finds OS003-Ostler-Release ${n_current_ref} time(s), so it can read this file"
    if [ "${n_evicted_ref:-0}" -eq 0 ]; then
        ok "CLAUDE.md no longer sends anyone at the iCloud-evicted checkout (0 hits for ${EVICTED_PATH_FRAGMENT})"
    else
        bad "CLAUDE.md still names ${EVICTED_PATH_FRAGMENT} ${n_evicted_ref} time(s) as somewhere to READ. That tree measured 41 commits behind and 1,607 evicted files; every grep of it can return a false zero."
    fi
fi

if [ "$(grep -c -F "$CHECKER_REL" "$CLAUDE_MD")" -ge 1 ]; then
    ok "CLAUDE.md names the checker by path, so a reader is told how to test the pointer rather than trust it"
else
    bad "CLAUDE.md does not name ${CHECKER_REL}. A freshness check nobody is told to run is a freshness check nobody runs."
fi

if [ -x "$CHECKER" ]; then
    ok "the checker is executable"
else
    bad "the checker is not executable: ${CHECKER}"
fi

# ===========================================================================
# ARM B: THE CHECKER CAN SAY RED, GREEN AND CANNOT-RUN
# ===========================================================================

# A rule file the fixtures point the checker at, so no arm below depends on
# the real CLAUDE.md and none of them can edit it.
mkrule() {   # mkrule <file> <path-or-empty> [<second path>]
    : > "$2"
    printf 'Some prose that is not the rule.\n' >> "$2"
    [ -n "${3:-}" ] && printf '    OS003_CHECKOUT = %s\n' "$3" >> "$2"
    [ -n "${4:-}" ] && printf '    OS003_CHECKOUT = %s\n' "$4" >> "$2"
    return 0
}

# A synthetic OS003: an "upstream" repo and a clone whose origin/main can be
# advanced without touching the clone's HEAD. Real git throughout; a mocked
# rev-list would not exercise the thing that decides the verdict.
#
# GIT_COMMITTER_DATE is set explicitly so the ref-age limb is measured against
# a date this test chose rather than whenever the runner happened to build the
# fixture. An age arm that depends on the clock is not an age arm.
mkrepo() {   # mkrepo <dir> <behind-count> <days-old>
    local dir="$1" behind="$2" days="$3" up="$1.upstream" i when
    rm -rf "$dir" "$up"
    mkdir -p "$up"
    when="$(date -u -r "$(( $(date -u +%s) - days * 86400 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
            || date -u -d "@$(( $(date -u +%s) - days * 86400 ))" +%Y-%m-%dT%H:%M:%S)"
    (
        cd "$up" || exit 1
        git init -q -b main .
        git config user.email t@example.invalid
        git config user.name  Test
        mkdir -p cuts/v1.0.1 cuts/v1.0.2
        : > cuts/v1.0.1/MUST_CONTAIN.tsv
        : > cuts/v1.0.2/MUST_CONTAIN.tsv
        git add -A
        GIT_AUTHOR_DATE="${when}Z" GIT_COMMITTER_DATE="${when}Z" git commit -q -m base
    ) || return 1
    git clone -q "$up" "$dir" 2>/dev/null || return 1
    (
        cd "$dir" || exit 1
        git config user.email t@example.invalid
        git config user.name  Test
    )
    i=0
    while [ "$i" -lt "$behind" ]; do
        i=$(( i + 1 ))
        (
            cd "$up" || exit 1
            mkdir -p "cuts/v1.1.${i}"
            : > "cuts/v1.1.${i}/MUST_CONTAIN.tsv"
            git add -A
            GIT_AUTHOR_DATE="${when}Z" GIT_COMMITTER_DATE="${when}Z" git commit -q -m "cut ${i}"
        ) || return 1
    done
    # Refresh the CLONE'S remote-tracking ref without moving its HEAD, which is
    # exactly the state a stale working copy is in.
    ( cd "$dir" && git fetch -q origin main && git update-ref refs/remotes/origin/main FETCH_HEAD )
    return 0
}

run_checker() {  # run_checker <rulefile> <target-or-empty> -> prints "rc<TAB>output"
    local out rc
    out="$(OS003_RULE_FILE="$1" /bin/bash "$CHECKER" ${2:+"$2"} 2>&1)"
    rc=$?
    printf '%s\n' "$rc"
    printf '%s\n' "$out" > "${WORK}/last.out"
}

expect() {  # expect <label> <want-rc> <want-string> <rulefile> [target]
    local label="$1" want_rc="$2" want_str="$3" rule="$4" target="${5:-}" rc
    rc="$(run_checker "$rule" "$target")"
    if [ "$rc" != "$want_rc" ]; then
        bad "${label}: exit ${rc}, expected ${want_rc}. $(head -3 "${WORK}/last.out" | tr '\n' ' ')"
        return
    fi
    if [ "$(grep -c -F -- "$want_str" "${WORK}/last.out")" -lt 1 ]; then
        bad "${label}: exit ${want_rc} was right but the output never says '${want_str}', so the code could be right for the wrong reason. Output: $(tail -3 "${WORK}/last.out" | tr '\n' ' ')"
        return
    fi
    ok "${label}: exit ${want_rc}, naming '${want_str}'"
}

RULE_OK="${WORK}/rule_ok.md"
RULE_NONE="${WORK}/rule_none.md"
RULE_TWO="${WORK}/rule_two.md"

# B1 CURRENT. The green must be reachable, or every red below proves nothing.
mkrepo "${WORK}/current" 0 0 || cannot_run "could not build the current fixture repo"
mkrule x "$RULE_OK" "${WORK}/current"

# The platform split, decided by asking the instrument rather than the OS name.
if find "${WORK}" -maxdepth 0 -flags +dataless >/dev/null 2>&1; then
    HAVE_FLAGS=1
    echo "    eviction instrument: PRESENT (find -flags); the full ladder is asserted"
else
    HAVE_FLAGS=0
    echo "    eviction instrument: ABSENT (this find has no -flags); the checker must REFUSE"
fi
echo

if [ "$HAVE_FLAGS" -eq 1 ]; then
    expect "B1 a current checkout" 0 "GATE: GREEN" "$RULE_OK"
    if [ "$(grep -c 'positive control found 1 of 1' "${WORK}/last.out")" -ge 1 ]; then
        ok "B1a the eviction limb ran its own POSITIVE CONTROL, so its zero is a real absence rather than a dead predicate"
    else
        bad "B1a the eviction limb reported no positive control. A 'find -flags' that matched nothing would report every tree clean, which is the uniform-zero failure this whole row is about."
    fi
    if [ "$(grep -c '^EXAMINED: ' "${WORK}/last.out")" -eq 1 ]; then
        ok "B1b a denominator was printed"
    else
        bad "B1b no EXAMINED line. A verdict with no denominator cannot be audited."
    fi

    # B2 STALE. The defect this row IS.
    mkrepo "${WORK}/stale" 3 0 || cannot_run "could not build the stale fixture repo"
    mkrule x "${WORK}/rule_stale.md" "${WORK}/stale"
    expect "B2 a checkout 3 commits behind" 1 "3 commit(s) behind origin/main" "${WORK}/rule_stale.md"

    # B3 AN ANCIENT REF. The false GREEN the behind-count alone would give: a
    # checkout that never fetches is 0 behind ITS OWN ref forever.
    mkrepo "${WORK}/ancient" 0 90 || cannot_run "could not build the ancient fixture repo"
    mkrule x "${WORK}/rule_ancient.md" "${WORK}/ancient"
    expect "B3 zero behind, but the ref is 90 days old" 1 "day(s) old" "${WORK}/rule_ancient.md"

    # B4 MUST-MISS for B3: an age inside the ceiling must NOT be red, or the
    # age limb would just be a second way of saying no.
    mkrepo "${WORK}/recent" 0 3 || cannot_run "could not build the recent fixture repo"
    mkrule x "${WORK}/rule_recent.md" "${WORK}/recent"
    expect "B4 MUST-MISS: a 3-day-old ref inside the 14-day ceiling is GREEN" 0 "GATE: GREEN" "${WORK}/rule_recent.md"

    # B5 A REGISTER WITH NOTHING IN IT. Every count above still reads clean.
    mkrepo "${WORK}/nocuts" 0 0 || cannot_run "could not build the no-cuts fixture repo"
    rm -rf "${WORK}/nocuts/cuts"
    mkrule x "${WORK}/rule_nocuts.md" "${WORK}/nocuts"
    expect "B5 a checkout with no cuts/ entries" 2 "NO cuts/ directory entries" "${WORK}/rule_nocuts.md"
else
    expect "B1 the eviction limb has no instrument on this host" 2 "no -flags" "$RULE_OK"
    if [ "$(grep -c 'commit(s) behind' "${WORK}/last.out")" -ge 0 ]; then
        ok "B1a the refusal is reported before a verdict, so an unmeasurable limb never reads as a clean one"
    fi
fi

# B6 NOT A GIT REPOSITORY. Platform-independent: reached before the eviction limb.
mkdir -p "${WORK}/plaindir"
mkrule x "${WORK}/rule_plain.md" "${WORK}/plaindir"
expect "B6 a directory that is not a git repository" 2 "not a git repository" "${WORK}/rule_plain.md"

# B7 NO origin/main. "Current" has nothing to be current with.
rm -rf "${WORK}/noremote"; mkdir -p "${WORK}/noremote"
( cd "${WORK}/noremote" && git init -q -b main . && git config user.email t@example.invalid && git config user.name Test && : > f && git add -A && git commit -q -m x )
mkrule x "${WORK}/rule_noremote.md" "${WORK}/noremote"
expect "B7 a repository with no origin/main" 2 "no origin/main ref" "${WORK}/rule_noremote.md"

# B8 NO RULE LINE. The checker must refuse rather than invent a path, which is
# the exact failure #1038 records.
mkrule x "$RULE_NONE" ""
expect "B8 a rule file with no OS003_CHECKOUT line" 2 "no 'OS003_CHECKOUT = <path>' line" "$RULE_NONE"

# B9 TWO RULE LINES. Two declared answers is not one answer.
mkrule x "$RULE_TWO" "${WORK}/current" "${WORK}/stale"
expect "B9 a rule file with two OS003_CHECKOUT lines" 2 "lines in" "$RULE_TWO"

# B10 A PATH THAT IS NOT THERE.
mkrule x "${WORK}/rule_absent.md" "${WORK}/there-is-no-such-tree"
expect "B10 a declared path that does not exist" 2 "no such directory" "${WORK}/rule_absent.md"

# ===========================================================================
# ARM C: ARM A'S OWN PREDICATES, PROVED ABLE TO FAIL
# ===========================================================================
#
# Arm A is four greps over one file. A grep that matches nothing reports every
# file clean, so arm A green could mean "the pointer is sound" or "this reader
# is blind" and they print identically. Each predicate is therefore re-run over
# a MUTATED COPY of the real CLAUDE.md and REQUIRED to flip.
#
# Every mutation states a WITNESS first. A mutation that did not apply looks
# exactly like one that was caught, and an unwitnessed ladder is decoration.

C="${WORK}/claude_mut.md"

# C1 the rule line deleted.
grep -v '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$CLAUDE_MD" > "$C"
if [ "$(grep -c '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$C")" -ne 0 ]; then
    bad "C1: THE MUTATION DID NOT APPLY, so its assertion is not scored."
elif [ "$(grep -c '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$C")" -eq 1 ]; then
    bad "C1: the 'exactly one rule line' predicate still reads 1 after the line was deleted."
else
    ok "C1 rule line deleted: the 'exactly one' predicate flips, so arm A can fail"
fi

# C2 the rule line duplicated.
cp "$CLAUDE_MD" "$C"
grep '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$CLAUDE_MD" >> "$C"
if [ "$(grep -c '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$C")" -ne 2 ]; then
    bad "C2: THE MUTATION DID NOT APPLY (expected 2 rule lines), so its assertion is not scored."
else
    ok "C2 rule line duplicated: the predicate reads 2, so 'two answers' is detectable"
fi

# C3 the evicted path put back. This is the exact regression: somebody restores
# the old sentence and every reader is sent at the silent tree again.
cp "$CLAUDE_MD" "$C"
printf 'read ~/%s - Ostler Release for the register\n' "$EVICTED_PATH_FRAGMENT" >> "$C"
if [ "$(grep -c "$EVICTED_PATH_FRAGMENT" "$C")" -lt 1 ]; then
    bad "C3: THE MUTATION DID NOT APPLY, so its assertion is not scored."
else
    ok "C3 evicted path re-added: the predicate finds it, so arm A's zero is a real absence"
fi

# C4 the checker no longer named.
grep -v -F "$CHECKER_REL" "$CLAUDE_MD" > "$C"
if [ "$(grep -c -F "$CHECKER_REL" "$C")" -ne 0 ]; then
    bad "C4: THE MUTATION DID NOT APPLY, so its assertion is not scored."
else
    ok "C4 checker no longer named: the predicate flips, so 'told how to test it' is a real assertion"
fi

# ===========================================================================
echo
echo "arms scored: ${arms}   failed: ${fails}"
if [ "$fails" -gt 0 ]; then
    echo "RESULT: FAIL, ${fails} of ${arms} arms"
    exit 1
fi
if [ "$arms" -lt 14 ]; then
    echo "RESULT: CANNOT-RUN, only ${arms} arms were scored, expected at least 14."
    echo "        A ladder that scored almost nothing is green in the same way as"
    echo "        one that scored everything."
    exit 2
fi
echo "RESULT: PASS, ${arms} of ${arms} arms"
exit 0
