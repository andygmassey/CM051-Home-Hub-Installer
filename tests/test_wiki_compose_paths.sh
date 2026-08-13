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

# ── the bootstrap URL and the bootstrap SHA must describe the SAME repo ──
#
# v1018-D682. This used to assert a REPO NAME: the URL must point at
# ostler-ai/ostler-installer, per a 2026-05-08 policy. CX-88 moved it to
# ostler-ai/ostler-releases on 2026-05-29 (install.sh:1351-1355), so the
# assertion was stale. But flipping the repo name to match main would have
# been the wrong repair, because BOTH sides are wrong in different ways:
#
#   * ostler-releases has 30 releases and has NEVER carried install.tar.gz.
#     `latest` is hub-v0.4.55, assistant tarballs only. The URL 404s.
#   * DEFAULT_INSTALLER_TARBALL_SHA256 hashes EXACTLY to ostler-installer's
#     v0.3.0 install.tar.gz -- a different repo, and not even that repo's
#     most recent release.
#   * install.sh's own --help says both things: :597 names ostler-releases,
#     :609 says the SHA is pinned to the most recent ostler-installer release.
#
# So the invariant worth holding is not WHICH repo, which is a product
# decision, but that the URL and the digest agree about which artefact they
# describe. A URL and a SHA pointing at different repos makes the two-key
# trust model documented at install.sh:603-605 inoperative: verification can
# never succeed, and the failure surfaces as a 404 that the github.com
# preflight at :1392 will mis-attribute to the customer's network.
#
# This is RED today, deliberately, and it is the product that is wrong.
# Do not repair it by editing this test. See #682 for the two options.
# Extract with grep -o, NOT sed 's///': a sed substitution that does not match
# prints the input line UNCHANGED, so a non-GitHub URL would yield the whole
# assignment line -- non-empty, so an emptiness guard never fires, and the
# mismatch below would report that line as if it were a repo name. Caught by a
# control that replaced the URL with a CDN host. grep -o yields nothing when
# there is no match, which is the honest answer.
# `|| true` on every extraction: this file runs under `set -euo pipefail`, so a
# grep that matches nothing exits 1 and kills the script THERE -- before the
# diagnostic branches below can say what was missing. Without these the
# "not a github.com URL" and "not assigned at all" messages are unreachable
# code, and the run dies at exit 1 with no explanation: a could-not-run
# wearing the costume of a finding. Both were caught by controls that removed
# the thing the greps look for.
_url_line="$(grep -m1 '^DEFAULT_INSTALLER_TARBALL_URL=' "$INSTALL_SCRIPT" || true)"
_url_repo="$(printf '%s\n' "$_url_line" \
    | grep -oE 'github\.com/[^/]+/[^/]+' | head -1 | cut -d/ -f2- || true)"
_sha_repo="$(grep -m1 'Default: pinned to the most recent' "$INSTALL_SCRIPT" \
    | grep -oE 'most recent [A-Za-z0-9._-]+ release' \
    | sed -E 's#most recent (.*) release#\1#' || true)"

if [[ -z "$_url_line" ]]; then
    echo "FAIL [tarball-url]: DEFAULT_INSTALLER_TARBALL_URL is not assigned at all. The bootstrap mechanism moved; retarget this check rather than assuming the pin is consistent." >&2
    exit 1
fi
if [[ -z "$_url_repo" ]]; then
    echo "FAIL [tarball-url]: DEFAULT_INSTALLER_TARBALL_URL is not a github.com URL, so its artefact cannot be matched against the SHA pin's stated GitHub provenance." >&2
    echo "  URL line: ${_url_line}" >&2
    echo "  If the bootstrap deliberately moved off GitHub Releases, retarget this check and re-state where the digest comes from. See #682." >&2
    exit 1
fi
if [[ -z "$_sha_repo" ]]; then
    echo "FAIL [tarball-url]: could not read the SHA pin's stated provenance from --help. If that line was reworded, retarget this check." >&2
    exit 1
fi
# _url_repo is owner/name, _sha_repo is the bare repo name from the help text.
if [[ "${_url_repo##*/}" != "$_sha_repo" ]]; then
    echo "FAIL [tarball-url]: the bootstrap URL and the bootstrap SHA describe DIFFERENT repos." >&2
    echo "  URL repo (install.sh:1356): ${_url_repo}" >&2
    echo "  SHA repo (--help, :609):    ${_sha_repo}" >&2
    echo "  Measured: ostler-releases has never published install.tar.gz (0 of 30 releases)," >&2
    echo "  and the pinned digest hashes to ostler-installer v0.3.0. The download can never" >&2
    echo "  verify, so the two-key trust model at install.sh:603-605 does not operate." >&2
    echo "  This is #682. Fix the product, not this test." >&2
    exit 1
fi
echo "PASS: bootstrap URL repo and SHA-pin repo agree (${_sha_repo})"

echo ""
echo "All wiki-compose / hardening tests passed."
