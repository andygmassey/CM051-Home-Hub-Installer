#!/usr/bin/env bash
# CM051 release.sh – produce dist/install.tar.gz from CM051 + HR015 sources.
#
# See RELEASE.md (in this directory) for the full source map and the
# happy-path commands. This script implements the bundling step, the
# forbidden-pattern verify, and a diff-against-previous-tag check.
#
# Usage:
#   ./release.sh --version vX.Y.Z [--hr015 PATH] [--verify] \
#                [--diff-against-tag PREV_TAG] [--dry-run] \
#                [--notes-skeleton]
#
# Flags:
#   --version V             Required. Release version tag, e.g. v0.2.0.
#   --hr015 PATH            Path to the HR015 repo (default: ../HR015\ -\ Gaming\ PC).
#   --verify                Run forbidden-pattern grep on staged tree before
#                           tarballing. Refuse to seal on any hit.
#   --diff-against-tag T    After staging, diff our tarball-input against the
#                           previous release tag's tarball. Surfaces accidental
#                           drops or unintended additions. Requires gh + network.
#   --dry-run               Stage only, do not tar. Print the staged tree.
#   --notes-skeleton        Generate dist/RELEASE_NOTES_<version>.md from the
#                           PR list since --diff-against-tag (or v0.1.0 if not
#                           given). Skeleton – you write the prose.
#
# Exit codes:
#   0  success
#   1  invalid args
#   2  forbidden pattern found in staged tree
#   3  source path missing
#   4  tarballing failed
#   5  diff-against-tag failed

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

CM051_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HR015_DIR="${CM051_DIR}/../HR015 - Gaming PC"
DIST_DIR="${CM051_DIR}/dist"
STAGE_DIR=""
VERSION=""
DO_VERIFY=0
DO_DRY_RUN=0
DO_NOTES_SKELETON=0
DIFF_AGAINST_TAG=""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}OK${NC}    $*"; }
warn() { echo -e "${YELLOW}WARN${NC}  $*" >&2; }
die()  { echo -e "${RED}FAIL${NC}  $*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Source map (KEEP IN LOCKSTEP WITH RELEASE.md)
# -----------------------------------------------------------------------------

# Files / dirs sourced from CM051 (this repo). Format: src_relpath
CM051_SOURCES=(
    "install.sh"
    "install.sh.strings.en-GB.sh"
    "lib"
    "scripts"
    "assistant-agent"
    "wiki-recompile"
)

# Files / dirs sourced from HR015. Format: src_relpath
HR015_SOURCES=(
    "ostler-import.sh"
    "ostler_security"
    "ostler_fda"
    "hub-power"
    "contact_syncer"
    "email-ingest"
    "doctor"
    "legal"
    "LICENSES"
    "THIRD_PARTY_NOTICES.md"
)

# Special: copy HR015/contact_syncer/requirements.txt -> install/requirements.txt
HR015_AGGREGATE_REQUIREMENTS_SRC="contact_syncer/requirements.txt"

# Forbidden patterns (extended grep regex). One match anywhere in the staged
# tree fails the build. See RELEASE.md for the policy.
FORBIDDEN_PATTERNS=(
    'lifeline'
    'LIFELINE_DIR'
    'IT Guy'
    'it-guy'
    'lifeline\.dev'
)

# Patterns we tolerate IF in specific files. Format: "pattern|filepath".
# File-path is relative to the staged tree. Each exemption is justified
# below – never add a new one without writing the why.
FORBIDDEN_EXEMPTIONS=(
    # Backwards-compat alias: existing installs use $LIFELINE_DIR; fallback
    # is read once at boot and resolved to OSTLER_DIR. Cannot remove until
    # we drop support for v0.1-era installs.
    'LIFELINE_DIR|hub-power/bin/hub-power-state.sh'
    # Migration-only: this script reads users' existing AAD-encrypted
    # blobs that have the literal byte-string "lifeline-recovery-key-v2:"
    # baked in. Removing the reference would break decryption.
    'lifeline|ostler_security/migrate_recovery_key_aad.py'
    # Historical name preservation in WebAuthn PRF derivation. Comments
    # explicitly mark this as do-not-touch – changing the salt would
    # invalidate every paired user's encryption key.
    'lifeline|ostler_security/webauthn_client.py'
    # Security model documentation: contrasts the rebrand explicitly
    # ("uses creativemachines/, not lifeline/"). Mentioning the old name
    # is the whole point of the doc.
    'lifeline|ostler_security/SECURITY_MODEL.md'
    # Customer-facing README example showing how to query the legacy
    # keychain service (for migration debugging).
    'lifeline|ostler_security/README.md'
    # Backwards-compat prefix list: tls_setup accepts ostler-/pwg-/lifeline-
    # cert filenames so users with v0.1-era installs keep working.
    'lifeline|ostler_security/tls_setup.py'
    # The rebrand-flip script itself. Its entire purpose is to migrate
    # constants from `lifeline`/`v2` to `ostler`/`v3`. Cannot remove the
    # word without removing the script.
    'lifeline|ostler_security/flip_constants.py'
    # Migration script for keychain service rename. Reads existing
    # entries under the old service name to copy them to the new one.
    'lifeline|ostler_security/migrate_keychain_service.py'
    # Deployment notes documenting the rebrand journey.
    'lifeline|ostler_security/DEPLOYMENT_NOTES.md'
)

# rsync exclude patterns. Test files, pytest caches, and Python build
# artefacts must NEVER reach a customer install – they bloat the bundle
# and ship internal naming (e.g. test docstrings referencing internal IP).
# v0.1.0 missed this.
RSYNC_EXCLUDES=(
    '__pycache__'
    '.pytest_cache'
    '.DS_Store'
    '.git*'
    'tests'
    '*.egg-info'
    'build'              # Python build output dir (e.g. ostler_security/build/)
    '.build'             # Swift Package Manager compile cache (ostler_security/bin/src/.build/)
                         # v0.2.0 dry-run shipped 259 .pcm / .swiftmodule files
                         # before this exclude landed (28M -> ~3M after).
    '*_AUDIT.md'         # internal audit docs (e.g. DAY_ZERO_AUDIT.md)
    'TECH_DEBT_*.md'
    'SESSION_HANDOFF_*.md'
    # Secrets – .env files are gitignored from git but rsync does not
    # honour .gitignore. The .env.example template is allowed (different
    # name); only the literal `.env` is excluded so a developer's real
    # credentials never reach a customer install. v0.2.0 dry-run caught
    # contact_syncer/.env containing a real CardDAV app-specific password
    # – without this exclude the customer tarball would have shipped it.
    '.env'
)

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)            VERSION="$2"; shift 2 ;;
        --hr015)              HR015_DIR="$2"; shift 2 ;;
        --verify)             DO_VERIFY=1; shift ;;
        --dry-run)            DO_DRY_RUN=1; shift ;;
        --diff-against-tag)   DIFF_AGAINST_TAG="$2"; shift 2 ;;
        --notes-skeleton)     DO_NOTES_SKELETON=1; shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)  die "unknown flag: $1" 1 ;;
    esac
