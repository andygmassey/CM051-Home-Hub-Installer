#!/usr/bin/env bash
# A productive iMessage run must not report an UNDECLARED zero (W012)
# ==================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# v1.0.63 walk 2. Doctor showed:
#
#     imessage  status=no_data  detail=zero_payload_undeclared  item_count=0
#
# The truth on that box: 10 conversations and 15,345 messages were ingested.
# people_created + people_enriched came to 0 because all 13 contacts were
# ALREADY known from Contacts. The run worked; the product said it produced
# nothing, and the person who read it as a bug was the author of the spec.
#
# WHY THE SENTINEL DID NOT SAY SO
#
# `_hydrate_sentinel_record` takes a THIRD argument, empty_reason, and writes
# `detail=${empty_reason:-zero_payload_undeclared}` when the payload is
# all-zero. The design distinguishes a zero we can explain from one we cannot.
# The iMessage call site passes only two arguments, so every explainable zero
# there is recorded as unexplained. 13 of 14 call sites are in that position;
# this test covers the one the walk caught.
#
# WHAT IS DELIBERATELY NOT FIXED HERE, AND WHY
#
# The honest repair is for the STATUS to be `ok`, not for the detail to read
# better: a run that ingested 15,345 messages did not produce "no data".
# `_hydrate_payload_is_all_zero` returns false as soon as any numeric field is
# non-zero, so a payload carrying conversation and message counts would report
# status=ok on its own. Those counts are NOT AVAILABLE to install.sh --
# `ostler_fda.pwg_ingest.ingest_imessage` returns only status, people_created
# and people_enriched. (`total_conversations`/`total_messages` exist on
# `ostler_fda/imessage.py`, a different function that is not the one wired in.)
# Making the status true requires the VENDORED ingest to report volume, and a
# vendored file's fix direction is upstream. This test therefore pins the
# reachable half -- the zero is declared -- and does not pretend the status is
# fixed.
#
# WHAT THIS TEST ASSERTS
#
#   A   ORIGINAL FAILING INPUT. Drive the REAL _hydrate_sentinel_record with
#       the REAL iMessage payload shape and a zero count. detail must NOT be
#       `zero_payload_undeclared`.
#   B   POSITIVE CONTROL, MUST BE PRESENT. A NON-zero people count still
#       records status=ok. Without this, a "fix" that stamps a declared reason
#       unconditionally would pass A while breaking every successful run.
#   C   ARCHIE'S CONTROL 3 -- THE DISTINCTION MUST SURVIVE. A box with
#       genuinely nothing goes through `_hydrate_sentinel_record_no_data
#       "imessage" "no_export_json"`, which must still record status=no_data
#       with ITS OWN reason. Declared-zero and genuinely-absent must stay
#       different rows, or the fix has deleted the distinction it restores.
#   D   NO UNDECLARED ZERO SURVIVES ON THIS PATH. The literal
#       `zero_payload_undeclared` must not appear in either sentinel written
#       by the iMessage legs above.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

FAILURES=0; PASSES=0
fatal() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
pass()  { PASSES=$((PASSES+1)); printf '  PASS  %s\n' "$1"; }
red()   { FAILURES=$((FAILURES+1)); printf '  RED   %s\n' "$1"; }

[[ -f "$INSTALL_SH" ]] || fatal "install.sh not found at ${INSTALL_SH}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/w012-XXXXXX")" || fatal "could not create a work dir"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Extract the REAL recorder functions. Premise-guarded: an extractor that
# silently returns nothing would make every assertion below a measurement of
# the extractor rather than of the product.
# ---------------------------------------------------------------------------
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}
for fn in _hydrate_payload_is_all_zero _hydrate_payload_count _hydrate_compute_change \
          _hydrate_sentinel_record _hydrate_sentinel_record_no_data; do
    extract_fn "$fn" "$INSTALL_SH" > "${WORK}/${fn}.sh"
    [[ -s "${WORK}/${fn}.sh" ]] || fatal "could not extract ${fn} from install.sh. This test would be measuring nothing."
    bash -n "${WORK}/${fn}.sh" || fatal "extracted ${fn} does not parse. Extraction is broken, not the code."
