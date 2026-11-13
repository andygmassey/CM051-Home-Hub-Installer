#!/usr/bin/env bash
# test_model_download_size_honesty.sh -- the advertised AI model download size
# must not be smaller than the size we have actually measured.
#
# WHY THIS EXISTS (v1061-D002, register #623)
#   install.sh told the customer the AI model download was "~5 GB". Measured on
#   the v1.0.61 walk box it is 7.2 GB. That is a 44% understatement of the
#   largest single download in the install, printed at the exact moment the
#   customer decides whether to continue on a metered or slow link.
#
#   The number was never measured. It was INFERRED from the resident weight
#   size (lib/ostler-model-fit.sh's weights_gb column, which was documented as
#   "download ~ same"). That inference is false for an effective-parameter
#   build, where the full parameter set is downloaded but only a subset is
#   resident. A label derived from a footprint is not a download size.
#
#   The repo already held the true figure in three places -- install.sh's own
#   comments ("a 7.2 GB model", "7 GB model pull ... on a 16 GB box") and
#   scripts/verify_install_duration_honesty.sh, which prices the whole-install
#   floor on "7.2 GB of models". Only the customer-facing label still said 5.
#   The lie survived because nothing compared the two.
#
#   #625 names download honesty as a CLASS, not an instance. This gate is the
#   instrument for the class: it binds the advertised figure to a measured
#   floor and binds the two independent copies of that figure to each other.
#
# WHAT IT ASSERTS
#   1. The download label for the model a 16 GB box is given must not be below
#      the measured floor.
#   2. install.sh's fallback ladder (the stripped-bundle path) must state the
#      SAME figure as lib/ostler-model-fit.sh. Two editable copies of one
#      customer claim drift, and the fallback path is the one nobody walks.
#   3. No customer-facing "N-M GB" downloaded-models range in install.sh may
#      start below the measured floor.
#
# CONTRACT
#   rc=0  every advertised size is at or above what we measured, and the two
#         copies of the figure agree
#   rc=1  a surface understates the download, or the two copies disagree
#   rc=2  CANNOT RUN -- a surface this gate must read is absent, or a scan
#         found nothing to examine (a blind pattern is not a pass)
#
# Controls run FIRST and are inline: each limb is fired against a synthetic
# pre-fix fixture in a temp dir and must go RED. A limb that cannot be shown to
# fail proves nothing when it passes. The fixtures never enter the repo.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── The measured floor ────────────────────────────────────────────────
# 7.2 GB, measured on the box during the v1.0.61 walk (2026-09-03) rather than
# read off a spec. Corroborated inside this repo by install.sh's own pull
# comments and by scripts/verify_install_duration_honesty.sh, which prices the
# install duration floor on the same figure.
#
# RAISE THIS, NEVER LOWER IT, and only against a NEW measurement on a box. If a
# future model tag genuinely downloads less, the honest move is to record that
# measurement here with its date and box -- not to relax the floor so a
# convenient label passes.
#
# 16 GB tier moved from gemma4:e2b (the 7.2 GB above) to qwen3.5:4b, a different
# tag with a NEW measurement, which is the case the paragraph above provides
# for. Measured for the Ollama install.sh pins (0.34.0, GGUF build): the
# registry manifest for qwen3.5:4b is byte-identical to
# docs/model-pins/ollama-0.34.0/qwen3.5_4b.json (the on-disk manifest of a
# clean pull) and its layers sum to 3,324,173,757 bytes = 3.32 GB.
MEASURED_FLOOR_GB="3.3"
FLOOR_PROVENANCE="qwen3.5:4b, clean pull under the pinned Ollama 0.34.0, layers 3.32 GB, 2026-10-19 (was 7.2 GB for gemma4:e2b, v1.0.61 walk box)"

# The tier the floor was measured on. A 16 GB Mac is the installer's hard RAM
# floor (ERR-02-PREREQ-RAM-LOW), so this is the smallest -- and therefore
# cheapest-to-download -- model the product ever ships.
MEASURED_TIER_RAM_GB=16