done

[[ -z "${VERSION}" ]] && die "--version is required" 1
[[ -d "${HR015_DIR}" ]] || die "--hr015 path not found: ${HR015_DIR}" 3

# -----------------------------------------------------------------------------
# Stage
# -----------------------------------------------------------------------------

mkdir -p "${DIST_DIR}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm051-release-XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT

INSTALL_DIR="${STAGE_DIR}/install"
mkdir -p "${INSTALL_DIR}"

echo "==> Staging from CM051 (${CM051_DIR})"
for src in "${CM051_SOURCES[@]}"; do
    SRC="${CM051_DIR}/${src}"
    [[ -e "${SRC}" ]] || die "missing CM051 source: ${SRC}" 3
    echo "   + ${src}"
    EXCLUDE_FLAGS=()
    for pat in "${RSYNC_EXCLUDES[@]}"; do EXCLUDE_FLAGS+=(--exclude="${pat}"); done
    rsync -a "${EXCLUDE_FLAGS[@]}" "${SRC}" "${INSTALL_DIR}/"
done

echo "==> Staging from HR015 (${HR015_DIR})"
for src in "${HR015_SOURCES[@]}"; do
    SRC="${HR015_DIR}/${src}"
    [[ -e "${SRC}" ]] || die "missing HR015 source: ${SRC}" 3
    echo "   + ${src}"
    EXCLUDE_FLAGS=()
    for pat in "${RSYNC_EXCLUDES[@]}"; do EXCLUDE_FLAGS+=(--exclude="${pat}"); done
    rsync -a "${EXCLUDE_FLAGS[@]}" "${SRC}" "${INSTALL_DIR}/"
