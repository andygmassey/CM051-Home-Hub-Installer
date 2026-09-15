#!/usr/bin/env bash
#
# tests/test_the_trial_must_actually_end.sh
#
# The subscription spine, tested as a customer rather than as a set of
# functions. Three defects, all found on 2026-09-16, all revenue:
#
#   1. expire_check() had ZERO production callers. The state file
#      install.sh wrote on day zero said status=active and nothing ever
#      changed it, so every Hub buyer had Ostler Pro free for life.
#   2. Andy's paid-once rule (BACKLOG.yaml, 2026-07-31: "keep it as long
#      as they've paid (fully) for Pro at least once. ie. not the 30 days
#      free plus a failed card try") was implemented in the Rust daemon
#      and entirely absent from the Python gate that actually ships.
#   3. PRODUCTISATION_CHECKLIST.md Rule 0.8 names eleven ingestion
#      surfaces that must check the gate. One did.
#
# WHY THIS TEST IS SHAPED LIKE THIS. The subject of every assertion below
# is a PERSON and a date, not a function and a flag. "A Hub buyer 31 days
# in loses Pro" is a claim about a customer; "expire_check is now called"
# is a claim about a call graph, and the call graph was never the thing
# that was wrong -- the customer outcome was.
#
# Limb A  the vendored gate unit suite, which ran NOWHERE in CI before
#         this file named it (measured: 0 references to
#         assistant_api/tests anywhere under .github, against a positive
#         control of 52 python-test invocations in the same tree)
# Limb B  the day-31 customer, end to end, through the same CLI the
#         shipped tick wrappers call
# Limb C  the real gate block, lifted verbatim out of each shipped tick
#         wrapper and executed against a staged Hub layout
# Limb D  the ical-server handlers gate before they do work
# Limb E  the path the wrappers derive is the path install.sh stages to
#
# Limb E is the one that stops this whole thing being theatre: limbs C
# and D can pass while the gate file is staged somewhere the wrappers
# never look, in which case every wrapper takes its fail-open branch and
# Rule 0.8 is enforced on nobody. A green C without E is a zero
# denominator wearing a tick.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 99
REPO_ROOT="$(pwd)"

GATE_SRC="vendor/cm041/assistant_api/subscription_gate.py"
ICAL="vendor/cm041/assistant_api/ical-server.py"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no $PY on PATH"; exit 99; }
test -f "$GATE_SRC" || { echo "FAIL: $GATE_SRC not found from $REPO_ROOT"; exit 99; }

fails=0
pass() { echo "PASS [$1]: $2"; }
fail() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# The tick wrappers derive the gate from their own staged service dir.
# Build that exact layout so limb C runs against the real shape:
#   $OSTLER_DIR/services/ical-server/subscription_gate.py
#   $OSTLER_DIR/services/<name>-source/
HUB="$TMPROOT/hub"
mkdir -p "$HUB/services/ical-server" "$HUB/services/imessage-source" "$HUB/state"
cp "$GATE_SRC" "$HUB/services/ical-server/subscription_gate.py"
GATE="$HUB/services/ical-server/subscription_gate.py"
STATE="$HUB/state/subscription_state.json"
export OSTLER_SUBSCRIPTION_STATE="$STATE"

# Write the state the INSTALLER writes, via the installer's own function.
# Never hand-write a status field: a fixture that writes the status is
# testing the fixture.
install_days_ago() {
    # Delete the state file FIRST. This models a fresh Hub, and it matters:
    # has_ever_paid is a sticky bit that activate_first_month_free carries
    # over on purpose, so a customer who has ever paid can re-run the
    # installer without losing their grace. Leaving a previous scenario's
    # paid state on disk therefore makes the NEXT "trialist" a payer, and
    # every pause assertion after it passes for the wrong reason. It did
    # exactly that on the first run of this file: five wrappers reported
    # "the pipeline ran for a customer who never paid" because the
    # customer in the fixture had, three scenarios earlier.
    rm -f "$STATE"
    "$PY" -c "
import sys
sys.path.insert(0, '$HUB/services/ical-server')
from subscription_gate import activate_first_month_free
from datetime import datetime, timezone, timedelta
activate_first_month_free(
    (datetime.now(timezone.utc) - timedelta(days=$1)).isoformat().replace('+00:00','Z'))
"
}

