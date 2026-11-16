#!/usr/bin/env bash
# The hub_screens_customer_read probe counts assertion rows with grep -c. On a
# verdict with NO assertion rows grep -c prints 0 AND exits 1, so an `|| echo 0`
# fallback yields the two-line value "0\n0"; the later `[ "$n" -gt 0 ]` then
# errors (not false), probe_fail never runs, and the probe exits rc=78 having
# printed no assertion (v1.0.120 walk). This drives the REAL count block,
# extracted from the real probe, over a verdict with no assertions (the
# two-zeros case) and over one with assertions, and asserts a single integer
# reaches probe_examined and the silent run is a FAIL, not a CANNOT-RUN.
# Exit: 0 holds | 1 broken | 2 CANNOT RUN
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../scripts/box_walk_probes/probes/hub_screens_customer_read.sh"
[ -f "$PROBE" ] || { echo "CANNOT RUN: probe missing" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
start="$(/usr/bin/grep -n 'A run that printed no assertion row' "$PROBE" | head -1 | cut -d: -f1)"
end="$(/usr/bin/grep -n 'probe_note "screens and facts' "$PROBE" | head -1 | cut -d: -f1)"
{ [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ]; } || { echo "CANNOT RUN: count block markers not found" >&2; exit 2; }
sed -n "${start},$((end - 1))p" "$PROBE" > "$W/block.sh"
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

run_block() {  # $1 = verdict file content; prints "EX=<..>|VERDICT=<fail|cannot|pass|none>"
  mkdir -p "$W/out"; printf '%b' "$1" > "$W/out/verdict.txt"
  /bin/bash -c '
    out="$1"; rc=0
    probe_examined() { echo "EX=$1" >> "$out/log"; }
    probe_fail() { echo "V=fail" >> "$out/log"; exit 0; }
    probe_cannot_run() { echo "V=cannot" >> "$out/log"; exit 0; }
    . "$2"
    echo "V=none" >> "$out/log"
  ' _ "$W/out" "$W/block.sh" 2>"$W/err" ; true
}
rm -f "$W/out/log"
run_block ''
log="$(tr '\n' '|' < "$W/out/log" 2>/dev/null)"
if [ "$log" = "EX=0|V=fail|" ]; then ok "no assertion rows: one integer (0) reaches probe_examined and the probe FAILs"
else bad "no assertion rows: got '$log' (stderr: $(head -c 200 "$W/err"))"; fi

rm -f "$W/out/log"
run_block '  ok one\n  FAIL two\n  CANNOT three\n'
log="$(tr '\n' '|' < "$W/out/log" 2>/dev/null)"
if [ "$log" = "EX=3|V=none|" ]; then ok "three assertion rows: probe_examined gets 3 and the probe carries on to the rc case"
else bad "three assertion rows: got '$log'"; fi

# An unreadable verdict file is CANNOT-RUN (grep rc 2), never a manufactured count.
rm -f "$W/out/log" "$W/out/verdict.txt"
/bin/bash -c '
  out="$1"; rc=0
  probe_examined() { echo "EX=$1" >> "$out/log"; }
  probe_fail() { echo "V=fail" >> "$out/log"; exit 0; }
  probe_cannot_run() { echo "V=cannot" >> "$out/log"; exit 0; }
  . "$2"
  echo "V=none" >> "$out/log"
' _ "$W/out" "$W/block.sh" 2>/dev/null
log="$(tr '\n' '|' < "$W/out/log" 2>/dev/null)"
if [ "$log" = "EX=0|V=cannot|" ]; then ok "unreadable verdict file: CANNOT-RUN, not a count"; else bad "unreadable verdict: got '$log'"; fi

# The block must contain no `|| echo 0` fallback (the manufactured second zero).
if /usr/bin/grep -q '|| echo 0' "$W/block.sh"; then bad "the count block still has an '|| echo 0' fallback"; else ok "no '|| echo 0' fallback in the count block"; fi
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
