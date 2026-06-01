#!/usr/bin/env bash
# CX-86 Gap A + Gap C vendor/ostler_fda browser-history regression
# ================================================================
#
# Asserts that vendor/ostler_fda/ ships the pieces install.sh's
# hydrate_browsing sub-phase needs:
#
#   - chrome_history.py       Chrome SQLite extractor (NEW in CX-86 Gap C)
#   - safari_history.py       Safari extractor (guards re-vendor loss)
#   - pwg_ingest.py           with ingest_browser_history + dispatcher entry
#   - extract_all.py          with chrome_history in ALL_SOURCES + wiring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Structural check.
missing=""
for path in chrome_history.py safari_history.py pwg_ingest.py extract_all.py; do
    if [ ! -f "$SCRIPT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/ostler_fda/ missing files:$missing" >&2
    echo "      Re-sync from HR015 ostler_fda/ (see CX-86 Gap A + Gap C)." >&2
    exit 1
fi
echo "structural check: vendor/ostler_fda/ contains chrome_history.py + safari_history.py + pwg_ingest.py + extract_all.py"

# chrome_history.py must expose the symbols install.sh + extract_all rely on.
for symbol in "CHROME_EPOCH_OFFSET" "DEFAULT_HISTORY_PATH" "_copy_history_db" "def extract_history" "def top_domains" "def to_timeline_entries"; do
    if ! grep -q -- "$symbol" "$SCRIPT_DIR/chrome_history.py"; then
        echo "FAIL: vendor/ostler_fda/chrome_history.py missing symbol: $symbol" >&2
        exit 1
    fi
done
echo "symbol check: chrome_history.py exposes WebKit epoch + copy-to-tempdir + extractor + helpers"

# WebKit timestamp constant must be exactly 11644473600.
if ! grep -qE "^CHROME_EPOCH_OFFSET = 11644473600\b" "$SCRIPT_DIR/chrome_history.py"; then
    echo "FAIL: CHROME_EPOCH_OFFSET must be exactly 11644473600 (WebKit -> Unix)" >&2
    exit 1
fi
echo "timestamp constant check: CHROME_EPOCH_OFFSET = 11644473600"

# Lock-during-running workaround must be invoked in extract_history.
if ! grep -q "with _copy_history_db" "$SCRIPT_DIR/chrome_history.py"; then
    echo "FAIL: chrome_history.extract_history must use _copy_history_db (lock workaround)" >&2
    exit 1
fi
echo "lock-workaround check: extract_history uses _copy_history_db context manager"

# pwg_ingest must register ingest_browser_history in the dispatcher.
# (Direct Ollama -> Qdrant writer since HR015 PR #138: no gateway.)
if ! grep -qE "def ingest_browser_history" "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest.py missing ingest_browser_history()" >&2
    exit 1
fi
if ! grep -q '"browser_history", ingest_browser_history' "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest.ingest_all dispatcher missing browser_history entry" >&2
    exit 1
fi
echo "pwg_ingest check: ingest_browser_history defined + registered in dispatcher"

# Direct-Qdrant writer must self-create its collection. On a fresh
# single-Mac install nothing else creates safari_history, and an upsert
# into a missing collection 404s into zero rows -- a blank Browsing page
# that looks "installed". Guards against re-vendoring a writer that
# dropped the ensure (the exact disease browsing-at-v1.0 fixed).
if ! grep -qE "def _qdrant_ensure_collection" "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest.py missing _qdrant_ensure_collection (direct writer must self-create its collection)" >&2
    exit 1
fi
if ! grep -q "_qdrant_ensure_collection(BROWSING_QDRANT_COLLECTION" "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: ingest_browser_history must call _qdrant_ensure_collection before upsert" >&2
    exit 1
fi
echo "self-create check: ingest_browser_history ensures safari_history before upsert"

# Direct-path writer must NOT carry the retired gateway POST machinery.
# (The direct writer's explanatory comment mentions /api/safari/ingest
# to say it does NOT use it, so we sentinel on the gateway config
# constant that only the old POST writer defined.)
if grep -qE "_GATEWAY_ENDPOINT_DEFAULT|OSTLER_GATEWAY_URL" "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest.py still carries the retired gateway POST machinery (stale vendor pre-PR #138)" >&2
    exit 1
fi
echo "no-gateway check: pwg_ingest.py carries no gateway POST machinery"

# Privacy AC: return dict must contain counts only -- key set is pinned
# to the direct contract (status + sent + points_created + skipped +
# total; the gateway-era errored/safari_entries/chrome_entries are gone).
for key in '"status":' '"sent":' '"points_created":' '"skipped_sensitive":' '"total":'; do
    if ! grep -q -- "$key" "$SCRIPT_DIR/pwg_ingest.py"; then
        echo "FAIL: pwg_ingest.py missing return-dict key in ingest_browser_history: $key" >&2
        exit 1
    fi
done
echo "privacy contract check: ingest_browser_history returns counts-only dict"

# extract_all must wire chrome_history (opt-in, default OFF).
if ! grep -qE 'ALL_SOURCES.*chrome_history' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.ALL_SOURCES missing chrome_history" >&2
    exit 1
fi
if ! grep -q 'if "chrome_history" in sources:' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.run_all missing chrome_history conditional block" >&2
    exit 1
fi
echo "extract_all check: chrome_history in ALL_SOURCES + run_all block present"

# Safari extractor must remain importable (guard against re-vendor drop).
if ! grep -q "def extract_history" "$SCRIPT_DIR/safari_history.py"; then
    echo "FAIL: safari_history.py extractor was lost during re-vendor" >&2
    exit 1
fi
echo "safari_history check: still present + extract_history defined"

# Optional import-time check.
PY_IMPORT_CHECK=$(/usr/bin/env python3 - "$SCRIPT_DIR/.." <<'PY'
import sys, importlib
sys.path.insert(0, sys.argv[1])
try:
    chrome = importlib.import_module("ostler_fda.chrome_history")
    assert chrome.CHROME_EPOCH_OFFSET == 11644473600
    assert callable(chrome._copy_history_db)
    print("OK")
except AssertionError as exc:
    print(f"FAIL: constant value mismatch ({exc})")
    sys.exit(2)
except ImportError as exc:
    msg = str(exc)
    if "No module named 'ostler_fda.chrome_history'" in msg:
        print(f"FAIL: {msg}")
        sys.exit(2)
    print(f"INCONCLUSIVE: external dep missing ({msg})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: chrome_history imports cleanly + WebKit constant matches"
        ;;
    INCONCLUSIVE:*)
        echo "import check: skipped (${PY_IMPORT_CHECK#INCONCLUSIVE: })"
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

echo "vendor/ostler_fda browser-history regression: PASS"
