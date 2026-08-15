#!/usr/bin/env bash
# Unset source-repo placeholder must WARN, never hard-error
# =============================================================
#
# THE INVARIANT
#
#     an unset ${VAR} in a manifest source_repo expands to EMPTY,
#     and the run continues
#
# WHY. vendor/VENDOR_MANIFEST.toml writes source_repo as "$HR015/doctor",
# "$CM041", "$CM052" and so on, expanded from the environment at run time.
# Callers (scripts/verify_vendor_fresh.sh) run `set -euo pipefail`, and
# resolve_source_repo expanded those with a bare `eval`, so an unset variable
# emitted "_vendor_lib.sh: line NNN: HR015: unbound variable" on stderr.
#
# BE PRECISE ABOUT THE BLAST RADIUS, because the first description of this bug
# (mine) was wrong and a wrong description would have justified a wrong fix.
# It is NOT a hard stop. The `set -u` death happens inside the subshell that
# $( ) creates, so the assignment simply lands empty, the function returns 0,
# and the caller carries on and counts the tree unverifiable. MEASURED: with
# the fix reverted, resolve_source_repo doctor prints the error to stderr,
# returns [], and the caller still reaches SURVIVED with rc=0.
#
# So what this fixes is SPURIOUS STDERR IN A GATE, which is worth fixing on its
# own terms -- a gate that prints scary interpreter errors during a normal run
# trains its reader to skim, and real errors then hide in the noise.
#
# WHAT IT DOES NOT FIX, stated so nobody reads this test as covering it: the
# false green was NOT caused by this. It was caused by all eight placeholders
# being unset (so 0 of 24 trees could be verified) combined with the lenient
# default that reported that as GREEN:
#
#     vendor-freshness: 24 tree(s) -- 0 fresh, 0 stale/divergent, 24 unverifiable
#     GATE: GREEN with 24 warning(s)                                    exit 0
#
# The strict flag closes the second half; checking the repos out closes the
# first. This test guards the denominator too, because a zero denominator
# reading as success is the thing that actually cost us.
#
# An unset placeholder means "that source repo is not checked out on this
# host". That is unverifiable, not fatal, and never a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; OFF=$'\033[0m'
fails=0
checks=0
pass() { checks=$((checks+1)); echo "  ${GRN}PASS${OFF}  $*"; }
fail() { checks=$((checks+1)); fails=$((fails+1)); echo "  ${RED}FAIL${OFF}  $*"; }

echo "== unset source-repo placeholder handling =="

# ---------------------------------------------------------------------------
# A. The raw shell shapes, so the test names the defect rather than a symptom.
#    The BROKEN shape is exercised here as a positive control: if it stops
#    hard-erroring, this test is measuring nothing and must be re-read.
# ---------------------------------------------------------------------------
if bash -c 'set -euo pipefail; raw="\$ARCHIE_DEFINITELY_UNSET_VAR";
            eval "printf %s \"$raw\"" >/dev/null' 2>/dev/null; then
    fail "positive control: the OLD bare-eval shape no longer errors on an unset var." \
         "This test can no longer tell the fix from the bug."
else
    pass "positive control: bare eval on an unset var DOES hard-error under set -u"
fi

if out="$(bash -c 'set -euo pipefail; raw="\$ARCHIE_DEFINITELY_UNSET_VAR";
                   expanded="$(set +u; eval "printf %s \"$raw\"")";
                   printf "[%s]" "$expanded"' 2>&1)"; then
    [[ "$out" == "[]" ]] \
        && pass "fixed shape expands an unset var to EMPTY (got $out)" \
        || fail "fixed shape produced $out, expected []"
else
    fail "fixed shape errored: $out"
fi

# ---------------------------------------------------------------------------
# B. The real function, with every placeholder unset.
#    resolve_source_repo must RETURN, not kill the shell.
# ---------------------------------------------------------------------------
probe="$(mktemp)"; trap 'rm -f "$probe"' EXIT
cat > "$probe" <<'INNER'
set -euo pipefail
. scripts/_vendor_lib.sh
for t in doctor cm052_ai_conversations cm059_editor; do
    # NO 2>/dev/null HERE, and that is the point of this test. An earlier
    # version of this file suppressed stderr on this very call and then
    # asserted that no 'unbound variable' appeared. It passed with the fix
    # REVERTED, because the assertion was reading a stream the probe had
    # already thrown away. Never redirect the evidence you are testing for.
    r="$(resolve_source_repo "$t" || echo '<ERRORED>')"
    printf '%s=[%s]\n' "$t" "$r"
