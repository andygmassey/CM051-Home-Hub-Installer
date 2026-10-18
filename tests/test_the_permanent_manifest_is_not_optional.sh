#!/usr/bin/env bash
# THE PERMANENT CUT-MANIFEST BACKSTOP IS NOT OPTIONAL.
#
# cut-manifests/permanent.yaml is over a thousand lines carrying the
# never-regress backstop: the operator personal-data and leak checks, and
# every box-walk probe row that is not specific to one cut. Before this fix,
# scripts/verify_cut_manifest.py loaded it "if present" --
#
#     if permanent.is_file():
#         manifests.append(("permanent", load_manifest(permanent)))
#     else:
#         print(f"WARN: {permanent} not present -- skipping never-regress backstop", ...)
#
# -- and continued on the per-cut manifest alone. Nothing incremented fails or
# cannot_runs for the rows that were never read, so a run with the wrong
# --manifest-dir, or a renamed/deleted permanent.yaml, still exited 0 having
# examined a fraction of what the gate claims to guard.
#
# WHAT IS ASSERTED HERE, three arms:
#   1. TEETH: with permanent.yaml present, entries from BOTH manifests are
#      read and a genuine pass in each contributes to the pass count.
#   2. THE DEFECT: with permanent.yaml absent, the gate must CANNOT-RUN
#      (rc=2), never exit 0 on the per-cut manifest alone.
#   3. The refusal names the file and says why, so an operator is not left
#      to guess.
#
# Exit: 0 all assertions pass, 1 a failure, 2 the harness itself could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY_SCRIPT="${REPO_ROOT}/scripts/verify_cut_manifest.py"
[ -f "${PY_SCRIPT}" ] || { echo "CANNOT-RUN: ${PY_SCRIPT} not found" >&2; exit 2; }

PY="$(command -v python3 || true)"
[ -n "${PY}" ] || { echo "CANNOT-RUN: no python3 on PATH" >&2; exit 2; }
if ! "${PY}" -c 'import yaml' >/dev/null 2>&1; then
    echo "CANNOT-RUN: PyYAML not importable under ${PY} -- install it before running this guard" >&2
    exit 2
fi

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# A minimal fixture CM051 tree: install.sh with a known needle, so
# grep_in_installer can PASS for real rather than being stubbed.
mkdir -p "${WORK}/cm051"
printf '#!/bin/sh\n# FIXTURE_NEEDLE_PRESENT\necho hi\n' > "${WORK}/cm051/install.sh"
mkdir -p "${WORK}/cm051/cut-manifests"

cat > "${WORK}/cm051/cut-manifests/permanent.yaml" <<'EOF'
version: permanent
entries:
  - id: permanent-fixture-1
    title: permanent backstop fixture
    source_pr: "0"
    proof:
      kind: grep_in_installer
      pattern: FIXTURE_NEEDLE_PRESENT
      must_match: true
EOF

cat > "${WORK}/cm051/cut-manifests/v9.9.9.yaml" <<'EOF'
version: v9.9.9
entries:
  - id: per-cut-fixture-1
    title: per-cut fixture
    source_pr: "0"
    proof:
      kind: grep_in_installer
      pattern: FIXTURE_NEEDLE_PRESENT
      must_match: true
EOF

run_gate() {
    "${PY}" "${PY_SCRIPT}" --version v9.9.9 \
        --cm051-dir "${WORK}/cm051" \
        --manifest-dir "${WORK}/cm051/cut-manifests" \
        --skip-source-at-sha 2>&1
}

echo "== 1. TEETH: permanent.yaml present -- both manifests are read =="
OUT="$(run_gate)"; RC=$?
if [ "${RC}" -eq 0 ]; then
    ok "with permanent.yaml present, the gate exits 0"
else
    bad "with permanent.yaml present, the gate gave rc=${RC} (expected 0)"
    printf '%s\n' "${OUT}" | sed 's/^/          /'
fi
if grep -q '2 PASS' <<< "${OUT}"; then
    ok "both the permanent AND the per-cut fixture row were measured (2 PASS)"
else
    bad "the summary does not show 2 PASS -- the fixture is not exercising both manifests"
    printf '%s\n' "${OUT}" | sed 's/^/          /'
fi
if grep -q -- '--- permanent (1 entries) ---' <<< "${OUT}"; then
    ok "the permanent manifest section header is printed"
else
    bad "no 'permanent (1 entries)' section header -- permanent.yaml was not loaded"
    printf '%s\n' "${OUT}" | sed 's/^/          /'
fi

echo
echo "== 2. THE DEFECT: permanent.yaml absent must CANNOT-RUN, never a bare pass =="
rm -f "${WORK}/cm051/cut-manifests/permanent.yaml"
OUT="$(run_gate)"; RC=$?
case "${RC}" in
    2) ok "an absent permanent.yaml refuses with CANNOT-RUN (rc=2)" ;;
    0) bad "an absent permanent.yaml exited 0 -- the never-regress backstop was silently skipped" ;;
    *) bad "an absent permanent.yaml gave rc=${RC}, expected 2" ;;
esac
# Grepping for the bare word "CANNOT-RUN" is not enough: the SUMMARY line on a
# healthy run always prints "0 CANNOT-RUN" as one of its four counters, so that
# substring is present on BOTH a real refusal and an ordinary green run that
# happens to score zero cannot-runs. Anchored on the first line of stderr,
# which is where ERROR: is printed and a Summary line never appears.
FIRST_LINE="$(printf '%s\n' "${OUT}" | head -1)"
case "${FIRST_LINE}" in
    *ERROR*permanent.yaml*not\ present*)
        ok "the refusal's FIRST line names permanent.yaml and says it is not present" ;;
    *)
        bad "the first line of output does not name permanent.yaml as absent: ${FIRST_LINE}" ;;
esac
if grep -q '=== Summary' <<< "${OUT}"; then
    bad "the run printed a Summary line for a permanent-manifest-absent run -- it scored something despite the missing backstop"
else
    ok "no Summary line is printed -- the run refused before scoring anything"
fi

echo
echo "== 3. a permanent.yaml that fails to PARSE must also refuse, not silently skip =="
mkdir -p "${WORK}/cm051/cut-manifests"
printf 'not: [valid, yaml, {\n' > "${WORK}/cm051/cut-manifests/permanent.yaml"
OUT="$(run_gate)"; RC=$?
if [ "${RC}" -ne 0 ]; then
    ok "an unparseable permanent.yaml does not exit 0 (rc=${RC})"
else
    bad "an unparseable permanent.yaml exited 0"
    printf '%s\n' "${OUT}" | sed 's/^/          /'
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
