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
    echo "==> PyYAML not present; attempting install"
    # TWO ATTEMPTS, AND THE SECOND ONE IS WHY THE v1.0.26 CUT DIED HERE.
    #
    # macos-26 runners ship a PEP 668 externally-managed python3, so
    # `pip install --user` fails with "error: externally-managed-environment"
    # and the gate could not run at all. --break-system-packages is the
    # sanctioned escape for exactly this case and is safe on an ephemeral
    # runner; it is tried SECOND so a normal dev machine still gets a clean
    # user install.
    if ! python3 -m pip install --user --quiet pyyaml 2>/dev/null; then
        if ! python3 -m pip install --break-system-packages --quiet pyyaml 2>/dev/null; then
            echo "ERROR: could not install PyYAML by either route." >&2
            echo "  tried: pip install --user pyyaml" >&2
            echo "  tried: pip install --break-system-packages pyyaml" >&2
            echo "  This gate CANNOT RUN. It has not checked the manifest." >&2
            echo "  Install manually: pip3 install pyyaml" >&2
            exit 2
        fi
    fi
fi

exec python3 "${PY}" "$@"
