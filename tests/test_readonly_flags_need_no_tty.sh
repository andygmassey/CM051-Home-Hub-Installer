#!/usr/bin/env bash
# tests/test_readonly_flags_need_no_tty.sh
# ============================================================================
# Every READ-ONLY flag must work without a controlling terminal.
#
# WHY THIS FILE EXISTS
# ────────────────────
# 2026-08-26, measured on a real box while box-walking v1.0.47. install.sh
# redirects stdin from /dev/tty so that `curl | bash` can still ask questions.
# The comment above that redirect says, correctly:
#
#     "Skip for read-only flags so they work in non-interactive contexts."
#
# It listed SHOW_HELP and SHOW_LICENSES. It did NOT list CHECK_ONLY. So
# `--check` -- the flag whose entire documented purpose is
#     "Phase 1: Check prerequisites (automatic, no input)"
#     "--check verifies prerequisites only and needs no licence"
# died on the spot in any context without a pty:
#
#     no pty : rc=1, one line -- "install.sh: line 697: /dev/tty: Device not configured"
#     pty    : rc=0, 19 lines -- the full prerequisite report
#
# That is the pre-purchase compatibility check, unusable over ssh or from any
# script, on every build that has ever shipped.
#
# HOW THIS TESTS IT
# ─────────────────
# It EXTRACTS THE REAL CONDITION from install.sh and evaluates it, rather than
# restating the rule in a copy that can drift. It also cross-checks the flag
# list against the argument parser, so adding a fourth read-only flag without
# adding it to the guard is a RED here rather than a defect discovered on a
# customer's Mac.
#
# Run: bash tests/test_readonly_flags_need_no_tty.sh
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILURES=0

fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  ok    %s\n' "$1"; }

[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: no readable $INSTALL_SH"; exit 2; }

# ── Extract the real guard line. Anchored on the line that PRECEDES the
# ── redirect, so this cannot silently test some other `if`.
GUARD_LINE_NO=$(grep -n 'exec < /dev/tty' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [ -z "$GUARD_LINE_NO" ]; then
    echo "CANNOT-RUN: no 'exec < /dev/tty' in install.sh -- the redirect this test"
    echo "  guards has moved or gone. Re-point the test rather than deleting it."
    exit 2
fi
GUARD=$(sed -n "$((GUARD_LINE_NO - 1))p" "$INSTALL_SH")
case "$GUARD" in
    if\ \[\[*\]\]\;\ then) : ;;
    *) echo "CANNOT-RUN: line before the redirect is not the expected 'if [[ ... ]]; then'"
       echo "  got: $GUARD"
       exit 2 ;;
esac
printf 'EXAMINED: guard at install.sh:%s\n  %s\n\n' "$((GUARD_LINE_NO - 1))" "$GUARD"

# Strip `if ` and `; then` to leave a bare `[[ ... ]]` we can evaluate.
COND=${GUARD#if }
COND=${COND%; then}

# ── The read-only flags, taken FROM THE PARSER, not from memory. A flag the
# ── parser knows about but this test does not would otherwise go unnoticed.
#
# 🔴 NO mapfile, NO \s. MEASURED ON THE SHELL THAT RUNS THIS.
#
# The first draft used `mapfile -t PARSED_FLAGS < <(grep -oE '^\s*--...')`.
# Both halves are wrong on the host that matters:
#   - `mapfile` is a bash 4 builtin. install.sh runs under /bin/bash, which is
#     3.2.57 on macOS, and the cut host and the macos runner are both 3.2. It
#     dies with "mapfile: command not found".
#   - `\s` is a GNU grep extension. /usr/bin/grep on macOS is BSD.
#
# What made it dangerous rather than merely broken: with `set -uo pipefail` and
# no `set -e`, the failure did not stop the run. Under bash 3.2 the test printed
# FIVE ok lines, its EXAMINED denominator line vanished, and ARM 4 -- the arm
# that exists to catch a fourth read-only flag added six months from now -- never
# executed. Under bash 5 on the same tree it was fully green. A test that reports
# five passes while its most valuable assertion is dead is worse than no test.
#
# So: POSIX character classes, a plain space-delimited string instead of an
# array, and an explicit refusal if the scan comes back empty.
PARSED_FLAGS=" $(
    /usr/bin/grep -oE '^[[:space:]]*--[a-z|-]+\)[[:space:]]*[A-Z_]+=true' "$INSTALL_SH" \
    | /usr/bin/grep -oE '[A-Z_]+=true' | cut -d= -f1 | sort -u | tr '\n' ' '
)"
PARSED_N=0
for _pf in $PARSED_FLAGS; do PARSED_N=$((PARSED_N + 1)); done
if [ "$PARSED_N" -eq 0 ]; then
    echo "CANNOT-RUN: found NO '--flag) FLAG=true' lines in install.sh's parser."
    echo "  Either the parser has been restructured or this pattern is stale."
    echo "  An empty flag list would make ARM 4 vacuous, and a vacuous arm reads"
    echo "  identically to a passing one. Re-point the pattern. Not a pass."
    exit 2
