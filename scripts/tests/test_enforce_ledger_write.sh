#!/usr/bin/env bash
# ============================================================================
# test_enforce_ledger_write.sh -- prove the vendored ledger gate FIRES.
#
# The gate it replaces produced NO CHECK-RUN AT ALL: a cross-repo `uses:` into
# a private repo fails the workflow at startup, and a startup failure yields
# zero jobs and zero check-runs. It was never red, it was absent. So the first
# thing this file proves is that the replacement can be RED at all.
#
# Every case drives scripts/enforce_ledger_write.sh in --changed-files-file
# mode (no git needed) or against a real throwaway git repo where the pin-line
# scan needs a diff.
#
# Exit code = number of failed assertions.
# macOS /bin/bash 3.2. British English; " -- " not em-dashes.
# ============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/enforce_ledger_write.sh"

TMP="$(mktemp -d -t enforce_ledger_write_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0; FAIL=0
CAP=""

run_case() { # name expected_rc <args...>
  local name="$1" exp="$2"; shift 2
  CAP="${TMP}/out.$$.${RANDOM}"
  printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${exp}"
  /bin/bash "${GATE}" "$@" >"${CAP}" 2>&1
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

mk_changed() { local f="${TMP}/changed.$$.${RANDOM}"; printf '%s\n' "$@" > "${f}"; echo "${f}"; }
mk_body()    { local f="${TMP}/body.$$.${RANDOM}";    printf '%s\n' "$1"  > "${f}"; echo "${f}"; }

EMPTY_BODY="$(mk_body 'Just a normal PR description with no markers at all.')"

# --- CASE 1: THE RED. Shipping-adjacent change, no marker -> BLOCK ----------
CH="$(mk_changed 'cut-manifests/v1.0.14.yaml' 'README.md')"
run_case "cut-manifests/ touched + no ledger marker -> BLOCK" 1 \
  --changed-files-file "${CH}" --pr-body-file "${EMPTY_BODY}"
assert_contains "case 1 names the trigger"        "cut-manifests/ touched"
assert_contains "case 1 names what it measured"   "changed file(s) from"
assert_contains "case 1 names what it expected"   "expected: one of those two markers"
assert_contains "case 1 prints the denominator"   "files in the diff:   2"

# --- CASE 2: same change WITH the ledger marker -> PASS ---------------------
BODY_OK="$(mk_body 'Bumps the manifest.

[ledger-entry: https://github.com/andygmassey/HR015-Gaming-PC/commit/deadbeef]')"
run_case "cut-manifests/ touched + ledger marker -> PASS" 0 \
  --changed-files-file "${CH}" --pr-body-file "${BODY_OK}"
assert_contains "case 2 echoes the marker it found" "[ledger-entry:"

# --- CASE 3: bypass marker -> PASS with a loud WARN -------------------------
BODY_SKIP="$(mk_body 'Docs only, really.

[skip-ledger-enforce: reverting an unshipped experiment]')"
run_case "bypass marker -> PASS but WARN" 0 \
  --changed-files-file "${CH}" --pr-body-file "${BODY_SKIP}"
assert_contains "case 3 warns rather than silently passing" "enforcement bypassed"
assert_contains "case 3 surfaces the stated reason" "reverting an unshipped experiment"

# --- CASE 4: nothing shipping-adjacent -> PASS ------------------------------
# The control for cases 1-3: the gate is not simply always-red.
CH_SAFE="$(mk_changed 'docs/README.md' 'gui/OstlerInstaller/View.swift')"
run_case "no shipping-adjacent path -> PASS without a marker" 0 \
  --changed-files-file "${CH_SAFE}" --pr-body-file "${EMPTY_BODY}"
assert_contains "case 4 says why it passed" "no shipping-adjacent path"

# --- CASE 5: vendor/ at depth fires ----------------------------------------
CH_V="$(mk_changed 'vendor/ostler_fda/extract_all.py')"
run_case "vendored file touched -> BLOCK" 1 \
  --changed-files-file "${CH_V}" --pr-body-file "${EMPTY_BODY}"
assert_contains "case 5 names the vendor trigger" "vendored file touched"

# --- CASE 6: ZERO changed files -> CANNOT-RUN (rc 3), never a pass ---------
CH_EMPTY="${TMP}/changed.empty"; : > "${CH_EMPTY}"
run_case "empty diff -> CANNOT-RUN, not PASS" 3 \
  --changed-files-file "${CH_EMPTY}" --pr-body-file "${EMPTY_BODY}"
assert_contains "case 6 refuses to call zero examined a pass" "Zero examined"

# --- CASE 7: missing refs -> CANNOT-RUN ------------------------------------
run_case "no refs and no changed-file list -> CANNOT-RUN" 3
assert_contains "case 7 says what is missing" "--base-ref and --head-sha are both required"

# --- CASE 8: a real git diff, pin line changed -> BLOCK ---------------------
# The pin-line triggers need an actual diff, so this case builds a throwaway
# repo. It also proves the two-dot diff is used: a file that MAIN changed and
# the branch did not must not count.
G="${TMP}/gitrepo"
mkdir -p "${G}/gui"
(
  cd "${G}" || exit 1
  git init -q .
  git config user.email t@example.invalid
  git config user.name  Test
  printf 'DAEMON_VERSION       ?= 0.4.57\n' > gui/Makefile
  printf 'unrelated\n' > other.txt
  git add -A && git commit -qm base
  git branch -q base-ref
  printf 'DAEMON_VERSION       ?= 0.4.58\n' > gui/Makefile
  git add -A && git commit -qm 'bump the daemon pin'
)
HEAD_SHA="$(git -C "${G}" rev-parse HEAD)"
CAP="${TMP}/out.git"
printf '\n=== CASE: real diff, DAEMON_VERSION line changed (expect rc=1) ===\n'
( cd "${G}" && /bin/bash "${GATE}" --base-ref base-ref --head-sha "${HEAD_SHA}" \
    --pr-body-file "${EMPTY_BODY}" ) >"${CAP}" 2>&1
rc=$?
sed 's/^/  | /' "${CAP}"
if [ "${rc}" -eq 1 ]; then
  printf 'PASS: DAEMON_VERSION pin change blocks without a marker (rc=%s)\n' "${rc}"; PASS=$((PASS+1))
else
  printf 'FAIL: expected rc=1, got %s\n' "${rc}" >&2; FAIL=$((FAIL+1))
fi
assert_contains "case 8 names the pin line it saw change" "DAEMON_VERSION|DAEMON_SHA256 line changed"
assert_contains "case 8 confirms the pin scan actually ran" "version-pin line scan: measured"

# --- CASE 9: the wiring. The old failure was INVISIBILITY, so assert the ----
# workflow defines its jobs LOCALLY and calls this script.
printf '\n=== CASE: the workflow runs this script in a locally-defined job ===\n'
WF="${SCRIPTS_DIR}/../.github/workflows/enforce-ledger-write.yml"
if [ ! -f "${WF}" ]; then
  printf 'FAIL: %s missing\n' "${WF}" >&2; FAIL=$((FAIL+1))
else
  ok=1
  grep -q 'runs-on:' "${WF}" || { printf 'FAIL: workflow defines no local runner\n' >&2; ok=0; }
  grep -qF 'scripts/enforce_ledger_write.sh' "${WF}" || { printf 'FAIL: workflow does not call the gate\n' >&2; ok=0; }
  if grep -q '^[[:space:]]*uses:[[:space:]]*[^[:space:]]*\.github/workflows/' "${WF}"; then
    printf 'FAIL: workflow still calls a reusable workflow -- that is the shape that produced 0 check-runs\n' >&2
    ok=0
  fi
  # Positive control for the absence check above: the same predicate MUST match
  # a string that is definitely present, or the absence proves nothing.
  grep -q '^[[:space:]]*uses:[[:space:]]*actions/checkout' "${WF}" \
    || { printf 'FAIL: control failed -- no `uses: actions/checkout` found, so the grep predicate is wrong\n' >&2; ok=0; }
  if [ "${ok}" -eq 1 ]; then
    printf 'PASS: jobs are defined locally and call the vendored gate\n'; PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
fi

printf '\n============================================================\n'
printf 'enforce-ledger-write gate self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
