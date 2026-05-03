#!/usr/bin/env bash
# Ostler – Beta Installer
# Usage: curl -fsSL https://ostler.ai/install.sh | bash
#
# Structure:
#   Phase 1: Check prerequisites (automatic, no input)
#   Phase 2: Collect ALL user input upfront (~2 minutes)
#   Phase 3: Install everything unattended (~10-15 minutes)
#   Phase 4: Health check + next steps
#
# What this does NOT do:
#   - Send your personal data anywhere. Public-data queries (Wikidata
#     enrichment, local web search via the bundled Vane + SearXNG
#     container) and model/software downloads are described in the
#     privacy policy.
#   - Install anything without telling you first.
#   - Touch your existing Docker containers or Homebrew packages.

set -euo pipefail

# ── Flags ──────────────────────────────────────────────────────────

CHECK_ONLY=false
SHOW_HELP=false
SHOW_LICENSES=false
ALLOW_PLAINTEXT=0

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        --help|-h) SHOW_HELP=true ;;
        --licenses|--licences) SHOW_LICENSES=true ;;
        --allow-plaintext) ALLOW_PLAINTEXT=1 ;;
    esac
done

# ── stdin check ────────────────────────────────────────────────────
# When piped via `curl | bash`, stdin is the script not the terminal.
# We need terminal input for passphrase etc, so redirect from /dev/tty.
# Skip for read-only flags so they work in non-interactive contexts.
if [[ "$SHOW_HELP" != true && "$SHOW_LICENSES" != true && ! -t 0 ]]; then
    exec < /dev/tty
fi

# Print third-party attribution and exit. Reads from the post-install
# location at ~/.ostler/THIRD_PARTY_NOTICES.md if present (covering the
# "after install" case), otherwise falls back to bundled / cloned
# sources, otherwise points the user at the website. Available to every
# user with a working install.
if [[ "$SHOW_LICENSES" == true ]]; then
    if [[ -f "${HOME}/.ostler/THIRD_PARTY_NOTICES.md" ]]; then
        cat "${HOME}/.ostler/THIRD_PARTY_NOTICES.md"
        if [[ -d "${HOME}/.ostler/LICENSES" ]]; then
            echo ""
            echo "================================================================"
            echo "Full licence text for each SPDX identifier above:"
            echo "  ${HOME}/.ostler/LICENSES/"
            echo "================================================================"
            ls "${HOME}/.ostler/LICENSES/" 2>/dev/null | sed 's/^/  /'
        fi
    elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/THIRD_PARTY_NOTICES.md" ]]; then
        cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/THIRD_PARTY_NOTICES.md"
    else
        echo "Ostler third-party acknowledgements"
        echo ""
        echo "The full attribution catalogue lives in your Hub install at:"
        echo "  ~/.ostler/THIRD_PARTY_NOTICES.md"
        echo "Full licence texts at:"
        echo "  ~/.ostler/LICENSES/"
        echo ""
        echo "Install Ostler first (see --help), or read the public version at:"
        echo "  https://ostler.ai/licenses.html"
        echo ""
        echo "If you spot a missing or incorrect entry, email legal@ostler.ai."
    fi
    exit 0
fi

if [[ "$SHOW_HELP" == true ]]; then
    echo "Ostler Installer"
    echo ""
    echo "Usage: curl -fsSL ostler.ai/install.sh | bash"
    echo "       bash install.sh [--check] [--help]"
    echo ""
    echo "Options:"
    echo "  --check             Check prerequisites without installing anything"
    echo "  --help              Show this help message"
    echo "  --licenses          Print third-party open-source attributions and exit"
    echo "  --allow-plaintext   Dev/CI only. Permit install to complete without"
    echo "                      database encryption. NOT FOR PRODUCTION USE."
    echo "                      Writes a posture marker at"
    echo "                      ~/.ostler/security-posture/install.json."
    echo ""
    echo "What this does:"
    echo "  1. Checks prerequisites (macOS, Apple Silicon, RAM, disk)"
    echo "  2. Asks you a few questions (~2 minutes)"
    echo "  3. Installs everything automatically (~10-15 minutes)"
    echo "  4. You walk away and come back to a working system"
    echo ""
    echo "Environment variables (advanced - override before running):"
    echo ""
    echo "  OSTLER_INSTALLER_TARBALL_URL"
    echo "    Where install.sh fetches the installer tarball when invoked"
    echo "    via curl|bash. The single install.sh script does not contain"
    echo "    the bundled assets it needs to install (ostler_security,"
    echo "    ostler_fda, contact_syncer, hub-power, doctor, third-party"
    echo "    notices); under curl|bash we download the tarball, extract"
    echo "    it, and re-exec from inside."
    echo "    Default: https://github.com/ostler-ai/ostler-installer/releases/latest/download/install.tar.gz"
    echo ""
    echo "  PWG_PIPELINE_REPO"
    echo "    Source repo for the import pipeline (CM041 People Graph)."
    echo "    Default: empty (productised tarball bundles the pipeline)."
    echo "    Set this env var to a clone URL if you are running install.sh"
    echo "    directly without a tarball (e.g. dev or private beta access)."
    echo ""
    echo "  PWG_HUB_POWER_REPO"
    echo "    Source repo for the hub-power LaunchAgent scripts (HR015)."
    echo "    Default: empty (productised tarball bundles the scripts)."
    echo "    Mac Mini / Studio deployments do not need this. MacBook hubs"
    echo "    may set it to a clone URL for sleep / battery handling."
    echo ""
    echo "  PWG_NOTICES_BASE_URL"
    echo "    Base URL for raw-fetching THIRD_PARTY_NOTICES.md and the"
    echo "    LICENSES/ tree when neither the tarball nor the hub-power"
    echo "    clone provides them. Default: empty (warn-only). Example:"
    echo "    https://raw.githubusercontent.com/<org>/<repo>/main"
    echo ""
    echo "  WIKI_OBSIDIAN_DIR"
    echo "    Enable Obsidian vault output for the wiki compiler. Empty"
    echo "    means disabled."
    echo "    Default: (unset)"
    echo ""
    echo "  OLLAMA_HEADLINE_MODEL"
    echo "    Model used for short fact headlines in the wiki compiler"
    echo "    (CM044). Larger narrative summaries use a separate model."
    echo "    Default: qwen3:8b"
    echo ""
    echo "  POWER_POLICY"
    echo "    Hub power policy on MacBooks: normal | aggressive | eco."
    echo "    Read from ~/.ostler/power.conf at runtime, not at install"
    echo "    time. Edit that file post-install to change."
    echo ""
    echo "Your personal data stays on your machine. Ostler makes only narrow"
    echo "public-data queries (Wikidata for enrichment, local web search via"
    echo "the bundled Vane + SearXNG container at http://localhost:3000) and"
    echo "downloads model and software updates. See the privacy policy at"
    echo "creativemachines.ai/ostler/legal-privacy for full detail."
    exit 0
fi

# ── Colours ─────────────────────────────────────────────────────────

# Colours (disabled if terminal doesn't support them or output is piped)
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
# Used by hard-fail paths that need to surface a security or
# integrity message. Goes to stderr so it never gets swallowed by
# tee /dev/null on the calling side; keeps red [ERROR] colour to
# match the visual class of `fail` (which exits) without exiting
# itself -- caller decides whether to exit or recover.
err()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
fail()  { echo -e "${RED}[fail]${NC}  $*"; exit 1; }
step()  { echo -e "\n${BOLD}==> $*${NC}"; }

# Retry a model pull up to 3 times with exponential backoff. A 6.6 GB
# pull over hotel WiFi is fragile; a single network blip should not
# abort the entire install at 80% progress.
ollama_pull_with_retry() {
    local model="$1"
    local attempt=1
    local backoff=10
    while (( attempt <= 3 )); do
        if ollama pull "$model"; then
            return 0
        fi
        if (( attempt < 3 )); then
            warn "ollama pull ${model} failed (attempt ${attempt}/3). Retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# ── --allow-plaintext loud warning ─────────────────────────────────
# If the operator passed --allow-plaintext, repeat a yellow warning
# three times so it cannot be missed in CI logs or terminal scrollback.
# This flag is dev/CI only. Production installs MUST run encrypted.
if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."
fi

# ── Paths ──────────────────────────────────────────────────────────

OSTLER_DIR="${HOME}/.ostler"
DATA_DIR="${OSTLER_DIR}/data"
CONFIG_DIR="${OSTLER_DIR}/config"
LOGS_DIR="${OSTLER_DIR}/logs"
SECURITY_DIR="${OSTLER_DIR}/security-module"
SECURITY_CONFIG_DIR="${OSTLER_DIR}/security"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"

# Two-zone layout: ~/Documents/Ostler/ holds the customer's
# generated content (wiki MDs, call transcripts, daily briefs,
# quick captures, one-off exports). ~/.ostler/ above is the
# engine room (databases, configs, logs, caches). The user-facing
# tree is created at install time and survives an uninstall by
# default; the customer is asked whether to keep it. See
# /tmp/tnm_brief_two_zone_architecture_2026-05-02.md (Gap 4).
USER_FACING_ROOT="${HOME}/Documents/Ostler"
USER_TREE_SENTINEL="${OSTLER_DIR}/.installer-tree-created"
# Ordered list of subdirs created under ${USER_FACING_ROOT}.
# Conversations/ is intentionally absent for now; it lands in a
# follow-up PR once the brief's zoning question is resolved.
USER_TREE_SUBDIRS=("Wiki" "Transcripts" "Daily-Briefs" "Captures" "Exports")

# ── SCRIPT_DIR resolution (tarball / dev / curl|bash bootstrap) ───
#
# The installer copies bundled assets (ostler_security/, ostler_fda/,
# contact_syncer/, hub-power/, doctor/, THIRD_PARTY_NOTICES.md,
# LICENSES/) from SCRIPT_DIR into ~/.ostler/ during install. Three
# install paths exist:
#
#   1. Tarball mode (productised launch). User downloaded
#      ostler-installer-X.tar.gz, extracted it, ran ./install.sh
#      from inside. BASH_SOURCE[0] is a real file path; the standard
#      cd+dirname dance works.
#
#   2. Dev mode. Developer cloned the installer repo and ran
#      ./install.sh from their checkout. Same shape as tarball mode.
#
#   3. curl|bash mode. `curl ... | bash`. BASH_SOURCE[0] is empty,
#      cd+dirname collapses to $HOME, and every `${SCRIPT_DIR}/<asset>`
#      lookup below would silently miss. We refuse to silently degrade –
#      if a canonical tarball URL is configured, we bootstrap from it
#      and re-exec; otherwise we fail with an actionable message
#      pointing the user at the tarball download flow.
#
# Override the tarball URL with OSTLER_INSTALLER_TARBALL_URL.
# The default points at the GitHub Release artifact on the public
# ostler-ai/ostler-installer mirror (versioned, signed, free, standard
# pattern). Cloudflare Pages serving a static tarball was considered
# but loses versioning + signing; GitHub Release is the long-term home.
# Interim installer-tarball mirror. The canonical home will be
# https://github.com/ostler-ai/ostler-installer/releases/... once
# the ostler-ai org clears GitHub's new-account hold (task #271);
# until then we host the release artefact on the andygmassey
# mirror so `curl -fsSL ostler.ai/install.sh | bash` works.
# NOTE: the matching `install.tar.gz` release artefact still
# needs publishing on this repo as a separate one-shot release
# step (operator-side; this installer never publishes itself).
DEFAULT_INSTALLER_TARBALL_URL="https://github.com/andygmassey/CM051-Home-Hub-Installer/releases/latest/download/install.tar.gz"
INSTALLER_TARBALL_URL="${OSTLER_INSTALLER_TARBALL_URL:-${DEFAULT_INSTALLER_TARBALL_URL}}"

if [[ -n "${OSTLER_BOOTSTRAP_SCRIPT_DIR:-}" ]]; then
    # Re-entry from a curl|bash bootstrap. The outer invocation
    # extracted a tarball and exec'd us with this env var pointing at
    # the extracted directory.
    SCRIPT_DIR="${OSTLER_BOOTSTRAP_SCRIPT_DIR}"
elif [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    # Tarball or dev mode.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # curl|bash mode. Try to bootstrap.
    BOOTSTRAP_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ostler-installer-XXXXXX")"
    trap 'rm -rf "${BOOTSTRAP_TMPDIR:-}"' EXIT INT TERM

    echo "==> Bootstrapping installer tarball from ${INSTALLER_TARBALL_URL}"
    if ! curl --fail --silent --show-error --location \
            --output "${BOOTSTRAP_TMPDIR}/install.tar.gz" \
            "${INSTALLER_TARBALL_URL}" 2>"${BOOTSTRAP_TMPDIR}/curl.err"; then
        echo
        echo "ERROR: Could not download the installer tarball."
        echo
        echo "  URL:    ${INSTALLER_TARBALL_URL}"
        echo "  Reason: $(cat "${BOOTSTRAP_TMPDIR}/curl.err" 2>/dev/null || echo unknown)"
        echo
        echo "The installer needs bundled assets (ostler_security, ostler_fda,"
        echo "contact_syncer, hub-power, doctor, third-party notices) that this"
        echo "single install.sh script does not contain. Fix one of:"
        echo
        echo "  1. Wait until the installer tarball is published. We are tracking"
        echo "     this at https://ostler.ai/launch."
        echo
        echo "  2. Override the tarball URL if you have one staged:"
        echo "       curl -fsSL https://ostler.ai/install.sh | \\"
        echo "         OSTLER_INSTALLER_TARBALL_URL=https://your-host/install.tar.gz \\"
        echo "         bash"
        echo
        echo "  3. Clone the installer repo and run ./install.sh from your"
        echo "     checkout (dev mode), with PWG_PIPELINE_REPO + PWG_HUB_POWER_REPO"
        echo "     set to source repos you have access to."
        echo
        exit 1
    fi

    if ! tar -xzf "${BOOTSTRAP_TMPDIR}/install.tar.gz" -C "${BOOTSTRAP_TMPDIR}"; then
        echo "ERROR: Downloaded tarball did not extract cleanly. Aborting."
        exit 1
    fi

    BOOTSTRAP_SCRIPT="$(find "${BOOTSTRAP_TMPDIR}" -maxdepth 3 -name install.sh -type f -print -quit)"
    if [[ -z "${BOOTSTRAP_SCRIPT}" ]]; then
        echo "ERROR: Tarball did not contain install.sh. Aborting."
        exit 1
    fi

    BOOTSTRAP_DIR="$(cd "$(dirname "${BOOTSTRAP_SCRIPT}")" && pwd)"
    export OSTLER_BOOTSTRAP_SCRIPT_DIR="${BOOTSTRAP_DIR}"
    # Drop the cleanup trap before exec so the extracted tree survives.
    trap - EXIT INT TERM
    exec bash "${BOOTSTRAP_SCRIPT}" "$@"
fi

# ── External resources (overridable via env vars) ──────────────────
#
# Both URLs default to empty in the productised installer. The
# productised path bundles the pipeline + hub-power scripts in the
# installer tarball (see ${SCRIPT_DIR}/contact_syncer and
# ${SCRIPT_DIR}/hub-power), so the clone fallback only fires for
# developers running install.sh directly without a tarball. Empty
# defaults mean a cold curl-pipe-bash install never points at a
# private dev repo; the clone path becomes opt-in via env var.
#
# These were previously hard-coded to andygmassey/* repos which are
# private, so an unauthenticated cold install hit a clone failure
# (handled non-fatally, but produced confusing log noise about repos
# the user had no business knowing about). The migration to a
# creativemachines-ai org public mirror is queued; until that lands,
# overrides are how dev / beta installs source these.

# Source repo for the import pipeline (CM041 People Graph). Override:
# PWG_PIPELINE_REPO="https://github.com/your-org/pipeline.git" ./install.sh
PIPELINE_REPO="${PWG_PIPELINE_REPO:-}"

# Hub power policy scripts (MacBook-as-Hub support). Ships in HR015 under
# hub-power/. At release the installer tarball bundles a copy under
# ${SCRIPT_DIR}/hub-power/; in dev it may be symlinked there. Override:
# PWG_HUB_POWER_REPO="https://github.com/your-org/infra.git" ./install.sh
HUB_POWER_REPO="${PWG_HUB_POWER_REPO:-}"

# Base URL for fallback fetch of THIRD_PARTY_NOTICES.md and the
# LICENSES/ tree. Same productisation rule: bundled tarball is the
# primary path, raw fetch is the fallback. Empty default keeps the
# productised install from probing a private repo. Set this to the
# raw.githubusercontent.com base URL of any branch holding the
# canonical attribution files (no trailing slash):
# PWG_NOTICES_BASE_URL="https://raw.githubusercontent.com/<org>/<repo>/main"
NOTICES_BASE_URL="${PWG_NOTICES_BASE_URL:-}"

# ══════════════════════════════════════════════════════════════════════
#  PHASE 1: PREREQUISITES (automatic — no user input)
# ══════════════════════════════════════════════════════════════════════

INSTALL_START=$(date +%s)

# ── Ensure Homebrew is on PATH (critical for re-runs) ────────────
# On Apple Silicon, Homebrew lives at /opt/homebrew which isn't in
# the default PATH. First installs add it via brew shellenv, but
# re-runs need it too for docker, ollama, python3, etc.
if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

echo ""
echo -e "${BOLD}  Ostler – Your personal knowledge graph${NC}"
echo -e "  Local-first. Private. Yours."
echo ""
echo "  This installer will ask you a few questions, then set up"
echo "  everything automatically. You can walk away after the questions."
echo ""

step "Checking prerequisites"

# ── Licence / activation check ─────────────────────────────────────
# TODO (post-App Store): Verify Home Hub purchase via StoreKit receipt.
# When the installer is bundled inside the Mac App Store app:
# - Apple ID gives us the user's name (no need to ask)
# - StoreKit receipt proves purchase
# - Activation code for free Ostler month is generated here
# - The whole Phase 2 reduces to: passphrase + confirm
#
# For the beta, we use an activation code entered here.
# Set OSTLER_BETA=1 to skip (F&F testers don't need a code).
# Activation check is not wired up yet (licence server and StoreKit
# receipts come with App Store packaging, CM043 Phase 4). Today every
# install behaves as beta, so the conditional block was a no-op with
# a single ':' inside. Dropped the empty block; left the TODO tag at
# file level so the activation path gets picked up during packaging.
#
# TODO(app-store-packaging): activate against licence server or local code check

# macOS check
if [[ "$(uname)" != "Darwin" ]]; then
    fail "This installer is for macOS only. Linux support coming soon."
fi
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
ok "macOS ${MACOS_VERSION} detected"

# Minimum macOS 13 (Ventura) — needed for modern Docker, Ollama, and security features
if [[ $MACOS_MAJOR -lt 13 ]]; then
    warn "macOS ${MACOS_VERSION} is outdated. We recommend macOS 13 (Ventura) or later."
    warn "Some features may not work correctly on older versions."
fi

# Git / Xcode command line tools — needed for cloning the pipeline
if ! command -v git &>/dev/null; then
    info "Git not found. Installing Xcode Command Line Tools..."
    echo "  macOS will show a dialog — click 'Install' and wait."
    xcode-select --install 2>/dev/null || true
    # Wait for xcode-select to finish, with a timeout so the installer
    # doesn't hang forever if the user dismisses the install dialog.
    XCODE_WAIT=0
    XCODE_TIMEOUT=600  # 10 minutes — generous; CLI install is ~150 MB
    until command -v git &>/dev/null; do
        if [[ $XCODE_WAIT -ge $XCODE_TIMEOUT ]]; then
            fail "Xcode Command Line Tools install did not complete in 10 minutes. Run 'xcode-select --install' manually, accept the dialog, then re-run this installer."
        fi
        sleep 5
        XCODE_WAIT=$((XCODE_WAIT + 5))
    done
    ok "Git available"
else
    ok "Git available"
fi

# Apple Silicon check
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon detected"
else
    warn "Intel Mac detected — performance will be limited. Apple Silicon recommended."
fi

# RAM check
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [[ $RAM_GB -lt 16 ]]; then
    fail "At least 16 GB RAM required. You have ${RAM_GB} GB. 24 GB recommended."
elif [[ $RAM_GB -lt 24 ]]; then
    warn "${RAM_GB} GB RAM detected. Works but limits AI model size. 24 GB+ recommended."
else
    ok "${RAM_GB} GB RAM detected"
fi

# Disk space check — need ~35 GB: Docker images (~1 GB), AI model (5-10 GB),
# embedding model (300 MB), import pipeline + venv (~500 MB), databases (grows
# with data), and headroom for GDPR exports.
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
if [[ $FREE_GB -lt 35 ]]; then
    warn "Only ${FREE_GB} GB free. We recommend at least 35 GB (Docker images + AI model + data)."
    if [[ $FREE_GB -lt 15 ]]; then
        fail "Not enough disk space (${FREE_GB} GB). Free up space and try again."
    fi
else
    ok "${FREE_GB} GB free disk space"
fi

# Power source check. On a MacBook, Phase 3 takes 10-15 minutes of
# continuous Docker pulls and Ollama model downloads. The hub power
# LaunchAgent installed at step 3.14 pauses Docker and Ollama when
# the battery drops below the policy threshold, which can hang the
# installer's readiness probes for the full timeout (90 s / 300 s).
# Warn the user to stay on AC.
HAS_BATTERY=false
if pmset -g batt 2>/dev/null | grep -qE '[0-9]+%'; then
    HAS_BATTERY=true
fi

if [[ "$HAS_BATTERY" == true ]]; then
    POWER_SOURCE=$(pmset -g batt 2>/dev/null | grep -oE "'(AC Power|Battery Power)'" | head -1 | tr -d "'")
    if [[ "$POWER_SOURCE" == "AC Power" ]]; then
        ok "Power source: AC (good for the 10-15 minute install)"
    else
        warn "Power source: ${POWER_SOURCE:-Battery Power}"
        warn "Phase 3 takes 10-15 minutes of Docker + Ollama downloads."
        warn "On battery, the hub power LaunchAgent (step 3.14) may pause"
        warn "Docker / Ollama mid-install and hang the readiness probes."
        warn "Plug into AC power for the full install."
    fi
else
    ok "Power source: AC (desktop Mac, no battery)"
fi

# Check Docker availability (don't install yet — just check)
HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    HAS_DOCKER=true
    ok "Docker running"
elif command -v colima &>/dev/null; then
    info "Colima installed but not running. Will start it."
elif command -v docker &>/dev/null; then
    warn "Docker installed but not running. Will need to start it."
else
    info "Docker not installed. Will install Colima + Docker CLI + docker-compose plugin (lightweight, no Docker Desktop required)."
fi

# Check if --check mode
if [[ "$CHECK_ONLY" == true ]]; then
    echo ""
    echo "  Prerequisites check complete. Run without --check to install."
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════
#  PHASE 2: COLLECT ALL USER INPUT (~2 minutes)
# ══════════════════════════════════════════════════════════════════════

# Re-run detection: if config exists, skip Phase 2 entirely
SKIP_PHASE2=false
FV_ENABLED=false
if [[ -f "${CONFIG_DIR}/.env" ]]; then
    ok "Previous installation detected. Loading config..."
    # Source existing config
    set -a; source "${CONFIG_DIR}/.env"; set +a
    USER_NAME="${USER_NAME:-}"
    USER_ID="${USER_ID:-}"
    ASSISTANT_NAME="${ASSISTANT_NAME:-}"
    USER_TZ="${TIMEZONE:-UTC}"
    COUNTRY_CODE="${DEFAULT_COUNTRY_CODE:-44}"
    EXPORTS_DIR=""
    CONTACT_COUNT=0
    # Check FileVault for summary display
    if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
        FV_ENABLED=true
    fi
    # Check if iCloud contacts were previously exported
    if [[ -f "${OSTLER_DIR}/imports/icloud-contacts.vcf" ]]; then
        EXPORTS_DIR="${OSTLER_DIR}/imports"
    fi
    SKIP_PHASE2=true

    echo ""
    echo "  User:       ${USER_NAME} (${USER_ID})"
    echo "  Assistant:  ${ASSISTANT_NAME}"
    echo "  Timezone:   ${USER_TZ}"
    echo ""
    read -p "  Continue with these settings? (Y/n): " REUSE
    if [[ "${REUSE:-y}" == "n" || "${REUSE:-y}" == "N" ]]; then
        SKIP_PHASE2=false
    fi
fi

if [[ "$SKIP_PHASE2" == false ]]; then

step "Setup (answer a few questions, then walk away)"

echo ""
echo -e "  ${BOLD}What Ostler needs from your Mac${NC}"
echo ""
echo "  macOS will ask you to approve two permissions. These are"
echo "  required for Ostler to work:"
echo ""
echo -e "    ${BOLD}Contacts${NC}          Your name + contacts for the knowledge graph"
echo -e "    ${BOLD}Files & Folders${NC}   Find data exports in your Downloads folder"
echo ""
echo "  Optional (can set up later):"
echo ""
echo -e "    ${BOLD}Full Disk Access${NC}  Instant data from Safari, iMessage, Notes,"
echo "                      Calendar, Photos, Reminders, Mail"
echo ""
echo -e "  ${BOLD}One tip before you continue:${NC}"
echo ""
echo "  If you use Gmail, iCloud Mail, Outlook, or any other email via"
echo "  webmail only — add those accounts to Mac Mail first:"
echo "    System Settings > Internet Accounts > add account > tick Mail"
echo ""
echo "  Apple handles the authentication; messages land in your local Mail"
echo "  store; Ostler reads from there via Full Disk Access. No passwords"
echo "  for Ostler to hold, no OAuth clients, no cloud API calls."
echo "  More accounts in Mail = more depth in your knowledge graph."
echo ""
echo "  Same trick for calendars: add them to Apple Calendar (System"
echo "  Settings > Internet Accounts) and Ostler reads everything together."
echo ""
echo "  Your personal data stays on this machine. Ostler makes a few"
echo "  narrow public-data queries (described in the privacy policy) plus"
echo "  model and software downloads. These are standard Apple prompts."
echo ""
read -p "  Ready to continue? (Y/n): " PERMS_OK
if [[ "${PERMS_OK:-y}" == "n" || "${PERMS_OK:-y}" == "N" ]]; then
    echo ""
    echo "  No problem. Review what Ostler needs at:"
    echo "  creativemachines.ai/ostler/privacy"
    echo ""
    echo "  Re-run the installer when you are ready."
    exit 0
fi

echo ""

# ── Auto-detect from macOS contact card ────────────────────────────

DETECTED_NAME=""
DETECTED_COUNTRY=""
DETECTED_EMAIL=""
DETECTED_PHONE=""

info "Reading your contact card to pre-fill your details..."
echo "  macOS may ask permission to access Contacts."
echo "  This reads your name, country, and phone number to save you typing."
echo "  It also exports your contacts for the knowledge graph."
echo "  (Your data stays on this machine — nothing is sent anywhere.)"
echo ""

# Capture stderr separately so we can detect a Contacts permission denial
# (errAEEventNotPermitted = -1743) and surface it cleanly. The previous
# `2>/dev/null || echo ""` swallowed denials silently and left the user
# wondering why nothing happened.
CARD_STDERR=$(mktemp)
CARD_DATA=$(osascript -e '
tell application "Contacts"
    set myCard to my card
    set myName to name of myCard
    set firstName to first name of myCard

    set myCountry to ""
    try
        set myCountry to country of first address of myCard
    end try

    set myEmail to ""
    try
        set myEmail to value of first email of myCard
    end try

    set myPhone to ""
    try
        set myPhone to value of first phone of myCard
    end try

    return myName & "|" & firstName & "|" & myCountry & "|" & myEmail & "|" & myPhone
end tell' 2>"$CARD_STDERR" || true)

if [[ -z "$CARD_DATA" ]] && grep -qE '\-1743|not authorized|errAEEventNotPermitted' "$CARD_STDERR" 2>/dev/null; then
    warn "macOS Contacts permission was declined or not yet granted."
    warn "You can re-grant it in System Settings > Privacy & Security > Contacts."
    warn "Continuing without contact-card auto-fill – Ostler will ask you instead."
fi
rm -f "$CARD_STDERR"

if [[ -n "$CARD_DATA" ]]; then
    DETECTED_NAME=$(echo "$CARD_DATA" | cut -d'|' -f1)
    DETECTED_FIRST=$(echo "$CARD_DATA" | cut -d'|' -f2)
    DETECTED_COUNTRY=$(echo "$CARD_DATA" | cut -d'|' -f3)
    DETECTED_EMAIL=$(echo "$CARD_DATA" | cut -d'|' -f4)
    DETECTED_PHONE=$(echo "$CARD_DATA" | cut -d'|' -f5)
    ok "Found: ${DETECTED_NAME}"

    # Back up contacts FIRST — before we do anything with them.
    # This is a safety net in case anything goes wrong during import.
    CONTACTS_BACKUP="${OSTLER_DIR}/backups/contacts-backup-$(date +%Y%m%d-%H%M%S).vcf"
    CONTACTS_EXPORT="${OSTLER_DIR}/imports/icloud-contacts.vcf"
    mkdir -p "${OSTLER_DIR}/imports" "${OSTLER_DIR}/backups"
    CONTACT_COUNT=$(osascript -e '
tell application "Contacts"
    set vcfData to vcard of every person
    return count of every person
end tell' 2>/dev/null || echo "0")

    if [[ "$CONTACT_COUNT" -gt 0 ]]; then
        # Save backup copy first
        osascript -e "
tell application \"Contacts\"
    set vcfData to vcard of every person
    set fp to POSIX file \"${CONTACTS_BACKUP}\"
    set fRef to open for access fp with write permission
    write vcfData to fRef
    close access fRef
end tell" 2>/dev/null && \
        ok "Backed up ${CONTACT_COUNT} contacts to ${CONTACTS_BACKUP}"

        # Export working copy for import
        cp "$CONTACTS_BACKUP" "$CONTACTS_EXPORT" 2>/dev/null && \
        ok "Exported ${CONTACT_COUNT} contacts (will import automatically)" || \
        info "Could not export contacts. You can import manually later."
    fi
else
    info "Could not read contact card. No problem — we will ask instead."
fi

# ── Map country name to dialling code ──────────────────────────────

_country_to_code() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        "united kingdom"|"uk"|"gb"|"great britain"|"england"|"scotland"|"wales") echo "44" ;;
        "united states"|"usa"|"us"|"america") echo "1" ;;
        "hong kong"|"hk") echo "852" ;;
        "australia"|"au") echo "61" ;;
        "china"|"cn") echo "86" ;;
        "japan"|"jp") echo "81" ;;
        "singapore"|"sg") echo "65" ;;
        "india"|"in") echo "91" ;;
        "germany"|"de") echo "49" ;;
        "france"|"fr") echo "33" ;;
        "canada"|"ca") echo "1" ;;
        "new zealand"|"nz") echo "64" ;;
        "ireland"|"ie") echo "353" ;;
        "philippines"|"ph") echo "63" ;;
        "indonesia"|"id") echo "62" ;;
        "malaysia"|"my") echo "60" ;;
        "thailand"|"th") echo "66" ;;
        "south korea"|"korea"|"kr") echo "82" ;;
        "taiwan"|"tw") echo "886" ;;
        "netherlands"|"nl") echo "31" ;;
        "sweden"|"se") echo "46" ;;
        "switzerland"|"ch") echo "41" ;;
        "italy"|"it") echo "39" ;;
        "spain"|"es") echo "34" ;;
        "brazil"|"br") echo "55" ;;
        "mexico"|"mx") echo "52" ;;
        "south africa"|"za") echo "27" ;;
        "united arab emirates"|"uae"|"ae") echo "971" ;;
        *) echo "" ;;
    esac
}

