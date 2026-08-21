#!/usr/bin/env bash
#
# The Front Page tick must emit the interest-profile artefact, not only the
# Dashboard front page.
#
# ── WHAT THIS GUARDS, MEASURED ON A FRESH v1.0.38 BOX 2026-08-21 ─────────
#
# com.creativemachines.ostler.editor-frontpage ran hourly, exited 0 every
# time, and logged "12 cards (phase=steady)". Meanwhile the Hub served:
#
#   /api/v1/preferences -> {"interests":[],"count":0,
#                           "source_path":".../preferences/interest_profile.json"}
#
# over a Qdrant `preferences` collection holding 9,879 points. The writer and
# the reader disagreed on the path and BOTH reported success:
#
#   writer (emit_frontpage) -> ~/.ostler/editor/front_page.json        EXISTS
#   reader (ical-server.py) -> ~/.ostler/preferences/interest_profile.json  ABSENT
#
# compiler/emit_artefact.py is the emitter for that artefact. It is vendored
# byte-identical from CM059 source, its path precedence matches the reader's
# exactly -- and nothing invoked it. Running it by hand on the box turned
# count:0 into count:495 with no other change.
#
# Because an absent artefact and an empty profile are the SAME branch in the
# reader (both count:0), this could never surface as an error. It surfaced as
# an assistant answering "I do not have personal knowledge about you" on a
# machine holding 6,848 people. That is why this test asserts on the
# INVOCATION and not on any log string: a log line proves the tick ran, which
# was already true and already useless.
#
# Runs under bash 3.2 (the macOS system bash the installed box provides).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="${REPO_ROOT}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "test_frontpage_tick_emits_interest_profile"
echo "  subject: ${TICK#$REPO_ROOT/}"

# ── 0. Premise ───────────────────────────────────────────────────────────
# If the tick is not where we think it is, every later zero is meaningless.
if [ -f "$TICK" ]; then
    ok "premise: the tick script exists"
else
    bad "premise: tick script NOT FOUND at $TICK -- every assertion below is vacuous"
    echo "  $pass passed, $fail failed"
    exit 1
fi

# ── 1. The emitter is invoked ────────────────────────────────────────────
if grep -q 'compiler\.emit_artefact' "$TICK"; then
    ok "the tick invokes compiler.emit_artefact"
else
    bad "the tick does NOT invoke compiler.emit_artefact -- /api/v1/preferences will serve count:0 forever"
fi

# ── 2. ANTI-VACUITY: the front-page emit must SURVIVE ────────────────────
# A fix that swapped one emit for the other would pass limb 1 and break the
# Dashboard. Both must be present.
if grep -q 'compiler\.emit_frontpage' "$TICK"; then
    ok "the front-page emit is still invoked (not swapped out)"
else
    bad "compiler.emit_frontpage is GONE -- the Dashboard front page would go stale"
fi

# ── 3. Ordering: the artefact emit precedes the front-page emit ──────────
# The artefact is what the ASSISTANT reads, so it gets first call on the
# tick's budget. Asserted rather than assumed, because a later edit that
# appends the new call would silently reverse it.
_a_line="$(grep -n 'compiler\.emit_artefact' "$TICK" | head -1 | cut -d: -f1)"
_f_line="$(grep -n 'compiler\.emit_frontpage' "$TICK" | head -1 | cut -d: -f1)"
if [ -n "${_a_line:-}" ] && [ -n "${_f_line:-}" ] && [ "$_a_line" -lt "$_f_line" ]; then
    ok "artefact emit (line $_a_line) precedes front-page emit (line $_f_line)"
else
    bad "ordering wrong or unmeasurable: artefact=${_a_line:-none} frontpage=${_f_line:-none}"
fi

# ── 4. The artefact emit must be NON-FATAL ───────────────────────────────
# The tick runs under `set -e`. An unguarded new step would take the
# already-working front-page emit down with it on any failure. Require the
# rc to be captured rather than allowed to abort the script.
if grep -q '_artefact_rc' "$TICK"; then
    ok "artefact emit captures its rc (cannot abort the front-page emit under set -e)"
else
    bad "artefact emit is unguarded -- a failure would kill the front-page emit too"
fi

# ── 5. Syntax ────────────────────────────────────────────────────────────
# A syntax error means the tick never runs, which is the exact failure this
# whole file exists to prevent.
if bash -n "$TICK" 2>/dev/null; then
    ok "tick parses under bash -n"
else
    bad "tick has a SYNTAX ERROR -- it would never run at all"
fi

# ── 6. NEGATIVE CONTROL ──────────────────────────────────────────────────
# Prove limb 1 can actually return FAIL. Mutate a copy by deleting the
# emit_artefact invocation and re-run the same predicate over it. If the
# predicate still passes, it is not measuring what it claims and every green
# above is worthless.
_mutant="$(mktemp)"
grep -v 'compiler\.emit_artefact' "$TICK" > "$_mutant"
if grep -q 'compiler\.emit_artefact' "$_mutant"; then
    bad "negative control DID NOT FIRE: the mutant still matches, so limb 1 proves nothing"
else
    ok "negative control: predicate returns FAIL against a tick with the invocation removed"
fi
rm -f "$_mutant"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