# The 48 GB+ tier, measured the same way on 2026-11-13 from the REGISTRY
# manifest for qwen3.6:35b-a3b (no blob download): the layers sum to
# 22,621,314,161 bytes = 22.62 GB, a GGUF build (format "gguf", runner
# "llamacpp") whose manifest is byte-identical in config and layers to the
# on-disk manifest the pinned Ollama 0.34.0 wrote on a clean pull,
# docs/model-pins/ollama-0.34.0/qwen3.6_35b-a3b.json (pins_0340 evidence,
# 2026-10-18). Advertised label "~22.7 GB" rounds the measurement UP.
MEASURED_FLOOR_48_GB="22.62"
FLOOR_48_PROVENANCE="qwen3.6:35b-a3b, registry manifest layers 22,621,314,161 bytes = 22.62 GB, GGUF, pinned Ollama 0.34.0, 2026-11-13"
MEASURED_TIER_48_RAM_GB=48

rc=0

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; rc=1; }
cannot_run() { printf 'CANNOT RUN  %s\n' "$*"; exit 2; }

# num_from_label "~7.2 GB" -> 7.2 ; "" on a label with no digits.
num_from_label() {
    printf '%s' "$1" | tr -cd '0-9.' | sed 's/\.$//'
}

# lt A B -> true when A < B, as floats. bash 3.2 has no float compare.
lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) < (b + 0)) }'
}

# ── Limb implementations, parameterised on a tree so the controls can ──
# ── point them at a synthetic pre-fix copy.                           ──

# Echoes the canonical download label for the measured tier, or "" if the
# helper cannot answer.
canonical_label_for_tier() {
    local tree="$1" ram="${2:-$MEASURED_TIER_RAM_GB}"
    (
        # shellcheck disable=SC1090
        . "$tree/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        local tag
        tag="$(ostler_recommend_model "$ram")"
        [ -n "$tag" ] || exit 0
        ostler_model_size_label "$tag"
    )
}

canonical_tag_for_tier() {
    local tree="$1" ram="${2:-$MEASURED_TIER_RAM_GB}"
    (
        # shellcheck disable=SC1090
        . "$tree/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        ostler_recommend_model "$ram"
    )
}

# Echoes the AI_MODEL_SIZE literal the install.sh fallback ladder assigns
# alongside the given model tag. Reads the ladder as text on purpose: sourcing
# install.sh is not possible, and the ladder is exactly the copy that drifts.
fallback_label_for_tag() {
    local tree="$1" tag="$2"
    grep -A 8 -F "AI_MODEL=\"${tag}\"" "$tree/install.sh" 2>/dev/null \
        | grep -m1 -E '^[[:space:]]*AI_MODEL_SIZE=' \
        | sed -e 's/.*AI_MODEL_SIZE="//' -e 's/".*//'
}

# ── Limb 1: the advertised figure is not below what we measured ───────
# limb_understated <tree> [ram] [floor]: defaults are the 16 GB tier.
limb_understated() {
    local tree="$1" ram="${2:-$MEASURED_TIER_RAM_GB}" floor="${3:-$MEASURED_FLOOR_GB}" lbl num
    lbl="$(canonical_label_for_tier "$tree" "$ram")"
    [ -n "$lbl" ] || return 3          # 3 = cannot run
    num="$(num_from_label "$lbl")"
    [ -n "$num" ] || return 3
    lt "$num" "$floor" && return 1
    return 0
}

# ── Limb 2: the two copies of the figure agree ────────────────────────
limb_drift() {
    local tree="$1" ram="${2:-$MEASURED_TIER_RAM_GB}" tag canon fb
    tag="$(canonical_tag_for_tier "$tree" "$ram")"
    [ -n "$tag" ] || return 3
    canon="$(canonical_label_for_tier "$tree" "$ram")"
    fb="$(fallback_label_for_tag "$tree" "$tag")"
    [ -n "$fb" ] || return 3
    [ "$canon" = "$fb" ] || return 1
    return 0
}

