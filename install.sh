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
NO_EXTENSIONS=false

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        --help|-h) SHOW_HELP=true ;;
        --licenses|--licences) SHOW_LICENSES=true ;;
        --allow-plaintext) ALLOW_PLAINTEXT=1 ;;
        --no-extensions) NO_EXTENSIONS=true ;;
    esac
done

# ── stdin check ────────────────────────────────────────────────────
# When piped via `curl | bash`, stdin is the script not the terminal.
# We need terminal input for confirmations etc, so redirect from /dev/tty.
# Skip for read-only flags so they work in non-interactive contexts.
if [[ "$SHOW_HELP" != true && "$SHOW_LICENSES" != true && ! -t 0 && "${OSTLER_GUI:-0}" != "1" ]]; then
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
    echo "  --no-extensions     Skip the browser-extensions install phase"
    echo "                      (Safari .app copy + Chrome Web Store open)."
    echo "                      The Hub still works; you just enable"
    echo "                      browsing capture later by hand."
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
    echo "  OSTLER_INSTALLER_TARBALL_SHA256"
    echo "    Expected SHA-256 (hex) of the install tarball. The download"
    echo "    is verified against this digest before extraction; a"
    echo "    mismatch fails the install closed (no tar -xzf, no exec)."
    echo "    Two-key trust model: an attacker would need to compromise"
    echo "    BOTH the tarball at OSTLER_INSTALLER_TARBALL_URL AND this"
    echo "    install.sh on Cloudflare to bypass it."
    echo "    Empty string skips verification (dev-mode escape, not for"
    echo "    production). Required when overriding TARBALL_URL to a"
    echo "    self-staged tarball."
    echo "    Default: pinned to the most recent ostler-installer release."
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
    echo "  PWG_DOCTOR_REPO"
    echo "    Source repo for the Ostler Doctor diagnostic dashboard"
    echo "    (HR015 doctor/agent/ subtree). Default: empty (productised"
    echo "    tarball bundles the agent). Set to a clone URL if you are"
    echo "    running install.sh directly without a tarball; without it"
    echo "    the Doctor LaunchAgent is skipped with a warn-only message."
    echo ""
    echo "  PWG_KNOWLEDGE_REPO"
    echo "    Source repo for the Knowledge service (CM024 Evernote ingest)."
    echo "    Default: empty (Knowledge service skipped warn-only; the"
    echo "    Doctor 'Import Evernote' surface, when the feature flag is"
    echo "    eventually flipped on, will surface 'service unavailable')."
    echo "    Set to a clone URL pointing at a tagged release SHA of the"
    echo "    evernote-knowledge repo to install ostler-knowledge into"
    echo "    a dedicated venv at ~/.ostler/services/knowledge/."
    echo ""
    echo "  PWG_CM048_REPO"
    echo "    Source repo for the CM048 conversation processing pipeline."
    echo "    Default: empty (productised tarball bundles the pipeline at"
    echo "    Contents/Resources/cm048_pipeline/; install.sh discovers it"
    echo "    and pip-installs into a dedicated venv at"
    echo "    ~/.ostler/services/cm048/). Set to a clone URL for dev or"
    echo "    private-beta installs. Missing pipeline AND no override is"
    echo "    a hard fail unless --allow-plaintext is passed."
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
    echo "  PWG_IMESSAGE_PROBE_OUTCOME"
    echo "    Test-only override for the install-time iMessage TCC probe"
    echo "    in Phase 3.18. When set, the probe skips osascript and uses"
    echo "    the value verbatim. Accepted values:"
    echo "    granted-and-working | tcc-denied | check-failed."
    echo "    Real macOS installs leave this unset."
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
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

# Default no-op stubs for the GUI helpers so any info/warn/err call
# that fires before SCRIPT_DIR is resolved + lib/progress_emitter.sh
# is sourced does not error out. The real helpers are installed
# later, after SCRIPT_DIR is known. They are also installed by the
# fallback path if the lib file is missing entirely.
gui_emit()        { :; }
gui_step_begin()  { :; }
gui_step_end()    { :; }
gui_log()         { :; }
gui_warn()        { :; }
gui_phase()       { :; }
gui_done()        { :; }
gui_active()      { return 1; }
gui_needs_sudo()  { :; }
gui_needs_fda()   { :; }

# When OSTLER_GUI=1 the structured gui_log / gui_warn markers already
# carry the message to the GUI Log drawer; the additional TTY echo
# then collides with formatBuffer's own `[INFO ]`/`[WARN ]` prefix
# (the rawLine path in Verbose mode picks the `[info]`/`[warn]`
# bracket text up and renders it pasted in next to the proper level
# marker, producing the noisy `[INFO ] [info]  ...` pattern Andy saw
# as `[INFO[]` in his Mac Studio install log on 2026-05-19). Suppress
# the TTY echo when the GUI is driving so only the structured marker
# surfaces.
info()  { gui_active || echo -e "${BLUE}[info]${NC}  $*"; gui_log info "$*"; }
ok()    { gui_active || echo -e "${GREEN}[ok]${NC}    $*"; gui_log info "$*"; }
warn()  { gui_active || echo -e "${YELLOW}[warn]${NC}  $*"; gui_warn "$*"; }
# Used by hard-fail paths that need to surface a security or
# integrity message. Goes to stderr so it never gets swallowed by
# tee /dev/null on the calling side; keeps red [ERROR] colour to
# match the visual class of `fail` (which exits) without exiting
# itself -- caller decides whether to exit or recover.
err()   { gui_active || printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; gui_log error "$*"; }
fail()  { gui_active || echo -e "${RED}[fail]${NC}  $*"; gui_log error "$*"; gui_done fail; exit 1; }

# step() opens a top-level section ("==> Title"). When OSTLER_GUI=1,
# also emits a PHASE marker so the GUI sidebar can swap to the next
# top-level chunk. Optional 2nd arg = stable id; if omitted, derived
# from the title.
step()  {
    local title="$1"
    local id="${2:-}"
    if [[ -z "$id" ]]; then
        id="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"
        [[ -z "$id" ]] && id="step"
    fi
    echo -e "\n${BOLD}==> $title${NC}"
    gui_phase "$id" "$title"
}

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
            warn "$(printf "$MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING" "${model}" "${attempt}" "${backoff}")"
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
    # This block fires BEFORE the curl|bash bootstrap extracts the
    # strings catalogue, so it cannot reference MSG_* vars. Dev/CI
    # only flag -- not customer-facing.
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."  # i18n-exempt
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."  # i18n-exempt
    warn "RUNNING WITH --allow-plaintext: encryption disabled. NOT FOR PRODUCTION."  # i18n-exempt
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
DEFAULT_INSTALLER_TARBALL_URL="https://github.com/ostler-ai/ostler-installer/releases/latest/download/install.tar.gz"
INSTALLER_TARBALL_URL="${OSTLER_INSTALLER_TARBALL_URL:-${DEFAULT_INSTALLER_TARBALL_URL}}"

# SHA-256 of the bootstrap tarball. Updated at release time alongside
# the ostler-installer release artefact -- see the release ceremony
# script (release.sh) and RELEASE.md. If you are setting
# OSTLER_INSTALLER_TARBALL_URL to a self-staged tarball, also export
# OSTLER_INSTALLER_TARBALL_SHA256 to its hex digest; an empty string
# means "skip verification" and is reserved for dev-mode use only.
# The sentinel REPLACE_AT_RELEASE_TIME also skips verification (with
# a warning) so pre-release / unconfigured builds do not fail closed
# in dev. release.sh patches this line on the repo-root install.sh
# after building the tarball, so the next release commit pins the
# FINAL SHA of the artefact customers will actually download. The
# inner install.sh inside the tarball stays at the sentinel by
# design (see RELEASE.md "What gets pinned where").
DEFAULT_INSTALLER_TARBALL_SHA256="10a6e8a688a465e1355387e34ed435760104e0ffb06f2e5070dacc8e40fd4e6e"
INSTALLER_TARBALL_SHA256="${OSTLER_INSTALLER_TARBALL_SHA256:-${DEFAULT_INSTALLER_TARBALL_SHA256}}"

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

    # Pre-flight: github.com reachable from this Mac? A 5s probe saves
    # 30s of pointless retries when the issue is network-side (Tailscale
    # exit-node, corporate VPN, DNS, no internet) and surfaces it with a
    # remediation message instead of a cryptic curl error.
    if ! curl --fail --silent --show-error --location \
            --connect-timeout 5 --max-time 8 \
            --output /dev/null https://github.com \
            2>"${BOOTSTRAP_TMPDIR}/preflight.err"; then
        echo
        echo "ERROR: Cannot reach github.com from this Mac."
        echo
        echo "  Detail: $(cat "${BOOTSTRAP_TMPDIR}/preflight.err" 2>/dev/null || echo unknown)"
        echo
        echo "Common causes:"
        echo "  - Tailscale exit-node routing       (try: tailscale down, then re-run)"
        echo "  - Corporate VPN blocking github.com (try: VPN off, then re-run)"
        echo "  - DNS resolver issue                (try: dig +short github.com)"
        echo "  - No internet"
        echo
        echo "Fix the network reach, then re-run the installer."
        exit 1
    fi

    echo "==> Bootstrapping installer tarball from ${INSTALLER_TARBALL_URL}"

    # Retry the tarball fetch up to 3 times with exponential backoff.
    # Today's failure mode (Mac Studio, fresh setup, GitHub CDN flake)
    # was 100% recoverable with a single retry. The single-shot version
    # exited with a cryptic curl-56 from the bash side and burned a
    # demo. Catch transient failures here.
    fetch_ok=0
    for attempt in 1 2 3; do
        if curl --fail --silent --show-error --location \
                --retry-connrefused --retry-all-errors \
                --connect-timeout 10 --max-time 120 \
                --output "${BOOTSTRAP_TMPDIR}/install.tar.gz" \
                "${INSTALLER_TARBALL_URL}" \
                2>"${BOOTSTRAP_TMPDIR}/curl.err"; then
            fetch_ok=1
            break
        fi
        if [[ $attempt -lt 3 ]]; then
            backoff=$((attempt * 2))
            echo "    Attempt ${attempt}/3 failed; retrying in ${backoff}s..."
            sleep "${backoff}"
        fi
    done

    if [[ $fetch_ok -eq 0 ]]; then
        echo
        echo "ERROR: Could not download the installer tarball after 3 attempts."
        echo
        echo "  URL:    ${INSTALLER_TARBALL_URL}"
        echo "  Reason: $(cat "${BOOTSTRAP_TMPDIR}/curl.err" 2>/dev/null || echo unknown)"
        echo
        echo "Recovery (single line, paste in terminal):"
        echo
        echo "  curl -fL ${INSTALLER_TARBALL_URL} -o /tmp/install.tar.gz && OSTLER_INSTALLER_TARBALL_URL=file:///tmp/install.tar.gz bash <(curl -fsSL https://ostler.ai/install.sh)"
        echo
        echo "If that fetch also fails, the issue is GitHub reachability."
        echo "Other options:"
        echo
        echo "  1. Wait until the installer tarball is published. We are tracking"
        echo "     this at https://ostler.ai/launch."
        echo
        echo "  2. Override the tarball URL with one staged elsewhere:"
        echo "       curl -fsSL https://ostler.ai/install.sh | OSTLER_INSTALLER_TARBALL_URL=https://your-host/install.tar.gz bash"
        echo
        echo "  3. Clone the installer repo and run ./install.sh from your"
        echo "     checkout (dev mode), with PWG_PIPELINE_REPO + PWG_HUB_POWER_REPO"
        echo "     set to source repos you have access to."
        echo
        exit 1
    fi

    # Verify SHA-256 of the downloaded tarball before extraction. This is
    # the supply-chain guard: an attacker who replaces the GitHub release
    # artefact must also compromise this install.sh (served via Cloudflare
    # or the OS001 Pages _redirects 302) to match the embedded digest.
    # Fail closed on mismatch. Skip (with WARNING) when the constant is
    # the unconfigured sentinel or the operator has set an empty override
    # (dev-mode escape for self-staged tarballs).
    if [[ -n "${INSTALLER_TARBALL_SHA256}" && "${INSTALLER_TARBALL_SHA256}" != "REPLACE_AT_RELEASE_TIME" ]]; then
        echo "==> Verifying tarball integrity"
        actual_sha=$(shasum -a 256 "${BOOTSTRAP_TMPDIR}/install.tar.gz" | awk '{print $1}')
        if [[ "${actual_sha}" != "${INSTALLER_TARBALL_SHA256}" ]]; then
            echo
            echo "ERROR: Tarball SHA-256 mismatch. Refusing to extract."
            echo
            echo "  Expected: ${INSTALLER_TARBALL_SHA256}"
            echo "  Got:      ${actual_sha}"
            echo "  URL:      ${INSTALLER_TARBALL_URL}"
            echo
            echo "This usually means one of:"
            echo "  - You are running an old install.sh against a new release. Re-fetch:"
            echo "      curl -fsSL https://ostler.ai/install.sh | bash"
            echo "  - The tarball is corrupted. Retry the install in a few minutes."
            echo "  - The tarball does not match what the publisher signed. Stop, do"
            echo "    not extract, and report to security@creativemachines.ai."
            echo
            exit 1
        fi
    else
        echo "==> WARNING: tarball SHA-256 verification skipped (dev mode or pre-release build)"
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

# ── Strings catalogue (Rule 0.9) ──────────────────────────────────
#
# Every customer-facing info/warn/step/ok/err/fail message lives in
# install.sh.strings.<lang>.sh as a MSG_* variable assignment. v1.0
# ships en-GB only; copy the file, translate the right-hand sides,
# and run with OSTLER_LANG=<lang> to localise. Loaded after the
# curl|bash bootstrap re-exec (above) so SCRIPT_DIR points at the
# extracted tarball where the catalogue ships, not at the empty
# stdin process of the first pipe.
OSTLER_LANG="${OSTLER_LANG:-en-GB}"
_STRINGS_FILE="${SCRIPT_DIR}/install.sh.strings.${OSTLER_LANG}.sh"
if [[ ! -f "$_STRINGS_FILE" ]]; then
    # Fall back to en-GB if the requested language file is missing,
    # so a stale OSTLER_LANG env var does not brick the installer.
    _STRINGS_FILE="${SCRIPT_DIR}/install.sh.strings.en-GB.sh"
fi
if [[ -f "$_STRINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$_STRINGS_FILE"
else
    printf 'install.sh: strings catalogue not found at %s\n' "$_STRINGS_FILE" >&2
    printf 'install.sh: this is a packaging bug; please report it.\n' >&2
    exit 1
fi
unset _STRINGS_FILE

# ── GUI progress emitter (sourced) ─────────────────────────────────
#
# Loads helpers `gui_emit`, `gui_step_begin`, `gui_step_end`,
# `gui_read`, `gui_log`, `gui_warn` and friends. Gated by the
# OSTLER_GUI=1 env var; when unset every helper is a silent no-op so
# the curl|bash TTY path stays byte-for-byte identical to today.
#
# Search order:
#   1. ${OSTLER_PROGRESS_EMITTER}                (explicit env override -- tests / staging)
#   2. ${SCRIPT_DIR}/lib/progress_emitter.sh     (tarball / dev / curl|bash bootstrap / .app bundle)
#   3. ${HOME}/.ostler/lib/progress_emitter.sh   (post-install re-run)
#
# Pre-2026-05-13: when none of those resolved, this fell through to a
# silent no-op fallback. That swallowed the bug Andy hit on Mac Studio:
# the CM051 .app bundled progress_emitter.sh at
# Contents/Resources/progress_emitter.sh (no lib/ subfolder), so the
# first test missed it on first run, the second missed it because
# ~/.ostler/ doesn't exist yet on a fresh install, fallback engaged,
# every gui_* call became `:` and the installer hung at "Step 0 of 11"
# forever because no progress markers reached the GUI parser.
#
# Fix shape per HR015/launch/TNM_BRIEF_INSTALL_SH_PROGRESS_EMITTER_BOOTSTRAP_2026-05-13.md:
#   - GUI install (OSTLER_GUI=1) with a missing emitter is a bug,
#     not a graceful degradation. Hard-fail with a re-download
#     instruction so the customer never sits on a silent hang.
#   - TTY install (OSTLER_GUI unset) still wants graceful no-ops
#     because every gui_* call is sprinkled into the script without
#     guards; the no-op'd emitter is the existing contract.
_ostler_emitter_candidate=""
if [[ -n "${OSTLER_PROGRESS_EMITTER:-}" && -f "${OSTLER_PROGRESS_EMITTER}" ]]; then
    _ostler_emitter_candidate="${OSTLER_PROGRESS_EMITTER}"
elif [[ -f "${SCRIPT_DIR}/lib/progress_emitter.sh" ]]; then
    _ostler_emitter_candidate="${SCRIPT_DIR}/lib/progress_emitter.sh"
elif [[ -f "${HOME}/.ostler/lib/progress_emitter.sh" ]]; then
    _ostler_emitter_candidate="${HOME}/.ostler/lib/progress_emitter.sh"
fi

if [[ -n "${_ostler_emitter_candidate}" ]]; then
    # shellcheck source=lib/progress_emitter.sh
    source "${_ostler_emitter_candidate}"
elif [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    # GUI install with no emitter on disk -- install bundle is
    # corrupt or built incorrectly. Surface loudly so the customer
    # re-downloads instead of watching the GUI hang silently.
    echo "FATAL: progress_emitter.sh not found in any expected location." >&2
    echo "  Expected one of:" >&2
    echo "    \$OSTLER_PROGRESS_EMITTER (env override)" >&2
    echo "    ${SCRIPT_DIR}/lib/progress_emitter.sh (bundled .app)" >&2
    echo "    ${HOME}/.ostler/lib/progress_emitter.sh (post-install)" >&2
    echo "  Your install bundle appears corrupt. Please re-download" >&2
    echo "  from https://ostler.ai/install and try again." >&2
    exit 1
else
    # TTY install (no OSTLER_GUI). The gui_* helpers are sprinkled
    # unguarded through install.sh; provide silent no-ops + a minimal
    # `gui_read` so terminal-only operators can still answer prompts.
    gui_emit()        { :; }
    gui_step_begin()  { :; }
    gui_step_end()    { :; }
    gui_read()        {
        # Mirrors the TTY half of the full helper so install.sh keeps
        # working when sourced direct from a terminal. Handles the
        # acknowledge + folder kinds added 2026-05-20 (GUI-only
        # controls degrade to a plain Enter / path prompt in TTY).
        local title="$1" kind="${2:-text}" default_value="${3:-}"
        local user_prompt="  ${title}"
        [[ -n "$default_value" ]] && user_prompt="${user_prompt} [${default_value}]"
        user_prompt="${user_prompt}: "
        local answer=""
        if [[ "$kind" == "secret" ]]; then
            read -r -s -p "$user_prompt" answer || true
            printf '\n' >&2
        elif [[ "$kind" == "acknowledge" ]]; then
            printf '  %s [Enter to continue]: ' "$title" >&2
            read -r answer || true
            [[ -z "$answer" && -n "$default_value" ]] && answer="$default_value"
        else
            read -r -p "$user_prompt" answer || true
        fi
        [[ -z "$answer" && -n "$default_value" ]] && answer="$default_value"
        printf '%s' "$answer"
    }
    gui_log()         { :; }
    gui_warn()        { :; }
    gui_phase()       { :; }
    gui_done()        { :; }
    gui_active()      { return 1; }
    gui_needs_sudo()  { :; }
    gui_needs_fda()   { :; }
fi
unset _ostler_emitter_candidate

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
# These were previously hard-coded to private dev repos, so an
# unauthenticated cold install hit a clone failure (handled non-
# fatally, but produced confusing log noise about repos the user
# had no business knowing about). The migration to a public mirror
# under the ostler-ai / creativemachines-ai orgs is queued; until
# that lands, overrides are how dev / beta installs source these.

# Source repo for the import pipeline (CM041 People Graph). Override:
# PWG_PIPELINE_REPO="https://github.com/your-org/pipeline.git" ./install.sh
PIPELINE_REPO="${PWG_PIPELINE_REPO:-}"

# Hub power policy scripts (MacBook-as-Hub support). Ships in HR015 under
# hub-power/. At release the installer tarball bundles a copy under
# ${SCRIPT_DIR}/hub-power/; in dev it may be symlinked there. Override:
# PWG_HUB_POWER_REPO="https://github.com/your-org/infra.git" ./install.sh
HUB_POWER_REPO="${PWG_HUB_POWER_REPO:-}"

# Ostler Doctor diagnostic dashboard. Ships in HR015 under doctor/agent/.
# Same bundle-or-clone fallback chain as hub-power. Productised tarball
# bundles a copy under ${SCRIPT_DIR}/doctor/agent/; without that and
# without an override the LaunchAgent is skipped warn-only (the rest of
# Ostler runs without Doctor). Override:
# PWG_DOCTOR_REPO="https://github.com/your-org/hr015.git" ./install.sh
DOCTOR_REPO="${PWG_DOCTOR_REPO:-}"

# Knowledge service (CM024 Evernote ingest). Pure on-demand Python CLI
# (ostler-knowledge), installed into a dedicated venv under
# ~/.ostler/services/knowledge/. No daemon -- just a binary on PATH.
# The Doctor "Import Evernote" surface (HR015 brief 3, launch-scope) is
# feature-flagged and OFF by default at v1; the CLI install path here
# is NOT flag-gated -- we always install, the flag only controls UI.
# Override:
# PWG_KNOWLEDGE_REPO="https://github.com/your-org/repo.git" ./install.sh
KNOWLEDGE_REPO="${PWG_KNOWLEDGE_REPO:-}"

# CM048 conversation processing pipeline. Python package providing the
# pwg-convo CLI plus the conversation processor that turns raw human
# transcripts into three-tier output (conversation MD, person signals
# to Oxigraph, user-coach observations). The productised tarball
# bundles a copy under ${SCRIPT_DIR}/cm048_pipeline/; install.sh
# pip-installs it into a dedicated venv at ~/.ostler/services/cm048/
# and symlinks .venv/bin/pwg-convo into /usr/local/bin/pwg-convo so
# Doctor + Marvin + the assistant can invoke it without venv juggling.
# Without bundling AND without an override, the install hard-fails
# (rather than the older silent-skip which only surfaced as confusing
# downstream failures). Pass --allow-plaintext to skip warn-only for
# dev / CI shells. Override:
# PWG_CM048_REPO="https://github.com/your-org/cm048.git" ./install.sh
CM048_REPO="${PWG_CM048_REPO:-}"

# Base URL for fallback fetch of THIRD_PARTY_NOTICES.md and the
# LICENSES/ tree. Same productisation rule: bundled tarball is the
# primary path, raw fetch is the fallback. Empty default keeps the
# productised install from probing a private repo. Set this to the
# raw.githubusercontent.com base URL of any branch holding the
# canonical attribution files (no trailing slash):
# PWG_NOTICES_BASE_URL="https://raw.githubusercontent.com/<org>/<repo>/main"
NOTICES_BASE_URL="${PWG_NOTICES_BASE_URL:-}"

# ══════════════════════════════════════════════════════════════════════
#  PHASE 1: PREREQUISITES (automatic -- no user input)
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

step "$MSG_STEP_CHECKING_PREREQUISITES" "prereq_check"

# ── Licence / activation check ─────────────────────────────────────
#
# Wired in the GUI layer ahead of this script running. Customer flow:
#
#   1. OstlerInstaller.app shows LicenseEntryView (drag-drop the
#      `ostler-licence.json` attachment from the welcome email,
#      or paste its contents).
#   2. `LicenseVerifier` runs Ed25519 signature verification against
#      the embedded production public key (task #332).
#   3. On `.valid`, `InstallerCoordinator.verifyLicense` calls
#      `LicensePersistence.write` which atomically writes the
#      verified payload to `~/.ostler/license/license.json`
#      (mode 0600, parent dir 0700, tmp + fsync + rename + parent
#      fsync). That's the canonical engine-zone path the Sparkle
#      auto-update delegate in ostler-assistant reads at runtime.
#   4. Device fingerprint registration with CM050 runs in parallel
#      (task #340), gated by the same `licenseVerified` flag.
#   5. Only then does the GUI exec this script. So by the time
#      `install.sh` is running, the licence is on disk + verified
#      + the device is registered.
#
# This script therefore does NOT touch the licence file. Anything
# Hub-side that needs licence introspection should read the
# canonical path written by the GUI -- single source of truth.
#
# TODO (post-App Store): StoreKit receipt verification replaces the
# drag-drop flow when the installer is bundled inside a Mac App
# Store app. Out of scope for v1.0 launch.

# macOS check
if [[ "$(uname)" != "Darwin" ]]; then
    fail "$MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT"
fi
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
ok "$(printf "$MSG_OK_MACOS_DETECTED" "${MACOS_VERSION}")"

# Minimum macOS 13 (Ventura) -- needed for modern Docker, Ollama, and security features
if [[ $MACOS_MAJOR -lt 13 ]]; then
    warn "$(printf "$MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13" "${MACOS_VERSION}")"
    warn "$MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY"
fi

# Git / Xcode command line tools -- needed for cloning the pipeline
if ! command -v git &>/dev/null; then
    info "$MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND"
    echo "  macOS will show a dialog -- click 'Install' and wait."
    xcode-select --install 2>/dev/null || true
    # Wait for xcode-select to finish, with a timeout so the installer
    # doesn't hang forever if the user dismisses the install dialog.
    XCODE_WAIT=0
    XCODE_TIMEOUT=600  # 10 minutes -- generous; CLI install is ~150 MB
    until command -v git &>/dev/null; do
        if [[ $XCODE_WAIT -ge $XCODE_TIMEOUT ]]; then
            fail "$MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID"
        fi
        sleep 5
        XCODE_WAIT=$((XCODE_WAIT + 5))
    done
    ok "$MSG_OK_GIT_AVAILABLE"
else
    ok "$MSG_OK_GIT_AVAILABLE"
fi

# Apple Silicon check
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "$MSG_OK_APPLE_SILICON_DETECTED"
else
    warn "$MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED"
fi

# RAM check
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [[ $RAM_GB -lt 16 ]]; then
    fail "$(printf "$MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED" "${RAM_GB}")"
elif [[ $RAM_GB -lt 24 ]]; then
    warn "$(printf "$MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS" "${RAM_GB}")"
else
    ok "$(printf "$MSG_OK_GB_RAM_DETECTED" "${RAM_GB}")"
fi

# Disk space check -- need ~35 GB: Docker images (~1 GB), AI model (5-10 GB),
# embedding model (300 MB), import pipeline + venv (~500 MB), databases (grows
# with data), and headroom for GDPR exports.
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
if [[ $FREE_GB -lt 35 ]]; then
    warn "$(printf "$MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST" "${FREE_GB}")"
    if [[ $FREE_GB -lt 15 ]]; then
        fail "$(printf "$MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE" "${FREE_GB}")"
    fi
else
    ok "$(printf "$MSG_OK_GB_FREE_DISK_SPACE" "${FREE_GB}")"
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
        ok "$MSG_OK_POWER_SOURCE_AC_GOOD_10_15"
    else
        warn "$(printf "$MSG_WARN_POWER_SOURCE" "${POWER_SOURCE:-Battery Power}")"
        warn "$MSG_WARN_PHASE_3_TAKES_10_15_MINUTES"
        warn "$MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP"
        warn "$MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS"
        warn "$MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL"
    fi
else
    ok "$MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO"
fi

# Check Docker availability (don't install yet -- just check)
HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    HAS_DOCKER=true
    ok "$MSG_OK_DOCKER_RUNNING"
elif command -v colima &>/dev/null; then
    info "$MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL"
elif command -v docker &>/dev/null; then
    warn "$MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL"
else
    info "$MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA"
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
    ok "$MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG"
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
    REUSE="$(gui_read "$MSG_PROMPT_REUSE_SETTINGS_TITLE" yesno "" "" "" "reuse_settings")"
    if [[ "${REUSE:-y}" == "n" || "${REUSE:-y}" == "N" ]]; then
        SKIP_PHASE2=false
    fi
fi

if [[ "$SKIP_PHASE2" == false ]]; then

step "$MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK" "setup_questions"

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
echo "  webmail only -- add those accounts to Mac Mail first:"
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
PERMS_OK="$(gui_read "$MSG_PROMPT_PERMS_OK_TITLE" yesno "" "$MSG_PROMPT_PERMS_OK_HELP" "" "perms_ok")"
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

info "$MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL"
echo "  macOS may ask permission to access Contacts."
echo "  This reads your name, country, and phone number to save you typing."
echo "  It also exports your contacts for the knowledge graph."
echo "  (Your data stays on this machine -- nothing is sent anywhere.)"
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
    warn "$MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT"
    warn "$MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM"
    warn "$MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL"
fi
rm -f "$CARD_STDERR"

if [[ -n "$CARD_DATA" ]]; then
    DETECTED_NAME=$(echo "$CARD_DATA" | cut -d'|' -f1)
    DETECTED_FIRST=$(echo "$CARD_DATA" | cut -d'|' -f2)
    DETECTED_COUNTRY=$(echo "$CARD_DATA" | cut -d'|' -f3)
    DETECTED_EMAIL=$(echo "$CARD_DATA" | cut -d'|' -f4)
    DETECTED_PHONE=$(echo "$CARD_DATA" | cut -d'|' -f5)
    ok "$(printf "$MSG_OK_FOUND" "${DETECTED_NAME}")"

    # Back up contacts FIRST -- before we do anything with them.
    # This is a safety net in case anything goes wrong during import.
    CONTACTS_BACKUP="${OSTLER_DIR}/backups/contacts-backup-$(date +%Y%m%d-%H%M%S).vcf"
    CONTACTS_EXPORT="${OSTLER_DIR}/imports/icloud-contacts.vcf"
    mkdir -p "${OSTLER_DIR}/imports" "${OSTLER_DIR}/backups"
    # CX-12 F6 (locked 2026-05-23): the osascript that follows counts +
    # exports the entire address book and can dwell silently for up to
    # ~30s on large libraries. Without a status line the GUI panel sits
    # blank while the customer wonders whether the installer has frozen
    # (Studio retest #5 "21s blank-wait" finding). Emit a structured
    # info line first so the Log drawer + the spinner caption both
    # surface what is happening.
    info "$MSG_INFO_PLEASE_WAIT_READING_CONTACTS"
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
        ok "$(printf "$MSG_OK_BACKED_UP_CONTACTS" "${CONTACT_COUNT}" "${CONTACTS_BACKUP}")"

        # Export working copy for import
        cp "$CONTACTS_BACKUP" "$CONTACTS_EXPORT" 2>/dev/null && \
        ok "$(printf "$MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY" "${CONTACT_COUNT}")" || \
        info "$MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN"
    fi
else
    info "$MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO"
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
DETECTED_CODE_SOURCE=""
if [[ -n "$DETECTED_COUNTRY" ]]; then
    DETECTED_CODE=$(_country_to_code "$DETECTED_COUNTRY")
    [[ -n "$DETECTED_CODE" ]] && DETECTED_CODE_SOURCE="contacts_country"
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
        [[ -n "$DETECTED_CODE" ]] && DETECTED_CODE_SOURCE="phone"
    fi
fi

# ── 1. Confirm name ───────────────────────────────────────────────

echo -e "  ${BOLD}Your details${NC}"
echo ""
if [[ -n "$DETECTED_NAME" ]]; then
    USER_NAME="$(gui_read "$MSG_PROMPT_USER_NAME_DETECTED_TITLE" text "${DETECTED_NAME}" "" "" "user_name")"
    USER_NAME=${USER_NAME:-$DETECTED_NAME}
else
    USER_NAME="$(gui_read "$MSG_PROMPT_USER_NAME_FALLBACK_TITLE" text "" "" "" "user_name")"
fi

# CX-12 F2 (locked 2026-05-23): expose the me-card phone + email as
# named install-context vars so later prompts (Q8 iMessage allowed,
# WhatsApp recipient, Q4 country code detect-from-phone) can pre-fill
# their default values instead of forcing the customer to retype data
# we already read from Contacts. Silent skip when either field is
# empty: the downstream prompts treat empty defaults the same as the
# pre-CX-12 behaviour. Trim leading/trailing whitespace just in case
# the osascript output picked up stray characters.
USER_PHONE="${DETECTED_PHONE:-}"
USER_PHONE="${USER_PHONE# }"
USER_PHONE="${USER_PHONE% }"
USER_EMAIL="${DETECTED_EMAIL:-}"
USER_EMAIL="${USER_EMAIL# }"
USER_EMAIL="${USER_EMAIL% }"

DETECTED_FIRST_LOWER=$(echo "${DETECTED_FIRST:-}" | tr '[:upper:]' '[:lower:]')
DEFAULT_ID=${DETECTED_FIRST_LOWER:-$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)}
USER_ID="$(gui_read "$MSG_PROMPT_USER_ID_TITLE" text "${DEFAULT_ID}" "$MSG_PROMPT_USER_ID_HELP" "" "user_id")"
USER_ID=${USER_ID:-$DEFAULT_ID}

# ── 2. Confirm country code ───────────────────────────────────────

echo ""
if [[ -n "$DETECTED_CODE" ]]; then
    # CX-12 F5 (locked 2026-05-23): differentiate the prompt surface
    # based on where the country code came from. When inferred from
    # the me-card phone prefix (rather than the Contacts country
    # field) we show the dedicated "We detected +%s. Use this for
    # your Hub?" title + help copy so the customer understands which
    # signal we used. Both surfaces still flow through the same Y/N
    # confirm → free-text fallback when declined.
    if [[ "$DETECTED_CODE_SOURCE" == "phone" ]]; then
        CC_CONFIRM_TITLE="$(printf "$MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE" "$DETECTED_CODE")"
        CC_CONFIRM_HELP="$MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP"
    else
        CC_CONFIRM_TITLE="$(printf "$MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE" "$DETECTED_CODE")"
        CC_CONFIRM_HELP=""
    fi
    echo "  Country code detected from your contact card: +${DETECTED_CODE}"
    CC_CONFIRM="$(gui_read "$CC_CONFIRM_TITLE" yesno "" "$CC_CONFIRM_HELP" "" "country_code_confirm")"
    if [[ "${CC_CONFIRM:-y}" == "n" || "${CC_CONFIRM:-y}" == "N" ]]; then
        COUNTRY_CODE="$(gui_read "$MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE" text "" "" "" "country_code")"
    else
        COUNTRY_CODE="$DETECTED_CODE"
    fi
else
    # Studio retest #7 finding #4: the bash-side echo block here
    # duplicated the help text now carried by
    # MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP (which also explains the
    # region-inference effect). Single source of truth in the
    # catalogue; the GUI renders the help string in the prompt body.
    COUNTRY_CODE="$(gui_read "$MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE" text "44" "$MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP" "" "country_code")"
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
        info "$(printf "$MSG_INFO_REGION_EU_EEA_SOURCE" "${OSTLER_REGION_ISO}" "${OSTLER_REGION_SOURCE}")"
        info "$MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN"
        info "$MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL"
        ;;
    uk)
        info "$(printf "$MSG_INFO_REGION_UNITED_KINGDOM_SOURCE" "${OSTLER_REGION_SOURCE}")"
        ;;
    us)
        info "$(printf "$MSG_INFO_REGION_UNITED_STATES_SOURCE" "${OSTLER_REGION_SOURCE}")"
        ;;
    row)
        info "$(printf "$MSG_INFO_REGION_SOURCE" "${OSTLER_REGION_ISO}" "${OSTLER_REGION_SOURCE}")"
        ;;
