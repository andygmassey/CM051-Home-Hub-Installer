#!/usr/bin/env bash
#
# tests/test_wiki_compose_paths.sh
#
# Locks the wiki-site / wiki-compiler volume + env paths in the
# docker-compose heredoc inside install.sh. Two classes of bug
# this test catches:
#
# 1. Wiring drift: the install.sh heredoc maps in-container paths
#    that must agree with the GHCR-built CM044 images. Pre-Gap 3
#    these did NOT agree (wiki_docs:/app/output / wiki_docs:/app/site),
#    which would have shipped a broken wiki to every fresh customer.
#    Re-introducing that drift would silently break /:8044 and the
#    compile run; this test traps it.
#
# 2. Two-zone regression: the Obsidian vault target must bind-mount
#    the customer's user-facing zone (~/Documents/Ostler/Wiki/) and
#    the _images/ sibling so a single host directory backs both the
#    HTML site and the Obsidian view. A future heredoc edit that
#    drops either bind-mount would silently re-introduce the empty-
#    Obsidian-vault problem Gap 3 was written to fix.
#
# Pure shell + grep / awk. No docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

# Extract the docker-compose heredoc body (between <<'DCEOF' and DCEOF).
COMPOSE="$(mktemp)"
trap 'rm -f "$COMPOSE"' EXIT

awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL_SCRIPT" > "$COMPOSE"

if [[ ! -s "$COMPOSE" ]]; then
    echo "FAIL: docker-compose heredoc body is empty" >&2
    echo "      (heredoc markers in install.sh may have changed shape)" >&2
    exit 1
fi

assert_contains() {
    local label="$1"
    local needle="$2"
    if ! grep -qF -- "$needle" "$COMPOSE"; then
        echo "FAIL [$label]: heredoc missing expected line:" >&2
        echo "  $needle" >&2
        exit 1
    fi
}

assert_not_contains() {
    local label="$1"
    local needle="$2"
    if grep -qF -- "$needle" "$COMPOSE"; then
        echo "FAIL [$label]: heredoc contains forbidden line:" >&2
        echo "  $needle" >&2
        exit 1
    fi
}

# ── Wiring fix #5: wiki-site mounts wiki-docs at /docs/docs:ro ─
assert_contains "wiki-site-volume" \
    "- wiki-docs:/docs/docs:ro"
echo "PASS: wiki-site mounts wiki-docs at /docs/docs:ro"

# ── Wiring fix #5: wiki-compiler mounts wiki-docs at /wiki ────
assert_contains "wiki-compiler-volume" \
    "- wiki-docs:/wiki"
echo "PASS: wiki-compiler mounts wiki-docs at /wiki"

# ── Wiring fix #5: old wiring (wiki_docs:/app/...) is gone ───
# Use the leading "- " volume-list syntax so prose comments
# referencing the historical wiring (which we want to keep for
# context) don't trigger the forbidden-line check.
assert_not_contains "old-wiring-app-output" \
    "- wiki_docs:/app/output"
assert_not_contains "old-wiring-app-site" \
    "- wiki_docs:/app/site"
echo "PASS: old wiki_docs:/app/* mountpoints removed from volume list"

# ── Gap 3: Obsidian vault target uses OSTLER_WIKI_DIR ─────────
assert_contains "obsidian-vault-bind-mount" \
    "\${OSTLER_WIKI_DIR:-\${HOME}/Documents/Ostler/Wiki}:/wiki/obsidian"
echo "PASS: wiki-compiler bind-mounts the Obsidian vault to the user-facing zone"

# ── Gap 3: image bind-mount (read-only) into the compiler ────
assert_contains "compiler-images-mount" \
    "\${OSTLER_WIKI_DIR:-\${HOME}/Documents/Ostler/Wiki}/_images:/wiki/obsidian/_images:ro"
echo "PASS: wiki-compiler mounts _images/ read-only at the vault's _images/"

# ── Gap 3: image bind-mount (read-only) into the site ────────
assert_contains "site-images-mount" \
    "\${OSTLER_WIKI_DIR:-\${HOME}/Documents/Ostler/Wiki}/_images:/docs/docs/Knowledge/images:ro"
echo "PASS: wiki-site mounts _images/ read-only at /docs/docs/Knowledge/images"

# ── Gap 3: WIKI_OBSIDIAN_DIR env on the compiler ─────────────
assert_contains "wiki-obsidian-dir-env" \
    "WIKI_OBSIDIAN_DIR=/wiki/obsidian"
echo "PASS: WIKI_OBSIDIAN_DIR=/wiki/obsidian env is set"

# ── Gap 3: WIKI_OUTPUT_DIR env on the compiler ───────────────
assert_contains "wiki-output-dir-env" \
    "WIKI_OUTPUT_DIR=/wiki"
echo "PASS: WIKI_OUTPUT_DIR=/wiki env is set"

# ── Volume rename: wiki-docs (with hyphen) for CM044 parity ──
assert_contains "volume-decl-renamed" \
    "wiki-docs:"
assert_not_contains "old-volume-decl" \
    "  wiki_docs:"
echo "PASS: top-level volume declared as wiki-docs (CM044 parity)"

# ── Phase 3.16 creates the Wiki/_images host path before compile ──
if ! grep -qF 'mkdir -p "${USER_FACING_ROOT}/Wiki" "${USER_FACING_ROOT}/Wiki/_images"' "$INSTALL_SCRIPT"; then
    echo "FAIL [phase-3.16-mkdir]: install.sh does not pre-create Wiki/_images before the first compile" >&2
    exit 1
fi
echo "PASS: install.sh pre-creates Wiki/ and Wiki/_images before the first compile run"

# ── err() function defined (hardening #1) ────────────────────
if ! grep -qE '^err\(\)' "$INSTALL_SCRIPT"; then
    echo "FAIL [err-function]: install.sh does not define err() function" >&2
    exit 1
fi
echo "PASS: err() function defined alongside info / ok / warn"

# ── DEFAULT_INSTALLER_TARBALL_URL points at andygmassey mirror (hardening #4) ──
if grep -q "DEFAULT_INSTALLER_TARBALL_URL=\"https://github.com/ostler-ai/" "$INSTALL_SCRIPT"; then
    echo "FAIL [tarball-url]: DEFAULT_INSTALLER_TARBALL_URL still points at ostler-ai/ (org-blocked)" >&2
    exit 1
fi
if ! grep -q "DEFAULT_INSTALLER_TARBALL_URL=\"https://github.com/andygmassey/CM051-Home-Hub-Installer/" "$INSTALL_SCRIPT"; then
    echo "FAIL [tarball-url]: DEFAULT_INSTALLER_TARBALL_URL not pointing at the andygmassey mirror" >&2
    exit 1
fi
echo "PASS: DEFAULT_INSTALLER_TARBALL_URL points at the andygmassey mirror"

echo ""
echo "All wiki-compose / hardening tests passed."
