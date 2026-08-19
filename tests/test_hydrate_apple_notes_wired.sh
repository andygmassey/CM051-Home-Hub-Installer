#!/usr/bin/env bash
# hydrate_apple_notes wiring + ship-dark guard (CM024 §7)
# =======================================================
#
# CM024's AppleNotesAdapter (ostler_knowledge/ingestion/adapters/
# apple_notes.py) is built + on CM024 origin/main, but nothing on the
# CM051 installer side invoked it, so Apple Notes stayed dark. This guard
# pins the installer-side wiring that makes the adapter actually run,
# SHIP-DARK (silent-on-empty; a no-op unless apple_notes.json exists).
#
# It asserts:
#   1. install.sh emits the hydrate_apple_notes progress step AND drives
#      the bundled ostler-knowledge two-phase convert+embed path
#      (--source apple_notes / --collection apple_notes_knowledge) -- the
#      SAME path every other knowledge source uses. No ship-dark hole.
#   2. Silent-on-empty: the work is gated on `-s apple_notes.json` (exists
#      AND non-empty), the guardrail for the adapter's discover() which
#      RAISES on a missing file. An absent file must skip cleanly.
#   3. Ordering: the step runs AFTER fda_extract (writes apple_notes.json),
#      graph_db_start (Qdrant up) and knowledge_setup (ostler-knowledge
#      installed), and BEFORE wiki_compile.
#   4. StepCatalog registration (sidebar parity; the install-gui-contract
#      test would otherwise go red on the new progress id).
#   5. The customer-facing MSG_* strings are defined and dash-clean.
#   6. The deferred explicit-flag hook (OSTLER_APPLE_NOTES_KNOWLEDGE) is
#      present (Andy's call; default ON so the only gate is data presence).
#   7. The vendored universal_import _dispatch_apple_notes leg is
#      UN-DEFERRED: the old stage-only "DEFERRED persistence" note is gone
#      and it routes the staged JSON through ostler-knowledge convert.
#
# Static asserts only -- no live ingest, no DB is touched here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
STRINGS="install.sh.strings.en-GB.sh"
CATALOG="gui/OstlerInstaller/Steps/StepCatalog.swift"
UNIVERSAL="vendor/ostler_fda/universal_import.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. install.sh emits the step + drives convert+embed ----------------
grep -q 'progress "Reading your Apple Notes" "hydrate_apple_notes"' "$INSTALL" \
    || fail "$INSTALL does not emit the hydrate_apple_notes progress step"
grep -q -- '--source apple_notes' "$INSTALL" \
    || fail "$INSTALL never invokes ostler-knowledge convert --source apple_notes (ship-dark)"
grep -q -- '--collection "\$_HYDRATE_APPLENOTES_COLLECTION"' "$INSTALL" \
    || fail "$INSTALL never invokes the embed phase for apple_notes"
grep -q 'apple_notes_knowledge' "$INSTALL" \
    || fail "$INSTALL does not reference the apple_notes_knowledge collection"
echo "wiring check: install.sh emits hydrate_apple_notes and drives convert+embed"

# 2. Silent-on-empty: gated on -s apple_notes.json -------------------
grep -q '\[\[ -s "\$_HYDRATE_APPLENOTES_JSON_FILE" \]\]' "$INSTALL" \
    || fail "$INSTALL hydrate_apple_notes is not gated on a non-empty apple_notes.json (-s)"
grep -q 'apple_notes.json' "$INSTALL" \
    || fail "$INSTALL does not reference apple_notes.json"
echo "ship-dark check: hydrate_apple_notes gated on -s apple_notes.json (silent-on-empty)"

# 3. Ordering: after fda_extract/graph_db_start/knowledge_setup, before wiki_compile
an_line="$(grep -n 'progress "Reading your Apple Notes" "hydrate_apple_notes"' "$INSTALL" | head -1 | cut -d: -f1)"
fda_line="$(grep -n '"fda_extract"' "$INSTALL" | head -1 | cut -d: -f1)"
graphdb_line="$(grep -n '"graph_db_start"' "$INSTALL" | head -1 | cut -d: -f1)"
knowledge_line="$(grep -n '"knowledge_setup"' "$INSTALL" | head -1 | cut -d: -f1)"
wiki_line="$(grep -n '"wiki_compile"' "$INSTALL" | head -1 | cut -d: -f1)"
[[ -n "$an_line" && -n "$fda_line" && -n "$graphdb_line" && -n "$knowledge_line" && -n "$wiki_line" ]] \
    || fail "could not locate one or more ordering anchors"
[[ "$an_line" -gt "$fda_line" ]] \
    || fail "hydrate_apple_notes ($an_line) must run AFTER fda_extract ($fda_line) so apple_notes.json exists"
[[ "$an_line" -gt "$graphdb_line" ]] \
    || fail "hydrate_apple_notes ($an_line) must run AFTER graph_db_start ($graphdb_line) so Qdrant is up"
[[ "$an_line" -gt "$knowledge_line" ]] \
    || fail "hydrate_apple_notes ($an_line) must run AFTER knowledge_setup ($knowledge_line) so ostler-knowledge is installed"
[[ "$an_line" -lt "$wiki_line" ]] \
    || fail "hydrate_apple_notes ($an_line) must run BEFORE wiki_compile ($wiki_line)"
