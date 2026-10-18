#!/usr/bin/env bash
# scripts/verify_os003_pointer.sh
# ============================================================================
# THE POINTER THAT CANNOT ROT SILENTLY.  CM051 #1038.
#
# CLAUDE.md is read first by every agent, and it says, in bold, to read the
# OS003 release repository before answering ANY question about what ships.
# Until now it named a directory, and a directory is a fact that moves.
#
# MEASURED 2026-09-17 on the operator's machine, which is what makes this a
# defect rather than a tidiness argument:
#
#   ~/Documents/Projects/OS003 - Ostler Release   (what the rule used to name)
#       HEAD c634e0bb, a STRICT ANCESTOR of origin/main, 41 commits behind
#       53 cut directories
#       1,607 iCloud-EVICTED files
#
#   ~/Developer/OS003-Ostler-Release               (what the rule names now)
#       0 commits behind origin/main
#       70 cut directories
#       0 evicted files
#
# Seventeen cuts invisible, and worse: this estate's own doctrine is that an
# evicted file makes grep return NOTHING and return it successfully, which is a
# FALSE ZERO indistinguishable from real absence. So the instruction did not
# only send readers somewhere stale; it sent them somewhere that answers
# questions with silence, and silence is how "the fix is not in the cut" gets
# said out loud with confidence.
#
# WHAT THIS SCRIPT IS FOR, AND WHY IT READS CLAUDE.md RATHER THAN HARD-CODING
#
# Repointing the rule fixes today. It does not stop tomorrow. So the rule now
# carries ONE machine-readable line:
#
#     OS003_CHECKOUT = <path>
#
# and this script resolves THAT line rather than a path of its own. The
# consequence is the point: the checker and the rule cannot drift apart,
# because there is only one of them. Change the rule and the checker follows;
# delete the line and the checker REFUSES rather than falling back to a guess.
#
# THREE STATES, AND THE THIRD ONE IS THE WHOLE REASON THIS EXISTS
#
#   0  GREEN       the resolved checkout is a git repository, current with
#                  origin/main, and readable.
#   1  RED         it resolved, and it is stale or evicted. A wrong register.
#   2  CANNOT-RUN  it could not be measured at all: no rule line, two rule
#                  lines, no such directory, not a git repository, no
#                  origin/main, or no instrument for the eviction limb.
#
# "Current" and "I could not look" print identically otherwise, and this whole
# row exists because a reader could not tell those two apart.
#
# THE EVICTION LIMB AND ITS INSTRUMENT
#
# macOS marks an iCloud-evicted file with the `dataless` flag, and `find
# -flags` is the instrument that reads it. GNU find has no `-flags` at all. A
# host without the instrument cannot answer the question, so this script says
# CANNOT-RUN there rather than reporting a clean run it never performed. On
# Darwin the limb is paired with a POSITIVE CONTROL: a file the script itself
# marks with an unrelated flag must be FOUND by the same predicate shape, or a
# zero from the dataless query is a statement about the reader.
#
# Usage:   scripts/verify_os003_pointer.sh [checkout-dir]
#   $1                 an explicit directory to judge (used by the tests)
#   $OS003_DIR         an operator override
#   CLAUDE.md          the declared default, and the authority
#
#   $OS003_RULE_FILE   which file carries the rule (tests point it at fixtures)
#
# British English throughout. No em dashes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RULE_FILE="${OS003_RULE_FILE:-${REPO_ROOT}/CLAUDE.md}"

red()        { printf 'GATE: RED -- %s\n' "$1" >&2; }
cannot_run() {
    printf 'GATE: CANNOT-RUN -- %s\n' "$1" >&2
    printf '      Nothing was established about the release register. This is\n' >&2
    printf '      NOT a pass: "current" and "I could not look" are different\n' >&2
    printf '      findings and only one of them is safe to act on.\n' >&2
    exit 2
}

echo "os003-pointer: the canonical-checkout rule, measured rather than trusted"
echo "  rule file: ${RULE_FILE}"

# ---------------------------------------------------------------------------
# 1. THE RULE LINE. Exactly one, or refuse.
#
# Zero means the rule has been deleted or reworded and this checker is now
# guarding nothing. Two means there are two answers and the script would pick
# one by accident. Neither is a state in which a verdict means anything.
# ---------------------------------------------------------------------------
[ -r "${RULE_FILE}" ] || cannot_run "rule file is not readable: ${RULE_FILE}"

RULE_HITS="$(grep -c '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "${RULE_FILE}")"
RULE_HITS="${RULE_HITS:-0}"
echo "  OS003_CHECKOUT lines found: ${RULE_HITS}"
if [ "${RULE_HITS}" -eq 0 ]; then
    cannot_run "no 'OS003_CHECKOUT = <path>' line in ${RULE_FILE}. The rule this
      checker exists to follow is gone, so following it would mean inventing a
      path, and an invented path is exactly what #1038 was."
