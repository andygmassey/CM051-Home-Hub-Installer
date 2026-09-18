#!/bin/bash
# CM051 #957. THE INSTALLER FOUND SEVEN EXPORTS, TOLD THE CUSTOMER SEVEN, AND
# IMPORTED ONE.
#
# EXPORTS_DIR is assigned at five detector sites as "${EXPORTS_DIR:-...}",
# which is first-write-wins by design: it is the value the summary line and
# the step-count logic print. The importer was then seeded from that ONE
# value, so every export root after the first was detected, counted, shown,
# and never read. Failure mode: BUILT WITH NO CONSUMER. The detector had one,
# and it was a display loop.
#
# This test drives the SHIPPED block out of install.sh rather than a copy of
# it, because a re-implementation here would pass forever while install.sh
# regressed. If the block cannot be extracted the test reports CANNOT-RUN and
# exits 2; it never reports a pass it did not measure.
#
# WHY /bin/bash AND NOT bash: install.sh runs on a customer Mac under
# /bin/bash 3.2.57. The block uses "${arr[@]:-}" under set -u, whose empty
# array behaviour is exactly the kind of thing bash 5 forgives and 3.2 does
# not.
#
# HAS IT EVER FAILED: yes, on purpose, every run. ARM 9 rebuilds the pre-fix
# one-line block and asserts the case-1 predicate goes RED on it. A green ARM
# 9 means the mutant did not apply and the other arms prove nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: ${INSTALL} is not readable."; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BLOCK="${WORK}/block.sh"

awk '/^# #957: EVERY detected root/,/^unset _root _known _seen$/' "$INSTALL" > "$BLOCK"
BLOCK_LINES="$(grep -c . "$BLOCK" || true)"
if [ "${BLOCK_LINES:-0}" -lt 10 ]; then
    echo "CANNOT-RUN: extracted only ${BLOCK_LINES:-0} lines from install.sh."
    echo "            The #957 block's start or end marker has moved; fix the"
    echo "            awk range above rather than deleting this test."
    exit 2
fi
echo "EXAMINED: ${BLOCK_LINES} lines of SHIPPED install.sh (the #957 block)"

# The pre-fix block, rebuilt from what git blame shows main did: EXPORTS_DIR
# and nothing else. ARM 9 runs the same predicate against it.
MUTANT="${WORK}/mutant.sh"
printf '%s\n' '[[ -n "${EXPORTS_DIR:-}" && -d "${EXPORTS_DIR}" ]] && _IMPORT_DIRS+=("$EXPORTS_DIR")' > "$MUTANT"

HOME_FAKE="${WORK}/home"
mkdir -p "${HOME_FAKE}/Downloads/Basic_LinkedInDataExport" \
         "${HOME_FAKE}/Desktop/instagram_export" \
         "${HOME_FAKE}/Documents/twitter_archive"

INFO_LOG="${WORK}/info.log"

# run <block> <exports_dir> [roots...]  -> prints one _IMPORT_DIRS entry per line
# DECLINED is the recorded answer to the import prompt: set it to 1 in the
# caller to run a case as though the person said no.
DECLINED=0
run() {
    local blk="$1" xd="$2"; shift 2
    : > "$INFO_LOG"
    HOME="$HOME_FAKE" EXPORTS_DIR="$xd" OSTLER_957_INFO="$INFO_LOG" \
    IMPORT_DECLINED="$DECLINED" \
    /bin/bash -c '
        set -Eeuo pipefail
        info() { printf "%s\n" "$*" >> "$OSTLER_957_INFO"; }
        DETECTED_EXPORT_ROOTS=("$@")
        _IMPORT_DIRS=()
        . "'"$blk"'"
        printf "%s\n" "${_IMPORT_DIRS[@]:-}"
    ' _ "$@"
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; return 0; }

L="${HOME_FAKE}/Downloads/Basic_LinkedInDataExport"
I="${HOME_FAKE}/Desktop/instagram_export"
T="${HOME_FAKE}/Documents/twitter_archive"

