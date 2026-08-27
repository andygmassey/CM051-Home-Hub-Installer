#!/usr/bin/env bash
# ============================================================================
# test_acceptance_gate_v1013_probe.sh -- prove the runtime acceptance probe
# is wired correctly and honours the box_walk_probe skip convention.
#
# We can't stand up a real Ostler box in a shell fixture, so this test proves
# the contract that the cut relies on:
#   1. With OSTLER_BOX_HOST UNSET the probe SKIP-exits 0 (never fails a headless
#      cut) -- matching how check_box_walk_probe treats an unset host.
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
printf '\n=== CASE: OSTLER_BOX_HOST unset -> SKIP (exit 0) ===\n'
out="$(env -u OSTLER_BOX_HOST "${PROBE}" 2>&1)"; rc=$?
printf '%s\n' "${out}" | sed 's/^/  | /'
if [[ "${rc}" -eq 0 ]]; then ok "unset host -> exit 0 (never fails the cut)"; else bad "unset host gave rc=${rc}, expected 0"; fi
if [ "$(printf '%s' "${out}" | grep -ci 'SKIP' || true)" -gt 0 ]; then ok "unset host prints a SKIP line"; else bad "no SKIP line on unset host"; fi

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
