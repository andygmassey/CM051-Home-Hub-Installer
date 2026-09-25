#!/usr/bin/env bash
# scripts/tests/test_grounded_probe_names_the_store_and_refuses_a_blind_turn.sh
# ============================================================================
# THE GUARD FOR CM051 #1125, #1597 AND THE PROBE-SIDE HALF OF #1113.
#
# assistant_answers_grounded is BLOCKING. All three rows report the same class
# of defect: the probe GRADING SOMETHING IT COULD NOT SEE, and reporting the
# result as `grounded`. A gate that cannot fail is indistinguishable from a
# clean sheet.
#
# WHAT WAS MEASURED ON origin/main e0fb21bf, BEFORE THE FIX
#
#   #1125  The adjudicator's success arm was `^FRAME tool_result pwg_.* OK$`.
#          Any graph tool satisfied it. Studio, n=10 per cell, quantisation the
#          only variable: "What are my interests?" answered by pwg_overview
#          9/10 on Q4_K_M and by pwg_preferences 10/10 on Q8_0. THE PROBE
#          SCORED BOTH 10/10 GROUNDED. pwg_overview returns how many
#          preferences the graph holds. A customer who asks what their
#          interests are and is told a number has not been told their
#          interests.
#
#   #1597  The same arm's FALLTHROUGH was `echo "grounded"`. Measured here,
#          three transcripts with a pwg tool CALLED and not one pwg tool_result
#          frame anywhere -- no result at all, a result the client could not
#          parse, and a result from a non-pwg tool -- each adjudicated
#          `grounded`. Zero successes, zero errors, zero empties, and the probe
#          reported that the customer's data had been reached.
#
#   #1113  A walk read "2 of 3 questions did not reach the customer's own data:
#          [no_tool_call] [no_tool_call]" while the daemon's own telemetry for
#          those turns said `tools=` EMPTY -- no tools were offered, so
#          tool_calls=0 was not the model declining. The probe printed the same
#          token for that as for a model holding eight graph tools and reaching
#          for none. Different defects, different owners, one word.
#
# WHAT THIS FILE ASSERTS. Six arms, each with its own control:
#
#   1  THE PROBE'S OWN CONTROL FIRES, and its declared denominator matches the
#      arms actually in the file. A denominator nobody recounts is decoration.
#   2  THE PRE-FIX ADJUDICATOR IS THE CONTROL, carried here verbatim because a
#      squash merge orphans its commit. It must return `grounded` on all four
#      transcripts the fixed one now refuses or names. If it does not, the
#      fixtures no longer describe the bug and this file CANNOT-RUN.
#   3  THE FIXED ADJUDICATOR, extracted from the live probe, returns
#      wrong_store, no_tool_result and no_expected_tools on those same files,
#      and still returns grounded on the must-miss beside each one.
#   4  EVERY TOOL THE BATTERY NAMES IS ONE THE RUNTIME REGISTERS, cross-read
#      from the sibling probe rather than copied. A store set naming a tool
#      that does not exist is a gate nothing can satisfy, and it fails looking
#      exactly like a product defect.
#   5  MUTANTS. Each defect is reintroduced one line at a time and the probe's
#      --self-test must report CONTROL DID NOT FIRE. A guard that survives its
#      own defect is decoration.
#   6  THE SCANNER, BLINDED. With the sibling probe removed, or its
#      REQUIRED_TOOLS line unreadable, the probe must REFUSE rather than pass.
#      An absence check that goes quiet when its apparatus dies is the failure
#      mode this whole suite exists to avoid.
#
# NO FIXTURE HERE CARRIES A FIELD THE REAL BOX NEVER EMITS. Every FRAME line
# below is one the embedded WebSocket client prints (`FRAME tool_call <name>`,
# `FRAME tool_result <name> OK|ERR|EMPTY`, `FRAME unparseable`, `FRAME done`),
# and every tool name is from the runtime registry arm 4 checks. A fixture that
# carried a marker the product never produces would prove only that this file
# can talk to itself.
#
# Exit: 0 all arms behaved, 1 an arm failed, 2 could not run.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PROBE_DIR="$REPO_ROOT/scripts/box_walk_probes/probes"
PROBE="$PROBE_DIR/assistant_answers_grounded.sh"
SIBLING="$PROBE_DIR/assistant_prompt_names_every_pwg_tool.sh"
LIB_DIR="$REPO_ROOT/scripts/box_walk_probes/lib"
RC_FAIL=1; RC_CANNOT_RUN=2

