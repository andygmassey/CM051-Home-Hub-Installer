#!/usr/bin/env bash
# tests/test_the_two_ws_clients_are_identical.sh
# ============================================================================
# TWO PROBES EMBED THE SAME WEBSOCKET CLIENT. THEY MUST NOT DRIFT.
#
# assistant_answers_grounded.sh embeds the /ws/chat client rather than shipping
# it alongside, and says why: "so the probe cannot half-exist on a box". That
# reason applies equally to assistant_grounds_the_opening_turn.sh, so it
# embeds the same client.
#
# Two copies of anything drift. This repo has paid for that twice already --
# the two contact_syncer trees, and install.sh's embedded copy of
# lib/ostler-resource-tier.sh, which drifted the moment someone fixed a comment
# in the wrong one of the pair. That second case is the precedent for the
# pattern used here: a copy is ALLOWED, and a gate makes divergence loud.
#
# THE RIGHT END STATE is one copy in lib/, sourced by both. It is deliberately
# not done yet: CM051 #2018 is open against assistant_answers_grounded.sh and
# extracting the function would collide with it. When #2018 lands, extract, and
# this test becomes a one-line "the lib is sourced by both" assertion.
#
# WHAT IS ASSERTED: the byte content of _ws_client_py() is identical in both
# files. Plus a CONTROL, because a comparison that cannot fail proves nothing:
# a deliberately mutated copy must be reported as different.
#
# NO PIPE INTO grep -q: it SIGPIPEs the producer and under pipefail reports
# failure for a pattern it found. Counted form only.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
A="$REPO/scripts/box_walk_probes/probes/assistant_answers_grounded.sh"
B="$REPO/scripts/box_walk_probes/probes/assistant_grounds_the_opening_turn.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }

for f in "$A" "$B"; do
    [ -f "$f" ] || { printf '  [FAIL] missing %s -- CANNOT-RUN, not a pass\n' "$f" >&2; exit 1; }
done

extract() { sed -n '/^_ws_client_py() {$/,/^}$/p' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
extract "$A" > "$TMP/a.txt"
extract "$B" > "$TMP/b.txt"

# The extraction must actually find something, or two empty files compare
# equal and this test passes for ever having examined nothing.
LA="$(wc -l < "$TMP/a.txt" | tr -d ' ')"
LB="$(wc -l < "$TMP/b.txt" | tr -d ' ')"
if [ "$LA" -lt 50 ] || [ "$LB" -lt 50 ]; then
    bad "extraction found ${LA} and ${LB} lines; under 50 means the marker moved and NOTHING was compared"
else
    ok "extracted a real function from both files (${LA} and ${LB} lines)"
fi

if cmp -s "$TMP/a.txt" "$TMP/b.txt"; then
    ok "the embedded _ws_client_py() is byte-identical in both probes"
else
    bad "the two embedded ws clients have DRIFTED" "$(diff "$TMP/a.txt" "$TMP/b.txt" | head -20)"
fi

# CONTROL. A mutated copy MUST compare different, or cmp is answering yes to
# everything and the assertion above is decoration.
sed '$ d' "$TMP/b.txt" > "$TMP/c.txt"
if cmp -s "$TMP/a.txt" "$TMP/c.txt"; then
    bad "CONTROL: a deliberately mutated copy compared EQUAL -- this test discriminates nothing"
else
    ok "CONTROL: a mutated copy compares different, so the check can fail"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