DETECTED_CODE=""
if [[ -n "$DETECTED_COUNTRY" ]]; then
    DETECTED_CODE=$(_country_to_code "$DETECTED_COUNTRY")
fi

# Also try to extract country code from phone number
if [[ -z "$DETECTED_CODE" && -n "$DETECTED_PHONE" ]]; then
    # Strip spaces and dashes, check for + prefix
    CLEAN_PHONE=$(echo "$DETECTED_PHONE" | tr -d ' -.()')
    if [[ "$CLEAN_PHONE" == +* ]]; then
        # Try common prefixes
        case "$CLEAN_PHONE" in
            +1*)   DETECTED_CODE="1" ;;
            +44*)  DETECTED_CODE="44" ;;
            +852*) DETECTED_CODE="852" ;;
            +61*)  DETECTED_CODE="61" ;;
            +86*)  DETECTED_CODE="86" ;;
            +81*)  DETECTED_CODE="81" ;;
            +65*)  DETECTED_CODE="65" ;;
            +91*)  DETECTED_CODE="91" ;;
            +33*)  DETECTED_CODE="33" ;;
            +49*)  DETECTED_CODE="49" ;;
        esac
    fi
fi

# ── 1. Confirm name ───────────────────────────────────────────────

echo -e "  ${BOLD}Your details${NC}"
echo ""
if [[ -n "$DETECTED_NAME" ]]; then
    read -p "  Full name (as it appears in your contacts) [${DETECTED_NAME}]: " USER_NAME
    USER_NAME=${USER_NAME:-$DETECTED_NAME}
else
    read -p "  Full name (e.g. Tom Harrison): " USER_NAME
fi

DETECTED_FIRST_LOWER=$(echo "${DETECTED_FIRST:-}" | tr '[:upper:]' '[:lower:]')
DEFAULT_ID=${DETECTED_FIRST_LOWER:-$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)}
read -p "  What should your assistant call you? [${DEFAULT_ID}]: " USER_ID
USER_ID=${USER_ID:-$DEFAULT_ID}

# ── 2. Confirm country code ───────────────────────────────────────

echo ""
if [[ -n "$DETECTED_CODE" ]]; then
    echo "  Country code detected from your contact card: +${DETECTED_CODE}"
    read -p "  Use +${DETECTED_CODE}? (Y/n): " CC_CONFIRM
    if [[ "${CC_CONFIRM:-y}" == "n" || "${CC_CONFIRM:-y}" == "N" ]]; then
        read -p "  Enter country code (e.g. 44 for UK, 1 for US): " COUNTRY_CODE
    else
        COUNTRY_CODE="$DETECTED_CODE"
    fi
else
    echo "  Your country code is used to normalise phone numbers during"
    echo "  contact import (e.g. 44 for UK, 1 for US, 852 for HK)."
    echo ""
    read -p "  Default country code: " COUNTRY_CODE
    COUNTRY_CODE=${COUNTRY_CODE:-44}
fi

# ── 2.5 Detect region for the Article 9 / voice-consent gate ──────
#
# A8 (locked 2026-05-02): EU users see an Article 9 explicit-consent
# screen before any ~/.ostler/ data is written. UK / US / RoW users
# get the existing INSTALL/CANCEL flow. Region defaults to EU when
# every signal is empty, per the brief at
# /tmp/plan_legal_position_implementation_2026-05-02.md section 2:
# the lawyer-friend prefers a "false positive on EU" to a
# "false negative".
#
# This is a Bash mirror of ostler_security.region (which the Hub
# venv hasn't installed yet at this point). Once the venv is up in
# Phase 3 we re-write the same region into
# ~/.ostler/posture/region.json via the shared Python module so
# Doctor + the Rust gates can read a single source of truth.
#
# No IP geolocation. No phone-home lookup. Manual / contact-card /
# phone-cc / locale only.
_classify_region() {
    # $1 = ISO-3166 alpha-2 country code (uppercase) or "" for unknown.
    local iso="$1"
    case "$iso" in
        GB|UK) echo "uk" ;;
        US) echo "us" ;;
        AT|BE|BG|HR|CY|CZ|DK|EE|FI|FR|DE|GR|HU|IE|IT|LV|LT|LU|MT|NL|PL|PT|RO|SK|SI|ES|SE|IS|LI|NO|CH)
            echo "eu" ;;
        "") echo "eu" ;;  # default-EU defensive policy
        *) echo "row" ;;
    esac
}

_country_to_iso() {
    # Best-effort country-name -> ISO-3166 alpha-2 mapping. Mirrors
    # ostler_security.region.COUNTRY_NAME_TO_ISO. Returns "" for
    # unknown so the caller can fall through to the next signal.
    local lower
    lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        "united kingdom"|"uk"|"gb"|"great britain"|"england"|"scotland"|"wales"|"northern ireland")
            echo "GB" ;;
        "united states"|"usa"|"us"|"america"|"united states of america")
            echo "US" ;;
        "germany"|"de") echo "DE" ;;
        "france"|"fr") echo "FR" ;;
        "spain"|"es") echo "ES" ;;
        "italy"|"it") echo "IT" ;;
        "netherlands"|"nl"|"the netherlands"|"holland") echo "NL" ;;
        "belgium"|"be") echo "BE" ;;
        "austria"|"at") echo "AT" ;;
        "ireland"|"ie"|"republic of ireland") echo "IE" ;;
        "portugal"|"pt") echo "PT" ;;
        "poland"|"pl") echo "PL" ;;
        "sweden"|"se") echo "SE" ;;
        "denmark"|"dk") echo "DK" ;;
        "finland"|"fi") echo "FI" ;;
        "greece"|"gr") echo "GR" ;;
        "czechia"|"czech republic"|"cz") echo "CZ" ;;
        "hungary"|"hu") echo "HU" ;;
        "romania"|"ro") echo "RO" ;;
        "bulgaria"|"bg") echo "BG" ;;
        "croatia"|"hr") echo "HR" ;;
        "slovakia"|"sk") echo "SK" ;;
        "slovenia"|"si") echo "SI" ;;
        "lithuania"|"lt") echo "LT" ;;
        "latvia"|"lv") echo "LV" ;;
        "estonia"|"ee") echo "EE" ;;
        "luxembourg"|"lu") echo "LU" ;;
        "cyprus"|"cy") echo "CY" ;;
        "malta"|"mt") echo "MT" ;;
        "iceland"|"is") echo "IS" ;;
        "liechtenstein"|"li") echo "LI" ;;
        "norway"|"no") echo "NO" ;;
        "switzerland"|"ch") echo "CH" ;;
        # 2-letter codes pass through (uppercased for the classifier).
        ??)
            echo "$lower" | tr '[:lower:]' '[:upper:]'
            ;;
        *) echo "" ;;
    esac
}

OSTLER_REGION_ISO=""
OSTLER_REGION_SOURCE=""

# Manual override (env var) takes top priority for testers + CI.
if [[ -n "${OSTLER_REGION_OVERRIDE:-}" ]]; then
    OSTLER_REGION_ISO=$(_country_to_iso "$OSTLER_REGION_OVERRIDE")
    OSTLER_REGION_SOURCE="manual"
fi

# Apple Contacts country wins over phone country code.
if [[ -z "$OSTLER_REGION_ISO" && -n "${DETECTED_COUNTRY:-}" ]]; then
    OSTLER_REGION_ISO=$(_country_to_iso "$DETECTED_COUNTRY")
    [[ -n "$OSTLER_REGION_ISO" ]] && OSTLER_REGION_SOURCE="contacts"
fi

# Phone country code -> ISO via dialling-code reverse lookup.
if [[ -z "$OSTLER_REGION_ISO" && -n "${COUNTRY_CODE:-}" ]]; then
    case "$COUNTRY_CODE" in
        44) OSTLER_REGION_ISO="GB" ;;
        1)  OSTLER_REGION_ISO="US" ;;
        49) OSTLER_REGION_ISO="DE" ;;
        33) OSTLER_REGION_ISO="FR" ;;
        34) OSTLER_REGION_ISO="ES" ;;
        39) OSTLER_REGION_ISO="IT" ;;
        31) OSTLER_REGION_ISO="NL" ;;
        46) OSTLER_REGION_ISO="SE" ;;
        41) OSTLER_REGION_ISO="CH" ;;
        353) OSTLER_REGION_ISO="IE" ;;
        61) OSTLER_REGION_ISO="AU" ;;
        65) OSTLER_REGION_ISO="SG" ;;
        852) OSTLER_REGION_ISO="HK" ;;
        81) OSTLER_REGION_ISO="JP" ;;
        86) OSTLER_REGION_ISO="CN" ;;
        91) OSTLER_REGION_ISO="IN" ;;
    esac
    [[ -n "$OSTLER_REGION_ISO" ]] && OSTLER_REGION_SOURCE="phone"
fi

# Locale fallback (LC_ALL > LANG > nothing).
if [[ -z "$OSTLER_REGION_ISO" ]]; then
    _locale_raw="${LC_ALL:-${LANG:-}}"
    if [[ "$_locale_raw" == *_* ]]; then
        _locale_country="${_locale_raw#*_}"
        _locale_country="${_locale_country:0:2}"
        if [[ ${#_locale_country} -eq 2 ]]; then
            OSTLER_REGION_ISO=$(echo "$_locale_country" | tr '[:lower:]' '[:upper:]')
            OSTLER_REGION_SOURCE="locale"
        fi
    fi
fi

if [[ -z "$OSTLER_REGION_ISO" ]]; then
    OSTLER_REGION_ISO="ZZ"
    OSTLER_REGION_SOURCE="default_eu"
fi

OSTLER_REGION=$(_classify_region "$OSTLER_REGION_ISO")

case "$OSTLER_REGION" in
    eu)
        info "Region: EU/EEA (${OSTLER_REGION_ISO}, source: ${OSTLER_REGION_SOURCE})"
        info "      Ostler will show an extra consent screen before installing"
        info "      (UK GDPR Article 9 - required for special-category data)."
        ;;
    uk)
        info "Region: United Kingdom (source: ${OSTLER_REGION_SOURCE})"
        ;;
    us)
        info "Region: United States (source: ${OSTLER_REGION_SOURCE})"
        ;;
    row)
        info "Region: ${OSTLER_REGION_ISO} (source: ${OSTLER_REGION_SOURCE})"
        ;;
esac

# ── 3. Confirm timezone ───────────────────────────────────────────

DETECTED_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo "")
if [[ -n "$DETECTED_TZ" ]]; then
    echo ""
    echo "  Detected timezone: ${DETECTED_TZ}"
    read -p "  Use this timezone? (Y/n): " TZ_CONFIRM
    if [[ "${TZ_CONFIRM:-y}" == "n" || "${TZ_CONFIRM:-y}" == "N" ]]; then
        read -p "  Enter timezone (e.g. Europe/London, Asia/Hong_Kong): " USER_TZ
    else
        USER_TZ="$DETECTED_TZ"
    fi
else
    read -p "  Enter timezone (e.g. Europe/London, Asia/Hong_Kong): " USER_TZ
    USER_TZ=${USER_TZ:-UTC}
fi

# ── 4. Name your AI assistant ─────────────────────────────────────

echo ""
echo -e "  ${BOLD}Name your AI assistant${NC}"
echo ""
echo "  Your assistant lives on your Mac and manages your knowledge"
echo "  graph. Give it a name you will enjoy talking to."
echo ""
echo "  Some ideas (or type your own):"
echo ""
echo -e "    ${BOLD}Marvin${NC}     – the laconic, brilliant assistant from Hitchhiker's Guide"
echo -e "    ${BOLD}Joshua${NC}     – the calm, careful AI from WarGames"
echo -e "    ${BOLD}Samantha${NC}   – the warm, attentive companion from Her"
echo -e "    ${BOLD}Atlas${NC}      – steady, reliable, mythological"
echo -e "    ${BOLD}Ada${NC}        – after Ada Lovelace, the first programmer"
echo ""

read -p "  Assistant name: " ASSISTANT_NAME
while [[ -z "$ASSISTANT_NAME" ]]; do
    warn "Your assistant needs a name. Pick from the suggestions above or type your own."
    read -p "  Assistant name: " ASSISTANT_NAME
done

ok "Your assistant is called ${ASSISTANT_NAME}"

# ── 4a. Channels (how to talk to your assistant) ──────────────────
#
# Captures the customer's preferred input/output channels so the
# Ostler assistant has somewhere to receive and reply to messages.
# v0.1 supports iMessage (default; macOS-native, no external auth)
# and email (IMAP/SMTP via app password). Other channels (Telegram,
# Slack, Discord, WhatsApp, etc.) are exposed by the Rust runtime
# but require additional auth flow that is out of scope for v0.1
# and lands in v0.2 via the assistant's own `setup channels` CLI.
#
# Captured here, written to disk in section 3.5c (after the .env
# write) so the password sits on disk for the shortest possible
# window before encryption setup. The TOML lands at
# ${OSTLER_DIR}/assistant-config/config.toml mode 0600.
#
# Open question for Andy: this wizard duplicates a small subset of
# the assistant's own `ostler-assistant setup channels --interactive`
# wizard. Long-term we could delegate to the Rust binary, but that
# requires Phase C (binary install) to land first AND for the
# assistant CLI's UX to fit inline with the installer flow. For
# v0.1, capturing here keeps the install one continuous flow.

echo ""
echo -e "  ${BOLD}How would you like to talk to ${ASSISTANT_NAME}?${NC}"
echo ""
echo "  Pick one or more channels. You can change these later by"
echo "  editing ${HOME}/.ostler/assistant-config/config.toml."
echo ""
echo -e "    ${BOLD}1. iMessage${NC}      – simplest, uses your Mac's Messages.app"
echo -e "    ${BOLD}2. Email${NC}         – IMAP/SMTP via an app password"
echo -e "    ${BOLD}3. Both${NC}          – iMessage + email (recommended)"
echo -e "    ${BOLD}4. Skip for now${NC}  – set up later"
echo -e "    ${BOLD}5. + WhatsApp${NC}    – iMessage + email + WhatsApp (read-only)"
echo ""
read -p "  Channel choice [3]: " CHANNEL_CHOICE
CHANNEL_CHOICE=${CHANNEL_CHOICE:-3}

# Normalise into per-channel boolean flags for the config writer.
CHANNEL_IMESSAGE_ENABLED=false
CHANNEL_EMAIL_ENABLED=false
CHANNEL_WHATSAPP_ENABLED=false
CHANNEL_WHATSAPP_CONSENT_ACCEPTED=false
CHANNEL_IMESSAGE_ALLOWED=""
CHANNEL_EMAIL_USERNAME=""
CHANNEL_EMAIL_PASSWORD=""
CHANNEL_EMAIL_FROM=""
CHANNEL_EMAIL_IMAP_HOST=""
CHANNEL_EMAIL_IMAP_PORT=993
CHANNEL_EMAIL_SMTP_HOST=""
CHANNEL_EMAIL_SMTP_PORT=587

case "$CHANNEL_CHOICE" in
    1) CHANNEL_IMESSAGE_ENABLED=true ;;
    2) CHANNEL_EMAIL_ENABLED=true ;;
    3|"") CHANNEL_IMESSAGE_ENABLED=true; CHANNEL_EMAIL_ENABLED=true ;;
    4) info "Skipping channel setup. Run later: ${OSTLER_DIR}/bin/ostler-assistant setup channels --interactive" ;;
    5)
        CHANNEL_IMESSAGE_ENABLED=true
        CHANNEL_EMAIL_ENABLED=true
        CHANNEL_WHATSAPP_ENABLED=true
        ;;
    *)
        warn "Unrecognised choice '${CHANNEL_CHOICE}'; defaulting to iMessage + email."
        CHANNEL_IMESSAGE_ENABLED=true
        CHANNEL_EMAIL_ENABLED=true
        ;;
esac

# ── WhatsApp risk tickbox (A7 - locked 2026-05-02) ────────────────
#
# Per the implementation brief at
# /tmp/plan_legal_position_implementation_2026-05-02.md section 1, the
# tickbox MUST appear at the moment the user adds the WhatsApp
# channel. Wording is verbatim from the section 4 plain-English text in
# the legal-doc draft, mirrored in legal/consent_strings.py
# (WHATSAPP_UNOFFICIAL_RISK_CONSENT). install.sh persists the
# decision via consent_cli once the venv is up in Phase 3; for now
# the answer is held in CHANNEL_WHATSAPP_CONSENT_ACCEPTED.
#
# Refusal does NOT abort the install. We simply leave WhatsApp
# unconfigured and the bridge stays disabled. The user can change
# their mind later via `ostler-assistant setup channels --interactive`
# (which presents the same tickbox).
if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}WhatsApp connector – please read carefully${NC}  ${YELLOW}[DRAFT - pending legal review]${NC}"
    echo ""
    echo "  Ostler can read your WhatsApp messages locally on this Mac so"
    echo "  you can search and reference them like any other part of your"
    echo "  life. The messages stay on your Mac. Nothing is sent to us."
    echo ""
    echo -e "  ${BOLD}There is a risk you should understand before turning this on.${NC}"
    echo ""
    echo "  WhatsApp's own Terms of Service say their service can only be"
    echo "  accessed using \"official\" WhatsApp software. Strictly speaking,"
    echo "  the way Ostler reads your messages – by reading WhatsApp Web's"
    echo "  storage on your Mac – is not what WhatsApp considers \"official.\""
    echo ""
    echo "  In practice, this kind of read access is widely used and we are"
    echo "  not aware of any documented case of WhatsApp banning a user for"
    echo "  it. But we cannot rule out the possibility that WhatsApp could:"
    echo ""
    echo "    - suspend your WhatsApp account, temporarily or permanently"
    echo "    - block the device from connecting"
    echo "    - require you to re-verify your number"
    echo ""
    echo "  If that happens, it happens to your WhatsApp account, not to"
    echo "  Creative Machines. You – not us – are the person bound by"
    echo "  WhatsApp's Terms of Service. We cannot get your account back"
    echo "  for you, and we are not liable for any loss you suffer if"
    echo "  WhatsApp takes action against your account."
    echo ""
    echo "  By continuing, you confirm that:"
    echo "    1. You understand this risk."
    echo "    2. You accept it on your own behalf."
    echo "    3. You agree that Creative Machines is not responsible if"
    echo "       WhatsApp suspends, restricts or terminates your WhatsApp"
    echo "       account because of your use of the connector."
    echo "    4. You can disable the connector at any time in Settings,"
    echo "       and disabling it does not undo any action WhatsApp may"
    echo "       have already taken."
    echo ""
    echo "  If you don't want to accept this risk, just leave it off – Ostler"
    echo "  works without WhatsApp. You can turn it on later from Settings."
    echo ""
    read -p "  Enable WhatsApp connector and accept the risk above? (y/N): " WA_CONSENT
    if [[ "${WA_CONSENT:-n}" == "y" || "${WA_CONSENT:-n}" == "Y" ]]; then
        CHANNEL_WHATSAPP_CONSENT_ACCEPTED=true
        ok "WhatsApp connector will be enabled (consent recorded)"
    else
        # Refusal: keep the channel disabled but record the decision
        # (so Doctor can show "user declined" rather than "missing").
        CHANNEL_WHATSAPP_ENABLED=false
        info "WhatsApp connector left off. You can enable it later via Settings."
    fi
fi

# ── iMessage details ───────────────────────────────────────────────
#
# The Rust runtime's IMessageConfig requires `allowed_contacts` to
# act as an inbound allowlist. Empty list = deny all (per the
# schema comment in crates/zeroclaw-config/src/schema.rs line 7147).
# We require at least one entry when iMessage is enabled so the
# customer doesn't end up with a silently-mute assistant.
if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
    echo ""
    echo -e "  ${BOLD}iMessage allowed contacts${NC}"
    echo ""
    echo "  Phone numbers or Apple ID emails that ${ASSISTANT_NAME} should accept"
    echo "  messages from. Comma-separated. You'll usually want at least"
    echo "  your own iCloud-linked phone or email here."
    echo ""
    echo "  Example: +447700900000, you@example.com"
    echo ""
    while [[ -z "$CHANNEL_IMESSAGE_ALLOWED" ]]; do
        read -p "  Allowed contacts: " CHANNEL_IMESSAGE_ALLOWED
        if [[ -z "$CHANNEL_IMESSAGE_ALLOWED" ]]; then
            warn "iMessage needs at least one allowed contact. Try again or pick"
            warn "a different channel choice (re-run installer)."
        fi
    done
fi