PASSES=0
cannot_run() { echo "" >&2; echo "CANNOT-RUN: $1" >&2; echo "  NOTHING was established. This is not a pass." >&2; exit "$RC_CANNOT_RUN"; }
fail() { echo "FAIL [$1]: $2" >&2; exit "$RC_FAIL"; }
ok()   { PASSES=$((PASSES+1)); echo "PASS [$1]: $2"; }
count() { printf '%s\n' "$2" | grep -cF -- "$1"; }

for need in diff sed awk grep; do
    command -v "$need" >/dev/null 2>&1 || cannot_run "$need not on PATH"
done
[[ -f "$PROBE" ]]   || cannot_run "no probe at $PROBE"
[[ -f "$SIBLING" ]] || cannot_run "no sibling probe at $SIBLING; arm 4 has nothing to cross-read and an uncrossed map is not a checked map"
[[ -f "$LIB_DIR/probe.sh" ]] || cannot_run "no probe lib at $LIB_DIR/probe.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/groundedstore.XXXXXX")" || cannot_run "could not create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# The store sets the battery really declares. Read from the probe, so a fixture
# here cannot be graded against a set no question carries.
PERSON='pwg_people pwg_person_timeline'
TASTES='pwg_preferences'
REGISTRY="$(sed -n "s/^_TOOL_REGISTRY='\(.*\)'$/\1/p" "$PROBE" | head -1)"
[[ -n "$REGISTRY" ]] || cannot_run "could not read _TOOL_REGISTRY from the probe; every arm below would be measuring an empty set"

# ── THE FIXTURES, all four measured as `grounded` on origin/main e0fb21bf ──
# #1125: the inventory tool answering a question about content.
printf 'FRAME session_start\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' > "$WORK/wrong_store"
# #1597: a graph tool called and no result for it ever observed, three ways.
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME done\n' > "$WORK/no_result"
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME unparseable\nFRAME done\n' > "$WORK/unparseable"
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result memory_recall OK\nFRAME done\n' > "$WORK/nonpwg_result"
# The MUST-MISSES that sit beside them: the right store, and the same frames on
# the broad opener, which the shipped guidance does not restrict.
printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME done\n' > "$WORK/right_store"
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME done\n' > "$WORK/observed"

# ── arm 1: the probe's own control fires, and its denominator is recounted ──
out="$(/bin/bash "$PROBE" --self-test 2>&1)"; rc=$?
[[ "$rc" -eq 1 ]] || fail arm-1 "--self-test exited ${rc}, expected 1. The box-walk runner marks a probe BROKEN unless its self-test goes red, and a negative control that cannot go red proves nothing: ${out}"
[[ "$(count 'VERDICT: BROKEN' "$out")" -eq 0 ]] || fail arm-1 "--self-test reported BROKEN: ${out}"
declared="$(printf '%s\n' "$out" | sed -n 's/^EXAMINED: \([0-9]*\) .*$/\1/p' | head -1)"
[[ -n "$declared" ]] || cannot_run "the probe's self-test printed no EXAMINED count, so there is no denominator to recount"
# RECOUNT IT FROM THE FILE. A declared denominator that nobody checks drifts
# away from the arms it claims to count, and then it is a number, not evidence.
a_ok=$(grep -c '|| _ok=0' "$PROBE")
rollups=$(grep -cE '\[ "\$_(name|map)_ok" -eq 1 \] \|\| _ok=0' "$PROBE")
a_name=$(grep -c '|| _name_ok=0' "$PROBE")
a_map=$(grep -c '_map_ok=0' "$PROBE")
a_rt=$(grep -cE '^    _rt ' "$PROBE")
actual=$(( a_ok - rollups + a_name + a_map + a_rt ))
[[ "$declared" -eq "$actual" ]] || fail arm-1 "the self-test declares EXAMINED: ${declared} and the file carries ${actual} arms ($(( a_ok - rollups )) adjudicator + ${a_name} name + ${a_map} map + ${a_rt} routing). A denominator that does not match its arms cannot be audited."
ok arm-1 "the probe's --self-test fires (rc=1) and its declared denominator ${declared} matches the ${actual} arms counted in the file"

