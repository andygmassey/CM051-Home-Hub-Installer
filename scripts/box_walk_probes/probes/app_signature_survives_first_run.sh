#!/usr/bin/env bash
# probes/app_signature_survives_first_run.sh
# ============================================================================
# QUESTION: does the installer still verify AFTER it has been run once?
#
# Measured 2026-08-25: the v1.0.45 DMG passed 14 of 14 artefact checks and then
# bricked itself the first time Andy launched it --
#     "OstlerInstaller is damaged and can't be opened. You should move it to
#      the Bin."
#
# CAUSE. The app ships ZERO .pyc. The first time its bundled python3.11 runs
# from a WRITABLE location it compiles its own stdlib and writes
#   Contents/Resources/python/lib/python3.11/__pycache__/*.cpython-311.pyc
# INSIDE the signed bundle. Adding any file voids the seal. syspolicyd then
# refuses the interpreter about once a second, each refusal raising a dialog,
# and the installer retries -- so pressing Cancel summons the next one. It took
# three removals to recover: the .pyc, com.apple.quarantine, and the separate
# com.apple.provenance record. A customer has none of them.
#
# 🔴 WHY EVERY ARTEFACT CHECK MISSED IT, and this is the lesson worth keeping:
# all 14 read the app on a READ-ONLY volume, where this defect CANNOT occur.
# A control that cannot exhibit the defect is not a control. This probe reads a
# WRITABLE copy, which is the only place a customer ever runs it.
# ============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"

run() {
  box_reachable || { probe_cannot_run "box not reachable"; return; }
  local A=/Applications/OstlerInstaller.app

  if ! box_run "[ -d '$A' ]"; then
    probe_cannot_run "no ${A} on this box -- nothing to examine. NOT a pass."
    return
  fi

  # DENOMINATOR. codesign must actually read the bundle: a silent failure to
  # read is indistinguishable, by exit code alone, from a clean verify.
  local out lines
  out=$(box_run "codesign --verify --deep --strict --verbose=2 '$A' 2>&1")
  lines=$(printf '%s\n' "$out" | /usr/bin/grep -c . || true)
  probe_examined "codesign emitted ${lines} line(s) for ${A}"
  if [ "${lines:-0}" -eq 0 ]; then
    probe_cannot_run "codesign produced NO output -- it did not look, so this is not a pass"
    return
  fi

  local added pyc
  added=$(printf '%s\n' "$out" | /usr/bin/grep -c '^file added:' || true)
  pyc=$(box_run "find '$A' -name '*.pyc' 2>/dev/null | /usr/bin/grep -c . || true")
  probe_examined "files added since signing: ${added} · .pyc inside bundle: ${pyc}"

  if printf '%s\n' "$out" | /usr/bin/grep -q 'sealed resource is missing or invalid'; then
    probe_fail "THE INSTALLER HAS VOIDED ITS OWN SIGNATURE: ${added} file(s) added after signing, ${pyc} .pyc in the bundle. macOS will refuse it as damaged and the customer has no way back."
  elif [ "${pyc:-0}" -gt 0 ]; then
    probe_fail "${pyc} .pyc inside the signed bundle. The seal verifies right now, but bytecode is being written into it, so it WILL break on a later run."
  else
    probe_pass "signature intact after running: 0 files added, 0 .pyc in the bundle"
  fi
}

probe_main run