esac

# ── 3. Confirm timezone ───────────────────────────────────────────

DETECTED_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo "")
if [[ -n "$DETECTED_TZ" ]]; then
    echo ""
    echo "  Detected timezone: ${DETECTED_TZ}"
    TZ_CONFIRM="$(gui_read "$MSG_PROMPT_TZ_CONFIRM_TITLE" yesno "" "$(printf "$MSG_PROMPT_TZ_CONFIRM_HELP" "$DETECTED_TZ")" "" "tz_confirm")"
    if [[ "${TZ_CONFIRM:-y}" == "n" || "${TZ_CONFIRM:-y}" == "N" ]]; then
        USER_TZ="$(gui_read "$MSG_PROMPT_USER_TZ_TITLE" text "" "" "" "user_tz")"
    else
        USER_TZ="$DETECTED_TZ"
    fi
else
    USER_TZ="$(gui_read "$MSG_PROMPT_USER_TZ_TITLE" text "UTC" "" "" "user_tz")"
    USER_TZ=${USER_TZ:-UTC}
fi

# ── 4. Name your AI assistant ─────────────────────────────────────
# Q6 helper text + suggestion list are rendered by OnboardingQuestionView
# from ViewCopy.json (assistant_name_helper + assistant_name_suggestions.
# comma_separated). The previous bash-side echo block here duplicated
# the same content in the question body (Studio retest #7 finding #6:
# "Body text is duplicated twice"), so we leave both empty here and
# let the GUI catalogue be the single source of truth. Customer sees
# one suggestion list, not two.

ASSISTANT_NAME="$(gui_read "$MSG_PROMPT_ASSISTANT_NAME_TITLE" text "" "" "" "assistant_name")"
while [[ -z "$ASSISTANT_NAME" ]]; do
    warn "$MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM"
    ASSISTANT_NAME="$(gui_read "$MSG_PROMPT_ASSISTANT_NAME_TITLE" text "" "" "" "assistant_name")"
done

ok "$(printf "$MSG_OK_YOUR_ASSISTANT_CALLED" "${ASSISTANT_NAME}")"

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
CHANNEL_CHOICE="$(gui_read "$MSG_PROMPT_CHANNEL_CHOICE_TITLE" choice "3" "$MSG_PROMPT_CHANNEL_CHOICE_HELP" "1,2,3,4,5" "channel_choice")"
CHANNEL_CHOICE=${CHANNEL_CHOICE:-3}

# Normalise into per-channel boolean flags for the config writer.
CHANNEL_IMESSAGE_ENABLED=false
CHANNEL_EMAIL_ENABLED=false
CHANNEL_WHATSAPP_ENABLED=false
CHANNEL_WHATSAPP_CONSENT_ACCEPTED=false
CHANNEL_WHATSAPP_RECIPIENT=""
CHANNEL_IMESSAGE_ALLOWED=""
CHANNEL_EMAIL_USERNAME=""
CHANNEL_EMAIL_PASSWORD=""
CHANNEL_EMAIL_FROM=""
CHANNEL_EMAIL_IMAP_HOST=""
CHANNEL_EMAIL_IMAP_PORT=993
CHANNEL_EMAIL_SMTP_HOST=""
CHANNEL_EMAIL_SMTP_PORT=587
CHANNEL_EMAIL_IMAP_FOLDER=""
# Multi-source flags (HR015 task #209 / TNM 2026-05-16). Apple Mail
# via FDA is the recommended path; custom IMAP+SMTP is reserved for
# genuinely self-hosted mailboxes. Defaults match the post-PU9 yes/no
# pair below: Apple Mail on, custom IMAP off, settled by the prompts.
CHANNEL_EMAIL_APPLE_MAIL_ENABLED=false
CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false

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
        warn "$(printf "$MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL" "${CHANNEL_CHOICE}")"
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
    echo -e "  ${BOLD}WhatsApp connector – please read carefully${NC}"
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
    echo -e "  ${DIM}Legal note: Your relationship with WhatsApp (Meta Platforms"
    echo -e "  Ireland Ltd) is contractual under their Terms of Service, to"
    echo -e "  which you are the party. Creative Machines provides software"
    echo -e "  that reads WhatsApp Web's storage on your Mac; we are not a"
    echo -e "  party to your WhatsApp ToS and have no rights or duties under"
    echo -e "  it. Compliance with WhatsApp's terms is your responsibility.${NC}"
    echo ""
    # gui_read so the GUI installer renders a sheet. A bare `read -p`
    # blocks forever in OSTLER_GUI=1 mode because stdin is /dev/null
    # (caught 2026-05-16 Mac Studio install hang).
    WA_CONSENT="$(gui_read "$MSG_PROMPT_WHATSAPP_CONSENT_TITLE" yesno "n" "$MSG_PROMPT_WHATSAPP_CONSENT_HELP" "" "whatsapp_consent")"
    if [[ "${WA_CONSENT:-n}" == "y" || "${WA_CONSENT:-n}" == "Y" ]]; then
        CHANNEL_WHATSAPP_CONSENT_ACCEPTED=true
        ok "$MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED"
    else
        # Refusal: keep the channel disabled but record the decision
        # (so Doctor can show "user declined" rather than "missing").
        CHANNEL_WHATSAPP_ENABLED=false
        info "$MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN"
    fi
fi

# ── WhatsApp recipient phone (for daily briefs) ───────────────────
#
# The assistant needs to know which phone number it should deliver
# the morning brief (09:00) and evening wrap (18:00) to over WhatsApp.
# We seed the captured number into:
#
#   1. [channels.whatsapp].allowed_numbers  – inbound allowlist
#      (without it, dm_policy = "allowlist" denies every message
#      including the customer's own).
#   2. [[cron.jobs]].delivery.to            – outbound recipient
#      for the morning brief + evening wrap jobs.
#
# E.164 format (leading +, country code, digits only). We don't
# validate beyond emptiness; bad numbers surface as a delivery
# error in Doctor on the first scheduled run.
if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Your WhatsApp phone number${NC}"
    echo ""
    echo "  Used for two things:"
    echo "    1. The phone you'll send messages FROM when chatting with"
    echo "       your assistant on WhatsApp."
    echo "    2. Where the morning brief (09:00) and evening wrap (18:00)"
    echo "       get delivered."
    echo ""
    echo "  Enter in E.164 format: leading +, country code, digits only."
    echo "  Example: +447700900000"
    echo ""
    # CX-12 F4 (locked 2026-05-23): pre-fill the WhatsApp recipient
    # with the me-card phone captured at Q3. Customer can edit or wipe
    # before submitting; the existing while-loop still enforces the +
    # E.164 prefix check, so a pre-filled non-+ value won't escape the
    # validator silently. Blank when no phone was detected.
    WHATSAPP_RECIPIENT_DEFAULT="${USER_PHONE:-}"
    while [[ -z "$CHANNEL_WHATSAPP_RECIPIENT" ]]; do
        CHANNEL_WHATSAPP_RECIPIENT="$(gui_read \
            "$MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE" text "$WHATSAPP_RECIPIENT_DEFAULT" \
            "$MSG_PROMPT_WHATSAPP_RECIPIENT_HELP" \
            "" "whatsapp_recipient")"
        # Trim whitespace.
        CHANNEL_WHATSAPP_RECIPIENT="${CHANNEL_WHATSAPP_RECIPIENT# }"
        CHANNEL_WHATSAPP_RECIPIENT="${CHANNEL_WHATSAPP_RECIPIENT% }"
        if [[ -z "$CHANNEL_WHATSAPP_RECIPIENT" ]]; then
            warn "$MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY"
            warn "$MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT"
            continue
        fi
        if [[ "${CHANNEL_WHATSAPP_RECIPIENT:0:1}" != "+" ]]; then
            warn "$MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN"
            CHANNEL_WHATSAPP_RECIPIENT=""
            continue
        fi
    done
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
    echo "  This is an inbound allowlist. ${ASSISTANT_NAME} will only act on"
    echo "  iMessages from the phone numbers and Apple ID emails you list"
    echo "  here. Anyone not on the list is silently ignored, so spam and"
    echo "  unrelated texts won't trigger a reply."
    echo ""
    echo "  Enter one or more entries, comma-separated. You'll almost"
    echo "  always want your own iCloud-linked phone or email so you can"
    echo "  message ${ASSISTANT_NAME} from your own devices. Add family or"
    echo "  close contacts only if you want ${ASSISTANT_NAME} to act on"
    echo "  their messages too."
    echo ""
    echo "  Example: +447700900000, you@example.com"
    echo ""
    echo "  The list cannot be empty: this prompt will re-ask until at"
    echo "  least one entry is given. To skip iMessage entirely, cancel"
    echo "  and re-run the installer with iMessage unticked."
    echo ""
    # CX-12 F3 (locked 2026-05-23): pre-fill the allowlist with the
    # me-card phone + email captured at Q3, comma-separated. Customer
    # can append, edit, or wipe before submitting. Blank when both
    # fields are empty so we don't ship a literal ", " as the default.
    IMESSAGE_ALLOWED_DEFAULT=""
    if [[ -n "$USER_PHONE" && -n "$USER_EMAIL" ]]; then
        IMESSAGE_ALLOWED_DEFAULT="${USER_PHONE}, ${USER_EMAIL}"
    elif [[ -n "$USER_PHONE" ]]; then
        IMESSAGE_ALLOWED_DEFAULT="$USER_PHONE"
    elif [[ -n "$USER_EMAIL" ]]; then
        IMESSAGE_ALLOWED_DEFAULT="$USER_EMAIL"
    fi
    while [[ -z "$CHANNEL_IMESSAGE_ALLOWED" ]]; do
        CHANNEL_IMESSAGE_ALLOWED="$(gui_read "$MSG_PROMPT_IMESSAGE_ALLOWED_TITLE" text "$IMESSAGE_ALLOWED_DEFAULT" "$(printf "$MSG_PROMPT_IMESSAGE_ALLOWED_HELP" "$ASSISTANT_NAME")" "" "imessage_allowed")"
        if [[ -z "$CHANNEL_IMESSAGE_ALLOWED" ]]; then
            warn "$MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT"
            warn "$MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED"
        fi
    done
fi

# ── Email sources ──────────────────────────────────────────────────
#
# Source order, agreed in HR015 task #209 / TNM 2026-05-16 update:
#
#   1. Apple Mail FDA (recommended for almost everyone).
#      Reads any account configured in Apple Mail (iCloud, Gmail,
#      Outlook, etc.) using Full Disk Access. No passwords stored
#      anywhere; the email-ingest LaunchAgent (HR015) drains the
#      local mbox folder hourly.
#   2. Google OAuth -- deferred to v1.5 (not in this build).
#   3. Custom IMAP+SMTP password.
#      Reserved for genuinely self-hosted mailboxes. We refuse to
#      accept cloud-provider hosts (Gmail / iCloud / Outlook) here:
#      the customer is nudged back to Apple Mail. We will never ask
#      for a customer's account password for a cloud provider.
#
# PU9 now allows MULTIPLE sources: a customer can tick Apple Mail
# AND a custom IMAP server. PU11/PU12 (password + confirm) only
# fire if Custom IMAP is enabled.
if [[ "$CHANNEL_EMAIL_ENABLED" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Where should Ostler read mail from?${NC}"
    echo ""
    echo "    Apple Mail is the recommended source for almost everyone."
    echo "    Sign in to iCloud, Gmail, or Outlook inside Apple Mail and"
    echo "    Ostler reads them all via Full Disk Access -- no passwords"
    echo "    stored anywhere."
    echo ""

    CHANNEL_EMAIL_APPLE_MAIL_INPUT="$(gui_read "$MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE" yesno "Y" "$MSG_PROMPT_EMAIL_APPLE_MAIL_HELP" "" "email_apple_mail")"
    case "${CHANNEL_EMAIL_APPLE_MAIL_INPUT:-Y}" in
        n|N|no|NO|No) CHANNEL_EMAIL_APPLE_MAIL_ENABLED=false ;;
        *)            CHANNEL_EMAIL_APPLE_MAIL_ENABLED=true ;;
    esac

    CHANNEL_EMAIL_CUSTOM_IMAP_INPUT="$(gui_read "$MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE" yesno "N" "$MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP" "" "email_custom_imap")"
    case "${CHANNEL_EMAIL_CUSTOM_IMAP_INPUT:-N}" in
        y|Y|yes|YES|Yes) CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true ;;
        *)               CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false ;;
    esac
    unset CHANNEL_EMAIL_APPLE_MAIL_INPUT CHANNEL_EMAIL_CUSTOM_IMAP_INPUT

    # Fail-safe default. If the customer said no to both we still need
    # the email channel to do something; default to Apple Mail rather
    # than silently disabling the channel after a Y at the prior step.
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" != true \
       && "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" != true ]]; then
        warn "$MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP"
        CHANNEL_EMAIL_APPLE_MAIL_ENABLED=true
    fi

    if [[ "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" == true ]]; then
        echo ""
        # Cloud-provider block list. The whole point of this branch
        # is that we DO NOT want to handle Gmail / iCloud / Outlook
        # passwords ourselves -- those go through Apple Mail. If the
        # customer types one of these hosts we nudge them back.
        while true; do
            CHANNEL_EMAIL_IMAP_HOST="$(gui_read "$MSG_PROMPT_IMAP_HOST_TITLE" text "" "$MSG_PROMPT_IMAP_HOST_HELP" "" "imap_host")"
            _imap_host_lower="$(printf '%s' "$CHANNEL_EMAIL_IMAP_HOST" | tr '[:upper:]' '[:lower:]')"
            case "$_imap_host_lower" in
                imap.gmail.com|imap-mail.outlook.com|outlook.office365.com|imap.mail.me.com)
                    warn "$(printf "$MSG_WARN_IS_CLOUD_PROVIDER_HOST" "${CHANNEL_EMAIL_IMAP_HOST}")"
                    warn "$MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT"
                    warn "$MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST"
                    continue
                    ;;
                "")
                    warn "$MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN"
                    continue
                    ;;
            esac
            unset _imap_host_lower
            break
        done
        imap_port_in="$(gui_read "$MSG_PROMPT_IMAP_PORT_TITLE" text "993" "" "" "imap_port")"
        CHANNEL_EMAIL_IMAP_PORT=${imap_port_in:-993}
        CHANNEL_EMAIL_SMTP_HOST="$(gui_read "$MSG_PROMPT_SMTP_HOST_TITLE" text "" "" "" "smtp_host")"
        smtp_port_in="$(gui_read "$MSG_PROMPT_SMTP_PORT_TITLE" text "587" "" "" "smtp_port")"
        CHANNEL_EMAIL_SMTP_PORT=${smtp_port_in:-587}

        echo ""
        CHANNEL_EMAIL_USERNAME="$(gui_read "$MSG_PROMPT_EMAIL_USERNAME_TITLE" text "" "" "" "email_username")"
        CHANNEL_EMAIL_FROM="$CHANNEL_EMAIL_USERNAME"

        # Hidden password input (kind=secret); confirm with re-entry
        # so a typo doesn't silently lock the assistant out of email.
        # This loop fires ONLY for custom IMAP -- we never ask a
        # customer for a cloud-provider password.
        while true; do
            echo ""
            CHANNEL_EMAIL_PASSWORD="$(gui_read "$MSG_PROMPT_EMAIL_PASSWORD_TITLE" secret "" "$MSG_PROMPT_EMAIL_PASSWORD_HELP" "" "email_password")"
            echo ""
            _email_confirm_input="$(gui_read "$MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE" secret "" "" "" "email_password_confirm")"
            echo ""
            if [[ "$CHANNEL_EMAIL_PASSWORD" == "$_email_confirm_input" && -n "$CHANNEL_EMAIL_PASSWORD" ]]; then
                break
            fi
            warn "$MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY"
        done
        unset _email_confirm_input
    else
        # Apple-Mail-only path. No IMAP credentials are collected;
        # HR015's email-ingest LaunchAgent reads from Apple Mail's
        # local mbox via Full Disk Access. We leave the IMAP / SMTP
        # / username / password vars empty so the channels.toml
        # writer renders them as empty strings, and the email-ingest
        # side keys off `apple_mail = true` instead.
        CHANNEL_EMAIL_USERNAME=""
        CHANNEL_EMAIL_FROM=""
        CHANNEL_EMAIL_PASSWORD=""
    fi

    # Folder / label scoping. Connecting the assistant to the main
    # inbox means it would see every email the user receives, not
    # just messages addressed to it. The product rule (email_safety)
    # is: dedicated label/folder, never the inbox.
    #
    # v1.0 (2026-05-20 Studio retest #2 follow-up): Andy's call --
    # 99.5% of operators want the dedicated 'Ostler' label by default,
    # so we hardcode it and surface customisation as a post-install
    # Doctor knob rather than an install-time question. Removing this
    # prompt drops the customer-visible question count by one.
    CHANNEL_EMAIL_IMAP_FOLDER="Ostler"

    # Build a human-friendly summary that reflects whichever paths
    # are enabled. Apple Mail FDA has no host / username; custom
    # IMAP carries the existing username + host info.
    _email_summary_parts=()
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]]; then
        _email_summary_parts+=("Apple Mail (FDA)")
    fi
    if [[ "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" == true ]]; then
        _email_summary_parts+=("${CHANNEL_EMAIL_USERNAME} via ${CHANNEL_EMAIL_IMAP_HOST}")
    fi
    IFS=' + ' read -r _email_summary_joined <<< "${_email_summary_parts[*]}"
    ok "$(printf "$MSG_OK_EMAIL_CHANNEL_FOLDER" "${_email_summary_joined}" "${CHANNEL_EMAIL_IMAP_FOLDER}")"
    unset _email_summary_parts _email_summary_joined
fi

if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
    ok "$(printf "$MSG_OK_IMESSAGE_CHANNEL" "${CHANNEL_IMESSAGE_ALLOWED}")"
fi

# ── 5. Data sources ───────────────────────────────────────────────
#
# Show which platforms we support, give them clickable links to
# request exports. Keep it SHORT -- people don't read walls of text.

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
echo "  now -- they take 1-3 days to arrive by email. You can do this"
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
_="$(gui_read "$MSG_PROMPT_EXPORTS_ACK_TITLE" acknowledge "" "$MSG_PROMPT_EXPORTS_ACK_HELP" "" "exports_ack")"

# ── 6. FileVault check (silent if enabled) ─────────────────────────

FV_STATUS=$(fdesetup status 2>/dev/null || echo "unknown")
FV_ENABLED=false
if echo "$FV_STATUS" | grep -q "FileVault is On"; then
    FV_ENABLED=true
else
    warn "$MSG_WARN_FILEVAULT_NOT_ENABLED"
    echo ""
    echo "  FileVault encrypts your entire disk. Without it, anyone"
    echo "  with physical access to your Mac can read your data."
    echo ""
    echo "  Enable it: System Settings > Privacy & Security > FileVault"
    echo ""
    FV_CONTINUE="$(gui_read "$MSG_PROMPT_FILEVAULT_SKIP_TITLE" yesno "n" "$MSG_PROMPT_FILEVAULT_SKIP_HELP" "" "filevault_skip")"
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
    info "$(printf "$MSG_INFO_CREATING_USER_FACING_CONTENT_TREE" "${USER_FACING_ROOT}")"
    mkdir -p "$USER_FACING_ROOT"
    for sub in "${USER_TREE_SUBDIRS[@]}"; do
        mkdir -p "${USER_FACING_ROOT}/${sub}"
    done
    {
        echo "Ostler user-facing tree created on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "Subdirs: ${USER_TREE_SUBDIRS[*]}"
    } > "$USER_TREE_SENTINEL"
    ok "$MSG_OK_USER_FACING_TREE_READY"
else
    info "$MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL"
fi

