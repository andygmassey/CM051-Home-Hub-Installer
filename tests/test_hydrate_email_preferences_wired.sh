#!/usr/bin/env bash
# hydrate_email_preferences wiring + skip-path guard (v1.0.3)
# ==========================================================
#
# The email-preferences payload (a pre-extracted ParsedPreference JSONL,
# CM021 email-intelligence output) is the operator's biggest single
# preference source. On a wipe/baseline reinstall it must regenerate
# from the source file, so it is wired as an install hydration sub-phase
# (hydrate_email_preferences) rather than a one-off manual load.
#
# This guard pins:
#   1. The vendored CM019 ingest CLI exposes the ingest-email command
#      (catches a stale re-vendor that drops it).
#   2. install.sh actually emits the hydrate_email_preferences progress
#      step AND invokes `ingest-email` (no ship-dark).
#   3. Ordering: the step runs AFTER graph_db_start (Qdrant/Oxigraph up)
#      and cm019_setup (the CM019 venv exists), and BEFORE wiki_compile.
#   4. The step id is registered in the GUI StepCatalog (sidebar parity;
#      the install-gui-contract test would otherwise go red).
#   5. The customer-facing MSG_* strings are defined and free of em/en
#      dashes (British copy convention for this phase).
#   6. NO hardcoded operator path in committed install.sh -- the source
#      file is resolved only from the two opt-in env vars.
#   7. The env-var resolution + skip logic behaves: explicit file wins,
#      archives-dir derives the known relative path, neither set yields
#      the clean customer skip, and an absent file does not error.
#      Exercised against a tiny synthetic fixture -- never the real file,
#      never a live ingest (no DB is touched here).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
STRINGS="install.sh.strings.en-GB.sh"
CATALOG="gui/OstlerInstaller/Steps/StepCatalog.swift"
VENDOR_CLI="vendor/cm019_preferences/services/ingest/src/cli.py"
FIXTURE="tests/fixtures/email_preferences_sample.jsonl"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Vendored CLI exposes ingest-email -------------------------------
[[ -f "$VENDOR_CLI" ]] || fail "vendored CM019 ingest CLI missing at $VENDOR_CLI (stale vendor)"
grep -q "'ingest-email'" "$VENDOR_CLI" \
    || fail "$VENDOR_CLI no longer registers the ingest-email command (stale vendor)"
echo "vendor check: ingest-email command present in vendored CM019 CLI"

# 2. install.sh emits the step + invokes ingest-email ----------------
grep -q 'progress "Loading your email preferences" "hydrate_email_preferences"' "$INSTALL" \
    || fail "$INSTALL does not emit the hydrate_email_preferences progress step"
grep -q "services.ingest.src.cli ingest-email" "$INSTALL" \
    || fail "$INSTALL never invokes services.ingest.src.cli ingest-email (ship-dark)"
echo "wiring check: install.sh emits hydrate_email_preferences and invokes ingest-email"

# 3. Ordering: after graph_db_start + cm019_setup, before wiki_compile
prefs_line="$(grep -n 'progress "Loading your email preferences" "hydrate_email_preferences"' "$INSTALL" | head -1 | cut -d: -f1)"
graphdb_line="$(grep -n 'progress "Starting your knowledge graph databases" "graph_db_start"' "$INSTALL" | head -1 | cut -d: -f1)"
cm019_line="$(grep -n 'progress "Setting up preference enrichment" "cm019_setup"' "$INSTALL" | head -1 | cut -d: -f1)"
wiki_line="$(grep -n '"wiki_compile"' "$INSTALL" | head -1 | cut -d: -f1)"
[[ -n "$prefs_line" && -n "$graphdb_line" && -n "$cm019_line" && -n "$wiki_line" ]] \
    || fail "could not locate one or more ordering anchors (prefs/graphdb/cm019/wiki)"
[[ "$prefs_line" -gt "$graphdb_line" ]] \
    || fail "hydrate_email_preferences (line $prefs_line) must run AFTER graph_db_start (line $graphdb_line) so Qdrant/Oxigraph are up"
[[ "$prefs_line" -gt "$cm019_line" ]] \
    || fail "hydrate_email_preferences (line $prefs_line) must run AFTER cm019_setup (line $cm019_line) so the CM019 venv exists"
[[ "$prefs_line" -lt "$wiki_line" ]] \
    || fail "hydrate_email_preferences (line $prefs_line) must run BEFORE wiki_compile (line $wiki_line)"
echo "ordering check: prefs($prefs_line) after graph_db_start($graphdb_line) + cm019_setup($cm019_line), before wiki_compile($wiki_line)"

# 4. StepCatalog registration ----------------------------------------
grep -q '"hydrate_email_preferences"' "$CATALOG" \
    || fail "hydrate_email_preferences not in StepCatalog.canonicalOrder (GUI sidebar drift)"
echo "catalog check: hydrate_email_preferences registered in StepCatalog.canonicalOrder"

# 5. MSG_* strings defined + no em/en dashes -------------------------
for key in \
    MSG_HYDRATE_EMAIL_PREFERENCES_STARTED \
    MSG_HYDRATE_EMAIL_PREFERENCES_DONE \
    MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE \
    MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT \
    MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING \
    MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES \
    MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT ; do
    grep -q "^${key}=" "$STRINGS" || fail "$STRINGS missing string $key"