done

echo "==> Aggregating requirements.txt from HR015/${HR015_AGGREGATE_REQUIREMENTS_SRC}"
cp "${HR015_DIR}/${HR015_AGGREGATE_REQUIREMENTS_SRC}" "${INSTALL_DIR}/requirements.txt"

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

if [[ "${DO_VERIFY}" -eq 1 ]]; then
    # -------------------------------------------------------------------
    # Assistant-binary version-pin coherence check
    # -------------------------------------------------------------------
    # The bundled install.sh has a default OSTLER_ASSISTANT_VERSION pin
    # which dictates which ostler-assistant binary tarball customers
    # download. If that pin drifts from the release version, customers
    # silently get last-release's binary (caught 2026-05-08 right after
    # v0.2.0 cut: install.sh was still pinned to 0.1.0, so a fresh
    # `curl | bash` would have ignored the v0.2.0 signed binary and
    # fetched the v0.1.0 unsigned one). Fail the build before tarball.
    echo "==> Verifying assistant-version pin matches --version"
    EXPECTED_PIN="${VERSION#v}"
    BUNDLED_PIN="$(grep -m1 -E '^OSTLER_ASSISTANT_VERSION=' "${INSTALL_DIR}/install.sh" | sed -E 's/.*-([0-9]+\.[0-9]+\.[0-9]+)\}.*/\1/')"
    if [[ "${BUNDLED_PIN}" != "${EXPECTED_PIN}" ]]; then
        die "install.sh OSTLER_ASSISTANT_VERSION default is '${BUNDLED_PIN}' but --version is '${EXPECTED_PIN}'. Bump install.sh before cutting." 2
    fi
    ok "install.sh assistant-version pin matches --version (${EXPECTED_PIN})"

    echo "==> Verifying staged tree (forbidden-pattern grep)"
    HITS_FILE="$(mktemp)"
    PATTERN_RE="$(IFS='|'; echo "${FORBIDDEN_PATTERNS[*]}")"
    LC_ALL=C grep -RInE "${PATTERN_RE}" "${INSTALL_DIR}" 2>/dev/null > "${HITS_FILE}" || true

    # Filter out exempted matches
    REAL_HITS_FILE="$(mktemp)"
    cp "${HITS_FILE}" "${REAL_HITS_FILE}"
    for ex in "${FORBIDDEN_EXEMPTIONS[@]}"; do
        EX_PATTERN="${ex%|*}"
        EX_PATH="${ex#*|}"
        TMP="$(mktemp)"
        # Drop lines that match BOTH the exempted pattern AND the exempted path
        grep -v -E "^[^:]*${EX_PATH//\//\\/}.*${EX_PATTERN}" "${REAL_HITS_FILE}" > "${TMP}" || true
        mv "${TMP}" "${REAL_HITS_FILE}"
    done

    if [[ -s "${REAL_HITS_FILE}" ]]; then
        echo -e "${RED}FAIL${NC}  Forbidden patterns found in staged tree:"
        sed 's/^/      /' "${REAL_HITS_FILE}"
        die "Sweep at source before re-running. See feedback memories." 2
    fi
    ok "no forbidden patterns in staged tree"
    rm -f "${HITS_FILE}" "${REAL_HITS_FILE}"

    # -------------------------------------------------------------------
    # Credential / secret scan. Defence-in-depth: rsync should already
    # exclude .env, but if a developer's real credentials end up in some
    # other shipped file (a hardcoded API key in source, a stray dotfile
    # under a different name) we want the release to fail rather than
    # ship the secret to every customer download.
    #
    # Patterns are intentionally conservative – only signals strong
    # enough that a human reviewer would treat them as definite secrets.
    # If this ever produces false positives, fix at source (don't add
    # exemptions; that's how secrets ship).
    # -------------------------------------------------------------------
    echo "==> Verifying staged tree (credential / secret scan)"
    SECRET_HITS="$(mktemp)"
    # Apple app-specific password format: xxxx-xxxx-xxxx-xxxx (lowercase a-z).
    # Always flagged – these only get generated for a human's iCloud account.
    LC_ALL=C grep -RInE '\b[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}\b' "${INSTALL_DIR}" 2>/dev/null >> "${SECRET_HITS}" || true
    # Any literal .env file that snuck through the rsync exclude.
    find "${INSTALL_DIR}" -type f -name '.env' 2>/dev/null \
        | sed 's|^|env-file:|' >> "${SECRET_HITS}" || true
    # Common API-key prefixes (Anthropic, OpenAI, GitHub PATs).
    LC_ALL=C grep -RInE '\b(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b' "${INSTALL_DIR}" 2>/dev/null >> "${SECRET_HITS}" || true

    if [[ -s "${SECRET_HITS}" ]]; then
        echo -e "${RED}FAIL${NC}  Possible secrets found in staged tree:"
        sed 's/^/      /' "${SECRET_HITS}"
        die "Remove the secret at source – never ship customer-bound credentials." 2
    fi
    ok "no credential / secret signatures in staged tree"
    rm -f "${SECRET_HITS}"
