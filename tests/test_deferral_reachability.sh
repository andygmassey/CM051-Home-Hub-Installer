#!/usr/bin/env bash
# ============================================================================
# test_deferral_reachability.sh
#
# The four controls for deferral_reachability_report() in
# scripts/verify_no_orphaned_fixes.sh. A guard with no demonstrated RED is not
# a guard, so these are committed rather than run once in somebody's shell.
#
#   ARM 1  VACUITY    nothing consulted -> CANNOT-RUN, and NO refs listed.
#                     Without this a sweep that measured nothing reports every
#                     deferral as unconsulted and reads as a catastrophe.
#   ARM 2  RED        a planted daemon:#999999 MUST be named UNCONSULTED.
#   ARM 3  GREEN      everything consulted -> zero unconsulted. Proves the
#                     check is not permanently red, which is the other way a
#                     ratchet dies.
#   ARM 4  EXCLUSION  a repo not checked here must NOT be reported, or every
#                     skipped repo manufactures false findings.
#
# THESE CONTROLS ALREADY PAID. On first run arms 1-3 died with
# `unchecked_labels: unbound variable`: the function defaulted its args with
# ${3:-$unchecked_labels}, which is itself an unbound-variable error under
# set -u. Arm 4 passed anyway because it supplied that argument. A green from
# arm 4 alone would have shipped a function that aborts in three of four
# conditions.
#
# The function body is extracted FROM THE REAL SCRIPT at run time, so this
# exercises the shipped code and not a transcription of it.
# ============================================================================
set -uo pipefail
SRC=scripts/verify_no_orphaned_fixes.sh
# Pull the function OUT OF THE REAL FILE at run time, so this exercises the
# shipped body and not a transcription of it.
awk '/^deferral_reachability_report\(\) \{/,/^\}$/' "$SRC" > /tmp/fn.sh
[ -s /tmp/fn.sh ] || { echo "EXTRACT FAILED"; exit 9; }
echo "extracted $(wc -l </tmp/fn.sh) lines from $SRC"
say() { printf '%s\n' "$*"; }
. /tmp/fn.sh

DEF=/tmp/d.yaml
cat > "$DEF" <<'Y'
deferrals:
  - ref: "daemon:#999999"
    reason: NEGATIVE CONTROL, no such PR exists anywhere
    until_cut: v9.9.9
  - ref: "CM051:#216"
    reason: this one WILL be consulted in arm 2
    until_cut: v9.9.9
Y

echo; echo "===== ARM 1: VACUITY (nothing consulted) ====="
: > /tmp/c1
deferral_reachability_report "$DEF" /tmp/c1 "" | sed 's/^/  /'

echo; echo "===== ARM 2: RED (CM051:#216 consulted, daemon:#999999 cannot be) ====="
printf 'CM051:#216\n' > /tmp/c2
deferral_reachability_report "$DEF" /tmp/c2 "" | sed 's/^/  /'

echo; echo "===== ARM 3: GREEN (both consulted -> zero unconsulted) ====="
printf 'CM051:#216\ndaemon:#999999\n' > /tmp/c3
deferral_reachability_report "$DEF" /tmp/c3 "" | sed 's/^/  /'

echo; echo "===== ARM 4: EXCLUSION (daemon not checked -> must NOT be reported) ====="
printf 'CM051:#216\n' > /tmp/c4
deferral_reachability_report "$DEF" /tmp/c4 "daemon" | sed 's/^/  /'
