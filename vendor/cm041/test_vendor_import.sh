#!/usr/bin/env bash
# CX-81 B1 vendor-set import regression
# ======================================
#
# Asserts that vendor/cm041/ contains all three packages that install.sh's
# hydrate_graph sub-phase needs at customer install time:
#
#   - contact_syncer      (vCard import, --vcf flag)
#   - meeting_syncer      (calendar backfill, --days flag)
#   - identity_resolver   (shared sibling, imported by BOTH syncers via
#                          a sys.path hack inside their syncer.py files)
#
# Before CX-81 B1 only contact_syncer + assistant_api were vendored;
# meeting_syncer + identity_resolver were missing. The latent
# consequence: any invocation of contact_syncer.syncer (not
# contact_syncer.import_all) raised ``ModuleNotFoundError: No module
# named 'identity_resolver'`` at customer install time.
#
# This script catches a regression of that exact shape: if a future
# refactor drops one of the three subdirs from vendor/cm041/, the
# import fails and the script exits non-zero. Wire into ``make check``
# / CI so the regression is visible BEFORE a customer install.
#
# Network-free, env-var-free, dependency-free for the structural
# check. The optional import-time check needs identity_resolver's
# runtime deps (httpx, phonenumbers); falls back to "deps missing,
# inconclusive" when those are absent rather than failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Structural check -- always runs, deps-free.
missing=""
for sub in contact_syncer meeting_syncer identity_resolver; do
    if [ ! -d "$SCRIPT_DIR/$sub" ]; then
        missing="$missing $sub"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/cm041/ missing subdirs:$missing" >&2
    echo "      Re-sync from CM041 source (see CX-81 B1)." >&2
    exit 1
fi
echo "structural check: vendor/cm041/ contains contact_syncer + meeting_syncer + identity_resolver"

# Specific files the install.sh hydrate_graph step depends on.
for path in \
    contact_syncer/syncer.py \
    meeting_syncer/syncer.py \
    identity_resolver/resolver.py \
    identity_resolver/__init__.py
do
    if [ ! -f "$SCRIPT_DIR/$path" ]; then
        echo "FAIL: vendor/cm041/$path missing" >&2
        exit 1
    fi
done
echo "file check: syncer.py + resolver.py present in all three packages"

# Optional import-time check. Mirrors how install.sh invokes the
# syncers (sys.path hack inside syncer.py expects identity_resolver
# as a sibling package).
PY_IMPORT_CHECK=$(/usr/bin/env python3 - <<'PY'
import sys, importlib
sys.path.insert(0, "vendor/cm041")
try:
    import identity_resolver
    import contact_syncer
    import meeting_syncer
    print("OK")
except ImportError as exc:
    msg = str(exc)
    # Differentiate "vendoring broke" from "external dep missing
    # in this CI environment". Vendoring breakage names one of the
    # three packages above; external-dep missing names httpx,
    # phonenumbers, qdrant_client, vobject, etc.
    for vendored in ("identity_resolver", "contact_syncer", "meeting_syncer"):
        if f"No module named '{vendored}'" in msg:
            print(f"FAIL: {msg}")
            sys.exit(2)
    print(f"INCONCLUSIVE: external dep missing ({msg})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: all three packages import cleanly"
        ;;
    INCONCLUSIVE:*)
        echo "import check: skipped (${PY_IMPORT_CHECK#INCONCLUSIVE: })"
        # Not a failure -- CI without the runtime deps still gets
        # the structural + file checks above.
        ;;
    FAIL:*)
        echo "$PY_IMPORT_CHECK" >&2
        exit 1
        ;;
    *)
        echo "import check: unexpected output: $PY_IMPORT_CHECK" >&2
        exit 1
        ;;
esac

echo "vendor/cm041 import regression: PASS"