# ── Email details ──────────────────────────────────────────────────
#
# Provider presets pre-fill the IMAP/SMTP host + port + TLS for
# the common cases. "Custom" prompts for everything. Gmail and
# iCloud both require an app password (NOT the user's main
# account password) -- the prompts reflect this.
if [[ "$CHANNEL_EMAIL_ENABLED" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Email provider${NC}"
    echo ""
    echo "    1. Gmail (requires app password)"
    echo "    2. iCloud (requires app-specific password)"
    echo "    3. Outlook / Office 365"
    echo "    4. Other / custom IMAP+SMTP"
    echo ""
    read -p "  Provider [1]: " EMAIL_PROVIDER
    EMAIL_PROVIDER=${EMAIL_PROVIDER:-1}

    case "$EMAIL_PROVIDER" in
        1)
            CHANNEL_EMAIL_IMAP_HOST="imap.gmail.com"
            CHANNEL_EMAIL_IMAP_PORT=993
            CHANNEL_EMAIL_SMTP_HOST="smtp.gmail.com"
            CHANNEL_EMAIL_SMTP_PORT=587
            echo ""
            echo "  Gmail requires an APP PASSWORD (not your main Google password)."
            echo "  Generate one at: https://myaccount.google.com/apppasswords"
            ;;
        2)
            CHANNEL_EMAIL_IMAP_HOST="imap.mail.me.com"
            CHANNEL_EMAIL_IMAP_PORT=993
            CHANNEL_EMAIL_SMTP_HOST="smtp.mail.me.com"
            CHANNEL_EMAIL_SMTP_PORT=587
            echo ""
            echo "  iCloud requires an APP-SPECIFIC PASSWORD."
            echo "  Generate one at: https://appleid.apple.com (Sign-In and Security)"
            ;;
        3)
            CHANNEL_EMAIL_IMAP_HOST="outlook.office365.com"
            CHANNEL_EMAIL_IMAP_PORT=993
            CHANNEL_EMAIL_SMTP_HOST="smtp.office365.com"
            CHANNEL_EMAIL_SMTP_PORT=587
            ;;
        4)
            echo ""
            read -p "  IMAP host: " CHANNEL_EMAIL_IMAP_HOST
            read -p "  IMAP port [993]: " imap_port_in
            CHANNEL_EMAIL_IMAP_PORT=${imap_port_in:-993}
            read -p "  SMTP host: " CHANNEL_EMAIL_SMTP_HOST
            read -p "  SMTP port [587]: " smtp_port_in
            CHANNEL_EMAIL_SMTP_PORT=${smtp_port_in:-587}
            ;;
        *)
            warn "Unrecognised provider '${EMAIL_PROVIDER}'; using Gmail defaults."
            CHANNEL_EMAIL_IMAP_HOST="imap.gmail.com"
            CHANNEL_EMAIL_IMAP_PORT=993
            CHANNEL_EMAIL_SMTP_HOST="smtp.gmail.com"
            CHANNEL_EMAIL_SMTP_PORT=587
            ;;
    esac

    echo ""
    read -p "  Email address (also used as IMAP/SMTP username): " CHANNEL_EMAIL_USERNAME
    CHANNEL_EMAIL_FROM="$CHANNEL_EMAIL_USERNAME"

    # Hidden password input (read -s); confirm with re-entry so a
    # typo doesn't silently lock the assistant out of email.
    while true; do
        echo ""
        read -s -p "  Password (hidden): " CHANNEL_EMAIL_PASSWORD
        echo ""
        read -s -p "  Confirm Password: " _email_confirm_input
        echo ""
        if [[ "$CHANNEL_EMAIL_PASSWORD" == "$_email_confirm_input" && -n "$CHANNEL_EMAIL_PASSWORD" ]]; then
            break
        fi
        warn "Passwords did not match (or were empty). Try again."
    done
    unset _email_confirm_input

    ok "Email channel: ${CHANNEL_EMAIL_USERNAME} via ${CHANNEL_EMAIL_IMAP_HOST}"
fi

if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
    ok "iMessage channel: ${CHANNEL_IMESSAGE_ALLOWED}"
fi

# ── 5. Data sources ───────────────────────────────────────────────
#
# Show which platforms we support, give them clickable links to
# request exports. Keep it SHORT — people don't read walls of text.

# Clickable links. OSC 8 works in iTerm2 but NOT in default Terminal.app
# (shows invisible text). Fall back to showing the URL plainly.
_link() {
    # Usage: _link "https://url" "display text"
    local term_prog="${TERM_PROGRAM:-}"
    if [[ "$term_prog" == "iTerm.app" || "$term_prog" == "WezTerm" || "$term_prog" == "Ghostty" ]]; then
        printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$2"
    else
        # Terminal.app and others: just show the URL
        printf '%s' "$1"
    fi
}

echo ""
echo -e "  ${BOLD}Your data sources${NC}"
echo ""
echo "  Ostler imports from 20 platforms. Request your data exports"
echo "  now — they take 1-3 days to arrive by email. You can do this"
echo "  on your phone while the installer runs."
echo ""
echo -e "  ${GREEN}iCloud Contacts: already exported (${CONTACT_COUNT:-0} contacts)${NC}"
echo ""
echo "  Request these (click to open):"
echo ""
printf "    %-14s %s\n" "LinkedIn"       "$(_link 'https://www.linkedin.com/mypreferences/d/download-my-data' 'Request data')"
printf "    %-14s %s\n" "Facebook"       "$(_link 'https://www.facebook.com/dyi/?referrer=yfi_settings' 'Request data') (select JSON)"
printf "    %-14s %s\n" "Instagram"      "$(_link 'https://accountscenter.instagram.com/info_and_permissions/dyi/' 'Request data') (select JSON)"
printf "    %-14s %s\n" "Google"         "$(_link 'https://takeout.google.com/' 'Google Takeout') (Calendar + Contacts)"
printf "    %-14s %s\n" "Twitter / X"    "$(_link 'https://x.com/settings/download_your_data' 'Request archive')"
printf "    %-14s %s\n" "WhatsApp"       "Settings > Account > Request Account Info"
echo ""
echo "  When your exports arrive, just download them to your"
echo "  Downloads folder. Ostler will find them automatically."
echo ""
echo "  Skip any you do not use. You can always import more later."
echo ""
read -p "  Press Enter to continue: " _

# ── 6. FileVault check (silent if enabled) ─────────────────────────

FV_STATUS=$(fdesetup status 2>/dev/null || echo "unknown")
FV_ENABLED=false
if echo "$FV_STATUS" | grep -q "FileVault is On"; then
    FV_ENABLED=true
else
    warn "FileVault is NOT enabled."
    echo ""
    echo "  FileVault encrypts your entire disk. Without it, anyone"
    echo "  with physical access to your Mac can read your data."
    echo ""
    echo "  Enable it: System Settings > Privacy & Security > FileVault"
    echo ""
    read -p "  Continue without FileVault? (y/N): " FV_CONTINUE
    if [[ "${FV_CONTINUE:-n}" != "y" && "${FV_CONTINUE:-n}" != "Y" ]]; then
        echo "  Enable FileVault first, then re-run this installer."
        exit 1
    fi
fi

fi  # end of SKIP_PHASE2 check (user input questions)

# ── 7. Passphrase ──────────────────────────────────────────────────
# (This section runs on every install -- has its own re-run detection)

# Install the ostler_security package into the Hub venv as a proper
# pip-installable package. Until 2026-04-28 this was a `cp -R` of the
# source dir plus runtime `sys.path.insert` hacks; that left the
# package off PYTHONPATH for any deployed entry point that did not
# patch sys.path itself (CM041 ical-server.py, whatsapp_bridge,
# CM048 ingest.py all silently fell through to plaintext SQLite).
# pyproject.toml in ostler_security/ now declares it as a real
# package with cryptography + pysqlcipher3 as deps; pip handles
# both the install path and the dependency tree.
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SECURITY_CONFIG_DIR"

# Two-zone layout: create the customer's user-facing tree under
# ~/Documents/Ostler/ on first install. Subsequent runs honour
# the sentinel and skip, so a customer who has deliberately
# removed (or renamed) one of the subdirs is not surprised by
# its silent re-creation on the next install.sh run. mkdir -p
# is itself idempotent; the sentinel exists only to express
# "we have already announced this layout to this install".
if [[ ! -f "$USER_TREE_SENTINEL" ]]; then
    info "Creating user-facing content tree at ${USER_FACING_ROOT}/"
    mkdir -p "$USER_FACING_ROOT"
    for sub in "${USER_TREE_SUBDIRS[@]}"; do
        mkdir -p "${USER_FACING_ROOT}/${sub}"
    done
    {
        echo "Ostler user-facing tree created on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "Subdirs: ${USER_TREE_SUBDIRS[*]}"
    } > "$USER_TREE_SENTINEL"
    ok "User-facing tree ready"
else
    info "User-facing tree already announced (sentinel present); skipping"
fi

HAS_SECURITY_MODULE=false
if [[ -d "${SCRIPT_DIR}/ostler_security" && -f "${SCRIPT_DIR}/ostler_security/pyproject.toml" ]]; then
    # macOS Sonoma+ blocks pip3 install to system Python, so use a venv.
    OSTLER_VENV="${OSTLER_DIR}/.venv"
    if [[ ! -d "$OSTLER_VENV" ]]; then
        python3 -m venv "$OSTLER_VENV"
    fi
    OSTLER_PIP="${OSTLER_VENV}/bin/pip"
    OSTLER_PYTHON="${OSTLER_VENV}/bin/python3"

    # pip install the package (drags cryptography + pysqlcipher3 in).
    # Also keep a copy of the source under SECURITY_DIR so other
    # tools that read non-Python assets (e.g. setup wizard reading
    # bip39_english.txt from a known on-disk path) still work; the
    # package_data inclusion in the wheel covers the import path.
    if "$OSTLER_PIP" install --quiet "${SCRIPT_DIR}/ostler_security" 2>/tmp/ostler-pip-install.log; then
        HAS_SECURITY_MODULE=true
        # Mirror the source for diagnostic / read-the-file flows.
        mkdir -p "$SECURITY_DIR"
        cp -R "${SCRIPT_DIR}/ostler_security" "$SECURITY_DIR/"
        # Also pip-install the sibling `legal` package (consent-string
        # constants used by ostler_security.consent + the Rust gates).
        # No runtime deps; safe to install best-effort. If it fails
        # we still continue – the Article 9 / WhatsApp / voice gates
        # raise via consent_cli with a clearer error than a bare
        # ImportError.
        if [[ -d "${SCRIPT_DIR}/legal" && -f "${SCRIPT_DIR}/legal/pyproject.toml" ]]; then
            "$OSTLER_PIP" install --quiet "${SCRIPT_DIR}/legal" 2>/dev/null || \
                warn "Could not install legal/ consent-strings package; continuing"
        fi
        ok "Security module installed into venv"
    else
        # Hard-fail: deployed services (CM041 ical-server, CM041
        # whatsapp-bridge, CM048 ingest) refuse to start at import
        # time without ostler_security. Continuing the install would
        # produce a green "succeeded" summary followed by services
        # that will not boot. Surface the failure now.
        # See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
        if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
            warn "Could not install ostler_security into the Hub venv."
            warn "Encryption + passphrase validation will not work."
            warn "Continuing because --allow-plaintext was passed."
            if [[ -s /tmp/ostler-pip-install.log ]]; then
                warn "pip said:"
                sed -e 's/^/    /' /tmp/ostler-pip-install.log | head -5
            fi
            rm -f /tmp/ostler-pip-install.log
        else
            echo ""
            warn "Could not install ostler_security into the Hub venv."
            warn "Encryption + passphrase validation will not work, and"
            warn "the deployed services refuse to start without them."
            if [[ -s /tmp/ostler-pip-install.log ]]; then
                warn "pip said:"
                sed -e 's/^/    /' /tmp/ostler-pip-install.log | head -5
            fi
            rm -f /tmp/ostler-pip-install.log
            fail "ostler_security install failed. Re-run with --allow-plaintext for dev/CI, or fix the pip error above and retry."
        fi
    fi
fi

# Copy FDA extraction module if available
# FDA_DIR is the PARENT – the package lives at FDA_DIR/ostler_fda/
FDA_DIR="${OSTLER_DIR}/fda-module"
HAS_FDA_MODULE=false
if [[ -d "${SCRIPT_DIR}/ostler_fda" ]]; then
    mkdir -p "$FDA_DIR"
    cp -R "${SCRIPT_DIR}/ostler_fda" "$FDA_DIR/"
    HAS_FDA_MODULE=true
fi

PASSPHRASE=""
RECOVERY_KEY=""

# Check if security is already configured (re-run detection)
if [[ -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
    ok "Security already configured (passphrase set up previously)"
    HAS_SECURITY_MODULE=false  # skip passphrase setup
elif [[ "$HAS_SECURITY_MODULE" == true ]]; then
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Why a strong passphrase matters${NC}"
    echo ""
    echo "  This is not a newsletter signup. Ostler will hold every"
    echo "  relationship, every conversation, every pattern in your life."
    echo "  Think of it like the password for your entire digital soul."
    echo ""
    echo "  We enforce a strong passphrase because the alternative is"
    echo "  someone else being able to read everything about you."
    echo ""
    echo "  Pick something you will remember. A sentence works well:"
    echo "    'mango sunset river telescope'"
    echo "    'my cat hates the vacuum cleaner'"
    echo "    'coffee before nine or everything burns'"
    echo ""
    echo "  Minimum: 16 characters or 4+ words."
    echo ""
    echo -e "  ${RED}If you lose this AND the recovery key, your data is${NC}"
    echo -e "  ${RED}gone forever. We cannot help. That is the point.${NC}"
    echo ""

    while true; do
        read -s -p "  Enter passphrase: " PASSPHRASE
        echo ""

        # Validate using the Python module (use venv Python for cryptography)
        VALIDATE_MSG=$(printf '%s' "$PASSPHRASE" | "$OSTLER_PYTHON" -c "
import sys
from ostler_security.passphrase import validate_passphrase_strength
pp = sys.stdin.read()
ok, msg = validate_passphrase_strength(pp)
if not ok:
    print(msg)
    sys.exit(1)
" 2>&1)
        VALIDATE_EXIT=$?

        if [[ $VALIDATE_EXIT -ne 0 ]]; then
            warn "$VALIDATE_MSG"
            continue
        fi

        read -s -p "  Confirm passphrase: " PASSPHRASE_CONFIRM
        echo ""

        if [[ "$PASSPHRASE" != "$PASSPHRASE_CONFIRM" ]]; then
            warn "Passphrases don't match. Try again."
            continue
        fi

        unset PASSPHRASE_CONFIRM
        ok "Passphrase accepted"
        break
    done
else
    warn "Security module not found. Passphrase setup will be skipped."
    warn "You can run the security setup later: python3 -m ostler_security.setup_wizard"
fi

# ── 8. AI model (automatic) ────────────────────────────────────────

# Model selection based on available RAM.
# MoE models (35B-A3B) have 35B total knowledge but only 3B active params,
# so they need ~23GB of VRAM/RAM but run at 3B speed.
if [[ $RAM_GB -ge 48 ]]; then
    AI_MODEL="qwen3.6:35b-a3b"
    AI_MODEL_SIZE="~23 GB"
elif [[ $RAM_GB -ge 24 ]]; then
    AI_MODEL="qwen3.5:9b"
    AI_MODEL_SIZE="~6.6 GB"
else
    AI_MODEL="gemma4:e2b"
    AI_MODEL_SIZE="~5 GB"
fi

ok "AI model: ${AI_MODEL} (${AI_MODEL_SIZE}) — selected for your ${RAM_GB} GB RAM"
PULL_MODEL="y"

# ── 9. GDPR data exports (auto-detect) ────────────────────────────
# Skip on re-run — user already consented, exports already known.

if [[ "$SKIP_PHASE2" == false ]]; then

EXPORTS_DIR=""
DETECTED_EXPORTS=()

# Scan common locations for recognisable GDPR export files
info "Scanning for GDPR data exports..."
for search_dir in "${HOME}/Downloads" "${HOME}/Desktop" "${HOME}/Documents"; do
    [[ -d "$search_dir" ]] || continue

    # LinkedIn: Connections.csv in a folder
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("LinkedIn: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 3 -name "Connections.csv" -path "*/linkedin*" 2>/dev/null || true)

    # Facebook: folder containing friends.json or friend_requests_received.json
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Facebook: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 4 -name "friends.json" -path "*/facebook*" 2>/dev/null || true)

    # Instagram: followers_and_following directory
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Instagram: $f")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$f")}"
    done < <(find "$search_dir" -maxdepth 3 -type d -name "followers_and_following" 2>/dev/null || true)

    # Google Calendar: .ics files
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Google Calendar: $f")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$f")}"
    done < <(find "$search_dir" -maxdepth 3 -name "*.ics" -size +1k 2>/dev/null | head -3 || true)

    # Twitter: tweet.js in a data directory
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Twitter/X: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 4 -name "tweet.js" -path "*/data/*" 2>/dev/null || true)

    # Google Takeout zip: takeout-YYYYMMDDTHHMMSSZ-N-NNN.zip
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Google Takeout (zip): $f")
        TAKEOUT_ZIP_PATH="${TAKEOUT_ZIP_PATH:-$f}"
    done < <(find "$search_dir" -maxdepth 2 -name "takeout-*.zip" 2>/dev/null || true)

    # Loose Gmail mbox files (already extracted from Takeout)
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Gmail mbox: $f")
        TAKEOUT_MBOX_PATH="${TAKEOUT_MBOX_PATH:-$f}"
    done < <(find "$search_dir" -maxdepth 4 -name "*.mbox" -size +1k 2>/dev/null | head -3 || true)
done

if [[ ${#DETECTED_EXPORTS[@]} -gt 0 ]]; then
    echo ""
    ok "Found ${#DETECTED_EXPORTS[@]} GDPR export(s):"
    for exp in "${DETECTED_EXPORTS[@]}"; do
        echo "     - ${exp}"
    done
    echo ""
    read -p "  Import these during install? (Y/n): " IMPORT_CONFIRM
    if [[ "${IMPORT_CONFIRM:-y}" == "n" || "${IMPORT_CONFIRM:-y}" == "N" ]]; then
        EXPORTS_DIR=""
    fi
else
    echo ""
    info "No GDPR exports found in Downloads, Desktop, or Documents."
    echo "  That is fine — you can import later. Request your data from:"
    echo "     LinkedIn, Facebook, Instagram, Google, Twitter, WhatsApp"
    echo "  Exports typically take 1-3 days to arrive."
    echo ""
    read -p "  Have exports elsewhere? Enter path (or press Enter to skip): " MANUAL_PATH
    if [[ -n "$MANUAL_PATH" ]]; then
        MANUAL_PATH="${MANUAL_PATH/#\~/$HOME}"
        if [[ -d "$MANUAL_PATH" ]]; then
            EXPORTS_DIR="$MANUAL_PATH"
            ok "Found exports at ${EXPORTS_DIR}"
        else
            warn "Directory not found: ${MANUAL_PATH} — skipping import."
        fi
    fi
fi

# Also include the auto-exported iCloud contacts
if [[ -f "${OSTLER_DIR}/imports/icloud-contacts.vcf" ]]; then
    if [[ -z "$EXPORTS_DIR" ]]; then
        EXPORTS_DIR="${OSTLER_DIR}/imports"
    else
        # Copy vCard into the exports dir so the pipeline picks it up
        cp "${OSTLER_DIR}/imports/icloud-contacts.vcf" "${EXPORTS_DIR}/" 2>/dev/null || true
    fi
fi

# ── 9.4 Google Takeout / Gmail mbox (auto-detected) ───────────────
# If we found a Takeout zip or a loose mbox above, offer to import.
# This is the "structural moat" path: read full Gmail content
# without ever holding Google OAuth credentials. See policy §2.
OSTLER_TAKEOUT_PATH=""
if [[ -n "${TAKEOUT_MBOX_PATH:-}" || -n "${TAKEOUT_ZIP_PATH:-}" ]]; then
    echo ""
    if [[ -n "${TAKEOUT_MBOX_PATH:-}" ]]; then
        MBOX_SIZE_MB=$(( $(stat -f%z "${TAKEOUT_MBOX_PATH}" 2>/dev/null || echo 0) / 1048576 ))
        info "Found Gmail mbox at ${TAKEOUT_MBOX_PATH} (${MBOX_SIZE_MB} MB)"
    elif [[ -n "${TAKEOUT_ZIP_PATH:-}" ]]; then
        ZIP_SIZE_MB=$(( $(stat -f%z "${TAKEOUT_ZIP_PATH}" 2>/dev/null || echo 0) / 1048576 ))
        info "Found Google Takeout zip at ${TAKEOUT_ZIP_PATH} (${ZIP_SIZE_MB} MB)"
    fi
    echo ""
    echo "  Ostler can read your full Gmail content from a Takeout export"
    echo "  WITHOUT connecting to Google's API. Your Gmail messages stay on"
    echo "  this machine; Google never sees that Ostler exists."
    echo ""
    read -p "  Import Gmail messages from this Takeout? (Y/n): " TAKEOUT_CONFIRM
    if [[ "${TAKEOUT_CONFIRM:-y}" != "n" && "${TAKEOUT_CONFIRM:-y}" != "N" ]]; then
        if [[ -n "${TAKEOUT_MBOX_PATH:-}" ]]; then
            OSTLER_TAKEOUT_PATH="${TAKEOUT_MBOX_PATH}"
        elif [[ -n "${TAKEOUT_ZIP_PATH:-}" ]]; then
            # Extract the mbox out of the zip into ~/.ostler/imports/takeout/
            TAKEOUT_EXTRACT_DIR="${OSTLER_DIR}/imports/takeout"
            mkdir -p "${TAKEOUT_EXTRACT_DIR}"
            info "Extracting Gmail mbox from Takeout zip (this can take a minute for large archives)..."
            EXTRACTED_MBOX=$(python3 -c "
import sys, zipfile
from pathlib import Path
zip_path = Path('${TAKEOUT_ZIP_PATH}')
dest = Path('${TAKEOUT_EXTRACT_DIR}')
try:
    with zipfile.ZipFile(zip_path, 'r') as zf:
        members = [m for m in zf.namelist() if m.lower().endswith('.mbox')]
        if not members:
            print('', file=sys.stderr)
            sys.exit(1)
        extracted = zf.extract(members[0], dest)
        print(extracted)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
            if [[ -n "$EXTRACTED_MBOX" && -f "$EXTRACTED_MBOX" ]]; then
                OSTLER_TAKEOUT_PATH="$EXTRACTED_MBOX"
                ok "Extracted to ${EXTRACTED_MBOX}"
            else
                warn "Could not extract Gmail mbox from the Takeout zip — skipping."
            fi
        fi
    fi
fi

# ── 9.5 Mac data sources picker (FDA-derived) ─────────────────────
#
# Per-source consent. Each FDA source is opt-in. Photos face data
# (GDPR Art. 9 special-category) is OFF unless the user explicitly
# ticks it. The result is exported as OSTLER_FDA_SOURCES env var,
# which extract_all.py reads in Phase 3.

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Which Mac sources should Ostler learn from?${NC}"
echo ""
echo "  Each source can be turned on or off. You can change these"
echo "  any time later. Sensitive ones (face recognition) are off"
echo "  by default — tick deliberately if you want them."
echo ""

# Detect Apple Mail Gmail-attached accounts to give the user a
# meaningful "Gmail" indicator without Google API integration.
HAS_APPLE_MAIL_GMAIL=false
if [[ -d "${HOME}/Library/Mail" ]]; then
    if find "${HOME}/Library/Mail" -maxdepth 4 -type d -iname "*gmail*" 2>/dev/null | grep -q .; then
        HAS_APPLE_MAIL_GMAIL=true
    fi
fi

cat <<MENU

  Three presets, or pick each one yourself:

    [1] Recommended  Safari history + bookmarks, Notes, Calendar,
                     Reminders. Fast, privacy-friendly defaults.

    [2] Everything   The above + iMessage, Apple Mail, Photos events
                     (NOT face recognition). Slower, more depth.

    [3] Customise    Pick each source individually.

MENU

read -p "  Choose 1, 2, or 3 (or press Enter for [1]): " PRESET
PRESET=${PRESET:-1}

# Default sets
RECOMMENDED="safari_history,safari_bookmarks,apple_notes,calendar,reminders"
EVERYTHING="${RECOMMENDED},imessage,apple_mail,photos_metadata"

case "$PRESET" in
    1)
        OSTLER_FDA_SOURCES="$RECOMMENDED"
        ok "Recommended sources selected"
        ;;
    2)
        OSTLER_FDA_SOURCES="$EVERYTHING"
        ok "All sources selected (face recognition still off)"
        ;;
    3)
        # Per-source loop. Each line: prompt with default, default set
        # by the second argument. Anything other than 'n'/'N' keeps default.
        ENABLED=()
        _ask_source() {
            # $1 = source name, $2 = display label, $3 = default (Y/N)
            local default="$3"
            local prompt_default
            if [[ "$default" == "Y" ]]; then prompt_default="Y/n"; else prompt_default="y/N"; fi
            read -p "  $2 [$prompt_default]: " ans
            ans="${ans:-$default}"
            if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
                ENABLED+=("$1")
            fi
        }
        echo ""
        echo "  Recommended (defaults on):"
        _ask_source "safari_history"   "Safari history          " Y
        _ask_source "safari_bookmarks" "Safari bookmarks        " Y
        _ask_source "apple_notes"      "Apple Notes             " Y
        _ask_source "calendar"         "Calendar                " Y
        _ask_source "reminders"        "Reminders               " Y
        echo ""
        echo "  Personal correspondence (default off — third-party content):"
        _ask_source "imessage"         "iMessage                " N
        if [[ "$HAS_APPLE_MAIL_GMAIL" == true ]]; then
            _ask_source "apple_mail" "Apple Mail (incl. Gmail)" N
        else
            _ask_source "apple_mail" "Apple Mail              " N
        fi
        _ask_source "photos_metadata"  "Photos events (no faces)" N
        echo ""
        echo "  Special-category data (default off — explicit consent required):"
        _ask_source "photos_faces" "Photos face recognition (Art. 9)" N
        # Build comma-separated list
        IFS=','
        OSTLER_FDA_SOURCES="${ENABLED[*]}"
        unset IFS
        ;;
    *)
        warn "Unrecognised choice. Using Recommended."
        OSTLER_FDA_SOURCES="$RECOMMENDED"
        ;;
esac

# If a Takeout import was confirmed in section 9.4, add google_takeout
# to the enabled sources list. Done AFTER the case so it covers all
# presets including Customise (where the user might forget to tick it).
if [[ -n "${OSTLER_TAKEOUT_PATH:-}" ]]; then
    if [[ -z "${OSTLER_FDA_SOURCES:-}" ]]; then
        OSTLER_FDA_SOURCES="google_takeout"
    elif [[ "${OSTLER_FDA_SOURCES}" != *"google_takeout"* ]]; then
        OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES},google_takeout"
    fi
fi

echo ""
echo "  Enabled sources: ${OSTLER_FDA_SOURCES//,/, }"

if [[ "$HAS_APPLE_MAIL_GMAIL" == false && "$OSTLER_FDA_SOURCES" == *"apple_mail"* ]]; then
    info "Tip: to include your Gmail, add it to Mac Mail first"
    info "(System Settings > Internet Accounts). Ostler reads from Mail's"
    info "local store – Google never sees that Ostler exists."
fi

# ── 10. Consent ───────────────────────────────────────────────────
#
# Two-branch flow per A8 (locked 2026-05-02):
#   - EU/EEA: Article 9 explicit-consent screen, verbatim wording
#     mirrored in legal/consent_strings.py (ARTICLE_9_EU_CONSENT).
#     Decline cleanly aborts and leaves no ~/.ostler/ residue.
#   - UK / US / RoW: legacy INSTALL/CANCEL block.
# Decision is held in OSTLER_CONSENT_ARTICLE_9_DECISION until Phase 3
# pip-installs ostler_security; we then persist via consent_cli.

