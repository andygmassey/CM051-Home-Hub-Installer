#!/usr/bin/env bash
# ============================================================================
# test_verify_branch_truth_gate.sh -- prove the branch-truth gate FIRES.
#
# Per feedback_gate_must_prove_it_fires_not_just_compile: a gate needs
# negative-case tests proving it REJECTS the violation, not just CI-green.
# The violation here is the v1.0.12-class regression: a cut whose pinned daemon
# tag is BEHIND / DIVERGED from the last-shipped daemon tag (drops shipped
# commits). A silent no-op gate would let that ship again.
#
# STRATEGY
# --------
# The gate reaches GitHub only through `$BRANCH_TRUTH_GH_BIN api ...`. We inject
# a mock `gh` whose stdout is driven by a per-case STATE file, so no network.
# We feed the pin via a fixture Makefile (GUI_MAKEFILE_OVERRIDE) and the last
# ship via a fixture ledger (SHIPPING_LEDGER_FILE).
#
# STATE file grammar (one directive per line):
#   tag         <tagname> <sha>            # lightweight tag -> "<sha> commit"
#   tag_missing <tagname>                  # -> 404 (tag does not exist)
#   compare <base> <head> <status> <a> <b> # -> "<status> <a> <b>"
#   compare_unreach <base> <head>          # -> transport failure (UNREACH)
# ============================================================================
set -uo pipefail    # NOT -e: run all cases even when one fails.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_branch_truth.sh"
MAKEFILE="${REPO_DIR}/gui/Makefile"
RELEASE_SH="${REPO_DIR}/release.sh"

[[ -x "${GATE}" ]] || chmod +x "${GATE}"

TMP="$(mktemp -d -t verify_branch_truth_gate_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

SHA_45="4545454545454545454545454545454545454545"
SHA_44="4444444444444444444444444444444444444444"
SHA_46="4646464646464646464646464646464646464646"

# ----- mock gh --------------------------------------------------------------
GH_MOCK="${TMP}/gh_mock.sh"
cat > "${GH_MOCK}" <<'MOCK_EOF'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "mock-gh: unexpected argv: $*" >&2; exit 99; }
path="${2:-}"
state="${MOCK_STATE:-}"
[ -f "${state}" ] || { echo '{"message":"no state"}'; exit 1; }
case "${path}" in
  */git/refs/tags/*)
    want="${path##*/git/refs/tags/}"
    while read -r kind a b _; do
      case "${kind}" in
        tag)         [ "${a}" = "${want}" ] && { printf '%s commit\n' "${b}"; exit 0; } ;;
        tag_missing) [ "${a}" = "${want}" ] && { printf '{"message":"Not Found"}\n'; exit 1; } ;;
      esac
    done < "${state}"
    printf '{"message":"Not Found"}\n'; exit 1 ;;
  */compare/*)
    rest="${path##*/compare/}"; base="${rest%%...*}"; head="${rest##*...}"
    while read -r kind a b c d e _; do
      case "${kind}" in
        compare)         [ "${a}" = "${base}" ] && [ "${b}" = "${head}" ] && { printf '%s %s %s\n' "${c}" "${d}" "${e}"; exit 0; } ;;
        compare_unreach) [ "${a}" = "${base}" ] && [ "${b}" = "${head}" ] && { exit 3; } ;;   # non-zero, no body -> UNREACH
      esac
    done < "${state}"
    printf '{"message":"Not Found"}\n'; exit 1 ;;
  *) echo "mock-gh: unhandled path: ${path}" >&2; exit 97 ;;
esac
MOCK_EOF
chmod +x "${GH_MOCK}"

# ----- fixture builders -----------------------------------------------------
mk_makefile() { # $1=daemon_version   -> echoes path
  local ver="$1" f="${TMP}/Makefile.$$.${RANDOM}"
  {
    echo "# fixture Makefile"
    echo "DAEMON_VERSION       ?= ${ver}"
  } > "${f}"
  echo "${f}"
}
mk_ledger() { # $1=last_daemon_tag   -> echoes path
  local tag="$1" f="${TMP}/ledger.$$.${RANDOM}.yaml"
  {
    echo "dmg_cuts:"
    echo "  - version: v9.9.9"
    echo "    contains_daemon: ${tag}"
    echo "    contains_hub: hub-app-deadbeef   # trailing comment must not confuse the parser"
  } > "${f}"
  echo "${f}"
}

