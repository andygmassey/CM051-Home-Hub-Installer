#!/usr/bin/env bash
# Every surface that tells the customer how long the install takes must tell
# them the same thing, and that thing must not be shorter than the longest
# install we have actually measured.
#
# WHY THIS EXISTS
#   The product has printed four different whole-install durations in one
#   sitting -- "10-15 minutes", "20-40 minutes", "15-60 minutes" and
#   "30 to 60 minutes" -- across install.sh, the strings catalogue and the
#   GUI hint panel. Two separate test limbs each pinned a DIFFERENT figure,
#   so both were green while the customer read three numbers.
#
#   The only end-to-end measurement we hold is the v1.0.33 box walk on a
#   16 GB Mac mini, 2026-08-17: 4083 seconds of recorded step time, 70
#   minutes wall clock, on a machine that had to download everything. Every
#   range above sits BELOW that. So each one was an under-promise the
#   customer catches us on while they are still deciding whether to trust us.
#
#   The 48GB+ tier downloads ~22.7 GB, so its floor is tier-aware (see below).
#   The claim is therefore "45 minutes to a few hours": the floor is
#   download-bound (7.2 GB of models), the ceiling is history-bound.
#
# CONTRACT
#   rc=0  every customer surface states the honest claim and none of them
#         carries a superseded range
#   rc=1  a surface disagrees, or a surface has gone silent
#   rc=2  a surface this gate is supposed to read does not exist
#
# Controls: scripts/tests/test_install_duration_honesty.sh
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The claim, and every range it supersedes. Adding a new range to the product
# without adding it here is the failure mode this gate exists to stop, so the
# refusal list is deliberately a superset of what we have ever shipped.
HONEST='45 minutes to a few hours'
SUPERSEDED='10-15 minutes|10-15 min|10 to 15 minutes|20-40 minutes|20 to 40 minutes|15-60 minutes|15 to 60 minutes|30-60 minutes|30 to 60 minutes'

# label:path. Each is a surface a customer reads with their own eyes.
SURFACES=(
    "install.sh (terminal banner + phase notes):install.sh"
    "the en-GB strings catalogue:install.sh.strings.en-GB.sh"
    "the GUI hint panel:gui/OstlerInstaller/Resources/HintCopy.json"
)

rc=0
missing=0

for entry in "${SURFACES[@]}"; do
    label="${entry%%:*}"
    rel="${entry##*:}"
    path="$ROOT/$rel"

    if [[ ! -f "$path" ]]; then
        printf 'MISSING  %s -- expected a duration surface at %s\n' "$label" "$rel"
        missing=1
        continue
    fi

    # A superseded range anywhere on the surface. Report the line, because
    # "it is somewhere in install.sh" is not an actionable failure for a
    # 20,000-line file.
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        printf 'FAIL  %s carries a superseded install duration: %s:%s\n' \
            "$label" "$rel" "$hit"
        rc=1
    done < <(grep -nE "$SUPERSEDED" "$path" 2>/dev/null)

    # And the honest claim must be PRESENT. Without this limb, deleting the
    # promise entirely reads as a pass -- the surface would simply go quiet
    # and the customer would be told nothing at all.
    if ! grep -qF "$HONEST" "$path"; then
        printf 'FAIL  %s never states the honest whole-install duration "%s" (measured: 70 min, v1.0.33 box walk 2026-08-17)\n' \
            "$label" "$HONEST"
        rc=1
    fi
done

# ── 48GB+ tier: the floor must be priced on the download that tier really
# makes. The estimate comes from the same fit table the picker reads. A tier
# that still prices its download at the old 7.2 GB fails here, and every
# surface must state the tier floor the table computes.
LIB="$ROOT/lib/ostler-model-fit.sh"
MEASURED_48_GB="22.62"   # registry layers, qwen3.6:35b-a3b, 2026-11-13
if [[ ! -f "$LIB" ]]; then
    printf 'MISSING  lib/ostler-model-fit.sh -- the tier estimate cannot be read\n'
    missing=1
else
    tier48_gb="$(bash -c '. "$1" >/dev/null 2>&1; ostler_model_download_gb "$(ostler_recommend_model 48)"' _ "$LIB")"
    tier48_floor="$(bash -c '. "$1" >/dev/null 2>&1; ostler_format_minutes "$(ostler_install_floor_minutes 48)"' _ "$LIB")"
    if [[ -z "$tier48_gb" || -z "$tier48_floor" ]]; then
        printf 'CANNOT RUN  the fit table named no 48GB+ model or no floor\n'
        missing=1
    elif awk -v g="$tier48_gb" -v m="$MEASURED_48_GB" 'BEGIN { exit !((g + 0) < (m + 0)) }'; then
        printf 'FAIL  48GB+ install estimate prices a %s GB download; the measured download is %s GB (lib/ostler-model-fit.sh)\n' \
            "$tier48_gb" "$MEASURED_48_GB"
        rc=1
    else
        for entry in "${SURFACES[@]}"; do
            rel="${entry##*:}"
            if ! grep -qF "$tier48_floor" "$ROOT/$rel" 2>/dev/null; then
                printf 'FAIL  %s does not state the 48GB+ install floor "%s" (the fit table computes it from %s GB)\n' \
                    "$rel" "$tier48_floor" "$tier48_gb"
                rc=1
            fi
        done
    fi
fi

if [[ $missing == 1 ]]; then
    printf 'verify_install_duration_honesty: a surface is absent -- this gate examined fewer files than it claims to cover\n'
    exit 2
fi

if [[ $rc == 0 ]]; then
    printf 'verify_install_duration_honesty: OK -- %d surfaces all state "%s"\n' "${#SURFACES[@]}" "$HONEST"
fi
exit $rc