OSTLER_CONSENT_ARTICLE_9_DECISION=""
OSTLER_CONSENT_VOICE_EU_DECISION=""
OSTLER_CONSENT_THIRD_PARTY_DECISION=""

if [[ "$OSTLER_REGION" == "eu" ]]; then
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}One last thing – what Ostler will look at on your Mac${NC}  ${YELLOW}[DRAFT - pending legal review]${NC}"
    echo ""
    echo "  Ostler is a personal assistant, so it works by looking at the"
    echo "  parts of your life you keep on this Mac. Some of that is"
    echo "  sensitive. UK and EU privacy law requires us to ask you, in"
    echo "  clear words, before we touch any of it."
    echo ""
    echo -e "  ${BOLD}Where the data lives.${NC} Everything Ostler reads stays on this"
    echo "  Mac, in encrypted folders only you can unlock. We never get a"
    echo "  copy. There is no \"cloud\" version of your data."
    echo ""
    echo -e "  ${BOLD}What's in scope.${NC} Depending on which connectors you turn on,"
    echo "  Ostler may process the following kinds of information that the"
    echo "  law treats as \"special category\" data:"
    echo ""
    echo "    - Health information mentioned in emails, messages, calendar"
    echo "      entries or recorded conversations"
    echo "    - Religious or philosophical beliefs"
    echo "    - Sexual orientation"
    echo "    - Trade union membership"
    echo "    - Voice recordings, used only to label *who* is speaking on"
    echo "      calls (speaker identification). We do not infer mood,"
    echo "      emotion, sentiment, stress or deception from voice."
    echo "    - Mentions of criminal offences – your own or other people's"
    echo ""
    echo "  We do not perform emotion recognition. If that ever changes we"
    echo "  will ask you again, separately, on a new consent screen."
    echo ""
    echo "  All of this stays on your Mac. None of it is sent to Creative"
    echo "  Machines or any third party, except in the specific cases listed"
    echo "  in our Privacy Policy at ostler.ai/privacy."
    echo ""
    echo -e "  ${BOLD}You can change your mind any time.${NC} Turn individual connectors"
    echo "  off in Settings, delete everything via \"Reset Ostler\", or"
    echo "  fully uninstall via ~/Documents/Ostler/Uninstall Ostler.app."
    echo ""
    echo "  Withdrawing consent stops processing from that point forward. It"
    echo "  does not undo work Ostler already did with your earlier consent."
    echo ""
    echo "  Your decision:"
    echo ""
    echo "    [Y] I consent to Ostler processing the categories of personal"
    echo "        data above, locally on this Mac, for the purpose of"
    echo "        running my personal assistant. (continues the install)"
    echo ""
    echo "    [N] I do not consent. (cancels and removes the installer;"
    echo "        nothing is stored on this Mac)"
    echo ""
    while true; do
        read -p "  Your decision (Y / N): " ART9
        case "${ART9:-}" in
            y|Y)
                OSTLER_CONSENT_ARTICLE_9_DECISION="accepted"
                break
                ;;
            n|N)
                OSTLER_CONSENT_ARTICLE_9_DECISION="declined"
                # Article 9 invariant (b): leaves no ~/.ostler/ residue.
                # At this point in Phase 2, the only thing that may have
                # touched ~/.ostler/ is the contacts export under
                # ~/.ostler/imports/. Wipe the lot.
                if [[ -d "$OSTLER_DIR" ]]; then
                    rm -rf "$OSTLER_DIR" 2>/dev/null || true
                fi
                unset PASSPHRASE 2>/dev/null || true
                echo ""
                echo "  No problem. Nothing has been installed and nothing was"
                echo "  written to your Mac."
                echo ""
                echo "  If you change your mind, re-run the installer."
                exit 0
                ;;
            *)
                echo "  Please answer Y or N."
                ;;
        esac
    done

    # ── 10b. EU voice consent gate ────────────────────────────────
    #
    # Speaker-ID only. v0.1 does NOT do emotion inference - the
    # scope field on the consent record carries
    # "speaker_identification_only" so a future emotion feature
    # cannot quietly reuse this consent.
    #
    # Decline does NOT abort the install. It just keeps cm041 voice
    # ingestion off. The Rust gate at cm041 startup honours the
    # decision (refuses to start WhisperKit when EU + declined).
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Recognising voices on calls${NC}  ${YELLOW}[DRAFT - pending legal review]${NC}"
    echo ""
    echo "  Ostler can label transcripts with who is speaking – for"
    echo "  example, \"Andy\", \"Alison\" – by storing a numeric"
    echo "  fingerprint of each voice locally on this Mac. Under UK and"
    echo "  EU privacy law this is biometric data, so we have to ask"
    echo "  first."
    echo ""
    echo -e "  ${BOLD}What we do.${NC} Identify *who* is speaking on a recording you make."
    echo -e "  ${BOLD}What we do not do.${NC} Detect mood, emotion, sentiment, stress"
    echo "  or any other inferred psychological state from voice."
    echo ""
    echo "  The fingerprints stay on this Mac. We never receive them. You"
    echo "  can turn this off any time in Settings -> Privacy -> Voice"
    echo "  recognition; turning it off deletes any fingerprints already"
    echo "  stored."
    echo ""
    while true; do
        read -p "  Recognise voices on your call recordings? (Y/n): " VOICE
        case "${VOICE:-y}" in
            y|Y|"")
                OSTLER_CONSENT_VOICE_EU_DECISION="accepted"
                break
                ;;
            n|N)
                OSTLER_CONSENT_VOICE_EU_DECISION="declined"
                info "Voice recognition will stay off. You can enable later in Settings."
                break
                ;;
            *) echo "  Please answer Y or N." ;;
        esac
    done
fi

# ── 10b.5 Third-party-data acknowledgement (every region) ────────
#
# Caveat 1 of /tmp/tnm_brief_three_caveats_2026-05-03.md. Region-
# agnostic mandatory consent. Mitigates the "we have records of
# people who never consented" surface (inbox / contacts / messages /
# photos / calendar attendees) by capturing explicit user
# acknowledgement that they are processing this data as a private
# personal-records keeper.
#
# Wording is verbatim from legal/consent_strings.py
# (THIRD_PARTY_DATA_NOTICE) and flagged [DRAFT - pending legal review].
# Decision is held in OSTLER_CONSENT_THIRD_PARTY_DECISION until
# Phase 3 pip-installs ostler_security; we then persist via consent_cli
# alongside Article 9 and the WhatsApp / voice tickboxes.
#
# Decline behaviour mirrors Article 9: cannot continue. Clean abort
# + rm -rf ~/.ostler/ to leave no residue. The third-party data is
# the entire reason Ostler exists; declining means the user is not
# willing to keep these records, and the install should not proceed.

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}About the data on your Mac that's not just yours${NC}  ${YELLOW}[DRAFT - pending legal review]${NC}"
echo ""
echo "  Ostler reads parts of your life that contain information about"
echo "  other people – emails they sent you, messages they wrote, faces"
echo "  in your photos, contact details, calendar attendees. This is"
echo "  normal. It's your inbox, your contacts, your life as it actually"
echo "  exists."
echo ""
echo "  Everything stays on this Mac. Creative Machines never receives"
echo "  any of it. There is no cloud account holding it."
echo ""
echo -e "  ${BOLD}Before you continue, please understand:${NC}"
echo ""
echo "    - You are keeping these records for yourself, like a private"
echo "      address book, a personal diary, or a journal. Ostler is the"
echo "      tool that helps you organise and search what you already"
echo "      have. You decide what to keep and what to delete."
echo ""
echo "    - Specific requests to be removed. If anyone you have records"
echo "      of asks you to be removed, you can delete that person from"
echo "      Ostler entirely (Settings -> People -> Delete a person). The"
echo "      deletion removes their data from your wiki, your graph,"
echo "      your search index, and your assistant's memory."
echo ""
echo "    - Nothing leaves your Mac. Not to us, not to a cloud, not to"
echo "      a third party – except in the specific cases listed in our"
echo "      Privacy Policy at ostler.ai/privacy (mainly: optional cloud"
echo "      routing for non-personal questions, software update checks,"
echo "      public metadata enrichment)."
echo ""
echo "  Read more at docs.ostler.ai/privacy/third-party-data."
echo ""
echo "  Your decision:"
echo ""
echo "    [Y] I understand. Continue."
echo "    [N] I do not consent. (cancels and removes the installer;"
echo "        nothing is stored on this Mac)"
echo ""
while true; do
    read -p "  Your decision (Y / N): " THIRD_PARTY
    case "${THIRD_PARTY:-}" in
        y|Y)
            OSTLER_CONSENT_THIRD_PARTY_DECISION="accepted"
            break
            ;;
        n|N)
            OSTLER_CONSENT_THIRD_PARTY_DECISION="declined"
            # Mirror Article 9 decline: leave no ~/.ostler/ residue.
            # By this point Phase 2 may have written the contacts
            # export under ~/.ostler/imports/; wipe the lot.
            if [[ -d "$OSTLER_DIR" ]]; then
                rm -rf "$OSTLER_DIR" 2>/dev/null || true
            fi
            unset PASSPHRASE 2>/dev/null || true
            echo ""
            echo "  No problem. Nothing has been installed and nothing was"
            echo "  written to your Mac."
            echo ""
            echo "  If you change your mind, re-run the installer."
            exit 0
            ;;
        *)
            echo "  Please answer Y or N."
            ;;
    esac
done

# ── 10c. Final install confirmation (every region) ────────────────

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Before we begin${NC}"
echo ""
echo "  Ostler will now install the following on this Mac:"
echo ""
echo "    - Docker containers via Colima (Qdrant, Oxigraph, Redis)"
echo "    - Ollama with ${AI_MODEL} (${AI_MODEL_SIZE})"
echo "    - Encryption for all stored data"
echo "    - Export watcher (scans Downloads for GDPR exports)"
[[ "${CONTACT_COUNT:-0}" -gt 0 ]] && \
echo "    - Import ${CONTACT_COUNT} contacts from iCloud"
[[ -n "$EXPORTS_DIR" ]] && \
echo "    - Import GDPR exports from ${EXPORTS_DIR}"
echo "    - Import from your selected Mac sources (above)"
echo ""
echo "  Your personal data stays on this machine. Ostler makes only narrow"
echo "  outbound queries for public-data enrichment and local web search"
echo "  (Vane + SearXNG, bundled), plus model/software updates. Full detail"
echo "  in the privacy policy."
echo "  You can remove everything at any time with: ostler-uninstall"
echo ""
echo -e "  ${BOLD}By continuing, you confirm:${NC}"
echo "    1. You are 18 or older"
echo "    2. You understand what Ostler stores and how"
echo "    3. You have set a passphrase you will remember"
echo "    4. You accept the terms at creativemachines.ai/ostler/terms"
echo ""

while true; do
    read -p "  Type INSTALL to proceed (or CANCEL to quit): " CONSENT
    if [[ "$CONSENT" == "INSTALL" ]]; then
        break
    elif [[ "$CONSENT" == "CANCEL" || "$CONSENT" == "cancel" ]]; then
        unset PASSPHRASE 2>/dev/null || true
        echo ""
        echo "  No problem. Nothing has been installed."
        echo "  Re-run the installer when you are ready."
        exit 0
    else
        echo ""
        echo "  Please type INSTALL (in capitals) to continue, or CANCEL to quit."
        echo ""
    fi
done

fi  # end of SKIP_PHASE2 check (GDPR scan + consent)

# ══════════════════════════════════════════════════════════════════════
#  PHASE 3: INSTALL EVERYTHING (unattended — user can walk away)
# ══════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Batch the sudo prompts at the end of Phase 2 so the unattended Phase 3
# is genuinely unattended. macOS sudo timestamp lasts ~5 minutes; both
# Phase-3.0 (pmset) and Homebrew's own sudo calls land well within that
# window so the user is not interrupted mid-install. This was the audit's
# top "walk away" complaint (~2026-05-01).
echo -e "  ${YELLOW}One-time password prompt: macOS needs your Mac password to disable${NC}"
echo -e "  ${YELLOW}sleep during the install (and to install Homebrew if missing).${NC}"
echo -e "  ${YELLOW}After this, the install runs unattended.${NC}"
echo ""
sudo -v || fail "Need sudo access to disable sleep + install Homebrew. Re-run when ready."
# Refresh the sudo timestamp every 60s while this script runs, so a long
# Phase 3 (e.g. slow ollama pull) does not silently expire it.
( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT

echo ""
echo -e "  ${GREEN}${BOLD}  All questions answered. Installing now.${NC}"
NEEDS_HOMEBREW=false
if ! command -v brew &>/dev/null; then
    NEEDS_HOMEBREW=true
else
    echo -e "  ${GREEN}  You can walk away — this takes about 10-15 minutes.${NC}"
fi
echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

PHASE3_START=$(date +%s)

# ── Progress bar ───────────────────────────────────────────────────

# Count steps dynamically based on what we're actually going to do
TOTAL_STEPS=9  # Homebrew, Docker, Ollama, Config, Security, FDA, Databases, Models, Pipeline
[[ -n "$EXPORTS_DIR" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))  # GDPR import
TOTAL_STEPS=$((TOTAL_STEPS + 1))  # Doctor
CURRENT_STEP=0

progress() {
    # Usage: progress "What is happening right now"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PCT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local BAR_WIDTH=30
    local FILLED=$((PCT * BAR_WIDTH / 100))
    local EMPTY=$((BAR_WIDTH - FILLED))
    local BAR=$(printf "%${FILLED}s" | tr ' ' '█')$(printf "%${EMPTY}s" | tr ' ' '░')

    # Calculate elapsed time and estimate remaining
    local NOW=$(date +%s)
    local ELAPSED=$((NOW - PHASE3_START))
    local ETA=""
    if [[ $CURRENT_STEP -gt 1 && $PCT -gt 0 ]]; then
        local TOTAL_EST=$((ELAPSED * 100 / PCT))
        local REMAIN=$((TOTAL_EST - ELAPSED))
        if [[ $REMAIN -gt 60 ]]; then
            ETA=" (~$((REMAIN / 60))m remaining)"
        elif [[ $REMAIN -gt 0 ]]; then
            ETA=" (~${REMAIN}s remaining)"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}[${BAR}] ${PCT}%${ETA}${NC}"
    echo -e "  ${BLUE}$1${NC}"
    echo ""
}

# ── 3.1 Homebrew ───────────────────────────────────────────────────

# ── 3.0 Prevent sleep ─────────────────────────────────────────────
# A personal knowledge system needs to be always-on for background
# tasks (export watcher, FDA re-runs, AI assistant). Disable sleep
# so the Mac stays awake even when the display is off.
# This requires admin privileges (sudo) which the user already has
# from the Homebrew install step.
#
# Battery-aware: on a MacBook Hub we only set never-sleep when on AC.
# On battery we preserve default sleep so the hub-power LaunchAgent
# (step 3.14) can manage the sleep -> wake transition and bring
# services back cleanly. Mac Mini / Studio installs keep the
# original always-on behaviour.

HAS_BATTERY=false
if pmset -g batt 2>/dev/null | grep -qE '[0-9]+%'; then
    HAS_BATTERY=true
fi

SLEEP_SETTING=$(pmset -g | grep '^ sleep' | awk '{print $2}' 2>/dev/null || echo "")
if [[ "$SLEEP_SETTING" != "0" ]]; then
    if [[ "$HAS_BATTERY" == true ]]; then
        info "MacBook Hub detected: setting never-sleep on AC only (hub-power handles battery transitions)"
        sudo pmset -c sleep 0 2>/dev/null && \
        sudo pmset -a womp 1 2>/dev/null && \
        ok "Sleep disabled on AC, battery sleep preserved, wake-on-network enabled" || \
        warn "Could not change sleep settings. Enable 'Prevent automatic sleeping when plugged in' in System Settings > Energy."
    else
        info "Desktop Hub (no battery) detected: disabling sleep system-wide"
        sudo pmset -a sleep 0 2>/dev/null && \
        sudo pmset -a womp 1 2>/dev/null && \
        ok "Sleep disabled, wake-on-network enabled" || \
        warn "Could not change sleep settings. Enable 'Prevent automatic sleeping' in System Settings > Energy."
    fi
fi

# ── 3.0a Phase 3 battery watcher ───────────────────────────────────
# The hub-power LaunchAgent that pauses Docker / Ollama on battery is
# not installed until step 3.14, so during Phase 3 itself the user is
# unprotected: a Mac that starts on AC and gets unplugged mid-install
# will silently stall on the next Docker pull or Ollama download.
#
# Spawn a background watcher for MacBook installs that polls power
# state every 60 seconds and prints a visible warning on a battery
# transition. Cheap (one pmset call/min); the EXIT trap kills it
# before the script returns; Phase 4 also kills it explicitly so the
# health check output is not interleaved with stale poll messages.
PHASE3_BATTERY_WATCH_PID=""
cleanup_battery_watch() {
    if [[ -n "$PHASE3_BATTERY_WATCH_PID" ]]; then
        kill "$PHASE3_BATTERY_WATCH_PID" 2>/dev/null || true
        PHASE3_BATTERY_WATCH_PID=""
    fi
}
trap cleanup_battery_watch EXIT

if [[ "$HAS_BATTERY" == true ]]; then
    (
        last_seen="ac"
        while true; do
            sleep 60
            current=$(pmset -g batt 2>/dev/null | grep -oE "'(AC Power|Battery Power)'" | head -1 | tr -d "'" || echo "unknown")
            case "$current" in
                "Battery Power")
                    if [[ "$last_seen" != "battery" ]]; then
                        echo ""
                        echo -e "${YELLOW}[warn]${NC} You're now on battery power."
                        echo -e "${YELLOW}[warn]${NC} The Hub power LaunchAgent isn't installed yet (step 3.14)."
                        echo -e "${YELLOW}[warn]${NC} Phase 3 may stall on Docker pulls or Ollama downloads."
                        echo -e "${YELLOW}[warn]${NC} Plug back into AC to keep things moving."
                        echo ""
                        last_seen="battery"
                    fi
                    ;;
                "AC Power")
                    if [[ "$last_seen" == "battery" ]]; then
                        echo ""
                        echo -e "${GREEN}[ok]${NC} Back on AC. Continuing."
                        echo ""
                        last_seen="ac"
                    fi
                    ;;
            esac
        done
    ) &
    PHASE3_BATTERY_WATCH_PID=$!
    info "Phase 3 battery watcher armed (PID $PHASE3_BATTERY_WATCH_PID)"
fi

progress "Checking Homebrew and system tools"

if command -v brew &>/dev/null; then
    ok "Homebrew installed"
else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ "$ARCH" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
fi

# ── 3.2 Docker ─────────────────────────────────────────────────────

progress "Starting Docker"

if [[ "$HAS_DOCKER" == true ]]; then
    ok "Docker running"
else
    # Prefer Colima over Docker Desktop. Colima is headless (no EULA, no
    # account signup, no system extension dialogs) and works perfectly for
    # running containers on macOS. Docker Desktop is a fallback.
    if ! command -v docker &>/dev/null; then
        info "Installing Colima + Docker CLI..."
        brew install colima docker docker-compose
        # Re-eval Homebrew PATH so newly installed commands are found
        if [[ -x /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        ok "Colima and Docker CLI installed"
    fi

    # Check if Colima or Docker Desktop can provide a runtime
    # Ensure docker-compose plugin is discoverable (Colima needs this)
    if [[ ! -f "${HOME}/.docker/config.json" ]] || ! grep -q "cliPluginsExtraDirs" "${HOME}/.docker/config.json" 2>/dev/null; then
        mkdir -p "${HOME}/.docker"
        echo '{"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]}' > "${HOME}/.docker/config.json"
    fi

    if command -v colima &>/dev/null; then
        # Colima uses its own Docker socket — tell Docker CLI where to find it
        export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

        if ! docker info &>/dev/null 2>&1; then
            info "Starting Colima (lightweight Docker runtime)..."
            # Allocate enough resources for 3 containers
            colima start --cpu 2 --memory 4 --disk 30 2>/dev/null || {
                warn "Colima failed to start. Trying Docker Desktop as fallback..."
                if [[ -d "/Applications/Docker.app" ]]; then
                    open -a Docker 2>/dev/null || true
                else
                    fail "Neither Colima nor Docker Desktop could start. Install Docker Desktop and re-run."
                fi
            }
        fi
    elif [[ -d "/Applications/Docker.app" ]]; then
        # Docker Desktop is installed but not running
        info "Starting Docker Desktop..."
        echo ""
        echo "  If this is Docker's first run, it may show several dialogs:"
        echo "    - Accept the licence agreement"
        echo "    - Allow the system extension (if prompted)"
        echo "    - Skip sign-in (you don't need a Docker account)"
        echo "    - Close any welcome/survey screens"
        echo ""
        open -a Docker 2>/dev/null || true
    else
        fail "Docker not available. Re-run the installer to install Colima."
    fi

    # Wait for Docker to be ready (Colima or Desktop)
    DOCKER_WAIT=0
    DOCKER_TIMEOUT=300
    while ! docker info &>/dev/null 2>&1; do
        if [[ $DOCKER_WAIT -ge $DOCKER_TIMEOUT ]]; then
            warn "Docker did not start within ${DOCKER_TIMEOUT} seconds."
            echo ""
            echo "  If using Docker Desktop, complete any setup dialogs and re-run."
            echo "  If using Colima, try: colima start"
            exit 1
        fi
        sleep 3
        DOCKER_WAIT=$((DOCKER_WAIT + 3))
        printf "  Waiting for Docker... (%ds)\r" $DOCKER_WAIT
    done
    echo ""
    ok "Docker running (took ${DOCKER_WAIT}s)"

    # Set up Colima auto-start on boot (if using Colima)
    if command -v colima &>/dev/null && colima status 2>/dev/null | grep -q "Running"; then
        COLIMA_PLIST="${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
        if [[ ! -f "$COLIMA_PLIST" ]]; then
            mkdir -p "${HOME}/Library/LaunchAgents"
            cat > "$COLIMA_PLIST" <<COLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.colima</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which colima)</string>
        <string>start</string>
        <string>--cpu</string>
        <string>2</string>
        <string>--memory</string>
        <string>4</string>
        <string>--disk</string>
        <string>30</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/colima.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/colima.err</string>
</dict>
</plist>
COLEOF
            launchctl bootstrap "gui/$(id -u)" "$COLIMA_PLIST" 2>/dev/null || \
                launchctl load "$COLIMA_PLIST" 2>/dev/null || true
            ok "Colima will start automatically on boot"
        fi
    fi
fi

# ── 3.3 Ollama ─────────────────────────────────────────────────────

progress "Setting up Ollama (local AI engine)"

if command -v ollama &>/dev/null; then
    ok "Ollama installed"
else
    # Install the cask (GUI app) not the formula (CLI only).
    # The cask auto-starts Ollama on boot via launchd.
    # The formula requires manual `ollama serve` after every reboot.
    info "Installing Ollama..."
    if brew install --cask ollama 2>/dev/null; then
        ok "Ollama installed (desktop app)"
    else
        # Fallback to CLI formula if cask fails
        brew install ollama
        ok "Ollama installed (CLI only -- may need manual start after reboot)"
    fi
fi

if curl -s http://localhost:11434/api/tags &>/dev/null; then
    ok "Ollama running"
else
    info "Starting Ollama..."
    # Try launching the app first (persists across reboots).
    # -gj: start in background, hidden — it's a daemon, no UI needed.
    open -gj -a Ollama 2>/dev/null || ollama serve &>/dev/null &
    # Wait up to 30 seconds for Ollama to be ready
    OLLAMA_WAIT=0
    while ! curl -s http://localhost:11434/api/tags &>/dev/null; do
        if [[ $OLLAMA_WAIT -ge 90 ]]; then
            warn "Could not start Ollama automatically."
            echo "  macOS may have asked you to approve Ollama."
            echo "  Open Ollama from Applications, approve any dialogs, then re-run."
            exit 1
        fi
        sleep 2
        OLLAMA_WAIT=$((OLLAMA_WAIT + 2))
    done
    ok "Ollama running"
fi

# ── 3.4 Python check ──────────────────────────────────────────────

NEED_PYTHON=false
if command -v python3 &>/dev/null; then
    PY_VERSION=$(python3 --version | cut -d' ' -f2)
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [[ $PY_MAJOR -ge 3 && $PY_MINOR -ge 10 ]]; then
        ok "Python ${PY_VERSION}"
    else
        warn "Python ${PY_VERSION} is too old (need 3.10+). Installing Python 3.12..."
        NEED_PYTHON=true
    fi
else
    warn "Python 3 not found. Installing Python 3.12..."
    NEED_PYTHON=true
fi

if [[ "$NEED_PYTHON" == true ]]; then
    brew install python@3.12
    # Homebrew Python is at /opt/homebrew/bin/python3.12
    # Make it the default python3 for this session
    export PATH="/opt/homebrew/opt/python@3.12/bin:$PATH"
    PY_VERSION=$(python3 --version | cut -d' ' -f2)
    ok "Python ${PY_VERSION} installed"
fi

# ── 3.5 Write config ──────────────────────────────────────────────

progress "Saving your configuration"

cat > "${CONFIG_DIR}/.env" <<ENVEOF
# Ostler configuration – generated by installer
USER_ID="${USER_ID}"
USER_NAME="${USER_NAME}"
ASSISTANT_NAME="${ASSISTANT_NAME}"
TIMEZONE="${USER_TZ}"

# Storage services (Docker containers on localhost)
OXIGRAPH_URL=http://localhost:7878
QDRANT_URL=http://localhost:6333
REDIS_URL=redis://localhost:6379

# Embedding
EMBED_OLLAMA_URL=http://localhost:11434
EMBED_MODEL=nomic-embed-text
EMBED_BATCH_SIZE=50

# Defaults
DEFAULT_COUNTRY_CODE=${COUNTRY_CODE}
DEFAULT_PRIVACY_LEVEL=L2

# Per-source FDA consent – comma-separated list of enabled sources.
# Set in Phase 2 (or read from a previous install on re-run). Read by
# ostler_fda.extract_all via the OSTLER_FDA_SOURCES env var.
OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES:-safari_history,safari_bookmarks,apple_notes,calendar,reminders}"

# If a Google Takeout mbox is registered, point extract_all at it.
OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}"

# Tailscale IPv4 for this Mac. Set in 3.14 by the installer if Tailscale
# was installed and signed in. Used by the iOS / Watch companion to reach
# this Mac from anywhere. Empty if Tailscale is not in use.
OSTLER_TAILSCALE_IP="${OSTLER_TAILSCALE_IP:-}"
ENVEOF

ok "Config saved to ${CONFIG_DIR}/.env"

