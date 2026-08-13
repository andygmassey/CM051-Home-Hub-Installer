#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Self-test for verify_test_wiring.sh.
#
# The gate it tests exists because 131 of 171 test files ran nowhere. It would
# be a poor joke to add a gate for that and not run its own controls, so every
# case below drives the gate against a PURPOSE-BUILT fixture repo and asserts an
# exit code. Never against the real tree: a control pinned to the live repo goes
# red for the wrong reason the moment someone adds a test.
#
# Each control states what a FALSE PASS would mean, because that is the failure
# that matters -- a wiring gate that cannot detect unwiring is the thing it is
# supposed to catch, wearing a badge.
# ---------------------------------------------------------------------------
set -uo pipefail

GATE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify_test_wiring.sh"
PASSED=0; FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

[ -x "$GATE_SRC" ] || { echo "gate not executable: $GATE_SRC" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Build a miniature repo: a tests/ dir, a .github/ that references some of them,
# and a copy of the gate.
setup() {
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo/tests" "$TMP/repo/.github/workflows" "$TMP/repo/scripts" "$TMP/repo/bin"
  cp "$GATE_SRC" "$TMP/repo/tests/verify_test_wiring.sh"
  chmod +x "$TMP/repo/tests/verify_test_wiring.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/repo/tests/test_alpha.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/repo/tests/test_beta.sh"
  # alpha IS referenced by a workflow; beta is not.
  printf 'jobs:\n  x:\n    steps:\n      - run: ./tests/test_alpha.sh\n' \
    > "$TMP/repo/.github/workflows/ci.yml"
}
manifest() { printf '%b' "$1" > "$TMP/repo/tests/TEST_WIRING.tsv"; }
# TODAY is pinned so the expiry controls do not change verdict by calendar.
run() { ( cd "$TMP/repo" && TEST_WIRING_TODAY=2026-08-13 /bin/bash tests/verify_test_wiring.sh >/dev/null 2>&1 ); echo $?; }

# MANUAL rows now need reason + declarer + review-by. Shorthand for a valid one.
OK_MANUAL='MANUAL\tneeds a real device\tandy\t2099-01-01'

echo "test_verify_test_wiring"

# --- baseline: both classified correctly -> 0 -------------------------------
setup
manifest "test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
[ "$rc" = 0 ] && ok "wired + reasoned-manual -> rc=0" \
              || bad "baseline: expected 0, got $rc"

# --- CONTROL 1: a WIRED claim that is FALSE --------------------------------
# The headline failure. If this passes, the manifest can claim coverage that
# does not exist -- which is exactly the state D675 measured, just written down.
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\tWIRED\tsomewhere, honest\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a WIRED row nothing references is caught (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: a FALSE 'WIRED' claim PASSED. The manifest can now assert coverage that does not exist."
else bad "CONTROL FAILED: false-WIRED gave rc=$rc, expected 1"; fi

# --- CONTROL 2: MANUAL with no reason --------------------------------------
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\tMANUAL\t\tandy\t2099-01-01\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: MANUAL with no reason is rejected (rc=1)"
else bad "CONTROL FAILED: reasonless MANUAL gave rc=$rc, expected 1. Manual without a reason is unwired with better manners."; fi

# --- CONTROL 3: UNCLASSIFIED is not a pass ---------------------------------
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\tUNCLASSIFIED\t\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: UNCLASSIFIED fails, it is not a warning (rc=1)"
else bad "CONTROL FAILED: UNCLASSIFIED gave rc=$rc, expected 1"; fi

# --- CONTROL 4: a test on disk with NO row ---------------------------------
# This is HOW the 131 accumulated: files were added and nothing noticed.
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: an UNLISTED test file is caught (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: a test with no manifest row PASSED. That is precisely how 131 files accumulated unnoticed."
else bad "CONTROL FAILED: unlisted file gave rc=$rc, expected 1"; fi

# --- CONTROL 5: a row naming a file that no longer exists ------------------
setup
manifest "test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\t$OK_MANUAL\ntest_ghost.sh\tWIRED\tnowhere\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a ROTTED row (file deleted) is caught (rc=1)"
else bad "CONTROL FAILED: rotted row gave rc=$rc, expected 1"; fi

# --- CONTROL 6: missing manifest -> 2, never 0 -----------------------------
setup
rm -f "$TMP/repo/tests/TEST_WIRING.tsv"
rc="$(run)"
if   [ "$rc" = 2 ]; then ok "CONTROL: missing manifest is UNAVAILABLE (rc=2), not a pass"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: no manifest PASSED. No expectations would read as no findings."
else bad "CONTROL FAILED: missing manifest gave rc=$rc, expected 2"; fi

# --- CONTROL 7: an unknown status word -------------------------------------
setup
manifest "test_alpha.sh\tPROBABLY\t.github/workflows/ci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: an unknown status word is rejected (rc=1)"
else bad "CONTROL FAILED: bad status gave rc=$rc, expected 1. A typo must not create a silent fourth state."; fi

# --- CONTROL 8: the gate parses under bash 3.2 -----------------------------
# The lesson from test_orphan_gate_cannot_verify.sh, same day: a script that
# cannot parse under /bin/bash never runs, while the suite around it still
# prints PASS lines for whatever it reached.
if /bin/bash -n "$GATE_SRC" 2>/dev/null; then
  ok "CONTROL: the gate itself parses under /bin/bash (3.2)"
else
  bad "CONTROL FAILED: the gate does not parse under /bin/bash. It would never run."
fi

# --- CONTROL 9: a STEM-PREFIX collision must not satisfy a WIRED row --------
# The bug this control was written for was LATENT in the first version of the
# gate, which matched the extensionless stem. In the real tree test_install_gui_
# contract.py would have been satisfied by a reference to test_install_gui_
# contract_negatives.py. Nothing was mis-reported, because both happened to be
# referenced -- but delete one runner and the gate would have reported the dead
# row as covered. A false pass in the exact direction the gate polices.
setup
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/repo/tests/test_alpha_extra.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: ./tests/test_alpha_extra.sh\n' \
  > "$TMP/repo/.github/workflows/ci.yml"
manifest "test_alpha.sh\tWIRED\tci.yml\ntest_alpha_extra.sh\tWIRED\tci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a longer sibling sharing the stem does NOT satisfy a WIRED row (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: test_alpha.sh passed on a reference to test_alpha_extra.sh. Stem matching is back and every prefix-sharing test is falsely covered."
else bad "CONTROL FAILED: stem collision gave rc=$rc, expected 1"; fi

# --- CONTROL 10: a mention in a COMMENT is not wiring ------------------------
# Same-day precedent on a different gate: a commented-out line in cut.yml was
# counted as CI wiring. grep -l answers "contains the string", not "runs it".
setup
printf 'jobs:\n  x:\n    steps:\n      # - run: ./tests/test_alpha.sh   (disabled)\n      - run: true\n' \
  > "$TMP/repo/.github/workflows/ci.yml"
manifest "test_alpha.sh\tWIRED\tci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a commented-out reference does not count as WIRED (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: a test disabled behind a comment reported as WIRED. Disabling a runner would be invisible."
else bad "CONTROL FAILED: comment reference gave rc=$rc, expected 1"; fi

# --- CONTROL 11: an EXPIRED manual declaration fails ------------------------
# Archie's constraint, and it is paid for: cut-deferrals.yaml carried a deferral
# for #606 after #606 merged, and the gate printed DEFERRED over shipping work.
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\tMANUAL\tneeds a device\tandy\t2026-01-01\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a MANUAL row past its review date fails (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: an expired opt-out PASSED. MANUAL becomes a permanent hiding place."
else bad "CONTROL FAILED: expired manual gave rc=$rc, expected 1"; fi

# --- CONTROL 12: MANUAL with no review date at all --------------------------
setup
manifest 'test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\tMANUAL\tneeds a device\tandy\t\n'
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: MANUAL with no review-by date is rejected (rc=1)"
else bad "CONTROL FAILED: dateless MANUAL gave rc=$rc, expected 1. No expiry is an expiry of never."; fi

# --- CONTROL 13: MANUAL that IS actually run --------------------------------
# Drift in the quiet direction: the row under-states coverage, and a runner
# exists that nobody believes in.
setup
printf 'jobs:\n  x:\n    steps:\n      - run: ./tests/test_alpha.sh\n      - run: ./tests/test_beta.sh\n' \
  > "$TMP/repo/.github/workflows/ci.yml"
manifest "test_alpha.sh\tWIRED\tci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: a MANUAL row that something DOES run is caught as stale (rc=1)"
else bad "CONTROL FAILED: stale MANUAL gave rc=$rc, expected 1"; fi

# --- CONTROL 15: a python test invoked as a MODULE counts as wired ----------
# Found by the gate demoting a genuinely-wired row on its first real run:
# wiki-tailnet-gate.yml runs `python3 -m unittest tests.test_tailnet_owner_
# resolution`, with no extension and a dot instead of a slash. Matching the
# raw filename missed it entirely.
setup
printf 'import unittest\n' > "$TMP/repo/tests/test_gamma.py"
printf 'jobs:\n  x:\n    steps:\n      - run: ./tests/test_alpha.sh\n      - run: python3 -m unittest tests.test_gamma -v\n' \
  > "$TMP/repo/.github/workflows/ci.yml"
manifest "test_alpha.sh\tWIRED\tci.yml\ntest_gamma.py\tWIRED\tci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 0 ]; then ok "CONTROL: 'python3 -m unittest tests.test_gamma' counts as WIRED (rc=0)"
else bad "CONTROL FAILED: a module-form invocation was not recognised (rc=$rc). Every python test run by unittest reads as unwired."; fi

# CONTROL 15b: and that leniency must NOT reopen the stem hole. Same module
# form, but the runner names a DIFFERENT, longer module.
setup
printf 'import unittest\n' > "$TMP/repo/tests/test_gamma.py"
printf 'import unittest\n' > "$TMP/repo/tests/test_gamma_extra.py"
printf 'jobs:\n  x:\n    steps:\n      - run: ./tests/test_alpha.sh\n      - run: python3 -m unittest tests.test_gamma_extra -v\n' \
  > "$TMP/repo/.github/workflows/ci.yml"
manifest "test_alpha.sh\tWIRED\tci.yml\ntest_gamma.py\tWIRED\tci.yml\ntest_gamma_extra.py\tWIRED\tci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$(run)"
if   [ "$rc" = 1 ]; then ok "CONTROL: module-form matching still rejects a longer sibling module (rc=1)"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: tests.test_gamma_extra satisfied a row for test_gamma.py. The boundary is not holding."
else bad "CONTROL FAILED: module stem collision gave rc=$rc, expected 1"; fi

# --- CONTROL 14: no usable date -> 2, never 0 -------------------------------
# If today cannot be established the expiry check is unenforceable. Skipping it
# quietly would turn every expired opt-out green.
setup
manifest "test_alpha.sh\tWIRED\t.github/workflows/ci.yml\ntest_beta.sh\t$OK_MANUAL\n"
rc="$( ( cd "$TMP/repo" && TEST_WIRING_TODAY=not-a-date /bin/bash tests/verify_test_wiring.sh >/dev/null 2>&1 ); echo $? )"
if   [ "$rc" = 2 ]; then ok "CONTROL: an unusable date is UNAVAILABLE (rc=2), not a pass"
elif [ "$rc" = 0 ]; then bad "CONTROL FAILED: no usable date PASSED. The expiry check would silently stop running."
else bad "CONTROL FAILED: bad date gave rc=$rc, expected 2"; fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"; exit 0
else printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASSED" "$FAILED" >&2; exit 1; fi