echo
echo "ARM 1-4: every distinct root reaches the importer, in order, once"
out="$(run "$BLOCK" "$L" "$L" "$I" "$T")"; rc=$?
n="$(printf '%s\n' "$out" | grep -c . || true)"
[ "$rc" -eq 0 ] || no "(0) the block exited $rc under set -Eeuo pipefail" "$out"
[ "$n" -eq 3 ] && ok "(1) all THREE distinct roots reach the importer" \
                || no "(1) $n root(s) reached the importer, expected 3" "$out"
printf '%s\n' "$out" | grep -qx -- "$I" && ok "(2) a root that is NOT the first-detected one is imported" \
                || no "(2) the second root was dropped: that IS the #957 defect" "$out"
d="$(printf '%s\n' "$out" | sort | uniq -d | grep -c . || true)"
[ "$d" -eq 0 ] && ok "(3) EXPORTS_DIR also appearing in the roots array is added once, not twice" \
                || no "(3) $d duplicate root(s)" "$out"
[ "$(printf '%s\n' "$out" | head -1)" = "$L" ] && ok "(4) EXPORTS_DIR stays FIRST, so importer order is unchanged" \
                || no "(4) first entry was '$(printf '%s\n' "$out" | head -1)', expected $L"

echo
echo "ARM 5-7: the edges, and the strict-subset guarantee"
out="$(run "$BLOCK" "$L")"
[ "$(printf '%s\n' "$out" | grep -c . || true)" -eq 1 ] \
    && ok "(5) CONTROL: an EMPTY roots array does exactly what main did" || no "(5)" "$out"
# CONSENT, ON THE EXACT BRANCH WHERE THE FIRST DRAFT WAS WRONG. The decline
# empties EXPORTS_DIR, and install.sh's iCloud-contacts block then REFILLS it
# to ${OSTLER_DIR}/imports for any customer who has an icloud-contacts.vcf.
# So at the point of import, a declined install has a NON-EMPTY EXPORTS_DIR,
# and a guard that tested emptiness could not fire on the path it was written
# for. This arm runs that branch: declined, EXPORTS_DIR refilled, roots full.
REFILLED="${HOME_FAKE}/.ostler/imports"; mkdir -p "$REFILLED"
DECLINED=1
out="$(run "$BLOCK" "$REFILLED" "$I" "$T")"
DECLINED=0
printf '%s\n' "$out" | grep -qx -- "$I" \
    && no "(6) a DECLINED import was carried out anyway, on the refilled-EXPORTS_DIR branch" "$out" \
    || ok "(6) a declined import reaches the importer with none of the detected roots"
[ "$(printf '%s\n' "$out" | grep -c . || true)" -eq 1 ] \
    && ok "(6b) the refilled EXPORTS_DIR is still passed, exactly as main does it" \
    || no "(6b) this changed what main does on the declined-with-vcf path" "$out"
out="$(run "$BLOCK" "$REFILLED" "$I" "$T")"
[ "$(printf '%s\n' "$out" | grep -c . || true)" -eq 3 ] \
    && ok "(6c) CONTROL: the SAME inputs NOT declined import all three, so arm 6 measures consent" \
    || no "(6c) the control case did not import 3, so arm 6 may be passing for another reason" "$out"
out="$(run "$BLOCK" "$L" "${WORK}/never-existed")"
printf '%s\n' "$out" | grep -qx -- "${WORK}/never-existed" \
    && no "(7) a NON-EXISTENT root was handed to the importer" "$out" \
    || ok "(7) a non-existent root is refused, so a stale detection cannot break the import"

echo
echo "ARM 8: CX-126, a whole scan tree is refused as an EXTRA root and SAID OUT LOUD"
out="$(run "$BLOCK" "$L" "${HOME_FAKE}/Downloads")"
printf '%s\n' "$out" | grep -qx -- "${HOME_FAKE}/Downloads" \
    && no "(8a) the whole of ~/Downloads was handed to the importer to rglob" "$out" \
    || ok "(8a) a root equal to a scan root is refused (CX-126 measured a multi-minute stall)"
grep -q 'Not importing the whole of' "$INFO_LOG" \
    && ok "(8b) the refusal is on the customer's install log, not silent" \
    || no "(8b) the root was dropped with no line of output" "$(cat "$INFO_LOG")"
