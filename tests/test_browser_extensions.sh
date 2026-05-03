#!/usr/bin/env bash
#
# tests/test_browser_extensions.sh
#
# Locks the browser-extensions wiring in Phase 3.17 of install.sh.
#
# Why this test exists:
#
#   The marketing pages on ostler.ai claim browsing-context capture
#   for both Safari and Chrome -- "every page you visit". Pre-PR
#   install.sh did not actually install or sideload either extension.
#   The customer hit the next-steps banner at the end of a
#   successful install with no extensions, no instructions, and a
#   broken claim. Andy's "two credibility gaps in two pages, no
#   third" rule says Safari ships at v0.1 alongside Chrome.
#
#   This test pins the wiring so a future edit cannot quietly
#   regress either browser:
#     1. PWG_SAFARI_EXT_VERSION / _URL / _REPO documented in --help.
#     2. SAFARI_EXT_RELEASE_URL config var resolves the env vars
#        through to a default GitHub Releases URL on CM020.
#     3. Phase 3.17 prompts the user (Y/n, defaulting Y).
#     4. Chrome path: copies bundled unpacked source to
#        ~/.ostler/extensions/chrome/.
#     5. Safari path: downloads the notarised .app from the
#        release URL, extracts to /Applications, drops the
#        quarantine xattr.
#     6. Posture marker at ~/.ostler/posture/extensions.json
#        records what landed (offered / chrome_bundled /
#        safari_installed / paths).
#     7. Next-steps banner has both browsers' sideload steps,
#        gated on per-browser installation success.
#     8. The bundled Chrome source ships in extensions/chrome/
#        with a real manifest.json (so the bundled-or-skip probe
#        actually finds something).
#
# Sister tests:
#   - test_total_steps_dynamic.sh -- progress bar contract
#   - test_doctor_repo_fallback.sh -- DOCTOR_REPO clone fallback
#   - test_assistant_config_vane_wiring.sh -- Vane TOML wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── --help documents the env vars ───────────────────────────────
if ! grep -q '"  PWG_SAFARI_EXT_VERSION ' "$INSTALL_SCRIPT"; then
    echo "FAIL [help-missing]: PWG_SAFARI_EXT_VERSION is not documented in --help" >&2
    exit 1
fi
echo "PASS: PWG_SAFARI_EXT_* documented in --help"

# ── Config block wires the env vars ─────────────────────────────
if ! grep -qE '^SAFARI_EXT_VERSION="\$\{PWG_SAFARI_EXT_VERSION:-' "$INSTALL_SCRIPT"; then
    echo "FAIL [config-version]: SAFARI_EXT_VERSION not wired from PWG_SAFARI_EXT_VERSION" >&2
    exit 1
fi
if ! grep -qE '^SAFARI_EXT_REPO="\$\{PWG_SAFARI_EXT_REPO:-' "$INSTALL_SCRIPT"; then
    echo "FAIL [config-repo]: SAFARI_EXT_REPO not wired from PWG_SAFARI_EXT_REPO" >&2
    exit 1
fi
if ! grep -qE 'SAFARI_EXT_RELEASE_URL=.*PWG_SAFARI_EXT_URL' "$INSTALL_SCRIPT"; then
    echo "FAIL [config-url]: SAFARI_EXT_RELEASE_URL not wired from PWG_SAFARI_EXT_URL" >&2
    exit 1
fi
echo "PASS: config block wires PWG_SAFARI_EXT_VERSION / _REPO / _URL"

# ── Phase 3.17 prompt mentions both browsers ────────────────────
if ! grep -qE 'Install the Safari \+ Chrome browser-history extensions\? \(Y/n\)' "$INSTALL_SCRIPT"; then
    echo "FAIL [prompt-text]: Phase 3.17 prompt does not say 'Safari + Chrome' (Y/n default Y)" >&2
    exit 1
fi
echo "PASS: Phase 3.17 prompt mentions Safari + Chrome (Y default)"

# ── Chrome path: bundled source copied ──────────────────────────
if ! grep -q 'cp -R "\${SCRIPT_DIR}/extensions/chrome/"\* "\$CHROME_EXT_DIR/"' "$INSTALL_SCRIPT"; then
    echo "FAIL [chrome-copy]: Chrome bundled source not copied to CHROME_EXT_DIR" >&2
    exit 1
fi
echo "PASS: Chrome source copied from bundled extensions/chrome/"

# ── Safari path: download + extract + xattr drop ────────────────
if ! grep -q 'curl -fSL --retry 2' "$INSTALL_SCRIPT"; then
    echo "FAIL [safari-curl]: 'curl -fSL --retry 2' not present" >&2
    exit 1
fi
if ! grep -q '"\$SAFARI_EXT_RELEASE_URL"' "$INSTALL_SCRIPT"; then
    echo "FAIL [safari-curl-url]: Safari download does not reference SAFARI_EXT_RELEASE_URL" >&2
    exit 1
