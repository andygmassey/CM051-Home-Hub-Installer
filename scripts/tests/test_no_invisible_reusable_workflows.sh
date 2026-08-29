#!/usr/bin/env bash
# ============================================================================
# test_no_invisible_reusable_workflows.sh -- prove the class guard FIRES.
#
# The guard exists because a workflow whose `uses:` cannot resolve fails at
# STARTUP, producing a run with zero jobs and therefore zero check-runs. That
# is worse than a red gate: it is an absent one, and absent is what a passing
# gate also looks like on a merge box.
#
# The planted violation is the REAL one, reconstructed byte for byte from
# CM051 PR #493: a job calling
# andygmassey/HR015-Gaming-PC/.github/workflows/reusable-enforce-ledger-write.yml@main.
#
# Exit code = number of failed assertions.
# macOS /bin/bash 3.2. British English; " -- " not em-dashes.
# ============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_no_invisible_reusable_workflows.sh"

TMP="$(mktemp -d -t no_invisible_wf_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0; FAIL=0
CAP=""

run_case() { # name expected_rc dir [allowlist]
  local name="$1" exp="$2" dir="$3" allow="${4:-/dev/null}"
  CAP="${TMP}/out.$$.${RANDOM}"
  printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${exp}"
  GITHUB_REPOSITORY="andygmassey/CM051-Home-Hub-Installer" \
  REUSABLE_WF_ALLOWLIST="${allow}" \
  GH_TOKEN="" GITHUB_TOKEN="" \
    /bin/bash "${GATE}" --workflows-dir "${dir}" >"${CAP}" 2>&1
  local rc=$?
  sed 's/^/  | /' "${CAP}"
  if [ "${rc}" -eq "${exp}" ]; then
    printf 'PASS: %s (rc=%s)\n' "${name}" "${rc}"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s got rc=%s, expected %s\n' "${name}" "${rc}" "${exp}" >&2; FAIL=$((FAIL+1))
  fi
}
assert_contains() {
  if grep -qF -- "$2" "${CAP}"; then
    printf 'PASS: %s\n' "$1"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (output missing: %s)\n' "$1" "$2" >&2; FAIL=$((FAIL+1))
  fi
}

mk_wf_dir() { local d="${TMP}/wf.$$.${RANDOM}"; mkdir -p "${d}"; echo "${d}"; }

write_clean_wf() { # $1 = dir
  cat > "$1/local.yml" <<'EOF'
name: local
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo ok
EOF
}

write_offending_wf() { # $1 = dir -- the REAL PR #493 shape
  cat > "$1/enforce-ledger-write.yml" <<'EOF'
name: enforce-ledger-write
on:
  pull_request:
jobs:
  ledger-pr:
    uses: andygmassey/HR015-Gaming-PC/.github/workflows/reusable-enforce-ledger-write.yml@main
    with:
      mode: pr
EOF
}

# --- CASE 1: THE RED. The exact PR #493 shape -> BLOCK ---------------------
D1="$(mk_wf_dir)"; write_clean_wf "${D1}"; write_offending_wf "${D1}"
run_case "the real PR #493 cross-repo call -> RED" 1 "${D1}"
assert_contains "case 1 names the source repo"     "andygmassey/HR015-Gaming-PC"
assert_contains "case 1 names the file and line"   "enforce-ledger-write.yml:6"
assert_contains "case 1 explains the invisibility" "0 jobs and therefore 0 check-runs"
assert_contains "case 1 prints the file denominator"  "files scanned:                 2"
assert_contains "case 1 prints the uses: control"     "\`uses:\` lines seen (control):  2"

# --- CASE 2: the control -- a clean tree passes ----------------------------
# A guard that always fires proves as little as one that never runs.
D2="$(mk_wf_dir)"; write_clean_wf "${D2}"
run_case "clean tree -> CLEAN" 0 "${D2}"
assert_contains "case 2 reports clean"           "CLEAN"
assert_contains "case 2 still prints denominators" "reusable-workflow calls found: 0"

# --- CASE 3: a LOCAL reusable workflow is fine -----------------------------
D3="$(mk_wf_dir)"; write_clean_wf "${D3}"
cat > "${D3}/caller.yml" <<'EOF'
name: caller
on:
  pull_request:
jobs:
  reuse:
    uses: andygmassey/CM051-Home-Hub-Installer/.github/workflows/local.yml@main
EOF
run_case "same-repo reusable workflow -> CLEAN" 0 "${D3}"
assert_contains "case 3 recognises the local call" "local reusable workflow"

# --- CASE 4: allowlisted source -> WARN, not RED ---------------------------
ALLOW="${TMP}/allow.tsv"
printf '# hdr\nandygmassey/HR015-Gaming-PC\tmeasured public on 2026-01-01\n' > "${ALLOW}"
run_case "allowlisted source -> WARN, not RED" 0 "${D1}" "${ALLOW}"
assert_contains "case 4 says it is allowlisted" "ALLOWLISTED"
assert_contains "case 4 admits it did not measure visibility" "NOT measured this run"

# --- CASE 5: ZERO workflow files -> CANNOT-RUN, never CLEAN ----------------
D5="$(mk_wf_dir)"
run_case "no workflow files -> CANNOT-RUN" 3 "${D5}"
assert_contains "case 5 refuses to pass on an empty scan" "0 workflow files found"

# --- CASE 6: files but no `uses:` at all -> CANNOT-RUN ---------------------
# The absence check must be paired with a control that MUST match. A tree of
# workflows with not one `uses:` line means the predicate is broken, not that
# the tree is clean.
D6="$(mk_wf_dir)"
cat > "${D6}/norun.yml" <<'EOF'
name: norun
on:
  pull_request:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo no actions here
EOF
run_case "workflow files but zero uses: lines -> CANNOT-RUN" 3 "${D6}"
assert_contains "case 6 calls out the broken predicate" "predicate is broken"

# --- CASE 7: the live tree is clean ----------------------------------------
# The point of the whole exercise. If this ever goes red on main, a workflow
# has been added that can vanish from the PR merge box.
printf '\n=== CASE: this repository, as it stands ===\n'
CAP="${TMP}/out.live"
GITHUB_REPOSITORY="andygmassey/CM051-Home-Hub-Installer" \
  /bin/bash "${GATE}" >"${CAP}" 2>&1
rc=$?
sed 's/^/  | /' "${CAP}"
if [ "${rc}" -eq 0 ]; then
  printf 'PASS: live .github/workflows tree has no invisible-workflow risk (rc=0)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: live tree rc=%s\n' "${rc}" >&2; FAIL=$((FAIL+1))
fi

printf '\n============================================================\n'
printf 'no-invisible-reusable-workflows self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
