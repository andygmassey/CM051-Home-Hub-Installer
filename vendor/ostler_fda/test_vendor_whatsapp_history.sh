#!/usr/bin/env bash
# CX-85 vendor/ostler_fda whatsapp_history import regression
# ===========================================================
#
# Asserts that vendor/ostler_fda/ ships the pieces install.sh's
# hydrate_whatsapp sub-phase needs at customer install time:
#
#   - whatsapp_history.py     extractor + 3-tier classifier + main() CLI
#   - pwg_ingest.py           with ingest_whatsapp + the whatsapp entry
#                             in _SOURCE_PREDICATE
#   - extract_all.py          with whatsapp_history in ALL_SOURCES
#
# Before CX-85 only iMessage + calendar + photos + apple_mail had
# ingest_* functions. If a future refactor drops the whatsapp_history
# module or breaks the pwg_ingest.ingest_whatsapp registration,
# install.sh's hydrate_whatsapp block silently degrades to
# MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING. This script catches
# that regression at CI time so we surface it BEFORE a customer
# install.
#
# Network-free, env-var-free, dependency-free for the structural
# check. The optional import-time check exercises the same module
# path install.sh runs ("python -m ostler_fda.whatsapp_history")
# and falls back to inconclusive when the runtime deps the rest
# of ostler_fda needs are missing in CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Structural check -- always runs, deps-free.
missing=""
for path in \
    whatsapp_history.py \
    pwg_ingest.py \
    extract_all.py
