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

# ── Empty KNOWLEDGE_REPO branch warns and skips ─────────────────
# THIS DEMANDED AN EXPLICIT `if [[ -z "$KNOWLEDGE_REPO" ]]` BRANCH. The
# installer expresses the same behaviour as the terminal `else` of an if/elif
# chain (install.sh:17354 bundled / :17370 KNOWLEDGE_REPO / :17402 else), which
# is why the literal stopped matching. KNOWLEDGE_REPO is a DEV OVERRIDE; the
# customer path is the bundled copy, so `info` rather than `warn` is right.
# Assert the BEHAVIOUR: the empty path is ANNOUNCED to the customer.
if ! grep -qF 'MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE' "$INSTALL_SCRIPT"; then
    echo "FAIL [empty-branch]: no '[[ -z \"\$KNOWLEDGE_REPO\" ]]' warn-and-skip branch" >&2
    exit 1
fi
echo "PASS: empty KNOWLEDGE_REPO branch warns and skips"

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
# NOT a literal `python3`. install.sh:17411 uses "$PYTHON3_BIN" -m venv, the
# RESOLVED interpreter, which on a customer install is the BUNDLED
# python-build-standalone rather than the /usr/bin/python3 Apple stub.
# Demanding the literal would demand the very thing CX-19 exists to stop: on a
# fresh Mac with no Command Line Tools, `python3` fires a GUI dialog and the
# install dies mid-step.
if ! grep -qF '"$PYTHON3_BIN" -m venv "$KNOWLEDGE_VENV"' "$INSTALL_SCRIPT"; then
    echo "FAIL [venv-create]: install.sh does not create the knowledge venv with the RESOLVED interpreter ('\"\$PYTHON3_BIN\" -m venv \"\$KNOWLEDGE_VENV\"'). A literal python3 here is the /usr/bin/python3 Apple stub on a fresh Mac -- CX-19." >&2
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
# THE STRING MOVED TO THE LOCALE CATALOGUE (Rule 0.9). install.sh:17399 emits
# the KEY -- `info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE"` -- so a
# grep for the English words in install.sh can never match.
#
# Assert BOTH HALVES of the writer/reader contract. A key emitted with no
# catalogue entry prints an EMPTY LINE, and the literal form could not see that:
# it would fail identically whether the message was missing or merely moved.
_ovr_key='MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE'
if ! grep -qF "$_ovr_key" "$INSTALL_SCRIPT"; then
    echo "FAIL [diag-override]: clone failure does not mention PWG_KNOWLEDGE_REPO override" >&2
    exit 1
fi

_ovr_strings="${REPO_ROOT}/install.sh.strings.en-GB.sh"
if [[ ! -f "$_ovr_strings" ]]; then
    echo "FAIL [diag-catalogue]: cannot find install.sh.strings.en-GB.sh to verify $_ovr_key" >&2
    exit 1
fi
_ovr_line="$(grep -F "${_ovr_key}=" "$_ovr_strings" || true)"
if [[ -z "$_ovr_line" ]]; then
    echo "FAIL [diag-catalogue]: $_ovr_key is emitted by install.sh but has NO catalogue entry -- the clone-failure hint would print an empty line" >&2
    exit 1
fi
case "$_ovr_line" in
    *PWG_KNOWLEDGE_REPO*) : ;;
    *) echo "FAIL [diag-catalogue]: $_ovr_key no longer names PWG_KNOWLEDGE_REPO, so the hint does not tell the customer what to set" >&2
       exit 1 ;;
esac
echo "PASS: clone-failure hint is emitted AND its catalogue entry names PWG_KNOWLEDGE_REPO"
echo "PASS: clone failure surfaces PWG_KNOWLEDGE_REPO override hint"

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