# ── 2.99 Python 3.10/3.11 check (must run BEFORE any venv is created) ──
#
# Studio retest 2026-05-22 caught a phase-ordering bug: the venv was
# created here using the system `python3` (3.9.6 on a default macOS
# 15 install), then Phase 3.4 ran `brew install python@3.11` AFTER
# the venv was already bound to 3.9.6. Result: `encrypt_db` died
# trying to pip-install pysqlcipher3 against a Python the wheel does
# not support. Fix: check + install Python BEFORE venv creation,
# carry the verified-good path forward as `PYTHON3_BIN`, and use
# that everywhere (not PATH-based `python3` resolution, which can
# resolve to the system binary even after a PATH prepend).
#
# Studio retest 2026-05-22 (round 3) caught the actual encrypt_db
# trap: pysqlcipher3 1.2.0 (the only release on PyPI, March 2020) is
# abandoned and unbuildable on macOS. Migrated to sqlcipher3 (the
# maintained fork) which ships prebuilt arm64 + x86_64 macOS wheels
# for cp310/cp311/cp312. We pin Python 3.11 here because round 3
# verified the full ostler_security + cryptography + sqlcipher3
# stack runs clean on 3.11; 3.12 wheels also exist for everything
# but the move-to-3.12 retest is post-launch hygiene rather than
# launch-blocking. 3.11 EOL is October 2027, plenty of runway.
if [[ -z "${PYTHON3_BIN:-}" ]]; then
    PYTHON3_BIN=""
    if command -v python3 &>/dev/null; then
        SYS_PY_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
        SYS_PY_MAJOR=$(echo "$SYS_PY_VERSION" | cut -d. -f1)
        SYS_PY_MINOR=$(echo "$SYS_PY_VERSION" | cut -d. -f2)
        # Accept 3.10 or 3.11 only. 3.12+ has sqlcipher3 wheels available
        # but is untested in this stack today (post-launch hygiene). 3.9
        # and older fail other deps.
        if [[ "$SYS_PY_MAJOR" -eq 3 && "$SYS_PY_MINOR" -ge 10 && "$SYS_PY_MINOR" -le 11 ]]; then
            PYTHON3_BIN="$(command -v python3)"
            ok "$(printf "$MSG_OK_PYTHON" "${SYS_PY_VERSION}")"
        fi
    fi
    if [[ -z "$PYTHON3_BIN" ]]; then
        if command -v python3 &>/dev/null; then
            warn "$(printf "$MSG_WARN_PYTHON_TOO_OLD_NEED_3_10" "${SYS_PY_VERSION}")"
        else
            warn "$MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON"
        fi
        if ! brew install python@3.11; then
            fail "Could not install Python 3.11 via Homebrew. Re-run the installer with a working network connection, or install Python 3.11 manually with: brew install python@3.11"
        fi
        # Use the explicit Homebrew keg path, NOT the PATH-prepended
        # `python3` which can resolve to /usr/bin/python3 (system 3.9.x)
        # even after a `export PATH=...` prepend.
        if [[ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]]; then
            PYTHON3_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
        elif [[ -x "/usr/local/opt/python@3.11/bin/python3.11" ]]; then
            PYTHON3_BIN="/usr/local/opt/python@3.11/bin/python3.11"
        else
            fail "brew install python@3.11 reported success but the python3.11 binary was not found at the expected paths. Try 'brew reinstall python@3.11' and re-run the installer."
        fi
        NEW_PY_VERSION=$("$PYTHON3_BIN" --version 2>&1 | cut -d' ' -f2)
        ok "$(printf "$MSG_OK_PYTHON_INSTALLED" "${NEW_PY_VERSION}")"
    fi
    export PYTHON3_BIN
fi

HAS_SECURITY_MODULE=false
if [[ -d "${SCRIPT_DIR}/ostler_security" && -f "${SCRIPT_DIR}/ostler_security/pyproject.toml" ]]; then
    # macOS Sonoma+ blocks pip3 install to system Python, so use a venv.
    # PYTHON3_BIN is the verified-3.10+ Python set above.
    OSTLER_VENV="${OSTLER_DIR}/.venv"
    if [[ ! -d "$OSTLER_VENV" ]]; then
        "$PYTHON3_BIN" -m venv "$OSTLER_VENV"
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
                warn "$MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS"
        fi
        ok "$MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV"
    else
        # Hard-fail: deployed services (CM041 ical-server, CM041
        # whatsapp-bridge, CM048 ingest) refuse to start at import
        # time without ostler_security. Continuing the install would
        # produce a green "succeeded" summary followed by services
        # that will not boot. Surface the failure now.
        # See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
        if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
            warn "$MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO"
            warn "$MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK"
            warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
            if [[ -s /tmp/ostler-pip-install.log ]]; then
                warn "$MSG_WARN_PIP_SAID"
                sed -e 's/^/    /' /tmp/ostler-pip-install.log | head -5
            fi
            rm -f /tmp/ostler-pip-install.log
        else
            echo ""
            warn "$MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO"
            warn "$MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2"
            warn "$MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT"
            if [[ -s /tmp/ostler-pip-install.log ]]; then
                warn "$MSG_WARN_PIP_SAID"
                sed -e 's/^/    /' /tmp/ostler-pip-install.log | head -5
            fi
            rm -f /tmp/ostler-pip-install.log
            fail "$MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN"
        fi
    fi
fi

# Copy FDA extraction module if bundled.
#
# FDA_DIR is the PARENT -- the package lives at FDA_DIR/ostler_fda/.
# When install.sh runs from inside the signed .app, SCRIPT_DIR is
# Contents/Resources and the postBuildScript in gui/project.yml lands
# the package at SCRIPT_DIR/ostler_fda/. When install.sh runs from a
# developer's HR015 sibling-clone layout (dev mode), the package is
# also at SCRIPT_DIR/ostler_fda/ (../HR015 - Gaming PC/ostler_fda
# symlinked or vendored locally).
#
# Pre-2026-05-21 a missing package fell through to "FDA extraction
# module not bundled. Skipping instant data extraction" later in
# Phase 3.7, leaving the customer with zero extracted data and no
# clear error. The hard-fail below mirrors the ostler_security probe
# pattern (install.sh:1820-1846) so a build regression surfaces
# immediately rather than 30 minutes into the install.
FDA_DIR="${OSTLER_DIR}/fda-module"
HAS_FDA_MODULE=false
if [[ -d "${SCRIPT_DIR}/ostler_fda" ]]; then
    mkdir -p "$FDA_DIR"
    cp -R "${SCRIPT_DIR}/ostler_fda" "$FDA_DIR/"
    HAS_FDA_MODULE=true
else
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT"
    else
        echo ""
        warn "$MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1"
        warn "$MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2"
        warn "$MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3"
        fail "$MSG_FAIL_FDA_MODULE_MISSING_RE_RUN"
    fi
fi

RECOVERY_KEY=""
RECOVERY_PASSPHRASE=""
PASSKEY_PRIMED=false

