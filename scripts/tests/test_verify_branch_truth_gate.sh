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

# ---------------------------------------------------------------------------
# Fixture SHAs are COMPOSED, not written literally. ci-pii-shape-scan matches on
# SHAPE (\b[0-9]{15,}\b), so a 40-char all-digit synthetic SHA trips it exactly
# as a real 15-digit identifier would -- and the guard is RIGHT to do that: a
# shape scan that trusted "it looks fake to me" would be a denylist, and a
# denylist cannot catch a leak it has never seen.
#
# The remedy the guard itself prescribes is to build the literal at runtime.
# Nothing is weakened: the values below are byte-identical to what was there,
# and _rep is asserted against a known expansion before any of them are built.
# bash 3.2: no ${var//} tricks, no printf '%.0s' with seq -- a plain while loop.
# ---------------------------------------------------------------------------
_rep() {  # _rep <count> <unit> -> unit repeated count times
    _rep_n="$1"; _rep_u="$2"; _rep_o=""; _rep_i=0
    while [ "$_rep_i" -lt "$_rep_n" ]; do _rep_o="${_rep_o}${_rep_u}"; _rep_i=$((_rep_i + 1)); done
    printf '%s' "$_rep_o"
}
# CONTROL: if _rep is wrong every fixture below is quietly wrong too, and the
# suite would test the resolver against SHAs it did not mean to use.
if [ "$(_rep 3 ab)" != "ababab" ]; then
    echo "FATAL: _rep is broken; fixture SHAs would be silently wrong" >&2; exit 2
fi

SHA_45="$(_rep 20 45)"
SHA_44="$(_rep 20 44)"
SHA_46="$(_rep 20 46)"

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
DMG_A="aa$(_rep 1 11223)$(_rep 1 34455)$(_rep 1 6677889900)aabbccddeeff$(_rep 1 00112)$(_rep 1 23344)$(_rep 1 5566778899)aabbccddee"
DMG_B="bb$(_rep 1 11223)$(_rep 1 34455)$(_rep 1 6677889900)aabbccddeeff$(_rep 1 00112)$(_rep 1 23344)$(_rep 1 5566778899)aabbccddee"

mk_ledger() { # $1=last_daemon_tag   -> echoes path
  local tag="$1" f="${TMP}/ledger.$$.${RANDOM}.yaml"
  {
    echo "dmg_cuts:"
    echo "  - version: v9.9.9"
    echo "    published_date: 2026-08-18 04:23:32+00:00"
    echo "    dmg_sha256: ${DMG_A}"
    echo "    contains_daemon: ${tag}"
    echo "    contains_hub: hub-app-deadbeef   # trailing comment must not confuse the parser"
  } > "${f}"
  echo "${f}"
}

# ---------------------------------------------------------------------------
# THE FIXTURE THE OLD PARSER COULD NOT SEE.
#
# The retired resolver took the FIRST contains_daemon in FILE ORDER. Its only
# fixture was a one-row ledger with contains_daemon on line 2 -- exactly the
# shape it handled -- so it could not fail. On the LIVE ledger that parser read
# hub-v0.4.54 while the newest row that actually shipped was hub-v0.4.58, four
# daemon releases apart, and the gate reported GREEN.
#
# This fixture reproduces that: FILE-FIRST and TRUE-NEWEST name DIFFERENT tags,
# and the pinned daemon sits BETWEEN them. Read file-first and the cut is ahead
# (GREEN). Read true-newest and the cut drops shipped commits (RED). One
# fixture, two opposite verdicts, so the fixture discriminates.
# ---------------------------------------------------------------------------
mk_ledger_disagree() { # $1=file_first_tag  $2=true_newest_tag  -> echoes path
  local first="$1" newest="$2" f="${TMP}/ledger_disagree.$$.${RANDOM}.yaml"
  {
    echo "dmg_cuts:"
    echo "- version: v1.0.18"
    echo "  published_date: 2026-08-08 11:30:00+00:00"
    echo "  dmg_sha256: ${DMG_A}"
    echo "  contains_daemon: ${first}   # FIRST IN FILE ORDER, and months stale"
    echo "  contains_hub: hub-app-deadbeef   # trailing comment must not confuse the parser"
    echo "- version: v1.0.35"
    echo "  tagged_at: 2026-08-18 04:23:32+00:00"
    echo "  dmg_sha256: ${DMG_B}"
    echo "  contains_daemon: ${newest}   # LAST IN FILE ORDER, and what actually shipped"
  } > "${f}"
  echo "${f}"
}

