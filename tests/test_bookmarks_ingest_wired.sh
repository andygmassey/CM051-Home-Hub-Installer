#!/usr/bin/env bash
# ingest_bookmarks wiring guard (day-one Reading page, clean follow-up
# to #524, no ship-dark)
# =============================================================
#
# The day-one Reading wiki signal (Safari bookmarks -> Qdrant
# preferences, category=bookmark) only helps the customer if the
# shipped install.sh actually invokes ingest_bookmarks -- and only works
# if the VENDORED ostler_fda copy (the one gui/project.yml bundles into
# the .app) defines it. A stale re-vendor that drops ingest_bookmarks,
# or an install.sh that imports it without the vendored copy carrying
# it, would ImportError at install time and leave the Reading page's
# bookmarks section blank.
#
# This guard fails if either invariant is lost.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
VENDORED="vendor/ostler_fda/pwg_ingest.py"

# 1. The vendored module (the shipping copy) must define ingest_bookmarks
#    (catches a stale re-vendor that drops it).
if ! grep -qE "^def ingest_bookmarks" "$VENDORED"; then
    echo "FAIL: $VENDORED missing ingest_bookmarks (stale vendor)" >&2
    exit 1
fi
echo "vendor check: ingest_bookmarks defined in vendored pwg_ingest"

# 2. The vendored module must register ingest_bookmarks in ingest_all so
#    a bare `ingest_all` run (the email-ingest tick) also populates the
#    Reading page on later runs.
if ! grep -q '("bookmarks", ingest_bookmarks)' "$VENDORED"; then
    echo "FAIL: $VENDORED ingest_all does not register ingest_bookmarks" >&2
    exit 1
fi
echo "vendor check: ingest_bookmarks registered in ingest_all"

# 3. install.sh must actually import + call it (no ship-dark).
if ! grep -q "ingest_bookmarks" "$INSTALL"; then
    echo "FAIL: $INSTALL never invokes ingest_bookmarks (ship-dark)" >&2
    exit 1
fi
echo "wiring check: install.sh invokes ingest_bookmarks"

# 4. ingest_bookmarks must be wired into the hydrate_browsing block so it
#    runs only when the Safari/browsing JSON is present (same FDA-data
#    guard as ingest_browser_history; safari_bookmarks.json lives in the
#    same FDA dir). We assert the import line names both
#    ingest_browser_history and ingest_bookmarks on the same import.
if ! grep -q "from ostler_fda.pwg_ingest import ingest_browser_history, ingest_bookmarks" "$INSTALL"; then
    echo "FAIL: install.sh does not import ingest_bookmarks alongside ingest_browser_history" >&2
    echo "      (it should ride the hydrate_browsing data-present guard)." >&2
    exit 1
fi
echo "wiring check: ingest_bookmarks imported alongside ingest_browser_history (rides its guard)"

# 5. The Reading reader contract: the vendored writer must tag points
#    category=bookmark so CM044 reading_pages.py (which filters on
#    exactly that) can find them. Catches a payload-shape drift.
if ! grep -q '"category": "bookmark"' "$VENDORED"; then
    echo "FAIL: $VENDORED ingest_bookmarks does not write category=bookmark payload" >&2
    echo "      CM044 reading_pages.py filters on category=bookmark; the section stays blank." >&2
    exit 1
fi
echo "contract check: ingest_bookmarks writes category=bookmark payload"

echo "ingest_bookmarks wiring guard: PASS"
