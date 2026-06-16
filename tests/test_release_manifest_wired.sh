#!/usr/bin/env bash
# Release-manifest wiring guard (WORKSTREAM C / C1)
# ================================================
#
# ~/.ostler/ostler-release.json is the single runtime-queryable record
# of "what version is actually deployed" -- the knowability whose
# absence cost a whole night on the .152 walk, and the anchor for
# pull-based customer updates. This guard fails if any link in the
# emit chain is lost in a future edit or a stale re-vendor:
#
#   1. The emitter lib (lib/release_manifest.sh) is present + intact.
#   2. install.sh sources it (with the bundled-first / ~/.ostler-second
#      search order) AND calls emit_release_manifest in Phase 4.
#   3. install.sh stages the lib into ~/.ostler/lib for re-run-as-update.
#   4. release.sh emits the build stamp into the staged tree.
#   5. The catalogue carries the two operator-facing strings.
#   6. Functional: emit_release_manifest writes a VALID JSON manifest,
#      scrapes the wiki image SHAs out of a docker-compose.yml, and
#      reads the build stamp when present (proves the contract end to
#      end, independent of a live install).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
LIB="lib/release_manifest.sh"
RELEASE="release.sh"
STRINGS="install.sh.strings.en-GB.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1. lib present + defines the entry point
[[ -f "$LIB" ]] || fail "$LIB missing"
grep -q 'emit_release_manifest()' "$LIB" || fail "emit_release_manifest not defined in $LIB"
grep -q 'OSTLER_MANIFEST_SCHEMA_VERSION=' "$LIB" || fail "schema version not set in $LIB"
bash -n "$LIB" || fail "$LIB has a syntax error"
pass "emitter lib present + intact"

# 2. install.sh sources it + calls it
grep -q 'lib/release_manifest.sh' "$INSTALL" || fail "install.sh does not reference lib/release_manifest.sh"
grep -q 'emit_release_manifest' "$INSTALL" || fail "install.sh never calls emit_release_manifest"
# the call must live in Phase 4 (after the docker-compose.yml with image
# pins exists). Cheap proxy: the call appears after the health_check step.
CALL_LINE="$(grep -n 'if emit_release_manifest;' "$INSTALL" | head -n1 | cut -d: -f1)"
HEALTH_LINE="$(grep -n 'progress.*health_check\|step.*health_check\|RUNNING_HEALTH_CHECK' "$INSTALL" | head -n1 | cut -d: -f1)"
[[ -n "$CALL_LINE" ]] || fail "emit_release_manifest call site not found"
[[ -n "$HEALTH_LINE" && "$CALL_LINE" -gt "$HEALTH_LINE" ]] || fail "emit call ($CALL_LINE) is not in Phase 4 (after health check $HEALTH_LINE)"
pass "install.sh sources + calls the emitter in Phase 4"

# 3. install.sh stages the lib into ~/.ostler/lib
grep -q 'release_manifest.sh" "${HOME}/.ostler/lib/release_manifest.sh"' "$INSTALL" \
    || fail "install.sh does not stage release_manifest.sh into ~/.ostler/lib"
pass "lib staged into ~/.ostler/lib for re-run-as-update"

# 4. release.sh emits the build stamp
grep -q 'ostler-release.build.json' "$RELEASE" || fail "release.sh does not emit the build stamp"
pass "release.sh emits the build stamp"

# 5. catalogue strings
grep -q 'MSG_OK_RELEASE_MANIFEST_WRITTEN=' "$STRINGS" || fail "MSG_OK_RELEASE_MANIFEST_WRITTEN missing"
grep -q 'MSG_INFO_RELEASE_MANIFEST_DEFERRED=' "$STRINGS" || fail "MSG_INFO_RELEASE_MANIFEST_DEFERRED missing"
pass "operator strings present in catalogue"

# 6. functional: emit a real manifest from a build stamp + compose file
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OSTLER_DIR="$TMP/.ostler"
export SCRIPT_DIR="$TMP/script"
mkdir -p "$OSTLER_DIR" "$SCRIPT_DIR"
cat > "$OSTLER_DIR/docker-compose.yml" <<'YML'
services:
  wiki-site:
    image: ghcr.io/ostler-ai/ostler-wiki-site@sha256:b7cf8ba6cc8365482206283110bc3f1b337c0c243b556b0fb0ccd9952f34f7ea
  wiki-compiler:
    image: ghcr.io/ostler-ai/ostler-wiki-compiler@sha256:cb8498e023de7b2e3a28d790ed18dc3bf12313a6fb45e85ab55ce4210fa8969b
YML
cat > "$SCRIPT_DIR/ostler-release.build.json" <<'JSON'
{
  "manifest_schema_version": "1",
  "ostler_version": "v1.0.1",
  "installer_version": "v1.0.1",
  "built_at": "2026-06-16T09:00:00Z",
  "daemon_tag": "hub-v0.4.12",
  "source_repos": { "cm051": "abc123def456" }
}
JSON
export OSTLER_ASSISTANT_VERSION="0.4.12"
# shellcheck source=lib/release_manifest.sh
source "$LIB"
emit_release_manifest
OUT="$OSTLER_DIR/ostler-release.json"
[[ -f "$OUT" ]] || fail "emit_release_manifest did not write $OUT"
python3 -m json.tool "$OUT" >/dev/null 2>&1 || fail "emitted manifest is not valid JSON"
grep -q '"ostler_version": "v1.0.1"' "$OUT" || fail "build-stamp ostler_version not carried through"
grep -q 'sha256:b7cf8ba6' "$OUT" || fail "wiki-site image SHA not scraped"
grep -q 'sha256:cb8498e0' "$OUT" || fail "wiki-compiler image SHA not scraped"
grep -q '"version": "0.4.12"' "$OUT" || fail "daemon version not recorded"
grep -q '"installed_at"' "$OUT" || fail "installed_at not recorded"
pass "functional emit: valid JSON, build stamp + scraped SHAs + daemon version"

# 6b. dev fallback: no build stamp, no compose -> still a valid manifest
TMP2="$(mktemp -d)"
OSTLER_DIR="$TMP2/.ostler" SCRIPT_DIR="$TMP2/empty"
mkdir -p "$OSTLER_DIR" "$SCRIPT_DIR"
export OSTLER_DIR SCRIPT_DIR
unset OSTLER_ASSISTANT_VERSION
emit_release_manifest
python3 -m json.tool "$OSTLER_DIR/ostler-release.json" >/dev/null 2>&1 \
    || fail "dev-fallback manifest is not valid JSON"
grep -q '"ostler_version": "dev"' "$OSTLER_DIR/ostler-release.json" \
    || fail "dev fallback should default ostler_version to dev"
rm -rf "$TMP2"
pass "dev fallback emits a valid manifest"

echo "ALL PASS: release manifest wiring"
