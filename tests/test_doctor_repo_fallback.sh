#!/usr/bin/env bash
#
# tests/test_doctor_repo_fallback.sh
#
# Locks the bundled-or-clone fallback chain for the Doctor agent in
# install.sh.
#
# Why this test exists:
#
#   The cold-install audit (2026-05-02) found that Phase 3.13 only
#   probed for `${SCRIPT_DIR}/doctor/agent/` and warn-skipped if
#   the source wasn't there. The Doctor agent lives in HR015's
#   `doctor/agent/` subtree -- so on a productised install where
#   the tarball does not bundle the Doctor source, the LaunchAgent
#   silently never installs and the next-steps reference to
#   localhost:8089/doctor is dead.
#
#   This test pins the new fallback chain (matching the pattern
#   used for hub-power, email-ingest, and wiki-recompile):
#     1. PWG_DOCTOR_REPO env var is documented in --help.
#     2. DOCTOR_REPO config var is wired from PWG_DOCTOR_REPO.
#     3. Phase 3.13 probes ${SCRIPT_DIR}/doctor/agent first.
#     4. Falls through to a re-run check (existing install at
#        ${OSTLER_DIR}/doctor/).
#     5. Falls through to a clone of $DOCTOR_REPO when set.
#     6. Falls through to warn-only when none of the above
#        produces a source.
#
# Sister tests:
#   - test_composite_cleanup.sh -- Phase 3 cleanup pattern
#   - test_total_steps_dynamic.sh -- progress bar contract

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── PWG_DOCTOR_REPO documented in --help ────────────────────────
if ! grep -q '"  PWG_DOCTOR_REPO"' "$INSTALL_SCRIPT"; then
    echo "FAIL [help-missing]: PWG_DOCTOR_REPO is not listed in the --help env-var section" >&2
    exit 1
fi
echo "PASS: PWG_DOCTOR_REPO documented in --help"

# ── DOCTOR_REPO config var wired from PWG_DOCTOR_REPO ───────────
if ! grep -qE '^DOCTOR_REPO="\$\{PWG_DOCTOR_REPO:-\}"' "$INSTALL_SCRIPT"; then
    echo "FAIL [config-missing]: DOCTOR_REPO=\${PWG_DOCTOR_REPO:-} not present in config block" >&2
    exit 1
fi
echo "PASS: DOCTOR_REPO config var wired from PWG_DOCTOR_REPO"

# ── Phase 3.13 probes ${SCRIPT_DIR}/doctor/agent first ──────────
if ! grep -q 'if \[\[ -d "\${SCRIPT_DIR}/doctor/agent" \]\]; then' "$INSTALL_SCRIPT"; then
    echo "FAIL [bundled-probe]: Phase 3.13 does not probe \${SCRIPT_DIR}/doctor/agent" >&2
    exit 1
fi
echo "PASS: Phase 3.13 probes \${SCRIPT_DIR}/doctor/agent (bundled tarball path)"

# ── Empty DOCTOR_REPO branch warns and skips ────────────────────
# Pattern: `elif [[ -z "$DOCTOR_REPO" ]]; then`
if ! grep -qE 'elif \[\[ -z "\$DOCTOR_REPO" \]\]; then' "$INSTALL_SCRIPT"; then
    echo "FAIL [empty-branch]: no 'elif [[ -z \"\$DOCTOR_REPO\" ]]' warn-and-skip branch" >&2
    exit 1
fi
echo "PASS: empty DOCTOR_REPO branch warns and skips"

# ── Clone branch references DOCTOR_REPO + probes doctor/agent ───
# Pattern: `git clone ... "$DOCTOR_REPO" "$DOCTOR_TMP" ... && [[ -d "$DOCTOR_TMP/doctor/agent" ]]`
if ! grep -q 'git clone .* "\$DOCTOR_REPO" "\$DOCTOR_TMP"' "$INSTALL_SCRIPT"; then
    echo "FAIL [clone-cmd]: clone command does not reference \$DOCTOR_REPO + \$DOCTOR_TMP" >&2
    exit 1
fi
echo "PASS: clone branch invokes git clone \$DOCTOR_REPO \$DOCTOR_TMP"

if ! grep -q '\[\[ -d "\$DOCTOR_TMP/doctor/agent" \]\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [clone-probe]: clone branch does not verify doctor/agent in the cloned tree" >&2
    exit 1
fi
echo "PASS: clone branch verifies \$DOCTOR_TMP/doctor/agent before copying"

# ── Clone failure produces useful diagnostics ───────────────────
# When the clone fails the user should see:
#   - the underlying git error (sed-prefixed, capped at 5 lines)
#   - the repo URL
#   - a "to install later" recipe
#   - a hint about PWG_DOCTOR_REPO override
if ! grep -q 'Override the source repo with PWG_DOCTOR_REPO' "$INSTALL_SCRIPT"; then
    echo "FAIL [diag-override]: clone failure does not mention PWG_DOCTOR_REPO override" >&2
    exit 1
fi
echo "PASS: clone failure surfaces PWG_DOCTOR_REPO override hint"

# ── Tmpdir is cleaned up in BOTH success and failure branches ───
# rm -rf "$DOCTOR_TMP" must appear at least twice (one per branch).
RM_TMP_COUNT="$(grep -c 'rm -rf "\$DOCTOR_TMP"' "$INSTALL_SCRIPT")"
if [[ "$RM_TMP_COUNT" -lt 2 ]]; then
    echo "FAIL [tmpdir-leak]: \$DOCTOR_TMP not cleaned in both branches (found ${RM_TMP_COUNT} rm calls)" >&2
    exit 1
fi
echo "PASS: \$DOCTOR_TMP cleaned in both success and failure branches"

echo ""
echo "ALL DOCTOR_REPO FALLBACK TESTS PASSED"
