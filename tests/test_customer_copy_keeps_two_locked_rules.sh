#!/bin/bash
# CM051 #1008, sub-items (3) and (4). TWO LOCKED BRAND RULES, BROKEN IN THE
# STRINGS A CUSTOMER READS, AND NEITHER HAD A GATE.
#
# Measured on origin/main 2026-09-18, against a CONTROL of 1156 total MSG_
# lines so a zero can never come from reading nothing:
#
#   9 MSG_ lines said "iOS Companion"
#   2 MSG_ lines promised a roadmap
#
# RULE ONE, feedback_ios_app_not_companion_in_customer_copy: customer copy
# says "the Ostler app on your iPhone", never "Companion". The word is a
# product name we do not use.
#
# RULE TWO, feedback_no_roadmap_leaks_in_public_copy: customer copy does not
# promise future platforms. And this instance was not merely a leak, IT WAS A
# SELF-CONTRADICTION INSIDE ONE FILE:
#
#   :210  "Intel support is not on the roadmap; raise a request if required."
#   :956  "Intel Macs are not supported in v1.0 ... Intel support is coming
#          in v1.0.1."
#
# One string told a customer the thing the other string promised them was not
# planned. Whichever they read second was a lie, and an Intel customer hits
# :956 because it is the abort message.
#
# WHY THIS FILE AND NOT THE HOOK. .githooks/check-rule-09-strings.sh guards
# ONE rule (the transcribing/recording wording) and neither of these. Measured:
# 0 files under tests/ or .githooks/ name the roadmap rule, against a CONTROL
# of 18 test files naming "recording", so the search reaches.
#
# SCOPE IS MSG_ ASSIGNMENTS ONLY, deliberately. A comment explaining why a
# word is banned must be allowed to contain the word, or the guard forbids its
# own documentation. This file says "Companion" many times and must stay green.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRINGS="${ROOT}/install.sh.strings.en-GB.sh"
[ -r "$STRINGS" ] || { echo "CANNOT-RUN: ${STRINGS} is not readable."; exit 2; }

# Customer-visible copy only: a MSG_ assignment at the start of a line.
MSG_LINES="$(grep -c '^MSG_' "$STRINGS" || true)"
if [ "${MSG_LINES:-0}" -lt 100 ]; then
    echo "CANNOT-RUN: only ${MSG_LINES:-0} MSG_ lines found in ${STRINGS}."
    echo "            The file has been restructured; re-point this test"
    echo "            rather than letting it pass on a tiny denominator."
    exit 2
fi
echo "EXAMINED: ${MSG_LINES} MSG_ assignments in install.sh.strings.en-GB.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; return 0; }

echo
echo "ARM 1: customer copy says the Ostler app on your iPhone, never Companion"
N="$(grep -c '^MSG_.*[Cc]ompanion' "$STRINGS" || true)"
[ "$N" -eq 0 ] \
    && ok "(1) 0 of ${MSG_LINES} MSG_ lines use the banned product name" \
    || no "(1) ${N} MSG_ line(s) still say Companion" "$(grep -n '^MSG_.*[Cc]ompanion' "$STRINGS")"

echo
echo "ARM 2: customer copy promises no future platform"
# "coming soon" and "coming in vX.Y.Z" are the two shapes that shipped.
N="$(grep -cE '^MSG_.*(coming soon|coming in v[0-9])' "$STRINGS" || true)"
[ "$N" -eq 0 ] \
    && ok "(2) no MSG_ line promises a platform that is not here yet" \
    || no "(2) ${N} MSG_ line(s) promise a roadmap" "$(grep -nE '^MSG_.*(coming soon|coming in v[0-9])' "$STRINGS")"

echo
echo "ARM 3: THE SELF-CONTRADICTION, which is worse than either leak alone"
# If one string tells the customer a platform is NOT on the roadmap, no other
# string may promise that same platform. This is the arm that would have
# caught the shipped state, because each string alone reads reasonably.
DENIES="$(grep -cE '^MSG_.*[Ii]ntel.*not on the roadmap' "$STRINGS" || true)"
PROMISES="$(grep -cE '^MSG_.*[Ii]ntel.*(coming|support is coming|in v[0-9])' "$STRINGS" || true)"
if [ "$DENIES" -gt 0 ] && [ "$PROMISES" -gt 0 ]; then
    no "(3) ${DENIES} string(s) say Intel is not on the roadmap AND ${PROMISES} promise it" \
       "$(grep -nE '^MSG_.*[Ii]ntel' "$STRINGS")"
else
    ok "(3) no platform is both denied and promised (denied=${DENIES}, promised=${PROMISES})"
fi

echo
echo "ARM 4: MUST-MISS. The predicates must reject what they should reject."
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
{
  printf '%s\n' 'MSG_SYNTH_A="Open the iOS Companion app."'
  printf '%s\n' 'MSG_SYNTH_B="Linux support coming soon."'
  printf '%s\n' '# A comment that says Companion and coming soon, which must NOT trip.'
} > "$TMP"
a="$(grep -c '^MSG_.*[Cc]ompanion' "$TMP" || true)"
b="$(grep -cE '^MSG_.*(coming soon|coming in v[0-9])' "$TMP" || true)"
c="$(grep -c '^MSG_' "$TMP" || true)"
[ "$a" -eq 1 ] && ok "(4a) a synthetic Companion string IS caught" || no "(4a) got $a"
[ "$b" -eq 1 ] && ok "(4b) a synthetic roadmap promise IS caught" || no "(4b) got $b"
[ "$c" -eq 2 ] && ok "(4c) and the COMMENT is not counted, so the guard does not forbid its own documentation" || no "(4c) counted $c MSG_ lines, expected 2"

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