pay_for_pro_until_days_from_now() {
    "$PY" -c "
import sys
sys.path.insert(0, '$HUB/services/ical-server')
from subscription_gate import refresh_from_companion
from datetime import datetime, timezone, timedelta
refresh_from_companion('cmVjZWlwdA==',
    (datetime.now(timezone.utc) + timedelta(days=$1)).isoformat().replace('+00:00','Z'))
"
}

# ---------------------------------------------------------------------
# Limb A -- the vendored gate unit suite
# ---------------------------------------------------------------------
echo "--- Limb A: subscription gate unit suite ---"
(
    cd "$REPO_ROOT/vendor/cm041/assistant_api" || exit 1
    # No 2>/dev/null. A usage error here must read as a usage error, not
    # as "no tests failed".
    "$PY" -m unittest discover -s tests -p 'test_subscription*.py' -t . 2>&1
) > "$TMPROOT/unit.log"
unit_rc=$?
ran="$(sed -n 's/^Ran \([0-9][0-9]*\) test.*/\1/p' "$TMPROOT/unit.log" | head -1)"
ran="${ran:-0}"
if [ "$unit_rc" -ne 0 ]; then
    fail "A" "gate unit suite failed (rc=$unit_rc)"
    sed -n '1,60p' "$TMPROOT/unit.log"
elif [ "$ran" -lt 30 ]; then
    # A denominator check. `unittest discover` exits 0 when it collects
    # nothing, so a green tick with 0 tests is the failure mode this
    # whole file exists to make impossible elsewhere.
    fail "A" "gate unit suite ran only $ran tests; expected at least 30. A suite that collected nothing exits 0."
else
    pass "A" "gate unit suite green, $ran tests collected and run"
fi

# ---------------------------------------------------------------------
# Limb B -- the customer on day 31
# ---------------------------------------------------------------------
echo "--- Limb B: the customer, end to end ---"

install_days_ago 29
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "B1" "day 29 of the free month: the customer still has Ostler Pro"
else
    fail "B1" "day 29 returned $rc (expected 0). The free month must be a real month."
fi

install_days_ago 31
"$PY" "$GATE" --check >"$TMPROOT/b2.log" 2>&1
rc=$?
if [ "$rc" -eq 3 ]; then
    pass "B2" "day 31, never subscribed: ongoing intelligence pauses"
else
    fail "B2" "day 31 returned $rc (expected 3). THIS IS THE REVENUE DEFECT: every Hub buyer keeps Pro for free forever."
    cat "$TMPROOT/b2.log"
fi

# The state file still SAYS active at this point on a Hub whose ticker
# never ran. The answer must not depend on the ticker.
install_days_ago 31
stored="$("$PY" -c "import json;print(json.load(open('$STATE'))['status'])")"
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$stored" = "active" ] && [ "$rc" -eq 3 ]; then
    pass "B3" "the stored status said 'active' and the customer was still paused: the reader walks the state itself, so a scheduler that never loads cannot reinstate the defect"
else
    fail "B3" "stored=$stored rc=$rc (expected stored=active, rc=3)"
fi

install_days_ago 40
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 3 ]; then
    pass "B4" "day 40, never subscribed: no 14-day grace. Andy's rule -- grace is for people who paid."
else
    fail "B4" "day 40 returned $rc (expected 3). A never-paid trialist is being handed the grace fortnight."
fi

pay_for_pro_until_days_from_now 30
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "B5" "a paying customer keeps Ostler Pro"
else
    fail "B5" "a paying customer returned $rc (expected 0). This locks out someone who has paid."
fi

# Paid once, lapsed two days ago. Andy: keep it.
"$PY" -c "
import sys
sys.path.insert(0, '$HUB/services/ical-server')
from subscription_gate import refresh_from_companion
from datetime import datetime, timezone, timedelta
refresh_from_companion('cmVjZWlwdA==',
    (datetime.now(timezone.utc) - timedelta(days=2)).isoformat().replace('+00:00','Z'))
"
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "B6" "a customer who paid for Pro and lapsed two days ago keeps their grace"
else
    fail "B6" "a lapsed payer returned $rc (expected 0). Grace exists for exactly this person."
fi

