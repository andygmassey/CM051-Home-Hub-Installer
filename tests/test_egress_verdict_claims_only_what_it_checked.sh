#!/usr/bin/env bash
# ============================================================================
# test_egress_verdict_claims_only_what_it_checked.sh                  (#1145)
#
# no_unexpected_egress classifies with is_outside_boundary(), which tests only
# OSTLER_EGRESS_ALLOWED_RE -- loopback, RFC1918, link-local, CGNAT. The ledger
# read, the contemporaneous dig loop and the live DERP-map fetch all live in
# self_test() and run nowhere else.
#
# Both verdicts said "declared boundary" anyway. Measured on a live box
# 2026-08-27, that sentence sat above three addresses of which TWO were
# declared or declarable -- controlplane.tailscale.com (ledger rows 30 and 54)
# and derp20c.tailscale.com. A reader who checks one, finds it in the ledger,
# and discounts the row never reaches the third, which is the only real one.
#
# THIS GATE IS CONDITIONAL, AND THAT IS THE POINT. It does not forbid the
# phrase. It forbids CLAIMING the ledger while run_probe does not read it. Fix
# #1145 properly -- move the attribution onto the walk path -- and this test
# stops objecting on its own, because the claim will have become true. A gate
# that banned the words outright would have to be deleted by the person who
# earns them, and nobody deletes a gate to land a fix.
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
PROBE="${REPO_ROOT}/scripts/box_walk_probes/probes/no_unexpected_egress.sh"

PASS=0
FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$PROBE" ]]; then
    printf '  [FAIL] probe not found at %s -- this test could not run, which is not a pass\n' "$PROBE"
    exit 1
fi

# ---------------------------------------------------------------------------
# (0) CONTROL. Locate run_probe and self_test, and prove the split is real
#     before drawing any conclusion from it.
# ---------------------------------------------------------------------------
RP_LINE="$(grep -n '^run_probe() {' "$PROBE" | head -1 | cut -d: -f1)"
ST_LINE="$(grep -n '^self_test() {' "$PROBE" | head -1 | cut -d: -f1)"

if [[ -z "$RP_LINE" || -z "$ST_LINE" ]]; then
    failure "(0) CONTROL FAILED: could not locate run_probe (${RP_LINE:-none}) and self_test (${ST_LINE:-none}). Renamed? Re-point this test rather than trusting the result below"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi
if [[ "$ST_LINE" -le "$RP_LINE" ]]; then
    failure "(0) CONTROL FAILED: self_test (${ST_LINE}) does not follow run_probe (${RP_LINE}); the line-range split below would read the wrong body"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi
pass "(0) CONTROL: run_probe at ${RP_LINE}, self_test at ${ST_LINE}, so the bodies can be told apart"

RUN_BODY="$(sed -n "${RP_LINE},$((ST_LINE - 1))p" "$PROBE" | grep -vE '^[[:space:]]*#')"
SELF_BODY="$(sed -n "${ST_LINE},\$p" "$PROBE" | grep -vE '^[[:space:]]*#')"

LEDGER_RE='HOSTS_FILE|egress_hosts|derpmap|DERP\b'

# MENTION IS NOT USE, and this test caught itself on exactly that. The fix that
# prompted this gate adds a probe_note SAYING the ledger is unconsulted -- and
# that note contains the words "egress_hosts.tsv" and "DERP map". Counted
# naively, the disclaimer that the ledger is unread reads as evidence that it
# is read, and the gate stands down on the broken state it exists to catch.
#
# So output lines are excluded. probe_note, probe_fail and probe_pass are what
# the probe SAYS; only the remaining lines are what it DOES.
_ledger_uses() { printf '%s\n' "$1" | grep -vE 'probe_(note|fail|pass|cannot_run)' | grep -cE "$LEDGER_RE" || true; }

RUN_READS="$(_ledger_uses "$RUN_BODY")"
SELF_READS="$(_ledger_uses "$SELF_BODY")"

# ---------------------------------------------------------------------------
# (1) CONTROL. The predicate must find the ledger SOMEWHERE, or a zero in (2)
#     would just mean the pattern is broken.
# ---------------------------------------------------------------------------
if [[ "${SELF_READS:-0}" -gt 0 ]]; then
    pass "(1) CONTROL: the ledger predicate matches ${SELF_READS} line(s) in self_test, so a zero elsewhere is meaningful"
else
    failure "(1) CONTROL FAILED: the ledger predicate matches nothing anywhere in this file. A zero in (2) would prove nothing"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi

# ---------------------------------------------------------------------------
# (2) THE GATE. If run_probe does not read the ledger, its verdicts may not
#     claim it.
# ---------------------------------------------------------------------------
CLAIMS="$(printf '%s\n' "$RUN_BODY" | grep -cE 'declared boundary' || true)"

if [[ "${RUN_READS:-0}" -gt 0 ]]; then
    pass "(2) run_probe reads the ledger (${RUN_READS} reference(s)), so it has earned the phrase 'declared boundary' -- #1145 appears to be fixed and this gate stands down"
elif [[ "${CLAIMS:-0}" -eq 0 ]]; then
    pass "(2) run_probe does not read the ledger and does not claim 'declared boundary' -- the verdict matches the measurement"
else
    failure "(2) run_probe claims 'declared boundary' in ${CLAIMS} verdict string(s) while reading the ledger 0 times. Either move the attribution onto the walk path (#1145), or say which boundary was actually checked"
fi

# ---------------------------------------------------------------------------
# NOTE ON THE FORM BELOW: `cmd | grep -q` in a CONDITION under `set -o pipefail`
# INVERTS -- grep -q exits on first match, upstream takes SIGPIPE, and pipefail
# calls the pipeline failed ON A MATCH. I wrote exactly that here and the
# ratchet in test_pipefail_shortcircuit_inversion.sh caught it (69 found,
# baseline 68). Remedy B: count in a substitution, compare the number.
#
# (3) The unconsulted-ledger note must survive. It is the only thing telling a
#     reader of a FAIL that a listed destination may well be declared.
# ---------------------------------------------------------------------------
if [[ "${RUN_READS:-0}" -gt 0 ]]; then
    pass "(3) not required: run_probe reads the ledger, so there is nothing to disclaim"
elif [[ "$(printf '%s\n' "$RUN_BODY" | grep -c 'NOT consulted' || true)" -gt 0 ]]; then
    pass "(3) the walk output states that the ledger was not consulted"
else
    failure "(3) nothing in run_probe's output tells a reader the ledger went unread. A FAIL then reads as undeclared traffic when two of three flagged addresses were declared"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
