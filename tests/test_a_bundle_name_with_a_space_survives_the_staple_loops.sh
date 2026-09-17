#!/usr/bin/env bash
# tests/test_a_bundle_name_with_a_space_survives_the_staple_loops.sh
# ============================================================================
# THE DEFECT, measured on cut run 35187827169 (tag v1.0.99, 2026-09-17 06:10Z).
# gui/Makefile's staple-apps target enumerated nested .app bundles into a
# variable and then iterated it UNQUOTED:
#
#     NESTED_APPS="$(find "$APP_PATH/Contents" -type d -name '*.app' ...)"
#     for app in $NESTED_APPS; do ...
#
# That splits on IFS, which includes the SPACE. #1970 added "Recover
# Ostler.app", the first bundle in this product whose name contains one, so
# the single real path
#
#     Contents/Resources/Recover Ostler.app
#
# became the two paths that do not exist
#
#     Contents/Resources/Recover        and        Ostler.app
#
# Round 1 reported each as "[skip] (no ticket issued for this CDHash)", which
# is indistinguishable from a bundle Apple legitimately issued no ticket for.
# The verify block then reported each as "[FAIL] ticket missing after staple"
# and `make: *** [staple-apps] Error 1` killed the cut. The bundle that
# actually needed the ticket was never stapled and never named in the log.
#
# WHY NOTHING CAUGHT IT. The loops had always been written this way; no bundle
# name had ever contained a space, so the construct had never been exercised.
# The workflow_dispatch dry run cannot reach it: it does not build, sign or
# staple anything.
#
# WHAT IS ASSERTED, in two independent ways:
#
#   1. MECHANISM, executed. Build a synthetic bundle tree containing a
#      space-named .app and run the enumeration as the Makefile now writes it.
#      It must yield paths that all EXIST. The must-fail arm runs the OLD
#      `for app in $LIST` form over the same tree and must yield paths that do
#      NOT exist -- so the test demonstrates the failure on every run rather
#      than only ever having passed.
#
#   2. TEXT, against the real file. Neither enumeration in gui/Makefile may
#      use the `for <var> in $$<VAR>` shape over a path list. A control line
#      that IS that shape must be rejected by the same predicate, so the
#      predicate is shown to discriminate.
#
# Assertion 1 alone would pass while the Makefile stayed broken; assertion 2
# alone would pass on a construct that does not work. Both, or neither.
#
# NO PIPE INTO grep -q ANYWHERE: that construct SIGPIPEs its producer and
# under `set -o pipefail` reports failure for a pattern it found. Counted form.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MK="$REPO/gui/Makefile"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; [ $# -lt 2 ] || printf '%s\n' "$2" >&2; }

if [ ! -f "$MK" ]; then
    printf '  [FAIL] gui/Makefile not found at %s -- CANNOT-RUN, not a pass\n' "$MK" >&2
    exit 1
fi

# --- the synthetic tree. SYNTHETIC ONLY: no real bundle, no real data. -------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP_PATH="$TMP/OstlerInstaller.app"
mkdir -p "$APP_PATH/Contents/Resources/Recover Ostler.app/Contents"
mkdir -p "$APP_PATH/Contents/Resources/Ostler.app/Contents"
mkdir -p "$APP_PATH/Contents/Resources/assistant-agent/OstlerAssistant.app/Contents"

printf '\n-- 1. MECHANISM, executed against a space-named bundle --\n'

# The shipped form: deepest-first into a file, read a line at a time.
LIST="$TMP/list"
find "$APP_PATH/Contents" -type d -name '*.app' 2>/dev/null \
    | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- > "$LIST"

missing=""
count=0
while IFS= read -r app; do
    [ -n "$app" ] || continue
    count=$((count + 1))
    [ -d "$app" ] || missing="$missing
    $app"
done < "$LIST"

if [ "$count" -ne 3 ]; then
    bad "the shipped enumeration yielded $count bundle(s), expected exactly 3" "$(cat "$LIST")"
elif [ -n "$missing" ]; then
    bad "the shipped enumeration produced path(s) that do not exist:" "$missing"
else
    ok "all 3 bundles enumerate as existing paths, space-named one included"
fi

# The space-named bundle must be enumerated WHOLE, not as two fragments.
whole="$(grep -c 'Recover Ostler\.app$' "$LIST")"
frag="$(grep -cx '.*/Recover' "$LIST")"
if [ "$whole" -eq 1 ] && [ "$frag" -eq 0 ]; then
    ok "'Recover Ostler.app' appears once, whole, and never as a bare '.../Recover'"
else
    bad "space-named bundle enumerated wrong: whole=$whole fragment=$frag" "$(cat "$LIST")"
fi

# MUST-FAIL ARM. The construct the cut actually shipped. If this does NOT
# break, the tree above is not exercising the defect and arm 1 proves nothing.
OLD_LIST="$(find "$APP_PATH/Contents" -type d -name '*.app' 2>/dev/null)"
old_missing=0
old_count=0
for app in $OLD_LIST; do
    old_count=$((old_count + 1))
    [ -d "$app" ] || old_missing=$((old_missing + 1))
done
if [ "$old_missing" -ge 2 ] && [ "$old_count" -eq 4 ]; then
    ok "CONTROL: the old 'for app in \$LIST' form splits it into $old_count entries, $old_missing of them non-existent"
else
    bad "CONTROL did not reproduce the defect (count=$old_count missing=$old_missing) -- this test is not exercising it"
fi

printf '\n-- 2. TEXT, against gui/Makefile as it ships --\n'

# The defect shape: `for <var> in $$<VAR>` inside a recipe. Anchored to the
# recipe tab so a prose mention in a comment cannot trip it.
offenders="$(grep -nE '^	[[:space:]]*for [a-zA-Z_]+ in .*\$\$[A-Z_]+' "$MK" || true)"
if [ -z "$offenders" ]; then
    ok "no recipe line iterates a shell variable unquoted with 'for ... in \$\$VAR'"
else
    bad "these recipe lines iterate a variable unquoted and will split on any space in a path:" "$offenders"
fi

# Both enumerations must read a line at a time. Counted, never grep -q.
reads="$(grep -cE 'while IFS= read -r app; do' "$MK")"
if [ "$reads" -ge 2 ]; then
    ok "both staple enumerations read a line at a time ($reads 'while IFS= read -r app' loops)"
else
    bad "expected at least 2 'while IFS= read -r app' loops in gui/Makefile, found $reads"
fi

# CONTROL on the offender predicate. A line that IS the defect shape must be
# rejected by it, or the grep above discriminates nothing and passes for ever.
CTL="$TMP/ctl.mk"
printf 'target:\n\tfor app in $$NESTED_APPS; do \\\n\t    echo "$$app"; \\\n\tdone\n' > "$CTL"
ctl_hits="$(grep -cE '^	[[:space:]]*for [a-zA-Z_]+ in .*\$\$[A-Z_]+' "$CTL")"
if [ "$ctl_hits" -ge 1 ]; then
    ok "CONTROL: the predicate does flag a recipe line written in the defect shape"
else
    bad "CONTROL: the predicate did not flag a line that IS the defect -- it discriminates nothing"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
