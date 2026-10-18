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
#   1. EVERY model's download label in lib/ostler-model-fit.sh is at or above
#      that model's measured floor, and every model HAS a measured floor. This
#      covers all three RAM tiers (16 / 24-47 / 48+), not only the 16 GB one:
#      a 16-only gate cannot see a label on the 24-47 or 48+ tier understate
#      its pull, and v1.0.109 found exactly that shape when the Ollama
#      version under the labels was in question.
#   2. For every RAM tier, install.sh's fallback ladder (the stripped-bundle
#      path) states the SAME figure as lib/ostler-model-fit.sh. Two editable
#      copies of one customer claim drift, and the fallback path is the one
#      nobody walks.
#   3. No customer-facing "N-M GB" downloaded-models range in install.sh may
#      start below the smallest measured download (the 16 GB tier's model).
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

# ── The measured floors, one row per model the installer can offer ──
# EVERY tag in lib/ostler-model-fit.sh's OSTLER_MODEL_TAGS must have a row
# here. The installer prints the size label for EVERY model in its fit table
# (install.sh's per-model fit rows), and the picker hands one of them to each
# RAM tier (16 / 24-47 / 48+), so every label is a customer claim. A tag with
# no row is an UNMEASURED customer claim and fails.
#
# Row: <tag> <floor_gb> <provenance>. RAISE a floor, never lower it, and only
# against a NEW measurement on a box, recorded here with its date, box and
# Ollama version. A tag that genuinely downloads less records the new
# measurement; it does not relax a floor so a convenient label passes.
#
# v1.0.109 pins Ollama 0.34.0 (#2977), which pulls the GGUF build. Every
# floor below is for THAT version. Source for all three: clean pulls into an
# empty scratch store with the official 0.34.0 binary, every blob re-hashed,
# ~/walkdriver/evidence/pins_0340_2026-10-19.md. Total = every layer + config.
#
#   gemma4:e2b       4,587,156,505 B -> 4.6  (ollama list ID b37049369adf,
#                    config 3ff8a734). LOWERED from 7.2 against this new
#                    measurement: 7.2 was the v1.0.61 walk box, 2026-09-03,
#                    before the tag moved (config c6bc3775 -> 3ff8a734).
#   qwen3.5:9b       6,550,825,550 B -> 6.6  (ollama list ID 56671c2ab938,
#                    config 08f9698c).
#   qwen3.6:35b-a3b  22,621,314,381 B -> 22.6 (ollama list ID a7eb95c53bcf,
#                    config 99afa5bb). Clean 0.34.0 pull on the Mac Studio
#                    into an empty scratch store, every blob re-hashed (row
#                    10 of the evidence file). It equals, to the byte, the
#                    earlier registry read of the same GGUF manifest.
#
# NOT for v1.0.110: under Ollama 0.40.5 on Apple Silicon these tags pull the
# MLX builds (e2b 7.48, 9b 7.64, 35b 23.60 GB; registry read 2026-10-18,
# ~/walkdriver/evidence/ollama_0405_registry_sizes_2026-10-18/). Changing the
# Ollama pin changes every floor here; re-measure before that lands.
MEASURED_FLOORS='gemma4:e2b 4.6 clean pull, Ollama 0.34.0, 4,587,156,505 B, ollama list b37049369adf (pins_0340_2026-10-19.md)
qwen3.5:9b 6.6 clean pull, Ollama 0.34.0, 6,550,825,550 B, ollama list 56671c2ab938 (pins_0340_2026-10-19.md)
qwen3.6:35b-a3b 22.6 clean pull, Ollama 0.34.0, 22,621,314,381 B, ollama list a7eb95c53bcf (pins_0340_2026-10-19.md)'

# The RAM tiers the picker serves. Each must resolve to a measured tag.
# 16 GB is the installer's hard floor (ERR-02-PREREQ-RAM-LOW).
TIER_RAMS="16 24 48"
MEASURED_TIER_RAM_GB=16

floor_for_tag() {
    printf '%s\n' "$MEASURED_FLOORS" | awk -v t="$1" '$1 == t { print $2; exit }'
}
provenance_for_tag() {
    printf '%s\n' "$MEASURED_FLOORS" | awk -v t="$1" '$1 == t { $1 = ""; $2 = ""; sub(/^  /, ""); print; exit }'
}

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

# Echoes every tag in the fit table, one per line ("" if unreadable).
all_tags() {
    (
        # shellcheck disable=SC1090
        . "$1/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        printf '%s\n' "${OSTLER_MODEL_TAGS[@]}"
    )
}

# tag_for_ram <tree> <ram_gb> -> the model the picker gives that RAM.
tag_for_ram() {
    (
        # shellcheck disable=SC1090
        . "$1/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        ostler_recommend_model "$2"
    )
}