do
    if [ ! -f "$SCRIPT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/ostler_fda/ missing files:$missing" >&2
    echo "      Re-sync from HR015 ostler_fda/ (see CX-85)." >&2
    exit 1
fi
echo "structural check: vendor/ostler_fda/ contains whatsapp_history.py + pwg_ingest.py + extract_all.py"

# whatsapp_history.py must expose the load-bearing 3-tier symbols
# the install.sh hydrate_whatsapp block + classifier consumers rely on.
for symbol in \
    "TIER_T1_DM" \
    "TIER_T2_INTIMATE" \
    "TIER_T2_ACTIVE" \
    "TIER_T3_SKIP" \
    "T2_CONFIDENCE" \
    "INTIMATE_PARTICIPANT_MAX" \
    "ENGAGEMENT_WINDOW_DAYS" \
    "ENGAGEMENT_FLOOR_ABSOLUTE" \
    "ENGAGEMENT_FLOOR_RELATIVE" \
    "def classify_chat" \
    "def extract_conversations" \
    "def conversation_stats" \
    "def main"
do
    if ! grep -q -- "$symbol" "$SCRIPT_DIR/whatsapp_history.py"; then
        echo "FAIL: vendor/ostler_fda/whatsapp_history.py missing symbol: $symbol" >&2
        echo "      The 3-tier classifier or CLI is incomplete; install.sh's" >&2
        echo "      hydrate_whatsapp block will silently degrade or crash." >&2
        exit 1
    fi
done
echo "symbol check: whatsapp_history.py exposes 3-tier classifier + CLI"

# Andy's threshold lock-ins (do not tune without sign-off). The
# regression test pins the actual numeric values so a refactor
# cannot silently shift them. The intimate cutoff was the
# load-bearing addition vs. the original engagement-only model.
if ! grep -qE "^INTIMATE_PARTICIPANT_MAX = 10\b" "$SCRIPT_DIR/whatsapp_history.py"; then
    echo "FAIL: INTIMATE_PARTICIPANT_MAX must be exactly 10 (Andy 2026-05-26 lock-in)." >&2
    exit 1
fi
if ! grep -qE "^ENGAGEMENT_WINDOW_DAYS = 90\b" "$SCRIPT_DIR/whatsapp_history.py"; then
    echo "FAIL: ENGAGEMENT_WINDOW_DAYS must be exactly 90 (lock-in)." >&2
    exit 1
fi
if ! grep -qE "^ENGAGEMENT_FLOOR_ABSOLUTE = 20\b" "$SCRIPT_DIR/whatsapp_history.py"; then
    echo "FAIL: ENGAGEMENT_FLOOR_ABSOLUTE must be exactly 20 (lock-in)." >&2
    exit 1
fi
if ! grep -qE "^ENGAGEMENT_FLOOR_RELATIVE = 0\.02\b" "$SCRIPT_DIR/whatsapp_history.py"; then
    echo "FAIL: ENGAGEMENT_FLOOR_RELATIVE must be exactly 0.02 (lock-in)." >&2
    exit 1
fi
if ! grep -qE "^T2_CONFIDENCE = 0\.7\b" "$SCRIPT_DIR/whatsapp_history.py"; then
    echo "FAIL: T2_CONFIDENCE must be exactly 0.7 (lock-in)." >&2
    exit 1
fi
echo "threshold lock-in check: < 10 / 90d / >= 20 / >= 0.02 / 0.7 all match"

# pwg_ingest must register the whatsapp source predicate. Without
# this the SPARQL upsert silently skips lastContactWhatsApp updates.
if ! grep -qE '"whatsapp":\s*"pwg:lastContactWhatsApp"' "$SCRIPT_DIR/pwg_ingest.py"; then
    echo "FAIL: pwg_ingest._SOURCE_PREDICATE missing whatsapp entry." >&2
    echo "      ingest_whatsapp will call _update_last_contact with no predicate" >&2
    echo "      and silently drop the freshness signal." >&2
    exit 1
fi
echo "pwg_ingest check: whatsapp entry in _SOURCE_PREDICATE"

# extract_all must include whatsapp_history in ALL_SOURCES (NOT
# DEFAULT_SOURCES per Q3b sign-off -- opt-in only).
if ! grep -qE 'ALL_SOURCES.*whatsapp_history' "$SCRIPT_DIR/extract_all.py"; then
    echo "FAIL: extract_all.ALL_SOURCES missing whatsapp_history." >&2
    echo "      The Phase 2 picker tickbox will be unwireable." >&2
    exit 1
fi
echo "extract_all check: whatsapp_history in ALL_SOURCES"

# Optional import-time check. Mirrors how install.sh invokes the
# CLI ("python -m ostler_fda.whatsapp_history --json"). Falls back
# to inconclusive when bs4 / httpx / other ostler_fda runtime deps
# are missing -- those are pip-installed by install.sh's email-ingest
# venv setup, not by the structural test runner.
PY_IMPORT_CHECK=$(/usr/bin/env python3 - "$SCRIPT_DIR/.." <<'PY'
import sys, importlib
sys.path.insert(0, sys.argv[1])
try:
    mod = importlib.import_module("ostler_fda.whatsapp_history")
    # Spot-check the 3-tier constants are the actual values, not strings.
    assert mod.INTIMATE_PARTICIPANT_MAX == 10
    assert mod.ENGAGEMENT_WINDOW_DAYS == 90
    assert mod.ENGAGEMENT_FLOOR_ABSOLUTE == 20
    assert abs(mod.ENGAGEMENT_FLOOR_RELATIVE - 0.02) < 1e-9
    assert abs(mod.T2_CONFIDENCE - 0.7) < 1e-9
    assert mod.TIER_T1_DM == "whatsapp_dm"
    assert mod.TIER_T2_INTIMATE == "whatsapp_group_intimate"
    assert mod.TIER_T2_ACTIVE == "whatsapp_group_active"
    print("OK")
except AssertionError as exc:
    print(f"FAIL: tier constant value mismatch ({exc})")
    sys.exit(2)
except ImportError as exc:
    msg = str(exc)
    if "No module named 'ostler_fda.whatsapp_history'" in msg:
        print(f"FAIL: {msg}")
        sys.exit(2)
    print(f"INCONCLUSIVE: external dep missing ({msg})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: whatsapp_history imports cleanly + tier constants match lock-ins"
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

echo "vendor/ostler_fda whatsapp_history regression: PASS"