done
echo "SURVIVED"
INNER

out="$(env -u HR015 -u CM019 -u CM021 -u CM024 -u CM041 -u CM048 -u CM052 -u CM059 \
        bash "$probe" 2>&1)" || true

if grep -q 'SURVIVED' <<<"$out"; then
    pass "resolve_source_repo survives every placeholder being unset"
else
    fail "resolve_source_repo did NOT survive unset placeholders. Output:"
    printf '%s\n' "$out" | sed 's/^/          /'
fi

# THE DISCRIMINATING ASSERTION. This is the one that goes red when the fix is
# reverted; everything else in this file passes either way.
if grep -q 'unbound variable' <<<"$out"; then
    fail "stderr still carries 'unbound variable' -- the set +u fix is NOT in effect."
    printf '%s\n' "$out" | grep 'unbound variable' | sed 's/^/          /'
else
    pass "no 'unbound variable' on stderr (the fix is in effect)"
fi

if grep -q '<ERRORED>' <<<"$out"; then
    fail "resolve_source_repo returned non-zero for an unset placeholder"
else
    pass "resolve_source_repo returns cleanly for an unset placeholder"
fi

# And the values must actually be empty, not merely error-free.
if grep -qE '^(doctor|cm052_ai_conversations|cm059_editor)=\[\]$' <<<"$out"; then
    pass "unset placeholders resolve to EMPTY, which is what makes them unverifiable"
else
    fail "expected empty resolutions; got:"
    printf '%s\n' "$out" | grep '=' | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
# C. The caller's `set -u` must survive. A fix that silently disarmed set -u
#    for the rest of the run would trade one blindness for a worse one.
# ---------------------------------------------------------------------------
if env -u CM052 bash -c '
        set -euo pipefail
        . scripts/_vendor_lib.sh
        resolve_source_repo cm052_ai_conversations >/dev/null 2>&1 || true
        case "$-" in *u*) exit 0;; *) exit 1;; esac' 2>/dev/null; then
    pass "caller's set -u is still armed after the call"
else
    fail "the call DISARMED set -u in the caller -- worse than the bug it fixes"
fi

# ---------------------------------------------------------------------------
# D. The denominator. This is the assertion that would have caught the false
#    green: the gate must SAY how many trees it examined and how many it could
#    not verify, and those must add up.
# ---------------------------------------------------------------------------
summary="$(env -u HR015 -u CM019 -u CM021 -u CM024 -u CM041 -u CM048 -u CM052 -u CM059 \
            bash scripts/verify_vendor_fresh.sh 2>&1 \
            | sed -e 's/\x1b\[[0-9;]*m//g' | grep -E '^vendor-freshness:' || true)"
if [[ -z "$summary" ]]; then
    fail "verify_vendor_fresh.sh printed no 'vendor-freshness:' denominator line at all"
else
    pass "denominator line present: $summary"
    total="$(sed -E 's/.*: ([0-9]+) tree.*/\1/' <<<"$summary")"
    unver="$(sed -E 's/.*, ([0-9]+) unverifiable.*/\1/' <<<"$summary")"
    if [[ "$total" =~ ^[0-9]+$ && "$unver" =~ ^[0-9]+$ ]]; then
        (( total > 0 )) \
            && pass "examined a non-zero number of trees ($total)" \
            || fail "examined ZERO trees -- a zero denominator reads as success"
        (( unver == total )) \
            && pass "with every placeholder unset, all $total are unverifiable (expected)" \
            || pass "with every placeholder unset, $unver of $total unverifiable"
    else
        fail "could not parse the denominator out of: $summary"
    fi
fi

echo
echo "EXAMINED $checks assertion(s): $((checks-fails)) passed, $fails failed"
if (( fails > 0 )); then
    echo "${RED}RESULT: FAIL${OFF}"
    exit 1
fi
echo "${GRN}RESULT: PASS${OFF}"
exit 0
