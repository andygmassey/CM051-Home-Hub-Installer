#!/usr/bin/env bash
# CX-84 vendor/ostler_fda iMessage hydration regression
# =====================================================
#
# Asserts that vendor/ostler_fda/ ships the pieces install.sh's
# hydrate_imessage sub-phase needs:
#
#   - imessage.py        chat.db extractor (already vendored pre-CX-84)
#   - pwg_ingest.py      with ingest_imessage + dispatcher entry
#   - extract_all.py     with imessage in ALL_SOURCES + the
#                        OSTLER_IMESSAGE_BACKFILL_DAYS env override
#                        added by CX-84
#
# Pins the privacy contract: ingest_imessage's return dict surfaces
# people-count keys only (status / people_created / people_enriched).
# install.sh sums created + enriched for the customer-facing line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Structural check.
missing=""
for path in imessage.py pwg_ingest.py extract_all.py; do
    if [ ! -f "$SCRIPT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/ostler_fda/ missing files:$missing" >&2
    echo "      Re-sync from HR015 ostler_fda/ (see CX-84)." >&2
    exit 1
fi
echo "structural check: vendor/ostler_fda/ contains imessage.py + pwg_ingest.py + extract_all.py"

# imessage.py must expose the chat.db reader install.sh implicitly
# relies on (via extract_all -> imessage_conversations.json).
for symbol in "def extract_conversations" "def conversation_stats" "since_days"; do
    if ! grep -q -- "$symbol" "$SCRIPT_DIR/imessage.py"; then
        echo "FAIL: vendor/ostler_fda/imessage.py missing symbol: $symbol" >&2
        exit 1
    fi
done
echo "symbol check: imessage.py exposes extract_conversations + conversation_stats + since_days"

# pwg_ingest must register ingest_imessage in the dispatcher.
if ! grep -qE "def ingest_imessage" "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest.py missing ingest_imessage()" >&2
    exit 1
fi
# Parse the module rather than grep a spelling. This check went FALSE RED for
# an unknown period because the dispatcher entry was refactored from
#   ("imessage", ingest_imessage)     -> bare name
# to
#   ("imessage", "ingest_imessage")   -> string, for lazy import
# The capability never left; only the formatting changed. A gate keyed to a
# spelling reports a defect that does not exist, which costs exactly as much
# trust as missing one that does.
if ! python3 - "$SCRIPT_DIR/pwg_ingest.py" <<'PYEOF'; then
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
# any tuple/list literal pairing "imessage" with something naming ingest_imessage
found = False
for node in ast.walk(tree):
    if isinstance(node, (ast.Tuple, ast.List)) and len(node.elts) == 2:
        a, b = node.elts
        a_is = isinstance(a, ast.Constant) and a.value == "imessage"
        b_is = ((isinstance(b, ast.Constant) and b.value == "ingest_imessage")
                or (isinstance(b, ast.Name) and b.id == "ingest_imessage"))
        if a_is and b_is:
            found = True; break
if not found:
    sys.exit(1)
PYEOF
    echo "FAIL: pwg_ingest dispatcher has no ('imessage', ingest_imessage) pair" >&2
    exit 1
fi

# POSITIVE CONTROL: the same parse must FAIL on a copy with the pair removed.
_probe="$(mktemp)"; grep -v 'ingest_imessage' "$SCRIPT_DIR/pwg_ingest.py" > "$_probe"
if python3 - "$_probe" <<'PYEOF'; then
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
found = any(isinstance(n,(ast.Tuple,ast.List)) and len(n.elts)==2
            and isinstance(n.elts[0],ast.Constant) and n.elts[0].value=="imessage"
            and ((isinstance(n.elts[1],ast.Constant) and n.elts[1].value=="ingest_imessage")
                 or (isinstance(n.elts[1],ast.Name) and n.elts[1].id=="ingest_imessage"))
            for n in ast.walk(tree))
sys.exit(0 if found else 1)
PYEOF
    rm -f "$_probe"
    echo "POSITIVE CONTROL FAILED: the dispatcher check still passes with the" >&2
    echo "  entry stripped. It is not checking anything." >&2
    exit 1
fi
rm -f "$_probe"
echo "pwg_ingest check: ingest_imessage defined + registered in dispatcher"

# Privacy contract: return dict must surface people_created + people_enriched.
# install.sh's hydrate_imessage block sums these two keys for the
# customer-facing count, so renaming them silently would land an
# install with always-zero counts. Pin the key set.
for key in '"status":' '"people_created":' '"people_enriched":'; do
    if ! grep -q -- "$key" "$SCRIPT_DIR/pwg_ingest.py"; then
        echo "FAIL: pwg_ingest.py missing return-dict key in ingest_imessage: $key" >&2
        exit 1
    fi
done
echo "privacy contract check: ingest_imessage returns counts-only dict (status + people_created + people_enriched)"

# extract_all must include imessage in ALL_SOURCES and honour the
# CX-84 OSTLER_IMESSAGE_BACKFILL_DAYS env override.
if ! grep -qE 'ALL_SOURCES.*\bimessage\b' "$SCRIPT_DIR/extract_all.py" \
   && ! grep -qE '"imessage"' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.ALL_SOURCES missing imessage" >&2
    exit 1
fi
if ! grep -q 'if "imessage" in sources:' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.run_all missing imessage conditional block" >&2
    exit 1
fi
if ! grep -q 'OSTLER_IMESSAGE_BACKFILL_DAYS' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.py missing OSTLER_IMESSAGE_BACKFILL_DAYS env override (CX-84)" >&2
    exit 1
fi
echo "extract_all check: imessage source + OSTLER_IMESSAGE_BACKFILL_DAYS env override present"

# Optional import-time check.
PY_IMPORT_CHECK=$(/usr/bin/env python3 - "$SCRIPT_DIR/.." <<'PY'
import sys, importlib
sys.path.insert(0, sys.argv[1])
try:
    ingest = importlib.import_module("ostler_fda.pwg_ingest")
    assert callable(ingest.ingest_imessage), "ingest_imessage is not callable"
    print("OK")
except AssertionError as exc:
    print(f"FAIL: {exc}")
    sys.exit(2)
except ImportError as exc:
    msg = str(exc)
    if "No module named 'ostler_fda.pwg_ingest'" in msg or "No module named 'ostler_fda.imessage'" in msg:
        print(f"FAIL: {msg}")
        sys.exit(2)
    print(f"INCONCLUSIVE: external dep missing ({msg})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: pwg_ingest.ingest_imessage imports cleanly + is callable"
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

echo "vendor/ostler_fda iMessage hydration regression: PASS"