fi

# -----------------------------------------------------------------------------
# Diff against previous tag
# -----------------------------------------------------------------------------

if [[ -n "${DIFF_AGAINST_TAG}" ]]; then
    echo "==> Diffing staged tree against ${DIFF_AGAINST_TAG} tarball"
    PREV_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm051-prev-XXXXXX")"
    pushd "${PREV_DIR}" > /dev/null
    if ! gh release download "${DIFF_AGAINST_TAG}" \
            --repo ostler-ai/ostler-installer \
            --pattern "install.tar.gz" 2>/dev/null; then
        popd > /dev/null
        rm -rf "${PREV_DIR}"
        die "could not download install.tar.gz from ${DIFF_AGAINST_TAG}" 5
    fi
    tar -xzf install.tar.gz
    popd > /dev/null

    echo "--- File-list diff (${DIFF_AGAINST_TAG} -> staged) ---"
    diff <(cd "${PREV_DIR}/install" && find . -type f | sort) \
         <(cd "${INSTALL_DIR}" && find . -type f | sort) \
         | head -50 || true
    rm -rf "${PREV_DIR}"
fi

# -----------------------------------------------------------------------------
# Dry-run
# -----------------------------------------------------------------------------

if [[ "${DO_DRY_RUN}" -eq 1 ]]; then
    echo "==> Dry-run: staged tree at ${INSTALL_DIR}"
    find "${INSTALL_DIR}" -type f | sed "s|${STAGE_DIR}/||" | sort | head -30
    echo "..."
    echo "$(find "${INSTALL_DIR}" -type f | wc -l) files total"
    exit 0
fi

# -----------------------------------------------------------------------------
# Tarball (single-pass, inner install.sh locked to sentinel)
#
# install.sh contains a DEFAULT_INSTALLER_TARBALL_SHA256 constant that pins
# the SHA-256 of the release tarball. Customers who run install.sh via
# curl|bash download the tarball and verify it against this constant before
# extracting -- the supply-chain guard. The constant ships in the standalone
# install.sh on GitHub (what curl fetches), so it must equal the SHA of the
# tarball being published.
#
# Build approach:
#
#   1. Force the staged install.sh's SHA pin to the sentinel value, so the
#      inner copy inside the tarball does not lie about which SHA the
#      tarball it lives in should have. If a power user extracts the
#      tarball and runs the inner install.sh standalone (curl-bash style
#      with BASH_SOURCE unset), the sentinel triggers the documented
#      "skip with WARNING" path rather than fail-closed against a stale
#      digest.
#
#   2. Tar once. The resulting tarball's SHA is the FINAL SHA.
#
#   3. Patch the repo-root install.sh's SHA pin to the FINAL SHA. The
#      repo-root install.sh is what customers fetch via curl|bash; its
#      pin is what the supply-chain guard verifies against on first run.
#
# The two-pass design that preceded this was equivalent in outcome to a
# single pass plus inner-sentinel: pass 1 + inject + pass 2 + revert +
# pass 3 produced a tarball byte-identical to pass 1 with no injection,
# because the staged tree ended at the same sentinel state. The
# simplification removes a redundant tar + sed cycle without changing
# what ships.
# -----------------------------------------------------------------------------

OUT="${DIST_DIR}/install.tar.gz"
SENTINEL_VALUE="REPLACE_AT_RELEASE_TIME"
OUTER_INSTALL_SH="${CM051_DIR}/install.sh"

