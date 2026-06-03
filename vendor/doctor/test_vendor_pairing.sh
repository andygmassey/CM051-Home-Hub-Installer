#!/usr/bin/env bash
# P1-3 vendor/doctor pairing-panel freshness regression
# =====================================================
#
# Asserts that vendor/doctor/agent/ ships the pieces the iOS app's
# Pairing tab needs. Ostler.app's Tauri Hub iframes
#   http://127.0.0.1:8089/pair-ios
# which is served by the vendored Doctor's web_ui.py. Before this guard
# the vendored Doctor was stale (last synced ~2026-05-27, before the
# pairing panel landed upstream): no /pair-ios route, no pair_status.py.
# On a fresh box the iframe 404'd and the Pairing tab rendered blank.
#
# This guard fails the build if a re-vendor ever drops the pairing
# route or its direct dependency again, mirroring the ostler_fda
# browser-history regression guard.
#
# Network-free, dependency-free. Wired into CI on vendor/** changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/agent"

# Structural check: the runtime fileset the pairing panel relies on.
#   web_ui.py            FastAPI entry point, serves /pair-ios
#   pair_status.py       fetch_pair_status() the route calls
#   chat_token.py        companion chat-token mint (lazy-imported by web_ui)
#   imessage_tcc_posture.py  imported by dashboard_components (re-vendor twin)
missing=""
for path in web_ui.py pair_status.py chat_token.py imessage_tcc_posture.py; do
    if [ ! -f "$AGENT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/doctor/agent/ missing files:$missing" >&2
    echo "      Re-sync from HR015 doctor/agent/ (see vendor/doctor/README.md)." >&2
    exit 1
fi
echo "structural check: vendor/doctor/agent/ contains web_ui.py + pair_status.py + chat_token.py + imessage_tcc_posture.py"

# The /pair-ios route must be present. This is the exact target the iOS
# app iframes; without it the Pairing tab is blank.
if ! grep -qE '@app\.get\("/pair-ios"' "$AGENT_DIR/web_ui.py"; then
    echo "FAIL: vendor/doctor/agent/web_ui.py has no @app.get(\"/pair-ios\") route" >&2
    echo "      The iOS Pairing tab iframes /pair-ios; a stale vendor blanks it." >&2
    exit 1
fi
echo "route check: web_ui.py registers @app.get(\"/pair-ios\")"

# The route handler resolves the paircode via pair_status.fetch_pair_status.
if ! grep -q "from pair_status import fetch_pair_status" "$AGENT_DIR/web_ui.py"; then
    echo "FAIL: web_ui.py /pair-ios path does not import pair_status.fetch_pair_status" >&2
    exit 1
fi
if ! grep -qE "^def fetch_pair_status" "$AGENT_DIR/pair_status.py"; then
    echo "FAIL: vendor/doctor/agent/pair_status.py missing fetch_pair_status()" >&2
    exit 1
fi
echo "wiring check: web_ui.py imports fetch_pair_status + pair_status.py defines it"

# The pair-status JSON endpoints the panel polls must be present too.
for route in '/api/v1/pair/status' '/api/v1/pair/regenerate'; do
    if ! grep -qF "\"$route\"" "$AGENT_DIR/web_ui.py"; then
        echo "FAIL: web_ui.py missing pair endpoint: $route" >&2
        exit 1
    fi
done
echo "endpoint check: web_ui.py registers /api/v1/pair/status + /api/v1/pair/regenerate"

# pair_status.py uses qrcode to render the pairing QR; the vendored
# requirements.txt must carry it or a customer venv install fails at runtime.
if grep -qE "^import qrcode|^from qrcode" "$AGENT_DIR/pair_status.py"; then
    if ! grep -qE "^qrcode" "$AGENT_DIR/requirements.txt"; then
        echo "FAIL: pair_status.py imports qrcode but vendor/doctor/agent/requirements.txt omits it" >&2
        echo "      Re-sync requirements.txt from HR015 doctor/agent/." >&2
        exit 1
    fi
    echo "dependency check: pair_status.py uses qrcode + requirements.txt pins it"
fi

# Import-coherence: every local module web_ui.py imports must be vendored,
# so a partial re-vendor cannot ship a web_ui that crashes on a missing
# sibling at customer runtime (the chat_token disease).
PY_IMPORT_CHECK=$(/usr/bin/env python3 - "$AGENT_DIR" <<'PY'
import ast, sys, os
agent = sys.argv[1]
src = open(os.path.join(agent, "web_ui.py"), encoding="utf-8").read()
tree = ast.parse(src)
local_modules = set()
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
        top = node.module.split(".")[0]
        if os.path.isfile(os.path.join(agent, top + ".py")) or top in {
            "pair_status", "chat_token", "proxy", "status_collector",
            "diagnostic_rules", "first_run", "dashboard_components",
            "web_ui_copy", "wiki_correct", "import_evernote",
            "imessage_tcc_posture", "banner_copy", "diagnostic_copy",
            "first_run_copy",
        }:
            local_modules.add(top)
missing = [m for m in sorted(local_modules)
           if not os.path.isfile(os.path.join(agent, m + ".py"))]
if missing:
    print("FAIL: web_ui.py imports un-vendored local modules: " + ", ".join(missing))
    sys.exit(2)
print("OK")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import-coherence check: every local module web_ui.py imports is vendored"
        ;;
    FAIL:*)
        echo "$PY_IMPORT_CHECK" >&2
        exit 1
        ;;
    *)
        echo "import-coherence check: unexpected output: $PY_IMPORT_CHECK" >&2
        exit 1
        ;;
esac

echo "vendor/doctor pairing-panel regression: PASS"