fi
echo "PASS: Safari .app downloaded via curl -fSL --retry from SAFARI_EXT_RELEASE_URL"

if ! grep -q 'ditto -x -k.*SAFARI_TMPDIR' "$INSTALL_SCRIPT"; then
    echo "FAIL [safari-extract]: ditto extraction step missing" >&2
    exit 1
fi
echo "PASS: Safari .zip extracted via ditto"

if ! grep -q 'mv "\${SAFARI_TMPDIR}/SafariHistoryExt.app" "\$SAFARI_APP_PATH"' "$INSTALL_SCRIPT"; then
    echo "FAIL [safari-mv]: Safari .app not moved into /Applications path" >&2
    exit 1
fi
echo "PASS: Safari .app moved into /Applications/SafariHistoryExt.app"

if ! grep -q 'xattr -d com.apple.quarantine "\$SAFARI_APP_PATH"' "$INSTALL_SCRIPT"; then
    echo "FAIL [safari-xattr]: quarantine xattr not dropped on Safari .app" >&2
    exit 1
fi
echo "PASS: quarantine xattr dropped on Safari .app post-install"

# ── Download failure is warn-only (does not abort) ──────────────
# Search for the curl failure branch and ensure it uses `warn` /
# `info` not `fail`. Browser extensions are opt-in; a
# release-not-yet-tagged race must not fail the install.
if grep -B1 -A8 'Could not download Safari extension' "$INSTALL_SCRIPT" | grep -q '^    fail '; then
    echo "FAIL [safari-fatal]: Safari download failure path uses fail; must be warn-only" >&2
    exit 1
fi
echo "PASS: Safari download failure is warn-only (install completes)"

# ── Posture marker JSON shape ───────────────────────────────────
for key in offered chrome_bundled safari_installed safari_release_url recorded_at; do
    if ! grep -q "\"$key\":" "$INSTALL_SCRIPT"; then
        echo "FAIL [posture-key]: posture marker JSON missing \"$key\" field" >&2
        exit 1
    fi
done
echo "PASS: posture marker has offered / chrome_bundled / safari_installed / safari_release_url / recorded_at"

if ! grep -q 'chmod 600 "\${OSTLER_DIR}/posture/extensions.json"' "$INSTALL_SCRIPT"; then
    echo "FAIL [posture-perms]: posture marker not chmod 600" >&2
    exit 1
fi
echo "PASS: posture marker is chmod 600"

# ── Next-steps banner: both browsers' instructions ──────────────
if ! grep -q 'Enable the Safari browser-history extension' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-safari]: next-steps banner missing 'Enable the Safari browser-history extension'" >&2
    exit 1
fi
echo "PASS: next-steps banner has Safari enable instructions"

if ! grep -q 'Sideload the Chrome browser-history extension' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-chrome]: next-steps banner missing 'Sideload the Chrome browser-history extension'" >&2
    exit 1
fi
echo "PASS: next-steps banner has Chrome sideload instructions"

if ! grep -q 'chrome://extensions' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-chrome-url]: Chrome instructions don't reference chrome://extensions" >&2
    exit 1
fi
echo "PASS: Chrome instructions reference chrome://extensions"

if ! grep -q 'Safari Settings > Extensions tab' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-safari-path]: Safari instructions don't walk through Settings > Extensions" >&2
    exit 1
fi
echo "PASS: Safari instructions walk through Settings > Extensions"

# ── Bundled Chrome source ───────────────────────────────────────
CHROME_BUNDLE_DIR="${REPO_ROOT}/extensions/chrome"
if [[ ! -d "$CHROME_BUNDLE_DIR" ]]; then
    echo "FAIL [bundle-chrome-dir]: extensions/chrome/ not bundled in repo" >&2
    exit 1
fi
if [[ ! -f "$CHROME_BUNDLE_DIR/manifest.json" ]]; then
    echo "FAIL [bundle-chrome-manifest]: extensions/chrome/manifest.json not bundled" >&2
    exit 1
fi
if ! grep -q '"manifest_version": 3' "$CHROME_BUNDLE_DIR/manifest.json"; then
    echo "FAIL [bundle-chrome-mv]: extensions/chrome/manifest.json is not MV3" >&2
    exit 1
fi
echo "PASS: extensions/chrome/ bundled with MV3 manifest.json"

# ── Bundled Safari placeholder ──────────────────────────────────
SAFARI_BUNDLE_DIR="${REPO_ROOT}/extensions/safari"
if [[ ! -d "$SAFARI_BUNDLE_DIR" ]]; then
    echo "FAIL [bundle-safari-dir]: extensions/safari/ not bundled in repo" >&2
    exit 1
fi
if [[ ! -f "$SAFARI_BUNDLE_DIR/README.md" ]]; then
    echo "FAIL [bundle-safari-readme]: extensions/safari/README.md placeholder not bundled" >&2
    exit 1
fi
echo "PASS: extensions/safari/README.md placeholder bundled"

echo ""
echo "ALL BROWSER EXTENSIONS TESTS PASSED"
