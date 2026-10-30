#!/usr/bin/env bash
# The ostler_launchd_jobs_loaded_and_exit_clean box read used a shell glob over
# three LaunchAgents/Daemons dirs. ssh runs it under the box's login shell
# (zsh), which aborts on an unmatched glob ("no matches found") when one dir is
# empty, so the probe read 0 jobs (v1.0.120 walk). This runs the REAL read text
# under zsh AND bash with one Ostler plist in a temp HOME and (on this host) an
# empty or absent /Library/LaunchAgents, and asserts a real count of 1.
# Exit: 0 holds | 1 broken | 2 CANNOT RUN
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${1:-$HERE/../scripts/box_walk_probes/probes/ostler_launchd_jobs_loaded_and_exit_clean.sh}"
[ -f "$PROBE" ] || { echo "CANNOT RUN: probe missing" >&2; exit 2; }
command -v zsh >/dev/null 2>&1 || { echo "CANNOT RUN: no zsh on this host" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
sed -n "/^_LAUNCHD_READ='/,/^done'\$/p" "$PROBE" | sed "1s/^_LAUNCHD_READ='//; \$s/'\$//" > "$W/read.sh"
[ -s "$W/read.sh" ] || { echo "CANNOT RUN: could not extract the box read" >&2; exit 2; }
mkdir -p "$W/home/Library/LaunchAgents" "$W/bin" "$W/sysLA" "$W/sysLD"
# The system dirs are redirected to EMPTY temp dirs so the failing condition
# (an empty /Library/LaunchAgents) holds on any host, not only a bare one.
sed -i.bak -e "s# /Library/LaunchAgents# $W/sysLA#g" -e "s# /Library/LaunchDaemons# $W/sysLD#g" "$W/read.sh"
grep -q "$W/sysLA" "$W/read.sh" || { echo "CANNOT RUN: system dir redirect did not apply" >&2; exit 2; }
: > "$W/home/Library/LaunchAgents/com.ostler.synthetic.plist"
printf '#!/bin/bash\ncase "$1" in print-disabled) ;; print) printf "\\tstate = not running\\n\\tlast exit code = 0\\n";; esac\nexit 0\n' > "$W/bin/launchctl"; chmod +x "$W/bin/launchctl"
# the condition under test: no Ostler plist in the system dirs on this host
sysn="$( (ls /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null) | /usr/bin/grep -ci ostler )"
fail=0
for sh in zsh bash; do
  out="$(HOME="$W/home" PATH="$W/bin:$PATH" "$sh" -c "$(cat "$W/read.sh")" 2>"$W/err.$sh")"
  n="$(printf '%s\n' "$out" | awk -F'\t' 'NF>=5{n++} END{print n+0}')"
  if [ "$n" -ge 1 ] && [ "$sysn" -eq 0 ]; then echo "  ok    $sh: read $n job(s) with no Ostler plist in the system dirs (real count, not an abort)"
  elif [ "$n" -ge 1 ]; then echo "  ok    $sh: read $n job(s) (system dirs hold $sysn Ostler plist(s); the empty-dir condition is not reproduced here)"
  else echo "  FAIL  $sh: read 0 jobs ($(head -c 160 "$W/err.$sh"))"; fail=1; fi
done
exit "$fail"