PASS=0; FAIL=0
LAST_CAPTURE=""
run_case() { # name expected_rc  MAKEFILE LEDGER STATE [ACKFILE]
  local name="$1" exp="$2" mk="$3" ledger="$4" state="$5" ack="${6:-/dev/null}"
  local cap="${TMP}/out.$$.${RANDOM}"
  printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${exp}"
  BRANCH_TRUTH_GH_BIN="${GH_MOCK}" MOCK_STATE="${state}" \
    GUI_MAKEFILE_OVERRIDE="${mk}" SHIPPING_LEDGER_FILE="${ledger}" \
    BRANCH_TRUTH_ACK_FILE="${ack}" \
    "${GATE}" >"${cap}" 2>&1
  local rc=$?
  sed 's/^/  | /' "${cap}"
  LAST_CAPTURE="${cap}"
  if [[ "${rc}" -eq "${exp}" ]]; then
    printf 'PASS: %s (rc=%s)\n' "${name}" "${rc}"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s got rc=%s, expected %s\n' "${name}" "${rc}" "${exp}" >&2; FAIL=$((FAIL+1))
  fi
}
assert_contains() { # name needle
  if grep -qF -- "$2" "${LAST_CAPTURE}"; then
    printf 'PASS: %s\n' "$1"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (output missing %q)\n' "$1" "$2" >&2; FAIL=$((FAIL+1))
  fi
}

# --- CASE 1: identical -> GREEN (rc 0) + loud main-divergence WARN ----------
MK="$(mk_makefile 0.4.45)"; LG="$(mk_ledger hub-v0.4.45)"
ST1="${TMP}/state1"
cat > "${ST1}" <<EOF
tag hub-v0.4.45 ${SHA_45}
compare hub-v0.4.45 hub-v0.4.45 identical 0 0
compare main hub-v0.4.45 diverged 132 36
EOF
run_case "identical pin == last ship (imminent v1.0.13.3 shape)" 0 "${MK}" "${LG}" "${ST1}"
assert_contains "case 1 reports identical PASS" "IDENTICAL to last ship"
assert_contains "case 1 prints the loud deferred-reconcile WARN" "DIVERGES from main"
assert_contains "case 1 names ahead/behind counts" "132 ahead, 36 behind"

# --- CASE 2: ahead -> GREEN (rc 0) ------------------------------------------
MK="$(mk_makefile 0.4.46)"; LG="$(mk_ledger hub-v0.4.45)"
ST2="${TMP}/state2"
cat > "${ST2}" <<EOF
tag hub-v0.4.46 ${SHA_46}
tag hub-v0.4.45 ${SHA_45}
compare hub-v0.4.45 hub-v0.4.46 ahead 3 0
compare main hub-v0.4.46 identical 0 0
EOF
run_case "pin AHEAD of last ship (normal forward cut)" 0 "${MK}" "${LG}" "${ST2}"
assert_contains "case 2 reports ahead PASS" "is AHEAD of last ship"

# --- CASE 3: behind -> RED (rc 1) -- the v1.0.12 regression shape -----------
MK="$(mk_makefile 0.4.44)"; LG="$(mk_ledger hub-v0.4.45)"
ST3="${TMP}/state3"
cat > "${ST3}" <<EOF
tag hub-v0.4.44 ${SHA_44}
tag hub-v0.4.45 ${SHA_45}
compare hub-v0.4.45 hub-v0.4.44 behind 0 5
compare main hub-v0.4.44 diverged 1 40
EOF
run_case "pin BEHIND last ship -- drops shipped commits" 1 "${MK}" "${LG}" "${ST3}"
assert_contains "case 3 hard-fails with the regression message" "DROPS SHIPPED COMMITS"
assert_contains "case 3 verdict is RED" "BRANCH-TRUTH RED"
assert_contains "case 3 offers the graft-forward fix" "graft-forward"