fi
printf 'EXAMINED: %s boolean flag(s) set by the parser:%s\n\n' \
    "$PARSED_N" "$PARSED_FLAGS"

# ── ARM 1: each read-only flag must SKIP the /dev/tty redirect when stdin is
# ── not a terminal. This is the customer-visible property.
READONLY=(CHECK_ONLY SHOW_HELP SHOW_LICENSES)
for flag in "${READONLY[@]}"; do
    CHECK_ONLY=false; SHOW_HELP=false; SHOW_LICENSES=false
    printf -v "$flag" '%s' true
    export OSTLER_GUI=0
    # `< /dev/null` makes `! -t 0` true, i.e. exactly the non-interactive case.
    if eval "$COND" < /dev/null; then
        fail "$flag=true still takes the /dev/tty redirect -- it will die with"
        printf '        "/dev/tty: Device not configured" anywhere without a pty\n'
    else
        pass "$flag=true skips the redirect (works without a tty)"
    fi
done

# ── ARM 2: THE POSITIVE CONTROL. With no read-only flag, a non-interactive
# ── stdin MUST still take the redirect -- otherwise the guard is simply
# ── disabled and ARM 1 would pass for the wrong reason.
CHECK_ONLY=false; SHOW_HELP=false; SHOW_LICENSES=false
export OSTLER_GUI=0
if eval "$COND" < /dev/null; then
    pass "CONTROL: a real install with no tty still redirects (guard is live)"
else
    fail "CONTROL FAILED: the guard never fires, so ARM 1 proves nothing."
fi

# ── ARM 3: OSTLER_GUI=1 must skip it too -- the GUI feeds stdin itself.
CHECK_ONLY=false; SHOW_HELP=false; SHOW_LICENSES=false
export OSTLER_GUI=1
if eval "$COND" < /dev/null; then
    fail "OSTLER_GUI=1 still redirects -- the GUI installer supplies its own stdin"
else
    pass "OSTLER_GUI=1 skips the redirect"
fi
export OSTLER_GUI=0

# ── ARM 4: every read-only flag the PARSER knows must appear in the guard.
# ── This is what catches a fourth flag added six months from now.
for flag in "${READONLY[@]}"; do
    case "$PARSED_FLAGS" in
        *" $flag "*) : ;;
        *) fail "$flag is in this test's read-only list but the parser never sets it -- one of the two is stale" ;;
    esac
    case "$COND" in
        *"$flag"*) pass "$flag is named in the guard condition" ;;
        *) fail "$flag is NOT named in the guard condition at install.sh:$((GUARD_LINE_NO - 1))" ;;
    esac
done

# ── ARM 5: THE RATCHET. ARM 4 walks READONLY and checks each entry reaches the
# ── guard. That direction cannot see a flag added to the PARSER that nobody
# ── classified -- and "a fourth flag added six months from now" is the whole
# ── reason ARM 4 exists.
#
# Mutation-proved: adding `--dry-run) DRY_RUN=true ;;` to the parser left this
# test GREEN with only ARM 4 present. The EXAMINED line dutifully printed
# "5 boolean flag(s)" and nothing acted on it. A denominator nobody asserts on
# is decoration.
#
# Whether a new flag is read-only is a JUDGEMENT -- NO_EXTENSIONS is a real
# install and must keep the redirect; CHECK_ONLY must not. So this does not
# guess. It pins the known set and refuses when it changes, naming the delta.
KNOWN_FLAGS=" CHECK_ONLY NO_EXTENSIONS SHOW_HELP SHOW_LICENSES "
for _pf in $PARSED_FLAGS; do
    case "$KNOWN_FLAGS" in
        *" $_pf "*) : ;;
        *) fail "NEW PARSER FLAG '$_pf' -- nobody has classified it."
           printf '        If it is read-only (prints and exits), add it to READONLY *and* to\n'
           printf '        the guard at install.sh:%s, or it dies without a tty. If it performs a\n' "$((GUARD_LINE_NO - 1))"
           printf '        real install, add it to KNOWN_FLAGS only. Do not silence this by\n'
           printf '        deleting the arm.\n' ;;
    esac
done
for _kf in $KNOWN_FLAGS; do
    case "$PARSED_FLAGS" in
        *" $_kf "*) : ;;
        *) fail "'$_kf' is pinned in KNOWN_FLAGS but the parser no longer sets it -- stale pin" ;;
    esac
done
pass "ratchet: parser flag set matches the classified set ($PARSED_N flag(s))"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS -- all three read-only flags work without a controlling terminal,"
    echo "       the guard still fires for a real install, and no unclassified"
    echo "       parser flag has appeared."
    exit 0
fi
echo "FAIL -- $FAILURES assertion(s) failed."
exit 1
