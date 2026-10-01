#!/usr/bin/env bash
# scripts/tests/test_read_only_walk_never_writes.sh
# ============================================================================
# CM051 #2564. `run_box_walk.sh --only <probe>` used to run every seed
# (grounding, preference, conversation, usage), kickstart the wiki recompile
# LaunchAgent, and run them UNCONDITIONALLY: they are plain top-to-bottom
# statements between phase 1 and phase 2, with no relation to which probe
# `--only` selected. On a live walk this wrote a synthetic person into
# Andy's own box while he was using it for something else -- `--only` read
# as "just check this one thing" and seeded the graph anyway.
#
# This stages a copy of box_walk_probes with the five writer functions
# replaced by stubs that leave a SENTINEL file if called, and two trivial
# probe stubs. It then runs the real runner, unmodified, against that tree,
# and checks which sentinels exist afterward. The sentinel is the only
# oracle: an exit code or a log line could lie about this the same way
# `|| true` already swallows every seed's own exit code.
#
# ARM 0 is a POSITIVE CONTROL: a full run, no flags, must leave every
# sentinel. Without it, every "no sentinel" result below would be
# indistinguishable from the stubs never being wired up at all -- the same
# shape of false green this suite exists to catch elsewhere (see
# run_probe_self_test's own doc in run_box_walk.sh).
#
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
# BASH 3.2 (macOS system bash) -- no associative arrays, no mapfile. No
# `timeout` binary on macOS either; the perl alarm wrapper is lifted from
# test_run_box_walk_records_phase1_verdicts.sh in this same directory.
# ============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../box_walk_probes"
[ -f "${SRC}/run_box_walk.sh" ] || { echo "CANNOT-RUN: no runner at ${SRC}/run_box_walk.sh"; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no scratch dir"; exit 78; }
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

WRITERS="grounding preference conversation usage wiki_wait"

# ---------------------------------------------------------------------------
# Stage a tree: the real runner, stub libs that sentinel instead of writing,
# and two probe stubs that are not people_count_agreement/people_stores_
# reconcile (those gate a real converge_wait, which this test does not stub).
# ---------------------------------------------------------------------------
_stage() {   # $1 = tree name under $WORK -> prints its path
    local t="${WORK}/$1"
    cp -R "$SRC" "$t"
    rm -f "$t"/probes/*.sh

    cat > "$t/probes/stub_pass.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--self-test" ] && exit 1
echo "VERDICT: PASS -- stub"
exit 0
EOF
    cp "$t/probes/stub_pass.sh" "$t/probes/stub_pass_two.sh"
    chmod +x "$t"/probes/*.sh

    local sentinels="${WORK}/sentinels-$1"
    mkdir -p "$sentinels"

    cat > "$t/lib/grounding_seed.sh" <<EOF
GROUNDING_SEED_STATE="unrun"
grounding_seed_apply() { touch "${sentinels}/grounding"; GROUNDING_SEED_STATE="seeded"; return 0; }
EOF
    cat > "$t/lib/preference_seed.sh" <<EOF
preference_seed_apply() { touch "${sentinels}/preference"; return 0; }
EOF
    cat > "$t/lib/conversation_seed.sh" <<EOF
conversation_seed_apply() { touch "${sentinels}/conversation"; return 0; }
EOF
    cat > "$t/lib/usage_seed.sh" <<EOF
usage_seed_apply() { touch "${sentinels}/usage"; return 0; }
EOF
    cat > "$t/lib/wiki_summaries_wait.sh" <<EOF
wiki_summaries_wait() { touch "${sentinels}/wiki_wait"; WIKI_WAIT_STATE="unrun"; WIKI_WAIT_DETAIL=""; return 0; }
EOF
    printf '%s' "$t"
}

_sentinels_for() { printf '%s/sentinels-%s' "$WORK" "$1"; }

# Runs the staged tree's runner. Never against a real box: OSTLER_BOX_HOST is
# a TLD reserved by RFC 2606 for exactly this (instant NXDOMAIN, no hang),
# the same host the sibling phase-1 test in this directory already uses.
_run() {   # tree, extra args...
    local t="$1"; shift
    ( cd "$t" && OSTLER_BOX_HOST=fake.invalid \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh "$@" ) \
        > "${t}/out.txt" 2>&1
}

_assert_no_sentinels() {   # label, tree-name
    local label="$1" name="$2" s miss=0
    s="$(_sentinels_for "$name")"
    for w in $WRITERS; do
        if [ -e "${s}/${w}" ]; then
            bad "${label}: ${w} wrote its sentinel -- a writer ran"
            miss=1
        fi
    done
    [ "$miss" -eq 0 ] && ok "${label}: no writer ran (0 of 5 sentinels)"
}

_assert_all_sentinels() {   # label, tree-name
    local label="$1" name="$2" s miss=0
    s="$(_sentinels_for "$name")"
    for w in $WRITERS; do
        [ -e "${s}/${w}" ] || { bad "${label}: ${w} never ran (its sentinel is absent)"; miss=1; }
    done
    [ "$miss" -eq 0 ] && ok "${label}: every writer ran (5 of 5 sentinels)"
}

# ---------------------------------------------------------------------------
printf -- '--- arm 0: POSITIVE CONTROL -- a full run with no flags writes everything ---\n'
T="$(_stage arm0)"
_run "$T"
_assert_all_sentinels "full run, no flags" arm0

printf -- '--- arm 1: THE REGRESSION ITSELF -- --only defaults to read-only ---\n'
T="$(_stage arm1)"
_run "$T" --only stub_pass
_assert_no_sentinels "--only stub_pass, no --allow-writes" arm1

printf -- '--- arm 2: --only --allow-writes opts back in ---\n'
T="$(_stage arm2)"
_run "$T" --only stub_pass --allow-writes
_assert_all_sentinels "--only stub_pass --allow-writes" arm2

printf -- '--- arm 3: --read-only forces it on a FULL run too ---\n'
T="$(_stage arm3)"
_run "$T" --read-only
_assert_no_sentinels "--read-only, no --only" arm3

printf -- '--- arm 4: --read-only and --allow-writes together is refused, not resolved silently ---\n'
T="$(_stage arm4)"
_run "$T" --read-only --allow-writes
if grep -q 'read-only.*allow-writes\|allow-writes.*read-only' "${T}/out.txt"; then
    ok "contradictory flags are refused with a named reason"
else
    bad "contradictory flags were not refused: $(tail -n 3 "${T}/out.txt" | tr '\n' ' ')"
fi
_assert_no_sentinels "--read-only --allow-writes (refused before anything ran)" arm4

printf -- '--- arm 5: a box marked in-use refuses writes on a FULL run, before any probe runs ---\n'
T="$(_stage arm5)"
MARKER="${T}/fake-walk-in-use"
touch "$MARKER"
( cd "$T" && OSTLER_WALK_IN_USE_MARKER="$MARKER" perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh ) \
    > "${T}/out.txt" 2>&1
_assert_no_sentinels "full run against a marked box, no --allow-writes" arm5
if grep -qF 'exists on the target box' "${T}/out.txt"; then
    ok "the marker refusal names the marker"
else
    bad "no marker-refusal message found: $(tail -n 5 "${T}/out.txt" | tr '\n' ' ')"
fi
if grep -q -- '--- PHASE 1' "${T}/out.txt"; then
    bad "phase 1 started after the marker refusal -- it did not stop the walk"
else
    ok "refused before phase 1 (self-tests) ever started"
fi

printf -- '--- arm 6: --allow-writes is the one thing that gets past a marked box ---\n'
T="$(_stage arm6)"
MARKER="${T}/fake-walk-in-use"
touch "$MARKER"
( cd "$T" && OSTLER_WALK_IN_USE_MARKER="$MARKER" perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh --allow-writes ) \
    > "${T}/out.txt" 2>&1
_assert_all_sentinels "marked box, --allow-writes" arm6

# ---------------------------------------------------------------------------
# MUTATION CONTROL. A test that has only ever seen the fixed code has been
# run, not tested (see "Has that test ever failed?" -- CLAUDE.md). Strip the
# `--only`-implies-read-only guard the same way the real defect shipped it
# and confirm arm 1's assertion actually goes red against the regressed
# source, not just against a tree that happens to behave.
# ---------------------------------------------------------------------------
printf -- '--- mutation control: removing the --only-implies-read-only guard must flip arm 1 ---\n'
T="$(_stage mut)"
before=$(grep -cF 'if [ -n "$ONLY" ] && [ "$ALLOW_WRITES" -ne 1 ]; then' "$T/run_box_walk.sh")
if [ "$before" -ne 1 ]; then
    bad "mutant anchor count ${before}, expected 1 -- the guard this test depends on moved"
else
    # Force READ_ONLY to stay 0 regardless of --only: the exact shape of the
    # original defect.
    perl -0pi -e 's/if \[ -n "\$ONLY" \] && \[ "\$ALLOW_WRITES" -ne 1 \]; then\n    READ_ONLY=1\nfi/if false; then READ_ONLY=1; fi/' "$T/run_box_walk.sh"
    after=$(grep -cF 'if [ -n "$ONLY" ] && [ "$ALLOW_WRITES" -ne 1 ]; then' "$T/run_box_walk.sh")
    if [ "$after" -ne 0 ]; then
        bad "mutant did NOT apply (guard still present) -- a mutant that did not apply looks exactly like one that was not caught"
    else
        ok "mutant applied (guard replaced with an unconditional false)"
        _run "$T" --only stub_pass
        s="$(_sentinels_for mut)"
        any=0
        for w in $WRITERS; do [ -e "${s}/${w}" ] && any=1; done
        if [ "$any" -eq 1 ]; then
            ok "mutant caught: --only wrote again once the guard was removed"
        else
            bad "mutant NOT caught: --only still wrote nothing with the guard removed -- this test is not actually exercising the guard"
        fi
    fi
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: ${FAIL} finding(s)"
    exit 1
fi
echo "PASS: read-only mode never runs a writer, and --only defaults to it"
exit 0