# Currently paying, network down: last receipt predates the renewal we
# never heard about.
"$PY" -c "
import json, sys
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
def iso(d): return d.isoformat().replace('+00:00','Z')
json.dump({
    'status': 'inactive',
    'last_validated_at': iso(now - timedelta(days=25)),
    'expires_at': iso(now - timedelta(days=5)),
    'grace_period_end': None,
    'source': 'companion',
    'receipt': 'cmVjZWlwdA==',
    'has_ever_paid': True,
}, open('$STATE','w'))
"
"$PY" "$GATE" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "B7" "a paying customer whose network is down keeps Ostler Pro (offline fail-open)"
else
    fail "B7" "offline payer returned $rc (expected 0). We must never punish a payer for infrastructure we cannot observe."
fi

# ---------------------------------------------------------------------
# Limb C -- the real gate block out of each shipped tick wrapper
# ---------------------------------------------------------------------
echo "--- Limb C: the gate block inside each shipped tick wrapper ---"

WRAPPERS="
vendor/imessage_source/bin/imessage-bundle-tick.sh
vendor/whatsapp_source/bin/whatsapp-bundle-tick.sh
vendor/spoken_source/bin/spoken-bundle-tick.sh
vendor/email_source/bin/email-bundle-tick.sh
vendor/email_ingest/bin/email-ingest-tick.sh
"

run_block() {
    # $1 harness path, $2 expected exit
    /bin/bash "$1" >"$TMPROOT/block.log" 2>&1
    echo $?
}

for w in $WRAPPERS; do
    base="$(basename "$w")"
    if [ ! -f "$w" ]; then
        fail "C:$base" "wrapper not found"
        continue
    fi
    block="$(awk '/^# --- Rule 0\.8: the Ostler Pro subscription gate/,/^# --- end Rule 0\.8 gate/' "$w")"
    if [ -z "$block" ]; then
        fail "C:$base" "no Rule 0.8 gate block. This pipeline ingests new data for a customer who is not paying."
        continue
    fi

    harness="$TMPROOT/harness_${base}"
    {
        echo 'set -euo pipefail'
        echo "SOURCE_DIR='$HUB/services/imessage-source'"
        echo "OSTLER_DIR='$HUB'"
        echo "PYTHON_BIN='$PY'"
        echo "OSTLER_PYTHON='$PY'"
        echo 'log() { printf "%s\n" "$*"; }'
        echo "$block"
        echo 'echo REACHED_THE_PIPELINE'
    } > "$harness"

    if ! /bin/bash -n "$harness"; then
        fail "C:$base" "gate block does not parse under /bin/bash"
        continue
    fi

    # An unpaid customer, 31 days in.
    install_days_ago 31
    out="$(/bin/bash "$harness" 2>&1)"
    if printf '%s' "$out" | /usr/bin/grep -q "REACHED_THE_PIPELINE"; then
        fail "C:$base" "the pipeline ran for a customer 31 days in who never paid"
    else
        pass "C:$base" "paused before ingesting, day 31, never subscribed"
    fi

    # A paying customer must NOT be stopped.
    pay_for_pro_until_days_from_now 30
    out="$(/bin/bash "$harness" 2>&1)"
    if printf '%s' "$out" | /usr/bin/grep -q "REACHED_THE_PIPELINE"; then
        pass "C:$base(paid)" "a paying customer's ingestion runs"
    else
        fail "C:$base(paid)" "a PAYING customer was stopped. Output: $out"
    fi

    # POSITIVE CONTROL for the fail-open branch: hide the gate module and
    # confirm the wrapper still ingests. A gate that blocks when it cannot
    # be found turns a packaging slip into a mass lockout of paying
    # customers, and nothing else in this suite would notice.
    install_days_ago 31
    mv "$GATE" "$GATE.hidden"
    out="$(/bin/bash "$harness" 2>&1)"
    mv "$GATE.hidden" "$GATE"
    if printf '%s' "$out" | /usr/bin/grep -q "REACHED_THE_PIPELINE"; then
        pass "C:$base(failopen)" "gate module absent: ingestion continues and says so"
    else
        fail "C:$base(failopen)" "gate module absent and ingestion STOPPED. A packaging mistake must never read as a lapsed subscription."
    fi
done

# ---------------------------------------------------------------------
# Limb D -- the ical-server ingestion handlers
# ---------------------------------------------------------------------
echo "--- Limb D: ical-server ingestion handlers ---"

