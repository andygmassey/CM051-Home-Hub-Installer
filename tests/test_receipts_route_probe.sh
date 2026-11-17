#!/usr/bin/env bash
# PROBE (receipts, 134 release, flag-off). Two claims, each with its control:
#  (1) WIRING: the shipped tick carries the receipts step, guarded by OSTLER_RECEIPTS_ENABLED=1, and the
#      LaunchAgent plist ships with the flag at 0 and both receipts dirs. A flag nobody passes is not wiring.
#  (2) LANDING: a synthetic receipt email in an mbox, run through the vendored extractor and handed to the
#      vendored core, lands as a Check row in the business book, never filed, never in the personal book.
#      Control: the same run with the handoff absent leaves the core store empty.
# Synthetic only: an invented supplier and an example.com address. HOME is sandboxed; nothing touches ~/.ostler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$ROOT/vendor/email_ingest/bin/email-ingest-tick.sh"
PLIST="$ROOT/vendor/email_ingest/launchd/com.creativemachines.ostler.email-ingest.plist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
# The shipped email venv carries beautifulsoup4 (vendor/cm021/pyproject.toml). Without it this probe cannot run:
# that is CANNOT-RUN, never a pass.
PY="${PROBE_PYTHON:-python3}"
"$PY" -c "import bs4" 2>/dev/null || { echo "CANNOT-RUN: $PY has no bs4 (set PROBE_PYTHON to the email venv python)" >&2; exit 2; }

# ---- (1) wiring --------------------------------------------------------------
grep -q 'if \[ "${OSTLER_RECEIPTS_ENABLED:-0}" = "1" \]; then' "$TICK" || fail "tick: receipts step is not flag-guarded"
TICK_LINE="$(grep -- '--to-receipts-core' "$TICK" || true)"
[ -n "$TICK_LINE" ] || fail "tick: no line passes --to-receipts-core (scheduled command lacks the flag)"
case "$TICK_LINE" in *'-m src.receipts'*'--to-receipts-core "$OSTLER_RECEIPTS_CLI_DIR"'*) ;; *) fail "tick: flag line malformed: $TICK_LINE" ;; esac
"$PY" - "$PLIST" <<'PY' || fail "plist: receipts keys missing or flag not 0"
import plistlib, sys
p = open(sys.argv[1], "rb").read().decode()
assert "<key>OSTLER_RECEIPTS_ENABLED</key>\n        <string>0</string>" in p
assert "RECEIPTS_CLI_DIR_PATH" in p and "RECEIPTS_EXTRACTOR_DIR_PATH" in p
PY
echo "ok wiring: tick passes --to-receipts-core under the flag; plist ships the flag at 0"

# ---- (2) landing --------------------------------------------------------------
MBOX="$TMP/receipts.mbox"
EML="$ROOT/tests/fixtures/receipts_route/amazon_order.eml"   # synthetic order email (email-intelligence fixture)
"$PY" - "$EML" "$MBOX" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(b"From probe@example.com Fri Jan 10 21:03:00 2024\n" + raw + b"\n")
PY

export OSTLER_RECEIPTS=1
PY_BIN="$PY"
export OSTLER_RECEIPTS_HOME="$TMP/store"
export OSTLER_RECEIPTS_FILES="$TMP/files"
CORE="$ROOT/vendor/receipts_core"
EXT="$ROOT/vendor/receipts_extractor"
export CORE_SRC="$CORE/src"

CORE_SRC="$CORE/src" "$PY" - <<'PY'
import os, sys
sys.path.insert(0, os.environ["CORE_SRC"])
from receipts.store import Store
from receipts import books as bk
bk.make_book(Store(), kind="business", name="Sole Trader", preset="uk_self_employed", home_currency="GBP",
             tax_registered=True, book_id="bk_biz", tax_year_start="04-06")
PY

# Control: extractor WITHOUT the handoff leaves the core store empty.
( cd "$EXT" && PYTHONPATH="$EXT" "$PY" -m src.receipts --input "$MBOX" --store "$TMP/control.jsonl" >/dev/null )
CONTROL_COUNT="$(CORE_SRC="$CORE/src" "$PY" -c "import os,sys; sys.path.insert(0, os.environ['CORE_SRC']); from receipts.store import Store; print(len(Store().receipts()))")"
[ "$CONTROL_COUNT" = "0" ] || fail "control: core store not empty without the handoff ($CONTROL_COUNT)"

# Treatment: the same extractor run WITH the handoff, as the tick runs it.
( cd "$EXT" && PYTHONPATH="$EXT" "$PY" -m src.receipts --input "$MBOX" --store "$TMP/extractor.jsonl" --to-receipts-core "$CORE" >/dev/null ) \
    || fail "handoff: extractor run with --to-receipts-core exited non-zero"

CORE_SRC="$CORE/src" "$PY" - <<'PY' || fail "landing: receipt not in the business Check, or leaked into the wrong book"
import os, sys
sys.path.insert(0, os.environ["CORE_SRC"])
from receipts.store import Store
from receipts.ops import export_payload
s = Store()
rows = s.receipts()
assert len(rows) == 1, "expected one receipt, got %d" % len(rows)
r = rows[0]
assert r["source"] == "email", r.get("source")
assert r["book_id"] is None and r["status"] == "check", "extractor must never file: %r %r" % (r["book_id"], r["status"])
biz = export_payload(s, {"book_id": "bk_biz", "tax_year": "2024/25"})
assert [x["id"] for x in biz["needs_checking"]["receipts"]] == [r["id"]], "not in the business Needs checking"
assert biz["expenses"] == [] and biz["totals"]["business_share_home"] == 0, "Check item counted in a total"
print("landed: business Needs checking, unfiled, 0 in totals")
PY
echo "ok landing: synthetic receipt email -> business Needs checking (control: empty store without handoff)"