# ── Limb 3: no advertised range starts below the floor ────────────────
# Echoes offending "line:lower_bound" rows on stdout; rc 3 when the scan found
# nothing at all to examine, because a pattern that has gone blind prints an
# identical clean run to a tree with no defects.
limb_ranges() {
    local tree="$1" hit line lower examined=0
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        examined=$((examined + 1))
        line="${hit%%:*}"
        lower="$(printf '%s' "$hit" | sed -e 's/^[0-9]*://' \
            -e 's/.*[^0-9.]\([0-9][0-9.]*\)-[0-9][0-9.]*[[:space:]]*GB.*/\1/')"
        [ -n "$lower" ] || continue
        if lt "$lower" "$MEASURED_FLOOR_GB"; then
            printf '%s:%s\n' "$line" "$lower"
        fi
    done < <(grep -nE '[0-9][0-9.]*-[0-9][0-9.]*[[:space:]]*GB' "$tree/install.sh" 2>/dev/null \
             | grep -iE 'model|ollama|download')
    [ "$examined" -gt 0 ] || return 3
    return 0
}

# ══ CONTROLS FIRST ════════════════════════════════════════════════════
# Prove every limb goes red on a tree built to be wrong in exactly that limb's
# way. Fixtures live only in a temp dir and never enter the repo.
#
# ⚠️ THE CONTROLS MUST NOT DEPEND ON THE SUBJECT'S CURRENT VALUE. The first cut
# of this file built its controls by sed-ing the KNOWN-BAD historical label
# into the fixture. That silently became a no-op when run against the actual
# pre-fix tree, because the pre-fix tree ALREADY carried that value -- so the
# limb-2 control could not be made to disagree with itself and the gate
# reported CANNOT RUN on the very tree it was written to catch. A control
# built by substituting a specific value only fires when the subject does not
# already hold it. These override the array slot BY INDEX instead, so the
# fixture is wrong by construction whatever the subject happens to say.

CTL="$(mktemp -d -t ostler-model-size-ctl)"
trap 'rm -rf "$CTL"' EXIT

for f in lib/ostler-model-fit.sh install.sh; do
    [ -f "$ROOT/$f" ] || cannot_run "$ROOT/$f is absent -- this gate cannot read the surface it claims to cover"
done

# new_fixture <name> -> echoes a tree path holding a copy of both surfaces.
new_fixture() {
    local d="$CTL/$1"
    mkdir -p "$d/lib"
    cp "$ROOT/lib/ostler-model-fit.sh" "$d/lib/ostler-model-fit.sh"
    cp "$ROOT/install.sh" "$d/install.sh"
    printf '%s' "$d"
}

# force_label <tree> <tag> <label> -- override the canonical label for <tag> by
# ARRAY INDEX, appended after the table so it wins however the table was
# written. Independent of what the label currently says.
force_label() {
    local tree="$1" tag="$2" lbl="$3" idx
    idx="$(
        # shellcheck disable=SC1090
        . "$tree/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        _ostler_model_index "$tag"
    )"
    case "$idx" in ''|-1) return 1 ;; esac
    printf '\nOSTLER_MODEL_SIZELBL[%s]="%s"\n' "$idx" "$lbl" >> "$tree/lib/ostler-model-fit.sh"
}

_ctl_tag="$(canonical_tag_for_tier "$ROOT")"
[ -n "${_ctl_tag}" ] || cannot_run "the model-fit helper named no model for a ${MEASURED_TIER_RAM_GB} GB box -- no control can be built"

# Synthetic labels chosen relative to the floor, never copied from the product.
_lbl_below="~$(awk -v f="$MEASURED_FLOOR_GB" 'BEGIN { printf "%.1f", (f / 2) }') GB"
_lbl_above="~$(awk -v f="$MEASURED_FLOOR_GB" 'BEGIN { printf "%.1f", (f + 10) }') GB"

say "== controls: each limb must FAIL on a tree built wrong in that limb's way =="