fi
if [ "${RULE_HITS}" -gt 1 ]; then
    cannot_run "${RULE_HITS} 'OS003_CHECKOUT = <path>' lines in ${RULE_FILE}. Two
      declared answers is not one answer; this script would silently take the
      first and the reader would never know which."
fi

DECLARED="$(grep '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "${RULE_FILE}" \
            | head -1 \
            | sed -e 's/^[[:space:]]*OS003_CHECKOUT[[:space:]]*=[[:space:]]*//' \
                  -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//')"
[ -n "${DECLARED}" ] || cannot_run "the OS003_CHECKOUT line declares an empty path"
echo "  rule declares: ${DECLARED}"

# ---------------------------------------------------------------------------
# 2. RESOLVE. Argument beats operator override beats the declared default.
# ---------------------------------------------------------------------------
TARGET="${1:-${OS003_DIR:-${DECLARED}}}"
case "${TARGET}" in
    "~/"*) TARGET="${HOME}/${TARGET#\~/}" ;;
esac
echo "  resolved to:   ${TARGET}"

[ -d "${TARGET}" ] || cannot_run "no such directory: ${TARGET}"

command -v git >/dev/null 2>&1 || cannot_run "no git on PATH"
git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1 \
    || cannot_run "not a git repository: ${TARGET}"
git -C "${TARGET}" rev-parse --verify --quiet origin/main >/dev/null 2>&1 \
    || cannot_run "no origin/main ref in ${TARGET}, so 'current' has nothing to
      be current WITH. Fetch it, or point the rule at a checkout that has one."

# ---------------------------------------------------------------------------
# 3. STALENESS. Commits on origin/main that this checkout does not have.
#
# NOT `git status`, and NOT a fetch. A fetch would HIDE a stale checkout by
# curing it mid-measurement, and this gate's job is to report the state the
# reader would actually have met.
# ---------------------------------------------------------------------------
BEHIND="$(git -C "${TARGET}" rev-list --count HEAD..origin/main 2>/dev/null)"
case "${BEHIND}" in
    ''|*[!0-9]*) cannot_run "could not count commits behind origin/main in ${TARGET}" ;;
esac

# 3b. AND HOW OLD THE REF IT WAS JUDGED AGAINST IS.
#
# `behind` is measured against this checkout's OWN remote-tracking ref, which
# is only as fresh as its last fetch. Measured while writing this: the evicted
# checkout reported 35 behind ITS origin/main while being 41 behind the real
# one. The error direction is safe there, but the dangerous case is the same
# mechanism with the count at zero: a checkout that has not fetched for a month
# reports "0 behind" and reads as current. A green computed against a ref
# nobody refreshed is the same false confidence in a new costume.
#
# So the ref's own age is measured and printed, and an ancient one is RED. No
# fetch happens here by default: a gate that reaches the network is slow and
# flaky, and fetching would CURE the staleness mid-measurement instead of
# reporting the state the reader would actually have met. `--fetch` is the
# explicit opt-in.
if [ "${1:-}" = "--fetch" ] || [ "${2:-}" = "--fetch" ]; then
    echo "  --fetch given: refreshing origin/main before judging"
    git -C "${TARGET}" fetch --quiet origin main 2>/dev/null \
        || cannot_run "--fetch was asked for and failed against ${TARGET}"
    BEHIND="$(git -C "${TARGET}" rev-list --count HEAD..origin/main 2>/dev/null)"
    case "${BEHIND}" in
        ''|*[!0-9]*) cannot_run "could not re-count commits behind origin/main after --fetch" ;;
    esac
fi
REF_EPOCH="$(git -C "${TARGET}" log -1 --format=%ct origin/main 2>/dev/null)"
case "${REF_EPOCH}" in
    ''|*[!0-9]*) cannot_run "could not read the commit date of origin/main in ${TARGET}" ;;
esac
NOW_EPOCH="$(date -u +%s)"
REF_AGE_DAYS=$(( ( NOW_EPOCH - REF_EPOCH ) / 86400 ))
MAX_REF_AGE_DAYS="${OS003_POINTER_MAX_REF_AGE_DAYS:-14}"
echo "  origin/main tip: $(git -C "${TARGET}" log -1 --format='%h %cI' origin/main 2>/dev/null) (${REF_AGE_DAYS} day(s) old, ceiling ${MAX_REF_AGE_DAYS})"
CUTS=0
[ -d "${TARGET}/cuts" ] && CUTS="$(ls -1 "${TARGET}/cuts" 2>/dev/null | grep -c . )"
CUTS="${CUTS:-0}"

