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
    "lib"
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

# Patterns we tolerate IF in specific files (backwards-compat aliases).
# Format: "pattern|filepath". File-path is relative to the staged tree.
FORBIDDEN_EXEMPTIONS=(
    'LIFELINE_DIR|hub-power/bin/hub-power-state.sh'
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
    rsync -a --exclude='__pycache__' --exclude='.DS_Store' --exclude='.git*' \
        "${SRC}" "${INSTALL_DIR}/"
done

echo "==> Staging from HR015 (${HR015_DIR})"
for src in "${HR015_SOURCES[@]}"; do
    SRC="${HR015_DIR}/${src}"
    [[ -e "${SRC}" ]] || die "missing HR015 source: ${SRC}" 3
    echo "   + ${src}"
    rsync -a --exclude='__pycache__' --exclude='.DS_Store' --exclude='.git*' \
        "${SRC}" "${INSTALL_DIR}/"
done

echo "==> Aggregating requirements.txt from HR015/${HR015_AGGREGATE_REQUIREMENTS_SRC}"
cp "${HR015_DIR}/${HR015_AGGREGATE_REQUIREMENTS_SRC}" "${INSTALL_DIR}/requirements.txt"

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

if [[ "${DO_VERIFY}" -eq 1 ]]; then
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
# Tarball
# -----------------------------------------------------------------------------

OUT="${DIST_DIR}/install.tar.gz"
echo "==> Tarballing -> ${OUT}"
( cd "${STAGE_DIR}" && tar -czf "${OUT}" install/ ) || die "tar failed" 4

# Checksum
( cd "${DIST_DIR}" && shasum -a 256 install.tar.gz > install.tar.gz.sha256 )

ok "Built ${OUT} ($(du -h "${OUT}" | cut -f1)) for ${VERSION}"
echo "   $(cat "${DIST_DIR}/install.tar.gz.sha256")"

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