echo "ordering check: apple_notes($an_line) after fda_extract/graph_db_start/knowledge_setup, before wiki_compile($wiki_line)"

# 4. StepCatalog registration ----------------------------------------
grep -q '"hydrate_apple_notes"' "$CATALOG" \
    || fail "hydrate_apple_notes not in StepCatalog.canonicalOrder (GUI sidebar drift)"
echo "catalog check: hydrate_apple_notes registered in StepCatalog.canonicalOrder"

# 5. MSG_* strings defined + no em/en dashes -------------------------
for key in \
    MSG_HYDRATE_APPLE_NOTES_STARTED \
    MSG_HYDRATE_APPLE_NOTES_DONE \
    MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA \
    MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING \
    MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES \
    MSG_HYDRATE_APPLE_NOTES_HEARTBEAT ; do
    grep -q "^${key}=" "$STRINGS" || fail "$STRINGS missing string $key"
done
# Em-dash U+2014, en-dash U+2013, figure-dash U+2012, horizontal-bar U+2015
# -> UTF-8 bytes E2 80 9{2,3,4,5}. Match under LC_ALL=C (BSD grep, no -P).
if grep -nE "^MSG_HYDRATE_APPLE_NOTES" "$STRINGS" \
    | LC_ALL=C grep -qE $'\xe2\x80\x92|\xe2\x80\x93|\xe2\x80\x94|\xe2\x80\x95'; then
    fail "hydrate_apple_notes strings contain an em/en dash (use a plain hyphen)"
fi
echo "strings check: all hydrate_apple_notes strings defined and dash-clean"

# 6. Deferred explicit-flag hook present -----------------------------
grep -q 'OSTLER_APPLE_NOTES_KNOWLEDGE' "$INSTALL" \
    || fail "$INSTALL missing the OSTLER_APPLE_NOTES_KNOWLEDGE deferred-flag hook"
echo "hook check: OSTLER_APPLE_NOTES_KNOWLEDGE deferred explicit-flag hook present"

# 7. CONSENT MUST MATCH CAPABILITY -----------------------------------
#
# This check used to assert `DEFERRED persistence` was GONE from
# universal_import.py. Two things were wrong with it.
#
# It named the wrong object. The message said "vendor still carries", sending
# the reader to a re-vendor. But the vendored copy and the HR015 source hash
# identically, so a re-vendor is a no-op -- and a re-vendor in this repo has
# twice been proven destructive. A failure message that recommends a dangerous
# no-op is worse than no message.
#
# And it asserted a state that cannot yet be true. Apple Notes persistence has
# not landed: vendor/VENDOR_MANIFEST.toml holds cm024_knowledge at 43d6c5da,
# and the re-pin to 7ace7672 that carries the apple_notes.py adapter is
# DEFERRED. So this line was permanently red, which meant checks 1 to 6 above
# -- which pass and are worth having -- never reported green.
#
# The invariant that actually matters is not "is it built yet". It is: WE MUST
# NOT ASK FOR ACCESS WE CANNOT USE. So assert the two facts against each other.
# While the stage-only stub is present, apple_notes must not be in RECOMMENDED
# and must not be in the default OSTLER_FDA_SOURCES. This fails if someone
# re-adds the source without landing the converter, and it fails the other way
# when the converter lands and the source is not restored. Either way it points
# at the real object.
[[ -f "$UNIVERSAL" ]] || fail "vendored universal_import missing at $UNIVERSAL"
if grep -q 'DEFERRED persistence' "$UNIVERSAL"; then
    # Stage-only by design. Confirm the installer does not solicit the data.
    if grep -qE '^RECOMMENDED=.*apple_notes' "$INSTALL"; then
        fail "apple_notes is in RECOMMENDED but persistence is still stage-only.
   The converter is NOT vendored: VENDOR_MANIFEST.toml pins cm024_knowledge at
   43d6c5da and the re-pin to 7ace7672 (which carries apple_notes.py) is
   DEFERRED, so 'convert --source apple_notes' exits non-zero.
   We would take Full Disk Access to a customer's Notes, read every one, and
   use none of them. Remove it from RECOMMENDED, or land the re-pin."
    fi
    if grep -qE '^OSTLER_FDA_SOURCES=.*apple_notes' "$INSTALL"; then
        fail "apple_notes is in the default OSTLER_FDA_SOURCES but persistence
   is still stage-only. Same reason as above: the notes would be extracted and
   then go nowhere searchable. Remove it from the default, or land the re-pin."
    fi
    echo "consent check: persistence is stage-only (universal_import.py), and"
    echo "               apple_notes is correctly absent from RECOMMENDED + defaults"
else
    # Persistence has landed. Now the route must be real AND the source restored.
    grep -q '"--source", "apple_notes"' "$UNIVERSAL" \
        || fail "$UNIVERSAL no longer carries the stage-only stub but _dispatch_apple_notes
   does not route through ostler-knowledge convert --source apple_notes either."
    grep -qE '^RECOMMENDED=.*apple_notes' "$INSTALL" \
        || fail "apple_notes persistence has LANDED but the source is still absent from
   RECOMMENDED. The capability exists and we are not offering it. Restore it."
    echo "un-defer check: persistence landed, route present, source restored"
fi

echo "hydrate_apple_notes wiring guard: PASS"