# ── 3.5b Assistant config (channels TOML) ──────────────────────────
#
# Persists the channel choices captured by the section 4a wizard
# into ${OSTLER_DIR}/assistant-config/config.toml. Loaded at runtime
# by the ostler-assistant binary (Phase C, separate PR drops the
# binary at ${OSTLER_DIR}/bin/ostler-assistant) once the
# ZEROCLAW_WORKSPACE env var is set to ${OSTLER_DIR}/assistant-config
# in the LaunchAgent.
#
# Format follows the schema in
# crates/zeroclaw-config/src/{schema.rs,scattered_types.rs}. Sections
# only emitted for enabled channels, so a "skip for now" install
# produces an empty config that the assistant will treat as
# defaults.
#
# Password handling: written in plaintext. The assistant supports
# `enc2:` ciphertext for sensitive fields but cannot encrypt before
# its own first run. Mode 0600 limits exposure to this user.
# Phase C should add a post-install `ostler-assistant secrets
# encrypt-config` step once the binary is staged so the plaintext
# window closes within the install flow.

ASSISTANT_CONFIG_DIR="${OSTLER_DIR}/assistant-config"
mkdir -p "$ASSISTANT_CONFIG_DIR"
ASSISTANT_CONFIG="${ASSISTANT_CONFIG_DIR}/config.toml"
umask_orig=$(umask)
umask 0077
{
    cat <<'TOMLPREAMBLE'
# Ostler assistant configuration.
#
# Generated by the Ostler installer. Edit by hand or re-run the
# installer to regenerate. Sensitive fields (e.g. email password)
# are stored in plaintext until the assistant first runs and
# encrypts them in place with the `enc2:` ChaCha20-Poly1305
# scheme. See crates/zeroclaw-config/src/secrets.rs for details.

# Schema version this file was written against. Matches
# CURRENT_SCHEMA_VERSION in crates/zeroclaw-config/src/migration.rs
# at install time so the assistant doesn't trigger a no-op
# migration on first load.
schema_version = 2
TOMLPREAMBLE

    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true || "$CHANNEL_EMAIL_ENABLED" == true ]]; then
        echo
        echo "[channels]"
    fi

    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
        echo
        echo "[channels.imessage]"
        echo "enabled = true"
        echo -n 'allowed_contacts = ['
        # Convert the comma-separated bash string into a TOML array of
        # quoted strings. Trim whitespace around each entry so the
        # user can put spaces between commas.
        first=true
        IFS=',' read -ra _imsg_arr <<< "$CHANNEL_IMESSAGE_ALLOWED"
        for entry in "${_imsg_arr[@]}"; do
            entry="${entry# }"; entry="${entry% }"
            entry="${entry//\"/\\\"}"
            if [[ "$first" == true ]]; then first=false; else echo -n ', '; fi
            echo -n "\"$entry\""
        done
        echo "]"
    fi

    if [[ "$CHANNEL_EMAIL_ENABLED" == true ]]; then
        # Escape any embedded double quotes in email fields so a
        # provider hostname with weird characters can't break the
        # TOML.
        _esc() { printf '%s' "$1" | sed 's/"/\\"/g'; }
        echo
        echo "[channels.email]"
        echo "enabled = true"
        echo "imap_host = \"$(_esc "$CHANNEL_EMAIL_IMAP_HOST")\""
        echo "imap_port = ${CHANNEL_EMAIL_IMAP_PORT}"
        echo "imap_folder = \"INBOX\""
        echo "smtp_host = \"$(_esc "$CHANNEL_EMAIL_SMTP_HOST")\""
        echo "smtp_port = ${CHANNEL_EMAIL_SMTP_PORT}"
        echo "smtp_tls = true"
        echo "username = \"$(_esc "$CHANNEL_EMAIL_USERNAME")\""
        echo "password = \"$(_esc "$CHANNEL_EMAIL_PASSWORD")\""
        echo "from_address = \"$(_esc "$CHANNEL_EMAIL_FROM")\""
        echo "allowed_senders = []"
    fi
} > "$ASSISTANT_CONFIG"
chmod 600 "$ASSISTANT_CONFIG"
umask "$umask_orig"

# Scrub the plaintext password from the bash environment as soon as
# the file is written. The TOML still has it on disk; this just
# narrows the in-memory exposure for the rest of the install.
unset CHANNEL_EMAIL_PASSWORD

if [[ "$CHANNEL_IMESSAGE_ENABLED" == true || "$CHANNEL_EMAIL_ENABLED" == true ]]; then
    ok "Assistant config saved to ${ASSISTANT_CONFIG} (mode 0600)"
else
    info "No channels configured. Run later: ${OSTLER_DIR}/bin/ostler-assistant setup channels --interactive"
fi

# ── 3.6 Security setup ────────────────────────────────────────────

progress "Encrypting your databases"

# Install SQLCipher
if ! brew list sqlcipher &>/dev/null 2>&1; then
    info "Installing SQLCipher..."
    brew install sqlcipher
fi

# Venv was created in Phase 2 for passphrase validation.
# Ensure it exists (re-run safe) and install remaining dependencies.
OSTLER_VENV="${OSTLER_DIR}/.venv"
if [[ ! -d "$OSTLER_VENV" ]]; then
    python3 -m venv "$OSTLER_VENV"
fi
OSTLER_PIP="${OSTLER_VENV}/bin/pip"
OSTLER_PYTHON="${OSTLER_VENV}/bin/python3"

info "Installing security Python dependencies..."
"$OSTLER_PIP" install --quiet "cryptography>=46.0.1,<47.0.0" 2>/dev/null || true

export SQLCIPHER_CFLAGS="-I$(brew --prefix sqlcipher)/include"
export SQLCIPHER_LDFLAGS="-L$(brew --prefix sqlcipher)/lib"
"$OSTLER_PIP" install --quiet "pysqlcipher3>=1.2.0,<2.0.0" 2>/dev/null || {
    # See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "pysqlcipher3 install failed. Databases will not be encrypted."
        warn "You may need to install manually: ${OSTLER_PIP} install pysqlcipher3"
        warn "Continuing because --allow-plaintext was passed."
    else
        warn "pysqlcipher3 install failed."
        warn "You may need to install manually: ${OSTLER_PIP} install pysqlcipher3"
        fail "pysqlcipher3 is required for encrypted databases. Re-run with --allow-plaintext for dev/CI, or fix the pip error above and retry."
    fi
}

# Run passphrase setup (using the passphrase collected in Phase 2)
# See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
if [[ -n "$PASSPHRASE" && "$HAS_SECURITY_MODULE" == true ]]; then
    SETUP_OUTPUT=$(printf '%s' "$PASSPHRASE" | "$OSTLER_PYTHON" -c "
import sys, os
from pathlib import Path
passphrase = sys.stdin.read()
try:
    from ostler_security.passphrase import setup_passphrase
    result = setup_passphrase(passphrase, config_dir=Path('${SECURITY_CONFIG_DIR}'))
    print('RECOVERY_KEY=' + result['recovery_key'])
except Exception as e:
    print('ERROR=' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)
    SETUP_EXIT=$?

    # Clear passphrase from shell memory immediately
    unset PASSPHRASE

    if [[ $SETUP_EXIT -ne 0 ]]; then
        if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
            warn "Security setup failed. Continuing without database encryption."
            warn "You can run the security setup later: python3 -m ostler_security.setup_wizard"
            warn "Continuing because --allow-plaintext was passed."
        else
            warn "Security setup failed. Output:"
            echo "$SETUP_OUTPUT" | sed -e 's/^/    /' | head -10
            fail "Passphrase setup failed. Re-run with --allow-plaintext for dev/CI, or fix the error above and retry."
        fi
    else
        RECOVERY_KEY=$(echo "$SETUP_OUTPUT" | grep "^RECOVERY_KEY=" | cut -d= -f2-)
        ok "Databases encrypted. Passphrase required at each startup."
    fi
elif [[ -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
    # Re-run: security already configured in a previous install.
    # This is the legitimate skip path; nothing to do.
    unset PASSPHRASE 2>/dev/null || true
else
    # PASSPHRASE empty or HAS_SECURITY_MODULE=false without an existing
    # keychain. Deployed services refuse to start without encryption,
    # so this would produce a green "succeeded" summary followed by
    # services that will not boot.
    unset PASSPHRASE 2>/dev/null || true
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "No passphrase set; databases will not be encrypted."
        warn "You can run the security setup later: python3 -m ostler_security.setup_wizard"
        warn "Continuing because --allow-plaintext was passed."
    else
        fail "No passphrase set and no existing security configuration. Re-run with --allow-plaintext for dev/CI, or re-run the installer and complete the passphrase prompt."
    fi
fi

# Posture marker for --allow-plaintext installs. Runtime guards in
# CM041 / CM048 will eventually read this to skip the hard-fail in
# dev mode; out of scope to wire that up here.
# See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
if [[ "$ALLOW_PLAINTEXT" == "1" && ! -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
    POSTURE_DIR="${OSTLER_DIR}/security-posture"
    mkdir -p "$POSTURE_DIR"
    POSTURE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "${POSTURE_DIR}/install.json" <<EOF
{
  "encryption": "deliberately_disabled",
  "reason": "--allow-plaintext flag",
  "timestamp": "${POSTURE_TS}"
}
EOF
    info "Wrote posture marker: ${POSTURE_DIR}/install.json"
fi

# ── 3.6b Persist consent + region (A7+A8) ────────────────────────
#
# Now that ostler_security + legal are pip-installed in the Hub
# venv, hand off the consent decisions captured in Phase 2 to the
# Python helper so:
#   - the registry at ~/.ostler/posture/consent.json is written
#     atomically, mode 0600, with the canonical SHA-256 of each
#     wording string from legal/consent_strings.py
#   - the region detection result lands at
#     ~/.ostler/posture/region.json so Doctor + the Rust gates
#     read a single source of truth.
#
# Best-effort: a failure here logs a warning but does NOT abort
# the install. The downstream gates (whatsapp-bridge, cm041
# voice) will refuse to start with a structured error, which is
# the right safety posture (gate stays closed, not silently open).
if [[ "$HAS_SECURITY_MODULE" == true ]]; then
    info "Persisting consent records and region..."

    # Region first.
    "$OSTLER_PYTHON" - "$OSTLER_REGION" "$OSTLER_REGION_ISO" "$OSTLER_REGION_SOURCE" <<'PY' || \
        warn "Could not persist region.json (continuing - Doctor will surface)"
import sys
from ostler_security.region import RegionResult, save_region
from datetime import datetime, timezone
region, iso, source = sys.argv[1], sys.argv[2], sys.argv[3]
result = RegionResult(
    region=region,
    iso_country=iso,
    source=source,
    timestamp=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
)
save_region(result)
PY

    # Article 9 (EU branch only).
    if [[ -n "$OSTLER_CONSENT_ARTICLE_9_DECISION" ]]; then
        USER_ID="${USER_ID:-andy}" \
        "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
            --tickbox article_9_special_category_consent \
            --decision "$OSTLER_CONSENT_ARTICLE_9_DECISION" \
            --region "$OSTLER_REGION" \
            --user-id "${USER_ID:-andy}" 2>/dev/null || \
            warn "Could not persist Article 9 consent (continuing)"
    fi

    # WhatsApp tickbox.
    if [[ "$CHANNEL_WHATSAPP_CONSENT_ACCEPTED" == true ]]; then
        USER_ID="${USER_ID:-andy}" \
        "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
            --tickbox whatsapp_unofficial_risk \
            --decision accepted \
            --region "$OSTLER_REGION" \
            --user-id "${USER_ID:-andy}" 2>/dev/null || \
            warn "Could not persist WhatsApp consent (continuing - bridge will refuse to start)"
    elif [[ "${WA_CONSENT:-}" == "n" || "${WA_CONSENT:-}" == "N" ]]; then
        # User explicitly declined the WhatsApp tickbox after
        # selecting option 5. Record the decline so Doctor surfaces
        # "user declined" rather than "missing".
        USER_ID="${USER_ID:-andy}" \
        "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
            --tickbox whatsapp_unofficial_risk \
            --decision declined \
            --region "$OSTLER_REGION" \
            --user-id "${USER_ID:-andy}" 2>/dev/null || true
    fi

    # EU voice gate.
    if [[ -n "$OSTLER_CONSENT_VOICE_EU_DECISION" ]]; then
        USER_ID="${USER_ID:-andy}" \
        "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
            --tickbox voice_speaker_id_eu \
            --decision "$OSTLER_CONSENT_VOICE_EU_DECISION" \
            --region "$OSTLER_REGION" \
            --user-id "${USER_ID:-andy}" 2>/dev/null || \
            warn "Could not persist EU voice consent (continuing - cm041 will refuse to start)"
    fi

    # Third-party-data acknowledgement (every region). Decline aborts
    # earlier in Phase 2, so by the time we get here the value is
    # always "accepted" (or empty if the install was resumed in a way
    # that skipped the screen, in which case we omit the record and
    # Doctor's Consent tile will surface "missing" as a posture marker).
    if [[ -n "$OSTLER_CONSENT_THIRD_PARTY_DECISION" ]]; then
        USER_ID="${USER_ID:-andy}" \
        "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
            --tickbox third_party_data_personal_records \
            --decision "$OSTLER_CONSENT_THIRD_PARTY_DECISION" \
            --region "$OSTLER_REGION" \
            --user-id "${USER_ID:-andy}" 2>/dev/null || \
            warn "Could not persist third-party-data acknowledgement (continuing)"
    fi

    ok "Consent records and region persisted to ~/.ostler/posture/"
fi

# ── 3.7 FDA extraction (instant onboarding data) ─────────────────

progress "Extracting data from your Mac (the instant bit)"

if [[ "$HAS_FDA_MODULE" == true ]]; then
    # Pre-launch apps to trigger iCloud sync ONLY if their databases are
    # missing. Calendar, Reminders, Notes, and Mail each create their data
    # store on first launch; if it already exists (re-run, or user has
    # used the app before), opening the app is unnecessary and intrusive.
    # -gj flags: open in background, hidden — no window steal on first run.
    APPS_TO_OPEN=()
    [[ ! -d "$HOME/Library/Calendars" ]] && APPS_TO_OPEN+=("Calendar")
    [[ ! -d "$HOME/Library/Group Containers/group.com.apple.reminders" ]] && APPS_TO_OPEN+=("Reminders")
    [[ ! -f "$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite" ]] && APPS_TO_OPEN+=("Notes")
    [[ ! -d "$HOME/Library/Mail" ]] && APPS_TO_OPEN+=("Mail")

    if [[ ${#APPS_TO_OPEN[@]} -gt 0 ]]; then
        info "Triggering iCloud sync for ${APPS_TO_OPEN[*]} (silent, first-run only)..."
        for app in "${APPS_TO_OPEN[@]}"; do
            open -gj -a "$app" 2>/dev/null || true
        done
        # Give apps 10 seconds to launch and start syncing
        sleep 10
        # Close them quietly (SIGTERM via AppleScript, not force-kill)
        for app in "${APPS_TO_OPEN[@]}"; do
            osascript -e "tell application \"$app\" to quit" 2>/dev/null || true
        done
        ok "Apps launched to trigger iCloud sync"
    else
        ok "App databases already present (skipping pre-launch)"
    fi
    echo ""

    info "Reading Safari, iMessage, Notes, Calendar, Photos, Reminders, Mail..."
    info "This reads macOS databases directly — no export needed."
    echo ""
    # macOS does NOT prompt for Full Disk Access from a terminal-launched
    # script – it silently denies. Probe by trying to read a file that
    # only succeeds with FDA, and walk the user through the manual grant
    # if denied. This was the #1 silent-failure UX issue in the install
    # audit (~2026-05-01).
    FDA_PROBE_PATHS=(
        "$HOME/Library/Mail"
        "$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    )
    FDA_GRANTED=false
    for probe in "${FDA_PROBE_PATHS[@]}"; do
        if [[ -r "$probe" ]] || ls "$probe" >/dev/null 2>&1; then
            FDA_GRANTED=true
            break
        fi
    done
    if [[ "$FDA_GRANTED" == false ]]; then
        warn "Full Disk Access not granted to Terminal."
        warn "macOS will NOT prompt for it from a script – you must grant it manually."
        echo ""
        echo "  To grant Full Disk Access:"
        echo "    1. Open System Settings > Privacy & Security > Full Disk Access"
        echo "    2. Click + and add Terminal (or whichever terminal you ran this in)"
        echo "    3. Toggle it ON"
        echo "    4. Re-run the installer"
        echo ""
        echo "  Continuing without FDA – Ostler will work, just with less data"
        echo "  (no iMessage / Mail history; just contacts / calendars / GDPR exports)."
        echo ""
    else
        info "Full Disk Access detected – full extraction available."
    fi
    echo ""

    # Pass user's per-source consent (set in Phase 2) to the extractor.
    FDA_OUTPUT=$(OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES}" \
                 OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}" \
                 "$OSTLER_PYTHON" -c "
import sys, json
sys.path.insert(0, '${FDA_DIR}')
from ostler_fda.extract_all import run_all
from pathlib import Path
summary = run_all(Path('${OSTLER_DIR}/imports/fda'))
print(json.dumps(summary, default=str))
" 2>&1) || true

    # Parse results for the summary
    FDA_OK=$(echo "$FDA_OUTPUT" | grep -c '^\[ok\]' || true)
    FDA_SKIP=$(echo "$FDA_OUTPUT" | grep -c '^\[skip\]' || true)

    # Show each line of extractor output
    echo "$FDA_OUTPUT" | grep '^\[' | while IFS= read -r line; do
        echo "     $line"
    done

    if [[ $FDA_OK -gt 0 ]]; then
        ok "Extracted from ${FDA_OK} source(s). Data saved to ${OSTLER_DIR}/imports/fda/"
    else
        info "No FDA sources available right now. You can grant Full Disk Access"
        info "later in System Settings > Privacy & Security > Full Disk Access"
        info "and re-run: ostler-fda"
    fi

    # Schedule a one-shot FDA re-run ~12 hours from now to catch slow
    # iCloud syncs. Calendar, Notes, Photos face recognition etc. can
    # take hours to fully sync after first app launch.
    FDA_RERUN_PLIST="${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
    if [[ ! -f "$FDA_RERUN_PLIST" ]]; then
        # Calculate the run date: now + 12 hours
        FDA_RERUN_HOUR=$(date -v+12H +%H)
        FDA_RERUN_MIN=$(date +%M)
        FDA_RERUN_DAY=$(date -v+12H +%d)
        FDA_RERUN_MONTH=$(date -v+12H +%m)
        FDA_RERUN_YEAR=$(date -v+12H +%Y)

        mkdir -p "${HOME}/Library/LaunchAgents"
        cat > "$FDA_RERUN_PLIST" <<FDARPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.fda-rerun</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/ostler-fda</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Year</key>
        <integer>${FDA_RERUN_YEAR}</integer>
        <key>Month</key>
        <integer>${FDA_RERUN_MONTH}</integer>
        <key>Day</key>
        <integer>${FDA_RERUN_DAY}</integer>
        <key>Hour</key>
        <integer>${FDA_RERUN_HOUR}</integer>
        <key>Minute</key>
        <integer>${FDA_RERUN_MIN}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/fda-rerun.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/fda-rerun.err</string>
</dict>
</plist>
FDARPEOF
        launchctl bootstrap "gui/$(id -u)" "$FDA_RERUN_PLIST" 2>/dev/null || \
            launchctl load "$FDA_RERUN_PLIST" 2>/dev/null || true
        ok "FDA re-run scheduled for ~12 hours from now (catches slow iCloud syncs)"
    fi
else
    info "FDA extraction module not bundled. Skipping instant data extraction."
    info "You can add it later for instant onboarding from Safari, iMessage, etc."
fi

# ── 3.8 Docker services ───────────────────────────────────────────

progress "Starting your knowledge graph databases"

# Check for port conflicts before starting containers
_check_port() {
    if lsof -i ":$1" -sTCP:LISTEN &>/dev/null; then
        local PID=$(lsof -t -i ":$1" -sTCP:LISTEN 2>/dev/null | head -1)
        local PROC=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
        warn "Port $1 is already in use by ${PROC} (PID ${PID})"
        return 1
    fi
    return 0
}

PORT_CONFLICT=false
_check_port 6333 || PORT_CONFLICT=true  # Qdrant
_check_port 7878 || PORT_CONFLICT=true  # Oxigraph
_check_port 6379 || PORT_CONFLICT=true  # Redis
_check_port 3000 || PORT_CONFLICT=true  # Vane (local web search)

if [[ "$PORT_CONFLICT" == true ]]; then
    warn "Some ports are in use. Docker containers may fail to start."
    warn "Stop the conflicting services or change the ports in docker-compose.yml"
fi

cat > "${OSTLER_DIR}/docker-compose.yml" <<'DCEOF'
services:
  qdrant:
    image: qdrant/qdrant:v1.12.1
    container_name: ostler-qdrant
    ports:
      - "127.0.0.1:6333:6333"
      - "127.0.0.1:6334:6334"
    volumes:
      - qdrant_data:/qdrant/storage
    restart: unless-stopped

  oxigraph:
    image: ghcr.io/oxigraph/oxigraph:0.4.6
    container_name: ostler-oxigraph
    ports:
      - "127.0.0.1:7878:7878"
    volumes:
      - oxigraph_data:/data
    command: serve --location /data --bind 0.0.0.0:7878
    restart: unless-stopped

  redis:
    # Valkey: BSD-3-Clause LF fork of Redis (Redis 7.4+ relicensed to RSAL/SSPL).
    # Drop-in compatible with our redis-py client and protocol.
    image: valkey/valkey:8-alpine
    container_name: ostler-redis
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped

  # Personal wiki (Andypedia) -- the human-readable browse layer over
  # the Oxigraph graph + Qdrant vectors. Compiled by wiki-compiler
  # below into the shared wiki-docs volume; served by MkDocs Material.
  # See CM044 (PWG Personal Wiki) for compiler internals.
  #
  # Volume paths fixed in the Gap 3 PR:
  #   - wiki-docs at /docs/docs (MkDocs's default docs_dir under
  #     the image's WORKDIR /docs). Was wiki_docs:/app/site, which
  #     never matched what the wiki-site image expects.
  #   - Knowledge images bind-mounted from the user-facing zone so
  #     a single host directory backs both the HTML site at :8044
  #     AND the Obsidian vault at ~/Documents/Ostler/Wiki/_images/
  #     (no 11GB duplication). Read-only into the container.
  wiki-site:
    image: ghcr.io/ostler-ai/ostler-wiki-site:0.1
    container_name: ostler-wiki-site
    ports:
      - "127.0.0.1:8044:8000"
    volumes:
      - wiki-docs:/docs/docs:ro
      - ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}/_images:/docs/docs/Knowledge/images:ro
    restart: unless-stopped

  # Wiki compiler -- runs on demand (compose profile "compile") to
  # rebuild the wiki from current Oxigraph + Qdrant state. Invoked
  # at install time by Phase 3.16 and on a recurring schedule by the
  # wiki-recompile LaunchAgent (separate piece). Reads the data
  # volumes read-only so a buggy compiler can never clobber the
  # source of truth.
  #
  # Volume paths fixed in the Gap 3 PR:
  #   - wiki-docs at /wiki (matches the compiler image's
  #     WIKI_OUTPUT_DIR=/wiki convention). Was wiki_docs:/app/output,
  #     which the compiler image never wrote to.
  #   - Obsidian vault target at /wiki/obsidian, bind-mounted from
  #     the user-facing zone (~/Documents/Ostler/Wiki/ by default).
  #     OSTLER_WIKI_DIR overrides the host path for operators who
  #     want the vault on a different volume.
  #   - _images/ at /wiki/obsidian/_images:ro so the post-processor's
  #     rewritten ../_images/<slug>/file.jpg srcs (see
  #     compiler/obsidian.py::convert_image_srcs in CM044) resolve
  #     against the same content the wiki-site mounts.
  wiki-compiler:
    image: ghcr.io/ostler-ai/ostler-wiki-compiler:0.1
    container_name: ostler-wiki-compiler
    profiles: [compile]
    volumes:
      - wiki-docs:/wiki
      - ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}:/wiki/obsidian
      - ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}/_images:/wiki/obsidian/_images:ro
      - oxigraph_data:/app/oxigraph:ro
      - qdrant_data:/app/qdrant:ro
    environment:
      # Inside-container path the compiler writes the MkDocs source
      # to. Pinned to /wiki to match the wiki-docs:/wiki mount above.
      - WIKI_OUTPUT_DIR=/wiki
      # Inside-container path the Obsidian post-processor writes to.
      # Pinned to /wiki/obsidian to match the bind-mount above.
      - WIKI_OBSIDIAN_DIR=/wiki/obsidian
      # CM044 productisation knobs (set by CM044 PR #22). Empty
      # defaults are intentional: the compiler treats "" as "no
      # operator-specific filter" and emits a generic wiki rather
      # than failing. Operators override per-machine via
      # ~/.ostler/.env or the env block at install time.
      - PWG_USER_ID=${PWG_USER_ID:-}
      - PWG_AI_CHAT_WINGS=${PWG_AI_CHAT_WINGS:-}
      - OSTLER_PII_OPERATOR_HK_PHONE_DIGITS=${OSTLER_PII_OPERATOR_HK_PHONE_DIGITS:-}
      - OSTLER_PII_OPERATOR_UK_PHONE_DIGITS=${OSTLER_PII_OPERATOR_UK_PHONE_DIGITS:-}
      - OSTLER_PII_SCAN_MODE=${OSTLER_PII_SCAN_MODE:-fail}

  # Local AI web search (Vane). Replaces the cloud-search dependency
  # that comparable assistants offload to Perplexity / Google. The
  # full image bundles SearXNG (the actual search engine) so this is
  # a single container, not a sidecar pair -- SearXNG runs on an
  # internal port the Vane process talks to over loopback. Customer
  # never sees it.
  #
  # Why Vane (rather than calling SearXNG directly): the front-end
  # answers natural-language queries by issuing the SearXNG search,
  # fetching the top results, and asking the local Ollama to
  # synthesise an answer. SearXNG alone would hand back a list of
  # links; Vane gives the assistant a usable summary.
  #
  # Pinned to v1.12.2 (full variant) so installs are deterministic
  # and a future upstream change does not silently alter behaviour.
  # Slim variant requires an external SearXNG, which would defeat
  # the single-container productisation goal.
  #
  # Network shape:
  #   - Listens on loopback at 127.0.0.1:3000 (matches the rest of
  #     the stack -- nothing on the LAN reaches it without Tailscale).
  #   - Talks to Ollama on the host via host.docker.internal:11434.
  #     extra_hosts is the macOS / Colima-friendly way to surface
  #     the host gateway into the container.
  #   - vane_data volume holds the user's chat history + the
  #     Vane-side config the customer can edit at the web UI
  #     (model selection, etc.). Survives container restarts.
  vane:
    image: itzcrazykns1337/vane:v1.12.2
    container_name: ostler-vane
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - vane_data:/home/vane/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped

volumes:
  qdrant_data:
  oxigraph_data:
  redis_data:
  wiki-docs:
  vane_data:
DCEOF

cd "$OSTLER_DIR"
# Bring up the data services only at this phase. The wiki-site
# image is added by piece 1 of the wiki-container brief but its
# first-compile + serve happens later in Phase 3.16 (piece 2);
# wiki-compiler is profile-gated so it never starts at all here.
# Naming the services explicitly keeps install resilient against
# a missing wiki image (e.g. registry not yet wired) -- the data
# layer comes up first; the wiki layer fails on its own phase
# with its own error surface.
docker compose up -d qdrant oxigraph redis
ok "Services started (Qdrant :6333, Oxigraph :7878, Redis :6379)"

# ── 3.8b Local web search (Vane) ──────────────────────────────────
#
# Brings up the bundled local web-search container in its own phase
# so a registry hiccup, an image-pull failure, or a port-3000
# collision never breaks the data-services bring-up above. The
# customer-facing comparison pages (privacy, why-local, vs-* family)
# all promise "web search runs locally on your Mac"; this is the
# implementation of that promise.
#
# First-pull cost: ~3.6 GB (full variant bundles SearXNG). On a
# fresh install this is the second-largest download after the
# Ollama conversation model -- the 60s timeout below covers the
# image-already-pulled case; first-time pulls happen during the
# `up -d` step's own progress output before we get here.
#
# Failure mode: warn-only. The customer keeps their working
# wiki + assistant + graph; only the web-search tool surface
# is unavailable until they re-run `docker compose up -d vane`.

progress "Starting local web search (Vane)"

VANE_OK=false
if docker compose up -d vane 2>&1 | tail -3; then
    # Vane boots SearXNG inside the container then starts Next.js;
    # the HTTP server listens before SearXNG is fully warm. Poll
    # localhost:3000 until we get a 200, capped at 60 seconds so
    # the install never wedges on a misbehaving container.
    VANE_DEADLINE=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < VANE_DEADLINE )); do
        if curl -sf -o /dev/null -m 3 http://localhost:3000; then
            VANE_OK=true
            break
        fi
        sleep 2
    done
    if [[ "$VANE_OK" == true ]]; then
        ok "Vane running at http://localhost:3000 (talks to your local Ollama)"
    else
        warn "Vane container started but http://localhost:3000 did not respond within 60s."
        warn "  Try: docker logs ostler-vane"
        warn "       docker compose -f ${OSTLER_DIR}/docker-compose.yml restart vane"
    fi
else
    warn "Vane (local web search) failed to start. Common causes:"
    warn "  - Image pull failed (network, disk space, or registry timeout)"
    warn "  - Port 3000 already in use by another service"
    warn "  Manual retry: cd ${OSTLER_DIR} && docker compose up -d vane"
    warn "  Web search is optional; the rest of Ostler works without it."
fi

# ── 3.9 AI models ─────────────────────────────────────────────────

progress "Downloading AI models (this is the big one)"

if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    ok "nomic-embed-text already available"
else
    info "Pulling nomic-embed-text (274 MB)..."
    if ! ollama_pull_with_retry nomic-embed-text; then
        fail "Could not pull nomic-embed-text after 3 attempts. Check your network and re-run the installer."
    fi
    ok "Embedding model ready"
fi

if [[ "${PULL_MODEL}" != "n" && "${PULL_MODEL}" != "N" ]]; then
    if ollama list 2>/dev/null | grep -q "${AI_MODEL}"; then
        ok "${AI_MODEL} already available"
    else
        # Show the licence summary before the pull so the user knows
        # what they are accepting. Default Ostler models (Qwen family)
        # are Apache 2.0; the Gemma fallback for low-RAM Macs ships
        # under Google's restrictive Gemma Terms of Use.
        case "$AI_MODEL" in
            qwen*)
                info "Licence: ${AI_MODEL} is Apache 2.0. Full text: ${OSTLER_DIR}/LICENSES/Apache-2.0.txt"
                ;;
            gemma*)
                warn "Licence: ${AI_MODEL} ships under Google's Gemma Terms of Use, not Apache 2.0."
                warn "         Read https://ai.google.dev/gemma/terms before commercial use."
                ;;
            *)
                info "Licence: ${AI_MODEL} – check upstream terms before commercial use."
                ;;
        esac
        info "Pulling ${AI_MODEL} (${AI_MODEL_SIZE})... this may take a few minutes."
        if ! ollama_pull_with_retry "$AI_MODEL"; then
            fail "Could not pull ${AI_MODEL} after 3 attempts. Check your network and re-run the installer."
        fi
        ok "${AI_MODEL} ready"
    fi
else
    info "Skipped conversation model. Pull later: ollama pull ${AI_MODEL}"
fi

# ── 3.10 Import pipeline ──────────────────────────────────────────

progress "Installing the data import pipeline"

# The import pipeline is bundled with the installer if available,
# or cloned from PIPELINE_REPO (defined in the config block at the top
# of this script; overridable via PWG_PIPELINE_REPO env var).
HAS_PIPELINE=false

if [[ -d "${SCRIPT_DIR}/contact_syncer" ]]; then
    # Pipeline is bundled with the installer
    mkdir -p "$PIPELINE_DIR"
    cp -R "${SCRIPT_DIR}/contact_syncer" "$PIPELINE_DIR/"
    [[ -f "${SCRIPT_DIR}/requirements.txt" ]] && cp "${SCRIPT_DIR}/requirements.txt" "$PIPELINE_DIR/"
    ok "Import pipeline bundled with installer"
    HAS_PIPELINE=true
elif [[ -d "$PIPELINE_DIR/contact_syncer" ]]; then
    # Already installed from a previous run
    info "Updating existing pipeline..."
    cd "$PIPELINE_DIR" && git pull --quiet 2>/dev/null || warn "Could not update pipeline (offline?)"
    HAS_PIPELINE=true
elif [[ -z "$PIPELINE_REPO" ]]; then
    # Productised install path: no tarball-bundled pipeline and no
    # PWG_PIPELINE_REPO override. The pipeline ships with the
    # installer tarball at release; if a user gets here without one,
    # GDPR import is simply unavailable (their Mac-side data extracted
    # above is unaffected).
    info "Import pipeline not bundled with installer."
    info "Mac-side data (iMessage, Safari, etc.) was extracted above."
    info "GDPR-export import will be available when the pipeline ships."
    info "Beta testers with access can set PWG_PIPELINE_REPO=<url> and re-run."
else
    info "Cloning import pipeline..."
    PIPELINE_CLONE_LOG="$(mktemp -t ostler-pipeline-clone.XXXXXX.log)"
    if git clone --quiet "$PIPELINE_REPO" "$PIPELINE_DIR" 2>"$PIPELINE_CLONE_LOG"; then
        HAS_PIPELINE=true
        rm -f "$PIPELINE_CLONE_LOG"
    else
        warn "Import pipeline not available (private repo - beta testers only)."
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable. Trim noise.
        if [[ -s "$PIPELINE_CLONE_LOG" ]]; then
            warn "Git said:"
            sed -e 's/^/    /' "$PIPELINE_CLONE_LOG" | head -5
        fi
        info "This is expected for now. GDPR import will be available in a future update."
        info "Your Mac data (iMessage, Safari, etc.) was already extracted above."
        info "Repo URL: ${PIPELINE_REPO}"
        info "To install later once you have access:"
        info "  git clone ${PIPELINE_REPO} ${PIPELINE_DIR}"
        info "  Override the source repo with PWG_PIPELINE_REPO=<url> ./install.sh"
        rm -f "$PIPELINE_CLONE_LOG"
    fi
fi

if [[ "$HAS_PIPELINE" == true ]]; then
    cd "$PIPELINE_DIR"

    if [[ -f "contact_syncer/requirements.txt" ]]; then
        PIPELINE_REQS="contact_syncer/requirements.txt"
    elif [[ -f "requirements.txt" ]]; then
        PIPELINE_REQS="requirements.txt"
    else
        PIPELINE_REQS=""
    fi

    if [[ -n "$PIPELINE_REQS" ]]; then
        if [[ ! -d ".venv" ]]; then
            python3 -m venv .venv
        fi
        .venv/bin/pip install --quiet -r "$PIPELINE_REQS"
        ln -sf "${CONFIG_DIR}/.env" contact_syncer/.env 2>/dev/null || true
        ok "Import pipeline ready"
    fi
fi

# ── 3.11 Run GDPR import if exports were provided ────────────────

if [[ -n "$EXPORTS_DIR" && "$HAS_PIPELINE" == true && -d "$PIPELINE_DIR/.venv" ]]; then
    progress "Importing your data (building your knowledge graph)"
    info "This may take 5-15 minutes depending on how much data you have..."
    cd "$PIPELINE_DIR"
    if .venv/bin/python -m contact_syncer.import_all \
        --exports-dir "$EXPORTS_DIR" \
        --user-name "$USER_NAME" \
        --verbose 2>&1 | while IFS= read -r line; do
            echo "  $line"
        done; then
        ok "GDPR import complete"
    else
        warn "GDPR import had errors. You can re-run with:"
        warn "  ostler-import ${EXPORTS_DIR} --user-name \"${USER_NAME}\" --verbose"
    fi
elif [[ -n "$EXPORTS_DIR" ]]; then
    info "GDPR exports detected but import pipeline not yet available."
    info "Your exports are safe. Import them later with: ostler-import ${EXPORTS_DIR}"
fi

# ── 3.12 ostler-import command ──────────────────────────────────

IMPORT_SCRIPT="${OSTLER_DIR}/bin/ostler-import"
mkdir -p "${OSTLER_DIR}/bin"

if [[ -f "${SCRIPT_DIR}/ostler-import.sh" ]]; then
    cp "${SCRIPT_DIR}/ostler-import.sh" "$IMPORT_SCRIPT"
else
    cat > "$IMPORT_SCRIPT" <<'IMPORTEOF'
#!/usr/bin/env bash
set -euo pipefail
OSTLER_DIR="${HOME}/.ostler"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"

if [[ $# -lt 1 ]]; then
    echo "Usage: ostler-import <exports-dir> [--user-name \"Name\"] [--verbose]"
    echo ""
    echo "Example: ostler-import ~/Downloads/gdpr-exports/ --user-name \"Tom\" --verbose"
    exit 1
fi

if [[ ! -d "$PIPELINE_DIR/contact_syncer" ]]; then
    echo "Error: Import pipeline not installed."
    echo "Re-run the Ostler installer to set it up."
    exit 1
fi

if [[ ! -d "$PIPELINE_DIR/.venv" ]]; then
    echo "Error: Python environment not set up."
    echo "Re-run the Ostler installer to fix this."
    exit 1
fi

cd "$PIPELINE_DIR"
if [[ -f "${OSTLER_DIR}/config/.env" ]]; then
    set -a; source "${OSTLER_DIR}/config/.env"; set +a
fi
.venv/bin/python3 -m contact_syncer.import_all --exports-dir "$1" "${@:2}"
IMPORTEOF
fi

chmod +x "$IMPORT_SCRIPT"

# Create a ostler-fda command for re-running FDA extraction
# (e.g. after granting Full Disk Access post-install)
cat > "${OSTLER_DIR}/bin/ostler-fda" <<'FDAEOF'
#!/usr/bin/env bash
set -euo pipefail
OSTLER_DIR="${HOME}/.ostler"
FDA_DIR="${OSTLER_DIR}/fda-module"
OSTLER_PYTHON="${OSTLER_DIR}/.venv/bin/python3"

if [[ ! -d "$FDA_DIR/ostler_fda" ]]; then
    echo "Error: FDA extraction module not installed."
    echo "Re-run the Ostler installer to set it up."
    exit 1
fi

if [[ ! -f "$OSTLER_PYTHON" ]]; then
    echo "Error: Python environment not set up."
    echo "Re-run the Ostler installer to fix this."
    exit 1
fi

echo "Extracting data from macOS apps..."
echo "(Grant Full Disk Access to Terminal if prompted)"
echo ""

# Load the user's source-consent list from .env so re-runs respect it.
if [[ -f "${HOME}/.ostler/config/.env" ]]; then
    set -a; source "${HOME}/.ostler/config/.env"; set +a
fi
"\$OSTLER_PYTHON" -c "
import sys
sys.path.insert(0, '${FDA_DIR}')
from ostler_fda.extract_all import run_all
from pathlib import Path
run_all(Path('${OSTLER_DIR}/imports/fda'))
"
FDAEOF
chmod +x "${OSTLER_DIR}/bin/ostler-fda"

# Create an export watcher script — scans Downloads for new GDPR exports
cat > "${OSTLER_DIR}/bin/ostler-scan-exports" <<'SCANEOF'
#!/usr/bin/env bash
# Scans ~/Downloads for recognised GDPR export files.
# Run manually or via launchd (checks every 4 hours).
set -euo pipefail

OSTLER_DIR="${HOME}/.ostler"
SCAN_STATE="${OSTLER_DIR}/state/scan_state.json"
DOWNLOADS="${HOME}/Downloads"

mkdir -p "${OSTLER_DIR}/state"

# Known patterns for each platform's export
FOUND=()

# LinkedIn
for f in "$DOWNLOADS"/Basic_LinkedInDataExport_*/ "$DOWNLOADS"/linkedin_*.zip "$DOWNLOADS"/LinkedInDataExport_*.zip; do
    [[ -e "$f" ]] && FOUND+=("LinkedIn: $f")
done

# Facebook
for f in "$DOWNLOADS"/facebook-*/ "$DOWNLOADS"/facebook_*.zip; do
    [[ -e "$f" ]] && FOUND+=("Facebook: $f")
done

# Instagram
for f in "$DOWNLOADS"/instagram-*/ "$DOWNLOADS"/instagram_*.zip; do
    [[ -e "$f" ]] && FOUND+=("Instagram: $f")
done

# Google Takeout
for f in "$DOWNLOADS"/takeout-*.zip "$DOWNLOADS"/Takeout/; do
    [[ -e "$f" ]] && FOUND+=("Google: $f")
done

# Twitter
for f in "$DOWNLOADS"/twitter-*/ "$DOWNLOADS"/twitter-*.zip "$DOWNLOADS"/x-*.zip; do
    [[ -e "$f" ]] && FOUND+=("Twitter: $f")
done

if [[ ${#FOUND[@]} -eq 0 ]]; then
    exit 0
fi

# Check if we have already notified about these (avoid repeat alerts)
FOUND_HASH=$(printf '%s\n' "${FOUND[@]}" | sort | shasum | cut -d' ' -f1)
if [[ -f "$SCAN_STATE" ]] && grep -q "$FOUND_HASH" "$SCAN_STATE" 2>/dev/null; then
    exit 0  # Already notified
fi

# Show notification
osascript -e "display notification \"${#FOUND[@]} data export(s) found in Downloads. Open Terminal and run: ostler-import ~/Downloads/\" with title \"Ostler\" subtitle \"GDPR exports ready to import\""

echo "$FOUND_HASH" >> "$SCAN_STATE"

# Print details if running interactively
if [[ -t 1 ]]; then
    echo "Found ${#FOUND[@]} export(s):"
    printf '  %s\n' "${FOUND[@]}"
fi
SCANEOF
chmod +x "${OSTLER_DIR}/bin/ostler-scan-exports"

# Set up launchd plist to scan every 4 hours
mkdir -p "${HOME}/Library/LaunchAgents"
SCAN_PLIST="${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
cat > "$SCAN_PLIST" <<SPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.export-scan</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/ostler-scan-exports</string>
    </array>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/export-scan.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/export-scan.err</string>
</dict>
</plist>
SPEOF
launchctl bootstrap "gui/$(id -u)" "$SCAN_PLIST" 2>/dev/null || \
    launchctl load "$SCAN_PLIST" 2>/dev/null || true
ok "Export watcher installed (scans Downloads every 4 hours)"

# Detect user's shell and add to appropriate RC file
USER_SHELL=$(basename "${SHELL:-/bin/zsh}")
case "$USER_SHELL" in
    zsh)  SHELL_RC="${HOME}/.zshrc" ;;
    bash) SHELL_RC="${HOME}/.bashrc" ;;
    fish)
        # Fish uses a different syntax
        FISH_CONFIG="${HOME}/.config/fish/config.fish"
        mkdir -p "$(dirname "$FISH_CONFIG")"
        if ! grep -q "ostler/bin" "$FISH_CONFIG" 2>/dev/null; then
            echo '' >> "$FISH_CONFIG"
            echo '# Ostler' >> "$FISH_CONFIG"
            echo 'set -gx PATH $HOME/.ostler/bin $PATH' >> "$FISH_CONFIG"
        fi
        SHELL_RC=""  # skip the bash/zsh block below
        ;;
    *)    SHELL_RC="${HOME}/.zshrc" ;;  # default to zsh on macOS
esac

if [[ -n "$SHELL_RC" ]] && ! grep -q "ostler/bin" "$SHELL_RC" 2>/dev/null; then
    echo '' >> "$SHELL_RC"
    echo '# Ostler' >> "$SHELL_RC"
    echo 'export PATH="${HOME}/.ostler/bin:${PATH}"' >> "$SHELL_RC"
fi

export PATH="${OSTLER_DIR}/bin:${PATH}"

# Create uninstall script
cat > "${OSTLER_DIR}/bin/ostler-uninstall" <<'UNINSTALLEOF'
#!/usr/bin/env bash
set -euo pipefail

# ── Argument parsing ───────────────────────────────────────────
# Default: prompt the customer interactively. Two non-interactive
# overrides are supported for scripted use (CI, beta-onboarding
# automation, customer-support tooling):
#
#   --keep-content     ~/Documents/Ostler/ stays put after uninstall
#   --remove-content   ~/Documents/Ostler/ is also removed
#
# These are mutually exclusive. Specifying neither falls through
# to the interactive Y/n prompt below.
KEEP_CONTENT_DECISION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-content)
            KEEP_CONTENT_DECISION="keep"
            shift
            ;;
        --remove-content)
            KEEP_CONTENT_DECISION="remove"
            shift
            ;;
        --help|-h)
            cat <<'HELPEOF'