# ── arm 2: the pre-fix adjudicator is the control ───────────────────────────
# Verbatim from origin/main e0fb21bf. It has no store set and no refusal.
cat > "$WORK/prefix.sh" <<'FIXTURE'
_GRAPH_TOOL_RE='^FRAME tool_call pwg_'
adjudicate_turn() {
    _t="$1"
    grep -q '^PROBE_FATAL' "$_t" && { echo "fatal"; return; }
    grep -q '^FRAME done$' "$_t" || { echo "incomplete"; return; }
    grep -q '^FRAME tool_call ' "$_t" || { echo "no_tool_call"; return; }
    grep -qE "$_GRAPH_TOOL_RE" "$_t" || { echo "memory_only"; return; }
    grep -q '^FRAME reply_fact NO$' "$_t" && { echo "fact_missing"; return; }
    grep -q '^FRAME tool_result pwg_.* OK$' "$_t" && { echo "grounded"; return; }
    grep -q '^FRAME tool_result pwg_.* ERR$' "$_t" && { echo "tool_error"; return; }
    grep -q '^FRAME tool_result pwg_.* EMPTY$' "$_t" && { echo "tool_found_nothing"; return; }
    echo "grounded"
}
FIXTURE
pre() { bash -c '. "$1"; adjudicate_turn "$2"' _ "$WORK/prefix.sh" "$1"; }
for f in wrong_store no_result unparseable nonpwg_result; do
    v="$(pre "$WORK/$f")"
    [[ "$v" == "grounded" ]] || cannot_run "the pre-fix control returned '${v}' on ${f}, not grounded. The fixture no longer describes the bug, so arm 3 would be measuring nothing."
done
ok arm-2 "the pre-fix adjudicator returns grounded on all 4 fixtures: the wrong-store shape (#1125) and all three unobserved shapes (#1597)"

# ── arm 3: the fixed adjudicator names the store and refuses the blind turn ──
awk '/^adjudicate_turn\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$PROBE" > "$WORK/fixed_body.sh"
[[ -s "$WORK/fixed_body.sh" ]] || cannot_run "could not extract adjudicate_turn from the probe"
awk '/^_result_mark\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$PROBE" >> "$WORK/fixed_body.sh"
grep -q '^_result_mark() {' "$WORK/fixed_body.sh" || cannot_run "could not extract _result_mark from the probe; adjudicate_turn would fall over on every arm and every arm would read as the fix working"
post() { bash -c '_GRAPH_TOOL_RE="^FRAME tool_call pwg_"; . "$1"; adjudicate_turn "$2" "$3"' _ "$WORK/fixed_body.sh" "$1" "${2-}"; }
check() {  # check <fixture> <store set> <expected> <why>
    v="$(post "$WORK/$1" "$2")"
    [[ "$v" == "$3" ]] || fail arm-3 "${1} with store set '${2}' returned '${v}', expected ${3} -- ${4}"
}
check wrong_store    "$TASTES"   wrong_store       "an inventory count is being accepted as the customer's interests (#1125)"
check wrong_store    "$REGISTRY" grounded          "the broad opener is unconstrained by the shipped guidance and must not go red on pwg_overview"
check right_store    "$TASTES"   grounded          "the fix must narrow the verdict, not redden the question"
check no_result      "$PERSON"   no_tool_result    "a graph call whose outcome was never seen is not a grounded turn (#1597)"
check unparseable    "$PERSON"   no_tool_result    "an unparseable result frame is not a successful read"
check nonpwg_result  "$PERSON"   no_tool_result    "a non-pwg result cannot stand in for the graph read that never arrived"
check observed       "$PERSON"   grounded          "the same call WITH its result is grounded, so the arm fires on the missing observation and not on the call"
check right_store    ""          no_expected_tools "with no store set the adjudicator must REFUSE, never grade on a prefix"
ok arm-3 "the fixed adjudicator returns wrong_store, no_tool_result and no_expected_tools where the pre-fix one returned grounded, and still returns grounded on all 3 must-misses"