check_handler_gated() {
    # $1 = def name, $2 = surface label
    "$PY" - "$ICAL" "$1" "$2" <<'PYEOF'
import ast, sys
path, defname, surface = sys.argv[1], sys.argv[2], sys.argv[3]
tree = ast.parse(open(path).read())
fn = next((n for n in ast.walk(tree)
           if isinstance(n, ast.FunctionDef) and n.name == defname), None)
if fn is None:
    print(f"MISSING: no def {defname}")
    sys.exit(2)
# The gate must be the FIRST executable statement, not merely present.
# A check further down has already let the handler spend the customer's
# CPU, and in api_conversation_process it would have spawned the thread.
body = [s for s in fn.body if not (isinstance(s, ast.Expr)
                                   and isinstance(s.value, ast.Constant))]
if not body:
    print(f"EMPTY: {defname} has no body")
    sys.exit(2)
first = body[0]
src = ast.dump(first)
if "_subscription_paused" not in src:
    print(f"UNGATED: first statement of {defname} is not the subscription gate")
    sys.exit(1)
if repr(surface) not in src and f"'{surface}'" not in src:
    print(f"WRONGSURFACE: {defname} does not name the surface {surface!r}")
    sys.exit(1)
print(f"OK: {defname} gates on {surface} before doing anything")
PYEOF
}

for pair in "api_ingest_ios:ios_ingest" \
            "api_safari_ingest:safari_capture" \
            "api_conversation_process:conversation_transcription"; do
    d="${pair%%:*}"; s="${pair##*:}"
    out="$(check_handler_gated "$d" "$s" 2>&1)"
    if [ $? -eq 0 ]; then
        pass "D:$d" "$out"
    else
        fail "D:$d" "$out"
    fi
done

# ---------------------------------------------------------------------
# Limb E -- the derived path is the staged path
# ---------------------------------------------------------------------
echo "--- Limb E: the wrappers look where install.sh actually stages ---"

# install.sh must stage the WHOLE of assistant_api/ (which is what carries
# subscription_gate.py) into a directory named services/ical-server.
if /usr/bin/grep -q 'ICAL_SERVER_DIR="${OSTLER_DIR}/services/ical-server"' install.sh; then
    pass "E1" "install.sh stages the assistant API to \${OSTLER_DIR}/services/ical-server"
else
    fail "E1" "install.sh no longer stages to \${OSTLER_DIR}/services/ical-server. Every tick wrapper's derived gate path is now wrong, and all five will silently take the fail-open branch."
fi

if /usr/bin/grep -q 'cp -R "${SCRIPT_DIR}/assistant_api/\." "$ICAL_SERVER_DIR/"' install.sh; then
    pass "E2" "install.sh copies the whole assistant_api tree, so subscription_gate.py lands beside ical-server.py"
else
    fail "E2" "install.sh no longer copies the whole assistant_api tree. subscription_gate.py may not be staged at all."
fi

# The vendored source must carry the module that gets staged.
if [ -f "$GATE_SRC" ]; then
    pass "E3" "subscription_gate.py is in the vendored payload"
else
    fail "E3" "subscription_gate.py missing from the vendored payload"
fi

# The two vendored copies must not drift. They are byte-identical today;
# a fix applied to one and not the other ships half a fix.
if diff -q "$GATE_SRC" "vendor/cm052_ai_conversations/src/cm052/subscription_gate.py" >/dev/null 2>&1; then
    pass "E4" "the cm041 and cm052 copies of the gate are identical"
else
    fail "E4" "the cm041 and cm052 copies of the gate have DRIFTED. CM052's conversation wire is the one surface that already gated; a drifted copy means it enforces a different rule from everything else."
fi

# ---------------------------------------------------------------------
# Limb F -- the Rule 0.8 remainder, as a ratchet rather than a comment
# ---------------------------------------------------------------------
# Rule 0.8 names eleven surfaces. This PR enforces it on six. The other
# five are listed HERE, by file and symbol, and re-checked on every CI
# run, because the alternative is a paragraph in a markdown file that
# says "tracked" and is read by nobody -- which is what the rule already
# was for four months.
#
# The list is a RATCHET. Each entry asserts two things: the symbol still
# exists (a rename must not silently orphan the task), and it is still
# ungated. If you gate one, this limb goes RED and tells you to delete
# the line -- so the remainder can only ever shrink, and only on purpose.
# A count that can only go down is a task; a comment is not.
echo "--- Limb F: the Rule 0.8 remainder (ratchet) ---"

