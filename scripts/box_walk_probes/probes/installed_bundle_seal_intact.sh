#!/usr/bin/env bash
# installed_bundle_seal_intact.sh -- every installed .app must still satisfy its
# own code signature AFTER a real install, not merely when it was signed.
#
# ============================================================================
# WHY THIS EXISTS, AND WHY 32 CUTS PASSED WITHOUT IT
# ============================================================================
#
# MEASURED on the v1.0.32 box, 2026-08-16, after a genuine install:
#
#     spctl -a -vv /Applications/OstlerInstaller.app
#       -> "a sealed resource is missing or invalid"        rc=1
#     codesign --verify --deep --strict
#       -> 346 UNSEALED files
#     263 of those written DURING the install window
#     PKG-INFO mtime 20:25:29  vs  signature Timestamp 17:09:52
#
# Cause: install.sh ran `pip install "${SCRIPT_DIR}/<pkg>"` at FIVE call sites,
# and when the installer runs from the signed app SCRIPT_DIR is
# Contents/Resources. `pip install <dir>` builds IN PLACE, writing *.egg-info
# and build/lib/ into the bundle. A pip build executing inside a notarised
# bundle voids its notarisation.
#
# EVERY SIGNING CHECK WE OWN RUNS PRE-INSTALL, on the freshly signed bundle.
# That is precisely why this survived 32 cuts: the gate and the defect were on
# different surfaces. The signature was valid at the moment it was measured and
# invalid at the moment it mattered. This probe measures the SECOND moment.
#
# The bundle still LAUNCHED on that box only because com.apple.quarantine
# happened to be absent. A customer downloading the DMG carries the quarantine
# bit, and Gatekeeper then refuses. So "it worked on the test Mac" is not
# evidence and must not be accepted as any.
#
# ============================================================================
# CANNOT-RUN IS NOT A PASS
# ============================================================================
#
# Exit 2 when the tooling or the bundles are absent. A box-walk that cannot
# reach codesign has not verified anything, and reporting that as clean is the
# zero-denominator failure this repo keeps finding.

set -uo pipefail

APPS=(
    "/Applications/OstlerInstaller.app"
    "/Applications/Ostler.app"
    "/Applications/Ostler RemoteCapture.app"
)

fail=0
examined=0
missing=0

command -v codesign >/dev/null 2>&1 || {
    echo "CANNOT-RUN: codesign not on PATH; nothing was verified" >&2
    exit 2
}

# POSITIVE CONTROL FIRST. If codesign cannot validate a bundle Apple ships,
# the tool or the environment is broken and every subsequent PASS is worthless.
if ! codesign --verify --deep --strict /System/Applications/Calculator.app >/dev/null 2>&1; then
    echo "CANNOT-RUN: the control bundle (Calculator.app) failed to verify," >&2
    echo "            so codesign is not usable here and no verdict below" >&2
    echo "            would mean anything." >&2
    exit 2
fi

echo "installed-bundle-seal: control PASSED (Calculator.app verifies), so the tool works"

for app in "${APPS[@]}"; do
    if [[ ! -d "$app" ]]; then
        echo "  MISSING   $app"
        missing=$((missing + 1))
        continue
    fi
    examined=$((examined + 1))

    # --deep --strict is the one that notices resources added after signing.
    # A plain `codesign -dv` reads the signature and would still say "signed".
    if out="$(codesign --verify --deep --strict "$app" 2>&1)"; then
        seal="intact"
    else
        seal="BROKEN"
        fail=$((fail + 1))
    fi

    # spctl is what Gatekeeper actually asks. Report it separately: a bundle can
    # verify and still be refused, and vice versa, and collapsing them hides
    # which one the customer will hit.
    if spctl -a -vv "$app" >/dev/null 2>&1; then
        gate="accepted"
    else
        gate="REJECTED"
        fail=$((fail + 1))
    fi

    printf "  %-9s %-9s %s\n" "$seal" "$gate" "$app"

    if [[ "$seal" == "BROKEN" ]]; then
        # Name the artefact and COUNT what is wrong, so the message points at
        # the defect rather than at the gate.
        n="$(printf '%s\n' "$out" | grep -c . || true)"
        echo "      $n line(s) from codesign; first 3:"
        printf '%s\n' "$out" | head -3 | sed 's/^/        /'
    fi
done

echo "installed-bundle-seal: EXAMINED $examined bundle(s), $missing absent, $fail failure(s)"

if [[ "$examined" -eq 0 ]]; then
    echo "CANNOT-RUN: no Ostler bundle was present to examine. This is NOT a pass;" >&2
    echo "            a box with nothing installed cannot demonstrate a good seal." >&2
    exit 2
fi

if [[ "$fail" -gt 0 ]]; then
    echo "FAIL: $fail seal/Gatekeeper failure(s) across $examined installed bundle(s)." >&2
    echo "      A bundle written into after signing is not notarised any more," >&2
    echo "      whatever the pre-install checks said." >&2
    exit 1
fi

exit 0
