#!/usr/bin/env bash
# hydrate_reminders wiring + ship-dark guard
# ===========================================
#
# vendor/ostler_fda/reminders.py writes reminders.json, extracted under BOTH
# the Recommended and Everything onboarding presets (RECOMMENDED includes
# "reminders"; EVERYTHING extends RECOMMENDED), so most real installs
# capture it. Before this guard's companion install.sh change, nothing read
# it back: no ingest dispatch entry, and the wiki compiler never consumed
# it. This mirrors tests/test_hydrate_apple_notes_wired.sh exactly, because
# the fix follows that control's install.sh pattern exactly (same
# two-phase convert+embed path, same sentinel shape).
#
# It asserts:
#   1. install.sh emits the hydrate_reminders progress step AND drives the
#      bundled ostler-knowledge two-phase convert+embed path
#      (--source reminders / --collection reminders_knowledge).
#   2. Silent-on-empty: gated on `-s reminders.json` (exists AND non-empty),
#      the guardrail for the adapter's discover() which RAISES on a missing
#      file. An absent file must skip cleanly.
#   3. Ordering: the step runs AFTER fda_extract (writes reminders.json),
#      graph_db_start (Qdrant up) and knowledge_setup (ostler-knowledge
#      installed), and BEFORE wiki_compile.
#   4. StepCatalog registration (sidebar parity).
#   5. The customer-facing MSG_* strings are defined and dash-clean.
#   6. The deferred explicit-flag hook (OSTLER_REMINDERS_KNOWLEDGE) is
#      present, mirroring OSTLER_APPLE_NOTES_KNOWLEDGE.
#   7. THE CAPABILITY CHECK, same invariant as apple_notes's: we must not
#      ask for access we cannot use. RemindersAdapter is a real vendored
#      file registered in the CM024 adapters map (unlike apple_notes at the
#      point its own guard was written, this capability is present from the
#      start), so the only correct branch is: reminders MUST be enabled in
#      RECOMMENDED / OSTLER_FDA_SOURCES, and install.sh MUST drive
#      convert --source reminders. If a future re-vendor ever drops the
#      adapter, this test flips arms exactly as test_hydrate_apple_notes_
#      wired.sh's check 7 does, rather than going silently green on a
#      capability that no longer exists.
#
# Static asserts only -- no live ingest, no DB is touched here. The actual
# convert pipeline was run against synthetic fixtures during development
# (see the PR description); this file pins the STATIC wiring so it cannot
# silently regress.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
STRINGS="install.sh.strings.en-GB.sh"
CATALOG="gui/OstlerInstaller/Steps/StepCatalog.swift"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. install.sh emits the step + drives convert+embed ----------------
grep -q 'progress "Reading your Reminders" "hydrate_reminders"' "$INSTALL" \
    || fail "$INSTALL does not emit the hydrate_reminders progress step"
grep -q -- '--source reminders' "$INSTALL" \
    || fail "$INSTALL never invokes ostler-knowledge convert --source reminders (ship-dark)"
grep -q -- '--collection "\$_HYDRATE_REMINDERS_COLLECTION"' "$INSTALL" \
    || fail "$INSTALL never invokes the embed phase for reminders"
grep -q 'reminders_knowledge' "$INSTALL" \
    || fail "$INSTALL does not reference the reminders_knowledge collection"
echo "wiring check: install.sh emits hydrate_reminders and drives convert+embed"

# 2. Silent-on-empty: gated on -s reminders.json ---------------------
grep -q '\[\[ -s "\$_HYDRATE_REMINDERS_JSON_FILE" \]\]' "$INSTALL" \
    || fail "$INSTALL hydrate_reminders is not gated on a non-empty reminders.json (-s)"
grep -q 'reminders.json' "$INSTALL" \
    || fail "$INSTALL does not reference reminders.json"
echo "ship-dark check: hydrate_reminders gated on -s reminders.json (silent-on-empty)"

# 3. Ordering: after fda_extract/graph_db_start/knowledge_setup, before wiki_compile
rm_line="$(grep -n 'progress "Reading your Reminders" "hydrate_reminders"' "$INSTALL" | head -1 | cut -d: -f1)"
fda_line="$(grep -n '"fda_extract"' "$INSTALL" | head -1 | cut -d: -f1)"
graphdb_line="$(grep -n '"graph_db_start"' "$INSTALL" | head -1 | cut -d: -f1)"
knowledge_line="$(grep -n '"knowledge_setup"' "$INSTALL" | head -1 | cut -d: -f1)"
wiki_line="$(grep -n '"wiki_compile"' "$INSTALL" | head -1 | cut -d: -f1)"
[[ -n "$rm_line" && -n "$fda_line" && -n "$graphdb_line" && -n "$knowledge_line" && -n "$wiki_line" ]] \
    || fail "could not locate one or more ordering anchors"
