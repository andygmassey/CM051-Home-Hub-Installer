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
#
# 2026-09-03 CORRECTION, AND IT IS THE SAME MISTAKE THIS CHECK ALREADY MADE
# ONCE. The block above fixed "it named the wrong object" and then named a
# second wrong object. It decided whether the FDA sweep may list apple_notes
# by grepping a stub in vendor/ostler_fda/universal_import.py -- but that stub
# governs the DRAG-AND-DROP path (a customer dropping a NoteStore.sqlite),
# NOT the sweep that OSTLER_FDA_SOURCES controls. The two are different code
# paths with different persistence stories, and this file asserts both.
#
# The contradiction was visible in this file's own output. Checks 1 to 6 PASS,
# and between them they prove the INSTALL path persists: install.sh emits
# hydrate_apple_notes, drives `convert --source apple_notes` on the staged
# JSON plus the embed phase, and orders it after fda_extract and before
# wiki_compile. Then check 7 failed the very same source for having no
# persistence. A test cannot prove a thing in one half and deny it in the
# other; one of the halves is measuring the wrong object, and it was this one.
#
# The premise is also simply out of date. The comment above says the re-pin
# "to 7ace7672 that carries the apple_notes.py adapter is DEFERRED". It is
# not: VENDOR_MANIFEST.toml now pins cm024_knowledge at 1fabd75d, the adapter
# is vendored, and the adapters registry maps the "apple_notes" source kind.
# The instruction was "remove it from the default, or land the re-pin". The
# re-pin landed. This check could not see it because it read a proxy in
# another tree instead of the capability itself.
#
# So measure the CAPABILITY DIRECTLY, and keep the consent invariant exactly
# as strict. `git ls-files`, not `ls`: a file on disk that is not in the commit
# does not ship, and would give a capability claim no artefact can honour.
CM024_ADAPTER="vendor/cm024_knowledge/ostler_knowledge/ingestion/adapters/apple_notes.py"
CM024_REGISTRY="vendor/cm024_knowledge/ostler_knowledge/ingestion/adapters/__init__.py"

_an_capability=absent
if [ -n "$(git ls-files -- "$CM024_ADAPTER")" ] \
   && [ -n "$(git ls-files -- "$CM024_REGISTRY")" ] \
   && grep -q '"apple_notes": AppleNotesAdapter' "$CM024_REGISTRY"; then
    _an_capability=present
fi

if [ "$_an_capability" = absent ]; then
    # No converter. We must not ask for access we cannot use: taking Full Disk
    # Access to a customer's Notes, reading every one and using none of them.
    if grep -qE '^RECOMMENDED=.*apple_notes' "$INSTALL"; then
        fail "apple_notes is in RECOMMENDED but the CM024 converter is NOT vendored.
   Expected $CM024_ADAPTER to be a tracked file and the adapters registry to map
   the apple_notes source kind; one or both are missing, so
   'convert --source apple_notes' exits non-zero. Remove it from RECOMMENDED,
   or land the re-pin."
    fi
    if grep -qE '^OSTLER_FDA_SOURCES=.*apple_notes' "$INSTALL"; then
        fail "apple_notes is in the default OSTLER_FDA_SOURCES but the CM024
   converter is NOT vendored. The notes would be extracted and then go nowhere
   searchable. Remove it from the default, or land the re-pin."
    fi
    echo "consent check: converter absent, and apple_notes is correctly absent"
    echo "               from RECOMMENDED + defaults"
else
    # Capability landed. Now the inverse must hold: we have it and must offer
    # it, and the install path must actually drive it. This arm fails if the
    # converter lands and nobody restores the source, which is the silent
    # half -- a capability built and never switched on.
    grep -qE '^OSTLER_FDA_SOURCES=.*apple_notes' "$INSTALL" \
        || fail "the CM024 apple_notes converter IS vendored and registered, but
   apple_notes is absent from the default OSTLER_FDA_SOURCES. The capability
   exists and nothing feeds it. Restore it."
    # Check 1 already asserted install.sh drives convert+embed; re-assert the
    # source kind here so this arm cannot pass on wiring that does not exist.
    grep -q -- '--source apple_notes' "$INSTALL" \
        || fail "converter vendored and source enabled, but install.sh never runs
   convert --source apple_notes. The sweep would stage JSON and stop."
    echo "capability check: CM024 converter vendored + registered, apple_notes"
    echo "                 enabled in OSTLER_FDA_SOURCES, install.sh drives convert"
fi

# The DRAG-AND-DROP path is a SEPARATE object with its own honesty rule. It is
# allowed to be stage-only, but it must SAY SO. A stub that quietly stopped
# describing itself as deferred would read as persistence that does not exist.
[[ -f "$UNIVERSAL" ]] || fail "vendored universal_import missing at $UNIVERSAL"
if grep -q 'DEFERRED persistence' "$UNIVERSAL"; then
    echo "drop-path check: universal_import _dispatch_apple_notes is stage-only"
    echo "                 and declares it (tracked separately; the FDA sweep"
    echo "                 persists via install.sh hydrate_apple_notes)"
else
    # The stub is GONE, so this leg now CLAIMS persistence. Make it prove it.
    # Deleting the comment is a one-line change; gaining a route is not, and
    # the cheap edit must not be able to buy the expensive verdict.
    grep -q '"--source", "apple_notes"' "$UNIVERSAL" \
        || fail "$UNIVERSAL no longer carries the stage-only stub but _dispatch_apple_notes
   does not route through ostler-knowledge convert --source apple_notes either.
   A leg that stopped declaring itself deferred without gaining a route reads as
   persistence that does not exist, which is worse than an honest stub."
    echo "drop-path check: universal_import routes through convert --source apple_notes"
fi

echo "hydrate_apple_notes wiring guard: PASS"
