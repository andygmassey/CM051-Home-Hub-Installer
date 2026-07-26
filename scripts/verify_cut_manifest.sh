#!/usr/bin/env bash
# scripts/verify_cut_manifest.sh
# ============================================================================
# Thin wrapper around verify_cut_manifest.py so the manifest gate sits
# alongside the sibling gates with a consistent bash entry-point:
#
#   scripts/verify_cut_freshness.sh
#   scripts/verify_cut_provenance.sh
#   scripts/provenance_gate.sh
#   scripts/verify_cut_manifest.sh   <-- THIS SCRIPT
#
# Forwards all args to the Python script. See cut-manifests/README.md for
# schema + primitive documentation.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/verify_cut_manifest.py"

if [[ ! -x "${PY}" ]]; then
    chmod +x "${PY}" 2>/dev/null || true
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found on PATH." >&2
    exit 2
fi

# Preflight: check PyYAML is importable, install if missing (local dev + CI).
if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "==> PyYAML not present; attempting user install"
    python3 -m pip install --user --quiet pyyaml || {
        echo "ERROR: failed to install PyYAML. Install manually: pip3 install pyyaml" >&2
        exit 2
    }
fi

exec python3 "${PY}" "$@"