# ── arm 4: every tool the battery names is one the runtime registers ─────────
sib_tools="$(sed -n 's/^REQUIRED_TOOLS="\(.*\)"$/\1/p' "$SIBLING" | head -1)"
[[ -n "$sib_tools" ]] || cannot_run "could not read REQUIRED_TOOLS from ${SIBLING}; an unread registry would make every membership test below vacuously true"
# POSITIVE CONTROL FIRST, on a value the reader MUST find. If this is absent
# the reader is broken and its silence about the rest means nothing.
grep -qw 'pwg_preferences' <<<"$sib_tools" || cannot_run "the registry read back without pwg_preferences, which the battery's own routing clause names. The reader is wrong, not the map."
battery_tools="$(sed -n '/^_questions() {/,/^}/p' "$PROBE" | sed -n 's/.*\t//p' | tr ' ' '\n' | grep -E '^pwg_' | sort -u)"
[[ -n "$battery_tools" ]] || cannot_run "read no tools out of the battery; the tab-separated store column is not being parsed and arm 4 would pass on an empty set"
unknown=""
while read -r t; do
    [[ -n "$t" ]] || continue
    grep -qw -- "$t" <<<"$sib_tools" || unknown="${unknown} ${t}"
done <<<"$battery_tools"
[[ -z "$unknown" ]] || fail arm-4 "the battery names tool(s) the runtime does not register:${unknown}. That is a gate nothing can satisfy, and every turn on that question would score wrong_store forever while looking like a product defect."
# NEGATIVE CONTROL: the same reader must REJECT a tool that is not registered.
grep -qw 'pwg_invented' <<<"$sib_tools" && fail arm-4 "the membership reader accepted pwg_invented, so it would accept anything"
# AND THE OTHER TWO THIRDS OF THE MAP. The broad opener's set is the literal
# text ${_TOOL_REGISTRY}, so the scan above sees only the 3 tools spelled out
# in the constrained rows. Saying "all tools in the battery are registered"
# while having read a third of them would be a uniform zero wearing a verdict,
# so _TOOL_REGISTRY is compared against the sibling in BOTH directions here.
reg_diff=""
for t in $REGISTRY; do
    grep -qw -- "$t" <<<"$sib_tools" || reg_diff="${reg_diff} +${t}"
done
for t in $sib_tools; do
    grep -qw -- "$t" <<<"$REGISTRY" || reg_diff="${reg_diff} -${t}"
done
[[ -z "$reg_diff" ]] || fail arm-4 "the probe's _TOOL_REGISTRY and the runtime registry disagree:${reg_diff} (+ in the probe only, - in the runtime only). The broad opener's set would then be wrong in one direction or the other."
ok arm-4 "the $(grep -c . <<<"$battery_tools") tools spelled out in the battery and all $(wc -w <<<"$REGISTRY" | tr -d ' ') in _TOOL_REGISTRY are in the runtime registry ($(wc -w <<<"$sib_tools" | tr -d ' ') tools), in both directions, and the reader rejects an unregistered name"