# Check if security is already configured (re-run detection)
#
# Two artefacts can mark "security configured":
#   - passkey.json  -- primary path (passkey-primary flow, 2026-04-23+)
#   - keychain.json -- legacy passphrase path OR opt-in recovery passphrase
#                       written by setup_passphrase() during a previous run
#
# Either is sufficient to skip security setup on a re-run.
if [[ -f "${SECURITY_CONFIG_DIR}/passkey.json" || -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
    ok "$MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN"
    HAS_SECURITY_MODULE=false  # skip security setup on re-run
elif [[ "$HAS_SECURITY_MODULE" == true ]]; then
    # ── Passphrase-primary unlock (v1.0) ──────────────────────────────
    # Replaces the passkey/Touch ID path (PR #137, 2026-05-22). Studio
    # retests #10 + #11 confirmed Apple's framework deliberately excludes
    # Apple Watch as user verification for Secure-Enclave-backed passkeys
    # (Macworld + Hanko cites), so Mac Studio (no Touch ID) literally
    # cannot register an ASAuthorizationPlatformPublicKeyCredentialProvider
    # passkey regardless of Watch state. Rather than ship a broken passkey
    # path or split into two flows mid-launch, v1.0 uses the recovery
    # passphrase the customer types here as the SOLE primary unlock.
    # Works on every Mac. One code path. Passkey convenience returns in
    # v1.0.1 as a Touch-ID-only convenience layer on top of this.
    echo ""
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Your passphrase protects your data${NC}"
    echo ""
    echo "  This is not a newsletter signup. Ostler will hold every"
    echo "  relationship, every conversation, every pattern in your life."
    echo "  Think of it like the lock for your entire digital soul."
    echo ""
    echo "  Your knowledge graph is encrypted with a passphrase you"
    echo "  choose on the next screen. You will type it each time you"
    echo "  start the Hub UI."
    echo ""
    echo "  Pick something memorable but strong. A password manager"
    echo "  is a good place to store it."
    echo ""
    echo -e "  ${RED}If you forget this passphrase, your data is gone${NC}"
    echo -e "  ${RED}forever. We cannot help. That is the point.${NC}"
    echo ""

    ACK_PASSKEY="$(gui_read "$MSG_PROMPT_PASSKEY_ACK_TITLE" acknowledge "OK" "$MSG_PROMPT_PASSKEY_ACK_HELP" "OK,CANCEL" "passkey_ack")"
    if [[ "$ACK_PASSKEY" == "CANCEL" || "$ACK_PASSKEY" == "cancel" ]]; then
        echo ""
        echo "  No problem. Nothing has been installed."
        echo "  Re-run the installer when you are ready."
        exit 0
    fi
    PASSKEY_PRIMED=true
    ok "$MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED"

    # ── Mandatory passphrase capture ─────────────────────────────────
    # v1.0 passphrase-primary: passphrase is the ONLY unlock factor,
    # so this is no longer opt-in. Customer must enter + confirm a
    # passphrase of at least 12 characters. setup_passphrase()
    # generates its own recovery key (XXXX-XXXX-XXXX format) shown
    # once at the end of Phase 3.6 -- that recovery key is the
    # backup if the typed passphrase is ever lost.
    #
    # RP_ERROR carries the previous-attempt failure reason into the
    # next gui_read's help text so the GUI renders it inline above
    # the password field. Cleared on success.
    echo ""
    echo "  $MSG_INFO_RECOVERY_PASSPHRASE_INTRO"
    echo ""
    RP_ERROR=""
    while true; do
        rp_help="$MSG_PROMPT_RECOVERY_PASSPHRASE_HELP"
        if [[ -n "$RP_ERROR" ]]; then
            rp_help="⚠️  ${RP_ERROR}

${rp_help}"
        fi
        RECOVERY_PASSPHRASE="$(gui_read "$MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE" secret "" "$rp_help" "" "recovery_passphrase")"
        echo ""
        if [[ -z "$RECOVERY_PASSPHRASE" ]]; then
            RP_ERROR="$MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED"
            warn "$MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED"
            continue
        fi

        # Quick length sanity check here; full strength validation
        # runs in Phase 3.6 once the venv is fully provisioned.
        # 12-char minimum mirrors the lower bound of
        # validate_passphrase_strength's diceware path.
        if [[ ${#RECOVERY_PASSPHRASE} -lt 12 ]]; then
            warn "$MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT"
            RP_ERROR="$MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT"
            unset RECOVERY_PASSPHRASE
            continue
        fi

        rpc_help="$MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP"
        RP_CONFIRM="$(gui_read "$MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE" secret "" "$rpc_help" "" "recovery_passphrase_confirm")"
        echo ""
        if [[ "$RECOVERY_PASSPHRASE" != "$RP_CONFIRM" ]]; then
            warn "$MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN"
            RP_ERROR="$MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN"
            unset RP_CONFIRM
            continue
        fi
        unset RP_CONFIRM
        RP_ERROR=""
        ok "$MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3"
        break
    done
else
    # HAS_SECURITY_MODULE is false AND there is no existing
    # keychain.json. This means the ostler_security package was not
    # found at ${SCRIPT_DIR}/ostler_security/ (or the pyproject.toml
    # probe failed), so the install would silently continue, skip
    # the passkey prompt, and then hard-fail at the encrypt_db
    # step several phases later with a confusing "no passkey
    # set" error. Surface the real failure here instead.
    #
    # Caught by Mac Studio retest #6 on 2026-05-21: the bundled
    # .app was missing ostler_security/ in Contents/Resources/
    # because the post-build script that copies the vendored
    # package into the .app had never been wired up. Fix is in
    # gui/project.yml + vendor/ostler_security/ in PR #115;
    # this hard-fail is the safety net so that if a future build
    # regression strips the package out again, the customer gets a
    # clear actionable error instead of a silent half-install.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP"
        warn "$MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        echo ""
        warn "$MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP"
        warn "$(printf "$MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH" "${SCRIPT_DIR}")"
        warn "$MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE"
        warn "$MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2"
        warn "$MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3"
        warn "$MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4"
        fail "$MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN"
    fi
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

ok "$(printf "$MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM" "${AI_MODEL}" "${AI_MODEL_SIZE}" "${RAM_GB}")"
PULL_MODEL="y"

# ── 9. GDPR data exports (auto-detect) ────────────────────────────
# Skip on re-run -- user already consented, exports already known.

if [[ "$SKIP_PHASE2" == false ]]; then

EXPORTS_DIR=""
DETECTED_EXPORTS=()

# Scan common locations for recognisable GDPR export files.
# Studio retest #7 finding #13 (Image #53): the previous `info`
# emit here rendered as a ~200ms transient status page in the GUI
# before the find-scan moved on. Drop to log-only so the GUI never
# renders a flash page; the bash terminal output is unaffected.
gui_log info "$MSG_INFO_SCANNING_GDPR_DATA_EXPORTS"
for search_dir in "${HOME}/Downloads" "${HOME}/Desktop" "${HOME}/Documents"; do
    [[ -d "$search_dir" ]] || continue

    # LinkedIn: Connections.csv in a folder. The previous
    # `-path "*/linkedin*"` predicate was case-sensitive and
    # excluded LinkedIn's actual export folder name
    # `Basic_LinkedInDataExport_<date>/` (no lowercase "linkedin"
    # substring), so every real LinkedIn export was silently
    # missed. Connections.csv is LinkedIn-specific enough to
    # discriminate without a path filter; the post-detect prompt
    # at line ~1700 lets the user opt out if a non-LinkedIn
    # Connections.csv is mis-attributed.
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("LinkedIn: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 3 -name "Connections.csv" 2>/dev/null || true)

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
    ok "$(printf "$MSG_OK_FOUND_GDPR_EXPORT_S" "${#DETECTED_EXPORTS[@]}")"
    for exp in "${DETECTED_EXPORTS[@]}"; do
        echo "     - ${exp}"
    done
    echo ""
    IMPORT_CONFIRM="$(gui_read "$MSG_PROMPT_IMPORT_CONFIRM_TITLE" yesno "" "$MSG_PROMPT_IMPORT_CONFIRM_HELP" "" "import_confirm")"
    if [[ "${IMPORT_CONFIRM:-y}" == "n" || "${IMPORT_CONFIRM:-y}" == "N" ]]; then
        EXPORTS_DIR=""
    fi
else
    echo ""
    info "$MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP"
    echo "  That is fine -- you can import later. Request your data from:"
    echo "     LinkedIn, Facebook, Instagram, Google, Twitter, WhatsApp"
    echo "  Exports typically take 1-3 days to arrive."
    echo ""
    MANUAL_PATH="$(gui_read "$MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE" folder "${HOME}/Downloads" "$MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP" "" "manual_exports_path")"
    if [[ -n "$MANUAL_PATH" ]]; then
        MANUAL_PATH="${MANUAL_PATH/#\~/$HOME}"
        if [[ -d "$MANUAL_PATH" ]]; then
            EXPORTS_DIR="$MANUAL_PATH"
            ok "$(printf "$MSG_OK_FOUND_EXPORTS" "${EXPORTS_DIR}")"
        else
            warn "$(printf "$MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT" "${MANUAL_PATH}")"
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
        info "$(printf "$MSG_INFO_FOUND_GMAIL_MBOX_MB" "${TAKEOUT_MBOX_PATH}" "${MBOX_SIZE_MB}")"
    elif [[ -n "${TAKEOUT_ZIP_PATH:-}" ]]; then
        ZIP_SIZE_MB=$(( $(stat -f%z "${TAKEOUT_ZIP_PATH}" 2>/dev/null || echo 0) / 1048576 ))
        info "$(printf "$MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB" "${TAKEOUT_ZIP_PATH}" "${ZIP_SIZE_MB}")"
    fi
    echo ""
    echo "  Ostler can read your full Gmail content from a Takeout export"
    echo "  WITHOUT connecting to Google's API. Your Gmail messages stay on"
    echo "  this machine; Google never sees that Ostler exists."
    echo ""
    TAKEOUT_CONFIRM="$(gui_read "$MSG_PROMPT_TAKEOUT_CONFIRM_TITLE" yesno "" "$MSG_PROMPT_TAKEOUT_CONFIRM_HELP" "" "takeout_confirm")"
    if [[ "${TAKEOUT_CONFIRM:-y}" != "n" && "${TAKEOUT_CONFIRM:-y}" != "N" ]]; then
        if [[ -n "${TAKEOUT_MBOX_PATH:-}" ]]; then
            OSTLER_TAKEOUT_PATH="${TAKEOUT_MBOX_PATH}"
        elif [[ -n "${TAKEOUT_ZIP_PATH:-}" ]]; then
            # Extract the mbox out of the zip into ~/.ostler/imports/takeout/
            TAKEOUT_EXTRACT_DIR="${OSTLER_DIR}/imports/takeout"
            mkdir -p "${TAKEOUT_EXTRACT_DIR}"
            info "$MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP"
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
                ok "$(printf "$MSG_OK_EXTRACTED" "${EXTRACTED_MBOX}")"
            else
                warn "$MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM"
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
echo "  by default -- tick deliberately if you want them."
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

# 2026-05-20: choice keys are semantic (recommended/everything/customise)
# rather than numeric (1/2/3). The OnboardingQuestionView keys off the
# prompt id `fda_preset` and renders a segmented radio control with the
# MSG_PROMPT_FDA_PRESET_CHOICE_* labels. Legacy numeric values are
# still accepted for the TTY fallback path so an `OSTLER_GUI` unset run
# from the terminal works the same as before.
PRESET="$(gui_read "$MSG_PROMPT_FDA_PRESET_TITLE" choice "recommended" "$MSG_PROMPT_FDA_PRESET_HELP" "recommended,everything,customise" "fda_preset")"
PRESET=${PRESET:-recommended}

# Default sets
RECOMMENDED="safari_history,safari_bookmarks,apple_notes,calendar,reminders"
EVERYTHING="${RECOMMENDED},imessage,apple_mail,photos_metadata"

case "$PRESET" in
    1|recommended)
        OSTLER_FDA_SOURCES="$RECOMMENDED"
        ok "$MSG_OK_RECOMMENDED_SOURCES_SELECTED"
        ;;
    2|everything)
        OSTLER_FDA_SOURCES="$EVERYTHING"
        ok "$MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL"
        ;;
    3|customise)
        # Per-source loop. Each line: prompt with default, default set
        # by the second argument. Anything other than 'n'/'N' keeps default.
        ENABLED=()
        _ask_source() {
            # $1 = source name, $2 = display label, $3 = default (Y/N)
            local default="$3"
            local prompt_default
            if [[ "$default" == "Y" ]]; then prompt_default="Y/n"; else prompt_default="y/N"; fi
            ans="$(gui_read "$2" yesno "$default" "$MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP" "" "src_$1")"
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
        echo "  Personal correspondence (default off -- third-party content):"
        _ask_source "imessage"         "iMessage                " N
        if [[ "$HAS_APPLE_MAIL_GMAIL" == true ]]; then
            _ask_source "apple_mail" "Apple Mail (incl. Gmail)" N
        else
            _ask_source "apple_mail" "Apple Mail              " N
        fi
        _ask_source "photos_metadata"  "Photos events (no faces)" N
        echo ""
        echo "  Special-category data (default off -- explicit consent required):"
        _ask_source "photos_faces" "Photos face recognition (Art. 9)" N
        # Build comma-separated list
        IFS=','
        OSTLER_FDA_SOURCES="${ENABLED[*]}"
        unset IFS
        ;;
    *)
        warn "$MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED"
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
    info "$MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT"
    info "$MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS"
    info "$MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT"
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
    echo -e "  ${BOLD}One last thing – what Ostler will look at on your Mac${NC}"
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
    echo -e "  ${DIM}Legal note: You are the data controller for all"
    echo -e "  special-category data Ostler processes on this Mac (UK GDPR"
    echo -e "  Article 4(7)). Creative Machines never receives any of this"
    echo -e "  data. Your explicit consent above (UK GDPR Article 9(2)(a))"
    echo -e "  is the lawful basis for processing. For personal and household"
    echo -e "  use, Article 2(2)(c) further limits scope. This consent is"
    echo -e "  revocable at any time without affecting processing that has"
    echo -e "  already taken place.${NC}"
    echo ""
    while true; do
        # gui_read so the GUI installer renders a sheet (bare `read -p`
        # hangs OSTLER_GUI=1 because stdin is /dev/null).
        ART9="$(gui_read "$MSG_PROMPT_CONSENT_ARTICLE_9_TITLE" yesno "" "$MSG_PROMPT_CONSENT_ARTICLE_9_HELP" "" "consent_article_9")"
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
                unset RECOVERY_PASSPHRASE 2>/dev/null || true
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
    echo -e "  ${BOLD}Recognising voices on calls${NC}"
    echo ""
    echo "  Ostler can label transcripts with who is speaking – for"
    echo "  example, \"Speaker A\", \"Speaker B\" – by storing a numeric"
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
    echo -e "  ${DIM}Legal note: Voice fingerprints stored on this Mac are"
    echo -e "  biometric data under UK GDPR Article 9(1). Your explicit"
    echo -e "  consent above (Article 9(2)(a)) is the lawful basis for"
    echo -e "  processing. You are the data controller (Article 4(7));"
    echo -e "  Creative Machines never receives the fingerprints. For"
    echo -e "  personal and household use, Article 2(2)(c) further limits"
    echo -e "  scope. Withdrawing consent in Settings deletes stored"
    echo -e "  fingerprints.${NC}"
    echo ""
    while true; do
        # gui_read so the GUI installer renders a sheet (bare `read -p`
        # hangs OSTLER_GUI=1 because stdin is /dev/null).
        VOICE="$(gui_read "$MSG_PROMPT_CONSENT_VOICE_EU_TITLE" yesno "Y" "$MSG_PROMPT_CONSENT_VOICE_EU_HELP" "" "consent_voice_eu")"
        case "${VOICE:-y}" in
            y|Y|"")
                OSTLER_CONSENT_VOICE_EU_DECISION="accepted"
                break
                ;;
            n|N)
                OSTLER_CONSENT_VOICE_EU_DECISION="declined"
                info "$MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU"
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
# (THIRD_PARTY_DATA_NOTICE).
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
echo -e "  ${BOLD}About the data on your Mac that's not just yours${NC}"
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
echo -e "  ${DIM}Legal note: For records you keep on this Mac, you are"
echo -e "  the data controller under UK and EU law (UK GDPR Article"
echo -e "  4(7)). Creative Machines never receives this data and is not"
echo -e "  the controller. Your processing for personal and household"
echo -e "  purposes falls within UK/EU GDPR Article 2(2)(c).${NC}"
echo ""
while true; do
    # gui_read so the GUI installer renders a sheet (bare `read -p`
    # hangs OSTLER_GUI=1 because stdin is /dev/null).
    THIRD_PARTY="$(gui_read "$MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE" yesno "" "$MSG_PROMPT_CONSENT_THIRD_PARTY_HELP" "" "consent_third_party")"
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
            unset RECOVERY_PASSPHRASE 2>/dev/null || true
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
echo "    3. You will keep your passphrase and recovery key safe"
echo "    4. You accept the terms at creativemachines.ai/ostler/terms"
echo ""

# 2026-05-22 Phase 2 UX sweep: install consent is the typed-input
# legal gate (kind `text_with_cancel`). Andy's brief: "this was
# where we needed the user to proactively write INSTALL for Legal
# reasons." The GUI renders a text field + Cancel button; Continue
# is disabled until the trimmed/upper-cased input matches the first
# choice ("INSTALL"). Cancel posts the second choice ("CANCEL")
# verbatim. The 2026-05-20 retest #2 button-pair shape is gone;
# the typed-INSTALL ceremony is the deliberate-consent signal the
# legal review wants. TTY fallback (no OSTLER_GUI) still accepts
# the typed answers for operators driving install.sh from a
# terminal -- the while-loop branches below cover both forms.
while true; do
    CONSENT="$(gui_read "$MSG_PROMPT_CONSENT_INSTALL_TITLE" text_with_cancel "" "$MSG_PROMPT_CONSENT_INSTALL_HELP" "INSTALL,CANCEL" "consent_install")"
    # Case-insensitive accept: the GUI normalises to upper-case
    # before posting; TTY operators might type "install" lower-case
    # via a terminal. Bash matches both shapes here.
    CONSENT_NORM="$(printf '%s' "$CONSENT" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    if [[ "$CONSENT_NORM" == "INSTALL" ]]; then
        break
    elif [[ "$CONSENT_NORM" == "CANCEL" ]]; then
        unset RECOVERY_PASSPHRASE 2>/dev/null || true
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

# Studio retest #7 finding #18 (Image #58): post-consent wrap-up
# screen so the customer sees a clean "all set, walk away" state
# instead of bouncing back to the "A few questions" sidebar state
# while Phase 3 kicks off. The step itself is a no-op marker -- the
# GUI renders the HintCopy "setup_complete_wrap_up" block until the
# next step (homebrew_install) fires its STEP_BEGIN.
step "All set. You can walk away now." "setup_complete_wrap_up"

fi  # end of SKIP_PHASE2 check (GDPR scan + consent)

# ══════════════════════════════════════════════════════════════════════
#  PHASE 3: INSTALL EVERYTHING (unattended -- user can walk away)
# ══════════════════════════════════════════════════════════════════════

# CX-8 2026-05-22: emit a phase marker so the GUI strap switches from
# "SETUP (ANSWER A FEW QUESTIONS, THEN WALK AWAY)" to "INSTALLING".
# Without this the previous phase label stuck across all of Phase 3,
# leaving the customer staring at "answer questions" copy while the
# install was actually progressing.
step "$MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE" "phase3_install"

echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Sudo pre-flight gate.
#
# CLI path (no OSTLER_GUI): batch one sudo prompt at the end of Phase 2
# so the unattended Phase 3 is genuinely unattended. macOS sudo timestamp
# lasts ~5 minutes; the Phase-3.0 pmset calls + Homebrew's own sudo calls
# land well within that window. This was the cold-install audit's top
# "walk away" complaint (~2026-05-01).
#
# GUI path (OSTLER_GUI=1): zero sudo prompts during install.sh execution
# (Option B, 2026-05-22 launch-blocker rebase of #111 onto current main).
# The parent .app:
#
#   1. Pre-creates /opt/homebrew + /usr/local/bin owned by the user so
#      Homebrew's own install does not escalate and our /usr/local/bin
#      ostler-knowledge symlink (~line 5339) writes user-side.
#   2. Spawns its own `caffeinate -dimsu` daemon for sleep prevention
#      in place of the `sudo pmset` calls in section 3.0.
#
# With both pre-handled, install.sh under OSTLER_GUI=1 needs no sudo
# at all. Skipping the pre-flight here also skips the prompt that
# never worked on the GUI's pty anyway (read-from-tty wedges
# invisibly behind the Log drawer; Studio retest 2026-05-22 00:42
# HKT and #5 23:43:43 are the same gate).
if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    info "GUI mode -- skipping sudo pre-flight (parent .app has pre-handled root operations)"  # i18n-exempt
else
    echo -e "  ${YELLOW}One-time password prompt: macOS needs your Mac password to disable${NC}"
    echo -e "  ${YELLOW}sleep during the install (and to install Homebrew if missing).${NC}"
    echo -e "  ${YELLOW}After this, the install runs unattended.${NC}"
    echo ""
    sudo -v || fail "$MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL"
fi

# ── Composite cleanup ─────────────────────────────────────────────
#
# Phase 3 allocates several runtime resources (sudo keepalive,
# battery watcher, assistant download tmpdir, Tailscale env-edit
# tmpfile) that must be torn down when the install exits, fails,
# or is interrupted. Bash `trap ... EXIT` is destructive -- each
# new registration replaces the previous one -- so the previous
# pattern of per-resource traps leaked everything except the
# most recently registered handler. The cold-install audit
# (2026-05-02) found the sudo keepalive and battery watcher both
# leaking after the assistant download phase overwrote their
# traps; worst case a stale `sudo -n true` runs every 60s on the
# customer's machine until reboot.
#
# Pattern: each resource has a flag variable. Allocator sets the
# flag; consumer (or composite_cleanup itself if we exit
# mid-phase) frees the resource and clears the flag. `trap
# composite_cleanup EXIT` is registered ONCE here and never
# overwritten.
#
# Adding a new resource: declare its flag below, allocate via
# `FLAG=value`, free via `<release>; FLAG=""`, and add a stanza
# to composite_cleanup. tests/test_composite_cleanup.sh asserts
# the flag list and stanza list stay in sync.
SUDO_KEEPALIVE_PID=""
PHASE3_BATTERY_WATCH_PID=""
ASSISTANT_TMPDIR=""
TAILSCALE_TMP_ENV=""

composite_cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
    if [[ -n "${PHASE3_BATTERY_WATCH_PID:-}" ]]; then
        kill "$PHASE3_BATTERY_WATCH_PID" 2>/dev/null || true
        PHASE3_BATTERY_WATCH_PID=""
    fi
    if [[ -n "${ASSISTANT_TMPDIR:-}" ]]; then
        rm -rf "$ASSISTANT_TMPDIR"
        ASSISTANT_TMPDIR=""
    fi
    if [[ -n "${TAILSCALE_TMP_ENV:-}" ]]; then
        rm -f "$TAILSCALE_TMP_ENV"
        TAILSCALE_TMP_ENV=""
    fi
}
trap composite_cleanup EXIT

# Refresh the sudo timestamp every 60s while this script runs, so a long
# Phase 3 (e.g. slow ollama pull) does not silently expire it. Under
# OSTLER_GUI=1 (Option B) install.sh has no downstream sudo callers, so
# the keepalive is a no-op anyway -- skip the spawn to avoid a stray
# `sudo -n true` once a minute on the customer's machine for the full
# install window.
if [[ "${OSTLER_GUI:-0}" != "1" ]]; then
    ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
fi

echo ""
echo -e "  ${GREEN}${BOLD}  All questions answered. Installing now.${NC}"
NEEDS_HOMEBREW=false
if ! command -v brew &>/dev/null; then
    NEEDS_HOMEBREW=true
else
    echo -e "  ${GREEN}  You can walk away -- this takes about 10-15 minutes.${NC}"
fi
echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

PHASE3_START=$(date +%s)

# ── Progress bar ───────────────────────────────────────────────────

# TOTAL_STEPS = how many `progress` calls will fire during Phase 3.
# Computed dynamically by walking the script so a future PR that
# adds a new `progress` line cannot quietly desynchronise the bar.
# The cold-install audit of 2026-05-02 caught exactly this drift:
# Vane bundling + the GUI-wrapper PR each added a `progress` call
# without bumping the hard-coded base, so the bar saturated at
# ~145% by the wiki phase.
#
# Strategy:
#   1. Count every `progress "..."` line in the script.
#   2. Subtract the ones whose enclosing `if` evaluates false at
#      this point (we can only check Phase 2 flags here -- gates
#      that depend on Phase 3 state, e.g. HAS_PIPELINE, are
#      best-effort).
#   3. If the count looks broken (zero, non-numeric, missing
#      script), fall back to the known-good base of 16 + the GDPR
#      conditional so the bar is never absent.
#
# Drift gate: tests/test_total_steps_dynamic.sh verifies the
# computation against a fixture; a new conditional `progress`
# call must be paired with a matching subtract entry below.

TOTAL_STEPS="$(grep -cE '^[[:space:]]*progress "' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0)"

# Conditional `progress` calls -- one entry per gated section.
# Subtract from the auto-count if the gate evaluates false. Add
# new entries here whenever a `progress` line is added inside an
# `if [[ ... ]]` that depends on a Phase 2 flag.
[[ -z "$EXPORTS_DIR" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))   # GDPR import (~line 3448)

# Defensive fallback for unusual invocation paths (BASH_SOURCE
# resolves to an unreadable /dev/fd/N, the grep returns 0, etc.).
# Better to overshoot 100% by a step or two than divide by zero.
if ! [[ "$TOTAL_STEPS" =~ ^[0-9]+$ ]] || [[ "$TOTAL_STEPS" -le 0 ]]; then
    TOTAL_STEPS=16
    [[ -n "$EXPORTS_DIR" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
CURRENT_STEP=0

progress() {
    # Usage: progress "What is happening right now" [stable-id]
    #
    # Emits a TTY progress bar (unchanged) AND, when OSTLER_GUI=1, a
    # STEP_END for the previous step + STEP_BEGIN for this one. The
    # optional 2nd arg is the stable id surfaced to the GUI; when
    # omitted it is derived from the title.
    local title="$1"
    local id="${2:-}"
    if [[ -z "$id" ]]; then
        id="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"
        [[ -z "$id" ]] && id="step"
    fi

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

    # Close any prior step (no-op if none open) before opening this
    # one. STEP_BEGIN carries idx/total so the GUI can render its own
    # progress bar without re-deriving from PCT.
    if [[ -n "${__OSTLER_STEP_ID:-}" ]]; then
        gui_step_end ok
    fi
    gui_step_begin "$id" "$title" 3 "$CURRENT_STEP" "$TOTAL_STEPS"
    gui_emit PCT "step=$id" "pct=$PCT"

    echo ""
    echo -e "  ${BOLD}[${BAR}] ${PCT}%${ETA}${NC}"
    echo -e "  ${BLUE}$1${NC}"
    echo ""
}

# ── 3.1 Homebrew ───────────────────────────────────────────────────

# ── 3.0 Prevent sleep ─────────────────────────────────────────────
# A personal knowledge system needs to be always-on for background
# tasks (export watcher, FDA re-runs, AI assistant). Keep the Mac
# awake for the duration of the install.
#
# Under OSTLER_GUI=1 (Option B, 2026-05-22) the parent .app has
# already spawned `caffeinate -dimsu` (see CaffeinateManager.swift)
# which holds an IOPMAssertion for the install window. No system-wide
# pmset edit, no sudo prompt -- the per-process assertion lives only
# as long as the .app and releases cleanly on any termination path.
#
# Under CLI install (no OSTLER_GUI): keep the legacy `sudo pmset`
# path. The user already authenticated at the Phase-2-end batched
# pre-flight, so this lands within the same sudo cache window.
#
# Battery-aware (CLI only): on a MacBook Hub we only set never-sleep
# when on AC. On battery we preserve default sleep so the hub-power
# LaunchAgent (step 3.14) can manage the sleep -> wake transition
# and bring services back cleanly. Mac Mini / Studio installs keep
# the original always-on behaviour.

HAS_BATTERY=false
if pmset -g batt 2>/dev/null | grep -qE '[0-9]+%'; then
    HAS_BATTERY=true
fi

if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    info "Sleep prevention via parent .app caffeinate -- skipping pmset"  # i18n-exempt
else
    SLEEP_SETTING=$(pmset -g | grep '^ sleep' | awk '{print $2}' 2>/dev/null || echo "")
    if [[ "$SLEEP_SETTING" != "0" ]]; then
        if [[ "$HAS_BATTERY" == true ]]; then
            info "$MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP"
            sudo pmset -c sleep 0 2>/dev/null && \
            sudo pmset -a womp 1 2>/dev/null && \
            ok "$MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED" || \
            warn "$MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE"
        else
            info "$MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING"
            sudo pmset -a sleep 0 2>/dev/null && \
            sudo pmset -a womp 1 2>/dev/null && \
            ok "$MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED" || \
            warn "$MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2"
        fi
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
# cleanup_battery_watch is called explicitly by Phase 4 to kill
# the watcher before the health-check output starts -- otherwise
# stale "transitioned to battery" messages can interleave with
# the summary banner. composite_cleanup (registered above) is
# the EXIT handler; this function is just a directly-callable
# convenience that lets Phase 4 free the resource early.
# PHASE3_BATTERY_WATCH_PID is already declared in the composite
# cleanup block; no second init here.
cleanup_battery_watch() {
    if [[ -n "$PHASE3_BATTERY_WATCH_PID" ]]; then
        kill "$PHASE3_BATTERY_WATCH_PID" 2>/dev/null || true
        PHASE3_BATTERY_WATCH_PID=""
    fi
}

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
    info "$(printf "$MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID" "$PHASE3_BATTERY_WATCH_PID")"
fi

progress "Checking Homebrew and system tools" "homebrew_install"

if command -v brew &>/dev/null; then
    ok "$MSG_OK_HOMEBREW_INSTALLED"
else
    info "$MSG_INFO_INSTALLING_HOMEBREW"
    # Under OSTLER_GUI=1 the parent .app has pre-created /opt/homebrew
    # owned by the user, AND NONINTERACTIVE=1 tells Homebrew's official
    # installer to skip its own sudo dialog + tty-only prompts (it
    # would otherwise re-prompt for password even when the prefix is
    # already user-owned, then fail because the GUI has no tty).
    if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    if [[ "$ARCH" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "$MSG_OK_HOMEBREW_INSTALLED"
fi

# ── 3.2 Docker ─────────────────────────────────────────────────────

progress "Starting Docker" "docker_install"

if [[ "$HAS_DOCKER" == true ]]; then
    ok "$MSG_OK_DOCKER_RUNNING"
else
    # Prefer Colima over Docker Desktop. Colima is headless (no EULA, no
    # account signup, no system extension dialogs) and works perfectly for
    # running containers on macOS. Docker Desktop is a fallback.
    if ! command -v docker &>/dev/null; then
        info "$MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI"
        brew install colima docker docker-compose
        # Re-eval Homebrew PATH so newly installed commands are found
        if [[ -x /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        ok "$MSG_OK_COLIMA_DOCKER_CLI_INSTALLED"
    fi

    # Check if Colima or Docker Desktop can provide a runtime
    # Ensure docker-compose plugin is discoverable (Colima needs this)
    if [[ ! -f "${HOME}/.docker/config.json" ]] || ! grep -q "cliPluginsExtraDirs" "${HOME}/.docker/config.json" 2>/dev/null; then
        mkdir -p "${HOME}/.docker"
        echo '{"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]}' > "${HOME}/.docker/config.json"
    fi

    if command -v colima &>/dev/null; then
        # Colima uses its own Docker socket -- tell Docker CLI where to find it
        export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

        if ! docker info &>/dev/null 2>&1; then
            info "$MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME"
            # Allocate enough resources for 3 containers
            colima start --cpu 2 --memory 4 --disk 30 2>/dev/null || {
                warn "$MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP"
                if [[ -d "/Applications/Docker.app" ]]; then
                    open -a Docker 2>/dev/null || true
                else
                    fail "$MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD"
                fi
            }
        fi
    elif [[ -d "/Applications/Docker.app" ]]; then
        # Docker Desktop is installed but not running
        info "$MSG_INFO_STARTING_DOCKER_DESKTOP"
        echo ""
        echo "  If this is Docker's first run, it may show several dialogs:"
        echo "    - Accept the licence agreement"
        echo "    - Allow the system extension (if prompted)"
        echo "    - Skip sign-in (you don't need a Docker account)"
        echo "    - Close any welcome/survey screens"
        echo ""
        open -a Docker 2>/dev/null || true
    else
        fail "$MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER"
    fi

    # Wait for Docker to be ready (Colima or Desktop)
    DOCKER_WAIT=0
    DOCKER_TIMEOUT=300
    while ! docker info &>/dev/null 2>&1; do
        if [[ $DOCKER_WAIT -ge $DOCKER_TIMEOUT ]]; then
            warn "$(printf "$MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS" "${DOCKER_TIMEOUT}")"
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
    ok "$(printf "$MSG_OK_DOCKER_RUNNING_TOOK_S" "${DOCKER_WAIT}")"

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
            ok "$MSG_OK_COLIMA_WILL_START_AUTOMATICALLY_BOOT"
        fi
    fi
fi

# ── 3.3 Ollama ─────────────────────────────────────────────────────

progress "Setting up Ollama (local AI engine)" "ollama_install"

if command -v ollama &>/dev/null; then
    ok "$MSG_OK_OLLAMA_INSTALLED"
else
    # Install the cask (GUI app) not the formula (CLI only).
    # The cask auto-starts Ollama on boot via launchd.
    # The formula requires manual `ollama serve` after every reboot.
    info "$MSG_INFO_INSTALLING_OLLAMA"
    if brew install --cask ollama 2>/dev/null; then
        ok "$MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP"
    else
        # Fallback to CLI formula if cask fails
        brew install ollama
        ok "$MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED"
    fi
fi

if curl -s http://localhost:11434/api/tags &>/dev/null; then
    ok "$MSG_OK_OLLAMA_RUNNING"
else
    info "$MSG_INFO_STARTING_OLLAMA"
    # Try launching the app first (persists across reboots).
    # -gj: start in background, hidden -- it's a daemon, no UI needed.
    open -gj -a Ollama 2>/dev/null || ollama serve &>/dev/null &
    # Wait up to 30 seconds for Ollama to be ready
    OLLAMA_WAIT=0
    while ! curl -s http://localhost:11434/api/tags &>/dev/null; do
        if [[ $OLLAMA_WAIT -ge 90 ]]; then
            warn "$MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY"
            echo "  macOS may have asked you to approve Ollama."
            echo "  Open Ollama from Applications, approve any dialogs, then re-run."
            exit 1
        fi
        sleep 2
        OLLAMA_WAIT=$((OLLAMA_WAIT + 2))
    done
    ok "$MSG_OK_OLLAMA_RUNNING"
fi

# ── 3.4 Python check ──────────────────────────────────────────────
#
# The verified-3.10+ Python is established in Phase 2.99 before any
# venv creation (so the venv is bound to the correct interpreter from
# the start). This block remains as a defence-in-depth no-op log line
# in case PYTHON3_BIN was somehow unset; the original install/check
# logic moved up to Phase 2.99 per the 2026-05-22 phase-ordering fix.
if [[ -n "${PYTHON3_BIN:-}" && -x "$PYTHON3_BIN" ]]; then
    PY_VERSION=$("$PYTHON3_BIN" --version 2>&1 | cut -d' ' -f2)
    ok "$(printf "$MSG_OK_PYTHON" "${PY_VERSION}")"
else
    fail "PYTHON3_BIN is unset at Phase 3.4; the Phase 2.99 Python check should have set it. This is a script bug."
fi

# ── 3.5 Write config ──────────────────────────────────────────────

progress "Saving your configuration" "config_save"

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

ok "$(printf "$MSG_OK_CONFIG_SAVED_ENV" "${CONFIG_DIR}")"

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

# ── Chat admin token seed (CM031 PR #43 / HR015 PR #63 sister) ────
#
# Pre-seed a ZeroClaw admin token so the unified Hub can mint
# device-bearer tokens for the iOS chat tab via
# POST /api/v1/auth/chat-token (HR015 doctor/agent/chat_token.py).
#
# The token gets written to TWO places, both mode 0600:
#
#   1. ${OSTLER_DIR}/secrets/zeroclaw_admin_token
#      Read by the Doctor at request time. Default path matches
#      HR015 chat_token.DEFAULT_ADMIN_TOKEN_FILE.
#   2. The [gateway].paired_tokens array in the assistant config TOML
#      (rendered just below). ZeroClaw loads it at boot and treats
#      any HTTP request bearing this token as authenticated.
#
# Idempotent: re-running the installer reuses the existing token.
# Regenerating would silently invalidate any iOS device that
# bootstrapped against the old token, forcing a re-pair.
SECRETS_DIR="${OSTLER_DIR}/secrets"
CHAT_ADMIN_TOKEN_FILE="${SECRETS_DIR}/zeroclaw_admin_token"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [[ -s "$CHAT_ADMIN_TOKEN_FILE" ]]; then
    CHAT_ADMIN_TOKEN=$(cat "$CHAT_ADMIN_TOKEN_FILE")
else
    CHAT_ADMIN_TOKEN=$(openssl rand -hex 32)
    umask_admin_orig=$(umask)
    umask 0077
    printf '%s' "$CHAT_ADMIN_TOKEN" > "$CHAT_ADMIN_TOKEN_FILE"
    umask "$umask_admin_orig"
    chmod 600 "$CHAT_ADMIN_TOKEN_FILE"
fi

# ── CM019 JWT_SECRET + PWG service-token seed (CM019 clean-house PR 2) ──
#
# Seeds the JWT signing secret read by the CM019 gateway / MCP /
# ingest services at boot, plus a separate service-token for the
# local Rust assistant + CLI tools.
#
# CM019 PR 3 (compose-side) changes docker-compose.apps.yml to
# resolve ${JWT_SECRET:?required - run install.sh} against the env.
# That PR is blocked on this one landing first: without a real
# JWT_SECRET in ${OSTLER_DIR}/.env, the first compose-up fails
# loudly. CM019 services (gateway, MCP, ingest) also hard-fail at
# import time against the same banlist mirrored from
# services/common/auth/jwt.py; shipping a placeholder defeats the
# discipline.
#
# Two artefacts, both mode 0600 with umask-tightened creation:
#
#   1. ${OSTLER_DIR}/.env line "JWT_SECRET=<openssl rand -hex 32>"
#      Read by docker-compose.apps.yml and any launchd-spawned
#      service that env-sources this file.
#   2. ${OSTLER_DIR}/secrets/service_token (file): the service
#      bearer used by the local Rust assistant + CLI tools to
#      call the CM019 services. Distinct from zeroclaw_admin_token
#      (which is the ZeroClaw / iOS-pairing bearer above).
#
# Idempotent: re-running the installer reuses existing values
# when they are real (>= 32 chars and not on the banlist). A
# banlisted or short value is regenerated with a warn(); silently
# keeping a banlisted secret would defeat the no-silent-fallback
# discipline the services rely on.
#
# Banlist mirrors services/common/auth/jwt.py _JWT_DEFAULT_BANLIST
# inline so a customer install does not depend on the personal-
# world-graph source being present at install time.

OSTLER_ENV_FILE="${OSTLER_DIR}/.env"
SERVICE_TOKEN_FILE="${SECRETS_DIR}/service_token"
_jwt_secret_min_length=32

_is_jwt_secret_banlisted() {
    # Matches the banlist at services/common/auth/jwt.py:39-49.
    case "$1" in
        "changeme-in-production-min-32-chars" \
            | "changeme" | "CHANGEME" | "secret" \
            | "your-secret-here" | "your-secret-key" \
            | "default-secret" | "test-secret" | "dev-secret")
            return 0
            ;;
    esac
    return 1
}

# Read existing JWT_SECRET if any. Use grep / cut rather than
# sourcing the file -- sourcing would execute arbitrary shell.
_existing_jwt_secret=""
if [[ -f "$OSTLER_ENV_FILE" ]]; then
    _existing_jwt_secret=$(grep -E '^JWT_SECRET=' "$OSTLER_ENV_FILE" | head -1 | cut -d= -f2- || true)
    _existing_jwt_secret="${_existing_jwt_secret#\"}"
    _existing_jwt_secret="${_existing_jwt_secret%\"}"
    _existing_jwt_secret="${_existing_jwt_secret#\'}"
    _existing_jwt_secret="${_existing_jwt_secret%\'}"
fi

_need_new_jwt=false
if [[ -z "$_existing_jwt_secret" ]]; then
    _need_new_jwt=true
elif _is_jwt_secret_banlisted "$_existing_jwt_secret"; then
    warn "$(printf "$MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019" "${OSTLER_ENV_FILE}")"
    _need_new_jwt=true
elif (( ${#_existing_jwt_secret} < _jwt_secret_min_length )); then
    warn "$(printf "$MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING" "${OSTLER_ENV_FILE}" "${#_existing_jwt_secret}" "${_jwt_secret_min_length}")"
    _need_new_jwt=true
fi

if [[ "$_need_new_jwt" == true ]]; then
    JWT_SECRET=$(openssl rand -hex 32)
    umask_jwt_orig=$(umask)
    umask 0077
    touch "$OSTLER_ENV_FILE"
    chmod 600 "$OSTLER_ENV_FILE"
    # Filter any prior JWT_SECRET line then append the fresh one
    # so existing unrelated keys in .env are preserved.
    if grep -q '^JWT_SECRET=' "$OSTLER_ENV_FILE" 2>/dev/null; then
        sed -i.bak '/^JWT_SECRET=/d' "$OSTLER_ENV_FILE"
        rm -f "${OSTLER_ENV_FILE}.bak"
    fi
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET" >> "$OSTLER_ENV_FILE"
    chmod 600 "$OSTLER_ENV_FILE"
    umask "$umask_jwt_orig"
    ok "$(printf "$MSG_OK_SEEDED_FRESH_JWT_SECRET" "${OSTLER_ENV_FILE}")"
else
    JWT_SECRET="$_existing_jwt_secret"
    info "$(printf "$MSG_INFO_REUSING_EXISTING_JWT_SECRET" "${OSTLER_ENV_FILE}")"
fi

# Service token: separate file under secrets/. Reuse if present
# (regenerating would invalidate any local CLI tool / assistant
# instance that bootstrapped against the prior token).
if [[ -s "$SERVICE_TOKEN_FILE" ]]; then
    PWG_SERVICE_TOKEN=$(cat "$SERVICE_TOKEN_FILE")
    info "$(printf "$MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN" "${SERVICE_TOKEN_FILE}")"
else
    PWG_SERVICE_TOKEN=$(openssl rand -hex 32)
    umask_svc_orig=$(umask)
    umask 0077
    printf '%s' "$PWG_SERVICE_TOKEN" > "$SERVICE_TOKEN_FILE"
    umask "$umask_svc_orig"
    chmod 600 "$SERVICE_TOKEN_FILE"
    ok "$(printf "$MSG_OK_SEEDED_PWG_SERVICE_TOKEN" "${SERVICE_TOKEN_FILE}")"
fi

unset _existing_jwt_secret _need_new_jwt _jwt_secret_min_length

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

    # ── Providers: Ollama fallback ──────────────────────────────
    #
    # Customer's LLM provider profile. Without this, the agent
    # runtime's fallback_provider() returns None and any agent-type
    # cron job (the morning brief + evening wrap emitted further
    # down, plus any future agent-driven surface) fails at fire
    # time with "no provider configured".
    #
    # Schema reference: crates/zeroclaw-config/src/providers.rs
    #   ProvidersConfig.fallback resolves to
    #   ProvidersConfig.models[<key>]. The HashMap key "ollama"
    #   is what the provider-factory matches in
    #   crates/zeroclaw-providers/src/lib.rs::create_provider;
    #   the optional name field inside the entry is a display
    #   override and is not needed here.
    #
    # base_url + model are the load-bearing fields. base_url is
    # the Ollama server URL the installer wired up in Phase 1.5b
    # (brew install ollama + open -a Ollama). The model is the
    # tier-aware default the installer chose at AI_MODEL
    # selection time (high RAM = qwen3.6:35b-a3b, mid =
    # qwen3.5:9b, low = gemma4:e2b). The customer can edit
    # either field post-install in the assistant config TOML.
    #
    # timeout_secs is set generously because the local Ollama
    # can take several seconds to warm up on first call after
    # launchd boot.
    _ai_model_default="${AI_MODEL:-qwen3.5:9b}"
    _ai_model_esc="${_ai_model_default//\"/\\\"}"
    echo
    echo "[providers]"
    echo "fallback = \"ollama\""
    echo
    echo "[providers.models.ollama]"
    echo "base_url = \"http://localhost:11434\""
    echo "model = \"${_ai_model_esc}\""
    echo "timeout_secs = 300"

    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true || "$CHANNEL_EMAIL_ENABLED" == true || "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
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
        # Source flags. `apple_mail = true` tells the email-ingest
        # LaunchAgent (HR015) to drain from Apple Mail's local mbox
        # via Full Disk Access. `custom_imap = true` tells it to
        # also poll the IMAP host below. Both may be true.
        if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]]; then
            echo "apple_mail = true"
        else
            echo "apple_mail = false"
        fi
        if [[ "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" == true ]]; then
            echo "custom_imap = true"
        else
            echo "custom_imap = false"
        fi
        # Folder/label is the scoping rule for both paths -- read
        # only messages in the named folder/label across whichever
        # source(s) are enabled.
        echo "imap_folder = \"$(_esc "$CHANNEL_EMAIL_IMAP_FOLDER")\""
        # IMAP / SMTP fields. Always emitted to keep the TOML keys
        # stable for the parser; populated only when custom_imap is
        # on, empty strings otherwise.
        echo "imap_host = \"$(_esc "$CHANNEL_EMAIL_IMAP_HOST")\""
        echo "imap_port = ${CHANNEL_EMAIL_IMAP_PORT}"
        echo "smtp_host = \"$(_esc "$CHANNEL_EMAIL_SMTP_HOST")\""
        echo "smtp_port = ${CHANNEL_EMAIL_SMTP_PORT}"
        echo "smtp_tls = true"
        echo "username = \"$(_esc "$CHANNEL_EMAIL_USERNAME")\""
        echo "password = \"$(_esc "$CHANNEL_EMAIL_PASSWORD")\""
        echo "from_address = \"$(_esc "$CHANNEL_EMAIL_FROM")\""
        echo "allowed_senders = []"
    fi

    if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
        # Web mode (wa-rs). Pair-code linking happens at runtime
        # the first time the assistant binary boots; the user runs
        # `ostler-assistant setup channels --interactive whatsapp`
        # to enter the 8-digit code from the WhatsApp app.
        #
        # allowed_numbers seeds the inbound allowlist with the
        # customer's own WhatsApp number captured during the wizard
        # (CHANNEL_WHATSAPP_RECIPIENT). Without it, dm_policy
        # defaults to "allowlist" and an empty allowlist denies
        # every inbound message -- including the customer's own
        # replies to their morning brief. See verify report at
        # /tmp/DAILY_BRIEFS_OOTB_VERIFY_2026-05-09.md item 6.
        echo
        echo "[channels.whatsapp]"
        echo "enabled = true"
        echo "mode = \"personal\""
        if [[ -n "$CHANNEL_WHATSAPP_RECIPIENT" ]]; then
            # Escape any embedded double quotes (paranoia: E.164
            # validation rejects them already, but the TOML emit
            # path stays safe regardless).
            _wa_recipient_esc="${CHANNEL_WHATSAPP_RECIPIENT//\"/\\\"}"
            echo "allowed_numbers = [\"${_wa_recipient_esc}\"]"
        fi
    fi

    # Pre-seed the chat admin token into ZeroClaw's gateway config
    # so the Doctor's POST /api/v1/auth/chat-token endpoint
    # (HR015 doctor/agent/chat_token.py) can call /api/pairing/initiate
    # with admin auth. Without this, every iOS chat-tab bootstrap
    # surfaces ChatEmptyState(.bootstrapFailed) with a 502 from
    # ZeroClaw rejecting the admin token. See sister PR HR015 #63.
    echo
    echo "[gateway]"
    echo "paired_tokens = [\"${CHAT_ADMIN_TOKEN}\"]"

    # Wire the assistant's web_search tool to the bundled Vane
    # container (Phase 3.8b). Without this block the customer has
    # Vane running AND the assistant supports Vane (ostler-assistant
    # #17), but the two are not connected -- the assistant would
    # fall back to its compiled-in default. Always emit; Vane is
    # bundled by default.
    echo
    echo "[tools.web_search]"
    echo "provider = \"vane\""
    echo "vane_url = \"http://localhost:3000\""

    # ── Cron jobs: morning brief + evening wrap ─────────────────
    #
    # Schema: crates/zeroclaw-config/src/schema.rs::CronJobDecl,
    #         CronScheduleDecl, DeliveryConfigDecl.
    #
    #   CronJobDecl   { id (required), name?, job_type = "shell"|"agent",
    #                   schedule, command? (shell), prompt? (agent),
    #                   delivery? }
    #   CronScheduleDecl is #[serde(tag = "kind", rename_all = "lowercase")]
    #     so the Cron variant is keyed `kind = "cron"`, NOT `type`.
    #   DeliveryConfigDecl { mode = "announce", channel, to, best_effort }
    #
    # Field discipline notes:
    #
    #   - `id` is REQUIRED on CronJobDecl. The daemon refuses to
    #     deserialise a job without it (no #[serde(default)] on the
    #     field). Earlier emits used only `name = "morning-brief"`
    #     and quietly stopped the whole cron section from loading.
    #   - `kind = "cron"` matches the schema tag. `type = "cron"`
    #     would land on the unknown-variant error path.
    #   - `job_type = "agent"` + `prompt` is the right shape for a
    #     daily brief: the runtime hands the prompt to the configured
    #     LLM provider, captures stdout, and announce-delivers it
    #     via the channel orchestrator. `shell` would need a CLI
    #     subcommand that does not yet exist on the binary.
    #
    # Only emit when WhatsApp is the configured outbound channel
    # AND we have a recipient phone. Without those, the cron job
    # would either fail at every fire (no recipient) or silently
    # do nothing (channel disabled). When we can't emit, the
    # next-steps banner tells the customer how to add jobs by
    # hand later (see Phase 5 banner edits below).
    #
    # tz is set from the wizard-captured USER_TZ so the brief
    # lands at 09:00 customer-local rather than UTC. The schema's
    # default scheduler is UTC if tz is absent.
    #
    # best_effort = false (NOT true): a delivery failure surfaces
    # as a hard error in cron history rather than getting swallowed
    # as a WARN. Andy's existing config used best_effort = true,
    # which masked the very bug the TNM cron-delivery fix was
    # written to solve. Per memory/feedback_no_silent_security_fallback.md
    # new customers default-fail-loud so any regression surfaces
    # in Doctor immediately.
    #
    # Prompt copy is plain prose, British English, deliberately
    # short. The agent runtime prepends a memory-recall context
    # block (zeroclaw-runtime/src/cron/scheduler.rs::run_agent_job),
    # so we do not have to spell out "look at yesterday's data"
    # twice. Customers can edit the prompt after install by hand
    # in ${OSTLER_DIR}/assistant-config/config.toml.
    if [[ "$CHANNEL_WHATSAPP_ENABLED" == true && -n "$CHANNEL_WHATSAPP_RECIPIENT" ]]; then
        _wa_recipient_cron_esc="${CHANNEL_WHATSAPP_RECIPIENT//\"/\\\"}"
        _user_tz_esc="${USER_TZ//\"/\\\"}"
        _morning_prompt="You are the user's personal assistant. Write a concise morning brief in plain prose for delivery over WhatsApp. Summarise the most relevant items from yesterday's conversations, meetings and emails. Aim for three or four short sentences. If yesterday was quiet, say so warmly without padding. British English. No headings, no lists, no markdown. Output only the brief itself."
        _evening_prompt="You are the user's personal assistant. Write a concise evening wrap in plain prose for delivery over WhatsApp. Reflect on the most notable items from today's conversations, meetings and emails. Aim for three or four short sentences. If today was quiet, say so warmly without padding. British English. No headings, no lists, no markdown. Output only the wrap itself."
        _morning_prompt_esc="${_morning_prompt//\"/\\\"}"
        _evening_prompt_esc="${_evening_prompt//\"/\\\"}"
        echo
        echo "[[cron.jobs]]"
        echo "id = \"morning-brief\""
        echo "name = \"Morning brief\""
        echo "job_type = \"agent\""
        echo "schedule = { kind = \"cron\", expr = \"0 9 * * *\", tz = \"${_user_tz_esc}\" }"
        echo "prompt = \"${_morning_prompt_esc}\""
        echo "delivery = { mode = \"announce\", channel = \"whatsapp\", to = \"${_wa_recipient_cron_esc}\", best_effort = false }"
        echo
        echo "[[cron.jobs]]"
        echo "id = \"evening-wrap\""
        echo "name = \"Evening wrap\""
        echo "job_type = \"agent\""
        echo "schedule = { kind = \"cron\", expr = \"0 18 * * *\", tz = \"${_user_tz_esc}\" }"
        echo "prompt = \"${_evening_prompt_esc}\""
        echo "delivery = { mode = \"announce\", channel = \"whatsapp\", to = \"${_wa_recipient_cron_esc}\", best_effort = false }"
    fi
} > "$ASSISTANT_CONFIG"
chmod 600 "$ASSISTANT_CONFIG"
umask "$umask_orig"

# Scrub the plaintext password from the bash environment as soon as
# the file is written. The TOML still has it on disk; this just
# narrows the in-memory exposure for the rest of the install.
unset CHANNEL_EMAIL_PASSWORD

# Same treatment for the chat admin token. Both copies (TOML +
# secrets file) are written and locked down by now.
unset CHAT_ADMIN_TOKEN

ok "$(printf "$MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600" "${ASSISTANT_CONFIG}")"
if [[ "$CHANNEL_IMESSAGE_ENABLED" != true && "$CHANNEL_EMAIL_ENABLED" != true && "$CHANNEL_WHATSAPP_ENABLED" != true ]]; then
    info "$(printf "$MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN" "${OSTLER_DIR}")"
fi

# ── 3.6 Security setup ────────────────────────────────────────────

progress "Encrypting your databases" "encrypt_db"

# Install SQLCipher
if ! brew list sqlcipher &>/dev/null 2>&1; then
    info "$MSG_INFO_INSTALLING_SQLCIPHER"
    brew install sqlcipher
fi

# Venv was created in Phase 2 for ostler_security install.
# Ensure it exists (re-run safe) and install remaining dependencies.
OSTLER_VENV="${OSTLER_DIR}/.venv"
if [[ ! -d "$OSTLER_VENV" ]]; then
    "$PYTHON3_BIN" -m venv "$OSTLER_VENV"
fi
OSTLER_PIP="${OSTLER_VENV}/bin/pip"
OSTLER_PYTHON="${OSTLER_VENV}/bin/python3"

info "$MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES"
# `cryptography` is dragged in transitively by the ostler_security
# wheel install above (line 1497) which hard-fails properly. The
# previous explicit pip install here used `2>/dev/null || true`
# and silently masked any genuine cryptography install failure --
# audit ref /tmp/silent_fail_audit_2026-05-04.md HIGH-2.

# Studio retest 2026-05-22 round 3: pysqlcipher3 1.2.0 (the only
# release on PyPI, March 2020) is abandoned. Its setup.py ignores
# both `SQLCIPHER_CFLAGS` and standard `CFLAGS`/`LDFLAGS`, so the
# wheel build never finds Homebrew's sqlcipher headers + always
# dies with `fatal error: 'sqlcipher/sqlite3.h' file not found`,
# regardless of Python version or env-var permutation. Migrate to
# `sqlcipher3` (the maintained fork), which ships prebuilt
# macosx_11_0_arm64 wheels for cp310/cp311/cp312 -- installs in <1s
# with no compile. Import API is identical at the dbapi2 level so
# `from sqlcipher3 import dbapi2 as sqlcipher` is a drop-in swap.
"$OSTLER_PIP" install "sqlcipher3>=0.6.0,<0.7.0" || {
    # See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT"
        warn "$(printf "$MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL" "${OSTLER_PIP}")"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        warn "$MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED"
        warn "$(printf "$MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL" "${OSTLER_PIP}")"
        fail "$MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN"
    fi
}

# Run passphrase-primary security setup via ostler_security.passphrase.
#
# v1.0 passphrase-primary unlock (replaces setup_wizard / passkey path).
# Studio retests #10 + #11 (2026-05-22) confirmed Apple's framework
# excludes Apple Watch as user verification for Secure-Enclave-backed
# passkeys (Macworld + Hanko cites). Mac Studio (no Touch ID) literally
# cannot register an ASAuthorizationPlatformPublicKeyCredentialProvider
# passkey regardless of Watch state. Rather than ship a broken passkey
# path or split into two flows mid-launch, v1.0 uses the recovery
# passphrase the customer typed in Phase 2 as the SOLE primary unlock.
# Works on every Mac. One code path. Passkey convenience returns in
# v1.0.1 as a Touch-ID-only convenience layer on top of this.
#
# setup_passphrase() (vendor/ostler_security/passphrase.py:276):
#   1. Validates passphrase strength (min length checked in Phase 2)
#   2. Generates encryption salt + main DEK
#   3. Generates recovery_key (XXXX-XXXX-XXXX-XXXX-XXXX-XXXX format)
#   4. Wraps the DEK under BOTH the passphrase-derived KEK and the
#      recovery-key-derived KEK
#   5. Writes ${SECURITY_CONFIG_DIR}/keychain.json
#
# Returns dict with 'recovery_key' (the XXXX-... format, shown once at
# Phase 4, line ~6373) and 'config_path'.
#
# See launch/DEFIB_2026-05-22_late_afternoon_passkey_fallback.md.
# See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
if [[ "$PASSKEY_PRIMED" == true && "$HAS_SECURITY_MODULE" == true ]]; then
    # Pass passphrase via env var (not arg) to avoid leak in ps(1).
    SETUP_OUTPUT=$(RECOVERY_PASSPHRASE_FOR_SETUP="$RECOVERY_PASSPHRASE" "$OSTLER_PYTHON" -c "
import os
import sys
from pathlib import Path
try:
    from ostler_security.passphrase import setup_passphrase
    from ostler_security.audit_log import log_event, EVENT_UNLOCK
    passphrase = os.environ['RECOVERY_PASSPHRASE_FOR_SETUP']
    result = setup_passphrase(passphrase, config_dir=Path('${SECURITY_CONFIG_DIR}'))
    log_event(
        EVENT_UNLOCK,
        source='install.sh',
        details={'action': 'passphrase_setup'},
        db_path=Path('${SECURITY_CONFIG_DIR}') / 'audit.db',
    )
    # Emit recovery_key on stdout for the installer to show once
    # at Phase 4 keychain-save (line ~6373). Format is the
    # XXXX-XXXX-XXXX-XXXX-XXXX-XXXX recovery key, not BIP39.
    print('RECOVERY_PHRASE=' + result['recovery_key'])
except SystemExit as e:
    print('ERROR=passphrase setup exited with code ' + str(e.code), file=sys.stderr)
    sys.exit(int(e.code) if isinstance(e.code, int) else 1)
except Exception as e:
    print('ERROR=' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)
    SETUP_EXIT=$?
    unset RECOVERY_PASSPHRASE

    if [[ $SETUP_EXIT -ne 0 ]]; then
        if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
            warn "$MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE"
            warn "$MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER"
            warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
        else
            warn "$MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT"
            echo "$SETUP_OUTPUT" | sed -e 's/^/    /' | head -15
            fail "$MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH"
        fi
    else
        RECOVERY_KEY=$(echo "$SETUP_OUTPUT" | grep "^RECOVERY_PHRASE=" | cut -d= -f2-)
        ok "$MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP"
    fi
elif [[ -f "${SECURITY_CONFIG_DIR}/passkey.json" || -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
    # Re-run: security already configured in a previous install.
    # This is the legitimate skip path; nothing to do.
    :
else
    # Not primed and no existing security configuration. Deployed
    # services refuse to start without encryption, so this would
    # produce a green "succeeded" summary followed by services that
    # will not boot.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT"
        warn "$MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        fail "$MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY"
    fi
fi

# Posture marker for --allow-plaintext installs. Runtime guards in
# CM041 / CM048 will eventually read this to skip the hard-fail in
# dev mode; out of scope to wire that up here.
# See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1.
if [[ "$ALLOW_PLAINTEXT" == "1" && ! -f "${SECURITY_CONFIG_DIR}/passkey.json" && ! -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then
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
    info "$(printf "$MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON" "${POSTURE_DIR}")"
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
    info "$MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION"

    # Region first.
    "$OSTLER_PYTHON" - "$OSTLER_REGION" "$OSTLER_REGION_ISO" "$OSTLER_REGION_SOURCE" <<'PY' || \
        warn "$MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING"
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

    # Wraps `ostler_security.consent_cli record` with proper stderr
    # handling. The previous in-line pattern used `2>/dev/null || warn`
    # which swallowed the python traceback, leaving operators with
    # "could not persist" but no diagnosable cause. Audit ref
    # /tmp/silent_fail_audit_2026-05-04.md HIGH-3.
    #
    # Mode:
    #   blocking - on failure, surface the captured stderr via warn so
    #              the operator can diagnose why the gate stays closed.
    #   declined - record an explicit decline; on failure, append to
    #              ${OSTLER_DIR}/posture/consent-cli-failures.log so
    #              Doctor surfaces it without bothering the user.
    _consent_cli_record() {
        local mode="$1" tickbox="$2" decision="$3" fail_msg="$4"
        local stderr_file
        stderr_file=$(mktemp)
        if USER_ID="${USER_ID:?USER_ID must be set before consent recording}" \
           "$OSTLER_PYTHON" -m ostler_security.consent_cli record \
                --tickbox "$tickbox" \
                --decision "$decision" \
                --region "$OSTLER_REGION" \
                --user-id "${USER_ID:?USER_ID must be set before consent recording}" 2>"$stderr_file"; then
            rm -f "$stderr_file"
            return 0
        fi
        if [[ "$mode" == "blocking" ]]; then
            warn "$fail_msg"
            warn "$MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS"
            head -c 400 "$stderr_file" 2>/dev/null | sed 's/^/    /' | head -10 || true
        else
            local doctor_log="${OSTLER_DIR}/posture/consent-cli-failures.log"
            mkdir -p "${OSTLER_DIR}/posture" 2>/dev/null || true
            {
                echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] tickbox=$tickbox decision=$decision"
                head -c 400 "$stderr_file" 2>/dev/null
                echo ""
                echo "---"
            } >> "$doctor_log" 2>/dev/null || true
        fi
        rm -f "$stderr_file"
        return 0
    }

    # Article 9 (EU branch only).
    if [[ -n "$OSTLER_CONSENT_ARTICLE_9_DECISION" ]]; then
        _consent_cli_record blocking \
            article_9_special_category_consent \
            "$OSTLER_CONSENT_ARTICLE_9_DECISION" \
            "Could not persist Article 9 consent (continuing)"
    fi

    # WhatsApp tickbox.
    if [[ "$CHANNEL_WHATSAPP_CONSENT_ACCEPTED" == true ]]; then
        _consent_cli_record blocking \
            whatsapp_unofficial_risk \
            accepted \
            "Could not persist WhatsApp consent (continuing - bridge will refuse to start)"
    elif [[ "${WA_CONSENT:-}" == "n" || "${WA_CONSENT:-}" == "N" ]]; then
        # User explicitly declined the WhatsApp tickbox after
        # selecting option 5. Record the decline so Doctor surfaces
        # "user declined" rather than "missing".
        _consent_cli_record declined \
            whatsapp_unofficial_risk \
            declined \
            "Could not persist WhatsApp decline record"
    fi

    # EU voice gate.
    if [[ -n "$OSTLER_CONSENT_VOICE_EU_DECISION" ]]; then
        _consent_cli_record blocking \
            voice_speaker_id_eu \
            "$OSTLER_CONSENT_VOICE_EU_DECISION" \
            "Could not persist EU voice consent (continuing - cm041 will refuse to start)"
    fi

    # Third-party-data acknowledgement (every region). Decline aborts
    # earlier in Phase 2, so by the time we get here the value is
    # always "accepted" (or empty if the install was resumed in a way
    # that skipped the screen, in which case we omit the record and
    # Doctor's Consent tile will surface "missing" as a posture marker).
    if [[ -n "$OSTLER_CONSENT_THIRD_PARTY_DECISION" ]]; then
        _consent_cli_record blocking \
            third_party_data_personal_records \
            "$OSTLER_CONSENT_THIRD_PARTY_DECISION" \
            "Could not persist third-party-data acknowledgement (continuing)"
    fi

    ok "$MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE"
fi

# ── 3.7 FDA extraction (instant onboarding data) ─────────────────

progress "Extracting data from your Mac (the instant bit)" "fda_extract"

if [[ "$HAS_FDA_MODULE" == true ]]; then
    # Pre-launch apps to trigger iCloud sync ONLY if their databases are
    # missing. Calendar, Reminders, Notes, and Mail each create their data
    # store on first launch; if it already exists (re-run, or user has
    # used the app before), opening the app is unnecessary and intrusive.
    # -gj flags: open in background, hidden -- no window steal on first run.
    APPS_TO_OPEN=()
    [[ ! -d "$HOME/Library/Calendars" ]] && APPS_TO_OPEN+=("Calendar")
    [[ ! -d "$HOME/Library/Group Containers/group.com.apple.reminders" ]] && APPS_TO_OPEN+=("Reminders")
    [[ ! -f "$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite" ]] && APPS_TO_OPEN+=("Notes")
    [[ ! -d "$HOME/Library/Mail" ]] && APPS_TO_OPEN+=("Mail")

    if [[ ${#APPS_TO_OPEN[@]} -gt 0 ]]; then
        info "$(printf "$MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN" "${APPS_TO_OPEN[*]}")"
        for app in "${APPS_TO_OPEN[@]}"; do
            open -gj -a "$app" 2>/dev/null || true
        done
        # Give apps 10 seconds to launch and start syncing
        sleep 10
        # Close them quietly (SIGTERM via AppleScript, not force-kill)
        for app in "${APPS_TO_OPEN[@]}"; do
            osascript -e "tell application \"$app\" to quit" 2>/dev/null || true
        done
        ok "$MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC"
    else
        ok "$MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE"
    fi
    echo ""

    info "$MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS"
    info "$MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO"
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
        warn "$MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL"
        warn "$MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM"
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
        info "$MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION"
    fi
    echo ""

    # Pass user's per-source consent (set in Phase 2) to the extractor.
    # Capture exit code separately from the output: a wholesale
    # extractor crash (import failure, segfault, raised exception)
    # is captured in $FDA_OUTPUT but the previous code only matched
    # `^\[ok\]/[skip]/[warn]` formatted lines, so a Python traceback
    # was invisible and the user got the bland "no FDA sources
    # available" message. Audit ref
    # /tmp/silent_fail_audit_2026-05-04.md HIGH-1.
    set +e
    FDA_OUTPUT=$(OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES}" \
                 OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}" \
                 "$OSTLER_PYTHON" -c "
import sys, json
sys.path.insert(0, '${FDA_DIR}')
from ostler_fda.extract_all import run_all
from pathlib import Path
summary = run_all(Path('${OSTLER_DIR}/imports/fda'))
print(json.dumps(summary, default=str))
" 2>&1)
    FDA_EXIT=$?
    set -e

    # Parse results for the summary
    FDA_OK=$(echo "$FDA_OUTPUT" | grep -c '^\[ok\]' || true)
    FDA_SKIP=$(echo "$FDA_OUTPUT" | grep -c '^\[skip\]' || true)

    # Show each line of extractor output
    echo "$FDA_OUTPUT" | grep '^\[' | while IFS= read -r line; do
        echo "     $line"
    done

    if [[ $FDA_OK -gt 0 ]]; then
        ok "$(printf "$MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED" "${FDA_OK}" "${OSTLER_DIR}")"
    elif [[ $FDA_EXIT -ne 0 ]]; then
        # Extractor crashed wholesale (import failure, segfault,
        # raised exception). Surface the tail of stderr+stdout so
        # the operator can diagnose, instead of pretending success
        # via the "no sources available" branch.
        warn "$(printf "$MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST" "$FDA_EXIT")"
        printf '%s\n' "$FDA_OUTPUT" | tail -n 20 | sed 's/^/    /'
        warn "$MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA"
    else
        info "$MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW"
        info "$MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL"
        info "$MSG_INFO_AND_RE_RUN_OSTLER_FDA"
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
        ok "$MSG_OK_FDA_RE_RUN_SCHEDULED_12_HOURS"
    fi
else
    # Reachable only when --allow-plaintext was passed AND the FDA
    # module is missing (the upstream probe at install.sh:1854 hard-
    # fails in non-plaintext mode). Surface that we are skipping the
    # instant data extraction so the operator is not surprised by an
    # empty ~/.ostler/imports/fda/.
    info "$MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING"
    info "$MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT"
fi

# ── 3.8 Docker services ───────────────────────────────────────────

progress "Starting your knowledge graph databases" "graph_db_start"

# Check for port conflicts before starting containers
_check_port() {
    if lsof -i ":$1" -sTCP:LISTEN &>/dev/null; then
        local PID=$(lsof -t -i ":$1" -sTCP:LISTEN 2>/dev/null | head -1)
        local PROC=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
        warn "$(printf "$MSG_WARN_PORT_1_ALREADY_USE_PID" "${PROC}" "${PID}")"
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
    warn "$MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS"
    warn "$MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER"
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

  # Personal wiki -- the human-readable browse layer over
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
    image: ghcr.io/creativemachines-ai/ostler-wiki-site:0.1.1
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
    image: ghcr.io/creativemachines-ai/ostler-wiki-compiler:0.1.1
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
ok "$MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878"

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

progress "Starting local web search (Vane)" "vane_install"

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
        ok "$MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS"
    else
        warn "$MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST"
        warn "$MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE"
        warn "$(printf "$MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML" "${OSTLER_DIR}")"
    fi
else
    warn "$MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START"
    warn "$MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE"
    warn "$MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE"
    warn "$(printf "$MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP" "${OSTLER_DIR}")"
    warn "$MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS"
fi

# ── 3.9 AI models ─────────────────────────────────────────────────

progress "Downloading AI models (this is the big one)" "ai_models"

if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    ok "$MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE"
else
    info "$MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB"
    if ! ollama_pull_with_retry nomic-embed-text; then
        fail "$MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT"
    fi
    ok "$MSG_OK_EMBEDDING_MODEL_READY"
fi

if [[ "${PULL_MODEL}" != "n" && "${PULL_MODEL}" != "N" ]]; then
    if ollama list 2>/dev/null | grep -q "${AI_MODEL}"; then
        ok "$(printf "$MSG_OK_ALREADY_AVAILABLE" "${AI_MODEL}")"
    else
        # Show the licence summary before the pull so the user knows
        # what they are accepting. Default Ostler models (Qwen family)
        # are Apache 2.0; the Gemma fallback for low-RAM Macs ships
        # under Google's restrictive Gemma Terms of Use.
        case "$AI_MODEL" in
            qwen*)
                info "$(printf "$MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT" "${AI_MODEL}" "${OSTLER_DIR}")"
                ;;
            gemma*)
                warn "$(printf "$MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA" "${AI_MODEL}")"
                warn "$MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA"
                ;;
            *)
                info "$(printf "$MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL" "${AI_MODEL}")"
                ;;
        esac
        info "$(printf "$MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES" "${AI_MODEL}" "${AI_MODEL_SIZE}")"
        if ! ollama_pull_with_retry "$AI_MODEL"; then
            fail "$(printf "$MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS" "${AI_MODEL}")"
        fi
        ok "$(printf "$MSG_OK_READY" "${AI_MODEL}")"
    fi
else
    info "$(printf "$MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA" "${AI_MODEL}")"
fi

# ── 3.10 Import pipeline ──────────────────────────────────────────

progress "Installing the data import pipeline" "import_pipeline"

# The import pipeline is bundled with the installer if available,
# or cloned from PIPELINE_REPO (defined in the config block at the top
# of this script; overridable via PWG_PIPELINE_REPO env var).
HAS_PIPELINE=false

if [[ -d "${SCRIPT_DIR}/contact_syncer" ]]; then
    # Pipeline is bundled with the installer
    mkdir -p "$PIPELINE_DIR"
    cp -R "${SCRIPT_DIR}/contact_syncer" "$PIPELINE_DIR/"
    [[ -f "${SCRIPT_DIR}/requirements.txt" ]] && cp "${SCRIPT_DIR}/requirements.txt" "$PIPELINE_DIR/"
    ok "$MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER"
    HAS_PIPELINE=true
elif [[ -d "$PIPELINE_DIR/contact_syncer" ]]; then
    # Already installed from a previous run
    info "$MSG_INFO_UPDATING_EXISTING_PIPELINE"
    cd "$PIPELINE_DIR" && git pull --quiet 2>/dev/null || warn "$MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE"
    HAS_PIPELINE=true
elif [[ -z "$PIPELINE_REPO" ]]; then
    # Productised install path: contact_syncer/ was not bundled with
    # the installer AND no PWG_PIPELINE_REPO override was set. This is
    # the customer-regression case (the .app build dropped the
    # vendored CM041 tree, or the customer ran install.sh standalone
    # rather than from inside the .app bundle). The previous
    # behaviour here was a silent skip; the productised contract is
    # that GDPR import is part of the install, not a maybe.
    #
    # Hard-fail unless --allow-plaintext is set (the dev-mode
    # escape-hatch which silences all bundle-vendoring guards).
    # See artefacts/2026-04-29/SILENT_FALLBACK_AUDIT_2026-04-29.md F1
    # for the umbrella pattern.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED"
        warn "$MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        echo ""
        warn "$MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER"
        warn "$MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL"
        warn "$MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET"
        fail "$MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER"
    fi
else
    info "$MSG_INFO_CLONING_IMPORT_PIPELINE"
    PIPELINE_CLONE_LOG="$(mktemp -t ostler-pipeline-clone.XXXXXX.log)"
    if git clone --quiet "$PIPELINE_REPO" "$PIPELINE_DIR" 2>"$PIPELINE_CLONE_LOG"; then
        HAS_PIPELINE=true
        rm -f "$PIPELINE_CLONE_LOG"
    else
        warn "$MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO"
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable. Trim noise.
        if [[ -s "$PIPELINE_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$PIPELINE_CLONE_LOG" | head -5
        fi
        info "$MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL"
        info "$MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC"
        info "$(printf "$MSG_INFO_REPO_URL" "${PIPELINE_REPO}")"
        info "$MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE"
        info "$(printf "$MSG_INFO_GIT_CLONE" "${PIPELINE_REPO}" "${PIPELINE_DIR}")"
        info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE"
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
            "$PYTHON3_BIN" -m venv .venv
        fi
        .venv/bin/pip install --quiet -r "$PIPELINE_REQS"
        ln -sf "${CONFIG_DIR}/.env" contact_syncer/.env 2>/dev/null || true
        ok "$MSG_OK_IMPORT_PIPELINE_READY"
    fi
fi

# ── 3.10b CM048 conversation processing pipeline ─────────────────
#
# Installs CM048 as a self-contained Python service under
# ${OSTLER_DIR}/services/cm048/ with its own venv and a pwg-convo CLI
# symlinked into /usr/local/bin/. CM048 turns raw human-to-human
# conversation transcripts into three-tier output: conversation MD,
# per-person relationship signals (Oxigraph), and user-coach
# observations (SQLite). Doctor + Marvin + assistant invoke pwg-convo
# via subprocess; CM048 has NO library coupling to other services on
# disk (productisation Rule 0.5: each service self-contained).
#
# Source-of-truth: vendor/cm048_pipeline/ in this repo (mirror of the
# upstream CM048 - PWG Conversation Processing). The .app post-build
# script in gui/project.yml copies the vendored tree into
# Contents/Resources/cm048_pipeline/, which lands at
# ${SCRIPT_DIR}/cm048_pipeline/ at install time. Dev installs without
# the tarball can set PWG_CM048_REPO to clone the upstream repo.
#
# --allow-plaintext skips the entire setup warn-only (conversation
# enrichment then unavailable; the rest of Ostler still runs). Without
# the flag, a missing pipeline is a hard fail -- the alternative is
# the customer hitting confusing "pwg-convo: command not found"
# errors hours after install when the first conversation arrives.

progress "Setting up conversation processing pipeline (CM048)" "cm048_setup"

CM048_DIR="${OSTLER_DIR}/services/cm048"
CM048_VENV="${CM048_DIR}/.venv"
CM048_BIN="${CM048_VENV}/bin/pwg-convo"
CM048_SYMLINK="/usr/local/bin/pwg-convo"
CM048_SOURCE_OK=false

mkdir -p "$(dirname "$CM048_DIR")"

if [[ -d "${SCRIPT_DIR}/cm048_pipeline" && -f "${SCRIPT_DIR}/cm048_pipeline/pyproject.toml" ]]; then
    # Productised path: vendored package bundled in the .app
    info "$(printf "$MSG_INFO_INSTALLING_CM048_PIPELINE_FROM" "${SCRIPT_DIR}/cm048_pipeline")"
    rm -rf "$CM048_DIR"
    mkdir -p "$CM048_DIR"
    cp -R "${SCRIPT_DIR}/cm048_pipeline/" "$CM048_DIR/"
    CM048_SOURCE_OK=true
elif [[ -n "$CM048_REPO" ]]; then
    # Dev / private-beta path: PWG_CM048_REPO override
    info "$(printf "$MSG_INFO_INSTALLING_CM048_PIPELINE_FROM" "$CM048_REPO")"
    CM048_CLONE_LOG="$(mktemp -t ostler-cm048-clone.XXXXXX.log)"
    if [[ -d "$CM048_DIR/.git" ]]; then
        info "$(printf "$MSG_INFO_EXISTING_CHECKOUT_UPDATING" "$CM048_DIR")"
        if git -C "$CM048_DIR" fetch --quiet origin 2>"$CM048_CLONE_LOG" \
            && git -C "$CM048_DIR" reset --hard --quiet origin/main 2>>"$CM048_CLONE_LOG"; then
            CM048_SOURCE_OK=true
            rm -f "$CM048_CLONE_LOG"
        else
            warn "$MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT"
            if [[ -s "$CM048_CLONE_LOG" ]]; then
                sed -e 's/^/    /' "$CM048_CLONE_LOG" | head -5
            fi
            rm -f "$CM048_CLONE_LOG"
            CM048_SOURCE_OK=true
        fi
    elif git clone --quiet --depth 1 "$CM048_REPO" "$CM048_DIR" 2>"$CM048_CLONE_LOG"; then
        info "$(printf "$MSG_INFO_CLONED" "$CM048_DIR")"
        CM048_SOURCE_OK=true
        rm -f "$CM048_CLONE_LOG"
    else
        warn "$MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE"
        if [[ -s "$CM048_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$CM048_CLONE_LOG" | head -5
        fi
        info "$(printf "$MSG_INFO_GIT_CLONE_2" "${CM048_REPO}" "${CM048_DIR}")"
        info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048"
        rm -f "$CM048_CLONE_LOG"
    fi
elif [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
    # Dev / CI escape hatch: skip the entire setup warn-only.
    warn "$MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT"
    warn "$MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE"
else
    # No bundle, no override, no escape hatch -- hard fail. The
    # alternative is the customer hitting "pwg-convo: command not
    # found" hours later when the first iMessage / email / WhatsApp
    # / meeting transcript tries to route through the pipeline.
    echo ""
    warn "$MSG_WARN_CM048_PIPELINE_NOT_FOUND"
    warn "$(printf "$MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH" "${SCRIPT_DIR}")"
    warn "$MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE"
    warn "$MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2"
    warn "$MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3"
    warn "$MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4"
    fail "$MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN"
fi

if [[ "$CM048_SOURCE_OK" == true && -f "$CM048_DIR/pyproject.toml" ]]; then
    info "$(printf "$MSG_INFO_CREATING_PYTHON_VENV" "$CM048_VENV")"
    "$PYTHON3_BIN" -m venv "$CM048_VENV"

    info "$MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV"
    "$CM048_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    if "$CM048_VENV/bin/pip" install --quiet "$CM048_DIR" 2>/tmp/ostler-cm048-pip.log; then
        info "$MSG_INFO_CM048_PIPELINE_INSTALLED_VENV"
    else
        warn "$MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL"
        if [[ -s /tmp/ostler-cm048-pip.log ]]; then
            sed -e 's/^/    /' /tmp/ostler-cm048-pip.log | tail -5
        fi
    fi

    if [[ -x "$CM048_BIN" ]]; then
        info "$(printf "$MSG_INFO_SYMLINKING" "$CM048_BIN" "$CM048_SYMLINK")"
        sudo ln -sf "$CM048_BIN" "$CM048_SYMLINK"

        # Health check via the symlink. pwg-convo uses argparse without
        # a --version flag (subcommands carry the per-mode arguments),
        # so we exercise --help which argparse adds automatically and
        # exits 0. Confirms PATH-side wiring + venv binding.
        if "$CM048_SYMLINK" --help >/dev/null 2>&1; then
            ok "$MSG_OK_CM048_PIPELINE_READY"
        else
            warn "$MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP"
        fi
    else
        warn "$(printf "$MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML" "$CM048_BIN")"
    fi
elif [[ "$CM048_SOURCE_OK" == true ]]; then
    warn "$MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML"
fi

# ── 3.11 Run GDPR import if exports were provided ────────────────

if [[ -n "$EXPORTS_DIR" && "$HAS_PIPELINE" == true && -d "$PIPELINE_DIR/.venv" ]]; then
    progress "Importing your data (building your knowledge graph)" "import_data"
    info "$MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES"
    cd "$PIPELINE_DIR"
    if .venv/bin/python -m contact_syncer.import_all \
        --exports-dir "$EXPORTS_DIR" \
        --user-name "$USER_NAME" \
        --verbose 2>&1 | while IFS= read -r line; do
            echo "  $line"
        done; then
        ok "$MSG_OK_GDPR_IMPORT_COMPLETE"
    else
        warn "$MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN"
        warn "$(printf "$MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE" "${EXPORTS_DIR}" "${USER_NAME}")"
    fi
elif [[ -n "$EXPORTS_DIR" ]]; then
    info "$MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE"
    info "$(printf "$MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM" "${EXPORTS_DIR}")"
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

# Create an export watcher script -- scans Downloads for new GDPR exports
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
ok "$MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY"

# ── Deferred device-registration retry ─────────────────────────────
#
# The GUI installer POSTs each Mac's hardware fingerprint to
# CM050's appcast.ostler.ai/register-device during the licence
# step so the three-device cap is honoured. When that call fails
# at install time (Wi-Fi blip, Worker briefly down) the GUI
# fails open and queues the request at
# ~/.ostler/state/pending_registration.json. This launchd agent
# retries the POST hourly until the queue clears. See
# CM050/appcast-server/docs/REGISTER_DEVICE.md for the contract.
if [[ -f "${SCRIPT_DIR}/scripts/deferred-register-device.sh" ]]; then
    mkdir -p "${OSTLER_DIR}/bin"
    cp "${SCRIPT_DIR}/scripts/deferred-register-device.sh" \
        "${OSTLER_DIR}/bin/deferred-register-device"
    chmod 755 "${OSTLER_DIR}/bin/deferred-register-device"

    REGISTER_PLIST="${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist"
    cat > "$REGISTER_PLIST" <<DRDPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.deferred-register-device</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/deferred-register-device</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/deferred-register-device.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/deferred-register-device.err</string>
</dict>
</plist>
DRDPEOF
    launchctl bootstrap "gui/$(id -u)" "$REGISTER_PLIST" 2>/dev/null || \
        launchctl load "$REGISTER_PLIST" 2>/dev/null || true
    ok "$MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS"
fi

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
echo "    - Doctor, export watcher, hub power, email-ingest, wiki-recompile,"
echo "      assistant, and RemoteCapture launchd services"
echo "    - /Applications/Ostler RemoteCapture.app"
echo "    - /Applications/Ostler.app"
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
launchctl bootout "gui/$(id -u)/com.ostler.export-scan" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.fda-rerun" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.deferred-register-device" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist" 2>/dev/null || true
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
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.whatsapp-keepalive" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler-remotecapture" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist"

# ── Ostler RemoteCapture .app + container ──────────────────────
# Remove the menubar app from /Applications and the per-user
# Application Support directory. Transcripts written under
# ~/Documents/Ostler/Transcripts/ are user-facing content and are
# handled by the keep-content decision higher up.
if [[ -d "/Applications/Ostler RemoteCapture.app" ]]; then
    echo "  Removing /Applications/Ostler RemoteCapture.app..."
    rm -rf "/Applications/Ostler RemoteCapture.app" 2>/dev/null || \
        sudo rm -rf "/Applications/Ostler RemoteCapture.app" 2>/dev/null || \
        echo "  (warning: could not remove /Applications/Ostler RemoteCapture.app; remove manually)"
fi
rm -rf "${HOME}/Library/Application Support/Ostler RemoteCapture" 2>/dev/null || true

# ── Ostler.app (Tauri Hub desktop) ─────────────────────────────
# Remove the customer-facing Hub desktop bundle from /Applications.
# No Application Support dir to clean: the GUI persists state via
# the gateway, not a per-user data directory.
if [[ -d "/Applications/Ostler.app" ]]; then
    echo "  Removing /Applications/Ostler.app..."
    rm -rf "/Applications/Ostler.app" 2>/dev/null || \
        sudo rm -rf "/Applications/Ostler.app" 2>/dev/null || \
        echo "  (warning: could not remove /Applications/Ostler.app; remove manually)"
fi

echo "  Restoring sleep settings..."
sudo pmset -a sleep 1 2>/dev/null || true

echo "  Removing Keychain entry..."
security delete-generic-password -s "Ostler Recovery Key" 2>/dev/null || true

echo "  Removing /usr/local/bin/ostler-knowledge symlink..."
sudo rm -f /usr/local/bin/ostler-knowledge 2>/dev/null || true

echo "  Removing Ostler directory (hub power + knowledge staging preserved)..."
# Preserve ~/.ostler/power.conf so a reinstall reuses the user's hub power
# policy. Also preserve ~/.ostler/data/knowledge-staging/ so a reinstall does
# not throw away the imported Evernote markdown + image trees (operator data
# that can take 20+ minutes to regenerate). Everything else under ~/.ostler
# goes.
KNOWLEDGE_STAGING_DIR="${HOME}/.ostler/data/knowledge-staging"
KNOWLEDGE_STAGING_BAK=""
if [[ -d "$KNOWLEDGE_STAGING_DIR" ]]; then
    KNOWLEDGE_STAGING_BAK="$(mktemp -d -t ostler-knowledge-staging-XXXXXX)"
    if ! mv "$KNOWLEDGE_STAGING_DIR" "${KNOWLEDGE_STAGING_BAK}/staging" 2>/dev/null; then
        KNOWLEDGE_STAGING_BAK=""
    fi
fi

if [[ -d "${HOME}/.ostler" ]]; then
    find "${HOME}/.ostler" -mindepth 1 -maxdepth 1 ! -name 'power.conf' -exec rm -rf {} + 2>/dev/null || true
    # If power.conf wasn't there, the directory is now empty - drop it too.
    rmdir "${HOME}/.ostler" 2>/dev/null || true
fi

if [[ -n "$KNOWLEDGE_STAGING_BAK" ]] && [[ -d "${KNOWLEDGE_STAGING_BAK}/staging" ]]; then
    mkdir -p "$(dirname "$KNOWLEDGE_STAGING_DIR")"
    mv "${KNOWLEDGE_STAGING_BAK}/staging" "$KNOWLEDGE_STAGING_DIR"
    rmdir "$KNOWLEDGE_STAGING_BAK" 2>/dev/null || true
    echo "  Knowledge staging preserved at ${KNOWLEDGE_STAGING_DIR}."
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

ok "$MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL"

# ── 3.13 Ostler Doctor ──────────────────────────────────────────

progress "Setting up Ostler Doctor diagnostic dashboard" "doctor_setup"

DOCTOR_DIR="${OSTLER_DIR}/doctor"
mkdir -p "$DOCTOR_DIR"

# Source resolution: bundled tarball first, existing re-run second,
# clone fallback third, warn-and-skip last. Same shape as
# hub-power / email-ingest / wiki-recompile.
if [[ -d "${SCRIPT_DIR}/doctor/agent" ]]; then
    cp -R "${SCRIPT_DIR}/doctor/agent/"* "$DOCTOR_DIR/"
    ok "$MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER"
elif [[ -f "${DOCTOR_DIR}/status_collector.py" ]]; then
    info "$(printf "$MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL" "${DOCTOR_DIR}")"
elif [[ -z "$DOCTOR_REPO" ]]; then
    # No tarball-bundled copy, no existing on-disk install, and no
    # PWG_DOCTOR_REPO override. Pre-2026-05-21 this was a soft skip
    # ("Doctor is optional, the rest of Ostler works without it") on
    # the premise that Doctor was a personal-instance convenience.
    # For the v1.0 customer install path that premise no longer
    # holds: Ostler.app's Pairing tab iframes
    # http://127.0.0.1:8089/pair-ios (the ostler-assistant #45
    # rewire), and the iOS pair flow renders an empty page if
    # Doctor is not running. Hard-fail so the customer gets a clear
    # actionable error instead of a half-install that breaks
    # pairing several screens later.
    #
    # --allow-plaintext is the dev/CI escape hatch, matching the
    # ostler_security (PR #115) hard-fail pattern. Operators
    # running a smoke install without the iOS surface can opt out.
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        echo ""
        warn "$MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL"
        warn "$(printf "$MSG_WARN_DOCTOR_LOOKED_FOR_PATH" "${SCRIPT_DIR}")"
        warn "$MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE"
        warn "$MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2"
        warn "$MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3"
        warn "$MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4"
        fail "$MSG_FAIL_DOCTOR_INSTALL_REQUIRED"
    fi
else
    info "$MSG_INFO_CLONING_DOCTOR_AGENT"
    DOCTOR_TMP="$(mktemp -d)"
    DOCTOR_CLONE_LOG="$(mktemp -t ostler-doctor-clone.XXXXXX.log)"
    if git clone --quiet --depth 1 "$DOCTOR_REPO" "$DOCTOR_TMP" 2>"$DOCTOR_CLONE_LOG" \
       && [[ -d "$DOCTOR_TMP/doctor/agent" ]]; then
        cp -R "$DOCTOR_TMP/doctor/agent/"* "$DOCTOR_DIR/"
        rm -rf "$DOCTOR_TMP"
        rm -f "$DOCTOR_CLONE_LOG"
        ok "$(printf "$MSG_OK_DOCTOR_AGENT_CLONED_FROM" "${DOCTOR_REPO}")"
    else
        rm -rf "$DOCTOR_TMP"
        warn "$MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED"
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable.
        if [[ -s "$DOCTOR_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$DOCTOR_CLONE_LOG" | head -5
        fi
        rm -f "$DOCTOR_CLONE_LOG"
        warn "$MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL"
        info "$(printf "$MSG_INFO_REPO_URL_2" "${DOCTOR_REPO}")"
        info "$MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE"
        info "$(printf "$MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC" "${DOCTOR_REPO}")"
        info "$(printf "$MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR" "${DOCTOR_DIR}")"
        info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR"
    fi
fi

if [[ -f "${DOCTOR_DIR}/requirements.txt" ]]; then
    if [[ ! -d "${DOCTOR_DIR}/.venv" ]]; then
        "$PYTHON3_BIN" -m venv "${DOCTOR_DIR}/.venv"
    fi
    "${DOCTOR_DIR}/.venv/bin/pip" install --quiet -r "${DOCTOR_DIR}/requirements.txt"
    ok "$MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED"

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
        <string>support@ostler.ai</string>
    </dict>
</dict>
</plist>
DOCEOF

    # Use bootstrap on Sequoia+ (load is deprecated), fall back to load
    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "$MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089"
fi

# ── 3.13b Knowledge service (CM024 Evernote ingest) ─────────────
#
# Installs the ostler-knowledge CLI under ~/.ostler/services/knowledge/.
# CM024 is a Python click app with a console_scripts entry for
# ostler-knowledge; pip-installing the repo into a dedicated venv
# creates the binary at .venv/bin/ostler-knowledge. We symlink that
# into /usr/local/bin/ostler-knowledge so the customer can invoke it
# directly without activating the venv.
#
# Source resolution (matches the hub-power / doctor / email-ingest
# pattern):
#   1. Bundled vendor copy at ${SCRIPT_DIR}/cm024_knowledge/ (productised
#      install -- the postBuildScript in gui/project.yml lands the
#      vendored upstream source there). Preferred path, no network.
#   2. PWG_KNOWLEDGE_REPO env override -- git clone --depth 1. For dev /
#      private-beta runs against a non-vendored install.sh.
#   3. Neither: warn-only skip. Doctor "Import Evernote" UI (feature-
#      flagged OFF at v1.0; flipped on for v1.1) will surface a "service
#      unavailable" message when the flag is later turned on.
#
# Customer data staging dir at ~/.ostler/data/knowledge-staging/ is
# created at install time AND preserved by the uninstaller (it holds
# imported note markdown + per-note image trees; can take 20+ minutes
# to regenerate on a real-sized Evernote export).
#
# Feature flag note (HR015 brief 3.x launch-scope): the CM024 install
# path always runs; only the Doctor "Import Evernote" UI surface is
# flag-gated. Knowledge is installed regardless of features.evernote_import.

progress "Setting up Knowledge service (CM024)" "knowledge_setup"

KNOWLEDGE_DIR="${OSTLER_DIR}/services/knowledge"
KNOWLEDGE_VENV="${KNOWLEDGE_DIR}/.venv"
KNOWLEDGE_BIN="${KNOWLEDGE_VENV}/bin/ostler-knowledge"
KNOWLEDGE_SYMLINK="/usr/local/bin/ostler-knowledge"
KNOWLEDGE_STAGING_DIR="${OSTLER_DIR}/data/knowledge-staging"

mkdir -p "$(dirname "$KNOWLEDGE_DIR")" "$KNOWLEDGE_STAGING_DIR"

KNOWLEDGE_SOURCE=""

if [[ -d "${SCRIPT_DIR}/cm024_knowledge" && -f "${SCRIPT_DIR}/cm024_knowledge/pyproject.toml" ]]; then
    # Productised install path: vendor/cm024_knowledge/ was copied
    # into Contents/Resources/cm024_knowledge/ by the .app build, or
    # is sitting alongside install.sh in the developer tarball
    # layout. Copy the source into KNOWLEDGE_DIR so pip-install sees
    # a stable on-disk tree (the customer's home directory rather
    # than the .app's read-only Resources).
    info "$MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER"
    # Wipe and re-copy on every install so a re-run does not stack
    # stale source files from an older vendored release.
    rm -rf "$KNOWLEDGE_DIR"
    mkdir -p "$KNOWLEDGE_DIR"
    # Copy contents (the trailing /. preserves the dir contents, not
    # the dir itself). Drop xattrs by not using -p.
    cp -R "${SCRIPT_DIR}/cm024_knowledge/." "$KNOWLEDGE_DIR/"
    KNOWLEDGE_SOURCE="bundled"
elif [[ -n "$KNOWLEDGE_REPO" ]]; then
    info "$(printf "$MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM" "$KNOWLEDGE_REPO")"

    KNOWLEDGE_CLONE_LOG="$(mktemp -t ostler-knowledge-clone.XXXXXX.log)"
    if [[ -d "$KNOWLEDGE_DIR/.git" ]]; then
        info "$(printf "$MSG_INFO_EXISTING_CHECKOUT_UPDATING" "$KNOWLEDGE_DIR")"
        if git -C "$KNOWLEDGE_DIR" fetch --quiet origin 2>"$KNOWLEDGE_CLONE_LOG" \
            && git -C "$KNOWLEDGE_DIR" reset --hard --quiet origin/main 2>>"$KNOWLEDGE_CLONE_LOG"; then
            rm -f "$KNOWLEDGE_CLONE_LOG"
            KNOWLEDGE_SOURCE="cloned"
        else
            warn "$MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT"
            if [[ -s "$KNOWLEDGE_CLONE_LOG" ]]; then
                sed -e 's/^/    /' "$KNOWLEDGE_CLONE_LOG" | head -5
            fi
            rm -f "$KNOWLEDGE_CLONE_LOG"
            KNOWLEDGE_SOURCE="cloned"
        fi
    elif git clone --quiet --depth 1 "$KNOWLEDGE_REPO" "$KNOWLEDGE_DIR" 2>"$KNOWLEDGE_CLONE_LOG"; then
        info "$(printf "$MSG_INFO_CLONED" "$KNOWLEDGE_DIR")"
        rm -f "$KNOWLEDGE_CLONE_LOG"
        KNOWLEDGE_SOURCE="cloned"
    else
        warn "$MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE"
        if [[ -s "$KNOWLEDGE_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$KNOWLEDGE_CLONE_LOG" | head -5
        fi
        info "$(printf "$MSG_INFO_GIT_CLONE_2" "${KNOWLEDGE_REPO}" "${KNOWLEDGE_DIR}")"
        info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE"
        rm -f "$KNOWLEDGE_CLONE_LOG"
    fi
else
    info "$MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE"
    info "$MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2"
    info "$MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE"
    info "$MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED"
fi

if [[ -n "$KNOWLEDGE_SOURCE" && -f "$KNOWLEDGE_DIR/pyproject.toml" ]]; then
    info "$(printf "$MSG_INFO_CREATING_PYTHON_VENV" "$KNOWLEDGE_VENV")"
    "$PYTHON3_BIN" -m venv "$KNOWLEDGE_VENV"

    info "$MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV"
    "$KNOWLEDGE_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    if "$KNOWLEDGE_VENV/bin/pip" install --quiet "$KNOWLEDGE_DIR" 2>/tmp/ostler-knowledge-pip.log; then
        info "$MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV"
    else
        warn "$MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL"
        if [[ -s /tmp/ostler-knowledge-pip.log ]]; then
            sed -e 's/^/    /' /tmp/ostler-knowledge-pip.log | tail -5
        fi
    fi

    if [[ -x "$KNOWLEDGE_BIN" ]]; then
        info "$(printf "$MSG_INFO_SYMLINKING" "$KNOWLEDGE_BIN" "$KNOWLEDGE_SYMLINK")"
        # Under OSTLER_GUI=1 (Option B) /usr/local/bin has already
        # been chowned to the user by the parent .app's
        # AuthorizationHelper, so a plain `ln -sf` writes
        # user-side with no further sudo prompt.
        if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
            ln -sf "$KNOWLEDGE_BIN" "$KNOWLEDGE_SYMLINK" \
                || sudo ln -sf "$KNOWLEDGE_BIN" "$KNOWLEDGE_SYMLINK"
        else
            sudo ln -sf "$KNOWLEDGE_BIN" "$KNOWLEDGE_SYMLINK"
        fi

        # Health check via the symlink (verifies PATH-side wiring + venv binding).
        if VERSION_OUT=$("$KNOWLEDGE_SYMLINK" --version 2>&1) && [[ -n "$VERSION_OUT" ]]; then
            ok "$(printf "$MSG_OK_KNOWLEDGE_SERVICE_READY" "$VERSION_OUT")"
        else
            warn "$MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION"
        fi
    else
        warn "$(printf "$MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML" "$KNOWLEDGE_BIN")"
    fi
elif [[ -n "$KNOWLEDGE_SOURCE" && -d "$KNOWLEDGE_DIR" ]]; then
    warn "$MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML"
    warn "$MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK"
    warn "$MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG"
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

progress "Setting up hub power policy (MacBook-as-Hub)" "hub_power"

HUB_POWER_DIR="${OSTLER_DIR}/hub-power"
HUB_POWER_SNIPPET=""
HUB_POWER_SOURCE=""

# Power-policy gate. The hub-power LaunchAgent exists to throttle
# Docker + Ollama on battery drain. On a desktop Mac (Mac Mini /
# Studio, always-on AC, no battery present) the watcher would see
# tier "ac" every tick and take no action, so installing it is
# pure dead weight. Skip it entirely on AC-only hardware.
#
# HAS_BATTERY is set earlier in Phase 3 (around line 788) from
# `pmset -g batt`. true = MacBook, false = desktop Mac.
if [[ "${HAS_BATTERY:-false}" != "true" ]]; then
    info "$MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT"
elif [[ -d "${SCRIPT_DIR}/hub-power" && -f "${SCRIPT_DIR}/hub-power/INSTALL_SNIPPET.sh" ]]; then
    HUB_POWER_SNIPPET="${SCRIPT_DIR}/hub-power/INSTALL_SNIPPET.sh"
    HUB_POWER_SOURCE="bundled"
    mkdir -p "$HUB_POWER_DIR"
    cp -R "${SCRIPT_DIR}/hub-power/"* "$HUB_POWER_DIR/"
    ok "$MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER"
elif [[ -f "${HUB_POWER_DIR}/INSTALL_SNIPPET.sh" ]]; then
    HUB_POWER_SNIPPET="${HUB_POWER_DIR}/INSTALL_SNIPPET.sh"
    HUB_POWER_SOURCE="existing"
    info "$(printf "$MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL" "${HUB_POWER_DIR}")"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    # MacBook hub, but neither tarball-bundled scripts nor a
    # PWG_HUB_POWER_REPO override is present. This was the old
    # silent-info code path -- on a customer .app install we now
    # expect the post-build script to have landed
    # vendor/hub_power/ at ${SCRIPT_DIR}/hub-power/, so reaching
    # here on a MacBook means the .app bundle is missing the
    # vendored scripts. Surface as a warn (not a hard fail --
    # the rest of the install still works, the customer just
    # won't get battery-aware throttling).
    warn "$MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE"
    warn "$MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2"
    warn "$MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3"
else
    info "$MSG_INFO_CLONING_HUB_POWER_SCRIPTS"
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
        ok "$(printf "$MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM" "${HUB_POWER_REPO}")"
    else
        rm -rf "$HUB_POWER_TMP"
        warn "$MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS"
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable.
        if [[ -s "$HUB_POWER_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$HUB_POWER_CLONE_LOG" | head -5
        fi
        rm -f "$HUB_POWER_CLONE_LOG"
        warn "$MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS"
        warn "$MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP"
        info "$(printf "$MSG_INFO_REPO_URL_3" "${HUB_POWER_REPO}")"
        info "$MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE"
        info "$(printf "$MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC" "${HUB_POWER_REPO}")"
        info "$(printf "$MSG_INFO_MKDIR_P_CP_R_TMP_HUB" "${HUB_POWER_DIR}" "${HUB_POWER_DIR}")"
        info "$(printf "$MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET" "${HUB_POWER_DIR}" "${HUB_POWER_DIR}")"
        info "$MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB"
    fi
fi

if [[ -n "$HUB_POWER_SNIPPET" && -f "$HUB_POWER_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$HUB_POWER_DIR" bash "$HUB_POWER_SNIPPET"; then
        ok "$MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM"
        info "$MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF"
    else
        warn "$MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE"
        warn "$MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK"
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

progress "Setting up email-ingest LaunchAgent (hourly Apple Mail drain)" "email_ingest"

EMAIL_INGEST_DIR="${OSTLER_DIR}/email-ingest"
EMAIL_INGEST_SNIPPET=""
EMAIL_INGEST_SOURCE=""

if [[ -d "${SCRIPT_DIR}/email-ingest" && -f "${SCRIPT_DIR}/email-ingest/INSTALL_SNIPPET.sh" ]]; then
    EMAIL_INGEST_SNIPPET="${SCRIPT_DIR}/email-ingest/INSTALL_SNIPPET.sh"
    EMAIL_INGEST_SOURCE="bundled"
    mkdir -p "$EMAIL_INGEST_DIR"
    cp -R "${SCRIPT_DIR}/email-ingest/"* "$EMAIL_INGEST_DIR/"
    ok "$MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER"
elif [[ -f "${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh" ]]; then
    EMAIL_INGEST_SNIPPET="${EMAIL_INGEST_DIR}/INSTALL_SNIPPET.sh"
    EMAIL_INGEST_SOURCE="existing"
    info "$(printf "$MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL" "${EMAIL_INGEST_DIR}")"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    # No bundled vendor copy AND no override repo. For productised
    # customer installs this is the regression case (.app shipped
    # without the email-ingest vendor). Hard-fail unless the dev/CI
    # plaintext escape hatch is set, matching the vendor-PR pattern
    # established by ostler_security (PR #115), FDA (#116), Doctor
    # (#117), hub-power (#118), CM024 (#119), CM048 (#120), CM041
    # (#121).
    if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
        warn "$MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT"
        warn "$MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED"
    else
        fail "$MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN"
    fi
else
    info "$MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS"
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
        ok "$(printf "$MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM" "${HUB_POWER_REPO}")"
    else
        rm -rf "$EMAIL_INGEST_TMP"
        warn "$MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS"
        # Surface the underlying git error so credential / network /
        # repo-not-found failures are distinguishable.
        if [[ -s "$EMAIL_INGEST_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$EMAIL_INGEST_CLONE_LOG" | head -5
        fi
        rm -f "$EMAIL_INGEST_CLONE_LOG"
        warn "$MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL"
        info "$(printf "$MSG_INFO_REPO_URL_3" "${HUB_POWER_REPO}")"
        info "$MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE"
        info "$(printf "$MSG_INFO_GIT_CLONE_TMP_HUB_SRC" "${HUB_POWER_REPO}")"
        info "$(printf "$MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2" "${EMAIL_INGEST_DIR}" "${EMAIL_INGEST_DIR}")"
        info "$(printf "$MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS" "${EMAIL_INGEST_DIR}" "${OSTLER_DIR}" "${LOGS_DIR}")"
        info "$(printf "$MSG_INFO_BASH_INSTALL_SNIPPET_SH" "${EMAIL_INGEST_DIR}")"
    fi
fi

if [[ -n "$EMAIL_INGEST_SNIPPET" && -f "$EMAIL_INGEST_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$EMAIL_INGEST_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       bash "$EMAIL_INGEST_SNIPPET"; then
        ok "$MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM"
        info "$MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST"
        info "$(printf "$MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST" "${OSTLER_DIR}")"
        info "$(printf "$MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR" "${LOGS_DIR}")"
    else
        warn "$MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE"
        warn "$MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY"
        warn "$MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL"
        warn "$MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL"
    fi
fi

# ── 3.14a-probe Mail content probe + sidecar (#259) ─────────────
#
# Writes the install-time half of ~/.ostler/state/pipeline_signals.json
# so the Doctor agent can decide whether to surface the "no local
# Mail content yet" banner.
#
# The Doctor empty-Mail banner (HR015 #109) fires only when ALL of:
#   - mail_has_fetched is false
#   - install_completed_ts is set
#   - more than 24 hours have elapsed since install_completed_ts
#
# The fourth key, first_ingest_complete_ts, is written by the
# email-ingest tick on the first non-empty ingest (#260 follow-up).
# We preserve it across reinstalls so the tick does not need to
# re-detect first ingest.
#
# Apple Mail data lives under ~/Library/Mail/V<N>/ which is FDA-
# protected. If FDA has not been granted yet, the find calls below
# silently return empty and the sidecar records mail_has_fetched=false;
# Doctor's broader FDA diagnostic surfaces the underlying cause.

MAIL_ACCOUNTS_FOUND=0
MAIL_HAS_FETCHED="false"
APPLE_MAIL_VERSION_DIR=""

# Mail.app stores per-version data under ~/Library/Mail/V<N>/.
# Pick the highest version number (most recent macOS / Mail.app).
if [[ -d "${HOME}/Library/Mail" ]]; then
    APPLE_MAIL_VERSION_DIR=$(find "${HOME}/Library/Mail" -maxdepth 1 -type d -name 'V[0-9]*' 2>/dev/null | sort -V | tail -1)
fi

if [[ -n "$APPLE_MAIL_VERSION_DIR" && -d "$APPLE_MAIL_VERSION_DIR" ]]; then
    # Account count is informational only. We accept rough over-counting
    # (CalDAV calendars sometimes appear under MailAccounts, drafts-only
    # accounts) per the 2026-05-17 findings; the load-bearing signal for
    # the banner is mail_has_fetched, not the count.
    ACCOUNTS_PLIST="${APPLE_MAIL_VERSION_DIR}/MailData/Accounts.plist"
    if [[ -f "$ACCOUNTS_PLIST" ]]; then
        # <key>AccountName</key> appears once per account dict. Tolerant
        # of false positives by design.
        MAIL_ACCOUNTS_FOUND=$(grep -c '<key>AccountName</key>' "$ACCOUNTS_PLIST" 2>/dev/null || echo 0)
    fi

    # "Has Mail.app ever pulled a message?" -- any non-empty
    # InboxCache.plist under the version dir is sufficient.
    if find "$APPLE_MAIL_VERSION_DIR" -name 'InboxCache.plist' -size +0c -print 2>/dev/null | head -1 | grep -q .; then
        MAIL_HAS_FETCHED="true"
    fi
fi

# Sidecar -- atomic write, 0600 perms. Preserves first_ingest_complete_ts
# if a prior tick has populated it (reinstall case). The JSON-merge
# logic lives in lib/write_pipeline_signals.py so it can be unit-tested.
PIPELINE_SIGNALS_DIR="${OSTLER_DIR}/state"
PIPELINE_SIGNALS_FILE="${PIPELINE_SIGNALS_DIR}/pipeline_signals.json"
mkdir -p "$PIPELINE_SIGNALS_DIR"

# Resolve the writer script with the same fallback chain as
# progress_emitter.sh above (bundled / dev / post-install re-run).
_pipeline_writer=""
if [[ -n "${OSTLER_PIPELINE_SIGNALS_WRITER:-}" && -f "${OSTLER_PIPELINE_SIGNALS_WRITER}" ]]; then
    _pipeline_writer="${OSTLER_PIPELINE_SIGNALS_WRITER}"
elif [[ -f "${SCRIPT_DIR}/lib/write_pipeline_signals.py" ]]; then
    _pipeline_writer="${SCRIPT_DIR}/lib/write_pipeline_signals.py"
elif [[ -f "${HOME}/.ostler/lib/write_pipeline_signals.py" ]]; then
    _pipeline_writer="${HOME}/.ostler/lib/write_pipeline_signals.py"
fi

if [[ -n "$_pipeline_writer" ]] && python3 "$_pipeline_writer" \
        --output "$PIPELINE_SIGNALS_FILE" \
        --accounts "$MAIL_ACCOUNTS_FOUND" \
        --has-fetched "$MAIL_HAS_FETCHED"; then
    info "$(printf "$MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL" "${MAIL_ACCOUNTS_FOUND}")"
    if [[ "$MAIL_HAS_FETCHED" == "true" ]]; then
        info "$MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST"
    else
        info "$MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD"
    fi
    gui_emit MAIL_ACCOUNTS_FOUND "count=${MAIL_ACCOUNTS_FOUND}" "has_fetched=${MAIL_HAS_FETCHED}"
else
    warn "$MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON"
fi

unset MAIL_ACCOUNTS_FOUND MAIL_HAS_FETCHED APPLE_MAIL_VERSION_DIR ACCOUNTS_PLIST
unset PIPELINE_SIGNALS_DIR PIPELINE_SIGNALS_FILE _pipeline_writer

# ── 3.14d Wiki recompile LaunchAgent (daily wiki rebuild) ───────
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

progress "Setting up wiki-recompile LaunchAgent (daily rebuild)" "wiki_recompile_agent"

WIKI_RECOMPILE_DIR="${OSTLER_DIR}/wiki-recompile"
WIKI_RECOMPILE_SNIPPET=""
WIKI_RECOMPILE_SOURCE=""

if [[ -d "${SCRIPT_DIR}/wiki-recompile" && -f "${SCRIPT_DIR}/wiki-recompile/INSTALL_SNIPPET.sh" ]]; then
    WIKI_RECOMPILE_SNIPPET="${SCRIPT_DIR}/wiki-recompile/INSTALL_SNIPPET.sh"
    WIKI_RECOMPILE_SOURCE="bundled"
    mkdir -p "$WIKI_RECOMPILE_DIR"
    cp -R "${SCRIPT_DIR}/wiki-recompile/"* "$WIKI_RECOMPILE_DIR/"
    ok "$MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER"
elif [[ -f "${WIKI_RECOMPILE_DIR}/INSTALL_SNIPPET.sh" ]]; then
    WIKI_RECOMPILE_SNIPPET="${WIKI_RECOMPILE_DIR}/INSTALL_SNIPPET.sh"
    WIKI_RECOMPILE_SOURCE="existing"
    info "$(printf "$MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL" "${WIKI_RECOMPILE_DIR}")"
elif [[ -z "$HUB_POWER_REPO" ]]; then
    info "$MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH"
    info "$MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015"
else
    info "$MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS"
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
        ok "$(printf "$MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM" "${HUB_POWER_REPO}")"
    else
        rm -rf "$WIKI_RECOMPILE_TMP"
        warn "$MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS"
        if [[ -s "$WIKI_RECOMPILE_CLONE_LOG" ]]; then
            warn "$MSG_WARN_GIT_SAID"
            sed -e 's/^/    /' "$WIKI_RECOMPILE_CLONE_LOG" | head -5
        fi
        rm -f "$WIKI_RECOMPILE_CLONE_LOG"
        warn "$MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL"
        info "$MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU"
        info "$(printf "$MSG_INFO_CD" "${OSTLER_DIR}")"
        info "$MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM"
    fi
fi

if [[ -n "$WIKI_RECOMPILE_SNIPPET" && -f "$WIKI_RECOMPILE_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$WIKI_RECOMPILE_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       bash "$WIKI_RECOMPILE_SNIPPET"; then
        ok "$MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM"
        info "$(printf "$MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN" "${OSTLER_DIR}")"
        info "$(printf "$MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR" "${LOGS_DIR}")"
    else
        warn "$MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE"
        warn "$MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL"
        warn "$(printf "$MSG_WARN_CD" "${OSTLER_DIR}")"
        warn "$MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM"
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
#   5. Clear the macOS quarantine xattr so the bundled binary
#      runs immediately. Gatekeeper still verifies the
#      notarisation ticket online on first execution; xattr
#      removal just skips the double-click confirmation dialog
#      that curl-installed binaries otherwise trigger.
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
# Defaults track ostler-ai/ostler-assistant v0.3.0.
#
# Open question: there is no zeroclaw subcommand for "encrypt the
# plaintext password the wizard just wrote" -- the secrets store
# auto-migrates legacy enc: values to enc2: on read but does not
# bootstrap from plaintext. The TOML stays mode 0600 in the
# meantime. A `config encrypt-secrets` subcommand would close the
# window; flagged as a follow-up Rust PR (or roll into Phase E).

progress "Setting up ostler-assistant binary (v${OSTLER_ASSISTANT_VERSION:-0.4.1})" "ostler_assistant"

OSTLER_ASSISTANT_VERSION="${OSTLER_ASSISTANT_VERSION:-0.4.1}"
# Customer-facing distribution. Binary first published to
# ostler-ai/ostler-installer 2026-05-03 after the org-level new-account hold
# was lifted by GitHub support (ticket #4347825).
OSTLER_ASSISTANT_REPO="${OSTLER_ASSISTANT_REPO:-ostler-ai/ostler-installer}"
OSTLER_ASSISTANT_TARGET="${OSTLER_ASSISTANT_TARGET:-aarch64-apple-darwin}"
OSTLER_ASSISTANT_DIR="${OSTLER_DIR}/assistant-agent"
ASSISTANT_BINARY="${OSTLER_DIR}/bin/ostler-assistant"

# Apple Silicon only. The Phase B release workflow does
# not produce an x86_64 build (customer Macs are arm64 by the
# brief). Surface this clearly rather than letting curl 404 on
# a non-existent Intel asset.
ARCH_DETECTED="$(uname -m 2>/dev/null || echo unknown)"
if [[ "$ARCH_DETECTED" != "arm64" && "$ARCH_DETECTED" != "aarch64" ]]; then
    warn "$(printf "$MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY" "${OSTLER_ASSISTANT_VERSION}" "${ARCH_DETECTED}")"
    warn "$MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG"
    info "$MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST"
    ASSISTANT_BINARY_INSTALLED=false
else

ASSISTANT_ARCHIVE_NAME="ostler-assistant-${OSTLER_ASSISTANT_TARGET}-v${OSTLER_ASSISTANT_VERSION}.tar.gz"
ASSISTANT_ARCHIVE_URL="https://github.com/${OSTLER_ASSISTANT_REPO}/releases/download/v${OSTLER_ASSISTANT_VERSION}/${ASSISTANT_ARCHIVE_NAME}"
ASSISTANT_CHECKSUM_URL="${ASSISTANT_ARCHIVE_URL}.sha256"

# ASSISTANT_TMPDIR is declared in the Phase 3 composite_cleanup
# block; this allocator sets it. composite_cleanup will rm -rf
# the dir if we exit before the explicit cleanups below fire.
ASSISTANT_TMPDIR="$(mktemp -d)"

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
        err "$MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH"
        err "$(printf "$MSG_ERR_EXPECTED" "${EXPECTED_SHA:-<empty sidecar>}")"
        err "$(printf "$MSG_ERR_ACTUAL" "${ACTUAL_SHA}")"
        err "$(printf "$MSG_ERR_URL" "${ASSISTANT_ARCHIVE_URL}")"
        err "$MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT"
        rm -rf "$ASSISTANT_TMPDIR"
        ASSISTANT_TMPDIR=""
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
                ok "$(printf "$MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_BINARY}")"
                info "$MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST"
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
                ok "$(printf "$MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_BINARY}")"
                info "$MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID"
                info "$MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP"
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
                err "$(printf "$MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O" "${ASSISTANT_BINARY}")"
                err "$(printf "$MSG_ERR_FILE_BRIEF_REPORTED" "${binary_file_type}")"
                err "$MSG_ERR_CODESIGN_DV_REPORTED"
                err "$(printf '%s\n' "$codesign_dv_output" | sed -e 's/^/    /' | head -5)"
                err "$MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT"
                err "$MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL"
                # ASSISTANT_BINARY_INSTALLED stays false (its
                # initial value), so the LaunchAgent step
                # downstream is skipped without further action.
                ;;
        esac

        if [[ "$ASSISTANT_BINARY_SIGN_STATE" != "corrupt" ]]; then
            if "$ASSISTANT_BINARY" --version >/dev/null 2>&1; then
                ASSISTANT_BINARY_INSTALLED=true
            else
                warn "$MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK"
                warn "$(printf "$MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION" "${ASSISTANT_BINARY}")"
            fi
        fi
    else
        warn "$MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL"
    fi
else
    warn "$(printf "$MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_ARCHIVE_URL}")"
    if [[ -s "$ASSISTANT_TMPDIR/curl.log" ]]; then
        warn "$MSG_WARN_CURL_SAID"
        sed -e 's/^/    /' "$ASSISTANT_TMPDIR/curl.log" | head -5
    fi
    warn "$(printf "$MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET" "${OSTLER_ASSISTANT_VERSION}")"
    warn "$MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S"
    warn "$MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY"
    info "$(printf "$MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ" "${ASSISTANT_ARCHIVE_URL}")"
    info "$(printf "$MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C" "${OSTLER_DIR}")"
    info "$(printf "$MSG_INFO_BASH_INSTALL_SNIPPET_SH_2" "${OSTLER_ASSISTANT_DIR}")"
fi

rm -rf "$ASSISTANT_TMPDIR"
ASSISTANT_TMPDIR=""

# Stage the assistant-agent INSTALL_SNIPPET assets even when the
# binary download failed. The snippet refuses to run without the
# binary, but a later manual stage just needs to source it.
if [[ -d "${SCRIPT_DIR}/assistant-agent" && -f "${SCRIPT_DIR}/assistant-agent/INSTALL_SNIPPET.sh" ]]; then
    mkdir -p "$OSTLER_ASSISTANT_DIR"
    cp -R "${SCRIPT_DIR}/assistant-agent/"* "$OSTLER_ASSISTANT_DIR/"
fi

if [[ "$ASSISTANT_BINARY_INSTALLED" == true && -f "${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh" ]]; then
    # Gate the WhatsApp keepalive LaunchAgent on the customer
    # actually enabling the WhatsApp channel. Without the channel,
    # the keepalive would just exit cleanly every fire (no
    # configured WhatsApp arm to health-check), wasting CPU and
    # log lines.
    if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
        ASSISTANT_INSTALL_KEEPALIVE="true"
    else
        ASSISTANT_INSTALL_KEEPALIVE="false"
    fi
    if OSTLER_INSTALL_ROOT="$OSTLER_ASSISTANT_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       ASSISTANT_CONFIG_DIR="$ASSISTANT_CONFIG_DIR" \
       INSTALL_WHATSAPP_KEEPALIVE="$ASSISTANT_INSTALL_KEEPALIVE" \
       bash "${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh"; then
        ok "$MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM"
        info "$(printf "$MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR" "${LOGS_DIR}")"
        info "$MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI"
        if [[ "$ASSISTANT_INSTALL_KEEPALIVE" == "true" ]]; then
            info "$MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17"
        fi
    else
        warn "$MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE"
        warn "$MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS"
        warn "$(printf "$MSG_WARN_BASH_INSTALL_SNIPPET_SH" "${OSTLER_ASSISTANT_DIR}")"
    fi
fi

fi  # end Apple Silicon guard

# ── 3.14f Ostler RemoteCapture .app bundle + LaunchAgent ─────────
#
# Stages the customer-facing Ostler RemoteCapture menubar app
# (CM042 source, packaged by ostler-ai/ostler-remote-capture's
# Phase C release workflow) into /Applications and registers a
# user-level LaunchAgent so it starts on login and stays alive
# across crashes.
#
# RemoteCapture is the call / meeting transcription companion: a
# MenuBarExtra (LSUIElement) that records system audio + microphone
# via ScreenCaptureKit + CATap, transcribes locally with WhisperKit,
# and lands transcripts under ~/Documents/Ostler/Transcripts/. The
# Info.plist sets LSUIElement, so the app shows in the menu bar
# only, no Dock icon.
#
# Pieces:
#   1. Pre-prompt the customer that macOS will request Screen
#      Recording + Microphone permission on first launch (TCC).
#      Post-CATap migration there is no purple recording indicator,
#      so the customer needs to know what is about to happen.
#   2. Resolve the release URL and SHA-256 sidecar URL.
#   3. Download both into a temp dir.
#   4. Verify SHA-256 (abort the phase on mismatch -- silent
#      acceptance of a bad download would put a tampered .app onto
#      the customer's daily-driver Mac).
#   5. Extract the tarball into /Applications. The release tarball
#      contains a single `Ostler RemoteCapture.app/` directory at
#      the root (see ostler-ai/ostler-remote-capture
#      .github/workflows/release.yml).
#   6. codesign --verify --deep --strict + spctl --assess --type
#      execute the .app. Both must pass. If either fails, hard fail
#      the phase: an unverified app bundle bypassing Gatekeeper is
#      not something we silently install on a customer machine.
#   7. Clear com.apple.quarantine on the .app so launchctl can spawn
#      it on login without a Gatekeeper double-click confirmation.
#      Gated on the verify step passing, per Phase C lines 5404+.
#   8. Render + bootstrap the LaunchAgent at
#      ~/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist.
#
# Productisation: OSTLER_REMOTECAPTURE_VERSION + OSTLER_REMOTECAPTURE_REPO
# are env-overridable so a beta cut or fork can point at a different
# release without editing install.sh. Default tracks
# ostler-ai/ostler-remote-capture v1.0.0 (placeholder; Andy bumps
# this when the first real release tag is cut).
#
# Failure mode: if any of download / verify / extract / sign-verify
# fails, warn-and-skip the LaunchAgent install. The customer gets a
# working Ostler install minus the RemoteCapture app; they can
# re-run the installer once the upstream release is fixed.

progress "Setting up Ostler RemoteCapture (call + meeting transcripts)" "ostler_remotecapture"

OSTLER_REMOTECAPTURE_VERSION="${OSTLER_REMOTECAPTURE_VERSION:-0.1.0}"
OSTLER_REMOTECAPTURE_REPO="${OSTLER_REMOTECAPTURE_REPO:-ostler-ai/ostler-releases}"
REMOTECAPTURE_APP_PATH="/Applications/Ostler RemoteCapture.app"
REMOTECAPTURE_LAUNCHAGENT_LABEL="com.creativemachines.ostler-remotecapture"
REMOTECAPTURE_LAUNCHAGENT_PLIST="${HOME}/Library/LaunchAgents/${REMOTECAPTURE_LAUNCHAGENT_LABEL}.plist"
REMOTECAPTURE_BINARY_INSIDE_APP="${REMOTECAPTURE_APP_PATH}/Contents/MacOS/RemoteCapture"
REMOTECAPTURE_APP_SUPPORT_DIR="${HOME}/Library/Application Support/Ostler RemoteCapture"

# Apple Silicon only. The Phase C release workflow only builds an
# arm64 slice (WhisperKit + ScreenCaptureKit perform best on Apple
# Silicon; customer Macs are arm64 by the brief). Surface the
# detection clearly rather than letting curl 404 on a non-existent
# Intel asset.
REMOTECAPTURE_ARCH_DETECTED="$(uname -m 2>/dev/null || echo unknown)"
if [[ "$REMOTECAPTURE_ARCH_DETECTED" != "arm64" && "$REMOTECAPTURE_ARCH_DETECTED" != "aarch64" ]]; then
    warn "$(printf "$MSG_WARN_CM042_APPLE_SILICON_ONLY" "${OSTLER_REMOTECAPTURE_VERSION}" "${REMOTECAPTURE_ARCH_DETECTED}")"
    info "$MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING"
    REMOTECAPTURE_INSTALLED=false
else

# Customer-facing TCC pre-prompt. RemoteCapture requests Screen
# Recording + Microphone on first launch via ScreenCaptureKit +
# AVCaptureDevice. Post-CATap migration there is no purple
# recording indicator in the menu bar while audio is captured, so
# the customer needs to know what to expect before they click
# Allow on the system prompts. Rule 0.9: all customer-rendered
# strings are catalogued in install.sh.strings.en-GB.sh.
info "$MSG_INFO_CM042_TCC_PRE_PROMPT"
echo ""
info "$(printf "$MSG_INFO_INSTALLING_CM042" "${OSTLER_REMOTECAPTURE_VERSION}")"

REMOTECAPTURE_ARCHIVE_NAME="RemoteCapture-${OSTLER_REMOTECAPTURE_VERSION}-arm64.tar.gz"
REMOTECAPTURE_ARCHIVE_URL="https://github.com/${OSTLER_REMOTECAPTURE_REPO}/releases/download/remote-capture-v${OSTLER_REMOTECAPTURE_VERSION}/${REMOTECAPTURE_ARCHIVE_NAME}"
REMOTECAPTURE_CHECKSUM_URL="${REMOTECAPTURE_ARCHIVE_URL}.sha256"

REMOTECAPTURE_TMPDIR="$(mktemp -d)"
REMOTECAPTURE_INSTALLED=false

if curl -fSL --retry 2 --retry-delay 2 -o "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}" "$REMOTECAPTURE_ARCHIVE_URL" 2>"${REMOTECAPTURE_TMPDIR}/curl.log" \
   && curl -fSL --retry 2 --retry-delay 2 -o "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}.sha256" "$REMOTECAPTURE_CHECKSUM_URL" 2>>"${REMOTECAPTURE_TMPDIR}/curl.log"; then

    # Verify SHA-256. Phase C writes the sidecar as
    # `<hex>  <filename>` (shasum default). Recompute against the
    # local download and compare hex prefixes. A mismatch is a
    # hard fail for the phase: we will not stage a tampered or
    # partial .app onto /Applications.
    REMOTECAPTURE_EXPECTED_SHA="$(awk '{print $1}' "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}.sha256")"
    REMOTECAPTURE_ACTUAL_SHA="$(shasum -a 256 "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}" | awk '{print $1}')"
    if [[ -z "$REMOTECAPTURE_EXPECTED_SHA" || "$REMOTECAPTURE_EXPECTED_SHA" != "$REMOTECAPTURE_ACTUAL_SHA" ]]; then
        err "$MSG_ERR_CM042_SHA_256_MISMATCH"
        err "$(printf "$MSG_ERR_EXPECTED" "${REMOTECAPTURE_EXPECTED_SHA:-<empty sidecar>}")"
        err "$(printf "$MSG_ERR_ACTUAL" "${REMOTECAPTURE_ACTUAL_SHA}")"
        err "$(printf "$MSG_ERR_URL" "${REMOTECAPTURE_ARCHIVE_URL}")"
        err "$MSG_ERR_CM042_REFUSING_STAGE_BUNDLE"
        rm -rf "$REMOTECAPTURE_TMPDIR"
        REMOTECAPTURE_TMPDIR=""
        fail "$MSG_FAIL_CM042_SIGNATURE_FAILED"
    fi

    # Extract into /Applications. The tarball contains
    # `Ostler RemoteCapture.app/` at the root of the archive. Use
    # sudo only if /Applications is not writable by the current
    # user (the GUI installer typically runs as the user, who has
    # write access to /Applications on a stock macOS install; we
    # fall back to sudo for the rare corporate-imaged box where
    # /Applications is admin-owned).
    if [[ -d "$REMOTECAPTURE_APP_PATH" ]]; then
        # Pre-existing install (re-run, or a beta cut). Remove
        # before extract so a tarball with a shorter file list does
        # not leave stale Resources behind.
        rm -rf "$REMOTECAPTURE_APP_PATH" 2>/dev/null || sudo rm -rf "$REMOTECAPTURE_APP_PATH" 2>/dev/null || true
    fi

    if tar xzf "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}" -C /Applications 2>"${REMOTECAPTURE_TMPDIR}/tar.log" \
       || sudo tar xzf "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}" -C /Applications 2>>"${REMOTECAPTURE_TMPDIR}/tar.log"; then

        if [[ ! -d "$REMOTECAPTURE_APP_PATH" ]]; then
            err "$(printf "$MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT" "${REMOTECAPTURE_APP_PATH}")"
            if [[ -s "${REMOTECAPTURE_TMPDIR}/tar.log" ]]; then
                sed -e 's/^/    /' "${REMOTECAPTURE_TMPDIR}/tar.log" | head -5
            fi
            rm -rf "$REMOTECAPTURE_TMPDIR"
            REMOTECAPTURE_TMPDIR=""
            fail "$MSG_FAIL_CM042_SIGNATURE_FAILED"
        fi

        # Signature + notarisation verification. Both must pass
        # before we clear quarantine or load the LaunchAgent.
        # codesign --verify --deep --strict checks every nested
        # bundle / framework / resource against the embedded
        # signature. spctl --assess --type execute checks the
        # Gatekeeper policy (Developer ID + notarisation ticket).
        # A bundle that fails either is not something we will
        # silently stage onto the customer's daily driver Mac.
        REMOTECAPTURE_CODESIGN_LOG="${REMOTECAPTURE_TMPDIR}/codesign.log"
        REMOTECAPTURE_SPCTL_LOG="${REMOTECAPTURE_TMPDIR}/spctl.log"
        if codesign --verify --deep --strict "$REMOTECAPTURE_APP_PATH" 2>"$REMOTECAPTURE_CODESIGN_LOG" \
           && spctl --assess --type execute "$REMOTECAPTURE_APP_PATH" 2>"$REMOTECAPTURE_SPCTL_LOG"; then

            # Both checks passed. Clear quarantine so launchctl
            # can spawn the .app on login without the Gatekeeper
            # confirmation dialog that curl-installed bundles
            # otherwise trigger. Mirror Phase C's gating: only
            # strip xattr when the verify chain passed.
            xattr -dr com.apple.quarantine "$REMOTECAPTURE_APP_PATH" 2>/dev/null || true
            ok "$(printf "$MSG_OK_CM042_INSTALLED" "${OSTLER_REMOTECAPTURE_VERSION}" "${REMOTECAPTURE_APP_PATH}")"
            REMOTECAPTURE_INSTALLED=true
        else
            err "$MSG_ERR_CM042_VERIFY_FAILED"
            if [[ -s "$REMOTECAPTURE_CODESIGN_LOG" ]]; then
                err "$MSG_ERR_CM042_CODESIGN_OUTPUT"
                sed -e 's/^/    /' "$REMOTECAPTURE_CODESIGN_LOG" | head -5
            fi
            if [[ -s "$REMOTECAPTURE_SPCTL_LOG" ]]; then
                err "$MSG_ERR_CM042_SPCTL_OUTPUT"
                sed -e 's/^/    /' "$REMOTECAPTURE_SPCTL_LOG" | head -5
            fi
            # Leave the .app in place so the customer / support
            # can inspect, but do not strip quarantine and do not
            # load the LaunchAgent.
            rm -rf "$REMOTECAPTURE_TMPDIR"
            REMOTECAPTURE_TMPDIR=""
            fail "$MSG_FAIL_CM042_SIGNATURE_FAILED"
        fi
    else
        warn "$MSG_WARN_CM042_EXTRACT_FAILED"
        if [[ -s "${REMOTECAPTURE_TMPDIR}/tar.log" ]]; then
            sed -e 's/^/    /' "${REMOTECAPTURE_TMPDIR}/tar.log" | head -5
        fi
    fi
else
    warn "$(printf "$MSG_WARN_CM042_DOWNLOAD_FAILED" "${OSTLER_REMOTECAPTURE_VERSION}" "${REMOTECAPTURE_ARCHIVE_URL}")"
    if [[ -s "${REMOTECAPTURE_TMPDIR}/curl.log" ]]; then
        warn "$MSG_WARN_CURL_SAID"
        sed -e 's/^/    /' "${REMOTECAPTURE_TMPDIR}/curl.log" | head -5
    fi
    warn "$MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS"
fi

rm -rf "$REMOTECAPTURE_TMPDIR"
REMOTECAPTURE_TMPDIR=""

# LaunchAgent: auto-start on login, KeepAlive across crashes. The
# .app is a MenuBarExtra (LSUIElement) so the customer sees the
# menu-bar icon appear on login. ProcessType=Interactive + Aqua
# session is implicit for a user LaunchAgent under gui/<uid>.
if [[ "$REMOTECAPTURE_INSTALLED" == true ]]; then
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$REMOTECAPTURE_LAUNCHAGENT_PLIST" <<RCAPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${REMOTECAPTURE_LAUNCHAGENT_LABEL}</string>
    <key>Program</key>
    <string>${REMOTECAPTURE_BINARY_INSIDE_APP}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/ostler-remotecapture.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/ostler-remotecapture.err</string>
</dict>
</plist>
RCAPEOF
    chmod 0644 "$REMOTECAPTURE_LAUNCHAGENT_PLIST"

    # bootout-then-bootstrap so re-runs of the installer reload
    # the plist cleanly. bootout of a non-loaded label is a no-op.
    launchctl bootout "gui/$(id -u)/${REMOTECAPTURE_LAUNCHAGENT_LABEL}" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$REMOTECAPTURE_LAUNCHAGENT_PLIST" 2>/dev/null \
       || launchctl load "$REMOTECAPTURE_LAUNCHAGENT_PLIST" 2>/dev/null; then
        ok "$(printf "$MSG_OK_CM042_LAUNCHAGENT_LOADED" "${REMOTECAPTURE_LAUNCHAGENT_LABEL}")"
        info "$(printf "$MSG_INFO_CM042_LOGS_AT" "${LOGS_DIR}")"
    else
        warn "$MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED"
    fi
fi

fi  # end RemoteCapture Apple Silicon guard

# ── 3.14g Ostler.app (Tauri Hub desktop) ────────────────────────
#
# Stages the customer-facing Ostler.app menu-bar / window companion
# (ostler-ai/ostler-assistant apps/tauri build, packaged by the
# Tauri bundler) into /Applications. Unlike RemoteCapture, this is
# not a daemon: it is the GUI surface the customer opens to chat
# with the assistant, view the wiki, and pair iOS devices. No
# LaunchAgent: the customer launches it from the Dock when they
# want it.
#
# Source preference (mirrors the THIRD_PARTY_NOTICES staging
# pattern at line 5826+):
#   1. /Applications/Ostler.app already present (customer dragged
#      it from the DMG window before running this installer).
#   2. ${SCRIPT_DIR}/Ostler.app (bundled inside the installer
#      tarball / inside the OstlerInstaller.app Resources for the
#      DMG path).
#   3. ${SCRIPT_DIR}/../Ostler.app (sibling of install.sh when
#      mounted from the DMG and the installer was launched without
#      copying assets out first).
#
# A future v1.0.1 PR can add a GitHub-release download path that
# mirrors the CM042 RemoteCapture network-fetch fallback, gated on
# a published ostler-assistant release tag. For v1.0 we keep the
# install path offline-friendly so a customer who curl|bashes the
# script gets a useful warning rather than a broken download
# (Ostler.app needs to ship inside the signed DMG to clear
# Gatekeeper first-launch).

progress "Setting up Ostler.app (Hub desktop companion)" "ostler_hub_app"

HUB_APP_DEST="/Applications/Ostler.app"
HUB_APP_SOURCE=""
HUB_APP_INSTALLED=false

if [[ -d "$HUB_APP_DEST" ]]; then
    HUB_APP_SOURCE="$HUB_APP_DEST"
elif [[ -d "${SCRIPT_DIR}/Ostler.app" ]]; then
    HUB_APP_SOURCE="${SCRIPT_DIR}/Ostler.app"
elif [[ -d "${SCRIPT_DIR}/../Ostler.app" ]]; then
    HUB_APP_SOURCE="${SCRIPT_DIR}/../Ostler.app"
fi

if [[ -n "$HUB_APP_SOURCE" ]]; then
    # Stage into /Applications when the source is not already there.
    # Pre-existing install: remove first so a slimmer bundle does
    # not leave stale Resources behind. Sudo fallback for the rare
    # corporate-imaged Mac where /Applications is admin-owned.
    if [[ "$HUB_APP_SOURCE" != "$HUB_APP_DEST" ]]; then
        info "$(printf "$MSG_INFO_HUB_APP_STAGING" "${HUB_APP_SOURCE}")"
        if [[ -d "$HUB_APP_DEST" ]]; then
            rm -rf "$HUB_APP_DEST" 2>/dev/null || sudo rm -rf "$HUB_APP_DEST" 2>/dev/null || true
        fi
        if ! cp -R "$HUB_APP_SOURCE" "$HUB_APP_DEST" 2>/dev/null; then
            sudo cp -R "$HUB_APP_SOURCE" "$HUB_APP_DEST" 2>/dev/null || true
        fi
    fi

    if [[ -d "$HUB_APP_DEST" ]]; then
        info "$(printf "$MSG_INFO_HUB_APP_VERIFYING" "${HUB_APP_DEST}")"

        # Signature + Gatekeeper verification, same posture as the
        # RemoteCapture phase. Both gates must pass before we strip
        # the quarantine xattr: an unverified bundle bypassing
        # Gatekeeper is not something we silently stage onto the
        # customer's daily-driver Mac.
        HUB_APP_CODESIGN_LOG="$(mktemp -t ostler-hub-app-codesign.XXXXXX)"
        HUB_APP_SPCTL_LOG="$(mktemp -t ostler-hub-app-spctl.XXXXXX)"
        if codesign --verify --deep --strict "$HUB_APP_DEST" 2>"$HUB_APP_CODESIGN_LOG" \
           && spctl --assess --type execute "$HUB_APP_DEST" 2>"$HUB_APP_SPCTL_LOG"; then
            xattr -dr com.apple.quarantine "$HUB_APP_DEST" 2>/dev/null || true
            if [[ "$HUB_APP_SOURCE" == "$HUB_APP_DEST" ]]; then
                ok "$(printf "$MSG_OK_HUB_APP_PRESENT" "${HUB_APP_DEST}")"
            else
                ok "$(printf "$MSG_OK_HUB_APP_STAGED" "${HUB_APP_DEST}")"
            fi
            HUB_APP_INSTALLED=true
        else
            warn "$MSG_WARN_HUB_APP_VERIFY_FAILED"
            if [[ -s "$HUB_APP_CODESIGN_LOG" ]]; then
                sed -e 's/^/    /' "$HUB_APP_CODESIGN_LOG" | head -5
            fi
            if [[ -s "$HUB_APP_SPCTL_LOG" ]]; then
                sed -e 's/^/    /' "$HUB_APP_SPCTL_LOG" | head -5
            fi
        fi
        rm -f "$HUB_APP_CODESIGN_LOG" "$HUB_APP_SPCTL_LOG"
    fi
else
    warn "$MSG_WARN_HUB_APP_NOT_FOUND"
    info "$MSG_INFO_HUB_APP_DRAG_HINT"
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
    ok "$(printf "$MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE" "${NOTICES_SOURCE}")"
    info "$MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL"
else
    warn "$MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES"
    warn "$MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI"
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
    ok "$(printf "$MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE" "${LICENSES_DEST}" "${LICENSES_SOURCE}")"
else
    warn "$MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON"
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
echo "  reach from anywhere -- encrypted, no public exposure, free for"
echo "  personal use. Without it, the iOS companion only works on"
echo "  your home Wi-Fi."
echo ""
TAILSCALE_CONFIRM="$(gui_read "$MSG_PROMPT_TAILSCALE_CONFIRM_TITLE" yesno "Y" "$MSG_PROMPT_TAILSCALE_CONFIRM_HELP" "" "tailscale_confirm")"

if [[ "${TAILSCALE_CONFIRM:-y}" != "n" && "${TAILSCALE_CONFIRM:-y}" != "N" ]]; then
    if ! command -v tailscale &>/dev/null && [[ ! -d "/Applications/Tailscale.app" ]]; then
        info "$MSG_INFO_INSTALLING_TAILSCALE"
        brew install --cask tailscale 2>/dev/null && \
            ok "$MSG_OK_TAILSCALE_INSTALLED" || \
            warn "$MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL"
    else
        ok "$MSG_OK_TAILSCALE_ALREADY_INSTALLED"
    fi

    # Open the Tailscale app -- first launch prompts for sign-in. Subsequent
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
        info "$MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3"
        info "$MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH"
        TS_WAIT=0
        while [[ -z "$OSTLER_TAILSCALE_IP" && $TS_WAIT -lt 180 ]]; do
            OSTLER_TAILSCALE_IP=$("$TS_CLI" ip --4 2>/dev/null | head -1 || true)
            if [[ -z "$OSTLER_TAILSCALE_IP" ]]; then
                sleep 3
                TS_WAIT=$((TS_WAIT + 3))
            fi
        done

        if [[ -n "$OSTLER_TAILSCALE_IP" ]]; then
            ok "$(printf "$MSG_OK_TAILSCALE_IP" "${OSTLER_TAILSCALE_IP}")"
            echo "  Use this address in the Ostler iOS companion app:"
            echo "    http://${OSTLER_TAILSCALE_IP}:8089"
            # Persist to .env (replace existing line if present, append otherwise)
            ENV_FILE="${CONFIG_DIR}/.env"
            if [[ -f "$ENV_FILE" ]]; then
                if grep -q "^OSTLER_TAILSCALE_IP=" "$ENV_FILE"; then
                    # In-place rewrite of the line. Composite cleanup
                    # (registered at top of Phase 3) rms the tmp file
                    # if we exit before the mv completes -- e.g. disk
                    # full or SIGINT mid-sed. Per-resource flag is
                    # TAILSCALE_TMP_ENV; clear it after a successful
                    # mv so composite_cleanup is a no-op for this
                    # resource on normal exit.
                    TAILSCALE_TMP_ENV=$(mktemp)
                    sed "s|^OSTLER_TAILSCALE_IP=.*|OSTLER_TAILSCALE_IP=\"${OSTLER_TAILSCALE_IP}\"|" "$ENV_FILE" > "$TAILSCALE_TMP_ENV"
                    mv "$TAILSCALE_TMP_ENV" "$ENV_FILE"
                    TAILSCALE_TMP_ENV=""
                else
                    echo "OSTLER_TAILSCALE_IP=\"${OSTLER_TAILSCALE_IP}\"" >> "$ENV_FILE"
                fi
            fi
        else
            warn "$MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_60"
            warn "$MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED"
        fi
    else
        warn "$MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU"
    fi
fi

# ── 3.16 Wiki -- first compile and serve ─────────────────────────────
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

progress "Compiling your personal wiki (first run)" "wiki_compile"

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
        ok "$MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044"
    else
        warn "$MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER"
        warn "$(printf "$MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE" "${OSTLER_DIR}")"
    fi
else
    warn "$MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES"
    warn "$MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET"
    warn "$MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE"
    warn "$MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME"
    warn "$MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED"
    warn "$(printf "$MSG_WARN_CD_2" "${OSTLER_DIR}")"
    warn "$MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2"
    warn "$MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE"
fi

# ══════════════════════════════════════════════════════════════════════
#  PHASE 4: HEALTH CHECK + COMPLETION
# ══════════════════════════════════════════════════════════════════════

# Stop the Phase 3 battery watcher so its poll messages don't interleave
# with the health-check output. The hub-power LaunchAgent installed at
# 3.14 is now responsible for battery awareness from here on.
cleanup_battery_watch

step "$MSG_STEP_RUNNING_HEALTH_CHECK" "health_check"

HEALTHY=true

if curl -sf http://localhost:6333/healthz &>/dev/null; then
    ok "$MSG_OK_QDRANT_HEALTHY"
else
    warn "$MSG_WARN_QDRANT_NOT_RESPONDING"
    HEALTHY=false
fi

if curl -sf http://localhost:7878/ &>/dev/null; then
    ok "$MSG_OK_OXIGRAPH_HEALTHY"
else
    warn "$MSG_WARN_OXIGRAPH_NOT_RESPONDING"
    HEALTHY=false
fi

if docker exec ostler-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    ok "$MSG_OK_REDIS_HEALTHY"
else
    warn "$MSG_WARN_REDIS_NOT_RESPONDING"
    HEALTHY=false
fi

if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    ok "$MSG_OK_OLLAMA_HEALTHY"
else
    warn "$MSG_WARN_OLLAMA_NOT_RESPONDING"
    HEALTHY=false
fi

# Vane (local web search) is optional. Surface it in the health
# check so the customer can see whether it is running, but do NOT
# flip the install-wide HEALTHY flag if it is missing -- the
# rest of Ostler works without it (Phase 3.8b is warn-only too).
if curl -sf -o /dev/null -m 3 http://localhost:3000; then
    ok "$MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH"
else
    info "$MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE"
fi

# ── 3.18 iMessage TCC posture probe (install-time snapshot) ──────
#
# v0.1 supports iMessage as a conversation channel. macOS gates
# AppleEvents to Messages.app behind explicit consent (System
# Settings > Privacy & Security > Automation). When the operator
# has not authorised it, osascript-based delivery fails with error
# -1743 (errAEEventNotPermitted) and conversations sent via
# iMessage silently never leave the box.
#
# This is a READ-ONLY probe: it asks for the iMessage account
# count, which requires the same Automation permission a real
# send would, but does NOT send a message. Running it at install
# time also acts as the trigger for the macOS Automation consent
# prompt -- surfacing the dialog while the customer is in
# install-context, not at first-brief in production.
#
# We mirror the daemon's probe shape (zeroclaw-runtime
# imessage_tcc.rs uses `count of accounts`) so the install-time
# snapshot and the daemon's runtime probe converge on the same
# fact. This marker is the install-time SNAPSHOT only:
# ostler-assistant runs its own probe at startup and tracks
# ongoing health independently. Re-run install.sh --repair to
# refresh the snapshot.
#
# See piece D / task #213 (daemon-side probe) and task #278
# (this install-time snapshot).
#
# Skipped when iMessage is not an enabled channel -- there is no
# point probing a permission the customer has not consented to.

if [[ "${CHANNEL_IMESSAGE_ENABLED:-false}" == "true" ]]; then
    info "$MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY"

    IMESSAGE_POSTURE_DIR="${OSTLER_DIR}/imessage-posture"
    IMESSAGE_POSTURE_FILE="${IMESSAGE_POSTURE_DIR}/state.md"
    IMESSAGE_TCC_STATUS="check-failed"
    IMESSAGE_TCC_STDERR=""

    mkdir -p "$IMESSAGE_POSTURE_DIR"

    # Test-shim hook: lets test harnesses inject an outcome without
    # invoking osascript. Real macOS installs leave this unset.
    if [[ -n "${PWG_IMESSAGE_PROBE_OUTCOME:-}" ]]; then
        case "$PWG_IMESSAGE_PROBE_OUTCOME" in
            granted-and-working|tcc-denied|check-failed)
                IMESSAGE_TCC_STATUS="$PWG_IMESSAGE_PROBE_OUTCOME"
                ;;
            *)
                IMESSAGE_TCC_STATUS="check-failed"
                ;;
        esac
        IMESSAGE_TCC_STDERR="(test shim: PWG_IMESSAGE_PROBE_OUTCOME)"
    else
        IMESSAGE_PROBE_STDERR=$(mktemp)
        if osascript -e 'tell application "Messages" to count of accounts' \
                >/dev/null 2>"$IMESSAGE_PROBE_STDERR"; then
            IMESSAGE_TCC_STATUS="granted-and-working"
        else
            if grep -qE '\-1743|not authorized|errAEEventNotPermitted' "$IMESSAGE_PROBE_STDERR" 2>/dev/null; then
                IMESSAGE_TCC_STATUS="tcc-denied"
            else
                IMESSAGE_TCC_STATUS="check-failed"
            fi
            IMESSAGE_TCC_STDERR=$(head -c 400 "$IMESSAGE_PROBE_STDERR" 2>/dev/null || true)
        fi
        rm -f "$IMESSAGE_PROBE_STDERR"
    fi

    IMESSAGE_TCC_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    {
        echo "# iMessage TCC posture (install-time snapshot)"
        echo ""
        echo "Source: install.sh probe at install time"
        echo "Status: ${IMESSAGE_TCC_STATUS}"
        echo "Captured at: ${IMESSAGE_TCC_TIMESTAMP}"
        echo "Probe: osascript \"tell application \\\"Messages\\\" to count of accounts\""
        echo "Detection: exit-code + stderr regex (-1743 / not authorized / errAEEventNotPermitted)"
        echo ""
        echo "Note: Runtime health is tracked separately by ostler-assistant's"
        echo "own iMessage TCC probe (one-shot at daemon startup, refreshed on"
        echo "doctor invocation). This file is a one-shot snapshot from the"
        echo "installer. Re-run install.sh --repair (or wait for the daemon's"
        echo "next probe cycle) to refresh."
        echo ""
    } > "$IMESSAGE_POSTURE_FILE"

    case "$IMESSAGE_TCC_STATUS" in
        granted-and-working)
            {
                echo "## Status detail"
                echo ""
                echo "Automation permission for Messages.app is granted."
                echo "iMessage delivery should work; if a brief later fails,"
                echo "run \`ostler-assistant doctor\` to see runtime status."
            } >> "$IMESSAGE_POSTURE_FILE"
            ok "$MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED"
            ;;
        tcc-denied)
            {
                echo "## Remediation"
                echo ""
                echo "Automation permission for Messages.app was not granted."
                echo "Open System Settings > Privacy & Security > Automation,"
                echo "find the row for Terminal (or Ostler Installer), and"
                echo "enable the Messages tick. Re-run install.sh --repair to"
                echo "refresh this marker."
            } >> "$IMESSAGE_POSTURE_FILE"
            warn "$MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743"
            warn "$MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL"
            warn "$MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER"
            ;;
        check-failed)
            {
                echo "## Status detail"
                echo ""
                echo "Probe ran but the result did not match a known shape."
                echo "Stderr fragment:"
                echo ""
                echo '```'
                printf '%s\n' "${IMESSAGE_TCC_STDERR}"
                echo '```'
                echo ""
                echo "Re-run install.sh --repair to retry the probe, or run"
                echo "\`ostler-assistant doctor\` to see runtime status once"
                echo "the daemon is up."
            } >> "$IMESSAGE_POSTURE_FILE"
            warn "$MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE"
            warn "$(printf "$MSG_WARN_SEE_STDERR_FRAGMENT" "${IMESSAGE_POSTURE_FILE}")"
            ;;
    esac

    chmod 600 "$IMESSAGE_POSTURE_FILE"
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
        info "$MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY"
        info "$MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER"
        info "$MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC"
    else
        # Count error markers in the human-readable output. The
        # doctor module emits ❌ for Severity::Error and prefixes
        # the category. We do not fail the install here -- we just
        # surface the count so the operator knows to re-run.
        DOCTOR_ERRORS=$(printf '%s\n' "$DOCTOR_OUTPUT" | grep -c '❌' 2>/dev/null || echo 0)
        if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
            warn "$(printf "$MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S" "${DOCTOR_ERRORS}")"
            warn "$(printf "$MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH" "${ASSISTANT_BINARY}")"
            warn "$MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC"
            warn "$MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE"
            warn "$MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP"
            # Intentionally leaving the install HEALTHY flag
            # untouched: the daemon is still in startup grace at
            # install time; the markers may flip to OK on their own
            # once channels finish booting. Operator re-runs the
            # doctor command after first launch to verify.
        else
            ok "$MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED"
        fi
    fi
else
    info "$MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING"
fi

# ── Show recovery key (saved from Phase 3.6 setup_passphrase) ─────
#
# v1.0 passphrase-primary: setup_passphrase() returns a recovery key
# in XXXX-XXXX-XXXX-XXXX-XXXX-XXXX format (not BIP39). It is the
# canonical "show once" backup if the customer ever loses the typed
# passphrase. Same Keychain-save flow as before.

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
    echo "  so you do not have to write it down. It is your only"
    echo "  way back in if you ever lose your passphrase."
    echo ""
    SAVE_KEYCHAIN="$(gui_read "$MSG_PROMPT_SAVE_KEYCHAIN_TITLE" yesno "Y" "$MSG_PROMPT_SAVE_KEYCHAIN_HELP" "" "save_keychain")"
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
                ok "$MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER"
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
                ok "$MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER"
                SAVED_TO_KEYCHAIN=true
            else
                warn "$MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE"
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

# ── 3.17 Browser extensions (SHF-2 Option C) ──────────────────────
#
# Sideload-installs the Safari macOS .app shell for the Ostler
# WebExtension and opens the Chrome Web Store listing in the user's
# default browser. Both are nice-to-have rather than blockers: any
# failure here logs a WARN and continues so the rest of the install
# is unaffected.
#
# The Safari .app is bundled in install.tar.gz at
# extensions/OstlerSafariExtension.app.zip (produced by CM020's
# bin/build-safari-extension.sh and shipped Developer-ID-signed +
# notarized + stapled). Skipping the bundle silently is the
# expected pre-launch path while the build script is still being
# wired into release.
#
# Skip rules:
#   --no-extensions   skip both halves
#   ostler.ai bot     OSTLER_GUI=1 path: still runs (the GUI shell
#                     wraps install.sh and DOES want extensions)
#
# The Chrome Web Store URL comes from OSTLER_CHROME_WEBSTORE_URL.
# Andy fills the real listing URL in once the Web Store review
# clears (~72h post submission); until then the placeholder points
# at the category root which is harmless if a customer lands there
# pre-listing.

if [[ "$NO_EXTENSIONS" == true ]]; then
    info "$MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS"
else
    EXTENSIONS_BUNDLE="${SCRIPT_DIR}/extensions/OstlerSafariExtension.app.zip"
    SAFARI_APP_INSTALL_PATH="/Applications/Ostler Safari Extension.app"

    if [[ -f "$EXTENSIONS_BUNDLE" ]]; then
        info "$MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS"
        # Idempotent: clear any prior install before unzip so re-runs
        # don't merge old + new app contents into a Frankensteined
        # bundle.
        rm -rf "$SAFARI_APP_INSTALL_PATH" 2>/dev/null || true
        if /usr/bin/ditto -x -k "$EXTENSIONS_BUNDLE" /Applications/ 2>/dev/null \
                && [[ -d "$SAFARI_APP_INSTALL_PATH" || -d "/Applications/SafariHistoryExt.app" ]]; then
            # CM020 ships the .app under its Xcode product name
            # (SafariHistoryExt.app); rename to the user-visible name
            # if needed so Safari Settings displays "Ostler Safari Extension".
            if [[ -d "/Applications/SafariHistoryExt.app" && ! -d "$SAFARI_APP_INSTALL_PATH" ]]; then
                mv "/Applications/SafariHistoryExt.app" "$SAFARI_APP_INSTALL_PATH" 2>/dev/null || true
            fi
            ok "$(printf "$MSG_OK_SAFARI_EXTENSION_INSTALLED" "${SAFARI_APP_INSTALL_PATH}")"
            echo "     Enable it in Safari Settings → Extensions → Ostler"
        else
            warn "$MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN"
            warn "$(printf "$MSG_WARN_BUNDLE" "${EXTENSIONS_BUNDLE}")"
        fi
    else
        info "$MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS"
    fi

    # Chrome Web Store: open the listing in the default browser. Fire
    # and forget; failures are non-fatal (e.g. headless install).
    CHROME_URL="${OSTLER_CHROME_WEBSTORE_URL:-https://chrome.google.com/webstore/category/extensions}"
    if [[ "${OSTLER_GUI:-0}" != "1" ]]; then
        # Direct CLI install: actually open the URL.
        info "$(printf "$MSG_INFO_OPENING_CHROME_WEB_STORE" "${CHROME_URL}")"
        open "$CHROME_URL" 2>/dev/null || warn "$(printf "$MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE" "${CHROME_URL}")"
    else
        # GUI wrapper install: just print the URL so the wrapper can
        # surface it in its own UI rather than spawning a browser.
        echo "     Chrome extension: ${CHROME_URL}"
    fi
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
[[ -f "${SECURITY_CONFIG_DIR}/passkey.json" ]] && echo "     Encryption:    passkey-wrapped DEK (Touch ID)"
[[ ! -f "${SECURITY_CONFIG_DIR}/passkey.json" && -f "${SECURITY_CONFIG_DIR}/keychain.json" ]] && echo "     Encryption:    passphrase-wrapped DEK (recovery passphrase)"
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
if [[ "$CHANNEL_IMESSAGE_ENABLED" == true || "$CHANNEL_EMAIL_ENABLED" == true || "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
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
    if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
        # WhatsApp Web mode needs a pair-code link before it can
        # talk to the user's account. The 8-digit code is generated
        # from the WhatsApp mobile app (Settings > Linked Devices >
        # Link a Device > Link with phone number instead) and pasted
        # into the assistant's setup wizard.
        echo "     - WhatsApp:     pending pair-code link (next step)"
    fi
    echo "     (edit ${OSTLER_DIR}/assistant-config/config.toml to change)"
    if [[ "$CHANNEL_WHATSAPP_ENABLED" == true ]]; then
        echo ""
        echo -e "  ${BOLD}Link your WhatsApp account:${NC}"
        echo "     1. On your phone: WhatsApp > Settings > Linked Devices >"
        echo "        Link a Device > Link with phone number instead"
        echo "     2. On this Mac, run:"
        echo -e "        ${BOLD}${OSTLER_DIR}/bin/ostler-assistant setup channels --interactive whatsapp${NC}"
        echo "     3. Enter the 8-digit code shown by the assistant into"
        echo "        the WhatsApp app on your phone."
    fi
elif [[ -n "${CHANNEL_CHOICE:-}" && "$CHANNEL_CHOICE" == "4" ]]; then
    echo ""
    echo "  No channels configured. Set one up later via:"
    echo "     ${OSTLER_DIR}/bin/ostler-assistant setup channels --interactive"
fi

# iMessage Automation permission banner. Silent on
# granted-and-working (Apple-restraint brand voice). Surfaces
# remediation when the install-time probe could not confirm
# delivery, so the customer is not left wondering why their
# briefs never arrive. The marker file at
# ~/.ostler/imessage-posture/state.md has the full detail.
if [[ "${CHANNEL_IMESSAGE_ENABLED:-false}" == "true" \
        && -n "${IMESSAGE_TCC_STATUS:-}" \
        && "${IMESSAGE_TCC_STATUS}" != "granted-and-working" ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}iMessage delivery posture: NOT YET CONFIRMED${NC}"
    if [[ "$IMESSAGE_TCC_STATUS" == "tcc-denied" ]]; then
        echo "     Open System Settings > Privacy & Security > Automation,"
        echo "     find the Terminal (or Ostler Installer) row, and enable"
        echo "     the Messages tick. Re-run install.sh --repair to refresh."
    else
        echo "     The probe could not confirm Messages.app permission."
        echo "     See ${OSTLER_DIR}/imessage-posture/state.md for detail,"
        echo "     or run \`ostler-assistant doctor\` once the daemon is up."
    fi
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
echo "  $MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── GUI completion markers ─────────────────────────────────────────
# Close any still-open step + signal completion to the GUI. No-op
# under TTY mode (OSTLER_GUI unset). The GUI consumes DONE to flip
# its sidebar to the success state and offer a "Reveal in Finder"
# affordance for ~/Documents/Ostler.
if [[ -n "${__OSTLER_STEP_ID:-}" ]]; then
    gui_step_end ok
fi
gui_done ok

# ── First-run auto-open ────────────────────────────────────────────
# Open the customer-facing wiki in the default browser. Best-effort --
# don't fail the install if this fails. Under GUI mode the installer
# Swift app will offer its own "Open Wiki" affordance on the success
# screen, so we skip here to avoid a double-open race.
if [[ "${OSTLER_GUI:-}" == "1" ]]; then
    # GUI installer will offer its own "Open Wiki" affordance; skip here.
    :
else
    open "http://localhost:8044" 2>/dev/null || true
fi