done
grep -q 'zero_payload_undeclared' "${WORK}/_hydrate_sentinel_record.sh" \
    || fatal "the extracted recorder does not contain zero_payload_undeclared -- extraction hit the wrong function."

# The iMessage call lines, taken from install.sh itself rather than retyped:
# a test that retypes the line under test cannot detect the line changing.
# Continuation-aware ON PURPOSE. A first version of this used plain `grep`
# and took only the first physical line. When the fix put the third argument
# after a `\`, the harness silently drove a TWO-argument call and reported the
# defect as still present -- a green fix reading as red, and it would equally
# have read a broken fix as fixed had the polarity gone the other way. A test
# that cannot see a line continuation is measuring its own parser. Same
# blindness as #647, where a path inside a loop body is invisible to the
# wiring gate.
join_call() {
    awk -v pat="$1" '
        $0 ~ pat && $0 !~ /^[[:space:]]*#/ { buf = $0
            while (buf ~ /\\$/) { sub(/\\$/, "", buf); getline nxt; sub(/^[[:space:]]+/, " ", nxt); buf = buf nxt }
            print buf; exit }
    ' "$2"
}
SUCCESS_CALL="$(join_call '^[[:space:]]*_hydrate_sentinel_record "imessage" ' "$INSTALL_SH")"
ABSENT_CALL="$(join_call '^[[:space:]]*_hydrate_sentinel_record_no_data "imessage" ' "$INSTALL_SH")"
[[ -n "$SUCCESS_CALL" ]] || fatal "no _hydrate_sentinel_record \"imessage\" call found in install.sh"
[[ -n "$ABSENT_CALL"  ]] || fatal "no _hydrate_sentinel_record_no_data \"imessage\" call found in install.sh"
case "$SUCCESS_CALL" in *\\) fatal "the joined iMessage call still ends in a continuation -- the joiner did not consume it, and every assertion below would measure a truncated call" ;; esac
printf 'Harness: extracted 5 recorder functions and both iMessage call lines (continuations joined) from real install.sh.\n'
printf 'Harness: call under test -> %s\n\n' "$SUCCESS_CALL"

run_case() {
    # $1 = _HYDRATE_IMESSAGE_COUNT, $2 = which call line, $3 = sentinel dir
    local count="$1" call="$2" dir="$3"
    mkdir -p "$dir"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '_HYDRATE_SENTINEL_DIR=%q\n' "$dir"
        printf '_HYDRATE_IMESSAGE_COUNT=%q\n' "$count"
        printf '%s\n' '_HY_ITEM_COUNT=0; _HY_LAST_UPDATE_AT=""'
        cat "${WORK}/_hydrate_payload_is_all_zero.sh" "${WORK}/_hydrate_payload_count.sh" \
            "${WORK}/_hydrate_compute_change.sh" "${WORK}/_hydrate_sentinel_record.sh" \
            "${WORK}/_hydrate_sentinel_record_no_data.sh"
        printf '%s\n' "$call"
    } > "${dir}/drive.sh"
    bash "${dir}/drive.sh" >"${dir}/out.txt" 2>"${dir}/err.txt"
}

field() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# --- A: the original failing input -----------------------------------------
run_case 0 "$SUCCESS_CALL" "${WORK}/a"
SA="${WORK}/a/imessage.done"
if [[ ! -f "$SA" ]]; then
    fatal "no sentinel was written for the zero case (rc/err: $(head -2 "${WORK}/a/err.txt" 2>/dev/null)). The harness did not drive the recorder."
fi
DET_A="$(field "$SA" detail)"; ST_A="$(field "$SA" status)"
if [[ "$DET_A" == "zero_payload_undeclared" ]]; then
    red "A  a zero people-count records detail=zero_payload_undeclared. The run may have ingested thousands of messages and the product says it produced nothing. This is W012."
elif [[ -z "$DET_A" ]]; then
    red "A  the zero case recorded NO detail at all -- worse than undeclared, since Doctor has nothing to render"
else
    pass "A  the zero is DECLARED: status=${ST_A} detail=${DET_A}"
fi

# --- B: positive control ---------------------------------------------------
run_case 7 "$SUCCESS_CALL" "${WORK}/b"
SB="${WORK}/b/imessage.done"
if [[ -f "$SB" && "$(field "$SB" status)" == "ok" ]]; then
    pass "B  positive control: a non-zero people count still records status=ok"
