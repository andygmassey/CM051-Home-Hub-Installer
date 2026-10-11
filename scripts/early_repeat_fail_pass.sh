#!/usr/bin/env bash
# scripts/early_repeat_fail_pass.sh
# ============================================================================
# THE EARLY PASS: re-ask the previous walk's FAILED probes, read-only, minutes
# after the install finishes, so a repeat failure shows at the top of the walk
# and not at the end of it.
#
#   scripts/early_repeat_fail_pass.sh --host user@box [--walks-dir DIR]
#                                     [--prev-record FILE] [--runner PATH]
#
# IT DECIDES NOTHING. Its output is labelled EARLY PASS, it writes no
# walks/*.tsv, it is not read by the walk verdict, and the full walk that
# follows is unchanged. Exit status is informational: 0 always, except 2 for a
# usage error. ttywalk.sh must not fold it into WALK_VERDICT.
#
# WHERE THE PREVIOUS FAILURES COME FROM: the newest walks/v*.tsv (version
# sort). Its `failed_probe` rows are the names; `failed_probe_names_recorded`
# says "N of M", and the M-N unnamed ones are reported, not dropped.
#
# THREE OUTCOMES PER PROBE, never two:
#   EARLY PASS / EARLY FAIL   the probe ran read-only and answered.
#   CANNOT-RUN (early)        it did not run, with the reason. Never silent.
#
# WHAT IT REFUSES TO RUN, AND SAYS SO:
#   - a name with no probes/<name>.sh (phase 2 row, renamed, deleted)
#   - a seed-dependent probe (needs the seed, which is a write). The list is
#     read from SEED_DEPENDENT_PROBES in run_box_walk.sh so there is one list.
#   If that list cannot be read, every probe is CANNOT-RUN (early): running a
#   seed-dependent probe unseeded would manufacture a FAIL.
#
# NO WRITES: run_box_walk.sh --read-only skips every seed and kickstart, and
# the environment clears OSTLER_PHASE1_VERDICTS / OSTLER_BOX_WALK_EVIDENCE_DIR
# so nothing lands in a record. Order inside the runner is untouched, so the
# pairing reader still runs before the pairing mutator.
#
# BASH 3.2 (macOS). No associative arrays, no mapfile, no `timeout`.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
HOST=""
WALKS_DIR="${REPO_ROOT}/walks"
PREV_RECORD=""
RUNNER="${HERE}/box_walk_probes/run_box_walk.sh"
BUDGET_S="${OSTLER_EARLY_PASS_BUDGET_S:-900}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)        HOST="${2:-}"; shift 2 ;;
        --walks-dir)   WALKS_DIR="${2:-}"; shift 2 ;;
        --prev-record) PREV_RECORD="${2:-}"; shift 2 ;;
        --runner)      RUNNER="${2:-}"; shift 2 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$HOST" ] || { printf 'usage: --host user@box is required\n' >&2; exit 2; }

say() { printf '%s\n' "$*"; }
BAR="------------------------------------------------------------"
say "$BAR"
say "EARLY PASS (read-only re-check of the previous walk's FAILED probes)"
say "NOT PART OF THE WALK VERDICT. NOT RECORDED. The full walk below decides."
say "$BAR"

cannot_all() {  # $1 = reason
    say "CANNOT-RUN (early): $1"
    say "EARLY PASS RESULT: CANNOT-RUN, nothing was re-checked."
    say "$BAR"
    exit 0
}

# -- 1. find the previous walk's evidence file ------------------------------
if [ -z "$PREV_RECORD" ]; then
    [ -d "$WALKS_DIR" ] || cannot_all "no walks directory at ${WALKS_DIR}"
    PREV_RECORD=""
    for f in $(ls "$WALKS_DIR" 2>/dev/null | grep -E '^v?[0-9]+(\.[0-9]+)*\.tsv$' | sort -V); do
        PREV_RECORD="${WALKS_DIR}/${f}"   # last one wins = newest version
    done
    [ -n "$PREV_RECORD" ] || cannot_all "no walks/v*.tsv record in ${WALKS_DIR} (0 files examined)"
fi
[ -f "$PREV_RECORD" ] && [ -r "$PREV_RECORD" ] || cannot_all "previous walk record is missing or unreadable: ${PREV_RECORD}"
say "previous walk record: ${PREV_RECORD}"

VERDICT="$(awk -F'\t' '$1=="verdict"{print $2; exit}' "$PREV_RECORD")"
NAMES_REC="$(awk -F'\t' '$1=="failed_probe_names_recorded"{print $2; exit}' "$PREV_RECORD")"
NAMES="$(awk -F'\t' '$1=="failed_probe"{print $2}' "$PREV_RECORD")"
[ -n "$VERDICT" ] || cannot_all "${PREV_RECORD} has no verdict row, so it is not a walk record this pass can read"
say "previous verdict: ${VERDICT}; failed names recorded: ${NAMES_REC:-<no row>}"

# unnamed remainder, from "N of M"
UNNAMED=0
case "$NAMES_REC" in
    *" of "*)
        _n="${NAMES_REC%% of *}"; _m="${NAMES_REC##* of }"
        case "$_n$_m" in *[!0-9]*|'') ;; *) [ "$_m" -gt "$_n" ] && UNNAMED=$((_m - _n)) ;; esac ;;