# ── arm 5: mutants ──────────────────────────────────────────────────────────
mkdir -p "$WORK/mut/probes"; ln -sfn "$LIB_DIR" "$WORK/mut/lib"
cp "$SIBLING" "$WORK/mut/probes/"
MUT="$WORK/mut/probes/assistant_answers_grounded.sh"
mutate() {  # mutate <label> <sed expr>
    sed -e "$2" "$PROBE" > "$MUT"
    local changed; changed=$(diff "$PROBE" "$MUT" | grep -c '^<')
    [[ "$changed" -ge 1 ]] || cannot_run "mutant '${1}' did not land (0 lines changed). A mutant that did not apply looks exactly like one that was not caught."
    local mout; mout="$(/bin/bash "$MUT" --self-test 2>&1)"
    [[ "$(count 'CONTROL DID NOT FIRE' "$mout")" -ge 1 ]] || fail arm-5 "mutant SURVIVED: ${1}. The probe's self-test still fired cleanly with the defect back in place, so the guard is decoration."
}
mutate "#1597 the fallthrough returns to echo grounded" \
    's/^    echo "no_tool_result"$/    echo "grounded"/'
mutate "#1125 any pwg OK counts as grounded again" \
    's|^    _result_mark "\$_t" OK "\$_accept" \&\& { echo "grounded"; return; }$|    grep -q "^FRAME tool_result pwg_.* OK$" "$_t" \&\& { echo "grounded"; return; }|'
mutate "#1125 the wrong_store arm is deleted" \
    's/^    grep -q .\^FRAME tool_result pwg_\.\* OK\$. "\$_t" \&\& { echo "wrong_store"; return; }$//'
mutate "an empty store set grades instead of refusing" \
    's/^    \[ -n "\$_accept" \] || { echo "no_expected_tools"; return; }$//'
mutate "wrong_store is demoted from defect to ok" \
    's/^        no_tool_call|memory_only|tool_error|tool_found_nothing|fact_missing|wrong_store)$/        no_tool_call|memory_only|tool_error|tool_found_nothing|fact_missing)/'
mutate "no_tool_result is promoted to a product defect" \
    's/^        no_tool_call|memory_only|tool_error|tool_found_nothing|fact_missing|wrong_store)$/        no_tool_call|memory_only|tool_error|tool_found_nothing|fact_missing|wrong_store|no_tool_result)/'
mutate "the interests question is widened to the whole registry" \
    's/^What are my interests?\tpwg_preferences$/What are my interests?\t${_TOOL_REGISTRY}/'
mutate "the interests question readmits pwg_overview" \
    's/^What are my interests?\tpwg_preferences$/What are my interests?\tpwg_preferences pwg_overview/'
mutate "the contacts question loses its store set" \
    's/^Who have I been in contact with recently?\tpwg_people pwg_person_timeline$/Who have I been in contact with recently?\t/'
mutate "the battery names a tool the runtime does not register" \
    's/^_TOOL_REGISTRY=.*$/_TOOL_REGISTRY="pwg_overview pwg_people pwg_person_timeline pwg_preferences pwg_knowledge_search pwg_decisions pwg_topics pwg_invented"/'
ok arm-5 "all 10 mutants are caught: each reintroduced defect makes the probe's --self-test report CONTROL DID NOT FIRE"