out="$(run "$BLOCK" "${HOME_FAKE}/Downloads")"
printf '%s\n' "$out" | grep -qx -- "${HOME_FAKE}/Downloads" \
    && ok "(8c) EXPORTS_DIR is EXEMPT: what main already imports is unchanged" \
    || no "(8c) this change altered what main imports, so it is not a strict superset" "$out"
[ -s "$INFO_LOG" ] \
    && no "(8d) the exempt case still printed a refusal the customer would not understand" "$(cat "$INFO_LOG")" \
    || ok "(8d) the exempt case prints nothing, because nothing was refused"

echo
echo "ARM 9: THE MUTANT. The pre-fix block must FAIL the arm-1 predicate."
out="$(run "$MUTANT" "$L" "$L" "$I" "$T")"
n="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$n" -eq 3 ]; then
    no "(9) the pre-fix block ALSO imported 3 roots, so arms 1-4 prove nothing"
else
    ok "(9) the pre-fix block imported $n of 3, which is the defect this test detects"
fi

echo
echo "ARM 10: the block cannot abort install.sh, which runs set -Eeuo pipefail"
abort_probe() {
    HOME="$HOME_FAKE" OSTLER_957_INFO="$INFO_LOG" /bin/bash -c '
        set -Eeuo pipefail
        info() { :; }
        EXPORTS_DIR=""
        DETECTED_EXPORT_ROOTS=()
        _IMPORT_DIRS=()
        . "'"$1"'"
        echo REACHED_THE_END
    ' 2>/dev/null
}
[ "$(abort_probe "$BLOCK")" = "REACHED_THE_END" ] \
    && ok "(10) an empty EXPORTS_DIR and empty roots do not abort the install" \
    || no "(10) the block aborted under set -e: install.sh would stop here"
ctl="${WORK}/ctl.sh"; printf 'false\n' > "$ctl"
[ "$(abort_probe "$ctl")" = "REACHED_THE_END" ] \
    && no "(10-CONTROL) the abort probe cannot see an abort, so arm 10 proves nothing" \
    || ok "(10-CONTROL) the probe DOES see an abort when the block returns non-zero"

echo
echo "ARM 11: the decline site clears the roots array, where consent is withdrawn"
# The GUI prompt cannot be driven here, so this arm reads the source. It is
# paired with arm 6, which measures the same property as BEHAVIOUR on the
# shipped block, so neither edit alone can let a declined import through.
DECLINE="$(awk '/IMPORT_CONFIRM:-y.*==.*"n"/,/^    fi$/' "$INSTALL")"
if [ -z "$DECLINE" ]; then
    no "(11) could not find the decline branch in install.sh: re-point this arm"
else
    printf '%s\n' "$DECLINE" | grep -qF 'DETECTED_EXPORT_ROOTS=()' \
        && ok "(11) the decline branch empties DETECTED_EXPORT_ROOTS, not only EXPORTS_DIR" \
        || no "(11) the decline empties EXPORTS_DIR and leaves the roots array full" "$DECLINE"
    printf '%s\n' "$DECLINE" | grep -qF 'IMPORT_DECLINED=1' \
        && ok "(11a) the decline RECORDS the answer, so nothing downstream has to infer it" \
        || no "(11a) the answer is not recorded, so a downstream guard must reconstruct it" "$DECLINE"
    # Recording only beats inferring while the record cannot be forged. Two
    # writes are legitimate: the 0 that binds it under set -u, and the 1 at
    # the prompt. A third means something else can answer for the person.
    W="$(grep -c '^[[:space:]]*IMPORT_DECLINED=' "$INSTALL" || true)"
    [ "$W" -eq 2 ] \
        && ok "(11b) IMPORT_DECLINED is written in exactly 2 places: the init and the prompt" \
        || no "(11b) IMPORT_DECLINED is written in $W places, so the consent record can be overwritten" \
             "$(grep -n '^[[:space:]]*IMPORT_DECLINED=' "$INSTALL")"
    printf '%s\n' "$DECLINE" | grep -qF 'EXPORTS_DIR=""' \
        && ok "(11-CONTROL) the extracted branch IS the decline: it clears EXPORTS_DIR too" \
        || no "(11-CONTROL) the awk range caught the wrong block, so arm 11 proves nothing" "$DECLINE"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
