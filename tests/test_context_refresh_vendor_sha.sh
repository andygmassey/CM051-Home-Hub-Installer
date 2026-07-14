#!/usr/bin/env bash
# context-refresh vendored-file SHA guard
# =======================================
#
# context-refresh/bin/generate_pwg_context.py is a GRAFTED (divergent)
# vendored copy of ostler-assistant's script -- it lives OUTSIDE vendor/,
# so verify_vendor_fresh.sh (which walks vendor/VENDOR_MANIFEST.toml) never
# sees it. That is exactly the ostler_fda failure class: a patched vendored
# file whose provenance record silently rots.
#
# This guard pins the file to the "Current SHA-256" recorded in its
# VENDOR.md. Patch the file without updating VENDOR.md (or vice versa) and
# CI goes red -- forcing the record to track the reality.
#
# Network-free, dependency-free.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILE="context-refresh/bin/generate_pwg_context.py"
VENDOR_MD="context-refresh/VENDOR.md"

if [ ! -f "$FILE" ] || [ ! -f "$VENDOR_MD" ]; then
    echo "FAIL: expected $FILE and $VENDOR_MD to exist" >&2
    exit 1
fi

# Compute the actual SHA-256 (shasum on macOS, sha256sum on Linux runners).
if command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$FILE" | awk '{print $1}')"
else
    ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
fi

# Extract the recorded "Current SHA-256" from the VENDOR.md table row.
RECORDED="$(grep -iE 'Current SHA-256' "$VENDOR_MD" \
    | grep -oE '[0-9a-f]{64}' | head -n1 || true)"

if [ -z "$RECORDED" ]; then
    echo "FAIL: no 'Current SHA-256' (64-hex) recorded in $VENDOR_MD" >&2
    exit 1
fi

if [ "$ACTUAL" != "$RECORDED" ]; then
    echo "FAIL: $FILE drifted from its VENDOR.md provenance record." >&2
    echo "      recorded (Current SHA-256): $RECORDED" >&2
    echo "      actual:                     $ACTUAL" >&2
    echo "      Update the 'Current SHA-256' row in $VENDOR_MD (and re-apply the" >&2
    echo "      local divergence patches if you re-vendored)." >&2
    exit 1
fi

echo "context-refresh vendored-file SHA guard: PASS ($ACTUAL)"