Usage: ostler-uninstall [options]

Removes the Ostler installation. Always removes ~/.ostler/ (except
power.conf), Docker volumes, LaunchAgents, and the PATH entry.

By default, prompts whether to also remove ~/Documents/Ostler/
(your generated wiki, transcripts, captures, exports). Use the
flags below to skip the prompt:

  --keep-content     Keep ~/Documents/Ostler/ after uninstall
  --remove-content   Remove ~/Documents/Ostler/ as well
  --help, -h         Show this help

The interactive YES confirm gate cannot be skipped.
HELPEOF
            exit 0
            ;;
        *)
            echo "  Unknown argument: $1" >&2
            echo "  Run 'ostler-uninstall --help' for usage." >&2
            exit 2
            ;;
    esac
done

USER_FACING_ROOT="${HOME}/Documents/Ostler"

echo ""
echo "  Ostler Uninstaller"
echo ""
echo "  This will remove:"
echo "    - Docker containers (ostler-qdrant, ostler-oxigraph, ostler-redis,"
echo "      ostler-wiki-site, ostler-wiki-compiler, ostler-vane)"
echo "    - Docker volumes (your knowledge graph data + web-search history)"
echo "    - Ostler directory (~/.ostler, except power.conf)"
echo "    - Doctor, export watcher, hub power, email-ingest, wiki-recompile, and assistant launchd services"
echo "    - Ostler commands from PATH"
echo ""
echo "  This will NOT remove:"
echo "    - Docker Desktop or Colima"
echo "    - Homebrew"
echo "    - Ollama or downloaded models (may be 5-23 GB)"
echo "      To remove: ollama rm <model-name>"
echo "    - Your original GDPR export files"
echo "    - Your hub power policy (~/.ostler/power.conf)"
echo "      kept so a reinstall reuses your existing policy"
echo ""
read -p "  Are you sure? This cannot be undone. (type YES to confirm): " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "  Cancelled."
    exit 0
fi

# ── User-facing content (Wiki/Transcripts/Captures/etc.) ───────
# Decide whether to also remove ~/Documents/Ostler/. The default
# is "keep": the customer's generated content survives an
# uninstall so that a re-install (or a switch to a different host
# that mounts the same Documents folder) finds the wiki + the
# transcripts intact.
if [[ -d "$USER_FACING_ROOT" ]]; then
    # File counts per subdir, shown before prompting so the
    # customer sees what is at stake. Counts are best-effort:
    # a permission error or an empty subdir reports 0.
    count_dir() {
        local d="$1"
        if [[ -d "$d" ]]; then
            find "$d" -type f 2>/dev/null | wc -l | tr -d ' '
        else
            echo 0
        fi
    }
    WIKI_COUNT="$(count_dir "$USER_FACING_ROOT/Wiki")"
    TRANSCRIPTS_COUNT="$(count_dir "$USER_FACING_ROOT/Transcripts")"
    BRIEFS_COUNT="$(count_dir "$USER_FACING_ROOT/Daily-Briefs")"
    CAPTURES_COUNT="$(count_dir "$USER_FACING_ROOT/Captures")"
    EXPORTS_COUNT="$(count_dir "$USER_FACING_ROOT/Exports")"

    echo ""
    echo "  Your generated content at ${USER_FACING_ROOT}/:"
    echo "    Wiki:          ${WIKI_COUNT} pages"
    echo "    Transcripts:   ${TRANSCRIPTS_COUNT} files"
    echo "    Daily briefs:  ${BRIEFS_COUNT} entries"
    echo "    Captures:      ${CAPTURES_COUNT} items"
    echo "    Exports:       ${EXPORTS_COUNT} items"
    echo ""

    if [[ -z "$KEEP_CONTENT_DECISION" ]]; then
        # Interactive prompt. Default Y matches the bolded letter
        # in the question, per the productisation contract:
        # bolded letter == default action.
        read -p "  Keep your generated content? [Y/n]: " KEEP_REPLY
        case "${KEEP_REPLY:-Y}" in
            n|N|no|NO|No)  KEEP_CONTENT_DECISION="remove" ;;
            *)             KEEP_CONTENT_DECISION="keep" ;;
        esac
    else
        # Avoid the ${VAR^} ucfirst expansion: macOS ships bash 3.2
        # which doesn't support it; explicit branches keep the
        # uninstaller portable across the bash versions customers
        # actually have installed.
        case "$KEEP_CONTENT_DECISION" in
            keep)    echo "  --keep-content flag set; ${USER_FACING_ROOT}/ will be preserved." ;;
            remove)  echo "  --remove-content flag set; ${USER_FACING_ROOT}/ will be removed." ;;
        esac
    fi
else
    # Tree never created (or already removed). Treat as keep so
    # we do not ask a redundant question, and so a stray flag
    # value does not cause a no-op rm to run.
    KEEP_CONTENT_DECISION="keep"
fi

echo ""
echo "  Stopping services..."
cd "${HOME}/.ostler" 2>/dev/null && docker compose down -v 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.doctor" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.it-guy" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.it-guy.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.export-scan" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.fda-rerun" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.colima" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.colima.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.email-ingest" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.wiki-recompile" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.it-guy.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"

echo "  Restoring sleep settings..."
sudo pmset -a sleep 1 2>/dev/null || true

echo "  Removing Keychain entry..."
security delete-generic-password -s "Ostler Recovery Key" 2>/dev/null || true

echo "  Removing Ostler directory (hub power policy preserved)..."
# Preserve ~/.ostler/power.conf so a reinstall reuses the user's hub power policy.
# Everything else under ~/.ostler goes.
if [[ -d "${HOME}/.ostler" ]]; then
    find "${HOME}/.ostler" -mindepth 1 -maxdepth 1 ! -name 'power.conf' -exec rm -rf {} + 2>/dev/null || true
    # If power.conf wasn't there, the directory is now empty - drop it too.
    rmdir "${HOME}/.ostler" 2>/dev/null || true
fi

# ── Apply the keep-content decision made earlier ───────────────
if [[ "$KEEP_CONTENT_DECISION" == "remove" ]]; then
    echo "  Removing user-facing content at ${USER_FACING_ROOT}/..."
    rm -rf "$USER_FACING_ROOT"
elif [[ -d "$USER_FACING_ROOT" ]]; then
    echo "  Keeping your generated content at ${USER_FACING_ROOT}/."
fi

echo ""
echo "  Done. Ostler has been removed."
if [[ "$KEEP_CONTENT_DECISION" == "keep" && -d "$USER_FACING_ROOT" ]]; then
    echo "  Your generated content remains at ${USER_FACING_ROOT}/."
fi
echo "  (You may want to remove the PATH line from your shell config.)"
echo ""
UNINSTALLEOF
chmod +x "${OSTLER_DIR}/bin/ostler-uninstall"

ok "ostler-import, ostler-fda, and ostler-uninstall commands installed"

# ── 3.13 Ostler Doctor ──────────────────────────────────────────

progress "Setting up Ostler Doctor diagnostic dashboard"

DOCTOR_DIR="${OSTLER_DIR}/doctor"
mkdir -p "$DOCTOR_DIR"

if [[ -d "${SCRIPT_DIR}/doctor/agent" ]]; then
    cp -R "${SCRIPT_DIR}/doctor/agent/"* "$DOCTOR_DIR/"
    ok "Copied Doctor agent files"
else
    warn "Doctor agent files not found — skipping (set up later)"
fi

