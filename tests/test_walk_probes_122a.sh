#!/usr/bin/env bash
# tests/test_walk_probes_122a.sh
# ============================================================================
# The three v1.0.122 walk probes (CM051 #2397+#2398, #2404, #966): chat_reminder_routes_to_home,
# image_pulls_match_pins, status_api_dates_are_sane. A probe is believed only after it has gone red:
#   1. each probe's --self-test behaves (exit 1, "negative control behaved"),
#   2. each judge's own python self-test is clean (every case on its own verdict),
#   3. MUTANTS: one assertion of each judge is broken in a temp copy; its self-test must go RED.
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BWP="$REPO/scripts/box_walk_probes"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 missing"; exit 2; }
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "test_walk_probes_122a"

P1=chat_reminder_routes_to_home:reminder_routing
P2=image_pulls_match_pins:image_pins
P3=status_api_dates_are_sane:status_dates

for pair in $P1 $P2 $P3; do
    probe="${pair%%:*}"; lib="${pair##*:}"
    [ -f "$BWP/probes/$probe.sh" ] && [ -f "$BWP/lib/$lib.py" ] || { echo "CANNOT-RUN: $probe or $lib.py missing"; exit 2; }
    bash "$BWP/probes/$probe.sh" --self-test >"$WORK/st" 2>&1; rc=$?
    [ "$rc" -eq 1 ] && grep -q '^VERDICT: FAIL -- negative control behaved' "$WORK/st" && ok "$probe self-test behaves" || bad "$probe self-test rc=$rc: $(tail -1 "$WORK/st")"
    python3 -I "$BWP/lib/$lib.py" --self-test >"$WORK/py" 2>&1; rc=$?
    [ "$rc" -eq 0 ] && grep -q ', 0 wrong' "$WORK/py" && ok "$lib judge self-test clean ($(tail -1 "$WORK/py"))" || bad "$lib judge self-test rc=$rc: $(tail -2 "$WORK/py" | tr '\n' ' ')"
done

# mutant <lib> <sed expression> <label>: the broken judge's self-test must exit non-zero
mutant() {
    local lib="$1" expr="$2" label="$3" d="$WORK/m.$3"
    mkdir -p "$d"; cp "$BWP/lib/send_safety.py" "$BWP/lib/$lib.py" "$d/"
    sed -E "$expr" "$BWP/lib/$lib.py" > "$d/$lib.py"
    if cmp -s "$BWP/lib/$lib.py" "$d/$lib.py"; then bad "mutant $label did not change the source (stale sed)"; return; fi
    python3 -I "$d/$lib.py" --self-test >"$WORK/mo" 2>&1; rc=$?
    [ "$rc" -ne 0 ] && ok "mutant $label turns the self-test RED (rc=$rc)" || bad "mutant $label survived: the self-test stayed green"
}
mutant reminder_routing 's/\(v\.ok if mk\[key\] == 0 else v\.bad\)/(v.ok if True else v.bad)/' reminder-outward-send
mutant reminder_routing 's/ and r\.get\("to"\) == cap\["home"\]:/ and r.get("to"):/' reminder-first-job
mutant reminder_routing 's/if r\.get\("mode"\) == "announce" and r\.get\("to"\) == cap\["home"\]:/if r.get("found"):/' reminder-silent
mutant image_pins 's/elif pin in held:/elif True:/' image-held-digest
mutant image_pins 's/elif all\(r == pin for r in run\):/elif True:/' image-running
mutant status_dates 's/late = \[f for f in fs if f\[2\] > cut\]/late = []/' status-horizon

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
