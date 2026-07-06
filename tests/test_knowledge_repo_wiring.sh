#!/usr/bin/env bash
#
# tests/test_knowledge_repo_wiring.sh
#
# Locks the install + uninstall wiring for the Knowledge service
# (CM024 Evernote ingest) in install.sh. Block 3.2 of the launch-scope
# brief at HR015/launch/TNM_BRIEF_CM024_BLOCK_3_LAUNCH_SCOPE_2026-05-13.md.
#
# Mirrors test_doctor_repo_fallback.sh in shape: structural grep
# assertions over install.sh. A live install+uninstall pass against
# /tmp is covered by Block 3.5 (Mac Studio smoke), not in this unit
# test, because it requires sudo (for the /usr/local/bin symlink)
# and CM024 venv creation.

set -uo pipefail

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

# ── PWG_KNOWLEDGE_REPO documented in --help ─────────────────────
if ! grep -q '"  PWG_KNOWLEDGE_REPO"' "$INSTALL_SCRIPT"; then
    echo "FAIL [help-missing]: PWG_KNOWLEDGE_REPO is not listed in the --help env-var section" >&2
    exit 1
fi
echo "PASS: PWG_KNOWLEDGE_REPO documented in --help"

# ── KNOWLEDGE_REPO config var wired from PWG_KNOWLEDGE_REPO ─────
if ! grep -qE '^KNOWLEDGE_REPO="\$\{PWG_KNOWLEDGE_REPO:-\}"' "$INSTALL_SCRIPT"; then
    echo "FAIL [config-missing]: KNOWLEDGE_REPO=\${PWG_KNOWLEDGE_REPO:-} not present" >&2
    exit 1
fi
echo "PASS: KNOWLEDGE_REPO wired from PWG_KNOWLEDGE_REPO"

# ── Phase 3.13b header present ──────────────────────────────────
if ! grep -qE '^# ── 3\.13b Knowledge service \(CM024 Evernote ingest\)' "$INSTALL_SCRIPT"; then
    echo "FAIL [phase-header]: 3.13b Knowledge service section header missing" >&2
    exit 1
fi
echo "PASS: 3.13b section header present"

# ── Install location uses ~/.ostler/services/knowledge/ ─────────
if ! grep -qE 'KNOWLEDGE_DIR="\$\{OSTLER_DIR\}/services/knowledge"' "$INSTALL_SCRIPT"; then
    echo "FAIL [install-path]: install location not at ~/.ostler/services/knowledge/" >&2
    exit 1
fi
echo "PASS: install location is ~/.ostler/services/knowledge/"

# ── Source resolution: bundled-first, then repo, then warn-skip ─
# Assertion updated 2026-07-07. The original block was a plain
# `if [[ -z "$KNOWLEDGE_REPO" ]] warn-skip / else clone` fork. That
# was SUPERSEDED when the productised install gained a BUNDLED vendor
# copy (${SCRIPT_DIR}/cm024_knowledge/, landed by gui/project.yml
# postBuildScript) as the preferred no-network source, matching the
# hub-power / doctor / email-ingest pattern. Same safety property
# (no source at all still warn-skips, never a hard fail), new
# three-way structure locked here.
if ! grep -qE 'if \[\[ -d "\$\{SCRIPT_DIR\}/cm024_knowledge" && -f "\$\{SCRIPT_DIR\}/cm024_knowledge/pyproject.toml" \]\]; then' "$INSTALL_SCRIPT"; then
    echo "FAIL [bundled-branch]: no bundled-first \${SCRIPT_DIR}/cm024_knowledge branch (productised no-network source)" >&2
    exit 1
fi
if ! grep -qE 'elif \[\[ -n "\$KNOWLEDGE_REPO" \]\]; then' "$INSTALL_SCRIPT"; then
    echo "FAIL [repo-branch]: no 'elif [[ -n \"\$KNOWLEDGE_REPO\" ]]' clone fallback branch" >&2
    exit 1
fi
if ! grep -q 'MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE' "$INSTALL_SCRIPT"; then
    echo "FAIL [empty-branch]: no warn-and-skip surface when neither bundled source nor KNOWLEDGE_REPO is available" >&2
    exit 1