if [[ -f "${DOCTOR_DIR}/requirements.txt" ]]; then
    if [[ ! -d "${DOCTOR_DIR}/.venv" ]]; then
        python3 -m venv "${DOCTOR_DIR}/.venv"
    fi
    "${DOCTOR_DIR}/.venv/bin/pip" install --quiet -r "${DOCTOR_DIR}/requirements.txt"
    ok "Doctor dependencies installed"

    mkdir -p "${HOME}/Library/LaunchAgents"
    DOCTOR_PLIST="${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
    cat > "$DOCTOR_PLIST" <<DOCEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.doctor</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DOCTOR_DIR}/.venv/bin/python3</string>
        <string>${DOCTOR_DIR}/web_ui.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${DOCTOR_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/doctor.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/doctor.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DOCTOR_PORT</key>
        <string>8089</string>
        <key>DOCTOR_SUPPORT_EMAIL</key>
        <string>support@creativemachines.ai</string>
    </dict>
</dict>
</plist>
DOCEOF

    # Use bootstrap on Sequoia+ (load is deprecated), fall back to load
    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "Ostler Doctor running at http://localhost:8089/doctor"
fi

# ── 3.14 Hub power policy (MacBook-as-Hub support) ───────────────
#
# Installs a LaunchAgent that pauses / resumes Docker services and
# Ollama based on AC / battery state, and brings things back cleanly
# after sleep. Design doc: HR015/HUB_PORTABILITY_PLAN.md.
#
# Safe on Mac Minis and Studios (always-on AC): the watcher sees tier
# "ac" every tick and takes no action. Only MacBooks see transitions.
#
# Source: HR015's hub-power/ directory. The installer tarball bundles
# a copy; dev environments may symlink. If neither is present we fall
# back to cloning from HUB_POWER_REPO.

progress "Setting up hub power policy (MacBook-as-Hub)"

HUB_POWER_DIR="${OSTLER_DIR}/hub-power"
HUB_POWER_SNIPPET=""
HUB_POWER_SOURCE=""

if [[ -d "${SCRIPT_DIR}/hub-power" && -f "${SCRIPT_DIR}/hub-power/INSTALL_SNIPPET.sh" ]]; then
    HUB_POWER_SNIPPET="${SCRIPT_DIR}/hub-power/INSTALL_SNIPPET.sh"
    HUB_POWER_SOURCE="bundled"
    mkdir -p "$HUB_POWER_DIR"
    cp -R "${SCRIPT_DIR}/hub-power/"* "$HUB_POWER_DIR/"
    ok "Hub power scripts bundled with installer"
elif [[ -f "${HUB_POWER_DIR}/INSTALL_SNIPPET.sh" ]]; then
    HUB_POWER_SNIPPET="${HUB_POWER_DIR}/INSTALL_SNIPPET.sh"
    HUB_POWER_SOURCE="existing"
    info "Reusing existing hub-power install at ${HUB_POWER_DIR}"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    # Productised install path: no tarball-bundled scripts and no
    # PWG_HUB_POWER_REPO override. Mac Mini / Studio deployments do
    # not need this LaunchAgent (always-on AC); only MacBook hubs do.
    info "Hub power scripts not bundled with installer."
    info "Mac Mini / Studio deployments are unaffected (always-on AC)."
    info "MacBook hubs: set PWG_HUB_POWER_REPO=<url> and re-run."
else
    info "Cloning hub-power scripts..."
    HUB_POWER_TMP="$(mktemp -d)"
    HUB_POWER_CLONE_LOG="$(mktemp -t ostler-hub-power-clone.XXXXXX.log)"
    if git clone --quiet --depth 1 "$HUB_POWER_REPO" "$HUB_POWER_TMP" 2>"$HUB_POWER_CLONE_LOG" \
       && [[ -d "$HUB_POWER_TMP/hub-power" ]]; then
        mkdir -p "$HUB_POWER_DIR"
        cp -R "$HUB_POWER_TMP/hub-power/"* "$HUB_POWER_DIR/"
        rm -rf "$HUB_POWER_TMP"
        rm -f "$HUB_POWER_CLONE_LOG"
        HUB_POWER_SNIPPET="${HUB_POWER_DIR}/INSTALL_SNIPPET.sh"
        HUB_POWER_SOURCE="cloned"
        ok "Hub power scripts cloned from ${HUB_POWER_REPO}"
    else
        rm -rf "$HUB_POWER_TMP"
        warn "Could not obtain hub-power scripts (bundled / cloned both failed)."
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable.
        if [[ -s "$HUB_POWER_CLONE_LOG" ]]; then
            warn "Git said:"
            sed -e 's/^/    /' "$HUB_POWER_CLONE_LOG" | head -5
        fi
        rm -f "$HUB_POWER_CLONE_LOG"
        warn "Skipping LaunchAgent install. Mac Mini deployments are unaffected."
        warn "MacBook deployments need this for battery / sleep handling."
        info "Repo URL: ${HUB_POWER_REPO}"
        info "To install later once you have access:"
        info "  git clone ${HUB_POWER_REPO} /tmp/hub-power-src"
        info "  mkdir -p ${HUB_POWER_DIR} && cp -R /tmp/hub-power-src/hub-power/* ${HUB_POWER_DIR}/"
        info "  OSTLER_INSTALL_ROOT=${HUB_POWER_DIR} bash ${HUB_POWER_DIR}/INSTALL_SNIPPET.sh"
        info "  Override the source repo with PWG_HUB_POWER_REPO=<url> ./install.sh"
    fi
fi

if [[ -n "$HUB_POWER_SNIPPET" && -f "$HUB_POWER_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$HUB_POWER_DIR" bash "$HUB_POWER_SNIPPET"; then
        ok "Hub power LaunchAgent loaded (label com.creativemachines.ostler.hub-power)"
        info "Policy override: edit ~/.ostler/power.conf (normal / aggressive / eco)"
    else
        warn "Hub power LaunchAgent install failed. See output above."
        warn "Mac Mini deployments are unaffected; MacBook users should retry."
    fi
fi

# ── 3.14a Email-ingest LaunchAgent (CM046 hourly drain) ──────────
#
# Hourly LaunchAgent that drains any new messages from Apple Mail
# into a Gmail-format mbox and hands it to CM046's email adapter,
# which threads + cleans + writes CM048 conversation files. Runs on
# every Mac (Mini and MacBook) -- everyone has email.
#
# Source: HR015's email-ingest/ directory (sibling of hub-power/).
# Same bundle / clone fallback chain as 3.14 above so a productised
# install (tarball with assets) and a dev install (clone HR015)
# both work.

progress "Setting up email-ingest LaunchAgent (hourly Apple Mail drain)"

EMAIL_INGEST_DIR="${OSTLER_DIR}/email-ingest"
EMAIL_INGEST_SNIPPET=""
EMAIL_INGEST_SOURCE=""

if [[ -d "${SCRIPT_DIR}/email-ingest" && -f "${SCRIPT_DIR}/email-ingest/INSTALL_SNIPPET.sh" ]]; then
    EMAIL_INGEST_SNIPPET="${SCRIPT_DIR}/email-ingest/INSTALL_SNIPPET.sh"
    EMAIL_INGEST_SOURCE="bundled"
    mkdir -p "$EMAIL_INGEST_DIR"
    cp -R "${SCRIPT_DIR}/email-ingest/"* "$EMAIL_INGEST_DIR/"
    ok "Email-ingest scripts bundled with installer"
elif [[ -f "${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh" ]]; then
    EMAIL_INGEST_SNIPPET="${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh"
    EMAIL_INGEST_SOURCE="existing"
    info "Reusing existing email-ingest install at ${EMAIL_INGEST_DIR}"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    info "Email-ingest scripts not bundled with installer."
    info "Set PWG_HUB_POWER_REPO=<HR015 url> and re-run to install."
else
    info "Cloning email-ingest scripts..."
    EMAIL_INGEST_TMP="$(mktemp -d)"
    EMAIL_INGEST_CLONE_LOG="$(mktemp -t ostler-email-ingest-clone.XXXXXX.log)"
    if git clone --quiet --depth 1 "$HUB_POWER_REPO" "$EMAIL_INGEST_TMP" 2>"$EMAIL_INGEST_CLONE_LOG" \
       && [[ -d "$EMAIL_INGEST_TMP/email-ingest" ]]; then
        mkdir -p "$EMAIL_INGEST_DIR"
        cp -R "$EMAIL_INGEST_TMP/email-ingest/"* "$EMAIL_INGEST_DIR/"
        rm -rf "$EMAIL_INGEST_TMP"
        rm -f "$EMAIL_INGEST_CLONE_LOG"
        EMAIL_INGEST_SNIPPET="${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh"
        EMAIL_INGEST_SOURCE="cloned"
        ok "Email-ingest scripts cloned from ${HUB_POWER_REPO}"
    else
        rm -rf "$EMAIL_INGEST_TMP"
        warn "Could not obtain email-ingest scripts (bundled / cloned both failed)."
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable.
        if [[ -s "$EMAIL_INGEST_CLONE_LOG" ]]; then
            warn "Git said:"
            sed -e 's/^/    /' "$EMAIL_INGEST_CLONE_LOG" | head -5
        fi
        rm -f "$EMAIL_INGEST_CLONE_LOG"
        warn "Skipping email-ingest LaunchAgent install."
        info "Repo URL: ${HUB_POWER_REPO}"
        info "To install later once you have access:"
        info "  git clone ${HUB_POWER_REPO} /tmp/hub-src"
        info "  mkdir -p ${EMAIL_INGEST_DIR} && cp -R /tmp/hub-src/email-ingest/* ${EMAIL_INGEST_DIR}/"
        info "  OSTLER_INSTALL_ROOT=${EMAIL_INGEST_DIR} OSTLER_DIR=${OSTLER_DIR} LOGS_DIR=${LOGS_DIR} \\"
        info "    bash ${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh"
    fi
fi

if [[ -n "$EMAIL_INGEST_SNIPPET" && -f "$EMAIL_INGEST_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$EMAIL_INGEST_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       bash "$EMAIL_INGEST_SNIPPET"; then
        ok "Email-ingest LaunchAgent loaded (label com.creativemachines.ostler.email-ingest)"
        info "Hourly tick. First run clamped to last 90 days."
        info "Manual run: bash ${OSTLER_DIR}/bin/email-ingest-tick.sh"
        info "Logs: ${LOGS_DIR}/email-ingest.log (and .err)"
    else
        warn "Email-ingest LaunchAgent install failed. See output above."
        warn "Mail data is still ingestible manually:"
        warn "  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
        warn "  pwg-email-ingest mbox /tmp/manual.mbox.txt"
    fi
fi

# ── 3.14d Wiki recompile LaunchAgent (daily Andypedia rebuild) ───
#
# Daily LaunchAgent that re-runs the wiki-compiler against the
# current Oxigraph + Qdrant state, so emails / conversations /
# imports landed in the previous 24 hours are reflected in the
# user's wiki the next morning. Companion to Phase 3.16's first
# compile -- that one runs once at install time; this one is the
# recurring schedule.
#
# Source: the same bundled-or-clone fallback chain as hub-power
# and email-ingest. Lives under wiki-recompile/ in the installer
# tarball / HR015 clone.

progress "Setting up wiki-recompile LaunchAgent (daily rebuild)"

WIKI_RECOMPILE_DIR="${OSTLER_DIR}/wiki-recompile"
WIKI_RECOMPILE_SNIPPET=""
WIKI_RECOMPILE_SOURCE=""

if [[ -d "${SCRIPT_DIR}/wiki-recompile" && -f "${SCRIPT_DIR}/wiki-recompile/INSTALL_SNIPPET.sh" ]]; then
    WIKI_RECOMPILE_SNIPPET="${SCRIPT_DIR}/wiki-recompile/INSTALL_SNIPPET.sh"
    WIKI_RECOMPILE_SOURCE="bundled"
    mkdir -p "$WIKI_RECOMPILE_DIR"
    cp -R "${SCRIPT_DIR}/wiki-recompile/"* "$WIKI_RECOMPILE_DIR/"
    ok "Wiki-recompile scripts bundled with installer"
elif [[ -f "${WIKI_RECOMPILE_DIR}/INSTALL_SNIPPET.sh" ]]; then
    WIKI_RECOMPILE_SNIPPET="${WIKI_RECOMPILE_DIR}/INSTALL_SNIPPET.sh"
    WIKI_RECOMPILE_SOURCE="existing"
    info "Reusing existing wiki-recompile install at ${WIKI_RECOMPILE_DIR}"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    info "Wiki-recompile scripts not bundled with installer."
    info "Set PWG_HUB_POWER_REPO=<HR015 url> and re-run to install."
else
    info "Cloning wiki-recompile scripts..."
    WIKI_RECOMPILE_TMP="$(mktemp -d)"
    WIKI_RECOMPILE_CLONE_LOG="$(mktemp -t ostler-wiki-recompile-clone.XXXXXX.log)"
    if git clone --quiet --depth 1 "$HUB_POWER_REPO" "$WIKI_RECOMPILE_TMP" 2>"$WIKI_RECOMPILE_CLONE_LOG" \
       && [[ -d "$WIKI_RECOMPILE_TMP/wiki-recompile" ]]; then
        mkdir -p "$WIKI_RECOMPILE_DIR"
        cp -R "$WIKI_RECOMPILE_TMP/wiki-recompile/"* "$WIKI_RECOMPILE_DIR/"
        rm -rf "$WIKI_RECOMPILE_TMP"
        rm -f "$WIKI_RECOMPILE_CLONE_LOG"
        WIKI_RECOMPILE_SNIPPET="${WIKI_RECOMPILE_DIR}/INSTALL_SNIPPET.sh"
        WIKI_RECOMPILE_SOURCE="cloned"
        ok "Wiki-recompile scripts cloned from ${HUB_POWER_REPO}"
    else
        rm -rf "$WIKI_RECOMPILE_TMP"
        warn "Could not obtain wiki-recompile scripts (bundled / cloned both failed)."
        if [[ -s "$WIKI_RECOMPILE_CLONE_LOG" ]]; then
            warn "Git said:"
            sed -e 's/^/    /' "$WIKI_RECOMPILE_CLONE_LOG" | head -5
        fi
        rm -f "$WIKI_RECOMPILE_CLONE_LOG"
        warn "Skipping wiki-recompile LaunchAgent install."
        info "Wiki will not auto-update; you can re-run the first-compile manually:"
        info "  cd ${OSTLER_DIR}"
        info "  docker compose --profile compile run --rm wiki-compiler"
    fi
fi

if [[ -n "$WIKI_RECOMPILE_SNIPPET" && -f "$WIKI_RECOMPILE_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$WIKI_RECOMPILE_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       bash "$WIKI_RECOMPILE_SNIPPET"; then
        ok "Wiki-recompile LaunchAgent loaded (label com.creativemachines.ostler.wiki-recompile)"
        info "Daily tick. Manual run: bash ${OSTLER_DIR}/bin/wiki-recompile-tick.sh"
        info "Logs: ${LOGS_DIR}/wiki-recompile.log (and .err)"
    else
        warn "Wiki-recompile LaunchAgent install failed. See output above."
        warn "Wiki will not auto-update; manual rebuild stays available:"
        warn "  cd ${OSTLER_DIR}"
        warn "  docker compose --profile compile run --rm wiki-compiler"
    fi
fi

# ── 3.14e Ostler assistant binary + LaunchAgent ──────────────────
#
# Stages the customer-facing assistant binary and registers a daemon
# LaunchAgent that runs it under the user's account. The binary is
# the upstream zeroclaw runtime renamed at tar time by Phase B's
# release pipeline; the LaunchAgent points it at the config.toml
# Phase D's wizard wrote in section 3.5b.
#
# Pieces:
#   1. Resolve the release URL and SHA-256 sidecar URL.
#   2. Download both into a temp dir.
#   3. Verify SHA-256 (abort on mismatch -- silent acceptance of
#      a bad download would put a tampered binary on the daily
#      driver Mac, so this is an explicit hard fail).
#   4. Extract to ${OSTLER_DIR}/bin/ostler-assistant.
#   5. Clear the macOS quarantine xattr because v0.1 ships
#      unsigned (Andy's Developer ID work is task #136).
#   6. Source assistant-agent/INSTALL_SNIPPET.sh to register the
#      LaunchAgent.
#
# Failure mode: if the download / verify / extract chain fails,
# warn and skip the LaunchAgent install. The wizard-written
# config.toml stays in place so a later manual binary install
# (re-run the installer when the network recovers, or stage the
# binary by hand) wires up cleanly.
#
# Productisation: OSTLER_ASSISTANT_VERSION + OSTLER_ASSISTANT_REPO
# are env-overridable so an enterprise fork or pre-release smoke
# can point at a different release without editing install.sh.
# Defaults track ostler-ai/ostler-assistant v0.1.
#
# Open question: there is no zeroclaw subcommand for "encrypt the
# plaintext password the wizard just wrote" -- the secrets store
# auto-migrates legacy enc: values to enc2: on read but does not
# bootstrap from plaintext. The TOML stays mode 0600 in the
# meantime. A `config encrypt-secrets` subcommand would close the
# window; flagged as a follow-up Rust PR (or roll into Phase E).

progress "Setting up ostler-assistant binary (v${OSTLER_ASSISTANT_VERSION:-0.1.0})"

OSTLER_ASSISTANT_VERSION="${OSTLER_ASSISTANT_VERSION:-0.1.0}"
# Customer-facing distribution. v0.1.0 binary published to
# ostler-ai/ostler-installer 2026-05-03 after the org-level new-account hold
# was lifted by GitHub support (ticket #4347825).
OSTLER_ASSISTANT_REPO="${OSTLER_ASSISTANT_REPO:-ostler-ai/ostler-installer}"
OSTLER_ASSISTANT_TARGET="${OSTLER_ASSISTANT_TARGET:-aarch64-apple-darwin}"
OSTLER_ASSISTANT_DIR="${OSTLER_DIR}/assistant-agent"
ASSISTANT_BINARY="${OSTLER_DIR}/bin/ostler-assistant"

# Apple Silicon only at v0.1. The Phase B release workflow does
# not produce an x86_64 build (customer Macs are arm64 by the
# brief). Surface this clearly rather than letting curl 404 on
# a non-existent Intel asset.
ARCH_DETECTED="$(uname -m 2>/dev/null || echo unknown)"
if [[ "$ARCH_DETECTED" != "arm64" && "$ARCH_DETECTED" != "aarch64" ]]; then
    warn "ostler-assistant v${OSTLER_ASSISTANT_VERSION} is Apple Silicon only (detected: ${ARCH_DETECTED})."
    warn "Skipping binary install. The wizard-written config.toml stays in place."
    info "Intel support is not on the v0.1 roadmap; raise a request if required."
    ASSISTANT_BINARY_INSTALLED=false
else

ASSISTANT_ARCHIVE_NAME="ostler-assistant-${OSTLER_ASSISTANT_TARGET}-v${OSTLER_ASSISTANT_VERSION}.tar.gz"
ASSISTANT_ARCHIVE_URL="https://github.com/${OSTLER_ASSISTANT_REPO}/releases/download/v${OSTLER_ASSISTANT_VERSION}/${ASSISTANT_ARCHIVE_NAME}"
ASSISTANT_CHECKSUM_URL="${ASSISTANT_ARCHIVE_URL}.sha256"

ASSISTANT_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$ASSISTANT_TMPDIR"' EXIT

ASSISTANT_BINARY_INSTALLED=false

if curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" "$ASSISTANT_ARCHIVE_URL" 2>"$ASSISTANT_TMPDIR/curl.log" \
   && curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME.sha256" "$ASSISTANT_CHECKSUM_URL" 2>>"$ASSISTANT_TMPDIR/curl.log"; then

    # Verify SHA-256. Phase B writes the sidecar as
    # `<hex>  <filename>` (shasum default). Recompute against
    # the local download and compare hex prefixes. A mismatch
    # is an explicit hard fail: continuing past this point
    # would stage a tampered or partial binary.
    EXPECTED_SHA="$(awk '{print $1}' "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME.sha256")"
    ACTUAL_SHA="$(shasum -a 256 "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" | awk '{print $1}')"
    if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        err "ostler-assistant tarball SHA-256 mismatch."
        err "  expected: ${EXPECTED_SHA:-<empty sidecar>}"
        err "  actual:   ${ACTUAL_SHA}"
        err "  url:      ${ASSISTANT_ARCHIVE_URL}"
        err "  Refusing to stage a binary that does not match the published checksum."
        rm -rf "$ASSISTANT_TMPDIR"
        trap - EXIT
        exit 1
    fi

    mkdir -p "${OSTLER_DIR}/bin"
    if tar xzf "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" -C "${OSTLER_DIR}/bin"; then
        chmod 0755 "$ASSISTANT_BINARY"

        # Three-state binary check. The SHA-256 verification
        # earlier in this section already caught a tampered
        # download, but a malformed extract or an upstream
        # release-pipeline bug could still hand us a file that
        # is not even a Mach-O. We refuse to silently degrade
        # such a binary to the unsigned-quarantine-strip path:
        # clearing the quarantine xattr on a corrupt binary
        # would let it run without the right-click-and-Allow
        # ceremony that would otherwise alert the operator.
        # Per feedback_no_silent_security_fallback: security
        # paths must hard-fail, not silently degrade.
        #
        # State distinction:
        #   1. `file` does not report Mach-O => state "corrupt".
        #      A random-bytes replacement, an empty file, or any
        #      non-executable extracted in error lands here. We
        #      can't trust codesign output below for non-Mach-O
        #      input -- codesign reports "not signed at all" for
        #      both legitimately-unsigned binaries AND completely
        #      garbage data, so without this Mach-O gate the
        #      detection silently misclassifies garbage as
        #      "unsigned" and strips the quarantine xattr.
        #   2. `codesign -dv` reports Authority=Developer ID
        #      Application => state "signed". Upstream pipeline
        #      stamped this build via release/sign-and-notarize.sh.
        #   3. Otherwise => state "unsigned". Today's default
        #      tarball, an ad-hoc-signed local build, or any
        #      non-Developer-ID signature. Trust path is the
        #      same: clear the quarantine xattr on the operator-
        #      authorised install.
        ASSISTANT_BINARY_SIGN_STATE="unknown"
        binary_file_type="$(/usr/bin/file --brief "$ASSISTANT_BINARY" 2>&1 || true)"
        codesign_dv_output="$(codesign -dv --verbose=4 "$ASSISTANT_BINARY" 2>&1 || true)"

        if [[ "$binary_file_type" != *"Mach-O"* ]]; then
            ASSISTANT_BINARY_SIGN_STATE="corrupt"
        elif echo "$codesign_dv_output" | grep -qE "Authority=Developer ID Application"; then
            ASSISTANT_BINARY_SIGN_STATE="signed"
        else
            # A valid Mach-O without a Developer ID signature
            # (today's default unsigned, or an ad-hoc / non-
            # Developer-ID signed build). Trust path: the
            # operator authorised this install, FileVault
            # protects the artefact at rest, the SHA-256
            # verified the download. Strip the xattr.
            ASSISTANT_BINARY_SIGN_STATE="unsigned"
        fi

        case "$ASSISTANT_BINARY_SIGN_STATE" in
            signed)
                # Signed + notarised binaries are Gatekeeper-
                # trusted; the quarantine xattr resolves cleanly
                # on first run via Apple's online ticket lookup,
                # so we leave it in place rather than stripping.
                ok "ostler-assistant v${OSTLER_ASSISTANT_VERSION} staged at ${ASSISTANT_BINARY} (signed)"
                info "Apple notarisation will be verified by Gatekeeper on first launch."
                ;;
            unsigned)
                # Unsigned binary (today's default, or a forked
                # build that opted out of signing). Clearing the
                # quarantine xattr lets the LaunchAgent run
                # without the user having to right-click + Allow
                # in Privacy & Security on first launch.
                # Operator-installed daemons under ~/.ostler/bin
                # are explicitly trusted by the install they
                # just authorised; quarantine adds friction
                # without buying anything beyond what FileVault
                # and the SHA verify above already cover.
                xattr -d com.apple.quarantine "$ASSISTANT_BINARY" 2>/dev/null || true
                ok "ostler-assistant v${OSTLER_ASSISTANT_VERSION} staged at ${ASSISTANT_BINARY} (unsigned)"
                info "Quarantine xattr cleared. Once the Developer-ID build is"
                info "available the installer will skip this step automatically."
                ;;
            corrupt)
                # Refuse to install. The SHA-256 sidecar already
                # passed (we wouldn't be here otherwise), so a
                # corrupt binary at this point implies an
                # upstream release-pipeline bug or a runtime
                # filesystem fault. Either way: don't strip
                # quarantine, don't load the LaunchAgent, leave
                # the binary in place for the operator to
                # inspect.
                err "ostler-assistant binary at ${ASSISTANT_BINARY} is not a Mach-O executable."
                err "  file --brief reported: ${binary_file_type}"
                err "  codesign -dv reported:"
                err "$(printf '%s\n' "$codesign_dv_output" | sed -e 's/^/    /' | head -5)"
                err "Refusing to strip quarantine or load the LaunchAgent."
                err "Re-run the installer once the upstream tarball is fixed."
                # ASSISTANT_BINARY_INSTALLED stays false (its
                # initial value), so the LaunchAgent step
                # downstream is skipped without further action.
                ;;
        esac

        if [[ "$ASSISTANT_BINARY_SIGN_STATE" != "corrupt" ]]; then
            if "$ASSISTANT_BINARY" --version >/dev/null 2>&1; then
                ASSISTANT_BINARY_INSTALLED=true
            else
                warn "ostler-assistant extracted but --version check failed."
                warn "Skipping LaunchAgent install. Try: ${ASSISTANT_BINARY} --version"
            fi
        fi
    else
        warn "Could not extract ostler-assistant tarball; skipping LaunchAgent."
    fi
else
    warn "Could not download ostler-assistant v${OSTLER_ASSISTANT_VERSION} from ${ASSISTANT_ARCHIVE_URL}"
    if [[ -s "$ASSISTANT_TMPDIR/curl.log" ]]; then
        warn "Curl said:"
        sed -e 's/^/    /' "$ASSISTANT_TMPDIR/curl.log" | head -5
    fi
    warn "Common causes: tag v${OSTLER_ASSISTANT_VERSION} not yet published, network offline,"
    warn "or running ahead of Phase B's release pipeline. Re-run the installer once the"
    warn "release lands, or stage the binary manually:"
    info "  curl -fL -o /tmp/ostler.tgz ${ASSISTANT_ARCHIVE_URL}"
    info "  tar xzf /tmp/ostler.tgz -C ${OSTLER_DIR}/bin"
    info "  bash ${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh"
fi

rm -rf "$ASSISTANT_TMPDIR"
trap - EXIT

# Stage the assistant-agent INSTALL_SNIPPET assets even when the
# binary download failed. The snippet refuses to run without the
# binary, but a later manual stage just needs to source it.
if [[ -d "${SCRIPT_DIR}/assistant-agent" && -f "${SCRIPT_DIR}/assistant-agent/INSTALL_SNIPPET.sh" ]]; then
    mkdir -p "$OSTLER_ASSISTANT_DIR"
    cp -R "${SCRIPT_DIR}/assistant-agent/"* "$OSTLER_ASSISTANT_DIR/"
fi

if [[ "$ASSISTANT_BINARY_INSTALLED" == true && -f "${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh" ]]; then
    if OSTLER_INSTALL_ROOT="$OSTLER_ASSISTANT_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       ASSISTANT_CONFIG_DIR="$ASSISTANT_CONFIG_DIR" \
       bash "${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh"; then
        ok "Ostler assistant LaunchAgent loaded (label com.creativemachines.ostler.assistant)"
        info "Logs: ${LOGS_DIR}/ostler-assistant.log (and .err)"
        info "Manual restart: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
    else
        warn "Ostler assistant LaunchAgent install failed. See output above."
        warn "Wizard config stays in place; binary stays staged. Manual retry:"
        warn "  bash ${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh"
    fi
fi

fi  # end Apple Silicon guard

# ── 3.14b Third-party attribution catalogue ─────────────────────
#
# Land THIRD_PARTY_NOTICES.md at ~/.ostler/ so the user can read it
# offline via `install.sh --licenses` and so any compliance review
# can verify what we ship attribution for. Source preference: bundled
# in installer tarball, then fetched from the same HUB_POWER clone we
# already used (when the operator opted into one), then a final
# raw-fetch fallback gated on PWG_NOTICES_BASE_URL. The productised
# tarball ships these files bundled, so the curl fallback only fires
# in dev runs that opt into a base URL.

NOTICES_DEST="${OSTLER_DIR}/THIRD_PARTY_NOTICES.md"
NOTICES_SOURCE=""

if [[ -f "${SCRIPT_DIR}/THIRD_PARTY_NOTICES.md" ]]; then
    cp "${SCRIPT_DIR}/THIRD_PARTY_NOTICES.md" "$NOTICES_DEST"
    NOTICES_SOURCE="bundled"
elif [[ -n "${HUB_POWER_TMP:-}" && -f "${HUB_POWER_TMP}/THIRD_PARTY_NOTICES.md" ]]; then
    cp "${HUB_POWER_TMP}/THIRD_PARTY_NOTICES.md" "$NOTICES_DEST"
    NOTICES_SOURCE="cloned (HR015)"
elif [[ -n "$NOTICES_BASE_URL" ]] && command -v curl >/dev/null 2>&1; then
    # Final fallback: raw fetch from the operator-provided base URL.
    # Empty default means a productised cold install never probes a
    # private repo; warn-only branch below documents the public link.
    if curl -fsSL --max-time 30 \
        "${NOTICES_BASE_URL}/THIRD_PARTY_NOTICES.md" \
        -o "$NOTICES_DEST" 2>/dev/null; then
        NOTICES_SOURCE="fetched"
    fi
fi

if [[ -n "$NOTICES_SOURCE" && -s "$NOTICES_DEST" ]]; then
    ok "Third-party attributions installed (source: ${NOTICES_SOURCE})"
    info "View any time with: bash install.sh --licenses"
else
    warn "Could not install THIRD_PARTY_NOTICES.md (non-fatal)."
    warn "Read the public version at https://ostler.ai/licenses.html"
fi

# Companion: install the LICENSES/ directory containing canonical licence
# texts for every SPDX identifier referenced in THIRD_PARTY_NOTICES.md.
# Same source preference as the NOTICES file.
LICENSES_DEST="${OSTLER_DIR}/LICENSES"
LICENSES_SOURCE=""

if [[ -d "${SCRIPT_DIR}/LICENSES" ]]; then
    mkdir -p "$LICENSES_DEST"
    cp -R "${SCRIPT_DIR}/LICENSES/"* "$LICENSES_DEST/"
    LICENSES_SOURCE="bundled"
elif [[ -n "${HUB_POWER_TMP:-}" && -d "${HUB_POWER_TMP}/LICENSES" ]]; then
    mkdir -p "$LICENSES_DEST"
    cp -R "${HUB_POWER_TMP}/LICENSES/"* "$LICENSES_DEST/"
    LICENSES_SOURCE="cloned (HR015)"
elif [[ -n "$NOTICES_BASE_URL" ]] && command -v curl >/dev/null 2>&1; then
    # Best-effort fetch of canonical licence texts from the
    # operator-provided base URL. Files are small and stable.
    # Non-fatal if any fail.
    mkdir -p "$LICENSES_DEST"
    LICENSES_BASE="${NOTICES_BASE_URL}/LICENSES"
    LICENSES_FETCHED=0
    for f in Apache-2.0.txt MIT.txt BSD-2-Clause.txt BSD-3-Clause.txt Zlib.txt MPL-2.0.txt README.md MODELS.md; do
        if curl -fsSL --max-time 30 "${LICENSES_BASE}/${f}" -o "${LICENSES_DEST}/${f}" 2>/dev/null; then
            LICENSES_FETCHED=$((LICENSES_FETCHED + 1))
        fi
    done
    if [[ "$LICENSES_FETCHED" -gt 0 ]]; then
        LICENSES_SOURCE="fetched (${LICENSES_FETCHED} files)"
    fi
fi

if [[ -n "$LICENSES_SOURCE" ]]; then
    ok "Licence texts installed at ${LICENSES_DEST}/ (source: ${LICENSES_SOURCE})"
else
    warn "Could not install LICENSES/ directory (non-fatal)."
fi

# ── 3.15 Tailscale (so the iOS / Watch companion can reach this Mac) ─
#
# Ostler's iOS companion app talks to this Mac's API at port 8089.
# On the home Wi-Fi the LAN IP works; out and about it doesn't. Tailscale
# gives this Mac a stable private IP (100.x.x.x) reachable from your
# phone anywhere, encrypted end-to-end, with no public exposure.
# Free for personal use up to 100 devices. Skipping this step is fine
# if you never use Ostler's companion away from home Wi-Fi.

OSTLER_TAILSCALE_IP=""

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Tailscale (recommended for iOS / Watch companion)${NC}"
echo ""
echo "  Tailscale gives this Mac a stable private IP your phone can"
echo "  reach from anywhere — encrypted, no public exposure, free for"
echo "  personal use. Without it, the iOS companion only works on"
echo "  your home Wi-Fi."
echo ""
read -p "  Install Tailscale now? (Y/n): " TAILSCALE_CONFIRM

if [[ "${TAILSCALE_CONFIRM:-y}" != "n" && "${TAILSCALE_CONFIRM:-y}" != "N" ]]; then
    if ! command -v tailscale &>/dev/null && [[ ! -d "/Applications/Tailscale.app" ]]; then
        info "Installing Tailscale..."
        brew install --cask tailscale 2>/dev/null && \
            ok "Tailscale installed" || \
            warn "Tailscale install failed — you can install it later from tailscale.com"
    else
        ok "Tailscale already installed"
    fi

    # Open the Tailscale app — first launch prompts for sign-in. Subsequent
    # launches noop. Wait for it to come up.
    if [[ -d "/Applications/Tailscale.app" ]]; then
        open -gj -a Tailscale 2>/dev/null || true
        sleep 3
    fi

    # The CLI lives at /Applications/Tailscale.app/Contents/MacOS/Tailscale
    # OR in PATH if Homebrew formula. Find it.
    TS_CLI=""
    if command -v tailscale &>/dev/null; then
        TS_CLI="tailscale"
    elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
        TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    fi

    if [[ -n "$TS_CLI" ]]; then
        # Wait up to 60s for the user to sign in (Tailscale.app shows a sign-in
        # window or menu-bar item). Once authenticated, `tailscale ip --4`
        # prints the IPv4 address.
        # 180s window: a non-technical user reading the prompt, switching
        # to the GUI, completing OAuth (Apple/Google/Microsoft sign-in
        # with possible 2FA), and returning easily eats 2-3 minutes.
        # 60s is too short and was the most-tripped Phase-3 timeout in
        # the install audit (~2026-05-01).
        info "Waiting for you to sign in to Tailscale (up to 3 minutes)..."
        info "If a Tailscale window appears, sign in with Apple / Google / Microsoft."
        TS_WAIT=0
        while [[ -z "$OSTLER_TAILSCALE_IP" && $TS_WAIT -lt 180 ]]; do
            OSTLER_TAILSCALE_IP=$("$TS_CLI" ip --4 2>/dev/null | head -1 || true)
            if [[ -z "$OSTLER_TAILSCALE_IP" ]]; then
                sleep 3
                TS_WAIT=$((TS_WAIT + 3))
            fi
        done

        if [[ -n "$OSTLER_TAILSCALE_IP" ]]; then
            ok "Tailscale IP: ${OSTLER_TAILSCALE_IP}"
            echo "  Use this address in the Ostler iOS companion app:"
            echo "    http://${OSTLER_TAILSCALE_IP}:8089"
            # Persist to .env (replace existing line if present, append otherwise)
            ENV_FILE="${CONFIG_DIR}/.env"
            if [[ -f "$ENV_FILE" ]]; then
                if grep -q "^OSTLER_TAILSCALE_IP=" "$ENV_FILE"; then
                    # In-place rewrite of the line. Trap ensures the
                    # temp file is cleaned up even if sed or mv fails
                    # partway through (disk full, interrupted signal).
                    TMP_ENV=$(mktemp)
                    trap 'rm -f "$TMP_ENV"' EXIT
                    sed "s|^OSTLER_TAILSCALE_IP=.*|OSTLER_TAILSCALE_IP=\"${OSTLER_TAILSCALE_IP}\"|" "$ENV_FILE" > "$TMP_ENV"
                    mv "$TMP_ENV" "$ENV_FILE"
                    trap - EXIT
                else
                    echo "OSTLER_TAILSCALE_IP=\"${OSTLER_TAILSCALE_IP}\"" >> "$ENV_FILE"
                fi
            fi
        else
            warn "Tailscale didn't sign in within 60 seconds. You can come back to this later."
            warn "Run 'tailscale ip --4' once signed in, then add the address to the iOS app."
        fi
    else
        warn "Could not find the Tailscale CLI. You can configure it manually later."
    fi
fi

# ── 3.16 Wiki (Andypedia) -- first compile and serve ─────────────────
#
# Resolves install UX BLOCKING #1: the customer's first encounter
# with Ostler is a browsable, human-readable wiki at
# http://localhost:8044, not Qdrant raw vectors and a SPARQL form.
# CM044 produces a wiki-compiler that builds an MkDocs Material site
# from the live Oxigraph + Qdrant state; piece 1 of this brief added
# both services to the compose stack. This phase invokes the first
# compile and starts the wiki-site container.
#
# Empty-wiki path: when the user has not run `ostler-import` yet,
# Oxigraph has no Person triples and the compiler produces a
# placeholder index page (see CM044 for the empty-wiki UX). The
# install does NOT fail in that case -- the wiki simply says
# "your wiki will populate after your first import" and the user
# follows the next-steps banner.
#
# Image source open question: the wiki-site / wiki-compiler images
# may not be pullable from a public registry yet. If the docker
# compose run fails with "manifest unknown" or similar, this phase
# warn-logs and continues -- the data layer (Phase 3.8) is already
# up, so the user has everything except the wiki UI. Piece 1's PR
# body documents the pre-built-vs-build-at-install decision.

progress "Compiling your personal wiki (first run)"

# Make sure the user-facing Wiki tree (created in Phase 3 by the
# user-tree block) plus the Wiki/_images/ subdirectory both
# exist BEFORE the first compile, so the host bind-mounts in
# the wiki-compiler service have a real directory to point at.
# Docker's auto-create on bind would otherwise root-own the dir
# (Docker Desktop) or fail (Colima), neither of which the
# customer would diagnose. mkdir -p is idempotent so re-runs
# of install.sh are harmless.
mkdir -p "${USER_FACING_ROOT}/Wiki" "${USER_FACING_ROOT}/Wiki/_images"

WIKI_FIRST_COMPILE_OK=false
cd "$OSTLER_DIR"
if docker compose --profile compile run --rm wiki-compiler 2>&1 | tail -10; then
    if docker compose up -d wiki-site 2>&1 | tail -3; then
        WIKI_FIRST_COMPILE_OK=true
        ok "Wiki running at http://localhost:8044"
    else
        warn "Wiki compiled but wiki-site container failed to start."
        warn "  Try: docker compose -f ${OSTLER_DIR}/docker-compose.yml up -d wiki-site"
    fi
else
    warn "Wiki first-compile failed. Common causes:"
    warn "  - ostler-wiki-compiler image not yet pullable (registry not wired)"
    warn "  - Oxigraph not yet healthy at this phase (check logs above)"
    warn "  - Insufficient disk for the wiki output volume"
    warn "  Manual retry once the cause is resolved:"
    warn "    cd ${OSTLER_DIR}"
    warn "    docker compose --profile compile run --rm wiki-compiler"
    warn "    docker compose up -d wiki-site"
fi

# ══════════════════════════════════════════════════════════════════════
#  PHASE 4: HEALTH CHECK + COMPLETION
# ══════════════════════════════════════════════════════════════════════

# Stop the Phase 3 battery watcher so its poll messages don't interleave
# with the health-check output. The hub-power LaunchAgent installed at
# 3.14 is now responsible for battery awareness from here on.
cleanup_battery_watch

step "Running health check"

HEALTHY=true

if curl -sf http://localhost:6333/healthz &>/dev/null; then
    ok "Qdrant healthy"
else
    warn "Qdrant not responding"
    HEALTHY=false
fi

if curl -sf http://localhost:7878/ &>/dev/null; then
    ok "Oxigraph healthy"
else
    warn "Oxigraph not responding"
    HEALTHY=false
fi

if docker exec ostler-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    ok "Redis healthy"
else
    warn "Redis not responding"
    HEALTHY=false
fi

if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    ok "Ollama healthy"
else
    warn "Ollama not responding"
    HEALTHY=false
fi

# Vane (local web search) is optional. Surface it in the health
# check so the customer can see whether it is running, but do NOT
# flip the install-wide HEALTHY flag if it is missing -- the
# rest of Ostler works without it (Phase 3.8b is warn-only too).
if curl -sf -o /dev/null -m 3 http://localhost:3000; then
    ok "Vane healthy (local web search)"
else
    info "Vane not responding (optional; see Phase 3.8b warnings)"
fi

# ── ostler-assistant doctor probe (best-effort, non-fatal) ────────
#
# Surfaces the cron-delivery + imessage-tcc posture markers that
# piece D of the cron-fix stack added in ostler-assistant. The
# daemon may not be fully booted when the installer reaches this
# point (channels still connecting, first cron sync in progress);
# any failure here is logged as deferred, not as an install error.
# Operators are reminded to re-run `ostler-assistant doctor` after
# first launch to verify.
#
# See piece D / task #278 of the cron diagnosis brief.

if [[ -x "${ASSISTANT_BINARY:-}" ]]; then
    DOCTOR_OUTPUT=$(timeout 10 "${ASSISTANT_BINARY}" doctor 2>&1) || \
        DOCTOR_OUTPUT="__DOCTOR_INVOCATION_FAILED__"

    if [[ "$DOCTOR_OUTPUT" == "__DOCTOR_INVOCATION_FAILED__" ]]; then
        info "ostler-assistant doctor: deferred (daemon may still be"
        info "  starting; run \`ostler-assistant doctor\` after first"
        info "  launch to verify cron-delivery + imessage-tcc posture)."
    else
        # Count error markers in the human-readable output. The
        # doctor module emits ❌ for Severity::Error and prefixes
        # the category. We do not fail the install here -- we just
        # surface the count so the operator knows to re-run.
        DOCTOR_ERRORS=$(printf '%s\n' "$DOCTOR_OUTPUT" | grep -c '❌' 2>/dev/null || echo 0)
        if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
            warn "ostler-assistant doctor reported ${DOCTOR_ERRORS} error(s)."
            warn "  Run \`${ASSISTANT_BINARY} doctor\` after first launch"
            warn "  to inspect. cron-delivery / imessage-tcc are common"
            warn "  early markers (channels still connecting + Apple"
            warn "  Events permission for Messages.app)."
            # Intentionally leaving the install HEALTHY flag
            # untouched: the daemon is still in startup grace at
            # install time; the markers may flip to OK on their own
            # once channels finish booting. Operator re-runs the
            # doctor command after first launch to verify.
        else
            ok "ostler-assistant doctor: no errors detected"
        fi
    fi
else
    info "ostler-assistant binary not installed; skipping doctor probe"
fi

# ── Show recovery key (saved from Phase 2/3) ──────────────────────

if [[ -n "$RECOVERY_KEY" ]]; then
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Your recovery key:${NC}"
    echo ""
    echo -e "    ${YELLOW}${BOLD}${RECOVERY_KEY}${NC}"
    echo ""

    # Offer to save to macOS Keychain automatically
    SAVED_TO_KEYCHAIN=false
    echo "  We can save this to your macOS Keychain (Passwords app)"
    echo "  so you do not have to write it down."
    echo ""
    read -p "  Save recovery key to Keychain? (Y/n): " SAVE_KEYCHAIN
    if [[ "${SAVE_KEYCHAIN:-y}" != "n" && "${SAVE_KEYCHAIN:-y}" != "N" ]]; then
        # Prefer an explicit Security.framework call so we can pin the
        # accessibility class to kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        # and kSecAttrSynchronizable=false. This keeps the recovery key
        # out of Time Machine backups and Migration Assistant – matching
        # OstlerPasskeyHelper / CM031 / ostler_security elsewhere.
        # The `security` CLI cannot set these attributes, so we shell
        # out to swift when available, and fall back to the CLI otherwise.
        SAVED_TO_KEYCHAIN_VIA="cli"
        SWIFT_BIN=""
        if command -v swift &>/dev/null; then
            SWIFT_BIN="swift"
        elif xcrun -f swift &>/dev/null 2>&1; then
            SWIFT_BIN="$(xcrun -f swift)"
        fi
        if [[ -n "$SWIFT_BIN" ]]; then
            KC_HELPER=$(mktemp -t ostler-kc.XXXXXX.swift)
            cat > "$KC_HELPER" << 'SWIFTEOF'
import Foundation
import Security
guard
    let service = ProcessInfo.processInfo.environment["KC_SERVICE"],
    let account = ProcessInfo.processInfo.environment["KC_ACCOUNT"],
    let password = ProcessInfo.processInfo.environment["KC_PASSWORD"],
    let pwData = password.data(using: .utf8)
else { exit(2) }
let baseQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
]
SecItemDelete(baseQuery as CFDictionary)
var addQuery = baseQuery
addQuery[kSecValueData as String] = pwData
addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
addQuery[kSecAttrSynchronizable as String] = NSNumber(value: false)
let status = SecItemAdd(addQuery as CFDictionary, nil)
exit(status == errSecSuccess ? 0 : 1)
SWIFTEOF
            if KC_SERVICE="Ostler Recovery Key" \
               KC_ACCOUNT="${USER_ID}" \
               KC_PASSWORD="${RECOVERY_KEY}" \
               "$SWIFT_BIN" "$KC_HELPER" 2>/dev/null; then
                SAVED_TO_KEYCHAIN_VIA="swift"
                ok "Recovery key saved to Keychain (search 'Ostler' in Passwords app)"
                SAVED_TO_KEYCHAIN=true
            fi
            rm -f "$KC_HELPER"
        fi
        # Fallback: `security` CLI. Default accessibility class is
        # kSecAttrAccessibleWhenUnlocked (item travels in Time Machine
        # backups / Migration Assistant). Acceptable for first-run when
        # swift isn't available – the user is told to write it down.
        if [[ "$SAVED_TO_KEYCHAIN" == false ]]; then
            if security add-generic-password \
                -a "${USER_ID}" \
                -s "Ostler Recovery Key" \
                -w "${RECOVERY_KEY}" \
                -T "" \
                -U 2>/dev/null; then
                ok "Recovery key saved to Keychain (search 'Ostler' in Passwords app)"
                SAVED_TO_KEYCHAIN=true
            else
                warn "Could not save to Keychain. Please write it down."
            fi
        fi
    fi

    if [[ "$SAVED_TO_KEYCHAIN" == false ]]; then
        echo -e "  ${RED}WRITE THIS DOWN NOW. It will not be shown again.${NC}"
        echo ""
        echo "  Store it in one of these places:"
        echo "    • Passwords app (search 'Ostler')"
        echo "    • Print it and keep it somewhere safe"
        echo "    • Apple Notes with a locked note"
    fi

    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# ── Summary ────────────────────────────────────────────────────────

INSTALL_END=$(date +%s)
INSTALL_DURATION=$(( INSTALL_END - INSTALL_START ))
INSTALL_MINS=$(( INSTALL_DURATION / 60 ))
INSTALL_SECS=$(( INSTALL_DURATION % 60 ))

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "$HEALTHY" == true ]]; then
    echo -e "${GREEN}${BOLD}  Ostler is running!${NC}"
else
    echo -e "${YELLOW}${BOLD}  Ostler is partially running (check warnings above)${NC}"
fi

echo ""
echo -e "  ${BOLD}What was installed:${NC}"
echo "     User:          ${USER_NAME} (${USER_ID})"
echo "     Assistant:     ${ASSISTANT_NAME}"
echo "     Timezone:      ${USER_TZ}"
echo "     Country code:  +${COUNTRY_CODE}"
echo "     AI model:      ${AI_MODEL}"
[[ "$FV_ENABLED" == true ]] && echo "     FileVault:     Enabled"
[[ -f "${SECURITY_CONFIG_DIR}/keychain.json" ]] && echo "     Encryption:    Databases encrypted with passphrase"
[[ -n "$CONTACT_COUNT" && "$CONTACT_COUNT" -gt 0 ]] && echo "     Contacts:      ${CONTACT_COUNT} exported from iCloud"
[[ -n "$EXPORTS_DIR" ]] && echo "     GDPR import:   Processed from ${EXPORTS_DIR}"
[[ "${FDA_OK:-0}" -gt 0 ]] && echo "     Instant data:  ${FDA_OK} macOS source(s) extracted"
echo "     Duration:      ${INSTALL_MINS}m ${INSTALL_SECS}s"
echo ""

# ── Next steps ─────────────────────────────────────────────────────

echo -e "  ${BOLD}Next steps:${NC}"
echo ""
if [[ -z "$EXPORTS_DIR" ]]; then
echo -e "  1. ${BOLD}Request your GDPR data exports${NC} (takes 1-3 days):"
echo "     - LinkedIn: Settings > Data Privacy > Get a copy of your data"
echo "     - Facebook: Settings > Your information > Download your information"
echo "     - Instagram: Settings > Your activity > Download your information"
echo "     - Google:    takeout.google.com (select Calendar)"
echo "     - Twitter:   Settings > Your account > Download an archive"
echo "     - WhatsApp:  Settings > Account > Request account info"
echo ""
echo "  2. Once exports arrive, import them:"
echo -e "     ${BOLD}ostler-import ~/Downloads/gdpr-exports/ \\${NC}"
echo -e "     ${BOLD}    --user-name \"${USER_NAME}\" --verbose${NC}"
echo ""
echo -e "  3. ${BOLD}Connect your accounts${NC} (see POST_INSTALL_SETUP.md):"
else
echo -e "  1. ${BOLD}Connect your accounts${NC} (see POST_INSTALL_SETUP.md):"
fi
echo "     - iCloud sign-in (for iMessage)"
echo "     - iCloud Calendar (app-specific password)"
echo "     - Gmail (OAuth via gws CLI)"
echo "     - WhatsApp (pair code linking)"
echo ""
# Primary user-facing URL: the wiki. This is the everything-Ostler
# dashboard the customer opens in a browser. The dev / debug
# dashboards below are available but de-emphasised so the next-
# steps banner reads as "go look at your wiki" rather than "here
# are five raw API surfaces". Resolves install UX BLOCKING #1.
if [[ "$WIKI_FIRST_COMPILE_OK" == true ]]; then
    echo -e "  ${BOLD}Your wiki:${NC} http://localhost:8044"
else
    echo "  Your wiki:  not yet available (first compile failed -- see warnings above)"
fi

# Channel summary: tell the customer how to actually talk to the
# assistant they just named. Lines only appear when the section 4a
# wizard captured a config; "skip for now" gets the manual-setup
# hint instead so the user never lands at a quiet assistant
# without knowing what to do.
if [[ "$CHANNEL_IMESSAGE_ENABLED" == true || "$CHANNEL_EMAIL_ENABLED" == true ]]; then
    echo ""
    if [[ "${ASSISTANT_BINARY_INSTALLED:-false}" == true ]]; then
        echo -e "  ${GREEN}${BOLD}Your assistant ${ASSISTANT_NAME} is running.${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}${ASSISTANT_NAME}'s binary did not install -- channels are configured but no daemon is up.${NC}"
        echo "  See warnings above for the download / extract failure."
    fi
    echo -e "  ${BOLD}Talk to ${ASSISTANT_NAME}:${NC}"
    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
        echo "     - iMessage from: ${CHANNEL_IMESSAGE_ALLOWED}"
    fi
    if [[ "$CHANNEL_EMAIL_ENABLED" == true ]]; then
        echo "     - Email to:     ${CHANNEL_EMAIL_USERNAME}"
    fi
    echo "     (edit ${OSTLER_DIR}/assistant-config/config.toml to change)"
elif [[ -n "${CHANNEL_CHOICE:-}" && "$CHANNEL_CHOICE" == "4" ]]; then
    echo ""
    echo "  No channels configured. Set one up later via:"
    echo "     ${OSTLER_DIR}/bin/ostler-assistant setup channels --interactive"
fi
echo ""
if [[ "$VANE_OK" == true ]]; then
    echo -e "  ${BOLD}Local web search:${NC} http://localhost:3000"
    echo "     (your assistant uses this; you can also chat with it directly)"
    echo ""
fi
echo "  Developer dashboards:"
echo "     - Qdrant:   http://localhost:6333/dashboard"
echo "     - Oxigraph: http://localhost:7878"
echo "     - Doctor:   http://localhost:8089/doctor"
echo ""
echo -e "  Config:    ${CONFIG_DIR}/.env"
echo -e "  Data:      ${DATA_DIR}"
echo -e "  Logs:      ${LOGS_DIR}"
echo ""
# ── Mac Mini Hub vs MacBook Hub ────────────────────────────────────
#
# If the hub-power LaunchAgent installed, tell the user which SKU
# they are running and how to tune it. Detecting battery presence is
# cheap: pmset reports a percentage only on machines with a battery.

HAS_BATTERY=false
if pmset -g batt 2>/dev/null | grep -qE '[0-9]+%'; then
    HAS_BATTERY=true
fi

echo -e "  ${BOLD}Hub deployment:${NC}"
if [[ "$HAS_BATTERY" == true ]]; then
    echo "     MacBook Hub. Docker + Ollama will pause automatically when"
    echo "     you unplug, and resume when you plug back in. Battery life"
    echo "     stays roughly as it was before Ostler."
else
    echo "     Mac Mini / Studio Hub. Always-on AC: nothing is paused."
    echo "     hub-power sees tier 'ac' every tick and takes no action."
fi
if [[ -f "${HOME}/.ostler/power.conf" ]]; then
    echo "     Policy override: edit ~/.ostler/power.conf"
    echo "                      (POWER_POLICY=normal | aggressive | eco)"
fi
echo ""
echo -e "  ${BOLD}Need help?${NC}"
echo "    During beta, email support@creativemachines.ai."
echo "    A dedicated support@creativemachines.ai address will be"
echo "    live by general launch."
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