# ── arm 6: the scanner, blinded ─────────────────────────────────────────────
# The map control reads the sibling probe. If that read can fail silently the
# control is worthless, so it must REFUSE when its own apparatus is gone.
cp "$PROBE" "$MUT"
rm -f "$WORK/mut/probes/assistant_prompt_names_every_pwg_tool.sh"
bout="$(/bin/bash "$MUT" --self-test 2>&1)"
[[ "$(count 'CONTROL DID NOT FIRE' "$bout")" -ge 1 ]] || fail arm-6 "with the sibling probe REMOVED the probe's self-test still fired cleanly. An absence check that goes quiet when its apparatus dies passes on anything."
[[ "$(count 'store-map control: CANNOT-RUN' "$bout")" -ge 1 ]] || fail arm-6 "the blinded scanner did not say so; it must name what it could not read"
sed 's/^REQUIRED_TOOLS=.*$/REQUIRED_TOOLS_RENAMED="x"/' "$SIBLING" > "$WORK/mut/probes/assistant_prompt_names_every_pwg_tool.sh"
bout2="$(/bin/bash "$MUT" --self-test 2>&1)"
[[ "$(count 'CONTROL DID NOT FIRE' "$bout2")" -ge 1 ]] || fail arm-6 "with REQUIRED_TOOLS unreadable the self-test still fired cleanly, so an empty read is being taken as agreement"
# POSITIVE CONTROL: restore the sibling and the same scanner must go quiet.
cp "$SIBLING" "$WORK/mut/probes/"
bout3="$(/bin/bash "$MUT" --self-test 2>&1)"
[[ "$(count 'CONTROL DID NOT FIRE' "$bout3")" -eq 0 ]] || fail arm-6 "with the sibling restored the self-test STILL did not fire, so arms above were measuring a broken harness rather than the fix"
ok arm-6 "blinding the scanner (sibling removed, then its registry line unreadable) makes the probe refuse, and restoring it makes the same scanner go quiet"

# ── arm 7: #1113, TOOLS OFFERED vs TOOLS DECLINED ───────────────────────────
#
# The probe-side half of #1113. A walk read "2 of 3 questions did not reach the
# customer's own data: [no_tool_call] [no_tool_call]" while the daemon's own
# telemetry said `tools=` EMPTY. One token, two states, two owners: a model
# that held eight graph tools and reached for none is a ROUTING defect; a model
# that was never offered any is a TOOL AVAILABILITY defect. The probe cannot
# read the daemon's telemetry line and does not pretend to. It can count what
# it already has: the battery asks several questions against the same daemon in
# one run, so a tool_call frame on ANY turn is in-band evidence, from this box,
# that tools were offered.
#
# The discriminator must NOT change the verdict. Zero tools offered is a worse
# product failure, not a lesser one, and a customer whose assistant holds no
# graph tools cannot be answered from their own data at all.
#
# This drives the REAL run_probe, because the discriminator lives in the loop
# and not in adjudicate_turn. The probe's own self-test cannot reach it.
H="$WORK/h1113.sh"
run_battery() {  # run_battery <probe path> <turn per battery question> -> full verdict line
                 # ONE TURN PER QUESTION. The battery gained a fourth in #1162
                 # (the rephrasing half of the declared pair); a call short of
                 # one turn leaves the last question `incomplete`, which makes
                 # the whole probe CANNOT-RUN and every arm here vacuous.
    local probe="$1"; shift
    local i=1 t
    rm -f "$WORK"/ans.*
    for t in "$@"; do
        case "$t" in
            grounded_prefs)  printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME done\n' ;;
            grounded_people) printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME done\n' ;;
            grounded_all)    printf 'FRAME session_start\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' ;;
            notool)          printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n' ;;
        esac > "$WORK/ans.$i"
        i=$((i+1))
    done
    cat > "$H" <<HDR