fi
echo "PASS: bundled-first source resolution (bundled -> repo clone -> warn-skip)"

# ── Clone uses --depth 1 + KNOWLEDGE_REPO ───────────────────────
if ! grep -qE 'git clone --quiet --depth 1 "\$KNOWLEDGE_REPO" "\$KNOWLEDGE_DIR"' "$INSTALL_SCRIPT"; then
    echo "FAIL [clone-cmd]: shallow clone of KNOWLEDGE_REPO not present" >&2
    exit 1
fi
echo "PASS: shallow clone of \$KNOWLEDGE_REPO to \$KNOWLEDGE_DIR"

# ── Venv created at .venv inside KNOWLEDGE_DIR ──────────────────
if ! grep -qE 'KNOWLEDGE_VENV="\$\{KNOWLEDGE_DIR\}/\.venv"' "$INSTALL_SCRIPT"; then
    echo "FAIL [venv-path]: venv path not at \$KNOWLEDGE_DIR/.venv" >&2
    exit 1
fi
# Assertion updated 2026-07-07: the venv is created with the resolved
# $PYTHON3_BIN (bundled python-build-standalone runtime, CX-19), not a
# bare `python3` that would hit the Apple CLT stub on a fresh Mac.
if ! grep -qE '"\$PYTHON3_BIN" -m venv "\$KNOWLEDGE_VENV"' "$INSTALL_SCRIPT"; then
    echo "FAIL [venv-create]: '\"\$PYTHON3_BIN\" -m venv \$KNOWLEDGE_VENV' missing (must use the resolved bundled python, CX-19)" >&2
    exit 1
fi
echo "PASS: venv created at \$KNOWLEDGE_DIR/.venv"

# ── pip install runs against KNOWLEDGE_DIR (uses pyproject.toml) ─
if ! grep -qE '"\$KNOWLEDGE_VENV/bin/pip" install --quiet "\$KNOWLEDGE_DIR"' "$INSTALL_SCRIPT"; then
    echo "FAIL [pip-install]: pip install of \$KNOWLEDGE_DIR missing" >&2
    exit 1
fi
echo "PASS: pip installs \$KNOWLEDGE_DIR into venv"

# ── /usr/local/bin/ostler-knowledge symlink via sudo ────────────
if ! grep -qE 'KNOWLEDGE_SYMLINK="/usr/local/bin/ostler-knowledge"' "$INSTALL_SCRIPT"; then
    echo "FAIL [symlink-target]: symlink target not /usr/local/bin/ostler-knowledge" >&2
    exit 1
fi
# Accept either branch of the OSTLER_GUI=1 fork: the GUI path runs
# `ln -sf` unprivileged (after AuthorizationHelper chowned the dir),
# the CLI path still runs `sudo ln -sf`. As long as one of them is
# present the symlink will get created.
if ! grep -qE '(sudo )?ln -sf "\$KNOWLEDGE_BIN" "\$KNOWLEDGE_SYMLINK"' "$INSTALL_SCRIPT"; then
    echo "FAIL [symlink-cmd]: 'ln -sf \$KNOWLEDGE_BIN \$KNOWLEDGE_SYMLINK' missing (sudo or non-sudo)" >&2
    exit 1
fi
echo "PASS: /usr/local/bin/ostler-knowledge symlink installed (GUI: no-sudo / CLI: sudo)"

# ── Health check via --version ──────────────────────────────────
if ! grep -qE '"\$KNOWLEDGE_SYMLINK" --version' "$INSTALL_SCRIPT"; then
    echo "FAIL [health-check]: post-install '\$KNOWLEDGE_SYMLINK --version' check missing" >&2
    exit 1
fi
echo "PASS: post-install health check via --version"

# ── Knowledge-staging dir created at install time ───────────────
if ! grep -qE 'KNOWLEDGE_STAGING_DIR="\$\{OSTLER_DIR\}/data/knowledge-staging"' "$INSTALL_SCRIPT"; then
    echo "FAIL [staging-path]: knowledge-staging dir not at ~/.ostler/data/knowledge-staging/" >&2
    exit 1
fi
echo "PASS: knowledge-staging dir at ~/.ostler/data/knowledge-staging/"