# ---------------------------------------------------------------------------
# 4. EVICTION. An unreadable file is a false zero wearing the clothes of a
#    real absence, and this repo has already lost a day to that.
# ---------------------------------------------------------------------------
EVICTED="not-measured"
TOTAL_FILES="$(find "${TARGET}" -type f 2>/dev/null | grep -c . )"
TOTAL_FILES="${TOTAL_FILES:-0}"

if find "${TARGET}" -maxdepth 0 -flags +dataless >/dev/null 2>&1; then
    # POSITIVE CONTROL FIRST, and on the same corpus shape. A `find -flags`
    # that silently matched nothing would report every tree clean, which is the
    # uniform-zero failure this estate keeps re-learning. So mark a file the
    # script owns with an unrelated flag and require the same predicate shape
    # to FIND it. A control taken after the measurement would be a control for
    # a different run.
    _ctl="$(mktemp -d)"
    : > "${_ctl}/canary"
    chflags nodump "${_ctl}/canary" 2>/dev/null
    _ctl_hits="$(find "${_ctl}" -type f -flags +nodump 2>/dev/null | grep -c . )"
    rm -rf "${_ctl}"
    if [ "${_ctl_hits:-0}" -ne 1 ]; then
        cannot_run "the eviction instrument failed its own positive control:
      a file marked with a flag was NOT found by 'find -flags' (${_ctl_hits:-0} of 1).
      A zero from the dataless query would then be a statement about the reader
      rather than about the tree."
    fi
    EVICTED="$(find "${TARGET}" -type f -flags +dataless 2>/dev/null | grep -c . )"
    EVICTED="${EVICTED:-0}"
    echo "  eviction instrument: find -flags (positive control found 1 of 1 flagged file)"
else
    cannot_run "this host's find has no -flags, so the eviction limb has no
      instrument. macOS marks an iCloud-evicted file 'dataless', and an evicted
      file makes grep return nothing AND return it successfully. A freshness
      verdict that cannot see eviction is not a verdict, so this refuses rather
      than reporting a limb it never ran."
fi

echo "EXAMINED: ${CUTS} cut directorie(s), ${BEHIND} commit(s) behind origin/main, ${EVICTED} of ${TOTAL_FILES} file(s) evicted"

# ---------------------------------------------------------------------------
# 5. VERDICT.
# ---------------------------------------------------------------------------
problems=0
if [ "${BEHIND}" -gt 0 ]; then
    red "${TARGET} is ${BEHIND} commit(s) behind origin/main."
    printf '      It holds %s cut directorie(s). Every cut merged since its HEAD is\n' "${CUTS}" >&2
    printf '      INVISIBLE to anyone who reads it as the release register, and the\n' >&2
    printf '      answer they will give is "not in the cut" rather than "I am reading\n' >&2
    printf '      a stale register". Pull it, or repoint OS003_CHECKOUT in %s.\n' "${RULE_FILE##*/}" >&2
    problems=$(( problems + 1 ))
fi
if [ "${REF_AGE_DAYS}" -gt "${MAX_REF_AGE_DAYS}" ]; then
    red "${TARGET} was judged against an origin/main tip that is ${REF_AGE_DAYS} day(s) old."
    printf '      "%s commit(s) behind" is measured against THAT ref, so it is only as\n' "${BEHIND}" >&2
    printf '      fresh as this checkout last fetch. Either OS003 has been quiet for\n' >&2
    printf '      over %s days or nobody has fetched here; both are states in which a\n' "${MAX_REF_AGE_DAYS}" >&2
    printf '      low behind-count means nothing. Re-run with --fetch.\n' >&2
    problems=$(( problems + 1 ))
fi
if [ "${EVICTED}" -gt 0 ]; then
    red "${TARGET} holds ${EVICTED} evicted file(s) of ${TOTAL_FILES}."
    printf '      grep reads NOTHING from an evicted file and exits 0, so every search\n' >&2
    printf '      of this tree can return a FALSE ZERO that looks exactly like real\n' >&2
    printf '      absence. Rehydrate it, or repoint OS003_CHECKOUT at a tree that is\n' >&2
    printf '      not cloud-evicted.\n' >&2
    problems=$(( problems + 1 ))
fi
if [ "${problems}" -gt 0 ]; then
    exit 1
fi

# ANTI-VACUITY. Zero cut directories means the register is not there at all,
# and every count above would still read clean.
if [ "${CUTS}" -eq 0 ]; then
    cannot_run "${TARGET} holds NO cuts/ directory entries. A register with
      nothing in it satisfies every count above while answering no question,
      which is the shape of a green that examined nothing."
fi

echo "GATE: GREEN -- ${TARGET} is current with origin/main, holds ${CUTS} cut(s), and has no evicted files."
exit 0