esac

NCOUNT=0
for n in $NAMES; do NCOUNT=$((NCOUNT + 1)); done
if [ "$NCOUNT" -eq 0 ]; then
    case "$VERDICT" in
        CLEAN|PASS|PASSED)
            say "EARLY PASS RESULT: previous walk was ${VERDICT} with 0 failed probes, nothing to repeat."
            say "$BAR"; exit 0 ;;
        *)
            cannot_all "previous verdict is ${VERDICT} but the record names 0 failed probes (${NAMES_REC:-no count row}); cannot tell what to repeat" ;;
    esac
fi
[ "$UNNAMED" -gt 0 ] && say "CANNOT-RUN (early): ${UNNAMED} failure(s) in the previous walk are not named in its record, so they cannot be re-checked"

# -- 2. split into runnable / not -------------------------------------------
SEED_LIST=""
if [ -r "$RUNNER" ]; then
    SEED_LIST="$(sed -n 's/^SEED_DEPENDENT_PROBES="\(.*\)"$/\1/p' "$RUNNER" | head -1)"
fi
PROBE_DIR="$(dirname "$RUNNER")/probes"

RUN_LIST=""
for n in $NAMES; do
    if [ ! -f "${PROBE_DIR}/${n}.sh" ]; then
        say "CANNOT-RUN (early) ${n}: no probe of that name in the box walk (a phase 2 row, or renamed)"
    elif [ -z "$SEED_LIST" ]; then
        say "CANNOT-RUN (early) ${n}: could not read SEED_DEPENDENT_PROBES from ${RUNNER}, so cannot tell whether it needs the seed"
    else
        case " $SEED_LIST " in
            *" $n "*) say "CANNOT-RUN (early) ${n}: seed-dependent, and the seed is a write; the full walk measures it" ;;
            *) RUN_LIST="${RUN_LIST:+$RUN_LIST,}${n}" ;;
        esac
    fi
done

if [ -z "$RUN_LIST" ]; then
    say "EARLY PASS RESULT: no previous failure could be re-checked read-only."
    say "$BAR"; exit 0
fi
[ -x "$RUNNER" ] || [ -f "$RUNNER" ] || cannot_all "runner missing: ${RUNNER}"

# -- 3. run them, read-only, into a private verdicts file -------------------
VFILE="$(mktemp)"; OUTF="$(mktemp)"
trap 'rm -f "$VFILE" "$OUTF"' EXIT
say "re-checking read-only: ${RUN_LIST}"
say "budget: ${BUDGET_S}s; people probes wait at most ${OSTLER_EARLY_CONVERGE_WAIT_S:-120}s for the graph to settle, else CANNOT-RUN"

RC=0
# --read-only is explicit even though --only implies it. The two env -u keep
# this pass out of any evidence the full walk's post_walk_qa collects.
# OSTLER_PHASE1_VERDICTS is set to OUR private file to read per-probe verdicts.
if command -v perl >/dev/null 2>&1; then
    OSTLER_BOX_HOST="$HOST" OSTLER_PHASE1_VERDICTS="$VFILE" \
    OSTLER_CONVERGE_WAIT_S="${OSTLER_EARLY_CONVERGE_WAIT_S:-120}" \
    env -u OSTLER_BOX_WALK_EVIDENCE_DIR \
    perl -e 'alarm shift; exec @ARGV' "$BUDGET_S" bash "$RUNNER" --read-only --only "$RUN_LIST" > "$OUTF" 2>&1 || RC=$?
else
    OSTLER_BOX_HOST="$HOST" OSTLER_PHASE1_VERDICTS="$VFILE" \
    OSTLER_CONVERGE_WAIT_S="${OSTLER_EARLY_CONVERGE_WAIT_S:-120}" \
    env -u OSTLER_BOX_WALK_EVIDENCE_DIR \
    bash "$RUNNER" --read-only --only "$RUN_LIST" > "$OUTF" 2>&1 || RC=$?
fi
sed 's/^/  early| /' "$OUTF"

# -- 4. per-probe verdicts --------------------------------------------------
REPEATS=0; ANSWERED=0
for n in $(printf '%s' "$RUN_LIST" | tr ',' ' '); do
    row="$(awk -F'\t' -v w="$n" '$1==w{v=$2; r=$4} END{if(v!="")printf "%s\t%s", v, r}' "$VFILE")"
    v="${row%%	*}"; r="${row#*	}"
    case "$v" in
        PASS|ADVISORY) say "EARLY PASS ${n}: ${v}"; ANSWERED=$((ANSWERED + 1)) ;;
        FAIL)          say "EARLY FAIL ${n}: REPEAT FAILURE. ${r}"; REPEATS=$((REPEATS + 1)); ANSWERED=$((ANSWERED + 1)) ;;
        CANNOT-RUN)    say "CANNOT-RUN (early) ${n}: ${r}" ;;
        BROKEN)        say "CANNOT-RUN (early) ${n}: BROKEN, failed its own negative control" ;;
        *)             say "CANNOT-RUN (early) ${n}: no verdict reached (runner rc=${RC}); see the early| lines above" ;;
    esac
done
say "EARLY PASS RESULT: ${REPEATS} repeat failure(s) of ${ANSWERED} answered (runner rc=${RC}). Not a verdict."
say "$BAR"
exit 0