# ── Clone failure produces useful diagnostics ───────────────────
# Assertion updated 2026-07-07: the literal English hint moved into
# the i18n catalogue as MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE
# (Rule 0.9 string extraction). Behaviour unchanged.
if ! grep -q 'MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE' "$INSTALL_SCRIPT"; then
    echo "FAIL [diag-override]: clone failure does not reference MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE (override hint)" >&2
    exit 1
fi
KNOWLEDGE_STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
if [[ ! -f "$KNOWLEDGE_STRINGS_FILE" ]] \
   || ! grep -q '^MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE=.*PWG_KNOWLEDGE_REPO' "$KNOWLEDGE_STRINGS_FILE"; then
    echo "FAIL [diag-override-string]: en-GB catalogue does not carry the PWG_KNOWLEDGE_REPO override wording" >&2
    exit 1
fi
echo "PASS: clone failure surfaces PWG_KNOWLEDGE_REPO override hint (via i18n catalogue)"

# ── Uninstaller removes /usr/local/bin/ostler-knowledge ─────────
if ! grep -qE 'sudo rm -f /usr/local/bin/ostler-knowledge' "$INSTALL_SCRIPT"; then
    echo "FAIL [uninstall-symlink]: uninstaller does not 'sudo rm -f /usr/local/bin/ostler-knowledge'" >&2
    exit 1
fi
echo "PASS: uninstaller removes /usr/local/bin/ostler-knowledge symlink"

# ── Uninstaller preserves knowledge-staging via mktemp+mv ───────
# Pattern: mv $KNOWLEDGE_STAGING_DIR to temp bak before the find,
# then mv back after.
if ! grep -qE 'KNOWLEDGE_STAGING_BAK=""' "$INSTALL_SCRIPT"; then
    echo "FAIL [staging-preserve]: uninstaller does not snapshot KNOWLEDGE_STAGING_DIR" >&2
    exit 1
fi
if ! grep -qE 'mv "\$KNOWLEDGE_STAGING_DIR" "\$\{KNOWLEDGE_STAGING_BAK\}/staging"' "$INSTALL_SCRIPT"; then
    echo "FAIL [staging-mv]: uninstaller does not move staging to bak" >&2
    exit 1
fi
if ! grep -qE 'mv "\$\{KNOWLEDGE_STAGING_BAK\}/staging" "\$KNOWLEDGE_STAGING_DIR"' "$INSTALL_SCRIPT"; then
    echo "FAIL [staging-restore]: uninstaller does not restore staging from bak" >&2
    exit 1
fi
echo "PASS: uninstaller preserves \$KNOWLEDGE_STAGING_DIR across the rm -rf"

# ── Feature-flag-not-gated invariant ────────────────────────────
# The install path must NOT depend on the features.evernote_import
# flag in features.yaml. The flag only controls the Doctor UI
# surface. Find any features.yaml reference inside the 3.13b block;
# there should be none.
KNOWLEDGE_BLOCK_START="$(grep -n '^# ── 3\.13b Knowledge service' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
KNOWLEDGE_BLOCK_END="$(grep -n '^# ── 3\.14 Hub power' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
if [[ -n "$KNOWLEDGE_BLOCK_START" ]] && [[ -n "$KNOWLEDGE_BLOCK_END" ]]; then
    KNOWLEDGE_BLOCK_RANGE="${KNOWLEDGE_BLOCK_START},${KNOWLEDGE_BLOCK_END}"
    FLAG_HITS="$(sed -n "${KNOWLEDGE_BLOCK_RANGE}p" "$INSTALL_SCRIPT" | grep -c 'features\.yaml\|evernote_import' || true)"
    # The block has a "Feature flag note" doc-comment mentioning these
    # strings; that is documentation, not gating. Allow up to 2 doc
    # mentions (the note paragraph). Anything above that suggests the
    # install logic actually reads the flag, which violates the brief.
    if [[ "$FLAG_HITS" -gt 2 ]]; then
        echo "FAIL [flag-gated]: install path appears to depend on features.evernote_import (${FLAG_HITS} hits inside 3.13b block)" >&2
        exit 1
    fi
fi
echo "PASS: install path is NOT feature-flag-gated (always installs)"

echo ""
echo "ALL KNOWLEDGE_REPO WIRING TESTS PASSED"