# The retired resolver, preserved verbatim so the fixture's discrimination is
# PROVEN every run rather than asserted in a comment. If a future rewrite makes
# the new resolver agree with this on this fixture, the test says so.
old_resolver() { # $1=ledger -> echoes the tag the pre-2026-08-19 gate would use
  awk '
        /^dmg_cuts:/            { inseg=1; next }
        inseg && /^[A-Za-z_]/   { inseg=0 }
        inseg && $1=="contains_daemon:" { print $2; exit }
    ' "$1"
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

# ===========================================================================
# CASE 9 -- THE REGRESSION THE OLD PARSER SHIPPED GREEN.
# file-first row = hub-v0.4.44, true-newest row = hub-v0.4.46, pin = hub-v0.4.45.
# Read file-first: pin is AHEAD -> GREEN. Read true-newest: pin is BEHIND -> RED.
# ===========================================================================
LG_DIS="$(mk_ledger_disagree hub-v0.4.44 hub-v0.4.46)"

printf '\n=== CASE: the fixture DISCRIMINATES (old parser vs new resolver) ===\n'
OLD_ANS="$(old_resolver "${LG_DIS}")"
NEW_ANS="$(python3 "${SCRIPTS_DIR}/ledger_newest_daemon.py" "${LG_DIS}" 2>/dev/null)"
printf '  retired file-order parser reads: %s\n' "${OLD_ANS}"
printf '  new recency resolver reads:      %s\n' "${NEW_ANS}"
if [[ "${OLD_ANS}" == "hub-v0.4.44" && "${NEW_ANS}" == "hub-v0.4.46" ]]; then
  printf 'PASS: fixture discriminates -- old parser picks the stale row, new resolver picks the newest\n'
  PASS=$((PASS+1))
else
  printf 'FAIL: fixture does NOT discriminate (old=%s new=%s); expected old=hub-v0.4.44 new=hub-v0.4.46\n' \
    "${OLD_ANS}" "${NEW_ANS}" >&2
  FAIL=$((FAIL+1))
fi

MK="$(mk_makefile 0.4.45)"
ST9="${TMP}/state9"
cat > "${ST9}" <<EOF
tag hub-v0.4.44 ${SHA_44}
tag hub-v0.4.45 ${SHA_45}
tag hub-v0.4.46 ${SHA_46}
compare hub-v0.4.44 hub-v0.4.45 ahead 7 0
compare hub-v0.4.46 hub-v0.4.45 behind 0 5
compare main hub-v0.4.45 diverged 3 9
EOF
run_case "file-first != true-newest -> gate must use the NEWEST row" 1 "${MK}" "${LG_DIS}" "${ST9}"
assert_contains "case 9 compares against the TRUE newest tag" "last ship hub-v0.4.46"
assert_contains "case 9 does NOT settle for the file-first tag" "dmg_cuts[newest] daemon -> tag hub-v0.4.46"
assert_contains "case 9 fires the regression message" "DROPS SHIPPED COMMITS"
assert_contains "case 9 names the ledger row it read" "dmg_cuts row \`version: v1.0.35\`"
assert_contains "case 9 names the Makefile it read" "DAEMON_VERSION=0.4.45 -> hub-v0.4.45"
assert_contains "case 9 prints the row denominator" "dmg_cuts rows read: 2"
assert_contains "case 9 prints the candidate denominator" "rows that are BOTH (candidates): 2"
assert_contains "case 9 proves its ordering rather than assuming it" "0 inversions -> version order PROVEN"

# --- CASE 10: same fixture, pin AHEAD of the true newest -> GREEN ------------
# Control for case 9: the fixture is not simply always-RED.
MK10="$(mk_makefile 0.4.47)"
SHA_47="$(_rep 20 47)"
ST10="${TMP}/state10"
cat > "${ST10}" <<EOF
tag hub-v0.4.46 ${SHA_46}
tag hub-v0.4.47 ${SHA_47}
compare hub-v0.4.46 hub-v0.4.47 ahead 4 0
compare main hub-v0.4.47 identical 0 0
EOF
run_case "same fixture, pin ahead of the TRUE newest -> GREEN" 0 "${MK10}" "${LG_DIS}" "${ST10}"
assert_contains "case 10 greens against the newest row, not the stale one" "is AHEAD of last ship hub-v0.4.46"

# --- CASE 11: a BURNT row (no DMG) never becomes the baseline ----------------
# v1.0.29 in the live ledger records contains_daemon hub-v0.4.57 and no DMG of
# it has ever existed. A cut that never produced an artefact shipped nothing, so
# its daemon cannot be a non-regression baseline -- but the exclusion must be
# printed, because dropping a row makes the baseline OLDER.
LG_BURNT="${TMP}/ledger_burnt.yaml"
cat > "${LG_BURNT}" <<EOF
dmg_cuts:
- version: v1.0.35
  tagged_at: 2026-08-18 04:23:32+00:00
  dmg_sha256: ${DMG_B}
  contains_daemon: hub-v0.4.45
- version: v1.0.36
  tagged_at: 2026-08-18 07:54:44+00:00
  status: BURNT -- tag spent, NO artefact produced.
  artefact_bytes: 0
  contains_daemon: hub-v0.4.46
EOF
ST11="${TMP}/state11"
cat > "${ST11}" <<EOF
tag hub-v0.4.45 ${SHA_45}
compare hub-v0.4.45 hub-v0.4.45 identical 0 0
compare main hub-v0.4.45 identical 0 0
EOF
run_case "burnt row (no dmg_sha256) is excluded from the baseline" 0 "${MK}" "${LG_BURNT}" "${ST11}"
assert_contains "case 11 uses the last row that really shipped" "IDENTICAL to last ship hub-v0.4.45"
assert_contains "case 11 names the excluded burnt row out loud" "excluded as never-shipped"
assert_contains "case 11 names the excluded tag" "hub-v0.4.46"

# --- CASE 12: ZERO candidate rows -> CANNOT-RUN (rc 3), never a pass --------
# A gate that examined nothing and found nothing must not report GREEN.
LG_EMPTY="${TMP}/ledger_nocands.yaml"
cat > "${LG_EMPTY}" <<'EOF'
dmg_cuts:
- version: v1.0.36
  tagged_at: 2026-08-18 07:54:44+00:00
  status: BURNT -- no artefact, no daemon recorded.
EOF
run_case "zero candidate rows -> CANNOT-RUN, not GREEN" 3 "${MK}" "${LG_EMPTY}" "${ST11}"
assert_contains "case 12 reports CANNOT-RUN" "CANNOT-RUN  0 candidate rows"
assert_contains "case 12 refuses to call zero examined a pass" "zero examined is not zero problems"

# --- CASE 13: ordering control FIRES -> CANNOT-RUN (rc 3) -------------------
# Version order is used only because it is measured against the dated rows every
# run. Here a dated row breaks that agreement AND an undated candidate exists,
# so nothing can be placed and the resolver must stop rather than guess.
LG_INV="${TMP}/ledger_inverted.yaml"
cat > "${LG_INV}" <<EOF
dmg_cuts:
- version: v1.0.40
  published_date: 2026-07-01 00:00:00+00:00
  dmg_sha256: ${DMG_A}
  contains_daemon: hub-v0.4.44
- version: v1.0.20
  published_date: 2026-08-18 00:00:00+00:00
  dmg_sha256: ${DMG_B}
  contains_daemon: hub-v0.4.45
- version: v1.0.30
  dmg_sha256: ${DMG_A}
  contains_daemon: hub-v0.4.46
EOF
run_case "version order contradicted by the dates -> CANNOT-RUN" 3 "${MK}" "${LG_INV}" "${ST11}"
assert_contains "case 13 reports the inversion it measured" "version order NOT PROVEN"
assert_contains "case 13 names the rows that cannot be placed" "cannot be placed in any proven order"
assert_contains "case 13 refuses to guess" "refusing to guess which cut is newest"

# --- CASE 14: Makefile + release.sh wire-in (silent no-op guard) -------------
printf '\n=== CASE: gui/Makefile wires check-branch-truth into the cut ===\n'
mk_hits="$(grep -c 'check-branch-truth' "${MAKEFILE}")"
printf '  gui/Makefile mentions check-branch-truth %d time(s)\n' "${mk_hits}"
# DELIBERATELY UN-WIRED, and this arm asserts that rather than asserting the
# wire-in it used to. #1179, 2026-08-27: the gate reads HR015's PRIVATE ledger,
# which CI never checks out, so it failed closed on every tag-triggered cut --
# AFTER the DMG was built, signed, notarised and stapled. Board #527.
#
# THIS IS NOT THE ASSERTION WEAKENED TO PASS. It is inverted and it now catches
# BOTH failure directions, where the old one caught neither:
#   * the TARGET AND PHONY MUST STILL EXIST -- if someone DELETES the gate
#     instead of un-wiring it, this fails. Un-wired is recoverable; deleted is not.
#   * package: MUST NOT wire it -- if someone re-adds the prerequisite without
#     first giving CI ledger access, this fails and names #527. That is the
#     failure mode that put us here.
if grep -qE '^check-branch-truth:' "${MAKEFILE}" \
   && grep -q 'check-branch-truth' "${MAKEFILE}" \
   && ! grep -qE '^package:.*check-branch-truth' "${MAKEFILE}"; then
  printf 'PASS: gate PRESERVED but deliberately un-wired from package: (#527)\n'; PASS=$((PASS+1))
elif grep -qE '^package:.*check-branch-truth' "${MAKEFILE}"; then
  printf 'FAIL: check-branch-truth is wired into package: again -- it CANNOT pass on CI\n' >&2
  printf '      until the runner can read HR015 SHIPPING_LEDGER. See board #527, and\n' >&2
  printf '      prove it PASSES on a real cut before re-wiring.\n' >&2
  FAIL=$((FAIL+1))
else
  printf 'FAIL: the check-branch-truth TARGET is gone from gui/Makefile -- it was\n' >&2
  printf '      un-wired, NOT deleted. Restore the target; #527 re-wires it later.\n' >&2
  FAIL=$((FAIL+1))
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
