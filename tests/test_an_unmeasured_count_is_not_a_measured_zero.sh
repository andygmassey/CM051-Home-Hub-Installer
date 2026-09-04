#!/usr/bin/env bash
# A count the installer never produced must not be recorded as a measured zero
# ===========================================================================
#
# THE INPUT THIS TEST REPLAYS, AND IT IS SELF-INFLICTED
#
# Two correct changes combined into a false statement:
#
#   W012 (#1417)  gave the hydrate zeros a DECLARED reason, e.g.
#                 "ran_ok_no_new_or_enriched_people"
#   #1443         guarded the counters so a failing producer yields "" rather
#                 than aborting the install
#   pre-existing  `${VAR:-0}` on the very next line turns "" into 0
#
# MEASURED before this change, driving the real recorder:
#
#   counter RAN, found nobody   status=no_data detail=ran_ok_no_new_or_enriched_people
#   counter FAILED, guarded     status=no_data detail=ran_ok_no_new_or_enriched_people
#
# Byte-identical, for two materially different runs. The declaration was safe
# only while the count could not be fabricated; the abort guard removed that
# protection. The product then states a cause it did not observe, in a durable
# artefact, with confidence -- worse than the undeclared zero it replaced.
#
# WHAT THIS TEST ASSERTS
#
#   A  The two cases produce DIFFERENT details. This is the whole property.
#   B  POSITIVE CONTROL. The measured-zero case still carries its W012 reason,
#      so the fix cannot be "call everything unmeasured".
#   C  NEGATIVE CONTROL, MUST FAIL IF REMOVED. A site driven with the flag
#      unset behaves as measured -- the flag defaults false, so a source that
#      never sets it is unaffected.
#   D  THE SHARED GLOBAL IS GONE. install.sh:26196 documents why a shared `rc`
#      is wrong ("every hydrate block reassigns it"). The guards must use
#      per-source flags, not one global.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
fatal(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
[ -f "$SUBJECT" ] || fatal "no install.sh at ${SUBJECT}"
_t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${_t%/}/unmeas-XXXXXX")" || fatal "no work dir"
trap 'rm -rf "$WORK"' EXIT

for fn in _hydrate_payload_is_all_zero _hydrate_payload_count _hydrate_compute_change _hydrate_sentinel_record; do
    awk -v fn="$fn" '$0 ~ "^"fn"\\(\\)[[:space:]]*\\{" {i=1} i{print} i&&/^\}/{exit}' "$SUBJECT" > "${WORK}/${fn}.sh"
    [ -s "${WORK}/${fn}.sh" ] || fatal "could not extract ${fn}; this test would measure nothing"
done

# Extract the imessage conditional from the file rather than retyping it: a
# test that retypes the code under test cannot notice the code changing.
S="$(grep -n '_HYDRATE_IMESSAGE_UNMEASURED:-false' "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$S" ] || fatal "no _HYDRATE_IMESSAGE_UNMEASURED conditional in install.sh -- the fix is absent, not merely broken"
E="$(awk -v s="$S" 'NR>s && /^[[:space:]]*fi[[:space:]]*$/ {print NR; exit}' "$SUBJECT")"
[ -n "$E" ] || fatal "could not find the end of the imessage conditional"
sed -n "${S},${E}p" "$SUBJECT" > "${WORK}/site.sh"
bash -n "${WORK}/site.sh" || fatal "the extracted conditional does not parse"

_detail() { # $1 = count, $2 = flag value ("" means leave unset)
    local d="${WORK}/s"; rm -rf "$d"; mkdir -p "$d"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '_HYDRATE_SENTINEL_DIR=%q\n' "$d"
        printf '%s\n' '_HY_ITEM_COUNT=0; _HY_LAST_UPDATE_AT=""'
        for f in "${WORK}"/_hydrate_*.sh; do cat "$f"; done
        printf '_HYDRATE_IMESSAGE_COUNT=%q\n' "$1"
        [ -n "$2" ] && printf '_HYDRATE_IMESSAGE_UNMEASURED=%s\n' "$2"
        cat "${WORK}/site.sh"
    } > "${d}/run.sh"
    bash "${d}/run.sh" >/dev/null 2>&1
    grep -E '^detail=' "${d}/imessage.done" 2>/dev/null | head -1 | cut -d= -f2-
}

D_MEASURED="$(_detail 0 false)"
D_FAILED="$(_detail '' true)"
D_UNSET="$(_detail 0 '')"

[ -n "$D_MEASURED" ] || fatal "the measured case wrote no detail -- the harness did not drive the recorder"

if [ "$D_MEASURED" != "$D_FAILED" ]; then
    ok "A  a failed counter records a DIFFERENT detail (${D_FAILED}) from a measured zero (${D_MEASURED})"
else
    bad "A  a failed counter and a measured zero both record '${D_MEASURED}'. The installer states a cause it did not observe."
fi

case "$D_MEASURED" in
    ran_ok_*) ok "B  positive control: the measured zero keeps its W012 reason (${D_MEASURED})" ;;
    *)        bad "B  the measured zero no longer carries a ran_ok_* reason (${D_MEASURED}); the fix has over-reached into the honest case" ;;
esac

if [ "$D_UNSET" = "$D_MEASURED" ]; then
    ok "C  with the flag unset the site behaves as measured, so a source that never sets it is unaffected"
else
    bad "C  an unset flag changed the detail to '${D_UNSET}'; the default is not false"
fi

N_SHARED="$(grep -c '_HYDRATE_COUNTER_RC' "$SUBJECT" || true)"
if [ "$N_SHARED" -eq 0 ]; then
    ok "D  no shared _HYDRATE_COUNTER_RC global remains (install.sh:26196 documents why)"
else
    bad "D  ${N_SHARED} references to the shared _HYDRATE_COUNTER_RC remain; per-source flags were the point"
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