# label_for_tag <tree> <tag> -> the customer-facing size label.
label_for_tag() {
    (
        # shellcheck disable=SC1090
        . "$1/lib/ostler-model-fit.sh" >/dev/null 2>&1 || exit 0
        ostler_model_size_label "$2"
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

# ── Limb 1: no model's advertised figure is below what we measured ────
# Prints "tag|label|floor|why" for each offender; rc 3 when nothing could be
# examined. "why" is "below" or "unmeasured" (a tag with no floor row).
limb_understated() {
    local tree="$1" tag lbl num floor examined=0
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        examined=$((examined + 1))
        lbl="$(label_for_tag "$tree" "$tag")"
        num="$(num_from_label "$lbl")"
        floor="$(floor_for_tag "$tag")"
        if [ -z "$floor" ]; then
            printf '%s|%s|-|unmeasured\n' "$tag" "$lbl"
        elif [ -z "$num" ] || lt "$num" "$floor"; then
            printf '%s|%s|%s|below\n' "$tag" "$lbl" "$floor"
        fi
    done < <(all_tags "$tree")
    [ "$examined" -gt 0 ] || return 3
    return 0
}

# ── Limb 2: for every RAM tier, the two copies of the figure agree ────
# Prints "ram|tag|canon|fallback" for each disagreement; rc 3 if a tier
# named no model or the ladder has no row for it.
limb_drift() {
    local tree="$1" ram tag canon fb
    for ram in $TIER_RAMS; do
        tag="$(tag_for_ram "$tree" "$ram")"
        [ -n "$tag" ] || return 3
        canon="$(label_for_tag "$tree" "$tag")"
        fb="$(fallback_label_for_tag "$tree" "$tag")"
        [ -n "$fb" ] || return 3
        [ "$canon" = "$fb" ] || printf '%s|%s|%s|%s\n' "$ram" "$tag" "$canon" "$fb"
    done
    return 0
}

# ── Limb 3: no advertised range starts below the smallest download ────
# The smallest download is the 16 GB tier's model: the cheapest install the
# product ships. Echoes offending "line:lower_bound" rows; rc 3 when the scan
# found nothing at all to examine, because a pattern that has gone blind
# prints an identical clean run to a tree with no defects.
limb_ranges() {
    local tree="$1" min_floor="$2" hit line lower examined=0
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        examined=$((examined + 1))
        line="${hit%%:*}"
        lower="$(printf '%s' "$hit" | sed -e 's/^[0-9]*://' \
            -e 's/.*[^0-9.]\([0-9][0-9.]*\)-[0-9][0-9.]*[[:space:]]*GB.*/\1/')"
        [ -n "$lower" ] || continue
        if lt "$lower" "$min_floor"; then
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

# Every tier's model, read from the subject. A tier that names nothing, or a
# floor table that cannot be read, is CANNOT RUN: no control can be built.
_tags_seen=""
for _r in $TIER_RAMS; do
    _t="$(tag_for_ram "$ROOT" "$_r")"
    [ -n "$_t" ] || cannot_run "the model-fit helper named no model for a ${_r} GB box -- no control can be built"
    _tags_seen="${_tags_seen} ${_t}"
done
[ -n "$(floor_for_tag gemma4:e2b)$(floor_for_tag qwen3.5:9b)" ] \
    || cannot_run "MEASURED_FLOORS could not be read -- every floor would be empty"

say "== controls: each limb must FAIL on a tree built wrong in that limb's way =="

# Limb 1 controls, run for EVERY tier's model so no tier is unguarded: a label
# definitively below that model's floor must fire, one above must not.
for _t in $_tags_seen; do
    _f="$(floor_for_tag "$_t")"
    [ -n "$_f" ] || continue   # an unmeasured tag is reported by the subject run
    _below="~$(awk -v f="$_f" 'BEGIN { printf "%.1f", (f / 2) }') GB"
    _above="~$(awk -v f="$_f" 'BEGIN { printf "%.1f", (f + 10) }') GB"
    _c="$(new_fixture "c1-${_t//[:.]/_}")"
    force_label "$_c" "$_t" "$_below" || cannot_run "could not build the limb 1 control for ${_t}"
    _out="$(limb_understated "$_c")"
    printf '%s\n' "$_out" | grep -q "^${_t}|.*|below\$" \
        && say "  ok  limb 1 fires on ${_t} labelled ${_below} (floor ${_f})" \
        || cannot_run "limb 1 did not go red on ${_t} labelled below its floor -- an unproven limb is not a check"
    _c="$(new_fixture "c1n-${_t//[:.]/_}")"
    force_label "$_c" "$_t" "$_above" || cannot_run "could not build the limb 1 negative control for ${_t}"
    _out="$(limb_understated "$_c")"
    printf '%s\n' "$_out" | grep -q "^${_t}|" \
        && cannot_run "limb 1 fired on ${_t} labelled ABOVE its floor -- it is not measuring what it claims" \
        || say "  ok  limb 1 stays GREEN on ${_t} above its floor"
done

# Limb 1 unmeasured control: a tag with no floor row must be reported.
_c="$(new_fixture c1u)"
printf '\nOSTLER_MODEL_TAGS+=("control:unmeasured")\nOSTLER_MODEL_SIZELBL+=("~99 GB")\n' >> "$_c/lib/ostler-model-fit.sh"
limb_understated "$_c" | grep -q '^control:unmeasured|.*|unmeasured$' \
    && say "  ok  limb 1 reports a model with no measured floor" \
    || cannot_run "limb 1 did not report a model that has no measured floor"

# Limb 2 control: move ONLY the canonical copy for the 24 GB tier's model.
_t24="$(tag_for_ram "$ROOT" 24)"
_c="$(new_fixture c2)"
force_label "$_c" "$_t24" "~999 GB" || cannot_run "could not build the limb 2 control"
limb_drift "$_c" | grep -q "^24|${_t24}|" \
    && say "  ok  limb 2 (drift between the two copies) fires on the 24 GB tier when one copy moves" \
    || cannot_run "limb 2 did not go red when the two copies of the 24 GB figure were made to disagree"

# Limb 3 positive control: plant one understated range.
_min_floor="$(floor_for_tag "$(tag_for_ram "$ROOT" "$MEASURED_TIER_RAM_GB")")"
[ -n "$_min_floor" ] || _min_floor=0
_c3="$(new_fixture c3)"
printf '%s\n' 'echo "    - control: downloaded models (may be 0.1-23 GB)"' >> "$_c3/install.sh"
_ctl_ranges="$(limb_ranges "$_c3" "$_min_floor")"; _r=$?
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

for _r in $TIER_RAMS; do
    _t="$(tag_for_ram "$ROOT" "$_r")"
    say "  ${_r} GB tier -> ${_t}, advertised $(label_for_tag "$ROOT" "$_t"); floor $(floor_for_tag "$_t") GB ($(provenance_for_tag "$_t"))"
done

_u="$(limb_understated "$ROOT")"; _r=$?
[ "$_r" -eq 3 ] && cannot_run "limb 1 examined no model in lib/ostler-model-fit.sh"
if [ -z "$_u" ]; then
    say "  PASS  every model's label in lib/ostler-model-fit.sh is at or above its measured floor"
else
    while IFS='|' read -r _t _l _f _w; do
        [ -n "$_t" ] || continue
        if [ "$_w" = "unmeasured" ]; then
            fail "lib/ostler-model-fit.sh advertises ${_t} as '${_l}' and there is NO measured floor for it. Measure the pull on a box and add a row to MEASURED_FLOORS."
        else
            fail "lib/ostler-model-fit.sh advertises ${_t} as '${_l}', but it was MEASURED at ${_f} GB ($(provenance_for_tag "$_t")). The customer reads this while deciding whether to continue on a metered link."
        fi
    done <<< "$_u"
fi

_d="$(limb_drift "$ROOT")"; _r=$?
[ "$_r" -eq 3 ] && cannot_run "limb 2 could not read install.sh's fallback ladder for every tier"
if [ -z "$_d" ]; then
    say "  PASS  for every tier (${TIER_RAMS}), helper and install.sh fallback ladder state the same figure"
else
    while IFS='|' read -r _ram _t _c _fb; do
        [ -n "$_ram" ] || continue
        fail "the two copies of the ${_ram} GB tier's figure disagree for ${_t}: lib/ostler-model-fit.sh says '${_c}', install.sh's fallback ladder says '${_fb}'. The fallback path is the stripped-bundle path -- the one nobody walks."
    done <<< "$_d"
fi

_ranges="$(limb_ranges "$ROOT" "$_min_floor")"; _r=$?
if [ "$_r" -eq 3 ]; then
    cannot_run "the range scan examined NO model-size ranges in install.sh -- the pattern has gone blind, and blind reports clean"
elif [ -n "$_ranges" ]; then
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        fail "install.sh:${row%%:*} advertises a downloaded-models range starting at ${row##*:} GB, below the smallest measured download of ${_min_floor} GB"
    done <<< "$_ranges"
else
    say "  PASS  every downloaded-models range in install.sh starts at or above ${_min_floor} GB"
fi

say ""
if [ "$rc" -eq 0 ]; then
    say "test_model_download_size_honesty: OK -- no advertised download size is below what we measured."
else
    say "test_model_download_size_honesty: the product is understating a download to the customer."
fi
exit "$rc"
