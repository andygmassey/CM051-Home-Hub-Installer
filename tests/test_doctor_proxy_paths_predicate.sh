#!/usr/bin/env bash
# Controls for scripts/check_doctor_proxy_paths.sh.
#
# WHY THESE EXIST
#
# The check this exercises replaced a whole-file `grep -q "$path" install.sh`.
# That old predicate was green on origin/main and it was green for two
# reasons that have nothing to do with the paths being wired:
#
#   - a path named in a COMMENT satisfied it, and install.sh comments name
#     these paths while explaining why each was added
#   - a path that is a PREFIX of another required path could never fail,
#     and two of the required paths are exactly that pair
#
# So arms 3 and 4 below do not merely assert the new predicate goes red.
# They assert the OLD predicate goes GREEN on the same fixture. Without that
# half, a reader has to take on trust that the rewrite was necessary, and a
# control that only confirms the new behaviour cannot tell you whether it
# changed anything. Assert the defect, not its formatting.
#
# Arms 5 to 7 pin CANNOT-RUN as a THIRD state. An unreadable value means the
# script checked nothing; reporting that as a pass is the failure this whole
# family of gates keeps producing.
#
# Arm 8 pins the floor: shrinking the required list must refuse, not quietly
# check less and print PASS.
#
# Pure bash + awk. No network, no repo mutation. Exit 0 on pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$REPO_ROOT/scripts/check_doctor_proxy_paths.sh"

PASS=0
FAIL=0

ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$CHECK" ]]; then
    echo "CANNOT-RUN: $CHECK missing or not executable" >&2
    exit 3
fi

ALL_PATHS="/api/safari/ingest,/api/v1/hub/health,/api/v1/timeline,/api/v1/people,/api/v1/people/search,/api/v1/people/context,/api/v1/person/{slug}/timeline,/api/v1/people/stale,/api/v1/people/recent,/api/v1/suggestions,/api/v1/calendar,/api/v1/calendar/today,/api/v1/conversation/process,/api/v1/conversation/status/{id},/api/v1/email/recent,/api/v1/ingest/ios,/api/v1/recording/active,/api/v1/coach/recent,/api/v1/people/{slug}/forget,/api/v1/decisions,/api/v1/topics,/api/v1/topics/{slug}/mentions,/api/v1/commitments"

# Build a minimal install.sh-shaped fixture. $1 is the file, $2 the rendered
# value, $3 an optional extra comment line placed near the stanza (the decoy).
make_fixture() {
    local out="$1" value="$2" decoy="${3:-}"
    {
        echo '#!/usr/bin/env bash'
        echo '# fixture standing in for install.sh'
        echo 'cat > "$DOCTOR_PLIST" <<PLIST'
        echo '<dict>'
        [[ -n "$decoy" ]] && echo "  <!-- $decoy -->"
        echo '        <key>DOCTOR_PROXY_PATHS</key>'
        echo "        <string>${value}</string>"
        echo '</dict>'
        echo 'PLIST'
    } > "$out"
}

# Run the check without taking rc through a pipe.
run_check() {
    local fixture="$1"
    set +e
    "$CHECK" "$fixture" > "$TMP/out" 2>&1
    RC=$?
    set -e
}

# The predicate this replaced, reproduced exactly: a whole-file substring grep.
old_predicate_finds() {
    grep -q "$2" "$1"
}

drop_field() {
    # Remove one comma-delimited field from a list, by exact field match.
    printf '%s' "$1" | awk -v drop="$2" -v RS=',' '
        $0 != drop { out = (out == "" ? $0 : out "," $0) }
        END { printf "%s", out }
    '
}

echo ""
echo "=== DOCTOR_PROXY_PATHS predicate controls ==="
echo ""

# ---- ARM 1: GREEN -----------------------------------------------------
make_fixture "$TMP/green.sh" "$ALL_PATHS"
run_check "$TMP/green.sh"
if [[ $RC -ne 0 ]]; then
    bad "ARM 1 GREEN: expected rc=0, got $RC
$(cat "$TMP/out")"
elif ! grep -q "^PASS:" "$TMP/out"; then
    bad "ARM 1 GREEN: rc=0 but no PASS line, so the run may not have checked anything"
else
    ok "ARM 1 GREEN: a complete list passes and states its denominator"
fi

# ---- ARM 2: RED, a required path simply deleted ------------------------
V="$(drop_field "$ALL_PATHS" "/api/v1/decisions")"
make_fixture "$TMP/missing.sh" "$V"
run_check "$TMP/missing.sh"
if [[ $RC -ne 1 ]]; then
    bad "ARM 2 RED (deleted): expected rc=1, got $RC. A dark iOS endpoint is passing."
elif ! grep -q "/api/v1/decisions" "$TMP/out"; then
    bad "ARM 2 RED (deleted): rc=1 but the message does not NAME the missing path"
else
    ok "ARM 2 RED (deleted): rc=1 and the missing path is named"
fi

# ---- ARM 3: RED, deleted from the value but MENTIONED in a comment -----
#
# This is the shape that made the old gate useless. Someone removes an
# endpoint from the proxy list and leaves the comment explaining it.
V="$(drop_field "$ALL_PATHS" "/api/v1/commitments")"
make_fixture "$TMP/decoy.sh" "$V" "moat reads: /api/v1/commitments is served by ical-server"
run_check "$TMP/decoy.sh"
if [[ $RC -ne 1 ]]; then
    bad "ARM 3 RED (comment decoy): expected rc=1, got $RC. A COMMENT is satisfying the gate."