# --- CASE 4: diverged -> RED (rc 1) -----------------------------------------
MK="$(mk_makefile 0.4.44)"; LG="$(mk_ledger hub-v0.4.45)"
ST4="${TMP}/state4"
cat > "${ST4}" <<EOF
tag hub-v0.4.44 ${SHA_44}
tag hub-v0.4.45 ${SHA_45}
compare hub-v0.4.45 hub-v0.4.44 diverged 2 5
compare main hub-v0.4.44 diverged 2 40
EOF
run_case "pin DIVERGED from last ship" 1 "${MK}" "${LG}" "${ST4}"
assert_contains "case 4 hard-fails" "DROPS SHIPPED COMMITS"

# --- CASE 5: behind BUT acked -> downgraded to WARN, GREEN (rc 0) -----------
ACK="${TMP}/ack.tsv"
printf '# hdr\nhub-v0.4.44\thub-v0.4.45\tdeliberate rollback: 0.4.45 regressed pairing\n' > "${ACK}"
run_case "behind but branch_truth_ack.tsv covers it -> WARN not FAIL" 0 "${MK}" "${LG}" "${ST3}" "${ACK}"
assert_contains "case 5 downgrades via the ack" "DOWNGRADED by branch_truth_ack.tsv"
assert_contains "case 5 surfaces the ack reason" "deliberate rollback"

# --- CASE 6: this-tag does not exist -> RED (rc 1) --------------------------
MK="$(mk_makefile 0.4.99)"; LG="$(mk_ledger hub-v0.4.45)"
ST6="${TMP}/state6"
cat > "${ST6}" <<EOF
tag_missing hub-v0.4.99
tag hub-v0.4.45 ${SHA_45}
EOF
run_case "pinned tag never pushed -> fail-closed" 1 "${MK}" "${LG}" "${ST6}"
assert_contains "case 6 names the missing tag" "does not exist"

# --- CASE 7: ledger missing -> RED (rc 1) -----------------------------------
MK="$(mk_makefile 0.4.45)"
run_case "SHIPPING_LEDGER missing -> fail-closed" 1 "${MK}" "${TMP}/NOPE.yaml" "${ST1}"
assert_contains "case 7 explains the missing ledger" "SHIPPING_LEDGER.yaml not found"

# --- CASE 8: GitHub unreachable on the hard compare -> CANNOT VERIFY (rc 3) --
MK="$(mk_makefile 0.4.45)"; LG="$(mk_ledger hub-v0.4.45)"
ST8="${TMP}/state8"
cat > "${ST8}" <<EOF
tag hub-v0.4.45 ${SHA_45}
compare_unreach hub-v0.4.45 hub-v0.4.45
EOF
run_case "GitHub unreachable comparing tags -> CANNOT VERIFY" 3 "${MK}" "${LG}" "${ST8}"
assert_contains "case 8 reports cannot-verify" "GitHub unreachable"

# --- CASE 9: Makefile + release.sh wire-in (silent no-op guard) --------------
printf '\n=== CASE: gui/Makefile wires check-branch-truth into the cut ===\n'
mk_hits="$(grep -c 'check-branch-truth' "${MAKEFILE}")"
printf '  gui/Makefile mentions check-branch-truth %d time(s)\n' "${mk_hits}"
if [[ "${mk_hits}" -ge 3 ]] && grep -qE '^package:.*check-branch-truth' "${MAKEFILE}"; then
  printf 'PASS: Makefile wire-in (phony + target + package prereq)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: expected >=3 mentions incl a package: prereq\n' >&2; FAIL=$((FAIL+1))
fi
if grep -q 'verify_branch_truth.sh' "${RELEASE_SH}" && grep -q 'DO_DRY_RUN' "${RELEASE_SH}"; then
  printf 'PASS: release.sh runs the gate as a --dry-run-skippable preflight\n'; PASS=$((PASS+1))
else
  printf 'FAIL: release.sh does not wire verify_branch_truth.sh\n' >&2; FAIL=$((FAIL+1))
fi

printf '\n============================================================\n'
printf 'Branch-truth-gate self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