[[ "$rm_line" -gt "$fda_line" ]] \
    || fail "hydrate_reminders ($rm_line) must run AFTER fda_extract ($fda_line) so reminders.json exists"
[[ "$rm_line" -gt "$graphdb_line" ]] \
    || fail "hydrate_reminders ($rm_line) must run AFTER graph_db_start ($graphdb_line) so Qdrant is up"
[[ "$rm_line" -gt "$knowledge_line" ]] \
    || fail "hydrate_reminders ($rm_line) must run AFTER knowledge_setup ($knowledge_line) so ostler-knowledge is installed"
[[ "$rm_line" -lt "$wiki_line" ]] \
    || fail "hydrate_reminders ($rm_line) must run BEFORE wiki_compile ($wiki_line)"
echo "ordering check: reminders($rm_line) after fda_extract/graph_db_start/knowledge_setup, before wiki_compile($wiki_line)"

# 4. StepCatalog registration ----------------------------------------
grep -q '"hydrate_reminders"' "$CATALOG" \
    || fail "hydrate_reminders not in StepCatalog.canonicalOrder (GUI sidebar drift)"
echo "catalog check: hydrate_reminders registered in StepCatalog.canonicalOrder"

# 5. MSG_* strings defined + no em/en dashes -------------------------
for key in \
    MSG_HYDRATE_REMINDERS_STARTED \
    MSG_HYDRATE_REMINDERS_DONE \
    MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA \
    MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING \
    MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES \
    MSG_HYDRATE_REMINDERS_HEARTBEAT ; do
    grep -q "^${key}=" "$STRINGS" || fail "$STRINGS missing string $key"
done
# Em-dash U+2014, en-dash U+2013, figure-dash U+2012, horizontal-bar U+2015
# -> UTF-8 bytes E2 80 9{2,3,4,5}. Match under LC_ALL=C (BSD grep, no -P).
if grep -nE "^MSG_HYDRATE_REMINDERS" "$STRINGS" \
    | LC_ALL=C grep -qE $'\xe2\x80\x92|\xe2\x80\x93|\xe2\x80\x94|\xe2\x80\x95'; then
    fail "hydrate_reminders strings contain an em/en dash (use a plain hyphen)"
fi
echo "strings check: all hydrate_reminders strings defined and dash-clean"

# 6. Deferred explicit-flag hook present -----------------------------
grep -q 'OSTLER_REMINDERS_KNOWLEDGE' "$INSTALL" \
    || fail "$INSTALL missing the OSTLER_REMINDERS_KNOWLEDGE deferred-flag hook"
echo "hook check: OSTLER_REMINDERS_KNOWLEDGE deferred explicit-flag hook present"

# 7. CONSENT MUST MATCH CAPABILITY, same invariant as apple_notes's --
CM024_ADAPTER="vendor/cm024_knowledge/ostler_knowledge/ingestion/adapters/reminders.py"
CM024_REGISTRY="vendor/cm024_knowledge/ostler_knowledge/ingestion/adapters/__init__.py"

_rm_capability=absent
if [ -n "$(git ls-files -- "$CM024_ADAPTER")" ] \
   && [ -n "$(git ls-files -- "$CM024_REGISTRY")" ] \
   && grep -q '"reminders": RemindersAdapter' "$CM024_REGISTRY"; then
    _rm_capability=present
fi

if [ "$_rm_capability" = absent ]; then
    # No converter. We must not ask for access we cannot use.
    if grep -qE '^RECOMMENDED=.*reminders' "$INSTALL"; then
        fail "reminders is in RECOMMENDED but the CM024 converter is NOT vendored.
   Expected $CM024_ADAPTER to be a tracked file and the adapters registry to map
   the reminders source kind; one or both are missing, so
   'convert --source reminders' exits non-zero. Remove it from RECOMMENDED,
   or land the adapter."
    fi
    echo "consent check: converter absent, and reminders is correctly absent"
    echo "               from RECOMMENDED"
else
    # Capability present. The install path must actually drive it.
    grep -qE '^RECOMMENDED=.*reminders' "$INSTALL" \
        || fail "the CM024 reminders converter IS vendored and registered, but
   reminders is absent from RECOMMENDED. The capability exists and the
   onboarding presets do not offer it."
    grep -q -- '--source reminders' "$INSTALL" \
        || fail "converter vendored and source enabled, but install.sh never runs
   convert --source reminders. The sweep would extract JSON and stop."
    echo "capability check: CM024 converter vendored + registered, reminders"
    echo "                 enabled in RECOMMENDED, install.sh drives convert"
fi

echo "hydrate_reminders wiring guard: PASS"
