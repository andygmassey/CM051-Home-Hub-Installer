#!/usr/bin/env bash
# scripts/run_ship_prereqs.sh <LINUX|MACOS> -- run every `make -C gui <target>` that scripts/ship_prereq_classes.tsv
# lists for that class, in file order, WITHOUT stopping at the first RED (one round trip shows every break),
# print one rc line per target, and exit non-zero if any target was non-zero. rc is never masked.
# MAKE_DIR / CLASSES override for tests.
set -u
cls="${1:?usage: run_ship_prereqs.sh LINUX|MACOS}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tsv="${CLASSES:-$root/scripts/ship_prereq_classes.tsv}"
gui="${MAKE_DIR:-$root/gui}"
[ -f "$tsv" ] || { echo "CANNOT-RUN: no $tsv" >&2; exit 2; }
targets="$(grep -v '^#' "$tsv" | awk -F'|' -v c="$cls" '$2==c {print $1}')"
[ -n "$targets" ] || { echo "CANNOT-RUN: class $cls has no targets in $tsv" >&2; exit 2; }
n=0; bad=0; summary=""
for t in $targets; do
    n=$((n+1)); log="$(mktemp)"
    make -C "$gui" "$t" >"$log" 2>&1; rc=$?
    cat "$log"
    [ "$t" = check-orphans ] && grep -E '^== summary: ' "$log" || true
    rm -f "$log"
    [ "$rc" -ne 0 ] && bad=$((bad+1))
    summary="${summary}$(printf '  rc=%s  %s' "$rc" "$t")
"
done
printf '\n== ship prerequisites (%s): %s target(s) run, %s non-zero ==\n%s' "$cls" "$n" "$bad" "$summary"
[ "$bad" -eq 0 ]
