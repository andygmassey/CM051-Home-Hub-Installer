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

# ── Operator self/me-card exclusion (CM044 PR #92) ───────────
# The wiki compiler reads WIKI_OPERATOR_NAME + WIKI_OPERATOR_EMAILS to drop
# the operator's OWN person node from Featured Contact / Frequent
# Collaborator / Upcoming Birthdays. The compose env block must reference
# both (interpolated from the compose .env), or the exclusion is inert.
assert_contains "wiki-operator-name-env" \
    "WIKI_OPERATOR_NAME=\${WIKI_OPERATOR_NAME:-}"
echo "PASS: WIKI_OPERATOR_NAME passed to the wiki-compiler env"
assert_contains "wiki-operator-emails-env" \
    "WIKI_OPERATOR_EMAILS=\${WIKI_OPERATOR_EMAILS:-}"
echo "PASS: WIKI_OPERATOR_EMAILS passed to the wiki-compiler env"

# ── #259: the compiler must be told WHICH Ollama model to use ─────────
# CM044 compiler/config.py defaults OLLAMA_MODEL to qwen3.5:9b, which is NOT
# pulled on <=23GB Macs (the installer's RAM picker gives them gemma4:e2b).
# The compose env block must pin OLLAMA_MODEL to the installer-selected
# AI_MODEL, or every wiki narrative LLM call 404s and pages render empty.
assert_contains "wiki-ollama-model-env" \
    "OLLAMA_MODEL=\${AI_MODEL:-qwen3.5:9b}"
echo "PASS: OLLAMA_MODEL pinned to the installer-selected model on the wiki-compiler env"

# ── #259 (the load-bearing half): the compose env reference above is a QUOTED
#    heredoc literal, so docker compose interpolates ${AI_MODEL:-qwen3.5:9b}
#    from the compose .env at run time -- NOT from an unexported install.sh
#    shell var. Unless install.sh WRITES AI_MODEL to $OSTLER_ENV_FILE, the
#    reference resolves to the qwen3.5:9b fallback and #259 silently regresses
#    (empty narratives on gemma4 boxes). This assertion is what stops that. ──
if ! grep -qF "printf 'AI_MODEL=%s\\n' \"\${AI_MODEL:-qwen3.5:9b}\" >> \"\$OSTLER_ENV_FILE\"" "$INSTALL_SCRIPT"; then
    echo "FAIL [wiki-ai-model-envfile]: install.sh does not write AI_MODEL to the compose .env -- the OLLAMA_MODEL=\${AI_MODEL:-qwen3.5:9b} reference is INERT and #259 regresses to qwen3.5:9b" >&2
    exit 1
fi
echo "PASS: install.sh writes AI_MODEL (the RAM-tier pick) to the compose .env so the compose reference resolves"

# ── The two vars must be WRITTEN to the compose .env so docker compose
#    interpolates them at `compose run` time (same mechanism as
#    USER_FIRST_NAME -- the env block reference above is otherwise inert). ──
if ! grep -qF "printf 'WIKI_OPERATOR_NAME=%s\\n' \"\${USER_NAME:-}\" >> \"\$OSTLER_ENV_FILE\"" "$INSTALL_SCRIPT"; then
    echo "FAIL [wiki-operator-name-envfile]: install.sh does not write WIKI_OPERATOR_NAME (from USER_NAME) to the compose .env" >&2
    exit 1
fi
echo "PASS: install.sh writes WIKI_OPERATOR_NAME (from USER_NAME) to the compose .env"

if ! grep -qF "printf 'WIKI_OPERATOR_EMAILS=%s\\n' \"\${_wiki_operator_emails}\" >> \"\$OSTLER_ENV_FILE\"" "$INSTALL_SCRIPT"; then
    echo "FAIL [wiki-operator-emails-envfile]: install.sh does not write WIKI_OPERATOR_EMAILS to the compose .env" >&2
    exit 1
fi
echo "PASS: install.sh writes WIKI_OPERATOR_EMAILS (from USER_EMAIL me-card) to the compose .env"

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

# ── the dead curl|bash bootstrap must STAY dead ──────────────
#
# v1018-D682, closed. This check has been three different things, and the
# history is the useful part.
#
# It started as a REPO-NAME policy: DEFAULT_INSTALLER_TARBALL_URL must
# point at ostler-ai/ostler-installer (2026-05-08). CX-88 moved the URL to
# ostler-ai/ostler-releases on 2026-05-29 and the assertion went stale. The
# obvious repair -- flip the repo name to match main -- would have been
# wrong, because measurement showed BOTH sides were broken:
#
#   * ostler-releases had 30 releases and had NEVER published
#     install.tar.gz. Verified anonymously, with a positive control on the
#     same release, so the 404 was a real absence and not a blind probe.
#   * DEFAULT_INSTALLER_TARBALL_SHA256 hashed EXACTLY to ostler-installer
#     v0.3.0's tarball -- a different repo, and not even that repo's latest.
#   * So the two-key trust model install.sh advertised could never verify.
#     It failed closed, which is the safe direction, but the property was
#     fiction.
#
# Andy ruled on 2026-08-13: DELETE the bootstrap rather than publish a
# tarball to revive it. Reviving would resurrect an install shape the
# product already retired at the web edge (ostler.ai/install.sh serves a
# stub refusing curl|bash) AND create a second trust root to maintain
# forever. He also ruled that this test should point at the ABSENCE rather
# than be deleted with the code: a test that verified a dead path is worth
# more guarding that the path stays dead, so a future re-add is caught on
# the PR that adds it.
_dead_symbols=(
    DEFAULT_INSTALLER_TARBALL_URL
    DEFAULT_INSTALLER_TARBALL_SHA256
    OSTLER_BOOTSTRAP_SCRIPT_DIR
    BOOTSTRAP_TMPDIR
)
for _sym in "${_dead_symbols[@]}"; do
    # Executable references only. The comments explaining WHY the bootstrap
    # was deleted legitimately name these symbols, and reading a comment as
    # code is the exact mistake that produced separate false findings twice
    # in this sweep. Strip comment lines before deciding.
    if grep -h "$_sym" "$INSTALL_SCRIPT" \
         | sed 's/^[[:space:]]*//' \
         | grep -qvE '^#'; then
        echo "FAIL [tarball-url]: ${_sym} is back in EXECUTABLE code. The curl|bash bootstrap was deleted on 2026-08-13 (#682): its URL repo had never published install.tar.gz and its SHA pinned a different repo's artefact, so the trust model it advertised could never verify." >&2
        echo "  Offending lines:" >&2
        grep -n "$_sym" "$INSTALL_SCRIPT" >&2
        echo "  Reviving this needs a published tarball AND a second trust root. Talk to Andy first." >&2
        exit 1
    fi
done
echo "PASS: the dead curl|bash bootstrap has not come back (#682)"

# The refusal must stay LOUD. Deleting the bootstrap WITHOUT a hard failure
# would be worse than the dead path it replaced: a piped run would fall
# through with SCRIPT_DIR collapsed to $HOME, every ${SCRIPT_DIR}/<asset>
# lookup would silently miss, and the customer would get a half-built Hub
# with no error. That is the silent-bail shape this repo keeps finding.
if ! grep -q 'Ostler cannot be installed with curl | bash' "$INSTALL_SCRIPT"; then
    echo "FAIL [tarball-url]: install.sh no longer refuses curl|bash explicitly. Without the bootstrap AND without the refusal, a piped run installs nothing and says so nowhere." >&2
    exit 1
fi
echo "PASS: curl|bash is refused loudly rather than falling through"

echo ""
echo "All wiki-compose / hardening tests passed."