# Limb 1 positive control: a label definitively below the floor.
_c1="$(new_fixture c1)"
force_label "$_c1" "$_ctl_tag" "$_lbl_below" || cannot_run "could not build the limb 1 control"
limb_understated "$_c1"; _r=$?
[ "$_r" -eq 1 ] \
    && say "  ok  limb 1 (understated) fires on a label below the floor" \
    || cannot_run "limb 1 did not go red on a label below the floor (rc=$_r) -- an unproven limb is not a check"

# Limb 1 negative control: a label ABOVE the floor must stay green. Without
# this, a limb hard-wired to "fail" would have passed the check above.
_c1n="$(new_fixture c1n)"
force_label "$_c1n" "$_ctl_tag" "$_lbl_above" || cannot_run "could not build the limb 1 negative control"
limb_understated "$_c1n"; _r=$?
[ "$_r" -eq 0 ] \
    && say "  ok  limb 1 stays GREEN above the floor (it measures the floor, not a literal)" \
    || cannot_run "limb 1 fired on a label ABOVE the floor (rc=$_r) -- it is not measuring what it claims"

# Limb 1 control on the 48 GB+ tier: the same predicate, a label below 22.62.
_c1_48="$(new_fixture c1_48)"
_ctl_tag48="$(canonical_tag_for_tier "$ROOT" "$MEASURED_TIER_48_RAM_GB")"
[ -n "$_ctl_tag48" ] || cannot_run "the model-fit helper named no model for a ${MEASURED_TIER_48_RAM_GB} GB box"
force_label "$_c1_48" "$_ctl_tag48" "~10.0 GB" || cannot_run "could not build the 48 GB tier control"
limb_understated "$_c1_48" "$MEASURED_TIER_48_RAM_GB" "$MEASURED_FLOOR_48_GB"; _r=$?
[ "$_r" -eq 1 ] \
    && say "  ok  limb 1 (48 GB tier) fires on a label below the measured 22.62 GB" \
    || cannot_run "limb 1 did not go red on the 48 GB tier control (rc=$_r)"

# Limb 2 positive control: move ONLY the canonical copy, leave the install.sh
# ladder untouched, so the two copies must disagree whatever they started at.
_c2="$(new_fixture c2)"
force_label "$_c2" "$_ctl_tag" "$_lbl_above" || cannot_run "could not build the limb 2 control"
limb_drift "$_c2"; _r=$?
[ "$_r" -eq 1 ] \
    && say "  ok  limb 2 (drift between the two copies) fires when one copy moves" \
    || cannot_run "limb 2 did not go red when the two copies of the figure were made to disagree (rc=$_r)"

# Limb 3 positive control: plant one understated range.
_c3="$(new_fixture c3)"
printf '%s\n' 'echo "    - control: downloaded models (may be 1-23 GB)"' >> "$_c3/install.sh"
_ctl_ranges="$(limb_ranges "$_c3")"; _r=$?
if [ "$_r" -eq 0 ] && [ -n "$_ctl_ranges" ]; then
    say "  ok  limb 3 (understated range) fires on a planted range"
elif [ "$_r" -eq 3 ]; then
    cannot_run "limb 3's range scan examined NOTHING on the control tree -- the pattern is blind, and a blind pattern reports clean"
else
    cannot_run "limb 3 did not report a planted understated range (rc=$_r)"
fi

say ""

# ══ THE REAL TREE ═════════════════════════════════════════════════════
say "== subject: $ROOT =="

_tag="$(canonical_tag_for_tier "$ROOT")"
_canon="$(canonical_label_for_tier "$ROOT")"
[ -n "$_tag" ] && [ -n "$_canon" ] \
    || cannot_run "lib/ostler-model-fit.sh named no model or no label for a ${MEASURED_TIER_RAM_GB} GB box"

say "  ${MEASURED_TIER_RAM_GB} GB tier -> ${_tag}, advertised ${_canon}; floor ${MEASURED_FLOOR_GB} GB (${FLOOR_PROVENANCE})"

