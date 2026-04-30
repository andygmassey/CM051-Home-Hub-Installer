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
#     enrichment, optional web search) and model/software downloads are
#     described in the privacy policy.
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
        echo "  https://creativemachines.ai/ostler/licenses.html"
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
    echo "public-data queries (Wikidata for enrichment, optional web search via"
    echo "SearXNG) and downloads model and software updates. See the privacy"
    echo "policy at creativemachines.ai/ostler/legal-privacy for full detail."
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
fail()  { echo -e "${RED}[fail]${NC}  $*"; exit 1; }
step()  { echo -e "\n${BOLD}==> $*${NC}"; }

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_DIR="${OSTLER_DIR}/security-module"
SECURITY_CONFIG_DIR="${OSTLER_DIR}/security"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"

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
    ASSISTANT_NAME="${ASSISTANT_NAME:-Marvin}"
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
end tell' 2>/dev/null || echo "")

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

read -p "  Assistant name [Marvin]: " ASSISTANT_NAME
ASSISTANT_NAME=${ASSISTANT_NAME:-Marvin}

ok "Your assistant is called ${ASSISTANT_NAME}"

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
# FDA_DIR is the PARENT — the package lives at FDA_DIR/lifeline_fda/
FDA_DIR="${OSTLER_DIR}/fda-module"
HAS_FDA_MODULE=false
if [[ -d "${SCRIPT_DIR}/lifeline_fda" ]]; then
    mkdir -p "$FDA_DIR"
    cp -R "${SCRIPT_DIR}/lifeline_fda" "$FDA_DIR/"
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
echo "  outbound queries for public-data enrichment and (optional) web search,"
echo "  plus model/software updates. Full detail in the privacy policy."
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
echo -e "  ${GREEN}${BOLD}  All questions answered. Installing now.${NC}"
NEEDS_HOMEBREW=false
if ! command -v brew &>/dev/null; then
    NEEDS_HOMEBREW=true
    echo -e "  ${YELLOW}  Note: Homebrew install will ask for your Mac password once.${NC}"
    echo -e "  ${YELLOW}  After that, everything is fully unattended.${NC}"
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
        info "macOS will now ask for your Mac login password to change this setting."
        sudo pmset -c sleep 0 2>/dev/null && \
        sudo pmset -a womp 1 2>/dev/null && \
        ok "Sleep disabled on AC, battery sleep preserved, wake-on-network enabled" || \
        warn "Could not change sleep settings. Enable 'Prevent automatic sleeping when plugged in' in System Settings > Energy."
    else
        info "Desktop Hub (no battery) detected: disabling sleep system-wide"
        info "macOS will now ask for your Mac login password to change this setting."
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

# Per-source FDA consent — comma-separated list of enabled sources.
# Set in Phase 2 (or read from a previous install on re-run). Read by
# lifeline_fda.extract_all via the OSTLER_FDA_SOURCES env var.
OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES:-safari_history,safari_bookmarks,apple_notes,calendar,reminders}"

# If a Google Takeout mbox is registered, point extract_all at it.
OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}"

# Tailscale IPv4 for this Mac. Set in 3.14 by the installer if Tailscale
# was installed and signed in. Used by the iOS / Watch companion to reach
# this Mac from anywhere. Empty if Tailscale is not in use.
OSTLER_TAILSCALE_IP="${OSTLER_TAILSCALE_IP:-}"
ENVEOF

ok "Config saved to ${CONFIG_DIR}/.env"

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
    info "(If macOS asks for Full Disk Access, grant it for faster onboarding."
    info " You can skip it – Ostler works without it, just with less data.)"
    echo ""

    # Pass user's per-source consent (set in Phase 2) to the extractor.
    FDA_OUTPUT=$(OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES}" \
                 OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}" \
                 "$OSTLER_PYTHON" -c "
import sys, json
sys.path.insert(0, '${FDA_DIR}')
from lifeline_fda.extract_all import run_all
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

volumes:
  qdrant_data:
  oxigraph_data:
  redis_data:
DCEOF

cd "$OSTLER_DIR"
docker compose up -d
ok "Services started (Qdrant :6333, Oxigraph :7878, Redis :6379)"

# ── 3.9 AI models ─────────────────────────────────────────────────

progress "Downloading AI models (this is the big one)"

if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    ok "nomic-embed-text already available"
else
    info "Pulling nomic-embed-text (274 MB)..."
    ollama pull nomic-embed-text
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
        ollama pull "$AI_MODEL"
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

if [[ ! -d "$FDA_DIR/lifeline_fda" ]]; then
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
from lifeline_fda.extract_all import run_all
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
echo ""
echo "  Ostler Uninstaller"
echo ""
echo "  This will remove:"
echo "    - Docker containers (ostler-qdrant, ostler-oxigraph, ostler-redis)"
echo "    - Docker volumes (your knowledge graph data)"
echo "    - Ostler directory (~/.ostler, except power.conf)"
echo "    - Doctor, export watcher, and hub power launchd services"
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
launchctl bootout "gui/$(id -u)/com.creativemachines.lifeline.hub-power" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.lifeline.hub-power.plist" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.it-guy.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.lifeline.hub-power.plist"

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

echo ""
echo "  Done. Ostler has been removed."
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
        <string>8090</string>
        <key>DOCTOR_SUPPORT_EMAIL</key>
        <string>support@creativemachines.ai</string>
    </dict>
</dict>
</plist>
DOCEOF

    # Use bootstrap on Sequoia+ (load is deprecated), fall back to load
    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "Ostler Doctor running at http://localhost:8090/doctor"
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
        ok "Hub power LaunchAgent loaded (label com.creativemachines.lifeline.hub-power)"
        info "Policy override: edit ~/.ostler/power.conf (normal / aggressive / eco)"
    else
        warn "Hub power LaunchAgent install failed. See output above."
        warn "Mac Mini deployments are unaffected; MacBook users should retry."
    fi
fi

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
    warn "Read the public version at https://creativemachines.ai/ostler/licenses.html"
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
        info "Waiting for you to sign in to Tailscale (up to 60 seconds)..."
        info "If a Tailscale window appears, sign in with Apple / Google / Microsoft."
        TS_WAIT=0
        while [[ -z "$OSTLER_TAILSCALE_IP" && $TS_WAIT -lt 60 ]]; do
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
        echo "    • Passwords app (search 'Lifeline')"
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
echo "  Dashboards:"
echo "     - Qdrant:   http://localhost:6333/dashboard"
echo "     - Oxigraph: http://localhost:7878"
echo "     - Doctor:   http://localhost:8090/doctor"
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
    echo "     stays roughly as it was before Lifeline."
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