done
# Em-dash U+2014, en-dash U+2013, figure-dash U+2012, horizontal-bar U+2015
# are all U+201x -> UTF-8 bytes E2 80 9{2,3,4,5}. Match those byte
# sequences under LC_ALL=C so the check is portable to BSD grep (macOS),
# which lacks -P.
if grep -nE "^MSG_HYDRATE_EMAIL_PREFERENCES" "$STRINGS" \
    | LC_ALL=C grep -qE $'\xe2\x80\x92|\xe2\x80\x93|\xe2\x80\x94|\xe2\x80\x95'; then
    fail "hydrate_email_preferences strings contain an em/en dash (use a plain hyphen)"
fi
echo "strings check: all hydrate_email_preferences strings defined and dash-clean"

# 6. No hardcoded operator path --------------------------------------
# The committed install.sh must resolve the source file only from the
# opt-in env vars, never a baked-in absolute path to anyone's machine.
if grep -nE "/Users/[A-Za-z0-9_]+/.*preferences_v4\.jsonl" "$INSTALL"; then
    fail "$INSTALL contains a hardcoded operator path to preferences_v4.jsonl"
fi
grep -q "OSTLER_EMAIL_PREFERENCES_FILE" "$INSTALL" \
    || fail "$INSTALL does not reference OSTLER_EMAIL_PREFERENCES_FILE"
grep -q "OSTLER_SOCIAL_ARCHIVES_DIR" "$INSTALL" \
    || fail "$INSTALL does not reference OSTLER_SOCIAL_ARCHIVES_DIR"
echo "security check: no hardcoded operator path; resolution is env-var driven"

# 7. Env-var resolution + skip behaviour -----------------------------
# Replica of the exact resolution block in install.sh. Kept in lock-step
# by inspection; exercising it here proves the precedence + skip logic
# without standing up Qdrant/Oxigraph or running a live ingest.
resolve_prefs_file() {
    # Mirrors install.sh hydrate_email_preferences resolution.
    local rel="email/preferences_v4.jsonl"
    local file=""
    if [[ -n "${OSTLER_EMAIL_PREFERENCES_FILE:-}" ]]; then
        file="${OSTLER_EMAIL_PREFERENCES_FILE}"
    elif [[ -n "${OSTLER_SOCIAL_ARCHIVES_DIR:-}" ]]; then
        file="${OSTLER_SOCIAL_ARCHIVES_DIR%/}/${rel}"
    fi
    printf '%s' "$file"
}

[[ -s "$FIXTURE" ]] || fail "synthetic fixture missing/empty at $FIXTURE"

# 7a. Neither env var set -> empty (the clean customer skip path).
( unset OSTLER_EMAIL_PREFERENCES_FILE OSTLER_SOCIAL_ARCHIVES_DIR
  got="$(resolve_prefs_file)"
  [[ -z "$got" ]] || { echo "FAIL: customer case (no env) should resolve empty, got '$got'" >&2; exit 1; } )
echo "resolution check: no env vars -> empty (customer skip path)"

# 7b. Explicit file path wins, even when the archives dir is also set.
( export OSTLER_EMAIL_PREFERENCES_FILE="$REPO_ROOT/$FIXTURE"
  export OSTLER_SOCIAL_ARCHIVES_DIR="/some/other/archives"
  got="$(resolve_prefs_file)"
  [[ "$got" == "$REPO_ROOT/$FIXTURE" ]] || { echo "FAIL: explicit file should win, got '$got'" >&2; exit 1; }
  [[ -s "$got" ]] || { echo "FAIL: resolved fixture should be a non-empty file" >&2; exit 1; } )
echo "resolution check: OSTLER_EMAIL_PREFERENCES_FILE takes precedence and points at a real file"

# 7c. Archives dir derives the known relative path; trailing slash safe.
( unset OSTLER_EMAIL_PREFERENCES_FILE
  tmp_archives="$(mktemp -d)"
  mkdir -p "$tmp_archives/email"
  cp "$REPO_ROOT/$FIXTURE" "$tmp_archives/email/preferences_v4.jsonl"
  export OSTLER_SOCIAL_ARCHIVES_DIR="$tmp_archives/"
  got="$(resolve_prefs_file)"
  [[ "$got" == "$tmp_archives/email/preferences_v4.jsonl" ]] \
      || { echo "FAIL: archives-dir derivation wrong, got '$got'" >&2; rm -rf "$tmp_archives"; exit 1; }
  [[ -s "$got" ]] || { echo "FAIL: derived archives path should be a real non-empty file" >&2; rm -rf "$tmp_archives"; exit 1; }
  rm -rf "$tmp_archives" )
echo "resolution check: OSTLER_SOCIAL_ARCHIVES_DIR derives email/preferences_v4.jsonl (trailing slash safe)"

# 7d. Archives dir set but file absent -> resolves a path that does NOT
#     exist, so the install.sh `[[ ! -s ]]` branch skips cleanly (no error).
( unset OSTLER_EMAIL_PREFERENCES_FILE
  empty_archives="$(mktemp -d)"
  export OSTLER_SOCIAL_ARCHIVES_DIR="$empty_archives"
  got="$(resolve_prefs_file)"
  [[ -n "$got" ]] || { echo "FAIL: archives-dir should still derive a path" >&2; rm -rf "$empty_archives"; exit 1; }
  [[ ! -s "$got" ]] || { echo "FAIL: file should be absent for the skip-path case" >&2; rm -rf "$empty_archives"; exit 1; }
  rm -rf "$empty_archives" )
echo "resolution check: archives dir set but file absent -> install.sh skips via [[ ! -s ]] (no error)"

echo "hydrate_email_preferences wiring guard: PASS"
