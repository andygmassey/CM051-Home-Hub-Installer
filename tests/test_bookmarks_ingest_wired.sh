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

# 2. The vendored module must register ingest_bookmarks in the ingest_all dispatch
#    table so a bare `ingest_all` run (the email-ingest tick) also populates
#    the Reading page on later runs.
#
#    THIS ASSERTED A RENDERING AND WENT RED WHILE THE WIRING WAS INTACT.
#
#    It used to grep for the literal `("bookmarks", ingest_bookmarks)` -- a BARE symbol.
#    The dispatch table was refactored to resolve writers by NAME:
#
#        _INGEST_DISPATCH = (
#            ...
#            ("bookmarks", "ingest_bookmarks"),      <- quoted, not a bare reference
#        )
#
#    so the grep missed and this test reported "ingest_all does not register
#    ingest_bookmarks" against a tree where it is registered -- in the vendored
#    copy, in the HR015 upstream, and invoked from install.sh. Anyone acting
#    on that report would have gone looking for a ships-dark writer that was
#    never dark. Nobody did, because this file runs nowhere.
#
#    The predicate now reads the CONTENT: inside the _INGEST_DISPATCH block,
#    one entry naming both the result key and the writer, in either spelling.
#    It is also SCOPED to that block, where the old one would have matched the
#    pair anywhere in a 2,500-line module.
DISPATCH_BLOCK="$(awk '/^_INGEST_DISPATCH[[:space:]]*=/{f=1} f{print} f&&/^\)/{exit}' "$VENDORED")"
if [ -z "$DISPATCH_BLOCK" ]; then
    # No table at all means this check examined nothing. An empty extract
    # compares clean, which is the false green the rewrite exists to avoid.
    echo "FAIL: could not locate _INGEST_DISPATCH in $VENDORED -- this check examined nothing" >&2
    exit 1
fi
if ! printf '%s\n' "$DISPATCH_BLOCK" \
     | grep -qE '\("bookmarks"[[:space:]]*,[[:space:]]*"?ingest_bookmarks"?[[:space:]]*\)'; then
    echo "FAIL: $VENDORED _INGEST_DISPATCH has no ("bookmarks", ingest_bookmarks) entry" >&2
    echo "      the dispatch table as found was:" >&2
    printf '%s\n' "$DISPATCH_BLOCK" | sed 's/^/        /' >&2
    exit 1
fi
echo "vendor check: ingest_bookmarks registered in the ingest_all dispatch table"

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
