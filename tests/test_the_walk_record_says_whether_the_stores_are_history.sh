#!/usr/bin/env bash
#
# THE WALK RECORD MUST SAY WHETHER THE STORES IT MEASURED ARE HISTORY.
#
# ttywalk.sh's reset step already says it, in its own output:
#
#   "the graph, the vectors and the compiled wiki are CARRIED OVER from the
#    previous install. Any probe reading them is measuring history, not this
#    artefact."
#
# MEASURED 2026-09-05: that sentence was printed by the reset and repeated
# NOWHERE downstream. 0 mentions across scripts/box_walk_probes/,
# post_walk_qa.sh and verify_walk_record.sh, against a control of 24 of 24
# probes naming probe_cannot_run. So a red from no_person_holds_two_contact_cards
# or people_stores_reconcile reached the record, and reached a promote decision,
# with nothing anywhere to say whether it described the DMG or the box's past.
#
# WHAT THIS ASSERTS
#   1. post_walk_qa.sh emits exactly ONE stores_provenance row into the record
#   2. an absent or unrecognised marker is recorded as unknown(...), NEVER as a
#      clean value -- driven through the real case block, not a paraphrase
#   3. ttywalk.sh writes the marker on BOTH arms of the uninstaller search, so
#      "we wiped" and "we did not" are different recorded facts
#   4. the config step CONSUMES the run file rather than reading it in place, so
#      a walk with no --reset cannot inherit the previous walk's answer
#   5. verify_walk_record.sh surfaces the field, so a refusal names it
#
# EXIT CODES. 0 every arm held; 1 a writer or reader misbehaved; 2 the anchors
# moved and nothing was measured.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="${ROOT}/scripts/post_walk_qa.sh"
TW="${ROOT}/scripts/ttywalk.sh"
VR="${ROOT}/scripts/verify_walk_record.sh"
STRIP="${ROOT}/scripts/lib/strip_comments.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
cannot() { printf '\nCANNOT-RUN: %s\n' "$1" >&2
           printf '  Nothing was measured. Re-point the anchors; do not delete the arms.\n' >&2
           exit 2; }

for f in "$QA" "$TW" "$VR"; do
    [ -f "$f" ] || cannot "missing ${f}"
done

# Comments must not vouch for code. Every count below is taken from the stripped
# text, and the control is that stripping does not empty the file.
strip() {
    if [ -x "$STRIP" ]; then /bin/bash "$STRIP" "$1"; else grep -v '^[[:space:]]*#' "$1"; fi
}
QA_CODE="$(strip "$QA")"
TW_CODE="$(strip "$TW")"
[ "$(printf '%s' "$QA_CODE" | grep -c .)" -gt 100 ] \
    || cannot "stripping comments left post_walk_qa.sh with almost nothing; the stripper or the file changed shape"
ok "CONTROL: comment-stripped post_walk_qa.sh still has $(printf '%s' "$QA_CODE" | grep -c .) code lines"

# --- 1. exactly one emitted row --------------------------------------------
n="$(printf '%s\n' "$QA_CODE" | grep -c "printf 'stores_provenance")"
case "$n" in
    1) ok "post_walk_qa.sh emits stores_provenance into the record (1 site, comments stripped)" ;;
    0) bad "post_walk_qa.sh emits NO stores_provenance row. A record that cannot say whether the stores are history presents carried-over data as evidence about the DMG." ;;
    *) bad "post_walk_qa.sh emits ${n} stores_provenance rows; the record would carry a duplicate key" ;;
esac

# --- 2. the unknown paths, driven through the REAL case block ---------------
# Lifted from the file rather than retyped, so a paraphrase here cannot pass
# while the writer drifts. Anchored on the case head and its esac.
CASEBLOCK="$(awk '/^    case "\$STORES_PROVENANCE" in$/{f=1} f{print} f&&/^    esac$/{exit}' "$QA")"
[ -n "$CASEBLOCK" ] || cannot "could not lift the STORES_PROVENANCE case block out of post_walk_qa.sh"

drive() {  # drive <raw marker value> -> the normalised value
    STORES_PROVENANCE="$1" /bin/bash -c "
        set -u
        STORES_PROVENANCE=\"\${STORES_PROVENANCE}\"
$CASEBLOCK
        printf '%s' \"\$STORES_PROVENANCE\""
}

check() {  # check <label> <input> <expected-prefix>
    local got; got="$(drive "$2")"
    case "$got" in
        "$3"*) ok "$1 -> ${got:0:52}" ;;
        *)     bad "$1 -> '${got}', expected something starting '${3}'" ;;
    esac
}
check "an absent marker"          ""                                   "unknown("
check "an unrecognised value"     "FileDoesntExistWillCreate"           "unknown("
check "carried over"              "carried-over-from-previous-install"  "carried-over-from-previous-install"
check "wiped by the uninstaller"  "wiped-by-shipped-uninstaller(~/.ostler/bin/x)" "wiped-by-shipped-uninstaller"
check "no reset step ran"         "unknown-no-reset-step"              "unknown-no-reset-step"

# --- 3. ttywalk writes BOTH arms -------------------------------------------
for arm in 'wiped-by-shipped-uninstaller' 'carried-over-from-previous-install' 'unknown-no-reset-step'; do
    if [ "$(printf '%s\n' "$TW_CODE" | grep -c -- "$arm")" -gt 0 ]; then
        ok "ttywalk.sh can record '${arm}'"
    else
        bad "ttywalk.sh never writes '${arm}'; that state would be indistinguishable from the others"
    fi
done

# --- 4. the run file is CONSUMED, not read in place -------------------------
if [ "$(printf '%s\n' "$TW_CODE" | grep -c 'mv ~/.walk-stores-provenance-run ~/.walk-stores-provenance')" -gt 0 ]; then
    ok "the config step MOVES the run file, so a walk with no --reset cannot inherit the previous walk's answer"
else
    bad "the run file is not moved. Read in place, a stale value from the last walk would be recorded as this one's."
fi

# --- 5. the reader surfaces it ---------------------------------------------
if [ "$(grep -c 'stores_provenance' "$VR")" -gt 0 ]; then
    ok "verify_walk_record.sh names stores_provenance, so a refusal can say which box state it describes"
else
    bad "verify_walk_record.sh never mentions stores_provenance; the field would be written and never read"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