else
    red "B  positive control FAILED: a non-zero count recorded status=$(field "$SB" status) -- the fix has broken successful runs, and A above cannot be trusted"
fi

# --- C: Archie's control 3 -- the distinction must survive -----------------
run_case 0 "$ABSENT_CALL" "${WORK}/c"
SC="${WORK}/c/imessage.done"
ST_C="$(field "$SC" status)"; DET_C="$(field "$SC" detail)"
if [[ "$ST_C" == "no_data" && "$DET_C" == "no_export_json" ]]; then
    if [[ "$DET_C" != "$DET_A" ]]; then
        pass "C  genuinely-absent still records status=no_data detail=${DET_C}, and it is DISTINCT from the declared-zero detail (${DET_A})"
    else
        red "C  genuinely-absent and declared-zero now record the SAME detail (${DET_C}) -- the fix deleted the distinction it exists to restore"
    fi
else
    red "C  the genuinely-absent path recorded status=${ST_C} detail=${DET_C}, expected no_data/no_export_json"
fi

# --- D: no undeclared zero survives on either iMessage leg -----------------
if grep -l 'zero_payload_undeclared' "$SA" "$SC" >/dev/null 2>&1; then
    red "D  'zero_payload_undeclared' still appears in a sentinel written by an iMessage leg"
else
    pass "D  no iMessage leg writes an undeclared zero"
fi

# --- E: the CLASS. No new source may file an unexplained zero ---------------
# iMessage was 1 of 14 call sites passing no empty_reason. Six of the others
# could reach the all-zero arm and are now declared. The rest cannot reach it,
# and each is listed here WITH THE REASON, because "it is fine" that nobody
# wrote down is indistinguishable from "nobody checked".
#
#   contacts / calendar / ai_conversations : guarded by `-gt 0`, so the
#       recorder is only reached with a non-zero count.
#   dedupe / places / privacy_backfill     : payload is `ran=1,rc=...`.
#       _hydrate_payload_is_all_zero returns false on the first non-zero
#       numeric field, so the zero arm is structurally unreachable.
#
# A NEW undeclared call site fails this arm. That is the point: the defect was
# never one line, it was a call site convention nobody enforced.
EXEMPT="contacts calendar ai_conversations dedupe places privacy_backfill"
UNDECLARED="$(awk '
    /_hydrate_sentinel_record "/ && !/^[[:space:]]*#/ {
        buf = $0
        while (buf ~ /\\$/) { sub(/\\$/, "", buf); getline nxt; sub(/^[[:space:]]+/, " ", nxt); buf = buf nxt }
        src = buf; sub(/^[^"]*"/, "", src); sub(/".*$/, "", src)
        n = gsub(/"[^"]*"/, "", buf)
        if (n < 3) print src
    }' "$INSTALL_SH" | sort -u)"
UNEXPECTED=""
for src in $UNDECLARED; do
    case " $EXEMPT " in *" $src "*) ;; *) UNEXPECTED="${UNEXPECTED:+$UNEXPECTED }$src" ;; esac
done
# Premise guard: if the scan finds nothing at all it has stopped working, and
# an empty result would render as a clean pass.
TOTAL_SITES="$(grep -cE '^[[:space:]]*_hydrate_sentinel_record "' "$INSTALL_SH")"
if [[ "$TOTAL_SITES" -lt 5 ]]; then
    fatal "the call-site scan found only ${TOTAL_SITES} sites -- it is not reading install.sh, and arm E would pass by finding nothing"
fi
if [[ -n "$UNEXPECTED" ]]; then
    red "E  call site(s) file an UNEXPLAINED zero and are not on the exempt list: ${UNEXPECTED}. Either pass a reason naming what the site MEASURED, or add it to EXEMPT with why its zero arm is unreachable."
else
    pass "E  class guard: ${TOTAL_SITES} call sites scanned, every undeclared one is exempt with a recorded reason"
fi

printf '\n'
printf 'CONCLUSION HISTOGRAM\n'
printf '  PASS : %d\n' "$PASSES"
printf '  RED  : %d\n' "$FAILURES"
printf '  TOTAL: %d\n' "$((PASSES + FAILURES))"
[[ $FAILURES -eq 0 ]] || exit 1
exit 0
