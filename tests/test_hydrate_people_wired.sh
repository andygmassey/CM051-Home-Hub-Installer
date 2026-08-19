#!/usr/bin/env bash
# hydrate_people wiring guard (#600, no ship-dark)
# ===============================================
#
# The people-Qdrant populate (ingest_people_to_qdrant) only helps the
# customer if the shipped install.sh actually invokes it -- and only
# works if it runs AFTER the Oxigraph-populating steps (it sweeps
# pwg:Person from Oxigraph). This guard fails if either invariant is
# lost in a future edit or a stale re-vendor.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
VENDORED="vendor/ostler_fda/pwg_ingest.py"

# 1. The vendored module must define the function (catches a stale
#    re-vendor that drops it).
if ! grep -qE "^def ingest_people_to_qdrant" "$VENDORED"; then
    echo "FAIL: $VENDORED missing ingest_people_to_qdrant (stale vendor)" >&2
    exit 1
fi
echo "vendor check: ingest_people_to_qdrant defined in vendored pwg_ingest"

# 2. install.sh must actually call it (no ship-dark).
if ! grep -q "ingest_people_to_qdrant" "$INSTALL"; then
    echo "FAIL: $INSTALL never invokes ingest_people_to_qdrant (ship-dark)" >&2
    exit 1
fi
echo "wiring check: install.sh invokes ingest_people_to_qdrant"

# 3. The hydrate_people step must run AFTER hydrate_imessage so Oxigraph
#    is fully populated (graph contacts + iMessage Person nodes) before
#    the sweep reads pwg:Person.
people_line="$(grep -n 'progress "Indexing your people for search" "hydrate_people"' "$INSTALL" | head -1 | cut -d: -f1)"
imessage_line="$(grep -n 'progress "Hydrating iMessage contacts" "hydrate_imessage"' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -z "$people_line" ] || [ -z "$imessage_line" ]; then
    echo "FAIL: could not locate hydrate_people and/or hydrate_imessage progress callsites" >&2
    exit 1
fi
if [ "$people_line" -le "$imessage_line" ]; then
    echo "FAIL: hydrate_people (line $people_line) must run AFTER hydrate_imessage (line $imessage_line)" >&2
    echo "      The sweep reads pwg:Person from Oxigraph; it must come after the graph is populated." >&2
    exit 1
fi
echo "ordering check: hydrate_people (line $people_line) runs after hydrate_imessage (line $imessage_line)"

# 4. The step id must be registered in the GUI StepCatalog (sidebar
#    parity; the install-gui-contract test enforces this too).
if ! grep -q '"hydrate_people"' gui/OstlerInstaller/Steps/StepCatalog.swift; then
    echo "FAIL: hydrate_people not in StepCatalog.canonicalOrder (sidebar drift)" >&2
    exit 1
fi
echo "catalog check: hydrate_people registered in StepCatalog.canonicalOrder"

echo "hydrate_people wiring guard: PASS"
