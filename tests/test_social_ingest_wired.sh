#!/usr/bin/env bash
# ingest_social wiring guard (Prefs Piece 3, #524, no ship-dark)
# =============================================================
#
# The day-one Social wiki signal (iMessage -> Qdrant preferences,
# category=social) only helps the customer if the shipped install.sh
# actually invokes ingest_social -- and only works if the VENDORED
# ostler_fda copy (the one gui/project.yml bundles into the .app)
# defines it. A stale re-vendor that drops ingest_social, or an
# install.sh that imports it without the vendored copy carrying it,
# would ImportError at install time and leave the Social page blank.
#
# This guard fails if either invariant is lost.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
VENDORED="vendor/ostler_fda/pwg_ingest.py"

# 1. The vendored module (the shipping copy) must define ingest_social
#    (catches a stale re-vendor that drops it).
if ! grep -qE "^def ingest_social" "$VENDORED"; then
    echo "FAIL: $VENDORED missing ingest_social (stale vendor)" >&2
    exit 1
fi
echo "vendor check: ingest_social defined in vendored pwg_ingest"

# 2. The vendored module must register ingest_social in ingest_all so a
#    bare `ingest_all` run (the email-ingest tick) also populates Social.
if ! grep -q '("social", ingest_social)' "$VENDORED"; then
    echo "FAIL: $VENDORED ingest_all does not register ingest_social" >&2
    exit 1
fi
echo "vendor check: ingest_social registered in ingest_all"

# 3. install.sh must actually import + call it (no ship-dark).
if ! grep -q "ingest_social" "$INSTALL"; then
    echo "FAIL: $INSTALL never invokes ingest_social (ship-dark)" >&2
    exit 1
fi
echo "wiring check: install.sh invokes ingest_social"

# 4. ingest_social must be wired into the hydrate_imessage block so it
#    runs only when the iMessage JSON is present (same data-present
#    guard as ingest_imessage). We assert the import line names both
#    ingest_imessage and ingest_social on the same import.
if ! grep -q "from ostler_fda.pwg_ingest import ingest_imessage, ingest_social" "$INSTALL"; then
    echo "FAIL: install.sh does not import ingest_social alongside ingest_imessage" >&2
    echo "      (it should ride the hydrate_imessage data-present guard)." >&2
    exit 1
fi
echo "wiring check: ingest_social imported alongside ingest_imessage (rides its guard)"

# 5. The Social reader contract: the vendored writer must tag points
#    category=social so CM044 social_pages.py (which filters on exactly
#    that) can find them. Catches a payload-shape drift.
if ! grep -q '"category": "social"' "$VENDORED"; then
    echo "FAIL: $VENDORED ingest_social does not write category=social payload" >&2
    echo "      CM044 social_pages.py filters on category=social; the page stays blank." >&2
    exit 1
fi
echo "contract check: ingest_social writes category=social payload"

echo "ingest_social wiring guard: PASS"