# Verify the staged install.sh has the SHA-pin line. This catches the
# "bootstrap prelude missing entirely" failure mode regardless of what
# value the source repo currently pins.
if ! grep -qE '^DEFAULT_INSTALLER_TARBALL_SHA256="[^"]*"' "${INSTALL_DIR}/install.sh"; then
    die "DEFAULT_INSTALLER_TARBALL_SHA256= line not found in staged install.sh -- is the bootstrap prelude block present?" 4
fi

echo "==> Locking staged install.sh SHA pin to sentinel"
sed -i '' -E "s/^DEFAULT_INSTALLER_TARBALL_SHA256=\"[^\"]*\"/DEFAULT_INSTALLER_TARBALL_SHA256=\"${SENTINEL_VALUE}\"/" "${INSTALL_DIR}/install.sh"

if ! grep -q "DEFAULT_INSTALLER_TARBALL_SHA256=\"${SENTINEL_VALUE}\"" "${INSTALL_DIR}/install.sh"; then
    die "Failed to lock staged install.sh to sentinel -- sed rewrite did not take effect" 4
fi
ok "Staged install.sh locked to sentinel"

echo "==> Tarballing -> ${OUT}"
( cd "${STAGE_DIR}" && tar -czf "${OUT}" install/ ) || die "tar failed" 4

( cd "${DIST_DIR}" && shasum -a 256 install.tar.gz > install.tar.gz.sha256 )
FINAL_SHA="$(awk '{print $1}' "${DIST_DIR}/install.tar.gz.sha256")"

ok "Built ${OUT} ($(du -h "${OUT}" | cut -f1)) for ${VERSION}"
echo "   FINAL SHA: ${FINAL_SHA}"

# Patch the repo-root install.sh with FINAL_SHA. This is the outer script
# served to customers via curl|bash; the pin in it is what the supply-chain
# guard checks the downloaded tarball against. We sed regardless of the
# current value (sentinel, previous release SHA, or anything else) so the
# release is deterministic across multiple cuts from the same checkout.
echo "==> Patching repo-root install.sh with FINAL SHA"
if ! grep -qE '^DEFAULT_INSTALLER_TARBALL_SHA256="[^"]*"' "${OUTER_INSTALL_SH}"; then
    die "DEFAULT_INSTALLER_TARBALL_SHA256= line not found in ${OUTER_INSTALL_SH}" 4
fi
sed -i '' -E "s/^DEFAULT_INSTALLER_TARBALL_SHA256=\"[^\"]*\"/DEFAULT_INSTALLER_TARBALL_SHA256=\"${FINAL_SHA}\"/" "${OUTER_INSTALL_SH}"

if ! grep -q "DEFAULT_INSTALLER_TARBALL_SHA256=\"${FINAL_SHA}\"" "${OUTER_INSTALL_SH}"; then
    die "Repo-root install.sh patch verification failed -- sed rewrite did not take effect" 4
fi
ok "Repo-root install.sh patched with FINAL SHA"
echo ""
echo "Next: review the install.sh diff with 'git diff install.sh' (one line: the SHA pin),"
echo "stage with 'git add install.sh', and commit alongside the release artefacts."
echo "See RELEASE.md 'SHA injection' section for the full ceremony."

# -----------------------------------------------------------------------------
# Notes skeleton (optional)
# -----------------------------------------------------------------------------

if [[ "${DO_NOTES_SKELETON}" -eq 1 ]]; then
    NOTES="${DIST_DIR}/RELEASE_NOTES_${VERSION}.md"
    PREV="${DIFF_AGAINST_TAG:-v0.1.0}"
    echo "==> Generating notes skeleton -> ${NOTES} (PRs since ${PREV})"
    {
        echo "# ${VERSION}"
        echo ""
        echo "<!-- TODO: one-line summary -->"
        echo ""
        echo "## Changes since ${PREV}"
        echo ""
        ( cd "${CM051_DIR}" && git log --oneline "${PREV}..HEAD" 2>/dev/null \
            | sed 's/^/- /' ) || echo "- <git log unavailable>"
        echo ""
        echo "## Breaking changes"
        echo ""
        echo "<!-- TODO: env var renames, dep bumps, behaviour changes -->"
        echo ""
        echo "## Known issues"
        echo ""
        echo "<!-- TODO: -->"
    } > "${NOTES}"
    ok "${NOTES} (you write the prose)"
fi

echo ""
echo "Next: see RELEASE.md for the gh release create + assistant-binary steps."