set -uo pipefail
PROBE_EX_PASS=0; PROBE_EX_FAIL=1; PROBE_EX_CANNOT_RUN=2
PROBE_EXAMINED_SET=1
probe_examined() { printf 'EXAMINED: %s %s\n' "\$1" "\$2"; }
probe_note()     { :; }
probe_pass()       { printf 'PASS %s\n' "\$1"; exit 0; }
probe_fail()       { printf 'FAIL %s\n' "\$1"; exit 1; }
probe_cannot_run() { printf 'CANNOT-RUN %s\n' "\$1"; exit 2; }
box_reachable() { return 0; }
_N_F="${WORK}/n1113"; : > "\$_N_F"
box_run() {
  case "\$1" in
    *base64*|*"rm -f"*) return 0 ;;
    *python3*)
      printf 'x' >> "\$_N_F"
      _i=\$(wc -c < "\$_N_F" | tr -d ' ')
      cat "${WORK}/ans.\$_i" 2>/dev/null
      return 0 ;;
    *) return 0 ;;
  esac
}
HDR
    grep -v -e '^\. "' -e '^source ' -e '^probe_main ' "$probe" >> "$H"
    printf 'run_probe\n' >> "$H"
    bash "$H" 2>/dev/null | grep -E '^(PASS|FAIL|CANNOT-RUN) ' | head -1
}
# CONTROL FIRST. A healthy battery must PASS through this harness, or every arm
# below is measuring the harness. Each turn reads a store its own question
# declares: overview for the broad opener, preferences for tastes, people for
# contacts.
ctl="$(run_battery "$PROBE" grounded_all grounded_prefs grounded_people grounded_prefs)"
[[ "$ctl" == PASS* ]] || cannot_run "a healthy battery produced '${ctl}' through this harness; the harness is wrong, not the probe"
# (a) NOTHING was offered: no turn produced a tool call at all.
none="$(run_battery "$PROBE" notool notool notool notool)"
[[ "$none" == FAIL* ]] || fail arm-7 "a battery in which no question reached the graph produced '${none}', not FAIL. Zero tools offered is a worse product failure, not a lesser one."
[[ "$(count 'NOT established that the model was offered any tools' "$none")" -ge 1 ]] || fail arm-7 "with zero tool calls anywhere the FAIL did not say tool availability is unproven, so it still reads as the model declining tools it held: ${none}"
# (b) Tools WERE offered: one turn called a tool, two did not.
some="$(run_battery "$PROBE" grounded_all notool notool notool)"
[[ "$some" == FAIL* ]] || fail arm-7 "two ungrounded turns beside one grounded one produced '${some}', not FAIL"
[[ "$(count 'Tools WERE offered on this box' "$some")" -ge 1 ]] || fail arm-7 "with a tool call on one turn the FAIL did not attribute the other two to routing: ${some}"
# MUST-MISS, both directions: the two messages must not be interchangeable.
[[ "$(count 'Tools WERE offered on this box' "$none")" -eq 0 ]] || fail arm-7 "the zero-tool-call battery claimed tools were offered"
[[ "$(count 'NOT established that the model was offered any tools' "$some")" -eq 0 ]] || fail arm-7 "the battery WITH a tool call claimed tool availability was unproven"
# MUTANT: freeze the counter at zero. Every battery then reads as "tools
# unproven", including one that demonstrably called a tool, so the
# discriminator would be a constant wearing the shape of a measurement.
sed -e 's/^            _turns_with_tool_call=$(( _turns_with_tool_call + 1 ))$/            :/' "$PROBE" > "$MUT"
[[ "$(diff "$PROBE" "$MUT" | grep -c '^<')" -eq 1 ]] || cannot_run "the #1113 counter mutant did not land"
msome="$(run_battery "$MUT" grounded_all notool notool notool)"
[[ "$(count 'Tools WERE offered on this box' "$msome")" -eq 0 ]] || fail arm-7 "the counter mutant still reported tools offered, so this arm is not reading the counter"
ok arm-7 "a battery with no tool call anywhere says tool availability is UNPROVEN, one with a tool call attributes the misses to routing, both still FAIL, and freezing the counter is caught"

echo ""
echo "ALL ${PASSES} ARMS PASSED: the grounded probe names the store that could hold the answer (#1125), refuses a turn whose retrieval was never observed (#1597), distinguishes tools-never-offered from tools-declined (#1113), and its battery map is checked against the runtime registry"
exit 0
