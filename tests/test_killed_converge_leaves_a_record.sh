#!/usr/bin/env bash
# ===========================================================================
# A converge pass killed at the install budget must leave a record, and
# install.sh must not claim the kill is harmless.
#
# install.sh kills the identity resolver on a 300s budget (SIGTERM, 2s,
# SIGKILL). The comment beside that kill used to justify it with
# "batch_resolver --execute commits each merge as it goes, so no work done so
# far is lost". That is true per MERGE and false per SPARQL UPDATE:
# merge_persons is eight separate updates, the identifiers move at step 1 and
# the mergedInto tombstone is written at step 6, so a kill in between leaves an
# unauthorised rehoming. SIGKILL cannot be trapped, so the resolver cannot
# finish the merge it is inside.
#
# The absence of the .done marker cannot tell "killed at the budget" from
# "exited non-zero for another reason", so the kill path writes its own marker.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/install.sh"
[ -r "$SRC" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SRC" >&2; exit 2; }

fails=0
chk() { if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi; }
has()  { grep -qF -- "$1" "$SRC"; }

printf 'a killed converge leaves a record\n'

# CONTROL FIRST. If this string is missing the file is not what we think it is,
# and every "absent" below would be vacuously true.
if ! has 'kill -9 "$_DEDUPE_PID"'; then
    printf 'CANNOT-RUN: the SIGKILL line is not in install.sh; this test is pointed at the wrong thing.\n' >&2
    exit 2
fi
chk "CONTROL: the SIGKILL the test is about is present" 0

# The false safety claim must be gone.
has 'work done so far is lost' && r=1 || r=0
chk "the 'no work done so far is lost' claim is gone" "$r"

# ...and the correction must name the actual mechanism, not just delete the lie.
has 'FALSE PER SPARQL UPDATE' && r=0 || r=1
chk "the comment names WHY the kill can tear a merge" "$r"

has 'mergedInto' && r=0 || r=1
chk "the comment names the authorisation step by predicate" "$r"

# The marker: defined, cleared at start, written on the kill path.
has '_DEDUPE_KILLED_MARKER="${OSTLER_DIR}/state/dedupe-converge.killed"' && r=0 || r=1
chk "a killed-marker path is defined beside the done-marker" "$r"

has 'rm -f "$_DEDUPE_DONE_MARKER" "$_DEDUPE_KILLED_MARKER"' && r=0 || r=1
chk "the killed-marker is cleared at the start of every run" "$r"

# It must be written AFTER the SIGKILL, not merely somewhere in the file.
k="$(grep -n 'kill -9 "$_DEDUPE_PID"' "$SRC" | head -1 | cut -d: -f1)"
w="$(grep -n '> "$_DEDUPE_KILLED_MARKER"' "$SRC" | head -1 | cut -d: -f1)"
if [ -n "$k" ] && [ -n "$w" ] && [ "$w" -gt "$k" ] && [ $(( w - k )) -lt 20 ]; then r=0; else r=1; fi
chk "the marker is written after the SIGKILL (kill@${k:-?} marker@${w:-?})" "$r"

# The marker block must EMIT the keys a later reader needs. Checked by reading
# a bounded window after the SIGKILL -- never by sourcing an extracted block,
# because an extraction whose end anchor fails would run installer code.
win="$(awk -v k="$k" 'NR>k && NR<=k+20' "$SRC")"
n_keys=0
for key in killed_at_utc waited_s budget_s signal risk; do
    printf '%s' "$win" | grep -q "${key}=" && n_keys=$((n_keys + 1))
done
[ "$n_keys" -eq 5 ] && r=0 || r=1
chk "the marker records all 5 keys within 20 lines of the kill (found ${n_keys} of 5)" "$r"

printf '  examined 8 assertions against %s\n' "$SRC"
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: the kill is recorded and no longer described as harmless.\n'