elif ! grep -q "/api/v1/commitments" "$TMP/out"; then
    bad "ARM 3 RED (comment decoy): rc=1 but the path is not named"
elif ! old_predicate_finds "$TMP/decoy.sh" "/api/v1/commitments"; then
    bad "ARM 3 CONTROL BROKEN: the old whole-file grep did NOT find the decoy, so this
      fixture does not reproduce the defect and the arm proves nothing"
else
    ok "ARM 3 RED (comment decoy): new predicate rc=1 on a fixture the OLD grep passes"
fi

# ---- ARM 4: RED, a required path that is a PREFIX of another -----------
#
# /api/v1/calendar is a prefix of /api/v1/calendar/today, and the same trap
# is about to exist for /api/v1/topics vs /api/v1/topics/{slug}/mentions.
V="$(drop_field "$ALL_PATHS" "/api/v1/calendar")"
make_fixture "$TMP/prefix.sh" "$V"
run_check "$TMP/prefix.sh"
if [[ $RC -ne 1 ]]; then
    bad "ARM 4 RED (prefix): expected rc=1, got $RC. /api/v1/calendar is being satisfied
      by /api/v1/calendar/today."
elif ! grep -q "/api/v1/calendar\b" "$TMP/out"; then
    bad "ARM 4 RED (prefix): rc=1 but the path is not named"
elif ! old_predicate_finds "$TMP/prefix.sh" "/api/v1/calendar"; then
    bad "ARM 4 CONTROL BROKEN: the old grep did NOT match the surviving longer path, so
      this fixture does not reproduce the prefix defect"
else
    ok "ARM 4 RED (prefix): new predicate rc=1 on a fixture the OLD grep passes"
fi

# ---- ARM 5: CANNOT-RUN, the key is absent ------------------------------
{
    echo '#!/usr/bin/env bash'
    echo '# no proxy stanza at all'
} > "$TMP/nokey.sh"
run_check "$TMP/nokey.sh"
if [[ $RC -eq 0 ]]; then
    bad "ARM 5 CANNOT-RUN (absent key): rc=0. Nothing was checked and it reported a pass."
elif [[ $RC -ne 3 ]]; then
    bad "ARM 5 CANNOT-RUN (absent key): expected rc=3, got $RC. CANNOT-RUN must be
      distinguishable from 'paths are missing', or the caller fixes the wrong thing."
elif ! grep -q "CANNOT-RUN" "$TMP/out"; then
    bad "ARM 5 CANNOT-RUN (absent key): rc=3 but the message does not say CANNOT-RUN"
else
    ok "ARM 5 CANNOT-RUN (absent key): rc=3, distinct from both pass and missing"
fi

# ---- ARM 6: CANNOT-RUN, more than one rendering ------------------------
{
    echo '        <key>DOCTOR_PROXY_PATHS</key>'
    echo "        <string>${ALL_PATHS}</string>"
    echo '        <key>DOCTOR_PROXY_PATHS</key>'
    echo '        <string>/api/v1/hub/health</string>'
} > "$TMP/dupe.sh"
run_check "$TMP/dupe.sh"
if [[ $RC -ne 3 ]]; then
    bad "ARM 6 CANNOT-RUN (two renderings): expected rc=3, got $RC. Checking the first
      of two proves nothing about the one the Doctor receives, and here the FIRST is
      complete while the second is not."
else
    ok "ARM 6 CANNOT-RUN (two renderings): rc=3 rather than trusting the first"
fi

# ---- ARM 7: CANNOT-RUN, empty value ------------------------------------
make_fixture "$TMP/empty.sh" ""
run_check "$TMP/empty.sh"
if [[ $RC -ne 3 ]]; then
    bad "ARM 7 CANNOT-RUN (empty value): expected rc=3, got $RC"
else
    ok "ARM 7 CANNOT-RUN (empty value): rc=3, reported as total darkness not 19 misses"
fi

# ---- ARM 8: the floor refuses a silently shrunk list --------------------
#
# Tonight's lesson: a mutation that matches nothing makes a self-test prove
# nothing while printing green. So the mutation is asserted APPLIED before
# its effect is measured.
MUT="$TMP/check_mutated.sh"
awk '!/"\/api\/v1\/commitments"/' "$CHECK" > "$MUT"
chmod +x "$MUT"
if cmp -s "$CHECK" "$MUT"; then
    bad "ARM 8 FLOOR: the mutation changed NOTHING, so this arm measured nothing.
      The anchor line no longer matches. Fix the anchor, do not delete the arm."
else
    set +e
    "$MUT" "$TMP/green.sh" > "$TMP/out" 2>&1
    RC=$?
    set -e
    if [[ $RC -eq 0 ]]; then
        bad "ARM 8 FLOOR: a shrunk required list PASSED. The gate can be weakened by
      deleting a line, and it will keep printing PASS while checking less."
    elif [[ $RC -ne 3 ]]; then
        bad "ARM 8 FLOOR: expected rc=3, got $RC"
    else
        ok "ARM 8 FLOOR: deleting a required path refuses (rc=3), mutation proved applied"
    fi
fi

echo ""
echo "---"
echo "PASS $PASS   FAIL $FAIL"
if [[ $FAIL -gt 0 || $PASS -eq 0 ]]; then
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi
echo ""
echo "RESULT: PASS"
exit 0
