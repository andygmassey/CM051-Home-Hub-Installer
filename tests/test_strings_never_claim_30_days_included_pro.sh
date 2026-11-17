#!/usr/bin/env bash
# Included Pro is 3 months (standard) / 6 months (founding), never 30 days.
# Fails if any install.sh.strings.*.sh value pairs "Pro" with a 30-day claim,
# or if the first-month-free keys carry any 30 + day-unit wording.
# Control: a synthetic 30-day line must be caught by the same predicate.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
UNIT='(30[ ]?(days?|Tage|jours|días|giorni|dag|dagen|dias|天|日|일|يوم|يومًا|يوماً)|30日間|首 ?30|前 ?30|첫 30|thirty days)'
hit() { /usr/bin/grep -E '^MSG_' | /usr/bin/grep -E "$UNIT" | /usr/bin/grep -E 'Pro|FIRST_MONTH_FREE' || true; }
ctl=$(printf '%s\n' 'MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro active for 30 days."' | hit)
[ -n "$ctl" ] || { echo "FAIL: control line not caught, predicate is blind"; exit 1; }
files=(install.sh.strings.*.sh)
[ "${#files[@]}" -ge 15 ] || { echo "FAIL: only ${#files[@]} strings files found"; exit 1; }
bad=0
for f in "${files[@]}"; do
  out=$(hit < "$f")
  if [ -n "$out" ]; then echo "FAIL $f: $out" | cut -c1-200; bad=1; fi
done
[ "$bad" -eq 0 ] || exit 1
echo "PASS: ${#files[@]} strings files, no 30-day included-Pro claim (control caught)"
