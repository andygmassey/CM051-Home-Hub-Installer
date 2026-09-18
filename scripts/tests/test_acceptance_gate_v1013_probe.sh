#!/usr/bin/env bash
# ============================================================================
# test_acceptance_gate_v1013_probe.sh -- prove the runtime acceptance probe
# is wired correctly and honours the box_walk_probe skip convention.
#
# We can't stand up a real Ostler box in a shell fixture, so this test proves
# the contract that the cut relies on:
#   1. With OSTLER_BOX_HOST UNSET the probe exits 78, CANNOT-RUN, and SAYS SO.
#
#      🔴 THIS ASSERTION WAS REVERSED ON 2026-09-19 AND THE OLD ONE WAS THE
#      DEFECT, board row 2221. It used to require exit 0, which this gate's own
#      header called "SHIPPABLE / SKIP" -- two different claims sharing one
#      code. The gate is registered in cut-manifests/permanent.yaml, so on a
#      runner with no box it announced SHIPPABLE for a launch-critical check
#      that had contacted nothing and evaluated no assertion. A zero denominator
#      reading as success.
#
#      WHY 78 CANNOT BREAK A HEADLESS CUT, which is what the old assertion was
#      protecting and is the thing to check before changing it. Read at source,
#      on BOTH invocation paths:
#        scripts/verify_cut_manifest.py:1588 returns SKIP for a box_walk_probe
#          row BEFORE the probe is invoked at all when the host is unset, so on
#          a boxless runner this script never runs and its exit code cannot
#          reach the cut.
#        run_box_walk.sh:44 declares EX_CANNOT_RUN=78 and :33 states that
#          CANNOT-RUN does not fail the run.
#        verify_cut_manifest.py:1754-1760 maps 78 to CANNOT-RUN, not FAIL.
#      When the host IS set nothing here changed: the probe must still exit 0.
#   2. The probe is REGISTERED: cut-manifests/v1.0.13.yaml has a box_walk_probe
#      entry naming it, and the script exists + is executable.
#   3. Gate 3 adds NO Makefile step (it rides the existing check-manifest wiring).
#   4. The probe is READ-ONLY: it contains no obvious state-mutating box command.
# ============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
PROBE="${SCRIPTS_DIR}/box_walk_probes/acceptance_gate_v1013.sh"
MANIFEST="${REPO_ROOT}/cut-manifests/v1.0.13.yaml"
MAKEFILE="${REPO_ROOT}/gui/Makefile"

PASS=0; FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

# --- 1. registered + executable --------------------------------------------
if [[ -x "${PROBE}" ]]; then ok "probe script exists + is executable"; else bad "probe missing/not executable: ${PROBE}"; fi

# --- 2. SKIP-exits 0 when OSTLER_BOX_HOST is unset --------------------------
printf '\n=== CASE: OSTLER_BOX_HOST unset -> CANNOT-RUN (exit 78), never SHIPPABLE ===\n'
out="$(env -u OSTLER_BOX_HOST "${PROBE}" 2>&1)"; rc=$?
printf '%s\n' "${out}" | sed 's/^/  | /'
if [[ "${rc}" -eq 78 ]]; then ok "unset host -> exit 78 (CANNOT-RUN, not SHIPPABLE)"; else bad "unset host gave rc=${rc}, expected 78. 0 would announce SHIPPABLE for a registered launch-critical gate that contacted no box."; fi
# THE MARKER IS HALF THE CONTRACT. run_box_walk.sh:537-539 records a probe that
# exits 78 with no "VERDICT: CANNOT-RUN --" line as UNRECORDED, and calls that a
# contract breach in those words. The code alone is not enough.
if [ "$(printf '%s' "${out}" | grep -c '^VERDICT: CANNOT-RUN -- ' || true)" -gt 0 ]; then ok "it emits the VERDICT marker the walk runner parses"; else bad "exit 78 with no 'VERDICT: CANNOT-RUN --' line: the runner records that as UNRECORDED and names it a contract breach"; fi
# AND IT MUST NAME THE MISSING PREREQUISITE, or an operator cannot act on it.
if [ "$(printf '%s' "${out}" | grep -c 'OSTLER_BOX_HOST' || true)" -gt 0 ]; then ok "the reason names the missing prerequisite"; else bad "the CANNOT-RUN reason does not name what is missing"; fi

# --- 3. manifest entry present + names the probe ---------------------------
printf '\n=== CASE: cut-manifests/v1.0.13.yaml registers the probe ===\n'
if grep -q 'kind: box_walk_probe' "${MANIFEST}" && grep -q 'probe: "acceptance_gate_v1013"' "${MANIFEST}"; then
  ok "v1.0.13.yaml has a box_walk_probe entry for acceptance_gate_v1013"
else
  bad "v1.0.13.yaml missing the acceptance_gate_v1013 box_walk_probe entry"
fi
if grep -q 'id: v1013-box-walk-acceptance-gate' "${MANIFEST}"; then
  ok "manifest entry carries an id"
else
  bad "manifest entry has no id"
fi

# --- 4. Gate 3 adds NO Makefile step (rides check-manifest) -----------------
printf '\n=== CASE: no new Makefile step for the probe (uses check-manifest) ===\n'
if grep -q 'acceptance_gate_v1013' "${MAKEFILE}"; then
  bad "Makefile references acceptance_gate_v1013 (should ride existing check-manifest, no new step)"
else
  ok "Makefile has no probe-specific step (probe runs via check-manifest -> box_walk_probe)"
fi

# --- 5. read-only sanity: no obvious state-mutating box command -------------
printf '\n=== CASE: probe is read-only (no mutating box command) ===\n'
# Precise mutation patterns only. curl is GET-only here (no -X METHOD / body);
# reject rm, mutating curl, SQL writes, and launchctl lifecycle verbs. Note we do
# NOT flag bare `-d ` (that also matches read-only `tr -d`) -- only curl bodies.
MUT_RE='box "[^"]*rm |curl [^"]*-X (POST|PUT|DELETE|PATCH)|curl [^"]*(--data|--data-raw| -d )|DROP TABLE|INSERT INTO|DELETE FROM|UPDATE [^"]* SET|launchctl (load|unload|bootstrap|bootout|kickstart|stop|start)'
if grep -nE "${MUT_RE}" "${PROBE}" >/dev/null; then
  bad "probe appears to contain a state-mutating box command"
  grep -nE "${MUT_RE}" "${PROBE}" | sed 's/^/  | /' >&2
else
  ok "no obvious mutating box command (curl GET / grep / sqlite SELECT / launchctl list only)"
fi

# --- 6. A7 is needs-eyes, not gating; A1-A6/A8 map to result FAIL -----------
printf '\n=== CASE: A7 needs-eyes; launch-critical assertions gate ===\n'
if grep -q 'result MANUAL A7' "${PROBE}"; then ok "A7 is MANUAL (needs-eyes, non-gating)"; else bad "A7 is not marked MANUAL"; fi
if grep -q 'result FAIL A2' "${PROBE}" && grep -q 'result FAIL A6' "${PROBE}"; then
  ok "launch-critical assertions can emit FAIL (gating)"
else
  bad "launch-critical assertions do not emit FAIL"
fi

printf '\n============================================================\n'
printf 'Acceptance-probe self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
