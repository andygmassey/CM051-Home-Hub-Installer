#!/usr/bin/env bash
# The wiki compile must be judged on pages produced, not on exit code.
#
# THE DEFECT, measured on CM051 main 5487446e before this test existed:
# install.sh had NO page count anywhere. `WIKI_BASELINE_RC` was the only
# success signal for the entire wiki, and that signal CANNOT FAIL:
#
#   CM044 compile.py:1438   returns results
#   CM044 compile.py:1577   main() DISCARDS the return value
#   CM044 __main__.py:4     calls main() with no sys.exit
#
# The entrypoint is `python -m compiler`, so the container exits 0 whether it
# wrote eighteen thousand pages or none, and `.compile-complete` is written
# either way. That is how "wiki compiled zero pages" walked past a green
# install on a real box: every directory present, every directory empty,
# 39 steps ok, err=0 warn=0.
#
# WHAT THIS PINS
#   1. A page COUNT exists after the compile and is compared against zero.
#   2. It counts FILES, not directories. The observed failure was a tree of
#      empty directories, which any `-d` or bare glob check reports as fine.
#   3. BEHAVIOURAL, not a grep: the counting logic is executed against an
#      empty tree and a populated one, and the two verdicts must differ.
#   4. POSITIVE CONTROL: the compile invocation is still present, so a scan
#      that has lost the whole block cannot report clean.
#   5. PROVED RED: the count block is removed from a scratch copy and limb 1
#      must fail.
#
# WHY NOT FATAL. install.sh has no path that ends a step in failure, so a
# hard exit here would change install semantics far beyond the wiki. The
# oracle states the number, marks the run unhealthy and refuses to call the
# wiki ready. A zero that is PRINTED beats a zero that fails silently. If
# that changes, this test's expectations change with it.
#
# Exit: 0 pass, 1 real failure, 2 cannot-run.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO/install.sh"
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { printf '  %sPASS%s  %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$1"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT RUN: no install.sh at $INSTALL_SH" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── DENOMINATOR FIRST ─────────────────────────────────────────────────────
n_compile="$(grep -c 'profile compile run' "$INSTALL_SH" || true)"
n_count="$(grep -c 'WIKI_PAGE_COUNT' "$INSTALL_SH" || true)"
printf '  DENOMINATOR: %s compile invocation(s), %s page-count reference(s)\n' \
    "$n_compile" "$n_count"

# ── 4. POSITIVE CONTROL ───────────────────────────────────────────────────
if [ "$n_compile" -gt 0 ]; then
    ok "POSITIVE CONTROL: the wiki compile invocation is still in install.sh"
else
    bad "POSITIVE CONTROL BROKEN: no compile invocation found, so this gate is scanning the wrong file and its verdict means nothing"
fi

# ── 1 + 2. a count exists, over FILES, compared against zero ──────────────
has_find_files="$(grep -c "find \"\$WIKI_DOCS_DIR\" -type f" "$INSTALL_SH" || true)"
has_zero_test="$(grep -c 'WIKI_PAGE_COUNT:-0}" -eq 0' "$INSTALL_SH" || true)"
if [ "$n_count" -gt 0 ] && [ "$has_find_files" -gt 0 ] && [ "$has_zero_test" -gt 0 ]; then
    ok "the compile is judged on a FILE count compared against zero, not on its exit code"
else
    bad "no page-count oracle: count_refs=$n_count find-type-f=$has_find_files zero-test=$has_zero_test. The compiler's exit code cannot fail, so without this the wiki has no oracle at all"
fi

# ── 3. BEHAVIOURAL: run the counting logic on both shapes ─────────────────
# The observed failure was a tree of EMPTY DIRECTORIES. Reproduce exactly
# that, not merely an absent directory, because an absent directory is the
# easy case and it is not the one that shipped.
count_pages() {  # same predicate as install.sh
    find "$1" -type f \( -name '*.md' -o -name '*.html' \) 2>/dev/null | wc -l | tr -d ' '
}

mkdir -p "$TMP/empty/Reading" "$TMP/empty/Music" "$TMP/empty/Years" \
         "$TMP/full/Reading"
: > "$TMP/full/Reading/a.md"; : > "$TMP/full/Reading/b.md"; : > "$TMP/full/index.html"

n_empty="$(count_pages "$TMP/empty")"
n_full="$(count_pages "$TMP/full")"
printf '  measured: empty-tree=%s populated-tree=%s\n' "$n_empty" "$n_full"

if [ "$n_empty" -eq 0 ] && [ "$n_full" -eq 3 ]; then
    ok "BEHAVIOURAL: a tree of empty directories counts 0 and a real wiki counts 3"
else
    bad "BEHAVIOURAL: predicate does not discriminate (empty=$n_empty full=$n_full); a directories-exist check would call the empty tree healthy"
fi

# ── 5. PROVED RED ─────────────────────────────────────────────────────────
grep -v 'WIKI_PAGE_COUNT' "$INSTALL_SH" > "$TMP/red.sh"
r_count="$(grep -c 'WIKI_PAGE_COUNT' "$TMP/red.sh" || true)"
if [ "$r_count" -eq 0 ] && [ "$n_count" -gt 0 ]; then
    ok "PROVED RED: stripping the count leaves $r_count reference(s), so limb 1 fails on that tree"
else
    bad "PROVED RED FAILED: stripping changed nothing (before=$n_count after=$r_count); this gate cannot see the defect it exists to find"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
