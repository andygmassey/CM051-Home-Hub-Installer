#!/usr/bin/env bash
# ============================================================================
# A SOURCE THE EXTRACTOR SUPPORTS BUT NO PRESET REQUESTS IS DARK, AND IT LOOKS
# EXACTLY LIKE A CUSTOMER WITH NO DATA.
#
# #681, confirmed on a live v1.0.37 box rather than inferred:
#
#   ~/Library/.../NoteStore.sqlite     PRESENT, 315,392 bytes
#   ~/.ostler/imports/fda/apple_notes.json   ABSENT
#   hydrate marker                     status=no_data detail=no_export_json
#
# Every layer was behaving correctly. `extract_all.py` has apple_notes in
# DEFAULT_SOURCES and writes apple_notes.json. The hydrate step correctly
# reported that no export existed. The defect was one layer up and invisible
# from either end: install.sh's RECOMMENDED and EVERYTHING presets never
# listed apple_notes or apple_music, so OSTLER_FDA_SOURCES never contained
# them, so run_all never ran them, so the JSON never appeared.
#
# THE MARKER WAS HONEST, WHICH IS WHY THIS SURVIVED. `no_export_json` reads
# as "customer has no Notes". It actually meant "nobody asked". Two of nine
# default sources were dark for the entire life of the product and every
# diagnostic said the system was fine.
#
# So this test asserts the JOIN, not either side: every source ostler_fda
# enables by default must appear in the EVERYTHING preset. It fails the day
# someone adds a tenth extractor and forgets the preset -- which is exactly
# how these two were lost.
#
# Non-zero = BLOCK THE CUT. Shipping an extractor no preset requests is
# shipping a feature the customer paid for and cannot receive.
#
# Exit: 0 every default source is requested | 1 one or more are dark | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
# The extractor's own declaration. Vendored copy is the one that ships.
EXTRACT_ALL="${HERE}/../vendor/ostler_fda/extract_all.py"
[ -f "$EXTRACT_ALL" ] || EXTRACT_ALL="${HERE}/../ostler_fda/extract_all.py"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$INSTALL_SH" ]  || cannot "install.sh not readable at $INSTALL_SH"
[ -r "$EXTRACT_ALL" ] || cannot "extract_all.py not found -- looked in vendor/ostler_fda/ and ostler_fda/"

echo "== #681: every default FDA source must be requested by a preset =="

# ── 1. what does the EXTRACTOR enable by default? ─────────────────
# Parsed from the shipped source, not from a list kept here. A hand-kept
# copy would drift and this test would assert its own memory.
DEFAULTS="$(python3 - "$EXTRACT_ALL" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'DEFAULT_SOURCES\s*=\s*frozenset\(\{(.*?)\}\)', src, re.S)
if not m:
    sys.exit(3)
print("\n".join(sorted(re.findall(r'"([a-z_]+)"', m.group(1)))))
PY
)" || cannot "could not parse DEFAULT_SOURCES from ${EXTRACT_ALL#"${HERE}/../"}"

n_def="$(printf '%s\n' "$DEFAULTS" | grep -c .)"
if [ "$n_def" -ge 5 ]; then
    ok "parsed ${n_def} default sources from the shipped extract_all.py"
else
    bad "only parsed ${n_def} default sources. The regex has drifted from the source and every verdict below is unfounded."
    finish
fi

# ── 2. what do the PRESETS actually request? ──────────────────────
# EVERYTHING is the widest preset, so a source absent from it is absent from
# every path a customer can choose. Read the assignments, not the comments:
# this file's prose names the sources it discusses.
PRESET_TEXT="$(grep -E '^(RECOMMENDED|EVERYTHING)=|^ *(RECOMMENDED|EVERYTHING)="\$\{?(RECOMMENDED|EVERYTHING)' "$INSTALL_SH" 2>/dev/null)"
if [ -n "$PRESET_TEXT" ]; then
    ok "found the preset assignments in install.sh"
else
    bad "no RECOMMENDED/EVERYTHING assignment found in install.sh -- the presets moved and this test is now blind."
    finish
fi

# ── 3. THE JOIN. Every default source must appear in a preset. ────
# THREE states, not two. A source may be requested, DECLARED dark with a
# reason, or dark by accident. Only the third is a defect. Forcing the second
# into the first is what made CM051 #898 harmful: it would have enabled
# apple_notes ahead of the converter that consumes it.
BASELINE="${HERE}/fda_dark_sources_baseline.tsv"
[ -r "$BASELINE" ] || cannot "declared-dark baseline missing at ${BASELINE#"${HERE}/"} -- without it a deliberate deferral is indistinguishable from an oversight"

declared="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | cut -f1)"
n_declared="$(printf '%s\n' "$declared" | grep -c . || true)"
printf '        declared-dark: %s source(s)\n' "$n_declared"

dark=""
while IFS= read -r src; do
    [ -n "$src" ] || continue
    if grep -qF "$src" <<< "$PRESET_TEXT"; then
        ok "requested: ${src}"
    elif grep -qxF "$src" <<< "$declared"; then
        reason="$(grep -P "^${src}\t" "$BASELINE" 2>/dev/null | cut -f2 | cut -c1-72)"
        [ -n "$reason" ] || reason="$(awk -F'\t' -v s="$src" '$1==s{print substr($2,1,72)}' "$BASELINE")"
        ok "declared dark: ${src} -- ${reason}..."
    else
        bad "DARK BY ACCIDENT: '${src}' is in DEFAULT_SOURCES, requested by NO preset, and NOT declared in the baseline. It will never run, and the hydrate step will report no_data as if the customer had none. Either request it, or declare it with a reason and a removal condition."
        dark="${dark} ${src}"
    fi
done <<< "$DEFAULTS"

# THE BASELINE MAY ONLY SHRINK. A row for a source that IS now requested is
# slack, and slack is where the next regression hides.
while IFS= read -r d; do
    [ -n "$d" ] || continue
    if grep -qF "$d" <<< "$PRESET_TEXT"; then
        bad "STALE BASELINE: '${d}' is declared dark but a preset now requests it. Remove the row in the same change that enabled the source."
    fi
done <<< "$declared"

# ── 4. ANTI-VACUITY: prove the join can still fail. ───────────────
# A test that only ever passes is a test nobody has watched fail. Seed a
# source that is definitely not in any preset and require a miss.
if grep -qF "definitely_not_a_real_source" <<< "$PRESET_TEXT"; then
    bad "ANTI-VACUITY FAILED: the preset text matched a source that does not exist, so the grep above matches anything and every 'requested' line is meaningless."
else
    ok "anti-vacuity: a non-existent source is correctly NOT found in the presets"
fi

if [ -n "$dark" ]; then
    printf '\n  Dark sources:%s\n' "$dark"
    printf '  Add them to RECOMMENDED (local, no new permission) or EVERYTHING\n'
    printf '  (needs an app or an opt-in), in install.sh.\n'
fi

finish
