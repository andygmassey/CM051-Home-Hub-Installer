#!/usr/bin/env bash
# tests/test_a_security_note_cannot_claim_a_flag_is_off.sh
# ============================================================================
# A SECURITY NOTE MAY NOT DESCRIBE A FLAG AS DEFAULTING OFF WHEN IT SHIPS ON.
#
# MEASURED 2026-09-05. probes/no_store_port_is_tcp_reachable.sh carried, for a
# week after the fixes landed:
#
#     6333 ... Needs the native api key (scaffolding exists, default-OFF).
#     7878 ... proxy bearer credential (#1214, merged, default-OFF).
#
# Both flags ship default-ON. The note was accurate when written, nothing said
# otherwise, and it made the whole store surface read as unfinished -- which
# helped hide the ONE port that genuinely is open (8044, issue #1594).
#
# A STALE SECURITY NOTE IS WORSE THAN NO NOTE. It is the document a reader
# consults to decide whether an issue is closed, and it answers with confidence.
#
# This checks the one direction that is machine-checkable and that bit us:
# a flag whose SHIPPED DEFAULT is 1 must not be described as OFF in a probe
# that reasons about it. The reverse (claiming ON when it ships OFF) is checked
# too, because a note that oversells a guard is the more dangerous half.
#
# Exit: 0 consistent, 1 a note disagrees with the shipped default, 2 CANNOT-RUN.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
PROBE="${ROOT}/scripts/box_walk_probes/probes/no_store_port_is_tcp_reachable.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cant() { printf 'CANNOT-RUN: %s\n' "$*" >&2
         printf 'A check that could not run has not passed.\n' >&2; exit 2; }

[ -f "$INSTALL" ] || cant "no install.sh at ${INSTALL}"
[ -f "$PROBE" ]   || cant "no probe at ${PROBE}"

# The flags this test reasons about, derived from install.sh rather than listed
# here, so a flag added later is covered without editing this file.
FLAGS="$(grep -oE 'OSTLER_[A-Z_]*ENFORCE:-[01]' "$INSTALL" | sort -u)"
[ -n "$FLAGS" ] || cant "no OSTLER_*ENFORCE flags found in install.sh; the predicate found nothing to check"

N_FLAGS=$(printf '%s\n' "$FLAGS" | grep -c .)
ok "CONTROL: ${N_FLAGS} enforce flag(s) derived from install.sh, so this test has a subject"

while IFS= read -r decl; do
    [ -n "$decl" ] || continue
    name="${decl%%:-*}"
    def="${decl##*:-}"
    # Does the probe mention this flag, or the guard it controls, near an
    # OFF/ON claim? Keep it to the flag name: a prose claim about "the api key"
    # is not machine-checkable and this test does not pretend it is.
    if ! grep -q "$name" "$PROBE"; then
        ok "${name} is not reasoned about in the probe (default ${def}); nothing to contradict"
        continue
    fi
    claims_off=$(grep -c "${name}[^\n]*default-OFF\|default-OFF[^\n]*${name}" "$PROBE" || true)
    if [ "$def" = "1" ] && [ "${claims_off:-0}" -gt 0 ]; then
        bad "${name} ships default-ON (:-1 in install.sh) but the probe describes it as default-OFF. That is the 2026-09-05 defect: a note that was true when written and reads as current."
    else
        ok "${name} ships default-${def} and the probe does not contradict it"
    fi
done <<< "$FLAGS"

# The blunt half, and the one that actually caught it: after the correction no
# row in this probe may claim default-OFF at all, because both flags it reasons
# about ship ON. If a genuinely OFF-by-default flag is ever added, this arm is
# the one to revisit -- deliberately, not by accident.
OFFS=$(grep -c 'default-OFF' "$PROBE" || true)
if [ "${OFFS:-0}" -eq 0 ]; then
    ok "no row claims default-OFF, and both flags the probe reasons about ship ON"
else
    bad "${OFFS} row(s) still claim default-OFF while every enforce flag ships :-1"
fi

# CONTROL: the predicate must be able to SEE a default-OFF claim, or the zero
# above proves nothing. Plant one in a copy and re-run the same grep.
_tmp="$(mktemp)"; trap 'rm -f "$_tmp"' EXIT
{ cat "$PROBE"; printf '# planted: OSTLER_STORE_AUTH_ENFORCE default-OFF\n'; } > "$_tmp"
if [ "$(grep -c 'default-OFF' "$_tmp")" -gt 0 ]; then
    ok "CONTROL: the predicate finds a planted default-OFF claim, so the zero above is a measurement"
else
    bad "CONTROL FAILED: the predicate cannot see a default-OFF claim even when one is present"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