REMAINDER="
vendor/cm048_pipeline/src/processor.py|def process(|the pwg-convo enrichment engine; every source funnels through it. Gated upstream at each tick wrapper today, but a direct pwg-convo call bypasses that.
vendor/cm048_pipeline/src/reminders_push.py|def apply_push_status_to_todos(|Apple Reminders push. Has a demo_mode short-circuit to mirror.
vendor/ostler_fda/extract_all.py|def run_all(|calendar pulls AND photo intelligence, hourly under com.ostler.fda-rerun.
vendor/imessage_bridge/bin/bridge.py|def poll_once(|the live iMessage/SMS chat bridge (KeepAlive), separate from the 15-minute bundle tick.
vendor/cm041/meeting_syncer/brief.py|def pre_meeting_brief(|pre-meeting brief. Shipped disabled (INSTALL_MEETING_BRIEF_LAUNCHAGENT defaults false), so gate it before it is switched on.
"

remaining=0
printf '%s\n' "$REMAINDER" | while IFS='|' read -r rf rsym rwhy; do
    [ -z "${rf:-}" ] && continue
    echo "  UNGATED  $rf  ($rsym)  -- $rwhy"
done

# Checked outside the pipe, because a `while` in a pipeline runs in a
# subshell and its counter never reaches the parent. That is the same
# shape of bug as everything else in this file: a value written where
# nothing can read it.
for entry in \
  "vendor/cm048_pipeline/src/processor.py|def process(" \
  "vendor/cm048_pipeline/src/reminders_push.py|def apply_push_status_to_todos(" \
  "vendor/ostler_fda/extract_all.py|def run_all(" \
  "vendor/imessage_bridge/bin/bridge.py|def poll_once(" \
  "vendor/cm041/meeting_syncer/brief.py|def pre_meeting_brief("
do
    rf="${entry%%|*}"; rsym="${entry##*|}"
    if [ ! -f "$rf" ]; then
        fail "F" "$rf is gone. The Rule 0.8 remainder points at a file that no longer exists; re-find the surface or delete the entry."
        continue
    fi
    if ! /usr/bin/grep -qF "$rsym" "$rf"; then
        fail "F" "$rf no longer defines '$rsym'. Renamed? The remainder task just lost its subject."
        continue
    fi
    if /usr/bin/grep -qF "is_active_or_grace" "$rf" || /usr/bin/grep -qF "subscription_gate" "$rf"; then
        fail "F" "$rf now references the subscription gate. Good -- now DELETE its line from the REMAINDER list in this test, so the count is true."
        continue
    fi
    remaining=$((remaining + 1))
done

# Positive control for the grep predicate above: it must FIND the gate in
# a file that has it. Without this, a broken -qF would report every file
# as ungated and the ratchet would be stuck at five forever.
if /usr/bin/grep -qF "is_active_or_grace" "vendor/cm052_ai_conversations/src/cm052/wire.py"; then
    pass "F:control" "the 'is it gated' predicate finds the gate in wire.py, the surface that was already gated"
else
    fail "F:control" "the predicate cannot find is_active_or_grace in wire.py, where it demonstrably is. Every 'UNGATED' verdict above is meaningless."
fi

echo "  Rule 0.8: 6 of 11 surfaces enforced, $remaining ungated surfaces remain in this repo."
echo "  Two further surfaces (daily briefs, local AI chat about new data) live in"
echo "  the prebuilt ostler-assistant daemon and CANNOT be gated from this repo:"
echo "  zero Cargo.toml and zero .rs files here, against 515 .py as a control."
if [ "$remaining" -ne 5 ]; then
    fail "F" "expected 5 ungated surfaces, counted $remaining. Update the list deliberately; do not let the number drift."
else
    pass "F" "the remainder is 5, each still present and still ungated"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS: the trial ends, the paid-once rule holds, and six ingestion surfaces stop for an unpaid Hub."
    exit 0
fi
echo "$fails check(s) FAILED"
exit 1
