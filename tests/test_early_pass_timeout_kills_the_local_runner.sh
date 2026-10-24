#!/bin/bash
# The early pass's budget must kill the LOCAL runner's children too.
#
# Archie's limb (review of #3137, item 6), added unchanged below the defaults.
# It kills the mutant that drops the local process-group kill: the remote
# reap still cleans the box, so tests/test_early_pass_timeout_kills_the_remote_probe.sh
# cannot see it. Here the runner blocks on a LOCAL child (no ssh at all), the
# budget is 3s, and the child must be dead afterwards. Measured by Archie:
# PASS on b1a51a46, FAIL on the mutant, FAIL on base.
# Usage: [early-pass script] [repo root]; both default to this checkout.
_R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -- "${1:-${_R}/scripts/early_repeat_fail_pass.sh}" "${2:-${_R}}"
# LOCAL limb: the runner blocks on a LOCAL child (no ssh). On timeout it must die too.
EP="$1"; REPO="$2"
WORK="$(mktemp -d)"; LM="$WORK/local_work_marker"
trap 'pkill -9 -f "$LM" 2>/dev/null; rm -rf "$WORK"' EXIT
printf '#!/bin/bash\nsleep "${1:-300}"\n' > "$LM"; chmod +x "$LM"
mkdir -p "$WORK/walks" "$WORK/runner/probes" "$WORK/bin"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/ssh"; chmod +x "$WORK/bin/ssh"
printf 'version\tv1.0.117\nwalked_at\t2026-10-22T10:00:00Z\nverdict\tFAIL\nfailed_probe_names_recorded\tyes\nfailed_probe\tslow_probe\n' > "$WORK/walks/v1.0.117-20261022T100000Z.tsv"
printf '#!/bin/bash\n' > "$WORK/runner/probes/slow_probe.sh"
printf '#!/bin/bash\nSEED_DEPENDENT_PROBES="x"\n"%s" 300\n' "$LM" > "$WORK/runner/run_box_walk.sh"
PATH="$WORK/bin:/usr/bin:/bin" OSTLER_EARLY_PASS_BUDGET_S=3 /bin/bash "$EP" --host fake@walkbox.invalid --walks-dir "$WORK/walks" \
  --prev-record "$WORK/walks/v1.0.117-20261022T100000Z.tsv" --runner "$WORK/runner/run_box_walk.sh" > "$WORK/out" 2>&1; tail -5 "$WORK/out"
sleep 1
if pgrep -f "$LM" >/dev/null; then echo "FAIL LOCAL: runner child survived the budget"; exit 1; else echo "PASS LOCAL: runner child gone"; fi