limb_understated "$ROOT"; _r=$?
case "$_r" in
    0) say "  PASS  lib/ostler-model-fit.sh advertises ${_canon}, at or above the measured floor" ;;
    1) fail "lib/ostler-model-fit.sh advertises ${_canon} for ${_tag}, but it was MEASURED at ${MEASURED_FLOOR_GB} GB (${FLOOR_PROVENANCE}). The customer reads this while deciding whether to continue on a metered link." ;;
    *) cannot_run "limb 1 could not read a size label off the real tree" ;;
esac

limb_drift "$ROOT"; _r=$?
_fb="$(fallback_label_for_tag "$ROOT" "$_tag")"
case "$_r" in
    0) say "  PASS  both copies of the figure say ${_canon} (helper + install.sh fallback ladder)" ;;
    1) fail "the two copies of the download figure disagree for ${_tag}: lib/ostler-model-fit.sh says '${_canon}', install.sh's fallback ladder says '${_fb}'. The fallback path is the stripped-bundle path -- the one nobody walks." ;;
    *) cannot_run "limb 2 could not read install.sh's fallback ladder for ${_tag}" ;;
esac

_tag48="$(canonical_tag_for_tier "$ROOT" "$MEASURED_TIER_48_RAM_GB")"
_canon48="$(canonical_label_for_tier "$ROOT" "$MEASURED_TIER_48_RAM_GB")"
[ -n "$_tag48" ] && [ -n "$_canon48" ] \
    || cannot_run "lib/ostler-model-fit.sh named no model or no label for a ${MEASURED_TIER_48_RAM_GB} GB box"
say "  ${MEASURED_TIER_48_RAM_GB} GB tier -> ${_tag48}, advertised ${_canon48}; measured ${MEASURED_FLOOR_48_GB} GB (${FLOOR_48_PROVENANCE})"
limb_understated "$ROOT" "$MEASURED_TIER_48_RAM_GB" "$MEASURED_FLOOR_48_GB"; _r=$?
case "$_r" in
    0) say "  PASS  48 GB tier advertises ${_canon48}, at or above the measured ${MEASURED_FLOOR_48_GB} GB" ;;
    1) fail "48 GB tier advertises ${_canon48} for ${_tag48}, but the registry layers measure ${MEASURED_FLOOR_48_GB} GB (${FLOOR_48_PROVENANCE})." ;;
    *) cannot_run "limb 1 (48 GB tier) could not read a size label off the real tree" ;;
esac
limb_drift "$ROOT" "$MEASURED_TIER_48_RAM_GB"; _r=$?
_fb48="$(fallback_label_for_tag "$ROOT" "$_tag48")"
case "$_r" in
    0) say "  PASS  both copies say ${_canon48} for the 48 GB tier (helper + install.sh fallback ladder)" ;;
    1) fail "48 GB tier: the two copies disagree for ${_tag48}: helper '${_canon48}', fallback ladder '${_fb48}'." ;;
    *) cannot_run "limb 2 (48 GB tier) could not read install.sh's fallback ladder for ${_tag48}" ;;
esac

_ranges="$(limb_ranges "$ROOT")"; _r=$?
if [ "$_r" -eq 3 ]; then
    cannot_run "the range scan examined NO model-size ranges in install.sh -- the pattern has gone blind, and blind reports clean"
elif [ -n "$_ranges" ]; then
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        fail "install.sh:${row%%:*} advertises a downloaded-models range starting at ${row##*:} GB, below the measured floor of ${MEASURED_FLOOR_GB} GB"
    done <<< "$_ranges"
else
    say "  PASS  every downloaded-models range in install.sh starts at or above ${MEASURED_FLOOR_GB} GB"
fi

say ""
if [ "$rc" -eq 0 ]; then
    say "test_model_download_size_honesty: OK -- the advertised download size is not below what we measured."
else
    say "test_model_download_size_honesty: the product is understating a download to the customer."
fi
exit "$rc"
