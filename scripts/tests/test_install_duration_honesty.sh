#!/usr/bin/env bash
# Prove verify_install_duration_honesty.sh FIRES, on each surface, in both
# directions.
#
# The defect this guards was NOT "one file said the wrong number". It was that
# two green test limbs pinned two DIFFERENT numbers, so the product printed
# four durations in one sitting and every gate said fine. So the controls that
# matter are per-surface: a stale range on the strings catalogue must fail even
# when install.sh is perfect, and vice versa. A gate that only checks one
# surface would have passed the tree that shipped v1.0.33.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify_install_duration_honesty.sh"
PASS=0; FAIL=0; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

HONEST='45 minutes to a few hours'
# The 48GB+ floor: 22.7 GB download, scaled from the 7.2 GB baseline (150 min).
T48='2 hours 30 minutes'
LIBSRC="$(cd "$(dirname "$GATE")/.." && pwd)/lib/ostler-model-fit.sh"

# Build a throwaway tree carrying all three surfaces, each honest, plus the
# real fit table so the gate prices the 48GB+ tier from the same table.
mkroot(){
    local d="$1"; rm -rf "$d"
    mkdir -p "$d/gui/OstlerInstaller/Resources" "$d/lib"
    cp "$LIBSRC" "$d/lib/ostler-model-fit.sh"
    printf 'echo "installs automatically (~%s; 48GB+: %s)"\n' "$HONEST" "$T48" > "$d/install.sh"
    printf 'MSG_X="the install can run %s; 48GB+: %s"\n' "$HONEST" "$T48" > "$d/install.sh.strings.en-GB.sh"
    printf '{ "subtitle": "Roughly %s", "why": "48GB+: %s" }\n' "$HONEST" "$T48" > "$d/gui/OstlerInstaller/Resources/HintCopy.json"
}
rc(){ bash "$GATE" "$1" >"$TMP/o" 2>&1; echo $?; }

# ── Control 1: the happy tree is green. A gate that cries wolf on a correct
#    tree gets switched off, which is how the last one died.
mkroot "$TMP/happy"
[[ "$(rc "$TMP/happy")" == 0 ]] && ok "all three surfaces honest -> rc=0" || no "correct tree wrongly failed"

# ── Controls 2-4: a superseded range on EACH surface, one at a time, with the
#    other two left correct. This is the case the old split gates missed.
for surface in "install.sh" "install.sh.strings.en-GB.sh" "gui/OstlerInstaller/Resources/HintCopy.json"; do
    mkroot "$TMP/stale"
    printf '\n# regression: 15-60 minutes\n' >> "$TMP/stale/$surface"
    if [[ "$(rc "$TMP/stale")" == 1 ]]; then
        ok "stale range in $surface alone -> rc=1"
        grep -q "$surface" "$TMP/o" \
            && ok "  and the failure NAMES $surface" \
            || no "  failure did not name the file it measured"
    else
        no "stale range in $surface NOT caught"
    fi
done

# ── Controls 5-7: deleting the promise must not read as a pass. Absence of a
#    wrong number is not presence of a right one.
for surface in "install.sh" "install.sh.strings.en-GB.sh" "gui/OstlerInstaller/Resources/HintCopy.json"; do
    mkroot "$TMP/silent"
    : > "$TMP/silent/$surface"
    [[ "$(rc "$TMP/silent")" == 1 ]] \
        && ok "$surface goes silent -> rc=1" \
        || no "$surface silence read as a PASS (the zero-denominator trap)"
done

# ── Control 8: every superseded range this product has ever printed is
#    refused, not just the most recent one.
for range in "10-15 minutes" "20-40 minutes" "15-60 minutes" "30 to 60 minutes" "10 to 15 minutes"; do
    mkroot "$TMP/hist"
    printf '\n# %s\n' "$range" >> "$TMP/hist/install.sh"
    [[ "$(rc "$TMP/hist")" == 1 ]] \
        && ok "refuses the historical range \"$range\"" \
        || no "historical range \"$range\" slipped through"
done

# ── Control 9: a missing surface is rc=2, NOT rc=0. A gate that examines two
#    files and reports OK is claiming a coverage it does not have.
mkroot "$TMP/gone"; rm -f "$TMP/gone/gui/OstlerInstaller/Resources/HintCopy.json"
[[ "$(rc "$TMP/gone")" == 2 ]] \
    && ok "absent surface -> rc=2, distinct from both pass and fail" \
    || no "absent surface did not produce the dedicated rc=2"

# ── Control 10: the 48GB+ estimate must not still be priced on 7.2 GB. The
#    fit table says the 48GB+ tier downloads 7.2 GB; the gate must go RED.
mkroot "$TMP/est72"
printf '\nOSTLER_MODEL_SIZELBL[0]="~7.2 GB"\n' >> "$TMP/est72/lib/ostler-model-fit.sh"
[[ "$(rc "$TMP/est72")" == 1 ]] && grep -q "48GB+ install estimate prices a 7.2 GB" "$TMP/o" \
    && ok "48GB+ estimate still priced at 7.2 GB -> rc=1, names the 7.2 GB" \
    || no "48GB+ estimate priced at 7.2 GB was NOT caught"

# ── Control 11: every surface must state the 48GB+ floor. Drop it from one.
mkroot "$TMP/no48"
printf '{ "subtitle": "Roughly %s" }\n' "$HONEST" > "$TMP/no48/gui/OstlerInstaller/Resources/HintCopy.json"
[[ "$(rc "$TMP/no48")" == 1 ]] && grep -q "HintCopy.json does not state the 48GB+" "$TMP/o" \
    && ok "a surface missing the 48GB+ floor -> rc=1, names the file" \
    || no "a surface missing the 48GB+ floor was NOT caught"

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "ALL INSTALL-DURATION CONTROLS PASSED"
