#!/usr/bin/env bash
# The v1.0.108 wow-moment probes (reply_debt_is_answered,
# morning_brief_catches_me_up) and the install.sh prompt they grade.
#   1. the judge self-test: every known-bad capture goes red
#   2. each probe's --self-test returns FAIL (1), as the walk runner expects
#   3. the morning-brief prompt install.sh writes covers today and promises
#      (the probe's prompt arm), and the pre-change prompt did NOT (control)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

python3 scripts/box_walk_probes/lib/wow_moments.py --self-test >/dev/null 2>&1 \
    && ok "wow_moments judge self-test: every mutant red" || bad "wow_moments judge self-test"
for p in reply_debt_is_answered morning_brief_catches_me_up; do
    bash "scripts/box_walk_probes/probes/$p.sh" --self-test >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] && ok "$p --self-test returns FAIL (1)" || bad "$p --self-test returned $rc, expected 1"
done

covers() {  # covers <install.sh path> -> prints YES/NO for the probe's prompt predicate
    python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^\s*_morning_prompt="(.*)"\s*$', src, re.M)
if not m:
    print("CANNOT"); raise SystemExit
p = m.group(1).replace('\\"', '"').lower()
print("YES" if ("today" in p and "promise" in p) else "NO")
PY
}
now="$(covers install.sh)"
[ "$now" = "YES" ] && ok "install.sh's morning-brief prompt covers today and promises" \
    || bad "install.sh's morning-brief prompt does not cover today and promises ($now)"
# Control: the pre-change prompt, as it shipped through v1.0.107.
ctl="$(mktemp)"
printf '        _morning_prompt="%s"\n' "You are the user's personal assistant. Write a concise morning brief in plain prose for delivery as a short message. Summarise the most relevant items from yesterday's conversations, meetings and emails." > "$ctl"
[ "$(covers "$ctl")" = "NO" ] && ok "control: the pre-change (yesterday-only) prompt is read as NOT covering today" \
    || bad "control: the yesterday-only prompt was read as covering today; the predicate proves nothing"
rm -f "$ctl"
echo "== $((5 - fails)) pass / $fails fail / 5 total =="
[ "$fails" -eq 0 ]
