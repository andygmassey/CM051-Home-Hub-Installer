#!/usr/bin/env bash
# Ostler – Beta Installer
# Usage: curl -fsSL https://ostler.ai/install.sh | bash
#
# Structure:
#   Phase 1: Check prerequisites (automatic, no input)
#   Phase 2: Collect ALL user input upfront (~2 minutes)
#   Phase 3: Install everything unattended (~15-60 minutes, depending
#            on how much history is on your Mac)
#   Phase 4: Health check + next steps
#
# What this does NOT do:
#   - Send your personal data anywhere. Public-data queries (Wikidata
#     enrichment, local web search via the bundled Vane + SearXNG
#     container) and model/software downloads are described in the
#     privacy policy.
#   - Install anything without telling you first.
#   - Touch your existing Docker containers or Homebrew packages.

# -E (errtrace): make the ERR trap fire for failures INSIDE shell
# functions / subshells / command substitutions, not just top-level
# commands. Without it a `set -u` death inside a helper function (the
# common abort shape -- CX-98 et al) would skip the ERR trap entirely
# and die silently with no DONE marker. The ERR trap itself
# (_ostler_on_err) is registered later, once the real gui helpers are
# sourced. See CX-454 (task #454).
set -Eeuo pipefail

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
    echo "  3. Installs everything automatically (~15-60 minutes, depending on your history)"
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
    echo "    Default: https://github.com/ostler-ai/ostler-releases/releases/latest/download/install.tar.gz"
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
    echo "    Source repo for the import pipeline (People Graph)."
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
    echo "    Source repo for the Knowledge service (Evernote ingest)."
    echo "    Default: empty (Knowledge service skipped warn-only; the"
    echo "    Doctor 'Import Evernote' surface, when the feature flag is"
    echo "    eventually flipped on, will surface 'service unavailable')."
    echo "    Set to a clone URL pointing at a tagged release SHA of the"
    echo "    evernote-knowledge repo to install ostler-knowledge into"
    echo "    a dedicated venv at ~/.ostler/services/knowledge/."
    echo ""
    echo "  PWG_CM048_REPO"
    echo "    Source repo for the conversation memory engine."
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
    echo "    (the wiki). Larger narrative summaries use a separate model."
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
gui_cancelled()   { :; }
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

# CX-17 (2026-05-23): stable error-code framework. Andy asked
# during Studio retest #6 whether we could "add error codes in the
# failure notice so we can track down when and where (and ideally
# what) fails if a customer has an issue". Yes -- every fail
# callsite now carries a stable code of shape ERR-NN-COMPONENT-SHORTREASON
# where NN is the 1-based step index in the StepCatalog.canonicalOrder
# sidebar (e.g. ERR-17-DOCTOR-* lives in the doctor_setup step). The
# code surfaces on the failure banner header, the auto-copied log
# header that goes to support, AND on the GUI DONE marker so the
# Swift side can pin the code to the failed step.
#
# Two callsite shapes:
#   - `fail "..."`            (legacy; still works; emits no code)
#   - `fail_with_code "ERR-NN-FOO-BAR" "..."` (preferred; emits code)
#
# A bare `fail "..."` is a regression at this point -- the
# tests/test_every_fail_call_has_error_code.sh harness asserts every
# fail callsite is `fail_with_code` so we don't drift back. The
# legacy fail() shape is kept for the test rig + emergency one-off
# patches only.
OSTLER_LAST_ERROR_CODE=""

# CX-454 (task #454): the single "a terminal DONE marker has gone out"
# sentinel. It is set =1 inside the real gui_done / gui_cancelled
# (lib/progress_emitter.sh), which are the only chokepoints that emit a
# DONE ok / fail / cancelled marker. Every explicit fail/fail_with_code
# routes through gui_done, so an anticipated failure sets it too.
#
# Two trap handlers read it so we report a mid-script death exactly
# once, never twice and never as a false success:
#   - the ERR trap (_ostler_on_err) stays silent if a terminal marker
#     already went out (so a curated ERR-NN-* is not overwritten by the
#     synthetic ERR-99);
#   - the EXIT backstop (top of composite_cleanup) emits a synthetic
#     DONE-fail ONLY if no terminal marker was emitted and the install
#     had actually started (see _ostler_on_err / composite_cleanup).
#
# Declared empty up-front so both `set -u`-safe handlers can read it via
# ${OSTLER_DONE_EMITTED:-} before the lib is sourced.
OSTLER_DONE_EMITTED=""

fail_with_code() {
    # fail_with_code <CODE> <MSG...>
    # CODE must match ERR-NN-* shape. We do not enforce that here
    # (a malformed code at runtime is worse than a malformed code
    # in the log) but the test harness asserts the shape at lint
    # time. The CODE is exported on OSTLER_LAST_ERROR_CODE so the
    # gui_done call below can attach it to the DONE marker.
    local code="$1"; shift
    OSTLER_LAST_ERROR_CODE="$code"
    export OSTLER_LAST_ERROR_CODE
    fail "$*"
}

fail()  {
    # CX-454: this routes through gui_done below, which sets
    # OSTLER_DONE_EMITTED. That marks the failure as already terminally
    # reported, so the ERR trap (_ostler_on_err) and the EXIT backstop
    # both stay silent and never double-report this explicit failure
    # with the synthetic ERR-99 code. Every fail_with_code routes
    # through here, so both helpers are covered.
    # Render the code prefix on the TTY line + the GUI log so the
    # error is greppable end-to-end. The code may be empty -- a
    # legacy fail "..." call (no code attached) renders without a
    # prefix, matching the pre-CX-17 behaviour.
    local code_prefix=""
    if [[ -n "${OSTLER_LAST_ERROR_CODE:-}" ]]; then
        code_prefix="[${OSTLER_LAST_ERROR_CODE}] "
    fi
    gui_active || echo -e "${RED}[fail]${NC}  ${code_prefix}$*"
    gui_log error "${code_prefix}$*"
    gui_done fail
    exit 1
}

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
#
# CX-87 (DMG #48g, 2026-05-29): two-stage engine-zone layout. All
# pre-FDA writes land in OSTLER_PRELAUNCH_DIR (a /tmp staging tree
# whose layout mirrors ~/.ostler/ exactly). After the FDA grant
# flow completes successfully (the re-probe returns FDA_GRANTED=true)
# the staging tree is atomic-renamed onto ~/.ostler/ and the path
# variables are re-bound to the final location. Everything after
# FDA grant therefore writes directly to ~/.ostler/ as before.
#
# Why: macOS Full Disk Access can fire a "Quit & Reopen" dialog
# when the user toggles the FDA switch for OstlerInstaller.app. If
# install.sh has already written .env / service_token / config.toml /
# .installer-tree-created to ~/.ostler/ before that point, the
# relaunched installer sees a half-populated engine zone and the
# Phase-2 reuse detection (line ~1100) silently auto-skips Phase 2.
# The install then bails after config_save without doing wiki /
# Ostler.app / pair-register / QR.
#
# Routing every pre-FDA write through a PID-stamped staging tree
# means the relaunched installer (fresh PID, fresh staging dir,
# empty ~/.ostler/) walks the questions normally instead of
# silently bailing.
#
# License.json is deliberately NOT staged -- the GUI's
# LicensePersistence writes it to ~/.ostler/license/license.json
# before install.sh starts, so the customer doesn't have to re-drop
# the licence after Quit & Reopen.  ~/.ostler/license/ existing
# alone does NOT trigger Phase-2 skip (that gate checks for
# ${CONFIG_DIR}/.env, which IS in the staging tree).
#
# Cleanup: composite_cleanup wipes the staging tree on any
# non-success exit so a half-populated staging dir doesn't
# accumulate in /tmp.

OSTLER_FINAL_DIR="${HOME}/.ostler"
OSTLER_PRELAUNCH_DIR="${OSTLER_PRELAUNCH_DIR:-/tmp/ostler-prelaunch-$$}"

# _ostler_set_paths $target_root rebinds OSTLER_DIR + every
# derived path variable to the supplied root. Called twice in the
# install lifecycle:
#   1. Here, immediately with OSTLER_PRELAUNCH_DIR.
#   2. After the FDA grant re-probe succeeds, with OSTLER_FINAL_DIR.
# Keeping the assignments in one place means future path additions
# only need to be added below + in the staging tree creation, not
# scattered across the script.
_ostler_set_paths() {
    OSTLER_DIR="$1"
    DATA_DIR="${OSTLER_DIR}/data"
    CONFIG_DIR="${OSTLER_DIR}/config"
    # LOGS_DIR follows the staging tree on purpose: the install log
    # is the forensic trail and should match whatever tree the rest
    # of the install state lives in. On a successful install the
    # whole tree gets renamed onto ~/.ostler/ so the log ends up at
    # the canonical location anyway. On a failed install the
    # composite_cleanup trap dumps a copy of the log to
    # /tmp/ostler-install-failsafe-$$.log before removing the
    # staging dir, so support has a copy even after cleanup.
    LOGS_DIR="${OSTLER_DIR}/logs"
    SECURITY_DIR="${OSTLER_DIR}/security-module"
    SECURITY_CONFIG_DIR="${OSTLER_DIR}/security"
    PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"
    USER_TREE_SENTINEL="${OSTLER_DIR}/.installer-tree-created"
    # CX-87 (DMG #48g): derived path vars assigned BEFORE the FDA
    # grant flow and read AFTER promotion -- must be rebound here
    # too. FDA_DIR is the canonical example: line ~2658 sets it
    # against the staging path; line ~5349 reads it after promotion.
    # Without this rebind the Python heredoc would sys.path.insert
    # a /tmp/ostler-prelaunch-<old-pid>/fda-module that no longer
    # exists (the mv moved its contents into ~/.ostler/fda-module).
    # SECRETS_DIR + OSTLER_ENV_FILE + ASSISTANT_CONFIG_DIR are also
    # set pre-FDA and read post-FDA; included here for the same
    # reason. ASSISTANT_BINARY follows from ASSISTANT_APP_BUNDLE
    # which itself follows from OSTLER_DIR.
    FDA_DIR="${OSTLER_DIR}/fda-module"
    SECRETS_DIR="${OSTLER_DIR}/secrets"
    OSTLER_ENV_FILE="${OSTLER_DIR}/.env"
    ASSISTANT_CONFIG_DIR="${OSTLER_DIR}/assistant-config"
    ASSISTANT_APP_BUNDLE="${OSTLER_DIR}/OstlerAssistant.app"
    ASSISTANT_BINARY="${ASSISTANT_APP_BUNDLE}/Contents/MacOS/ostler-assistant"
    ASSISTANT_BINARY_LEGACY="${OSTLER_DIR}/bin/ostler-assistant"
    OSTLER_ASSISTANT_DIR="${OSTLER_DIR}/assistant-agent"
    CHAT_ADMIN_TOKEN_FILE="${SECRETS_DIR}/zeroclaw_admin_token"
    SERVICE_TOKEN_FILE="${SECRETS_DIR}/service_token"
    # Python venv lives at $OSTLER_DIR/.venv. Created during the
    # encrypt_db step (pre-FDA), used heavily after FDA grant for the
    # Python heredocs in the FDA extraction + hydrate steps.
    OSTLER_VENV="${OSTLER_DIR}/.venv"
    OSTLER_PIP="${OSTLER_VENV}/bin/pip"
    OSTLER_PYTHON="${OSTLER_VENV}/bin/python3"
}

_ostler_set_paths "$OSTLER_PRELAUNCH_DIR"

# Pre-create the staging tree so the first writes downstream
# (LOGS_DIR mkdir at ~line 396) land in a writable location.
mkdir -p "$OSTLER_PRELAUNCH_DIR"
chmod 700 "$OSTLER_PRELAUNCH_DIR"

# Mirror any pre-existing ~/.ostler/license/ into the staging tree
# so install.sh paths that read license.json find it where they
# expect. The licence file itself stays at ~/.ostler/license/ (the
# GUI's LicensePersistence wrote it there); we only symlink so a
# staging-tree relative reference resolves.
if [[ -d "${OSTLER_FINAL_DIR}/license" ]]; then
    ln -sfn "${OSTLER_FINAL_DIR}/license" "${OSTLER_PRELAUNCH_DIR}/license"
fi

# CX-87 (DMG #48g, 2026-05-29): defined early so the Phase-2 re-run
# branch (~line 1237) can call it BEFORE the trap registration at
# the top of Phase 3 (composite_cleanup section). The trap-side
# OSTLER_PRELAUNCH_PROMOTED guard is also declared early below so
# the function and the trap share the same scope. The cleanup
# stanza inside composite_cleanup itself is registered with the
# trap; if a future split moves the trap up here, both halves
# stay symmetric.
OSTLER_PRELAUNCH_PROMOTED=false

# Atomic-promote the pre-FDA staging tree onto ~/.ostler/. Called
# once per install lifecycle, idempotent on re-call.
#
# Contract:
#   - If the staging tree is already promoted (idempotent re-call),
#     no-op.
#   - If ~/.ostler/ does not exist, walks staging-tree top-level +
#     mv each entry across (per-entry atomic rename).
#   - If ~/.ostler/ already exists (license.json was written by the
#     GUI's LicensePersistence into ~/.ostler/license/ before
#     install.sh started, so this is the normal v1.0 case), we walk
#     each top-level entry in the staging tree, rm + mv into
#     ~/.ostler/. The license/ symlink in the staging tree resolves
#     back to ~/.ostler/license/ already, so we deliberately skip it
#     to avoid replacing the real directory with a self-referential
#     symlink.
#   - After the promotion: rebind every path variable to ~/.ostler/
#     so subsequent install.sh writes land at the canonical
#     location, set OSTLER_PRELAUNCH_PROMOTED=true so the cleanup
#     trap stops trying to wipe a path that no longer exists, and
#     wipe the now-empty staging dir.
#
# Why not a single mv even when ~/.ostler/ exists: macOS `mv` of a
# directory onto an existing directory errors out (it expects the
# target to be absent). We could remove the target first, but that
# would unlink the GUI-written licence file and the customer would
# have to re-drop the .json. Walking the staging tree top-level
# instead keeps the licence intact while still doing one rename
# per child (atomic per-entry, which is the property we need).
_ostler_promote_prelaunch_tree() {
    if [[ "$OSTLER_PRELAUNCH_PROMOTED" == "true" ]]; then
        return 0
    fi
    if [[ -z "${OSTLER_PRELAUNCH_DIR:-}" ]] || [[ ! -d "$OSTLER_PRELAUNCH_DIR" ]]; then
        return 0
    fi
    if [[ "$OSTLER_PRELAUNCH_DIR" == "$OSTLER_FINAL_DIR" ]]; then
        # Belt and braces: a future env-var override that pointed
        # the staging tree at ~/.ostler/ directly should never end
        # up in a self-rename here.
        OSTLER_PRELAUNCH_PROMOTED=true
        return 0
    fi

    mkdir -p "$OSTLER_FINAL_DIR"
    chmod 700 "$OSTLER_FINAL_DIR" 2>/dev/null || true

    # Walk top-level entries in the staging tree and move them
    # into ~/.ostler/. Hidden entries (starting with .) included.
    local entry name
    for entry in "$OSTLER_PRELAUNCH_DIR"/* "$OSTLER_PRELAUNCH_DIR"/.[!.]* "$OSTLER_PRELAUNCH_DIR"/..?*; do
        [[ -e "$entry" ]] || continue
        name="$(basename "$entry")"
        # Skip the license symlink we set up at startup -- the real
        # licence dir already lives at ${OSTLER_FINAL_DIR}/license/.
        if [[ "$name" == "license" ]] && [[ -L "$entry" ]]; then
            continue
        fi
        # If the target already exists (e.g. the customer is
        # re-running install.sh over a previous incomplete install),
        # prefer the freshly-written staging-tree entry. rm + mv
        # is not atomic across the two operations but the only
        # observable window is one in which a reader sees the
        # target absent, which is the same window mv -f handles
        # internally on macOS for files (but not directories).
        if [[ -e "${OSTLER_FINAL_DIR}/${name}" ]]; then
            rm -rf "${OSTLER_FINAL_DIR}/${name}"
        fi
        mv "$entry" "${OSTLER_FINAL_DIR}/${name}"
    done

    # Wipe the now-empty staging dir (it should only contain the
    # license symlink at this point, if at all).
    rm -rf "$OSTLER_PRELAUNCH_DIR" 2>/dev/null || true

    # Rebind every path variable to the canonical location so
    # subsequent install.sh writes land at ~/.ostler/.
    _ostler_set_paths "$OSTLER_FINAL_DIR"
    OSTLER_PRELAUNCH_PROMOTED=true

    # CX-95 (DMG #48g+, 2026-05-29): repair the venv after promote.
    #
    # `python -m venv` bakes the absolute creation path into the
    # shebang of every script in bin/ (pip, pip3, pip3.11, console
    # scripts like ostler-consent / ostler-recovery) and into
    # pyvenv.cfg's `command = ...` line. When the venv was created
    # inside ${OSTLER_PRELAUNCH_DIR}/.venv (Phase 2 line ~2605 or
    # Phase 3.6 line ~4906) and we just mv'd it to
    # ${OSTLER_FINAL_DIR}/.venv, every shebang now points at a
    # /tmp/ostler-prelaunch-<old-pid>/.venv/bin/python3.X that
    # macOS deleted with the staging tree (rm -rf above).
    #
    # The symptom is ERR-09 on the customer's next pip invocation
    # (Phase 3.6 sqlcipher3 at line ~4930, or any re-run that hits
    # $OSTLER_PIP), because the kernel resolves the shebang before
    # exec'ing the script:
    #   bad interpreter: /tmp/ostler-prelaunch-4490/.venv/bin/python3.11:
    #                    no such file or directory
    #
    # Studio retest of DMG #48g (2026-05-29) caught this; the
    # customer-reported pip shebang was literally
    #   #!/tmp/ostler-prelaunch-4490/.venv/bin/python3.11
    # against a venv at ${HOME}/.ostler/.venv that mv had relocated.
    #
    # Fix: detect stale shebang, nuke + recreate the venv at the
    # final location, then reinstall the Phase-2 packages
    # (ostler_security + legal) so post-promote use sites
    # (lines ~5070 region.py, ~5102 consent_cli, ~7314 ical-server)
    # keep importing cleanly. Phase 3.6 re-installs sqlcipher3 /
    # cryptography itself via the idempotent `[[ ! -d ]]` check at
    # line ~4906, so we don't need to handle those here.
    _ostler_repair_venv_after_promote
}

# CX-95 (DMG #48g+, 2026-05-29): repair venv shebangs after promote.
# Idempotent helper called from _ostler_promote_prelaunch_tree above.
# Safe to call when no venv exists (no-op). Safe to call when venv
# was created at the final location (shebang check finds no drift,
# no rebuild).
_ostler_repair_venv_after_promote() {
    local venv_dir="${OSTLER_FINAL_DIR}/.venv"
    local pip_path="${venv_dir}/bin/pip"
    [[ -d "$venv_dir" ]] || return 0

    # Detect stale shebang. If $venv_dir/bin/pip exists, read the
    # first line and check whether it points at a python3 that
    # actually exists. A live shebang is "#!<absolute-path>", and
    # the path must resolve to an executable file. Anything else
    # means we need to rebuild.
    local needs_rebuild=false
    if [[ -f "$pip_path" ]]; then
        local shebang_line interp
        shebang_line="$(head -n 1 "$pip_path" 2>/dev/null)"
        if [[ "$shebang_line" =~ ^\#\!([^[:space:]]+) ]]; then
            interp="${BASH_REMATCH[1]}"
            if [[ ! -x "$interp" ]]; then
                needs_rebuild=true
            fi
        else
            # No parseable shebang -> something is wrong; rebuild.
            needs_rebuild=true
        fi
    else
        # venv directory exists but pip is missing -> incomplete or
        # corrupted venv. Rebuild defensively.
        needs_rebuild=true
    fi

    if [[ "$needs_rebuild" != "true" ]]; then
        return 0
    fi

    # Need PYTHON3_BIN to recreate. It's set during the Phase 2.99
    # python check (~line 2540). If we're called before that (e.g.
    # the SKIP_PHASE2 re-run path at line ~1357 calls us before
    # Phase 2.99 fires), fall back to system python3. The fallback
    # is best-effort: if PYTHON3_BIN truly isn't available the venv
    # rebuild fails and Phase 3.6 line ~4906 retries the create.
    local python_bin="${PYTHON3_BIN:-}"
    if [[ -z "$python_bin" ]]; then
        # Prefer the .app's bundled python3.11 -- customer installs
        # always have this. Then brew kegs, then PATH. SCRIPT_DIR is
        # the installer root (signed .app Contents/Resources or
        # dev-mode sibling clone), set during the bootstrap prelude.
        if [[ -n "${SCRIPT_DIR:-}" && -x "${SCRIPT_DIR}/python/bin/python3.11" ]]; then
            python_bin="${SCRIPT_DIR}/python/bin/python3.11"
        elif [[ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]]; then
            python_bin="/opt/homebrew/opt/python@3.11/bin/python3.11"
        elif [[ -x "/usr/local/opt/python@3.11/bin/python3.11" ]]; then
            python_bin="/usr/local/opt/python@3.11/bin/python3.11"
        elif command -v python3 &>/dev/null; then
            python_bin="$(command -v python3)"
        else
            # No python available yet. Leave the stale venv alone --
            # Phase 3.6 will re-fail visibly and the customer can
            # retry once Homebrew lands python@3.11.
            return 0
        fi
    fi

    rm -rf "$venv_dir"
    if ! "$python_bin" -m venv "$venv_dir" 2>/dev/null; then
        # Venv recreate failed. Leave the dir absent so Phase 3.6
        # surfaces the failure visibly via its own error path.
        return 0
    fi

    # Reinstall the packages that Phase 2 + Phase 3.6 put into the
    # pre-promote venv, so post-promote import sites + deployed
    # LaunchAgents keep working:
    #
    #   ostler_security -- needed at lines ~5070 / ~5102 / ~7314 +
    #                      by every deployed service at runtime
    #                      (ical-server, whatsapp-bridge, cm048 ingest)
    #   legal           -- consent-string constants used by
    #                      ostler_security.consent + the Rust gates
    #   sqlcipher3      -- ostler_security.database falls back to
    #                      plaintext sqlite without this; the
    #                      deployed services rely on encrypted DBs
    #                      to honour the install-time
    #                      "data-encrypted-at-rest" promise.
    #   cryptography    -- transitive dep of ostler_security; the
    #                      wheel install above re-resolves it from
    #                      pip's local cache.
    #
    # All three are pip-cached binary wheels (sqlcipher3 ships
    # macosx_11_0_arm64 wheels for cp310/cp311/cp312); reinstall is
    # sub-second offline once pip's local wheel cache is warm. We
    # let pip choose between fresh download + cache hit silently.
    # Any failure here is non-fatal (Phase 3.6 retries sqlcipher3
    # at line ~4930, the import sites have graceful fallbacks); the
    # post-promote venv is at least syntactically valid even on a
    # partial reinstall.
    if [[ -d "${SCRIPT_DIR}/ostler_security" && -f "${SCRIPT_DIR}/ostler_security/pyproject.toml" ]]; then
        "${venv_dir}/bin/pip" install --quiet "${SCRIPT_DIR}/ostler_security" 2>/dev/null || true
    fi
    if [[ -d "${SCRIPT_DIR}/legal" && -f "${SCRIPT_DIR}/legal/pyproject.toml" ]]; then
        "${venv_dir}/bin/pip" install --quiet "${SCRIPT_DIR}/legal" 2>/dev/null || true
    fi
    "${venv_dir}/bin/pip" install --quiet "sqlcipher3>=0.6.0,<0.7.0" 2>/dev/null || true
}

# Two-zone layout: ~/Documents/Ostler/ holds the customer's
# generated content (wiki MDs, call transcripts, daily briefs,
# quick captures, one-off exports). ~/.ostler/ above is the
# engine room (databases, configs, logs, caches). The user-facing
# tree is created at install time and survives an uninstall by
# default; the customer is asked whether to keep it. See
# /tmp/tnm_brief_two_zone_architecture_2026-05-02.md (Gap 4).
USER_FACING_ROOT="${HOME}/Documents/Ostler"
# Ordered list of subdirs created under ${USER_FACING_ROOT}.
# Conversations/ holds the four-artefact conversation-memory bundles
# (summary + todos + transcript + metadata) that CM048's pwg-convo
# emits for every wired human channel -- WhatsApp first (the gating
# floor), then iMessage / email / meeting-voice. The bundle feeds
# write under ${USER_FACING_ROOT}/Conversations/<date>/<slug>-<id>/.
# (AI Conversations live in a SEPARATE tree, added in v1.0.1.)
USER_TREE_SUBDIRS=("Wiki" "Conversations" "Transcripts" "Daily-Briefs" "Captures" "Exports")

# ── DMG #48 install transcript ────────────────────────────────────
#
# Studio retest of DMG #47 (2026-05-27): the install GUI flowed
# all the way to "end" but `which brew`, `which colima`, `which
# tailscale` were all "not found", AND no `${LOGS_DIR}/install*.log`
# existed on disk. Customer + support had zero diagnostic trail to
# work with. Tee everything emitted from this point forward into
# ${INSTALL_LOG} so the next failure leaves a paper trail.
#
# Why so early: Phase 3.1 Homebrew install is the most-likely
# failure axis and lives at line ~3613. We want the install.log to
# capture context BEFORE it. So we mkdir + tee up here, just after
# the path definitions, before any of the heavy lifting.
#
# Implementation: a backgrounded `tee` subprocess fed via a FIFO
# would be cleaner but adds a trap for cleanup. The simpler
# `exec > >(tee -a ...) 2>&1` pattern uses bash process substitution
# and survives `set -e` because it is part of a redirection list,
# not a foreground command. The tee output appends so a re-run
# extends the transcript rather than clobbering forensic state from
# the previous failed run.
mkdir -p "${LOGS_DIR}" 2>/dev/null || true
INSTALL_LOG="${LOGS_DIR}/install.log"
# Tee unbuffered so the GUI's `tail -f` style log viewer sees lines
# immediately rather than 4KB-buffered. macOS has no `stdbuf` natively
# (it's part of GNU coreutils, available via `brew install coreutils`
# as `gstdbuf`), and on a fresh customer Mac brew is installed downstream
# of this block. Probe stdbuf > gstdbuf > plain tee. If we fall back to
# plain tee the install still works; the GUI log just streams in larger
# chunks until brew + coreutils are on PATH.
_ostler_select_tee_cmd() {
    if command -v stdbuf >/dev/null 2>&1; then
        echo "stdbuf -oL tee"
    elif command -v gstdbuf >/dev/null 2>&1; then
        echo "gstdbuf -oL tee"
    else
        echo "tee"
    fi
}
_OSTLER_TEE_CMD="$(_ostler_select_tee_cmd)"
if [[ -w "${LOGS_DIR}" ]]; then
    {
        echo ""
        echo "=== install.sh run $(date -u +"%Y-%m-%dT%H:%M:%SZ") (DMG #48 transcript) ==="
        echo "USER=$(id -un) (uid=$(id -u))"
        echo "ARCH=$(uname -m)"
        echo "OSTLER_GUI=${OSTLER_GUI:-0}"
        echo "PATH=${PATH}"
        echo "TEE_CMD=${_OSTLER_TEE_CMD}"
        echo "SCRIPT_DIR not yet resolved (set later in the prelude)"
        echo "============================================================"
    } >> "${INSTALL_LOG}"
    # Redirect future stdout+stderr through tee so both the customer's
    # terminal / GUI window AND ${INSTALL_LOG} get every byte.
    exec > >(${_OSTLER_TEE_CMD} -a "${INSTALL_LOG}") 2>&1
else
    # Fallback when ~/.ostler/logs is not writeable (defensive: a
    # caller already restricted permissions). Still try /tmp so we
    # have SOMETHING on disk. Mention the fallback in the
    # customer log so support sees it.
    INSTALL_LOG="/tmp/ostler-install-$(date +%s).log"
    echo "WARN: ${LOGS_DIR} is not writeable; install.log falling back to ${INSTALL_LOG}" >&2
    exec > >(${_OSTLER_TEE_CMD} -a "${INSTALL_LOG}") 2>&1
fi
export INSTALL_LOG

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
# ostler-ai/ostler-releases mirror (versioned, signed, free, standard
# pattern). Customer-shipping releases were consolidated under
# ostler-ai/ostler-releases on 2026-05-29; see CX-88. Cloudflare
# Pages serving a static tarball was considered but loses versioning
# + signing; GitHub Release is the long-term home.
DEFAULT_INSTALLER_TARBALL_URL="https://github.com/ostler-ai/ostler-releases/releases/latest/download/install.tar.gz"
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
    gui_cancelled()   { :; }
    gui_active()      { return 1; }
    gui_needs_sudo()  { :; }
    gui_needs_fda()   { :; }
fi
unset _ostler_emitter_candidate

# ── Hardware-fit model picker helper (REUSE-4) ────────────────────
#
# lib/ostler-model-fit.sh holds the static model->min-RAM-for-num_ctx
# table plus the pure fit/recommend logic used by the "AI model
# (automatic)" step further down. Sourced here (alongside
# progress_emitter.sh) so the same multi-location resolution applies:
#   1. ${SCRIPT_DIR}/lib/ostler-model-fit.sh   (tarball / dev / .app bundle)
#   2. ${HOME}/.ostler/lib/ostler-model-fit.sh (post-install re-run)
# Sourcing is side-effect-free (defines functions + arrays, prints
# nothing). If it is missing we fall back to the legacy RAM ladder in
# the AI-model step, so a stripped bundle degrades rather than aborts.
_ostler_modelfit_candidate=""
if [[ -f "${SCRIPT_DIR}/lib/ostler-model-fit.sh" ]]; then
    _ostler_modelfit_candidate="${SCRIPT_DIR}/lib/ostler-model-fit.sh"
elif [[ -f "${HOME}/.ostler/lib/ostler-model-fit.sh" ]]; then
    _ostler_modelfit_candidate="${HOME}/.ostler/lib/ostler-model-fit.sh"
fi
if [[ -n "${_ostler_modelfit_candidate}" ]]; then
    # shellcheck source=lib/ostler-model-fit.sh
    source "${_ostler_modelfit_candidate}"
fi
unset _ostler_modelfit_candidate

# ── Three-state data-source detection (CX-100, CX-101) ────────────
#
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Apple's "configured" and "populated" are two different states for
# every iCloud-synced data source. Configuring an account in System
# Settings -> Internet Accounts writes ~/Library/Accounts/Accounts4.sqlite;
# populating the local derived store (Mail's *.emlx tree, Calendar.sqlitedb
# row count, Contacts' *.abcddb) requires the corresponding app to have
# run and synced. Old probes conflated the two and reported "0 accounts"
# whenever the local store was empty, even when 2 accounts existed in
# Accounts4.sqlite. This silently broke every install where the customer
# configured iCloud but hadn't opened Mail / Contacts / Calendar yet.
#
# These helpers split the probe in two:
#   - _accountsdb_count_mail / _accountsdb_count_calendar / _accountsdb_count_contacts
#     count source-of-truth rows in Accounts4.sqlite for each data class.
#     They tolerate schema variation across macOS versions (best-effort
#     SQL with || echo 0 fallback) and return a clean integer on stdout.
#   - _store_populated_mail / _store_populated_calendar / _store_populated_contacts
#     check whether the local derived store has any rows / files yet.
#     Returns 0 (true) if populated, 1 (false) otherwise.
#
# Combined the two probes give a three-state classification:
#   accountsdb=0  -> state 1 (no source configured)        -> skip, configurable later
#   accountsdb>0, store empty -> state 2 (configured, not synced) -> prompt + wait + poll
#   accountsdb>0, store ok    -> state 3 (configured + populated) -> hydrate
#
# Three-state probe helpers
# -------------------------
# All Accounts4.sqlite reads use `:memory:` attach trick to avoid
# accidentally write-locking the live database. sqlite3 file:?mode=ro
# is the read-only form; even with that, defensively redirect stderr.

_accountsdb_path() {
    printf '%s' "${HOME}/Library/Accounts/Accounts4.sqlite"
}

# CX-103 (DMG #48k, 2026-05-29): Accounts4.sqlite is gated by Full
# Disk Access on Sequoia. On a fresh install where the customer has
# not yet granted FDA to OstlerInstaller.app, sqlite3 returns
# "authorization denied" and our `2>/dev/null` mask collapses the
# probe to "0 accounts" -- mis-firing the "Mail not connected"
# prompt at Studio retest of DMG #48j. _has_fda probes the same
# file with stderr captured + grepped for the TCC denial signature
# so the caller can distinguish "FDA missing" from "no accounts".
# Returns 0 if FDA is granted (or path missing -- nothing to probe).
# Returns 1 if FDA is denied. Never raises.
_has_fda() {
    local db
    db="$(_accountsdb_path)"
    [[ -f "$db" ]] || return 0
    local err
    err="$(sqlite3 "file:${db}?mode=ro" -bail "SELECT 1 LIMIT 1" 2>&1 >/dev/null)" || true
    if [[ "$err" == *"authorization denied"* ]] \
       || [[ "$err" == *"unable to open database"* ]]; then
        return 1
    fi
    return 0
}

# Returns the number of mail-capable accounts the customer has
# configured in System Settings -> Internet Accounts. Counts only
# top-level account rows (ZAUTHENTICATIONTYPE != 'parent') for the
# account types that actually carry mail capability. AppleAccount =
# iCloud (Mail dataclass enabled at AppleID level); the explicit
# IMAP / Google / Yahoo / Hotmail / Exchange types cover the rest.
#
# Echoes a clean integer on stdout. On any sqlite3 / schema failure
# echoes 0. Never raises.
_accountsdb_count_mail() {
    local db
    db="$(_accountsdb_path)"
    [[ -f "$db" ]] || { printf '0'; return 0; }
    local n
    n="$(sqlite3 "file:${db}?mode=ro" -bail "
        SELECT COUNT(*) FROM ZACCOUNT a
        JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
        WHERE t.ZIDENTIFIER IN (
            'com.apple.account.IMAP',
            'com.apple.account.IMAPMail',
            'com.apple.account.Hotmail',
            'com.apple.account.Google',
            'com.apple.account.Yahoo',
            'com.apple.account.Exchange',
            'com.apple.account.AppleAccount',
            'com.apple.account.MobileMe',
            'com.apple.account.iCloud'
        )
        AND (a.ZAUTHENTICATIONTYPE IS NULL OR a.ZAUTHENTICATIONTYPE != 'parent')
        AND COALESCE(a.ZACTIVE, 1) = 1
    " 2>/dev/null)" || n=0
    # Sanitise to clean integer (drop anything non-digit, cap to 10
    # digits) so a malformed return cannot poison arithmetic compare.
    printf '%s' "${n:-0}" | tr -dc '0-9' | head -c10
}

# Returns the count of CalDAV-capable accounts. iCloud appears via
# AppleAccount top-level. Google / Yahoo / Exchange / direct CalDAV
# all carry CalDAV dataclass.
_accountsdb_count_calendar() {
    local db
    db="$(_accountsdb_path)"
    [[ -f "$db" ]] || { printf '0'; return 0; }
    local n
    n="$(sqlite3 "file:${db}?mode=ro" -bail "
        SELECT COUNT(*) FROM ZACCOUNT a
        JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
        WHERE t.ZIDENTIFIER IN (
            'com.apple.account.CalDAV',
            'com.apple.account.CalDAVLegacy',
            'com.apple.account.Google',
            'com.apple.account.Yahoo',
            'com.apple.account.Exchange',
            'com.apple.account.AppleAccount',
            'com.apple.account.MobileMe',
            'com.apple.account.iCloud',
            'com.apple.account.SubscribedCalendar'
        )
        AND (a.ZAUTHENTICATIONTYPE IS NULL OR a.ZAUTHENTICATIONTYPE != 'parent')
        AND COALESCE(a.ZACTIVE, 1) = 1
    " 2>/dev/null)" || n=0
    printf '%s' "${n:-0}" | tr -dc '0-9' | head -c10
}

# Returns the count of CardDAV-capable accounts. Google / Exchange /
# direct CardDAV cover the rest. iCloud appears via AppleAccount.
_accountsdb_count_contacts() {
    local db
    db="$(_accountsdb_path)"
    [[ -f "$db" ]] || { printf '0'; return 0; }
    local n
    n="$(sqlite3 "file:${db}?mode=ro" -bail "
        SELECT COUNT(*) FROM ZACCOUNT a
        JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
        WHERE t.ZIDENTIFIER IN (
            'com.apple.account.CardDAV',
            'com.apple.account.CardDAVLegacy',
            'com.apple.account.Google',
            'com.apple.account.Yahoo',
            'com.apple.account.Exchange',
            'com.apple.account.AppleAccount',
            'com.apple.account.MobileMe',
            'com.apple.account.iCloud'
        )
        AND (a.ZAUTHENTICATIONTYPE IS NULL OR a.ZAUTHENTICATIONTYPE != 'parent')
        AND COALESCE(a.ZACTIVE, 1) = 1
    " 2>/dev/null)" || n=0
    printf '%s' "${n:-0}" | tr -dc '0-9' | head -c10
}

# ── Local-store population probes ─────────────────────────────────
#
# Returns 0 if the local store has at least one populated artefact,
# 1 otherwise. These probes use existence-of-content checks rather
# than existence-of-directory checks (which the old install.sh
# pre-launch gate used and which mis-classified state-2 macs as
# state-3).

# Mail: any non-zero-byte .emlx, OR a populated Envelope Index.
_store_populated_mail() {
    local v_dir
    v_dir=$(find "${HOME}/Library/Mail" -maxdepth 1 -type d -name 'V[0-9]*' 2>/dev/null | sort -V | tail -1)
    [[ -z "$v_dir" ]] && return 1
    # Any .emlx file in the tree means Mail.app has pulled at least
    # one message. -print -quit short-circuits at the first hit.
    if find "$v_dir" -type f -name '*.emlx' -size +0c -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
    # Fallback: Envelope Index sqlite with rows. The file exists once
    # Mail.app has opened, but it's only populated after first sync.
    local envelope="$v_dir/MailData/Envelope Index"
    if [[ -f "$envelope" ]]; then
        local n
        n="$(sqlite3 "file:${envelope}?mode=ro" -bail \
            "SELECT COUNT(*) FROM messages LIMIT 1" 2>/dev/null || echo 0)"
        n="${n:-0}"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [[ "$n" -gt 0 ]] && return 0
    fi
    return 1
}

# Calendar: Calendar Cache row count > 0 OR any *.calendar dir with a
# .ics file inside. CX-122 (2026-06-01): macOS Sequoia 15.x stores events
# in the Calendar Agent GROUP CONTAINER, not ~/Library/Calendars (that
# legacy path is empty/absent on a clean 15.x box). The prior comment here
# was wrong: it claimed Sequoia writes to ~/Library/Calendars, so this gate
# false-negatived a fully synced calendar (Studio 2026-06-01: 15,472 events
# present, gate said "not synced", hydration skipped). The FDA extractor
# (ostler_fda/calendar.py) reads the Group Container; this gate MUST probe
# the SAME store or it strangles a working extractor. Group Container first,
# then the legacy locations for older macOS.
_store_populated_calendar() {
    local probe_db=""
    local gc_db="${HOME}/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
    [[ -f "$gc_db" ]] && probe_db="$gc_db"

    local cal_dir="${HOME}/Library/Calendars"
    if [[ -z "$probe_db" && -d "$cal_dir" ]]; then
        local cache="$cal_dir/Calendar Cache"
        local sqlitedb="$cal_dir/Calendar.sqlitedb"
        [[ -f "$cache" ]] && probe_db="$cache"
        [[ -z "$probe_db" && -f "$sqlitedb" ]] && probe_db="$sqlitedb"
    fi
    if [[ -n "$probe_db" ]]; then
        local n
        n="$(sqlite3 "file:${probe_db}?mode=ro" -bail \
            "SELECT COUNT(*) FROM CalendarItem LIMIT 1" 2>/dev/null || echo 0)"
        n="${n:-0}"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [[ "$n" -gt 0 ]] && return 0
    fi
    # Fallback: any .ics under any legacy .calendar bundle
    if [[ -d "$cal_dir" ]] && find "$cal_dir" -maxdepth 3 -type f -name '*.ics' -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# Contacts: any non-empty *.abcddb (per-source SQLite store) under
# ~/Library/Application Support/AddressBook/Sources/.
_store_populated_contacts() {
    # CX-107 (DMG #48l, 2026-05-29): switched from byte-size-only probe to
    # row-count probe. The pre-fix path returned true for an empty
    # schema-only abcddb (sqlite creates the file at ~12 KB before any
    # rows exist), so a freshly-signed-in iCloud customer who had not
    # yet opened Contacts.app got mis-classified as state-3 (populated)
    # and the state-2 wait prompt never fired. The new probe attaches
    # ZABCDRECORD read-only and counts >= 1 row before declaring the
    # store populated. Falls back to byte-size when ZABCDRECORD is
    # missing (older macOS variants) so we never wrongly downgrade a
    # populated mac to state-2.
    local src_dir="${HOME}/Library/Application Support/AddressBook/Sources"
    [[ -d "$src_dir" ]] || return 1
    local db
    db="$(find "$src_dir" -name 'AddressBook-v22.abcddb' -size +0c -print -quit 2>/dev/null)"
    if [[ -z "$db" ]]; then
        db="$(find "$src_dir" -name '*.abcddb' -size +0c -print -quit 2>/dev/null)"
    fi
    [[ -z "$db" ]] && return 1
    local n
    n="$(sqlite3 "file:${db}?mode=ro" -bail \
        "SELECT COUNT(*) FROM ZABCDRECORD LIMIT 1" 2>/dev/null || echo "")"
    if [[ -n "$n" ]] && [[ "$n" =~ ^[0-9]+$ ]]; then
        [[ "$n" -gt 0 ]] && return 0
        return 1
    fi
    # ZABCDRECORD missing -- older macOS. Fall back to the byte-size
    # probe (which only mis-fires on Sequoia-style empty schemas).
    return 0
}

# ── Wait-for-populate helper (state-2 prompt) ────────────────────
#
# Emits a state-2 wait prompt for a given source. The customer is
# asked to open the relevant Apple app; the installer then polls the
# local-store probe for up to OSTLER_HYDRATE_POPULATE_WAIT_S seconds
# (default 60). If the customer clicks Continue early the wait
# unblocks immediately. If the timeout expires with no population,
# falls through with a "We didn't detect sync" info line and the
# hydrate step proceeds best-effort.
#
# Args:
#   $1 source slug ("mail" | "calendar" | "contacts")
#   $2 displayed app name ("Apple Mail" | "Calendar" | "Contacts")
#   $3 system-settings deep-link (optional, opens Internet Accounts
#      or the app itself)
#   $4 prompt title key (catalogue-keyed)
#   $5 prompt help key (catalogue-keyed)
#
# Returns 0 if the local store became populated during the wait,
# 1 if the timeout expired without population.
_three_state_wait_for_populate() {
    local source="$1"
    local app_name="$2"
    local app_deeplink="$3"
    local title_str="$4"
    local help_str="$5"

    # CX-108 (DMG #48l, 2026-05-29): default wait bumped from 60s to
    # 180s. Studio retest of DMG #48k showed 60s expired before iCloud
    # finished a fresh Calendar sync (sync took ~70-80s on Andy's box
    # with 5 years of events). 180s covers the vast majority of fresh
    # syncs; customers on slow uplinks can extend further via the env
    # var. Still bounded -- we will not block the install indefinitely.
    # Same value used for Contacts state-2 wait now CX-107 lets the
    # probe fire honestly.
    local timeout_s="${OSTLER_HYDRATE_POPULATE_WAIT_S:-180}"
    local poll_interval_s="${OSTLER_HYDRATE_POPULATE_POLL_S:-3}"

    # Offer to open the app for them. If they say no, still poll --
    # they might open it themselves.
    local open_app_answer
    open_app_answer="$(gui_read \
        "$title_str" \
        yesno \
        "y" \
        "$help_str" \
        "" \
        "open_${source}_to_populate")"

    case "${open_app_answer:-y}" in
        y|Y|yes|YES|Yes)
            if [[ -n "$app_deeplink" ]]; then
                open "$app_deeplink" 2>/dev/null || true
            else
                open -a "$app_name" 2>/dev/null || true
            fi
            ;;
        *)
            # Customer declined. Skip the wait entirely; state-2
            # stays unresolved and the hydrate step records an
            # accurate "not populated yet" status. Doctor follows
            # up later.
            return 1
            ;;
    esac

    # Poll the local-store probe. Time-cap at $timeout_s.
    # CX-108 (DMG #48l, 2026-05-29): emit a progress heartbeat every
    # 30s so the customer sees something during the longer 180s wait.
    # Without this the GUI sidebar sits silent for three minutes and
    # the customer assumes the installer has hung.
    local elapsed=0
    local probe_fn="_store_populated_${source}"
    info "$(printf "$MSG_INFO_WAITING_FOR_APP_TO_POPULATE" "${app_name}" "${timeout_s}")"
    local next_heartbeat=30
    while [[ "$elapsed" -lt "$timeout_s" ]]; do
        if "$probe_fn"; then
            ok "$(printf "$MSG_OK_APP_HAS_POPULATED" "${app_name}")"
            return 0
        fi
        sleep "$poll_interval_s"
        elapsed=$((elapsed + poll_interval_s))
        if [[ "$elapsed" -ge "$next_heartbeat" ]] && [[ "$elapsed" -lt "$timeout_s" ]]; then
            local remaining=$((timeout_s - elapsed))
            info "$(printf "$MSG_INFO_WAITING_FOR_APP_HEARTBEAT" \
                "${app_name}" "${elapsed}" "${remaining}")"
            next_heartbeat=$((next_heartbeat + 30))
        fi
    done

    # Timeout. Surface a graceful fallback, install continues.
    info "$(printf "$MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING" "${app_name}")"
    return 1
}

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

# Record the wall-clock start of the prereq_check phase so we can
# enforce a minimum dwell time at the end of the section. Studio
# retest #3 (2026-05-22) flagged that on a fast Mac the
# "Checking your Mac" row flashes past in <1 second, leaving the
# customer with no time to read what the installer is verifying.
# We emit per-item PCT markers below so the GUI can show ticks
# accumulate (RAM ✓, CPU ✓, macOS ✓, disk ✓) and then pad the tail
# of the phase to a minimum 1.5 s if all checks finish faster
# (controlled by PREREQ_MIN_DWELL_S below; tests can override via
# the env var to keep test runs snappy).
PREREQ_CHECK_START=$(date +%s)
PREREQ_MIN_DWELL_S="${PREREQ_MIN_DWELL_S:-2}"

# Initial PCT=5 so the progress bar shows it has started doing
# something before the macOS-version probe completes. Pure cosmetic
# but eliminates the "frozen at 0" first impression on really slow
# disks (rare but seen on a cold SSD spin-up).
gui_emit PCT "step=prereq_check" "pct=5"

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
    fail_with_code "ERR-02-MACOS-LINUX-ONLY" "$MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT"
fi
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
ok "$(printf "$MSG_OK_MACOS_DETECTED" "${MACOS_VERSION}")"

# Minimum macOS 13 (Ventura) -- needed for modern Docker, Ollama, and security features
if [[ $MACOS_MAJOR -lt 13 ]]; then
    warn "$(printf "$MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13" "${MACOS_VERSION}")"
    warn "$MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY"
fi
gui_emit PCT "step=prereq_check" "pct=20"

# Xcode Command Line Tools -- needed for git, make, and as a hard
# prereq for Homebrew (which the install phase invokes later).
#
# CX-21 (2026-05-23): the previous check used `command -v git`, which
# is fatally wrong on a fresh macOS install. Apple ships /usr/bin/git
# as a stub that exists IN PATH whether or not CLT is installed --
# when CLT is missing, invoking it triggers the macOS "Install
# Command Line Tools" GUI dialog and exits non-zero. So `command -v
# git` always returned true and the install block was silently
# skipped. Robust check: /usr/bin/xcode-select -p (exit 0 only when
# CLT is actually installed).
#
# CX-22 (2026-05-23): also do NOT block here on the install. CLT
# download is 5-10 minutes; making the customer wait BEFORE the
# questions phase means 5-10 idle minutes staring at a "checking
# prerequisites" screen. Instead, trigger the install dialog here
# and proceed immediately to the questions phase. CLT downloads in
# the background WHILE the customer answers the questions (which
# also takes ~5 min). The wait-for-CLT loop has moved to the top of
# the homebrew_install step (lower in this script), where it only
# fires if CLT is still finishing.
CLT_INSTALL_TRIGGERED=false
if ! /usr/bin/xcode-select -p &>/dev/null; then
    info "$MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND"
    /usr/bin/xcode-select --install 2>/dev/null || true

    # CX-23 (2026-05-24): macOS's CLT install dialog appears BEHIND
    # the OstlerInstaller window on a fresh-Mac install (unlike TCC
    # and admin dialogs which auto-focus to front). Andy retest #17
    # missed the dialog entirely and the install timed out at the
    # homebrew_install wait. Layered fix below -- any one of the
    # three paths bringing the dialog forward is enough.
    #
    # Give macOS a moment to launch the CLT installer process before
    # we try to activate it.
    sleep 1

    # Path 1: AppleScript-driven activation. Requires the process to
    # exist; the `2>/dev/null || true` makes us tolerant of cases
    # where xcode-select silently no-ops (e.g., a previous install
    # already in progress).
    osascript -e 'tell application "System Events" to tell process "Install Command Line Developer Tools" to set frontmost to true' 2>/dev/null || true

    # Path 2: macOS's `open -a` is the standard way to bring an app
    # to the front. The CLT installer's .app lives at the canonical
    # CoreServices path on every modern macOS.
    open "/System/Library/CoreServices/Install Command Line Developer Tools.app" 2>/dev/null || true

    CLT_INSTALL_TRIGGERED=true
    ok "$MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND"

    # CX-54 (DMG #30, 2026-05-24) + CX-71 (DMG #44, 2026-05-25):
    # customers consistently miss that they can continue answering
    # installer questions while macOS's CLT installer downloads in
    # the background. CX-54 added a single bounce-back; Studio
    # retest of DMG #43 found that after the customer clicks Install
    # on the CLT prompt, macOS's Software Update download-progress
    # window steals focus again ~10-30 s later, leaving customers
    # staring at it. CX-71 extends the single bounce to a polling
    # loop: re-activate OstlerInstaller every 4 s for up to 60 s OR
    # until the CLT installer process is gone (download finished
    # OR customer cancelled). Subshell + disown so install.sh main
    # thread proceeds to the questions phase immediately.
    if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
        info "$MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND"
        (
            sleep 4
            _focus_loop_cap=15  # 15 iterations x 4 s = 60 s
            for _focus_iter in $(seq 1 $_focus_loop_cap); do
                # Stop looping if the CLT installer is no longer
                # running -- either it finished its download or the
                # customer dismissed it. No point bouncing focus
                # against a window that does not exist.
                if ! pgrep -f "Install Command Line Developer Tools" >/dev/null 2>&1; then
                    break
                fi
                osascript -e 'tell application "OstlerInstaller" to activate' 2>/dev/null || \
                    open -a "OstlerInstaller" 2>/dev/null || true
                sleep 4
            done
        ) &
        disown 2>/dev/null || true
    fi
else
    ok "$MSG_OK_GIT_AVAILABLE"
fi
export CLT_INSTALL_TRIGGERED
gui_emit PCT "step=prereq_check" "pct=35"

# Apple Silicon check.
#
# CX-19 (2026-05-23): bundled Python (python-build-standalone) is the
# Apple Silicon (arm64) build for v1.0. Intel Mac support is deferred
# to v1.0.1 -- the same upstream releases ship x86_64-apple-darwin
# binaries, but Intel Macs were never a primary launch target and we
# don't have a clean retest path on Intel hardware before launch.
# Hard-fail honestly here so the customer sees a clear message rather
# than an opaque downstream failure when the bundled python3.11 cannot
# execute on x86_64.
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "$MSG_OK_APPLE_SILICON_DETECTED"
else
    fail_with_code "ERR-01-ARCH-INTEL-NOT-SUPPORTED" "$MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0"
fi
gui_emit PCT "step=prereq_check" "pct=50"

# RAM check
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [[ $RAM_GB -lt 16 ]]; then
    fail_with_code "ERR-02-PREREQ-RAM-LOW" "$(printf "$MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED" "${RAM_GB}")"
elif [[ $RAM_GB -lt 24 ]]; then
    warn "$(printf "$MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS" "${RAM_GB}")"
else
    ok "$(printf "$MSG_OK_GB_RAM_DETECTED" "${RAM_GB}")"
fi
gui_emit PCT "step=prereq_check" "pct=70"

# Disk space check -- need ~35 GB: Docker images (~1 GB), AI model (5-10 GB),
# embedding model (300 MB), import pipeline + venv (~500 MB), databases (grows
# with data), and headroom for GDPR exports.
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
if [[ $FREE_GB -lt 35 ]]; then
    warn "$(printf "$MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST" "${FREE_GB}")"
    if [[ $FREE_GB -lt 15 ]]; then
        fail_with_code "ERR-02-PREREQ-DISK-LOW" "$(printf "$MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE" "${FREE_GB}")"
    fi
else
    ok "$(printf "$MSG_OK_GB_FREE_DISK_SPACE" "${FREE_GB}")"
fi
gui_emit PCT "step=prereq_check" "pct=85"

# Power source check. On a MacBook, Phase 3 runs ~15-60 minutes of
# continuous Docker pulls, Ollama model downloads and history
# backfill (the upper end on a Mac with years of mail / messages).
# The hub power
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
gui_emit PCT "step=prereq_check" "pct=100"

# Minimum-dwell pad for the prereq_check phase. On a fast Mac with
# warm caches, the section above completes in ~250 ms which leaves
# the GUI sidebar tick + the "Checking your Mac" row no time to
# settle in the customer's visual field before the next row takes
# over. Studio retest #3 (2026-05-22) flagged this. Pad to a minimum
# of PREREQ_MIN_DWELL_S seconds, calculated against the wall-clock
# start time captured before the licence/macOS/git/arch/RAM/disk
# probes ran. Test runs and CI override via env to keep the suite
# snappy (PREREQ_MIN_DWELL_S=0).
if [[ "${OSTLER_GUI:-0}" == "1" ]] && [[ "${PREREQ_MIN_DWELL_S}" -gt 0 ]]; then
    PREREQ_CHECK_END=$(date +%s)
    PREREQ_CHECK_ELAPSED=$(( PREREQ_CHECK_END - PREREQ_CHECK_START ))
    if (( PREREQ_CHECK_ELAPSED < PREREQ_MIN_DWELL_S )); then
        sleep "$(( PREREQ_MIN_DWELL_S - PREREQ_CHECK_ELAPSED ))"
    fi
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

# ── CX-98 (DMG #48h, 2026-05-29): unconditional Phase-2 defaults ──
#
# Every variable assigned ONLY inside the SKIP_PHASE2=false block
# below (line ~1521 to ~2642) AND read AFTER that block is a
# latent set -u bomb when reuse_settings=yes. The Studio retest of
# DMG #48h tripped CHANNEL_IMESSAGE_ENABLED at line ~4823
# (config_save TOML writer) because the user took the reuse path
# and the channels-questions block (which holds the initialiser
# at line ~2099) never ran.
#
# Andy on the DMG #48h retest log:
#   /Applications/OstlerInstaller.app/Contents/Resources/install.sh:
#     line 4823: CHANNEL_IMESSAGE_ENABLED: unbound variable
#
# Defend by initialising every "read outside / assigned inside"
# variable HERE, before the reuse/skip branch is taken. The
# questions block at line ~2099 overwrites these defaults when
# walked; on the reuse path the defaults persist and the TOML
# writer correctly emits NO [channels] section (which matches
# Phase-2-was-never-walked: no channels configured yet).
#
# See feedback memory: writer-reader-contracts-can-silent-fail.
# Audit shape per silent-bail-regression-test-shape: walk the
# config-writer block byte-by-byte under set -u and assert no
# unbound-variable trips. See tests/test_cx98_*.sh.

# Channel flags + per-channel fields. Drives the [channels.*]
# emitter at lines ~4823-4928 and the welcome-screen rendering
# at lines ~10647 + ~11131-11144 + ~11165.
CHANNEL_CHOICE=""
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
CHANNEL_EMAIL_APPLE_MAIL_ENABLED=false
CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=false
WA_CONSENT=""

# Consent decisions (CX-126). Same CX-98 class as the CHANNEL_* flags
# above: these three are assigned ONLY inside the Phase-2 consent screen
# (the "── 10. Consent ──" section ~line 3936, inside the second
# SKIP_PHASE2==false block) and read again in Phase 3 on the always-run
# path -- the conversation-feed block dereferences
# OSTLER_CONSENT_THIRD_PARTY_DECISION at the email body feed (~8832) and
# the iMessage body feed (~8853). On the reuse path (SKIP_PHASE2=true)
# the consent screen never runs, so without this hoist `set -u` aborts
# the install right after email-ingest -- exactly what the Studio
# clean-wipe reuse run hit (step 19/34, then dead, GUI false-green).
# Hoisting the empty-string defaults here makes the reuse path skip the
# body feeds (the safe default for a third-party-data gate: never start
# ingesting other people's message bodies on a re-run without a
# re-confirmed consent). The walk path still overwrites these in the
# consent screen; the persist block inside the same Phase-2 region is
# unaffected on reuse.
OSTLER_CONSENT_ARTICLE_9_DECISION=""
OSTLER_CONSENT_VOICE_EU_DECISION=""
OSTLER_CONSENT_THIRD_PARTY_DECISION=""

# Region + ISO + source. Read at line ~3498 (EU branch entry),
# ~5265 (region-persist Python heredoc), ~5300 (consent_cli
# --region arg). Originally assigned at lines 1952-2008 inside
# the wrap. Defaults match the "default_eu" fallback at line
# 2004-2005 so the EU branch lights up by default -- which is
# the safer side to err on for GDPR consent recording.
OSTLER_REGION="eu"
OSTLER_REGION_ISO="ZZ"
OSTLER_REGION_SOURCE="default_eu"

# Re-run detection: if config exists from a prior COMPLETE install,
# offer to skip Phase 2 entirely.
#
# CX-87 (DMG #48g, 2026-05-29): probe the FINAL location
# ${OSTLER_FINAL_DIR}/config/.env -- NOT ${CONFIG_DIR}/.env which
# now points at the per-PID staging tree and is empty on every
# fresh process. The previous probe shape would silently fail to
# detect a prior install (always-false) AND, prior to the staging
# tree fix, silently TRIGGER on a half-populated pre-FDA staging
# state from the same process (which is the bug that produced the
# auto-bail after config_save).
#
# CX-98 (DMG #48h+1, 2026-05-29): tighten the trigger further by
# requiring the .env to contain a real USER_ID= line, not just
# exist. A partial / truncated .env from a crashed prior install
# could otherwise mis-trigger reuse, and the customer would get a
# half-populated config with no Phase-2 walk to repair it. The
# pre-FDA licence write at ${OSTLER_FINAL_DIR}/license/license.json
# does NOT trigger reuse on its own; the config writer at line
# ~4525 is the only path that writes the .env and it writes
# USER_ID="..." as its first non-comment line.
SKIP_PHASE2=false
FV_ENABLED=false
# CX-123 (#643): belt-and-braces. Initialise the summary's OPTIONAL display
# vars to safe defaults UNCONDITIONALLY here, so they are set on EVERY path
# (fresh install + reuse), not only the path that happens to assign them.
# The real conditional assignments below / later still override on their
# own path; these just guarantee the final-summary recap never sees an
# unset value. (The recap is also wrapped in set +u/-u as the primary
# guard; this keeps the printed recap sensible rather than blank.)
CONTACT_COUNT=0
EXPORTS_DIR=""
WIKI_FIRST_COMPILE_OK=false
IMESSAGE_TCC_STATUS=""
VANE_OK=false
if [[ -f "${OSTLER_FINAL_DIR}/config/.env" ]] \
   && grep -q '^USER_ID=' "${OSTLER_FINAL_DIR}/config/.env" 2>/dev/null; then
    ok "$MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG"
    # Source existing config from the canonical location.
    set -a; source "${OSTLER_FINAL_DIR}/config/.env"; set +a
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
    if [[ -f "${OSTLER_FINAL_DIR}/imports/icloud-contacts.vcf" ]]; then
        EXPORTS_DIR="${OSTLER_FINAL_DIR}/imports"
    fi
    SKIP_PHASE2=true

    echo ""
    echo "  User:       ${USER_NAME} (${USER_ID})"
    echo "  Assistant:  ${ASSISTANT_NAME}"
    echo "  Timezone:   ${USER_TZ}"
    echo ""
    # CX-96 (DMG #48g+1, 2026-05-29): the reuse-settings prompt landed
    # bare ("Continue with these settings?") with no explanation that
    # the customer's previous answers (name / assistant / timezone /
    # country code / channels / etc.) will be auto-reused. Andy on the
    # DMG #48g Studio retest: "the user will get pissed off when it
    # reopens and they *appear* to be doing the same stuff over again
    # -- we need to be more upfront that the previous answers will be
    # used". Build a help body that combines the static explainer copy
    # with a one-line summary of the three values install.sh has
    # already restored from ${OSTLER_FINAL_DIR}/config/.env so the
    # customer can see at a glance what is about to be reused.
    _reuse_summary="$(printf "$MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT" \
        "${USER_NAME}" \
        "${ASSISTANT_NAME}" \
        "${USER_TZ}")"
    _reuse_help="${MSG_PROMPT_REUSE_SETTINGS_HELP}

${_reuse_summary}"
    REUSE="$(gui_read "$MSG_PROMPT_REUSE_SETTINGS_TITLE" yesno "y" "$_reuse_help" "" "reuse_settings")"
    unset _reuse_summary _reuse_help
    # CX-87 (DMG #48g, 2026-05-29): an empty REUSE answer is treated
    # as "n" (walk Phase 2 fresh), NOT "y". Pre-fix, the default
    # branched the other way: ${REUSE:-y} fell through to "y" when
    # the FIFO closed mid-prompt (which is exactly what happens
    # when macOS fires the FDA Quit & Reopen flow part-way through
    # the questions phase, ripping the prompt-pipe out from under
    # gui_read). The fall-through silently SKIP_PHASE2=true'd and
    # the install bailed after the config_save step. Forcing
    # explicit "y" before we reuse means an empty / pipe-closed
    # answer always walks the questions, which is the safer
    # default: re-typing settings beats a half-installed Ostler.
    case "${REUSE:-}" in
        y|Y|yes|Yes|YES)
            SKIP_PHASE2=true
            ;;
        *)
            SKIP_PHASE2=false
            ;;
    esac
    # CX-87 (DMG #48g, 2026-05-29): when re-running on a Mac with a
    # prior complete install, promote the staging tree onto
    # ~/.ostler/ immediately. There is no Quit & Reopen risk on a
    # re-run (FDA was granted on the previous install and the TCC
    # entry survives), so the staging-tree-for-pre-FDA-writes
    # scaffold isn't needed. The promote function is idempotent on
    # an empty staging tree.
    if [[ "$SKIP_PHASE2" == "true" ]]; then
        _ostler_promote_prelaunch_tree
    fi
fi

if [[ "$SKIP_PHASE2" == false ]]; then

step "$MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK" "setup_questions"

# CX-DMG44 (DMG #44, 2026-05-25): upfront briefing on the full set
# of permission prompts the customer will see during install. The
# previous block listed three high-level categories which understated
# what actually fires: nine to ten macOS popups across pre-warm + FDA
# assist + iMessage Automation, sometimes back-to-back. Customers
# felt ambushed mid-install. Enumerating up-front lets them
# anticipate and accept rather than panic.
#
# Permission inventory (kept in sync with the actual install flow --
# update this comment + the printed list together when the prompt
# count changes):
#   1. Contacts                       (line ~1140 contact-card read)
#   2. Calendar                       (CX-69 pre-warm, line ~1117)
#   3. Reminders                      (CX-46 pre-warm, existing)
#   4. Downloads folder               (CX-70 pre-warm)
#   5. Desktop folder                 (CX-70 pre-warm)
#   6. Documents folder               (CX-70 pre-warm)
#   7. Full Disk Access -- installer  (FDA-only data sources)
#   8. Full Disk Access -- daemon     (CX-60 ostler-assistant chat.db)
#   9. iMessage Automation            (CX-55 if iMessage channel enabled)
#  10. macOS admin password           (sudo for Homebrew, sleep-disable)
# Plus, on a fresh Mac: the Xcode CLT installer dialog (not a TCC
# permission per se, but customer-visible).
PERMISSIONS_TOTAL=10
gui_emit STEP "name=permissions_briefing" "total_permissions=${PERMISSIONS_TOTAL}"

echo ""
echo -e "  ${BOLD}What Ostler needs from your Mac${NC}"
echo ""
echo "  During the install you will see around ${PERMISSIONS_TOTAL} macOS"
echo "  permission popups. They come from macOS itself, not from us."
echo "  Each looks like a small system dialog asking you to allow"
echo "  access to a specific thing. We'll label each one before it"
echo "  appears so you know what to expect."
echo ""
echo "  Required (Ostler will not work without these):"
echo ""
echo -e "    1. ${BOLD}Contacts${NC}              Your name + your address book"
echo -e "    2. ${BOLD}Calendar${NC}              Meetings + events in your graph"
echo -e "    3. ${BOLD}Reminders${NC}             Tasks in your graph"
echo -e "    4-6. ${BOLD}Downloads/Desktop/Documents${NC}    Find data exports"
echo -e "    7. ${BOLD}Full Disk Access (installer)${NC}     Read Safari, Notes etc. (asked now, upfront)"
echo -e "    8. ${BOLD}Full Disk Access (daemon)${NC}        Read iMessage history (asked near the end)"
echo -e "    9. ${BOLD}Messages automation${NC}    Send + receive iMessages as you (asked now, upfront)"
echo -e "    10. ${BOLD}macOS admin password${NC}            One-off for Homebrew + sleep"
echo ""
echo "  Plus, on a fresh Mac, a Command Line Tools installer dialog"
echo "  from Apple (Xcode); these are downloaded in the background"
echo "  so you can keep answering the install questions."
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
    gui_cancelled   # CX-126: neutral cancelled terminal, not a failure
    exit 0
fi

echo ""

# CX-69 (DMG #44, 2026-05-25): Calendar AppleScript permission
# pre-warm. Later in install (Phase 4 daemon startup + CM048 event
# extractor) we read calendars via osascript, which fires macOS's
# Calendar permission prompt for the installer's TCC posture. If
# that prompt fires mid-install, the customer is deep in spinner
# territory and misses it. Move the prompt forward to right after
# PERMS_OK by running a no-op count probe -- the probe value is
# discarded, the side-effect is the TCC prompt landing in the
# attention window.
#
# Stderr goes to /dev/null; we don't fail install if the probe is
# denied. The Calendar functionality fails gracefully downstream
# (CM048 extractor logs an empty-calendar warning, doesn't crash).
if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    info "$MSG_INFO_CALENDAR_PERMISSION_PREWARM"
fi
osascript -e 'tell application "Calendar" to count calendars' >/dev/null 2>&1 || true

# FDA_PREWARM (#572, 2026-06-09; refined 2026-06-13): register
# OstlerInstaller in the System Settings > Full Disk Access list early by
# attempting a read of an FDA-gated database. macOS only lists an app in
# that pane once it has ATTEMPTED an FDA-protected read.
#
# 2026-06-13 (.149 walk): the original list ALSO prewarmed
# ~/Library/Messages/chat.db and the Mail Envelope Index, on the comment's
# assumption that FDA reads are "silent, no popup". That is FALSE on
# current macOS -- reading chat.db fires the "Allow Ostler to read your
# messages" TCC dialog. Prewarming them HERE popped that dialog ~30s into
# the install, decoupled from the in-context FDA guidance and against a
# pane that did not yet show the entry. So Messages/Mail are deliberately
# NOT prewarmed here any more: the in-context FDA probe
# (FDA_ASSIST_TRIGGER, ~line 6491) reads them just before the grant
# assist, which already refreshes the System Settings pane
# (FDA_PANE_REFRESH, ~line 6580) -- so the dialog now fires where the
# guidance is, and the entry is present when the pane opens. Safari
# History.db reads silently and stays, keeping the Files entry warm for
# the common case. Best-effort: never fails the install.
if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    # Safari only -- chat.db / Mail are NOT prewarmed here because their
    # reads fire a user-facing TCC dialog (see note above). They are read
    # in context at the FDA probe + assist downstream.
    _fda_prime="$HOME/Library/Safari/History.db"
    [[ -e "$_fda_prime" ]] && head -c 1 "$_fda_prime" >/dev/null 2>&1 || true
    unset _fda_prime
fi

# ── 9-fda. Full Disk Access (installer) -- hoisted upfront (WALK-1 / Wave 2.1) ──
#
# WALK-1 (2026-06-19, Andy's live walk): the installer Full Disk Access
# grant dialog used to fire deep in the Phase-3 fda_extract step (~the
# 86% point), breaking the locked "answer the questions upfront, then
# walk away" promise -- a customer who left the install running came
# back to a blocking FDA grant modal mid-run.
#
# Fix: lift-and-shift the installer FDA grant assist HERE, into the
# Phase-2 questions block, right after the permissions briefing
# (PERMS_OK) and the Safari FDA_PREWARM above, and BEFORE the me-card
# read -- so the FDA toggle and any macOS "Quit & Reopen" relaunch
# happen before the customer has typed any answers. This mirrors the
# CX-37 / CX-130 Apple Mail hoist and the Wave 2.1 Tailscale decision
# hoist (TAILSCALE_CONFIRM_SHOWN_EARLY). The late fda_extract site
# (search "INSTALLER_FDA_SHOWN_EARLY") becomes a guarded fallback plus
# an UNCONDITIONAL re-probe, so a deferred / declined / relaunch-settled
# grant is always recovered before the extractor runs, never silently
# skipped.
#
# Honest limits (do NOT over-claim):
#   * No auto-grant. macOS requires the human to toggle the app in
#     System Settings; we open the pane, pre-warm the entry, present a
#     blocking modal and re-probe -- the ceiling, same as the proven
#     late assist this lifts.
#   * The grant path is pure bash + osascript + `head -c 1`; it does NOT
#     need the Python venv or the FDA module (both established later), so
#     hoisting it above encrypt_db / the module copy is safe (spec 1.3).
#   * Promotion of the pre-FDA staging tree stays LATE (the late
#     fda_extract catch-all). We do NOT promote here -- promoting in
#     Phase 2 would populate ~/.ostler/ before a later abort and re-trip
#     the CX-87 Phase-2-skip bug. The early block only sets FDA_GRANTED
#     plus the INSTALLER_FDA_SHOWN_EARLY guard.
#   * The DAEMON FDA grant (ai.ostler.assistant) CANNOT be front-loaded
#     -- its binary does not exist until late Phase 3. It is pre-announced
#     in the briefing copy above and granted late; we do not claim "zero
#     late prompts".
if [[ -z "${INSTALLER_FDA_SHOWN_EARLY:-}" && "${OSTLER_GUI:-0}" == "1" ]]; then
    # Honest read-probe (same shape as the late fda_extract probe): a
    # first-byte read of an FDA-gated SQLite DB. macOS TCC denies open()
    # on these without FDA, so `head -c 1` exits non-zero on denial --
    # unlike `[[ -r ]]` / `ls` which only check directory-entry perms
    # (the DMG #48c false-positive trap).
    _fda_read_probe_early() {
        [[ -e "$1" ]] && head -c 1 "$1" >/dev/null 2>&1
    }
    INSTALLER_FDA_PROBE_PATHS_EARLY=(
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Messages/chat.db"
        "$HOME/Library/Mail/V10/MailData/Envelope Index"
    )
    _fda_early_tried=0
    _fda_early_ok=0
    for probe in "${INSTALLER_FDA_PROBE_PATHS_EARLY[@]}"; do
        [[ -e "$probe" ]] || continue
        _fda_early_tried=$((_fda_early_tried + 1))
        if _fda_read_probe_early "$probe"; then
            _fda_early_ok=$((_fda_early_ok + 1))
        fi
    done
    # Conservative posture: only believe FDA is granted when at least one
    # probe ran AND every attempted probe succeeded. No probe path exists
    # (clean Mac, no Safari / Messages / Mail ever opened) -> default
    # false so the assist fires once; a spurious prompt is recoverable,
    # missing extraction is not.
    if [[ $_fda_early_tried -gt 0 && $_fda_early_ok -eq $_fda_early_tried ]]; then
        FDA_GRANTED=true
    else
        FDA_GRANTED=false
    fi

    if [[ "$FDA_GRANTED" == false ]]; then
        warn "$MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL"
        warn "$MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM"

        # Pre-warn modal (CX-87 shape). The crucial guidance is the
        # "Quit & Reopen" hint -- macOS fires that dialog straight after
        # the customer toggles FDA on for OstlerInstaller.app, and a
        # click on Later silently breaks the grant for this process. The
        # CX-87 pre-launch staging tree (OSTLER_PRELAUNCH_DIR) keeps
        # ~/.ostler/ empty until the late promote, so a Quit & Reopen
        # here relaunches into a clean Phase 2 (no auto-skip).
        info "$MSG_INFO_INSTALLER_FDA_PREWARN"
        _prewarn_msg="$(printf '%s\n\n%s\n\n%s' \
            "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1" \
            "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2" \
            "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3")"
        _prewarn_msg_esc="${_prewarn_msg//\"/\\\"}"
        _prewarn_title_esc="${MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE//\"/\\\"}"
        _prewarn_button_esc="${MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON//\"/\\\"}"
        _prewarn_icon_path=""
        if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
            _prewarn_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
        elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
            _prewarn_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
        elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
            _prewarn_icon_path="${SCRIPT_DIR}/AppIcon.icns"
        elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
            _prewarn_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
        fi
        if [[ -n "$_prewarn_icon_path" ]]; then
            _prewarn_icon_path_esc="${_prewarn_icon_path//\"/\\\"}"
            _prewarn_icon_clause="with icon file POSIX file \"${_prewarn_icon_path_esc}\""
        else
            _prewarn_icon_clause="with icon note"
        fi
        osascript \
            -e 'tell application "System Events" to activate' \
            -e "tell application \"System Events\" to display dialog \"${_prewarn_msg_esc}\" with title \"${_prewarn_title_esc}\" buttons {\"${_prewarn_button_esc}\"} default button \"${_prewarn_button_esc}\" ${_prewarn_icon_clause}" \
            >/dev/null 2>&1 || true
        unset _prewarn_msg _prewarn_msg_esc _prewarn_title_esc \
              _prewarn_button_esc _prewarn_icon_path \
              _prewarn_icon_path_esc _prewarn_icon_clause

        info "$MSG_INFO_INSTALLER_FDA_ASSIST_OPENING"
        # FDA_PANE_REFRESH (#572, 2026-06-09): force a fresh System
        # Settings load before pointing the customer at the FDA pane. A
        # Settings window left open from an earlier prompt can show a
        # STALE Full Disk Access list that predates the OstlerInstaller
        # entry primed at install start -- killall + reopen guarantees the
        # list is current. Kept VERBATIM from the late assist; the #279
        # race fix is reused unchanged. Best-effort.
        killall "System Settings" >/dev/null 2>&1 || true
        killall "System Preferences" >/dev/null 2>&1 || true
        sleep 1
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

        _installer_fda_msg="$(printf '%s\n\n%s\n%s' \
            "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1" \
            "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2" \
            "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3")"
        _installer_fda_msg_esc="${_installer_fda_msg//\"/\\\"}"
        _installer_fda_title_esc="${MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE//\"/\\\"}"
        _installer_fda_button_esc="${MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON//\"/\\\"}"

        _installer_fda_icon_path=""
        if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
            _installer_fda_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
        elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
            _installer_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
        elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
            _installer_fda_icon_path="${SCRIPT_DIR}/AppIcon.icns"
        elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
            _installer_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
        fi
        if [[ -n "$_installer_fda_icon_path" ]]; then
            _installer_fda_icon_path_esc="${_installer_fda_icon_path//\"/\\\"}"
            _installer_fda_icon_clause="with icon file POSIX file \"${_installer_fda_icon_path_esc}\""
        else
            _installer_fda_icon_clause="with icon note"
        fi

        # Pause briefly to let System Settings finish its window animation
        # before raising the modal, then activate + display so the dialog
        # renders in front of Settings (#279 z-order fix, kept verbatim).
        sleep 1
        osascript \
            -e 'tell application "System Events" to activate' \
            -e "tell application \"System Events\" to display dialog \"${_installer_fda_msg_esc}\" with title \"${_installer_fda_title_esc}\" buttons {\"${_installer_fda_button_esc}\"} default button \"${_installer_fda_button_esc}\" ${_installer_fda_icon_clause}" \
            >/dev/null 2>&1 || true
        unset _installer_fda_msg _installer_fda_msg_esc \
              _installer_fda_title_esc _installer_fda_button_esc \
              _installer_fda_icon_path _installer_fda_icon_path_esc \
              _installer_fda_icon_clause

        # Re-probe: macOS refreshes the TCC posture for the caller binary
        # as soon as the user toggles it on, so a direct read returns the
        # live state without re-exec. Same honest read-probe so a false
        # positive cannot creep back in.
        sleep 2
        _fda_early_retried=0
        _fda_early_reok=0
        for probe in "${INSTALLER_FDA_PROBE_PATHS_EARLY[@]}"; do
            [[ -e "$probe" ]] || continue
            _fda_early_retried=$((_fda_early_retried + 1))
            if _fda_read_probe_early "$probe"; then
                _fda_early_reok=$((_fda_early_reok + 1))
            fi
        done
        if [[ $_fda_early_retried -gt 0 && $_fda_early_reok -eq $_fda_early_retried ]]; then
            FDA_GRANTED=true
        fi
        if [[ "$FDA_GRANTED" == true ]]; then
            info "$MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED"
        else
            info "$MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED"
        fi
        unset _fda_early_retried _fda_early_reok
    fi
    unset _fda_early_tried _fda_early_ok

    # Mark the upfront grant as shown so the late fda_extract site runs
    # as a guarded fallback (assist suppressed) but ALWAYS re-probes.
    # Promotion of the staging tree deliberately does NOT happen here
    # (spec 3.4) -- it stays at the late catch-all.
    INSTALLER_FDA_SHOWN_EARLY=1
    export INSTALLER_FDA_SHOWN_EARLY FDA_GRANTED

    # WALK-1 (Wave 2.1): now that the installer FDA grant is behind us at
    # the START, reassure the customer that the long middle is unattended,
    # and PRE-ANNOUNCE the one genuinely-late permission we cannot
    # front-load: the DAEMON Full Disk Access (Messages history for the
    # assistant). Its binary (ai.ostler.assistant) does not exist until
    # late Phase 3, so its TCC grant cannot be hoisted -- we flag it here
    # exactly as the Tailscale sign-in step is pre-announced, so it is
    # expected rather than a surprise. We do NOT claim "zero late prompts".
    info "$MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE"
    info "$MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE"
fi

# ── Auto-detect from macOS contact card ────────────────────────────

DETECTED_NAME=""
DETECTED_FIRST=""
DETECTED_COUNTRY=""
DETECTED_EMAIL=""
DETECTED_PHONE=""

# Auto-detect the customer's name/country/email/phone from their macOS
# "my card" in Contacts, to pre-fill the questions below so they do not
# retype data we can already read (#639). This uses
# `osascript -e 'tell application "Contacts" ...'`, which fires the macOS
# AppleEvent Automation consent prompt the first time ("OstlerInstaller
# wants to control Contacts"). That prompt is accepted for v1.0: the
# pre-fill is worth the one extra dialog. A denial (errAEEventNotPermitted
# / -1743) is detected from stderr and handled gracefully below -- we warn
# and fall back to plain questions, never a silent pass.
#
# (The promptless CNContact `ostler-contacts` helper is the #453 v1.0.1
# follow-up. PyObjC via the bundled Python is not an option here: the
# bundled venv is not created until the Phase-3 encrypt_db step, well
# after this Phase-2 question block.)
info "$MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL"

# `my card` only resolves when Contacts.app is actually RUNNING. On a Mac
# right after first setup -- or any login where the user has not opened
# Contacts -- the app is cold, the AppleEvent fails with -600 "Application
# isn't running", and the read returns empty with NO consent prompt. The
# pre-fill then silently produces nothing: blank name/country defaults, an
# empty wiki title, and empty self-handles (#646). This was the v1.0.0 .145
# box-walk regression. Launch Contacts hidden in the background first (-g
# keeps the installer in focus, -j launches it hidden) so the event lands
# against a live app and the normal automation-consent prompt can appear.
open -gja Contacts >/dev/null 2>&1 || true

# Capture stderr separately so a Contacts permission denial (-1743) or a
# cold-app failure (-600) is detected and surfaced cleanly instead of
# silently swallowed. The inner `|| true` keeps the failure inside the
# $(...) subshell so set -E cannot fire the ERR trap on a denial (cf. #640).
CARD_STDERR=$(mktemp)
_read_my_card() {
    osascript -e '
tell application "Contacts"
    launch
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
end tell' 2>"$CARD_STDERR"
}
CARD_DATA=$(_read_my_card || true)
# Cold-start race: if the first event beat Contacts to readiness (-600),
# give the background launch a moment to take hold and read once more.
if [[ -z "$CARD_DATA" ]] && grep -q -- '-600' "$CARD_STDERR" 2>/dev/null; then
    sleep 2
    CARD_DATA=$(_read_my_card || true)
fi

if [[ -z "$CARD_DATA" ]] && grep -qE -- '-1743|not authorized|errAEEventNotPermitted' "$CARD_STDERR" 2>/dev/null; then
    warn "$MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT"
    warn "$MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM"
    warn "$MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL"
elif [[ -z "$CARD_DATA" ]] && grep -q -- '-600' "$CARD_STDERR" 2>/dev/null; then
    # Contacts could not be brought up to read the card; continue without
    # auto-fill rather than swallowing the failure silently as before.
    warn "$MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL"
fi
rm -f "$CARD_STDERR"

if [[ -n "$CARD_DATA" ]]; then
    DETECTED_NAME=$(echo "$CARD_DATA" | cut -d'|' -f1)
    DETECTED_FIRST=$(echo "$CARD_DATA" | cut -d'|' -f2)
    DETECTED_COUNTRY=$(echo "$CARD_DATA" | cut -d'|' -f3)
    DETECTED_EMAIL=$(echo "$CARD_DATA" | cut -d'|' -f4)
    DETECTED_PHONE=$(echo "$CARD_DATA" | cut -d'|' -f5)
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

# CX-81 B6: derive USER_FIRST_NAME from the captured full name. The me-card
# detected DETECTED_FIRST first when available; otherwise we split USER_NAME
# on the first whitespace run. Used by the assistant to address the customer
# by their preferred name + by CM044 to template the wiki nav label
# ({first_name}pedia). Falls back to empty if both inputs are blank, in
# which case downstream surfaces use the "Personal wiki" / "Your assistant"
# non-symmetric fallbacks documented in BRAND_SPEC_V1.1 §8.
if [[ -n "${DETECTED_FIRST:-}" ]]; then
    USER_FIRST_NAME="${DETECTED_FIRST}"
else
    # Split USER_NAME on the first whitespace run. `awk` is portable across
    # macOS bash 3.2 + bash 5; `cut -d' '` would mishandle tab-separated or
    # multi-space inputs from Contacts.
    USER_FIRST_NAME=$(echo "$USER_NAME" | awk '{print $1}')
fi
# Strip stray surrounding whitespace.
USER_FIRST_NAME="${USER_FIRST_NAME# }"
USER_FIRST_NAME="${USER_FIRST_NAME% }"

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

# The "What should your assistant call you?" answer (USER_ID) is the
# customer's EXPLICIT preferred form of address. It MUST win over the
# me-card first name for every assistant + wiki surface: USER_FIRST_NAME
# feeds the welcome iMessage, chat replies, daily briefs and the
# {first_name}pedia wiki title. Before this, USER_FIRST_NAME was derived
# above purely from the me-card "first name of myCard" (DETECTED_FIRST),
# so a customer who answered "Andy" was still addressed by their formal
# me-card name "Andrew" -- the question was asked, then ignored. Re-derive
# USER_FIRST_NAME from the preferred answer, first letter capitalised for
# display (USER_ID can arrive lower-cased from DEFAULT_ID). Fall back to
# the earlier me-card/full-name derivation only if USER_ID is blank.
if [[ -n "${USER_ID:-}" ]]; then
    _uid_first="$(printf '%s' "${USER_ID:0:1}" | tr '[:lower:]' '[:upper:]')"
    USER_FIRST_NAME="${_uid_first}${USER_ID:1}"
    USER_FIRST_NAME="${USER_FIRST_NAME# }"
    USER_FIRST_NAME="${USER_FIRST_NAME% }"
fi

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
#
# CX-98 (DMG #48h+1, 2026-05-29): the defaults that were inline
# here pre-CX-98 (CHANNEL_*_ENABLED=false + the empty strings +
# the 993/587 IMAP/SMTP ports + the Apple-Mail / custom-IMAP
# pair) are now set UNCONDITIONALLY at the top of Phase 2 before
# the SKIP_PHASE2 branch -- search for "CX-98 (DMG #48h" near
# line ~1445. The reuse-settings path skips this whole questions
# block, and without the pre-branch initialiser the config_save
# step at line ~4823 trips set -u on CHANNEL_IMESSAGE_ENABLED.
# Re-stating the inline defaults here would be redundant; the
# case/if branches below still overwrite them based on the
# customer's CHANNEL_CHOICE answer.
#
# WA_CONSENT (line ~5337 reader) and OSTLER_REGION* (lines ~3498,
# ~5265, ~5300 readers) were also lifted unconditional; same
# rationale, same git blame.

case "$CHANNEL_CHOICE" in
    1) CHANNEL_IMESSAGE_ENABLED=true ;;
    2) CHANNEL_EMAIL_ENABLED=true ;;
    3|"") CHANNEL_IMESSAGE_ENABLED=true; CHANNEL_EMAIL_ENABLED=true ;;
    4) info "Skipping channel setup. Run later: ${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant setup channels --interactive" ;;
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

# ── Messages Automation prompt — FRONT-LOADED (v1.0.2, P1) ────────
#
# Previously the macOS "OstlerInstaller wants to control Messages"
# Automation prompt fired only at section 3.18 (~95% through install),
# which on the .156 walk landed ~75 s AFTER the success banner -- i.e.
# the customer saw "all done", walked away, then got ambushed by a
# system permission popup. That breaks the launch promise that NOTHING
# prompts after the success screen.
#
# The Automation grant depends only on (a) the iMessage channel being
# chosen -- known NOW, immediately after CHANNEL_CHOICE above -- and
# (b) Messages.app being launchable. Neither needs the late daemon or
# channel config, so we trigger the consent prompt HERE, in the same
# attention window as the FDA + Contacts prompts, while the customer is
# still answering questions. The late 3.18 block then becomes a
# RE-PROBE only (it records posture but no longer fires a fresh prompt
# or a second pre-warn modal) -- guarded by IMESSAGE_AUTOMATION_PRIMED_EARLY.
#
# Keeping the grant (vs dropping it like Mail's AppleScript) is
# deliberate: driving the main Messages.app via AppleScript is how the
# assistant SENDS iMessages as the user. We only move WHEN it is asked,
# not whether.
IMESSAGE_AUTOMATION_PRIMED_EARLY=false
if [[ "$CHANNEL_IMESSAGE_ENABLED" == true && "${OSTLER_GUI:-0}" == "1" ]]; then
    # Warm the main Messages.app so the probe's `count of accounts`
    # AppleEvent does not -1712 against a cold app. `-g` keeps it in the
    # background (no focus steal mid-install). Best-effort + non-fatal.
    open -ga Messages 2>/dev/null || true

    # Pre-warn ack so the "wants to control Messages" popup is expected,
    # not an ambush. Mirrors the 3.18 wording. Short cooldown so it does
    # not stack on the FDA/Contacts dialogs that just closed.
    info "$MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION"
    sleep 2
    _="$(gui_read \
        "$MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE" \
        acknowledge \
        "" \
        "$MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP" \
        "" \
        "imessage_automation_incoming_ack_early")"
    info "$MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY"

    # READ-ONLY probe that requires the SAME Automation grant a real send
    # would -- this is what triggers the macOS consent prompt. We discard
    # the posture here (3.18 records the authoritative snapshot); the only
    # side-effect we want now is the prompt landing in the attention
    # window. Test-shim escape hatch honoured so harnesses never osascript.
    if [[ -z "${PWG_IMESSAGE_PROBE_OUTCOME:-}" ]]; then
        osascript -e 'tell application "Messages" to count of accounts' \
            >/dev/null 2>&1 || true
    fi
    IMESSAGE_AUTOMATION_PRIMED_EARLY=true
fi
export IMESSAGE_AUTOMATION_PRIMED_EARLY

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
    echo "  Ostler can read the CONTENT of your recent WhatsApp messages"
    echo "  locally on this Mac - not just who you messaged and when, but"
    echo "  what was said - so you can search and reference them like any"
    echo "  other part of your life. It reads recent WhatsApp conversations"
    echo "  your Mac has synced - typically several months up to about a"
    echo "  year. The messages stay on your Mac. Nothing is sent to us."
    echo ""
    echo -e "  ${BOLD}Why this is the riskiest of the three channels${NC}"
    echo ""
    echo "  Of the three messaging channels Ostler supports (iMessage,"
    echo "  email, WhatsApp), this is the only one with a third-party"
    echo "  platform risk. iMessage data lives in macOS itself; email"
    echo "  arrives in Apple Mail's local store. Both are read with"
    echo "  Apple's blessing via Full Disk Access."
    echo ""
    echo "  WhatsApp is different. It's owned by Meta and has its own"
    echo "  Terms of Service. The way Ostler reads your messages – by"
    echo "  reading the data WhatsApp Web has already saved into a"
    echo "  hidden folder on your Mac – is not how WhatsApp's terms"
    echo "  say their service should be accessed. We never contact"
    echo "  Meta, we never relay anything to them, and we never use"
    echo "  the WhatsApp API. We just read the file they wrote locally."
    echo "  But that still counts as \"unofficial\" by their definition."
    echo ""
    echo "  In practice, this kind of read access is widely used and we"
    echo "  are not aware of any documented case of WhatsApp banning a"
    echo "  user for it. But we cannot rule out the possibility that"
    echo "  WhatsApp could detect the activity and decide to:"
    echo ""
    echo "    - suspend your WhatsApp account, temporarily or permanently"
    echo "    - block this device from connecting to WhatsApp Web"
    echo "    - require you to re-verify your phone number"
    echo ""
    echo "  If any of that happens, it happens to your WhatsApp account,"
    echo "  not to Creative Machines. You – not us – are the person"
    echo "  bound by WhatsApp's Terms of Service. We cannot get your"
    echo "  account back for you, and we are not liable for any loss"
    echo "  you suffer if WhatsApp takes action against your account."
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
    echo "  Enter your number with the country code: leading +, digits only."
    echo "  Example: +44 7700 900123"
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

    # #260 / #639: collect the Mail history-window choice HERE, upfront in
    # Phase 2, adjacent to the Apple Mail question. It was previously a
    # blocking gui_read mid-install (~L6498), which stalled a walk-away
    # install. Default keeps 5 years; "extend" pulls the full local
    # mailbox. The choice is stored in OSTLER_MAIL_BACKFILL_DAYS and
    # consumed by the first FDA extraction with no further prompt. Only
    # relevant when Apple Mail is the email source.
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]]; then
        _mail_extend_answer="$(gui_read \
            "$MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE" \
            yesno \
            "N" \
            "$MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP" \
            "" \
            "mail_extend_history")"
        case "${_mail_extend_answer:-N}" in
            y|Y|yes|YES|Yes)
                # 50 years comfortably covers any realistic local mailbox
                # without an unbounded query.
                OSTLER_MAIL_BACKFILL_DAYS="18250"
                ;;
            *) : ;;  # leave unset -> defaults to 1825 (5y) at extract time
        esac
        unset _mail_extend_answer
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
        #
        # CX-97 (DMG #48g+1, 2026-05-29): same shape as the
        # recovery_passphrase mismatch loop above -- surface the
        # mismatch via gui_read's $7 error_text arg so the GUI shows
        # a clear oxblood banner above the SAME re-emitted prompt
        # instead of silently re-asking. The X counter dedupe +
        # promptIdToIndex restore on the GUI side keep the question
        # number pinned to where the customer actually is in the flow.
        _email_pass_error=""
        _email_confirm_error=""
        while true; do
            echo ""
            CHANNEL_EMAIL_PASSWORD="$(gui_read "$MSG_PROMPT_EMAIL_PASSWORD_TITLE" secret "" "$MSG_PROMPT_EMAIL_PASSWORD_HELP" "" "email_password" "$_email_pass_error")"
            echo ""
            _email_confirm_input="$(gui_read "$MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE" secret "" "" "" "email_password_confirm" "$_email_confirm_error")"
            echo ""
            if [[ "$CHANNEL_EMAIL_PASSWORD" == "$_email_confirm_input" && -n "$CHANNEL_EMAIL_PASSWORD" ]]; then
                break
            fi
            warn "$MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY"
            _email_pass_error="$MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY"
            _email_confirm_error="$MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY"
        done
        unset _email_confirm_input _email_pass_error _email_confirm_error
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

        # CX-37 (DMG #30, 2026-05-24): early Mail-account probe.
        # Previously the "no Mail accounts -> open Internet Accounts"
        # prompt fired during Phase 4 (email_ingest step), interrupting
        # the "you can walk away now" promise with a 5-10s wait for the
        # operator to answer + a System Settings dialog mid-install.
        # Move the prompt to the questions phase so by the time Phase 4
        # runs, accounts are configured. Probe + remediation only --
        # the pipeline_signals.json sidecar write stays in Phase 4.
        #
        # CX-57 (DMG #32, 2026-05-24): the CX-37 probe block was
        # killing the installer at exit 1 right after the customer
        # answered email_custom_imap in Studio retest #27. Bash
        # `set -euo pipefail` makes the probe's `find | sort | tail`
        # pipeline + `grep -c '<key>' || echo 0` fallback fragile in
        # weird ways:
        #   - grep -c "no match" returns "0" + exit 1; the `|| echo 0`
        #     then APPENDS another "0", so the captured value can be
        #     "0\n0", which `[[ -eq 0 ]]` rejects as a syntax error.
        #   - file-system permission denials inside command sub can
        #     poison the outer pipeline status under pipefail.
        # Wrap the entire probe in `set +e` so any sub-step failure is
        # contained -- the worst case is we skip the early prompt and
        # the Phase 4 fallback fires anyway. Also drop the grep
        # entirely in favour of a `tr -dc '0-9' | head -c10` digit
        # filter so the count value is always a clean integer or 0.
        # Tracer log markers bracket the block so the next retest can
        # pinpoint a regression instantly.
        gui_log info "CX-37 probe: entering"
        set +e
        # CX-103 (DMG #48k, 2026-05-29): FDA may not yet be granted
        # at question phase. Without FDA, Accounts4.sqlite reads fail
        # with TCC "authorization denied" -- the `2>/dev/null` mask
        # collapses to "0 accounts", which mis-fires the "Mail not
        # connected" prompt for every customer whose first install
        # has not pre-granted FDA. Skip the early prompt entirely if
        # we cannot read source-of-truth. The Phase 4 email_ingest
        # probe runs AFTER FDA is granted and produces the correct
        # count for downstream pipeline_signals.json.
        if ! _has_fda; then
            gui_log info "CX-103: skipping early Mail probe -- FDA not yet granted (Phase 4 probe will run after grant)"
            MAIL_PROMPT_SHOWN_EARLY=1
            export MAIL_PROMPT_SHOWN_EARLY
        fi
        if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]] \
           && [[ "${OSTLER_GUI:-0}" == "1" ]] \
           && [[ -z "${MAIL_PROMPT_SHOWN_EARLY:-}" ]]; then
            # CX-100 (DMG #48j, 2026-05-29): early probe now reads
            # Accounts4.sqlite source-of-truth instead of the Mail.app
            # derived Accounts.plist. The old derived read returned 0
            # on every Mac where the customer had configured iCloud
            # in System Settings but had not opened Mail.app yet --
            # which mis-fired the "no mail accounts connected"
            # prompt during Phase 2. See the same comment block at
            # the Phase 4 Mail probe (search for "CX-100 checkpoint").
            _early_mail_accounts="$(_accountsdb_count_mail)"
            _early_mail_accounts="${_early_mail_accounts:-0}"
            gui_log info "CX-100 probe: accountsdb mail count=[${_early_mail_accounts}]"
            if [[ "$_early_mail_accounts" -eq 0 ]] 2>/dev/null; then
                _early_mail_answer="$(gui_read \
                    "$MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE" \
                    yesno \
                    "Y" \
                    "$MSG_PROMPT_MAIL_NOT_CONNECTED_HELP" \
                    "" \
                    "mail_not_connected")"
                case "${_early_mail_answer:-n}" in
                    y|Y|yes|YES|Yes)
                        ok "$MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS"
                        open "x-apple.systempreferences:com.apple.preferences.internetaccounts" 2>/dev/null || true
                        ;;
                    *)
                        ok "$MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS"
                        ;;
                esac
                unset _early_mail_answer
            fi
            MAIL_PROMPT_SHOWN_EARLY=1
            export MAIL_PROMPT_SHOWN_EARLY
            unset _early_mail_accounts
        fi
        set -e
        gui_log info "CX-37 probe: exiting"

        # CX-130 (v1.0.1): hoist the "account exists but Mail.app has
        # not fetched yet -> open Mail and wait while it syncs" prompt
        # out of the unattended Phase 3 and into this questions phase,
        # exactly as CX-37 did for the "no Mail account" prompt above.
        #
        # The shipped install fired this populate-wait at ~L10263 inside
        # the Phase-3 execution region (the "you can walk away now"
        # stretch), so a customer who left the install running came back
        # to a blocking "Open Apple Mail?" dialog ~16% in. Asking it HERE,
        # while the customer is already answering questions, keeps Phase 3
        # interaction-free. The Phase-3 block remains as a fallback for the
        # case where this early prompt did not run (e.g. FDA not yet
        # granted at question time, or the GUI was off then on).
        #
        # Same belt-and-braces shape as the CX-37 probe: wrap in `set +e`
        # so a probe sub-step failure can never kill the install -- worst
        # case we skip the early prompt and the Phase-3 fallback fires.
        # Guarded on the SAME conditions as the Phase-3 block: accounts > 0
        # (source of truth via Accounts4.sqlite), Mail.app has not pulled
        # a message yet, GUI on. FDA must be readable or the account count
        # is unreliable (CX-103) -- reuse _has_fda to skip cleanly.
        gui_log info "CX-130 populate probe: entering"
        set +e
        if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]] \
           && [[ "${OSTLER_GUI:-0}" == "1" ]] \
           && [[ -z "${MAIL_POPULATE_PROMPT_SHOWN_EARLY:-}" ]] \
           && _has_fda; then
            _early_pop_accounts="$(_accountsdb_count_mail)"
            _early_pop_accounts="${_early_pop_accounts:-0}"
            gui_log info "CX-130 populate probe: accountsdb mail count=[${_early_pop_accounts}]"
            if [[ "$_early_pop_accounts" -gt 0 ]] 2>/dev/null \
               && ! _store_populated_mail; then
                # State 2: accounts configured but Mail.app has not pulled
                # anything yet. Offer to open Mail + wait while it syncs.
                # CX-110: pass "Mail" (canonical bundle name) to the
                # `open -a` path; customer-facing copy still reads
                # "Apple Mail" via the help string.
                _early_pop_help="$(printf "$MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP" "${_early_pop_accounts}")"
                if _three_state_wait_for_populate \
                    "mail" \
                    "Mail" \
                    "" \
                    "$MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE" \
                    "$_early_pop_help"; then
                    # Mail synced during the wait. The Phase-3 probe re-runs
                    # _store_populated_mail and will now see the populated
                    # store, so it writes mail_has_fetched=true to the
                    # pipeline_signals.json sidecar + emits the gui_emit
                    # MAIL_ACCOUNTS_FOUND marker for Doctor. We do not write
                    # the sidecar here because the writer + signals path are
                    # only resolved in Phase 3; re-detection in Phase 3
                    # carries the side-effects without duplication.
                    gui_log info "CX-130 populate probe: Mail populated during early wait"
                fi
                unset _early_pop_help
            fi
            # Mark the early prompt as shown so the Phase-3 populate block
            # SKIPS -- asking twice mid-install would be worse than asking
            # once early. The Phase-3 sidecar write + gui_emit still run.
            MAIL_POPULATE_PROMPT_SHOWN_EARLY=1
            export MAIL_POPULATE_PROMPT_SHOWN_EARLY
            unset _early_pop_accounts
        fi
        set -e
        gui_log info "CX-130 populate probe: exiting"
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
    #
    # CX-57 (DMG #32, 2026-05-24): bracket with tracer logs + use a
    # plain joiner instead of `IFS=' + ' read <<<` so a single
    # malformed entry can't poison the entire email channel summary.
    # Same belt-and-braces shape as the CX-37 probe above.
    gui_log info "CX-57 email-summary: entering"
    _email_summary_parts=()
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]]; then
        _email_summary_parts+=("Apple Mail (FDA)")
    fi
    if [[ "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" == true ]]; then
        _email_summary_parts+=("${CHANNEL_EMAIL_USERNAME:-?} via ${CHANNEL_EMAIL_IMAP_HOST:-?}")
    fi
    _email_summary_joined=""
    for _email_part in "${_email_summary_parts[@]}"; do
        if [[ -z "$_email_summary_joined" ]]; then
            _email_summary_joined="$_email_part"
        else
            _email_summary_joined="${_email_summary_joined} + ${_email_part}"
        fi
    done
    [[ -z "$_email_summary_joined" ]] && _email_summary_joined="Apple Mail (FDA)"
    ok "$(printf "$MSG_OK_EMAIL_CHANNEL_FOLDER" "${_email_summary_joined}" "${CHANNEL_EMAIL_IMAP_FOLDER}")"
    unset _email_summary_parts _email_summary_joined _email_part
    gui_log info "CX-57 email-summary: exiting"
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
printf "    %-14s %s\n" "Spotify"        "$(_link 'https://www.spotify.com/account/privacy/' 'Request data')"
printf "    %-14s %s\n" "Netflix"        "$(_link 'https://www.netflix.com/account/getmyinfo' 'Request data')"
printf "    %-14s %s\n" "Apple"          "$(_link 'https://privacy.apple.com/' 'Request data') (Media Services)"
printf "    %-14s %s\n" "Amazon"         "$(_link 'https://www.amazon.com/hz/privacy-central/data-requests/preview.html' 'Request data')"
echo ""
echo "  When your exports arrive, just leave them in your Downloads"
echo "  folder. Ostler imports them automatically. There is nothing"
echo "  else for you to do."
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
# CX-19 (launch blocker, 2026-05-23): prefer bundled Python over system Python.
#
# Studio retest #14 (DMG #16) caught a phase-ordering bug that EVERY fresh
# customer Mac hits: `python3 --version` triggers the /usr/bin/python3
# Apple stub on a stock macOS 15 install (no Command Line Tools, no
# Homebrew), which fires the "Install Command Line Tools" GUI dialog
# and returns non-zero. The brew-install-python fallback below also
# fails because Homebrew has not been installed yet at this point in
# install.sh -- the Homebrew install step is in the INSTALL phase, the
# Python check is in the QUESTIONS phase that runs before it.
#
# Fix: bundle python-build-standalone Python 3.11 inside the .app and
# prefer it over any system python3. SCRIPT_DIR is Contents/Resources
# when install.sh runs from the signed .app, so
# ${SCRIPT_DIR}/python/bin/python3.11 is the bundled binary embedded
# at archive time (see gui/project.yml postBuildScripts +
# gui/Makefile download-python target).
#
# Dev mode fallback (running from HR015 source layout, not from the
# signed .app) retains the existing brew-install-or-system-python
# logic. This branch is hit only by developers running install.sh
# directly from a sibling clone -- not by customers.
if [[ -z "${PYTHON3_BIN:-}" ]]; then
    PYTHON3_BIN=""
    BUNDLED_PYTHON="${SCRIPT_DIR}/python/bin/python3.11"
    if [[ -x "$BUNDLED_PYTHON" ]]; then
        PYTHON3_BIN="$BUNDLED_PYTHON"
        BUNDLED_PY_VERSION=$("$PYTHON3_BIN" --version 2>&1 | cut -d' ' -f2)
        ok "$(printf "$MSG_OK_PYTHON_BUNDLED" "${BUNDLED_PY_VERSION}")"
    else
        # Dev mode fallback: existing brew-install-or-system-python path.
        # This branch is hit only when install.sh runs from a developer's
        # HR015 sibling-clone, not from the customer-facing signed .app
        # (which always has ${SCRIPT_DIR}/python/bin/python3.11 bundled).
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
                fail_with_code "ERR-05-HOMEBREW-PYTHON-INSTALL" "Could not install Python 3.11 via Homebrew. Re-run the installer with a working network connection, or install Python 3.11 manually with: brew install python@3.11"
            fi
            # Use the explicit Homebrew keg path, NOT the PATH-prepended
            # `python3` which can resolve to /usr/bin/python3 (system 3.9.x)
            # even after a `export PATH=...` prepend.
            if [[ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]]; then
                PYTHON3_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
            elif [[ -x "/usr/local/opt/python@3.11/bin/python3.11" ]]; then
                PYTHON3_BIN="/usr/local/opt/python@3.11/bin/python3.11"
            else
                fail_with_code "ERR-05-HOMEBREW-PYTHON-MISSING" "brew install python@3.11 reported success but the python3.11 binary was not found at the expected paths. Try 'brew reinstall python@3.11' and re-run the installer."
            fi
            NEW_PY_VERSION=$("$PYTHON3_BIN" --version 2>&1 | cut -d' ' -f2)
            ok "$(printf "$MSG_OK_PYTHON_INSTALLED" "${NEW_PY_VERSION}")"
        fi
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
        else
            # Surface a missing-bundle warning so a future buried-failure
            # retest catches the gap in the GUI install log rather than
            # at the customer's first Article 9 / WhatsApp / voice gate
            # (which would raise ModuleNotFoundError hours after install).
            # See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F3.
            warn "$MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED"
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
            fail_with_code "ERR-09-OSTLER-SECURITY-PIP" "$MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN"
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
        fail_with_code "ERR-10-FDA-MODULE-MISSING" "$MSG_FAIL_FDA_MODULE_MISSING_RE_RUN"
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
        gui_cancelled   # CX-126: neutral cancelled terminal, not a failure
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
    # CX-97 (DMG #48g+1, 2026-05-29): pass mismatch / too-short /
    # required errors via gui_read's new $7 error_text arg so the GUI
    # renders a clear oxblood banner ABOVE the input on the SAME
    # re-emitted prompt, rather than burying the warn() text into the
    # help body. Re-emit of the same prompt id keeps the X counter
    # pinned (seenPromptIds dedupe) AND restores X to the prompt's
    # original index (promptIdToIndex map) so the customer sees the
    # same question number with a clear "didn't match" cue, not an
    # apparently-new question.
    #
    # RP_ERROR carries the LAST failure reason. We split it into
    # two slots so the help body stays clean static copy + the
    # error banner gets its own surfaced run:
    #   - RP_PASS_ERROR -> passes back to the recovery_passphrase
    #     prompt on retry (e.g. required, too short).
    #   - RP_CONFIRM_ERROR -> passes back to the
    #     recovery_passphrase_confirm prompt on mismatch.
    RP_PASS_ERROR=""
    RP_CONFIRM_ERROR=""
    while true; do
        rp_help="$MSG_PROMPT_RECOVERY_PASSPHRASE_HELP"
        RECOVERY_PASSPHRASE="$(gui_read "$MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE" secret "" "$rp_help" "" "recovery_passphrase" "$RP_PASS_ERROR")"
        echo ""
        if [[ -z "$RECOVERY_PASSPHRASE" ]]; then
            RP_PASS_ERROR="$MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED"
            warn "$MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED"
            continue
        fi

        # Quick length sanity check here; full strength validation
        # runs in Phase 3.6 once the venv is fully provisioned.
        # 12-char minimum mirrors the lower bound of
        # validate_passphrase_strength's diceware path.
        if [[ ${#RECOVERY_PASSPHRASE} -lt 12 ]]; then
            warn "$MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT"
            RP_PASS_ERROR="$MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT"
            unset RECOVERY_PASSPHRASE
            continue
        fi
        # First-pass succeeded; clear the password-side error before
        # we walk forward to confirmation.
        RP_PASS_ERROR=""

        rpc_help="$MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP"
        RP_CONFIRM="$(gui_read "$MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE" secret "" "$rpc_help" "" "recovery_passphrase_confirm" "$RP_CONFIRM_ERROR")"
        echo ""
        if [[ "$RECOVERY_PASSPHRASE" != "$RP_CONFIRM" ]]; then
            warn "$MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN"
            # Both prompts re-emit on mismatch -- surface the same
            # banner on the passphrase prompt (so the customer types
            # it again knowing it didn't match) AND on the confirm
            # prompt (in case the customer happened to mis-type the
            # confirm, not the original).
            RP_PASS_ERROR="$MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN"
            RP_CONFIRM_ERROR="$MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN"
            unset RP_CONFIRM
            continue
        fi
        unset RP_CONFIRM
        RP_PASS_ERROR=""
        RP_CONFIRM_ERROR=""
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
        fail_with_code "ERR-09-OSTLER-SECURITY-BUNDLE" "$MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN"
    fi
fi

# ── 8. AI model (automatic) ────────────────────────────────────────

# Model selection based on detected hardware (REUSE-4 hardware-fit picker).
#
# WHY NOT A FLAT RAM LADDER: the daemon runs every chat at num_ctx=32768
# (OLLAMA_NUM_CTX, see assistant-agent plist + test_assistant_ollama_num_ctx.sh).
# A 32k KV cache costs gigabytes ON TOP of the model weights, so "enough RAM
# for the weights" is not the same as "fits at the required context window".
# Several box-walks cold-start-failed because a model was picked that could
# not allocate its 32k context. lib/ostler-model-fit.sh scores each candidate
# Fits / may be slow / won't fit against the agent's real num_ctx and names
# the best comfortable fit as Recommended.
#
# MoE models (35B-A3B) have 35B total knowledge but only 3B active params,
# so they need ~23GB resident but run at 3B speed.
if declare -F ostler_recommend_model >/dev/null 2>&1; then
    _mf_chip="$(ostler_detect_chip)"
    _mf_numctx="${OSTLER_MODEL_FIT_NUM_CTX:-32768}"
    info "$(printf "$MSG_MODELFIT_HEADER" "${_mf_chip}" "${RAM_GB}" "${_mf_numctx}")"

    AI_MODEL="$(ostler_recommend_model "${RAM_GB}")"

    # Print the per-model fit assessment (pills + quant + Recommended tag) so
    # the customer sees WHY a model was chosen and what they would get with
    # more RAM. Best-first ordering matches the table in the helper.
    for _mf_model in "${OSTLER_MODEL_TAGS[@]}"; do
        _mf_verdict="$(ostler_model_fit "${_mf_model}" "${RAM_GB}")"
        _mf_pill="$(ostler_model_fit_pill "${_mf_verdict}")"
        _mf_size="$(ostler_model_size_label "${_mf_model}")"
        _mf_quant="$(ostler_model_quant "${_mf_model}")"
        _mf_row="$(printf "$MSG_MODELFIT_ROW" "${_mf_pill}" "${_mf_model}" "${_mf_size}" "${_mf_quant}")"
        if [[ "${_mf_model}" == "${AI_MODEL}" ]]; then
            _mf_row="${_mf_row}${MSG_MODELFIT_RECOMMENDED_TAG}"
        fi
        info "${_mf_row}"
    done

    AI_MODEL_SIZE="$(ostler_model_size_label "${AI_MODEL}")"
    unset _mf_chip _mf_numctx _mf_model _mf_verdict _mf_pill _mf_size _mf_quant _mf_row
    ok "$(printf "$MSG_MODELFIT_SELECTED" "${AI_MODEL}" "${AI_MODEL_SIZE}" "${RAM_GB}")"
else
    # Fallback: helper not on disk (stripped bundle). Legacy RAM ladder --
    # same thresholds the fit table encodes for the comfortable ("fits") tier.
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
fi
PULL_MODEL="y"

# ── 9. GDPR data exports (auto-detect) ────────────────────────────
# Skip on re-run -- user already consented, exports already known.

if [[ "$SKIP_PHASE2" == false ]]; then

EXPORTS_DIR=""
DETECTED_EXPORTS=()
# #619 (2026-06-06): folders the scan could not read (TCC or POSIX
# permission denied). Recorded so a denied folder is surfaced as an
# actionable message rather than masquerading as an empty one.
DENIED_FOLDERS=()

# #619 diagnosis note (verify before assuming a prompt bug). The
# announce-no-prompt symptom Andy sees is most likely a #446 artifact,
# not a code bug here: the three folder-TCC grants persist for the
# installer bundle (ai.ostler.installer) across dev wipes because
# dev-wipe-studio.sh does not reset TCC for the installer bundle IDs.
# With the grant already present the `ls` pre-warm finds access and
# macOS shows no prompt, while the scan still works. To reproduce a
# genuinely TCC-clean state, reset the three services for the bundle
# before a run:
#   tccutil reset SystemPolicyDownloadsFolder ai.ostler.installer
#   tccutil reset SystemPolicyDesktopFolder   ai.ostler.installer
#   tccutil reset SystemPolicyDocumentsFolder ai.ostler.installer
# (macOS attributes folder TCC to the responsible app carrying the
# NSDownloads/NSDesktop/NSDocumentsFolderUsageDescription keys in
# gui/OstlerInstaller/Info.plist.) The hardening below is correct
# regardless of that diagnosis: a denied folder must never read as
# empty in silence.

# #619: true if the directory can actually be listed. A folder blocked
# by TCC or POSIX permissions still passes [[ -d ]] but fails `ls`;
# without this check the find-scan below swallows the denial (its
# `2>/dev/null || true`) and the folder looks empty.
_gdpr_folder_readable() {
    ls "$1" >/dev/null 2>&1
}

# CX-18 (2026-05-23): Studio retest #13 surfaced three unannounced
# macOS folder-access prompts (Downloads, Desktop, Documents) firing
# back-to-back while the customer was waiting on the GDPR scan to
# finish, with no explanation of why their Mac suddenly wanted
# permission to read all three folders. Emit a structured info line
# BEFORE the find-scan starts so the Log drawer + GUI spinner caption
# explain what is about to happen. This is a true status line (NOT
# gui_log) so it renders on screen for the customer to read before
# the macOS popups land. Cross-reference: NSDesktopFolderUsageDescription
# + NSDocumentsFolderUsageDescription + NSDownloadsFolderUsageDescription
# in gui/OstlerInstaller/Info.plist drive what macOS shows in each
# prompt.
info "$MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING"

# CX-47 (DMG #30, 2026-05-24): elevate the 3-folder-prompt warning
# from a transient info line to a blocking acknowledge gui_read. The
# previous info() rendered for ~200ms then scrolled away, so customers
# hit the three Downloads/Desktop/Documents TCC popups without warning
# and didn't know what they were. Blocking ack lets them read + click
# Continue knowing what's about to happen. Suppressed under TTY/CI.
if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    _="$(gui_read \
        "$MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE" \
        acknowledge \
        "" \
        "$MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING" \
        "" \
        "gdpr_scan_incoming_ack")"
fi

# Scan common locations for recognisable GDPR export files.
# Studio retest #7 finding #13 (Image #53): the previous `info`
# emit here rendered as a ~200ms transient status page in the GUI
# before the find-scan moved on. Drop to log-only so the GUI never
# renders a flash page; the bash terminal output is unaffected.
gui_log info "$MSG_INFO_SCANNING_GDPR_DATA_EXPORTS"

# CX-70 (DMG #44, 2026-05-25): pre-warm the three folder TCC
# prompts up front with an `ls` probe per folder + a labelled
# info line before each, so the customer sees three named
# prompts in sequence rather than three unannounced popups
# arriving back-to-back during the find scan below. CX-47 already
# added a combined acknowledge above; CX-70 adds per-prompt
# labelling so the customer knows which is which.
#
# The `ls >/dev/null 2>&1` triggers macOS's TCC prompt for the
# folder if not already granted. We don't depend on the output --
# only the side-effect. 0.5 s gaps so successive prompts don't
# overlap visually.
if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    info "$MSG_INFO_FOLDER_PREWARM_DOWNLOADS"
    ls "${HOME}/Downloads" >/dev/null 2>&1 || true
    sleep 0.5
    info "$MSG_INFO_FOLDER_PREWARM_DESKTOP"
    ls "${HOME}/Desktop" >/dev/null 2>&1 || true
    sleep 0.5
    info "$MSG_INFO_FOLDER_PREWARM_DOCUMENTS"
    ls "${HOME}/Documents" >/dev/null 2>&1 || true
fi

# --- #657: bulletproof, name-agnostic GDPR export detection -----------------
# Write the shared signature-based detector to ~/.ostler/lib so BOTH this
# install-time scan AND the post-install export watcher use the SAME logic.
# Embedded as a QUOTED heredoc (the lib body uses $'...', $(...), ${...} and
# must be written verbatim, not expanded here) and shipped inside install.sh,
# so no cut-tooling / Makefile change is needed. Canonical source + tests:
# lib/ostler-detect-exports.sh; tests/test_gdpr_export_detect.sh runs a drift
# guard in CI that fails if this embedded copy diverges from that file.
mkdir -p "${HOME}/.ostler/lib" 2>/dev/null || true
cat > "${HOME}/.ostler/lib/ostler-detect-exports.sh" <<'OSTLER_DETECT_EXPORTS_EOF'
#!/usr/bin/env bash
# Bulletproof GDPR-export detection for Ostler's import.
#
# Identifies exports by their SIGNATURE FILES (content), never by the folder
# or zip NAME -- so a customer can drop ANY shape of export and Ostler still
# finds it:
#   - LinkedIn "Basic" OR "Complete" export, or a renamed folder/zip
#   - an export left ZIPPED (never unzipped) or already extracted
#   - exports nested a few folders deep inside the download
#
# The actual importer (ostler-import) is content-based and recurses the whole
# search dir, so detection only has to (a) decide whether an import is worth
# running and (b) --unzip any signature-bearing .zip first so its loose files
# become visible to the parsers.
#
# Usage:
#   ostler-detect-exports.sh <dir> [--unzip]
# Prints one  "LABEL<TAB>path"  line per detected export (path = the export's
# top-level folder under <dir>, or the .zip itself). Exit 0 if >=1 detected,
# 1 if none. With --unzip, signature-bearing zips are extracted in place first.
set -uo pipefail

DIR="${1:-}"
DO_UNZIP=0
[[ "${2:-}" == "--unzip" ]] && DO_UNZIP=1
[[ -n "$DIR" && -d "$DIR" ]] || exit 1

# platform <US> extended-regex of signature basenames (a file OR dir whose
# name is specific enough to identify the source export). Kept deliberately
# high-signal to avoid false positives. <US> = unit separator (0x1f).
SIGS=(
  $'LinkedIn\x1f^Connections\\.csv$'
  $'Facebook\x1f^your_friends\\.json$|^friends\\.json$'
  $'Instagram\x1f^followers_and_following$|^followers_1\\.json$'
  $'X\x1f^tweets\\.js$|^tweet\\.js$'
  $'Google\x1f^watch-history\\.json$|^MyActivity\\.json$|^My Activity$'
  $'Spotify\x1f^StreamingHistory.*\\.json$|^YourLibrary\\.json$|^Userdata\\.json$'
  $'Netflix\x1f^ViewingActivity\\.csv$'
  $'Amazon\x1f^Retail\\.OrderHistory.*\\.csv$|^Digital Items\\.csv$'
  $'Reddit\x1f^post_headers\\.csv$|^saved_posts\\.csv$'
  $'TikTok\x1f^user_data.*\\.json$'
  $'Pinterest\x1f^boards\\.csv$|^pins\\.csv$'
  $'Discord\x1f^messages\\.csv$|^activity$'
)

# --- 1. Optionally unzip any signature-bearing archive -----------------------
# Build one combined regex (path form) for matching zip member lists.
_zip_re=""
for entry in "${SIGS[@]}"; do
    re="${entry#*$'\x1f'}"
    # member paths look like "folder/Connections.csv"; strip the ^...$ anchors
    re_unanchored="${re//^/}"; re_unanchored="${re_unanchored//\$/}"
    _zip_re="${_zip_re:+$_zip_re|}${re_unanchored}"
done

if [[ "$DO_UNZIP" == "1" ]]; then
    while IFS= read -r z; do
        [[ -f "$z" ]] || continue
        if unzip -Z1 "$z" 2>/dev/null | grep -qiE "(${_zip_re})"; then
            dest="${z%.zip}"
            # Only extract once; never clobber an already-unzipped folder.
            if [[ ! -d "$dest" ]]; then
                mkdir -p "$dest" 2>/dev/null || true
                unzip -oq "$z" -d "$dest" 2>/dev/null || true
            fi
        fi
    done < <(find "$DIR" -maxdepth 2 -type f -iname '*.zip' 2>/dev/null || true)
fi

# --- 2. Content detection over loose files (post-unzip) ----------------------
# Resolve the export's top-level folder under DIR (so the friendly label and
# the dedupe key are stable regardless of the export's internal nesting).
_top_under() {  # $1 = a hit path; echoes the first path component below DIR
    local p="$1" parent
    while :; do
        parent="$(dirname "$p")"
        [[ "$parent" == "$DIR" || "$parent" == "/" || "$parent" == "." ]] && break
        p="$parent"
    done
    printf '%s\n' "$p"
}

found_any=1
declare -a SEEN_TOPS=()
for entry in "${SIGS[@]}"; do
    label="${entry%%$'\x1f'*}"
    re="${entry#*$'\x1f'}"
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        top="$(_top_under "$hit")"
        # de-dup identical top folders reported by multiple signatures
        skip=0
        for s in ${SEEN_TOPS[@]+"${SEEN_TOPS[@]}"}; do [[ "$s" == "$label::$top" ]] && skip=1 && break; done
        [[ "$skip" == "1" ]] && continue
        SEEN_TOPS+=("$label::$top")
        printf '%s\t%s\n' "$label" "$top"
        found_any=0
    done < <(find "$DIR" -maxdepth 6 \( -type f -o -type d \) 2>/dev/null \
                | awk -F/ -v re="$re" 'tolower($NF) ~ tolower(re) || $NF ~ re {print}' \
                | head -5)
done

exit "$found_any"
OSTLER_DETECT_EXPORTS_EOF
chmod +x "${HOME}/.ostler/lib/ostler-detect-exports.sh" 2>/dev/null || true

# ── Resource-tier governor lib (v1.0.3 first-run-storm fix) ────────
# Adaptive first-run resource governor: detects the hardware tier
# (RAM + CPU cores) and emits a per-tier first-run policy that the
# tick wrappers consult so the background enrichment storm scales to
# the machine and the interactive surfaces stay responsive. Same
# embed pattern as ostler-detect-exports.sh above: a QUOTED heredoc
# shipped inside install.sh, with a CI drift guard
# (tests/test_resource_tier_governor.sh) that fails if this embedded
# copy diverges from the canonical lib/ostler-resource-tier.sh.
mkdir -p "${HOME}/.ostler/lib" 2>/dev/null || true
cat > "${HOME}/.ostler/lib/ostler-resource-tier.sh" <<'OSTLER_RESOURCE_TIER_EOF'
#!/usr/bin/env bash
#
# ostler-resource-tier.sh
#
# Adaptive first-run resource governor: hardware-tier detector (v1.0.3).
#
# A fresh install fires a storm of background enrichment work (the four
# conversation-bundle feeds + the wiki recompile, all RunAtLoad=true at
# install completion) on top of the Docker VM and macOS first-login
# Spotlight indexing. On capable hardware this is tolerable; on the
# 16GB floor it drives the 1-minute load average past 30 and the Hub app
# becomes unusable (dashboard "Load failed", Doctor fails, chat WS dies).
#
# This library detects the machine's tier from RAM + CPU cores and emits
# a per-tier first-run policy that the installer and the tick wrappers
# consult, so the background storm scales to the actual hardware and the
# interactive surfaces (chat, dashboard, Doctor, wiki) stay responsive.
#
# It REUSES the RAM detection already in install.sh
# (sysctl hw.memsize) and ADDS core-count detection (hw.ncpu /
# hw.perflevel0.physicalcpu for performance cores). It is installed to
# ~/.ostler/lib/ostler-resource-tier.sh (the same pattern as
# ostler-detect-exports.sh) so the policy is defined ONCE and both the
# installer and every tick wrapper source it.
#
# Usage (source it, then read the exported vars):
#
#     . "${HOME}/.ostler/lib/ostler-resource-tier.sh"
#     ostler_resource_tier_detect
#     echo "$OSTLER_TIER $OSTLER_ENRICH_CONCURRENCY"
#
# Or, as a one-shot CLI that prints the policy as KEY=VALUE lines:
#
#     bash ostler-resource-tier.sh
#
# Emitted variables (also printed by the CLI form):
#   OSTLER_TIER                 floor | low | high
#   OSTLER_ENRICH_CONCURRENCY   max simultaneous LLM enrichment jobs (1|2|4)
#   OSTLER_DEFER_NONESSENTIAL   1 = defer non-essential enrichment on first
#                               run; 0 = allow (high tier)
#   OSTLER_LOADAVG_CEILING      per-core 1-min loadavg above which a
#                               non-essential tick defers (tenths allowed)
#   OSTLER_ENRICH_NUM_CTX       reduced num_ctx for ENRICHMENT summaries
#                               ONLY (never the interactive chat); empty on
#                               high tier (use the model default)
#   OSTLER_RAM_GB               detected RAM in whole GB (diagnostics)
#   OSTLER_CPU_CORES            detected total cores (diagnostics)
#   OSTLER_PERF_CORES           detected performance cores (diagnostics)
#
# Fail-safe: every probe degrades to the CONSERVATIVE (floor) tier if it
# cannot read the hardware, so a sysctl quirk can never accidentally
# unleash the unbounded storm. British English throughout.

# Detect RAM in whole GB. Echoes 0 on failure (caller treats 0 as floor).
ostler_rt_ram_gb() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    case "$bytes" in
        ''|*[!0-9]*) echo 0; return 0 ;;
    esac
    echo "$(( bytes / 1073741824 ))"
}

# Detect total logical cores. Echoes 0 on failure.
ostler_rt_cpu_cores() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    case "$n" in
        ''|*[!0-9]*) echo 0; return 0 ;;
    esac
    echo "$n"
}

# Detect performance cores. Apple Silicon exposes
# hw.perflevel0.physicalcpu (P-cores); Intel does not, so fall back to
# physical cores, then to total cores. Echoes 0 on total failure.
ostler_rt_perf_cores() {
    local n
    n="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
    case "$n" in
        ''|*[!0-9]*) n="" ;;
    esac
    if [ -z "${n:-}" ]; then
        n="$(sysctl -n hw.physicalcpu 2>/dev/null || true)"
        case "$n" in
            ''|*[!0-9]*) n="" ;;
        esac
    fi
    if [ -z "${n:-}" ]; then
        n="$(ostler_rt_cpu_cores)"
    fi
    echo "${n:-0}"
}

# Read the 1-minute load average. Echoes it (a decimal) or empty on
# failure. macOS `sysctl -n vm.loadavg` -> "{ 1.23 4.56 7.89 }".
ostler_rt_loadavg_1m() {
    local raw
    raw="$(sysctl -n vm.loadavg 2>/dev/null || true)"
    if [ -z "$raw" ]; then
        # Linux / fallback: /proc/loadavg "1.23 4.56 7.89 ..."
        if [ -r /proc/loadavg ]; then
            raw="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)"
            printf '%s' "$raw"
            return 0
        fi
        return 0
    fi
    # Strip the braces, take the first number.
    printf '%s' "$raw" | tr -d '{}' | awk '{print $1}'
}

# Compose the tier policy. Sets the OSTLER_* vars in the caller's shell.
# Honours pre-set overrides: if OSTLER_TIER is already exported we trust
# it and only fill the blanks (lets tests and operators pin a tier).
ostler_resource_tier_detect() {
    OSTLER_RAM_GB="$(ostler_rt_ram_gb)"
    OSTLER_CPU_CORES="$(ostler_rt_cpu_cores)"
    OSTLER_PERF_CORES="$(ostler_rt_perf_cores)"

    # Allow an explicit override (testing / operator opt-out). An empty or
    # unknown value falls through to detection.
    local tier="${OSTLER_TIER:-}"
    case "$tier" in
        floor|low|high) ;;   # accept
        *) tier="" ;;
    esac

    if [ -z "$tier" ]; then
        # Conservative default: if we could read NOTHING, stay at floor.
        if [ "${OSTLER_RAM_GB:-0}" -le 0 ]; then
            tier="floor"
        elif [ "${OSTLER_RAM_GB}" -ge 32 ]; then
            tier="high"
        elif [ "${OSTLER_RAM_GB}" -ge 16 ]; then
            # 16GB is the installer's hard floor (ERR-02-PREREQ-RAM-LOW),
            # so the LOWEST supported machine sits at LOW, not floor:
            # concurrency 2, qwen3.5:9b. The "floor" tier below is reserved
            # for the sub-16GB / <=4 P-core case (e.g. an 8GB Air, were the
            # prereq ever lowered) and the detection-failure fallback.
            tier="low"
        else
            tier="floor"
        fi
        # Core-count override: <=4 performance cores is a floor machine
        # even if it somehow reports plenty of RAM (e.g. an 8GB Air, were
        # the 16GB prereq ever lowered).
        if [ "${OSTLER_PERF_CORES:-0}" -gt 0 ] && [ "${OSTLER_PERF_CORES}" -le 4 ]; then
            if [ "$tier" = "high" ]; then
                tier="low"
            else
                tier="floor"
            fi
        fi
    fi
    OSTLER_TIER="$tier"

    # Per-tier policy. Operator/test overrides win if already set.
    case "$OSTLER_TIER" in
        high)
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-4}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-0}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-3.0}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-}"
            ;;
        low)
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-2}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-1}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-2.0}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-8192}"
            ;;
        *)  # floor (the conservative fallback)
            OSTLER_TIER="floor"
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-1}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-1}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-1.5}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-4096}"
            ;;
    esac

    export OSTLER_TIER OSTLER_ENRICH_CONCURRENCY OSTLER_DEFER_NONESSENTIAL \
        OSTLER_LOADAVG_CEILING OSTLER_ENRICH_NUM_CTX \
        OSTLER_RAM_GB OSTLER_CPU_CORES OSTLER_PERF_CORES
}

# Decide whether a NON-ESSENTIAL enrichment tick should defer right now.
# Returns 0 (yield) if it should defer, 1 (proceed) otherwise.
#
# A non-essential tick defers when EITHER the tier sets the defer flag
# (floor/low first-run posture) AND the machine is currently busier than
# the tier ceiling, OR -- regardless of the defer flag -- the normalised
# load is already over the ceiling. Essential work never calls this.
#
# "Normalised load" = 1-min loadavg / total cores, compared against
# OSTLER_LOADAVG_CEILING. We avoid floating point (POSIX sh has none) by
# scaling both sides by 100 and comparing integers via awk only for the
# division, falling back to "proceed" if anything is unreadable
# (fail-safe: never wedge background work on a probe quirk).
#
# Args: none. Reads OSTLER_DEFER_NONESSENTIAL, OSTLER_LOADAVG_CEILING,
# OSTLER_CPU_CORES (call ostler_resource_tier_detect first).
ostler_resource_tier_should_defer_nonessential() {
    local defer="${OSTLER_DEFER_NONESSENTIAL:-1}"
    local ceiling="${OSTLER_LOADAVG_CEILING:-1.5}"
    local cores="${OSTLER_CPU_CORES:-0}"

    local load
    load="$(ostler_rt_loadavg_1m)"

    # If we cannot read load or cores, fall back to the defer flag alone:
    # floor/low defer (conservative), high proceeds.
    if [ -z "${load:-}" ] || [ "${cores:-0}" -le 0 ]; then
        if [ "$defer" = "1" ]; then
            return 0
        fi
        return 1
    fi

    # over_ceiling = (load / cores) > ceiling ? 1 : 0, computed in awk so
    # the decimals are honoured. awk failure -> treat as NOT over (proceed).
    local over
    over="$(awk -v l="$load" -v c="$cores" -v cap="$ceiling" \
        'BEGIN { if (c <= 0) { print 0; exit } if ((l / c) > cap) print 1; else print 0 }' \
        2>/dev/null || echo 0)"

    if [ "$over" = "1" ]; then
        return 0   # busy: defer regardless of the flag
    fi

    # Not over the ceiling. Defer only on the floor/low first-run posture
    # is NOT applied here: the off-peak window + interactive marker handle
    # the steady-state drip. The defer flag's job is to keep the FIRST-RUN
    # spike from running at all while load is high, which the over-ceiling
    # check above already enforces. So below the ceiling we proceed.
    return 1
}

# CLI form: print the policy as KEY=VALUE lines (consumable by install.sh
# via `eval`), then exit. Only runs when executed directly, not sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    ostler_resource_tier_detect
    printf 'OSTLER_TIER=%s\n' "$OSTLER_TIER"
    printf 'OSTLER_ENRICH_CONCURRENCY=%s\n' "$OSTLER_ENRICH_CONCURRENCY"
    printf 'OSTLER_DEFER_NONESSENTIAL=%s\n' "$OSTLER_DEFER_NONESSENTIAL"
    printf 'OSTLER_LOADAVG_CEILING=%s\n' "$OSTLER_LOADAVG_CEILING"
    printf 'OSTLER_ENRICH_NUM_CTX=%s\n' "$OSTLER_ENRICH_NUM_CTX"
    printf 'OSTLER_RAM_GB=%s\n' "$OSTLER_RAM_GB"
    printf 'OSTLER_CPU_CORES=%s\n' "$OSTLER_CPU_CORES"
    printf 'OSTLER_PERF_CORES=%s\n' "$OSTLER_PERF_CORES"
fi
OSTLER_RESOURCE_TIER_EOF
chmod +x "${HOME}/.ostler/lib/ostler-resource-tier.sh" 2>/dev/null || true

# Write the per-tick user-control library (resource throttle + Pause) to
# ~/.ostler/lib so every tick wrapper can source it. It carries TWO
# user-facing gates: ostler_runtime_load_env (sources the Doctor Config
# panel's env file so a settings change reaches the wrappers) and
# ostler_pause_active (the user-facing Pause control). QUOTED heredoc, so
# this is a byte-for-byte embed of lib/ostler-runtime.sh -- keep the two
# in sync if either is edited. Also ensure the pause sentinel + config
# dirs exist so the Doctor can write into them on first use.
mkdir -p "${HOME}/.ostler/lib" "${HOME}/.ostler/run" "${HOME}/.ostler/config" 2>/dev/null || true
cat > "${HOME}/.ostler/lib/ostler-runtime.sh" <<'OSTLER_RUNTIME_EOF'
#!/usr/bin/env bash
#
# ostler-runtime.sh
#
# Per-tick user-control gates for the background processing wrappers.
# Sourced at the very top of every tick wrapper (the four conversation
# feeds + the wiki recompile). Two jobs, both user-facing:
#
#   1. ostler_runtime_load_env -- source the Doctor Config panel's env
#      file (~/.ostler/config/ostler.env) so a settings change (preset,
#      quiet hours, governor on/off) actually reaches the wrappers. This
#      is the contract the old config panel was missing: it wrote a YAML
#      nothing read; the panel now ALSO materialises these env knobs and
#      the wrappers source them here.
#
#   2. ostler_pause_active -- the user-facing Pause control. Returns 0
#      (true) when background processing is paused and the pause has not
#      expired, so the wrapper can exit 0 and yield the tick. Live chat
#      and the assistant daemon's foreground turns NEVER call this -- only
#      background ingest / enrich / recompile.
#
# Installed to ~/.ostler/lib/ostler-runtime.sh (same pattern as
# ostler-resource-tier.sh) so it is defined once and every wrapper
# sources it. British English throughout.
#
# Overrides (tests / non-default deployments):
#   OSTLER_ENV_FILE        -> the sourced env file (default
#                             ~/.ostler/config/ostler.env).
#   OSTLER_PAUSE_SENTINEL  -> the pause sentinel (default
#                             ~/.ostler/run/processing.paused).

# Source the Doctor Config env file if present. Absent file = use the
# wrappers' built-in defaults (the pre-panel behaviour), so a fresh
# install with no saved settings is unchanged.
ostler_runtime_load_env() {
    local f="${OSTLER_ENV_FILE:-$HOME/.ostler/config/ostler.env}"
    if [ -f "$f" ]; then
        # shellcheck source=/dev/null
        . "$f"
    fi
}

# Pause sentinel. The Doctor writes the first line as the expiry epoch:
#   - a positive integer  -> paused until that epoch (UTC seconds)
#   - 0 / empty / never    -> paused indefinitely, until the user resumes
# An expired sentinel is removed and treated as not-paused (self-heal),
# so a "Pause 1 hour" cannot wedge background work past its window even
# if the Doctor never runs again. An unparseable first line is treated
# as paused (honour the user intent; the Resume control always clears
# it).
#
# Returns 0 (paused -> caller should yield) or 1 (not paused -> proceed).
ostler_pause_active() {
    local f="${OSTLER_PAUSE_SENTINEL:-$HOME/.ostler/run/processing.paused}"
    [ -f "$f" ] || return 1

    local expiry
    expiry="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    case "$expiry" in
        ''|0|never|forever)
            return 0 ;;            # indefinite pause
        *[!0-9]*)
            return 0 ;;            # unparseable -> honour the pause
        *)
            ;;                     # a plain integer epoch: check expiry
    esac

    local now
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ "${now:-0}" -ge "$expiry" ]; then
        rm -f "$f" 2>/dev/null || true   # expired: self-heal
        return 1
    fi
    return 0
}
OSTLER_RUNTIME_EOF
chmod +x "${HOME}/.ostler/lib/ostler-runtime.sh" 2>/dev/null || true

# Auto-unzip any signature-bearing export zips in the scan dirs FIRST, so the
# content detection below (and the parsers) can read a still-zipped download.
# Runs AFTER the prewarm above has cleared the TCC prompts and AFTER the lib is
# written, so the call always finds it. Name-agnostic; failure-tolerant.
for _sd in "${HOME}/Downloads" "${HOME}/Desktop" "${HOME}/Documents"; do
    [[ -d "$_sd" ]] || continue
    bash "${HOME}/.ostler/lib/ostler-detect-exports.sh" "$_sd" --unzip >/dev/null 2>&1 || true
done

for search_dir in "${HOME}/Downloads" "${HOME}/Desktop" "${HOME}/Documents"; do
    [[ -d "$search_dir" ]] || continue

    # #619: distinguish a permission-denied folder from an empty one.
    # The find scans below all end `2>/dev/null || true`, so an access
    # denial yields zero hits indistinguishable from "nothing here" --
    # the customer's exports could be sitting in this folder, unreadable,
    # and they would be told nothing was found. Record the denial and
    # skip this folder's scan; the post-scan block surfaces it.
    if ! _gdpr_folder_readable "$search_dir"; then
        DENIED_FOLDERS+=("$search_dir")
        continue
    fi

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

    # Facebook: folder containing your_friends.json (2026 export name) or
    # legacy friends.json. CX-126: the old `-path "*/facebook*"` filter was
    # dropped -- the current export unzips to `your_facebook_activity/`
    # (no "facebook" substring), so the filter silently excluded every
    # real 2026 export from the "found N" display. The filename is
    # specific enough on its own; maxdepth 5 covers the deeper
    # your_facebook_activity/connections/friends/ nesting.
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Facebook: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 5 \( -name "your_friends.json" -o -name "friends.json" \) 2>/dev/null || true)

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

    # Twitter/X: tweets.js (2026 export name) or legacy tweet.js, in a
    # data/ directory. CX-126: current X exports ship `tweets.js`; the
    # detector only greps `tweet.js`, so the "found N" display omitted
    # every current export (the CM019 preferences parser already ingests
    # both, so this only makes the display + EXPORTS_DIR seeding honest).
    while IFS= read -r f; do
        DETECTED_EXPORTS+=("Twitter/X: $(dirname "$f")")
        EXPORTS_DIR="${EXPORTS_DIR:-$(dirname "$(dirname "$f")")}"
    done < <(find "$search_dir" -maxdepth 4 \( -name "tweets.js" -o -name "tweet.js" \) -path "*/data/*" 2>/dev/null || true)

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

# #619: surface any folder the scan could not read. Without this, a
# permission-denied folder is silently indistinguishable from an empty
# one and the customer is told "no exports found" while their exports
# sit unread. Name each denied folder and route the customer toward the
# manual-exports path below (and toward granting access + re-running).
if [[ ${#DENIED_FOLDERS[@]} -gt 0 ]]; then
    echo ""
    for denied_dir in "${DENIED_FOLDERS[@]}"; do
        warn "$(printf "$MSG_WARN_FOLDER_ACCESS_DENIED_SCAN" "${denied_dir}")"
    done
    info "$MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE"
fi

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
    # #619: be honest about WHY nothing was found. If a folder was
    # denied, "no exports found" is misleading -- the scan was blocked,
    # not the folder empty. The manual-exports prompt below is the route
    # in either case, so a denial is never a silent dead-end.
    if [[ ${#DENIED_FOLDERS[@]} -gt 0 ]]; then
        info "$MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS"
    else
        info "$MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP"
    fi
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
" 2>/dev/null) || EXTRACTED_MBOX=""
            # CX-127: the helper above exits 1 when the zip holds no .mbox
            # (e.g. a SPLIT multi-part Google Takeout -- takeout-...-6-001.zip
            # whose non-first part has no mailbox) or on any zip exception.
            # Under the script-wide `set -Eeuo pipefail`, a bare
            # `VAR=$(... exit 1)` assignment aborts the WHOLE install on the
            # spot -- jumping over the graceful warn-and-continue branch just
            # below and killing a fully-recoverable optional step with no
            # error and no DONE marker (the GUI then shows "failed"). The
            # `|| EXTRACTED_MBOX=""` neutralises the errexit abort so the
            # empty-result handler below runs as designed. Same set -e family
            # as #640 / #643.
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

# #48g historical backfill (CX-84/85/86): auto-detect the optional
# third-party sources so the picker can include them when the customer
# actually has the app installed. Without these probes WhatsApp +
# Chrome remain dead code: the FDA extractor only fires when the source
# is in OSTLER_FDA_SOURCES, and the source was never offered.
#
# Heuristics (file-existence only -- no FDA at this point, that is
# granted later in Phase 3 just before extract_all runs):
#   WhatsApp Desktop: the Mac App Store build writes its sqlite to
#       ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite
#   Chrome: any Chrome / Chromium profile writes a History sqlite to
#       ~/Library/Application Support/Google/Chrome/Default/History
HAS_WHATSAPP_DESKTOP=false
if [[ -f "${HOME}/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite" ]]; then
    HAS_WHATSAPP_DESKTOP=true
fi
HAS_CHROME=false
if [[ -f "${HOME}/Library/Application Support/Google/Chrome/Default/History" ]]; then
    HAS_CHROME=true
fi

# DMG fix 3 (#618 partial): name Chrome in the Recommended description
# (TTY menu) when it is installed, so a Chrome-primary customer sees
# that their real main browser is included. The GUI preset label
# (MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED) already promises this.
_recommended_chrome_note=""
if [[ "$HAS_CHROME" == true ]]; then
    _recommended_chrome_note=", Chrome history"
fi

cat <<MENU

  Three presets, or pick each one yourself:

    [1] Recommended  Safari history + bookmarks, Notes, Calendar,
                     Reminders, iMessage, Apple Mail${_recommended_chrome_note}. The
                     everyday sources -- privacy-friendly, all local.

    [2] Everything   The above + WhatsApp + Chrome (if installed),
                     Photos events (NOT face recognition). Slower,
                     more depth.

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
#
# #48g (2026-05-29): RECOMMENDED now includes imessage + apple_mail so it
# matches the customer-facing copy at MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED
# ("Includes Apple Mail, Contacts, Calendar, Notes, Messages, Reminders,
# and Safari history"). Pre-fix the strings file promised those sources
# but the bash var did not include them, so install completed with the
# wiki empty of iMessage + email-correspondent data on every install.
RECOMMENDED="safari_history,safari_bookmarks,apple_notes,calendar,reminders,imessage,apple_mail"

# DMG fix 3 (#618 partial): most customers are Chrome-primary, so a
# Recommended install must ingest Chrome history too when Chrome is
# installed -- otherwise it silently captures the barely-used Safari and
# misses the real main browser. chrome_history.py already ships and is
# exercised by the Everything path; this just lists the source. Safari
# stays in Recommended regardless (harmless if empty). Without Chrome,
# Recommended is unchanged. The GUI preset label already promises this
# (MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED) -- the var was the gap, the
# same strings-promise-vs-var mismatch as the #48g imessage/apple_mail
# fix. Brave / Edge / Arc / Firefox stay post-launch (#618).
if [[ "$HAS_CHROME" == true ]]; then
    RECOMMENDED="${RECOMMENDED},chrome_history"
fi

# EVERYTHING adds whatsapp_history + photos conditionally -- the
# extractors throw FileNotFoundError if the source DB is missing, so it
# is safe to list them, but skipping the listing when the app isn't
# installed keeps the post-install summary honest ("Found 0 WhatsApp
# people" reads as a bug; not listing the source reads as fine).
# chrome_history is inherited from RECOMMENDED above, so it is NOT
# re-added here (a duplicate in OSTLER_FDA_SOURCES would double-list it).
EVERYTHING="${RECOMMENDED},photos_metadata"
if [[ "$HAS_WHATSAPP_DESKTOP" == true ]]; then
    EVERYTHING="${EVERYTHING},whatsapp_history"
fi

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
        _ask_source "imessage"         "iMessage                " Y
        if [[ "$HAS_APPLE_MAIL_GMAIL" == true ]]; then
            _ask_source "apple_mail" "Apple Mail (incl. Gmail) " Y
        else
            _ask_source "apple_mail" "Apple Mail               " Y
        fi
        echo ""
        echo "  Third-party apps (default on if the app is installed):"
        # WhatsApp Desktop + Chrome are off-by-default unless the app
        # was detected at section 9.5 entry. The extractor returns
        # FileNotFoundError if you tick the box without the app, so a
        # mistaken tick is recoverable; we just don't push the customer
        # to tick what is dead-on-arrival.
        if [[ "$HAS_WHATSAPP_DESKTOP" == true ]]; then
            _ask_source "whatsapp_history" "WhatsApp Desktop history  " Y
        else
            _ask_source "whatsapp_history" "WhatsApp Desktop history  " N
        fi
        if [[ "$HAS_CHROME" == true ]]; then
            _ask_source "chrome_history"   "Chrome history            " Y
        else
            _ask_source "chrome_history"   "Chrome history            " N
        fi
        _ask_source "photos_metadata"  "Photos events (no faces)  " N
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

# #48g: auto-add the third-party sources to RECOMMENDED too when their
# app is installed. The customer who picked Recommended did NOT see a
# WhatsApp / Chrome tickbox; the only signal is "the app exists on
# this Mac". The opt-out path is the Customise preset.
#
# Rationale (Andy 2026-05-29): the wiki being empty post-install is a
# customer-trust killer. If you have WhatsApp Desktop installed, you
# almost certainly want your WhatsApp contacts in your People graph;
# the install-time FDA-grant moment is the one chance to capture them
# without an extra UI flow. Same logic for Chrome.
if [[ "$PRESET" == "recommended" || "$PRESET" == "1" ]]; then
    if [[ "$HAS_WHATSAPP_DESKTOP" == true ]]; then
        OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES},whatsapp_history"
    fi
    if [[ "$HAS_CHROME" == true ]]; then
        OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES},chrome_history"
    fi
fi

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
                gui_cancelled   # CX-126: neutral cancelled terminal, not a failure
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
    # Q19 consent_third_party: GDPR-grade consent must be an active opt-in.
    # Default seeded as "n" so the customer must explicitly toggle to Yes
    # (the GUI's yesValue() returns true for empty strings, which would
    # otherwise pre-check the Yes toggle and amount to a pre-ticked box).
    THIRD_PARTY="$(gui_read "$MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE" yesno "n" "$MSG_PROMPT_CONSENT_THIRD_PARTY_HELP" "" "consent_third_party")"
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
            gui_cancelled   # CX-126: neutral cancelled terminal, not a failure
            exit 0
            ;;
        *)
            echo "  Please answer Y or N."
            ;;
    esac
done

# ── 10b-ts. Tailscale DECISION -- hoisted upfront (WALK-1 / Wave 2.1) ──
#
# WALK-1 (2026-06-19, Andy's live walk): the Tailscale setup/skip CHOICE
# used to fire deep in Phase 3 (~L12255, roughly 86% through the install),
# breaking the locked "answer the questions upfront, then walk away"
# promise -- a customer who left the install running came back to a
# blocking "Connect your iPhone and Watch / setup or skip" dialog mid-run.
#
# Fix: collect the DECISION here, in the Phase-2 questions block, exactly
# as CX-37 / CX-130 hoisted the Apple Mail prompts. The actual Tailscale
# install + browser sign-in stays in Phase 3 (it needs Homebrew + the
# tailscale binary, both established later), but it is now PRE-ANNOUNCED
# below and runs without any surprise decision prompt: the late code reads
# the answer collected here via TAILSCALE_CONFIRM_SHOWN_EARLY and never
# re-prompts. So the long unattended middle has zero human decision gates;
# the only late interaction is the expected, pre-announced sign-in step
# (URL printed + browser opened + a timed wait), which is informational,
# not a blocking question.
#
# Belt-and-braces like the Mail probes: a non-GUI (TTY) operator still
# gets the gui_read fallback; the SHOWN_EARLY guard is set unconditionally
# once we have asked (or decided not to ask), so the Phase-3 site is fully
# driven by the upfront answer.
if [[ -z "${TAILSCALE_CONFIRM_SHOWN_EARLY:-}" ]]; then
    TAILSCALE_CONFIRM="$(gui_read "$MSG_PROMPT_TAILSCALE_CONFIRM_TITLE" choice "setup" "$MSG_PROMPT_TAILSCALE_CONFIRM_HELP" "setup,skip" "tailscale_confirm")"
    TAILSCALE_CONFIRM_SHOWN_EARLY=1
    export TAILSCALE_CONFIRM TAILSCALE_CONFIRM_SHOWN_EARLY
    # Pre-announce the late sign-in step so the customer knows that, while
    # they CAN walk away for the unattended middle, there is one short
    # optional step waiting for them near the end if they chose "setup".
    if [[ "${TAILSCALE_CONFIRM:-setup}" == "setup" ]]; then
        info "$MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE"
    fi
fi

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
        gui_cancelled   # CX-126: neutral cancelled terminal, not a failure
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
step "$MSG_STEP_SETUP_COMPLETE_WRAP_UP" "setup_complete_wrap_up"

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
    sudo -v || fail_with_code "ERR-04-SUDO-DENIED" "$MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL"
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
# OSTLER_PRELAUNCH_PROMOTED was declared early (near the OSTLER_DIR
# definitions at the top of the script) so the Phase-2 re-run branch
# could call _ostler_promote_prelaunch_tree before this trap was
# registered. The cleanup stanza below reads it; we deliberately do
# NOT redeclare here to avoid clobbering a "true" value the Phase-2
# branch may already have set.

composite_cleanup() {
    # ─── CX-454 EXIT backstop (runs FIRST, before any cleanup) ───
    # The load-bearing half of the mid-script-death fix. On bash 3.2 a
    # `set -u` unbound-variable abort skips the ERR trap and can mask
    # its exit code to 0 (verified), so the ONLY reliable signal that we
    # died mid-install is: a step had started AND no terminal DONE
    # marker was ever emitted. In that case emit a synthetic DONE-fail
    # naming the failing step BEFORE we tear down resources, so the GUI
    # shows a real failure with a code + step instead of the generic
    # no-DONE catch-all. Guards:
    #   - OSTLER_DONE_EMITTED empty: no ok/fail/cancelled marker went
    #     out (a clean success, an explicit fail, or a user-cancel all
    #     set it, so none of those false-trigger here).
    #   - __OSTLER_STEP_ID non-empty: the install had actually begun, so
    #     an early `--help`/`--version`/pre-step `exit 0` (which never
    #     opens a step) cannot be mislabelled as a failure.
    # Fully ${VAR:-}-guarded so the backstop itself is set -u safe.
    # ─── OSTLER_EXIT_BACKSTOP_BEGIN ───
    if [[ -z "${OSTLER_DONE_EMITTED:-}" && -n "${__OSTLER_STEP_ID:-}" ]]; then
        OSTLER_LAST_ERROR_CODE="ERR-99-INSTALL-ABORT-${__OSTLER_STEP_ID}"
        export OSTLER_LAST_ERROR_CODE
        gui_log error "Install aborted before completion during step '${__OSTLER_STEP_ID}' with no completion marker (likely a set -u unbound-variable abort)."
        gui_done fail
    fi
    # ─── OSTLER_EXIT_BACKSTOP_END ───

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
    # CX-87 (DMG #48g): wipe the pre-FDA staging tree if we are
    # exiting before the promotion step ran. If a staging-tree
    # install log exists, copy it to a failsafe location first so
    # support has a paper trail even after cleanup. The failsafe
    # path is /tmp-anchored + PID-stamped so concurrent installs
    # do not collide, and survives the cleanup because we don't
    # touch it after the copy.
    if [[ "$OSTLER_PRELAUNCH_PROMOTED" != "true" \
       && -n "${OSTLER_PRELAUNCH_DIR:-}" \
       && -d "$OSTLER_PRELAUNCH_DIR" ]]; then
        if [[ -f "${OSTLER_PRELAUNCH_DIR}/logs/install.log" ]]; then
            cp "${OSTLER_PRELAUNCH_DIR}/logs/install.log" \
               "/tmp/ostler-install-failsafe-$$.log" 2>/dev/null || true
        fi
        rm -rf "$OSTLER_PRELAUNCH_DIR" 2>/dev/null || true
    fi
}
trap composite_cleanup EXIT
# _ostler_promote_prelaunch_tree is defined early (near the path
# variable setup at the top of this script) so the Phase-2 re-run
# branch can call it before this trap is registered. See the
# block under the "Atomic-promote the pre-FDA staging tree" comment
# above the path-variable setup.

# ─── OSTLER_ERR_TRAP_BEGIN (CX-454 / task #454) ───────────────────
# Report a mid-script death as a loud DONE-fail BEFORE the script
# exits, so the GUI surfaces a real failure with a step + stable code
# instead of the generic "stopped before it finished" catch-all (or,
# historically, a masked green success).
#
# TWO HANDLERS, because of a VERIFIED bash 3.2 behaviour (3.2.57 is the
# system bash on the customer's Mac, both /bin/bash and PATH):
#
#   1. The ERR trap fires only for a genuine COMMAND failure under
#      `set -e` (e.g. an uncaught `docker`/`cp` non-zero). On bash 3.2
#      it does NOT fire for a `set -u` unbound-variable abort -- that
#      death happens during word expansion, skips the ERR trap, AND can
#      surface with a MASKED exit code of 0 (verified). Since the
#      unbound-var abort is the single most common install death shape
#      (CX-18/52/95/98 were all this), an ERR trap ALONE would miss the
#      class this task is aimed at. The ERR trap is still worth keeping:
#      for the command-failure class it gives the precise failing line.
#
#   2. The EXIT backstop (top of composite_cleanup) is the load-bearing
#      net. The EXIT trap DOES fire on a `set -u` abort (verified), so
#      if the install had started (a step id exists) and NO terminal
#      DONE marker was emitted, it emits a synthetic DONE-fail naming
#      the step that was running. This catches the unbound-var /
#      exit-code-masked class the ERR trap cannot see.
#
# `set -E` (errtrace, set at the top of the script) makes the ERR trap
# fire for command failures inside functions, not just at top level.
#
# Both handlers are `set -u` safe (every var read via ${VAR:-}) so the
# reporter can never trip `set -u` and die while reporting.
_ostler_on_err() {
    local exit_code="${1:-1}"
    local line="${2:-0}"
    local cmd="${3:-}"
    # If a terminal DONE marker already went out (an explicit
    # fail/fail_with_code, a clean gui_done ok, a cancel, or a prior
    # ERR fire), stay silent: report exactly once, and never overwrite
    # a curated ERR-NN-* with the synthetic ERR-99.
    if [[ -n "${OSTLER_DONE_EMITTED:-}" ]]; then
        return
    fi
    # Synthetic, stable, support-greppable code carrying the failing
    # line. Documented shape: ERR-99-INSTALL-ABORT-L<line>.
    OSTLER_LAST_ERROR_CODE="ERR-99-INSTALL-ABORT-L${line}"
    export OSTLER_LAST_ERROR_CODE
    # Record command + step + line in the LOG stream (already redacted
    # by the GUI's LogRedactor) so support has the raw context. Keep the
    # raw command OFF the customer banner -- the banner carries step +
    # code only, via the DONE marker below.
    local step="${__OSTLER_STEP_ID:-}"
    gui_log error "Install aborted unexpectedly at line ${line}${step:+ (step ${step})}: ${cmd}"
    # Emit the one DONE-fail marker the GUI keys on. gui_done attaches
    # OSTLER_LAST_ERROR_CODE as code= AND sets OSTLER_DONE_EMITTED, so
    # the EXIT backstop below then stays silent.
    gui_done fail
}
trap '_ostler_on_err $? $LINENO "$BASH_COMMAND"' ERR
# ─── OSTLER_ERR_TRAP_END ──────────────────────────────────────────

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
    echo -e "  ${GREEN}  You can walk away -- this takes 15-60 minutes, depending on how much history is on your Mac.${NC}"
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

# CX-22 (2026-05-23, retest #16): if CLT was triggered at prereq-check
# phase, the customer has been answering questions for ~5 min while CLT
# downloads in background. By the time we get here, CLT is usually
# ready. If it isn't, wait now -- but with progress emits so the
# customer (and the GUI watchdog) see we're alive. This is the ONLY
# wait-for-CLT block in install.sh; the prereq-check phase trigger is
# fire-and-forget.
if ! /usr/bin/xcode-select -p &>/dev/null; then
    info "$MSG_INFO_WAITING_FOR_CLT_TO_FINISH"
    XCODE_WAIT=0
    XCODE_TIMEOUT=900  # 15 minutes -- generous; CLI install is ~150 MB
    LAST_HEARTBEAT=0
    XCODE_REPOPPED=0
    until /usr/bin/xcode-select -p &>/dev/null; do
        if [[ $XCODE_WAIT -ge $XCODE_TIMEOUT ]]; then
            fail_with_code "ERR-02-PREREQ-XCODE-CLI" "$MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID"
        fi
        sleep 10
        XCODE_WAIT=$((XCODE_WAIT + 10))
        # .153 cold-wipe walk: the wait is driven by the macOS "install
        # developer tools?" GUI dialog, which the customer must CLICK. If
        # they look away (as on .153) the only repeated line was a passive
        # "Still waiting...", reading as a download in progress -- so they
        # never clicked, and a dismissed/lost dialog would silently burn the
        # full 15-min timeout into ERR-02. Two safe, no-sudo mitigations:
        #
        # (a) Re-pop the dialog ONCE at ~2 min. `xcode-select --install` is
        #     user-level; if the install is genuinely running it no-ops, if
        #     the dialog was dismissed it comes back. `|| true` keeps it
        #     errexit-safe.
        if [[ $XCODE_REPOPPED -eq 0 && $XCODE_WAIT -ge 120 ]]; then
            /usr/bin/xcode-select --install &>/dev/null || true
            XCODE_REPOPPED=1
        fi
        # (b) Heartbeat every 30s so the GUI watchdog stays quiet AND the
        # customer sees an ACTIONABLE line (click the dialog), not a passive
        # "still waiting" that hides the pending click.
        if (( XCODE_WAIT - LAST_HEARTBEAT >= 30 )); then
            info "$(printf "$MSG_INFO_CLT_STILL_INSTALLING_ELAPSED" "$XCODE_WAIT")"
            LAST_HEARTBEAT=$XCODE_WAIT
        fi
    done
    ok "$MSG_OK_GIT_AVAILABLE"
fi

if command -v brew &>/dev/null; then
    ok "$MSG_OK_HOMEBREW_INSTALLED"
else
    info "$MSG_INFO_INSTALLING_HOMEBREW"
    # Under OSTLER_GUI=1 the parent .app has pre-created /opt/homebrew
    # owned by the user, AND NONINTERACTIVE=1 tells Homebrew's official
    # installer to skip its own sudo dialog + tty-only prompts (it
    # would otherwise re-prompt for password even when the prefix is
    # already user-owned, then fail because the GUI has no tty).
    #
    # CX-24 (2026-05-24, Studio retest #18): the Homebrew installer
    # was dying sub-second with NO captured output, leaving us
    # zero diagnostic info. Capture stderr+stdout to a log file so
    # any failure surfaces a real error message in the customer log
    # (and in the failure banner mailto via the log Reference line).
    BREW_INSTALL_LOG="/tmp/ostler-brew-install.log"
    rm -f "$BREW_INSTALL_LOG"

    # Pre-probe state that affects Homebrew installer behaviour, so
    # the captured log starts with context (sudo cache age, prefix
    # ownership) before the actual install attempt. Helps future
    # diagnosis when this fails again on a different fresh-Mac
    # variant.
    {
        echo "=== Homebrew install context ($(date -u +"%Y-%m-%dT%H:%M:%SZ")) ==="
        echo "USER=$(id -un) (uid=$(id -u))"
        echo "OSTLER_GUI=${OSTLER_GUI:-0}"
        echo "ARCH=$ARCH"
        echo "PATH=$PATH"
        echo "--- /opt/homebrew owner check ---"
        ls -ld /opt /opt/homebrew 2>&1 || true
        echo "--- sudo -nv test (does sudo work without prompt?) ---"
        sudo -nv 2>&1 || echo "sudo -nv failed: cached credentials unavailable"
        echo "--- xcode-select state ---"
        xcode-select -p 2>&1 || true
        echo "--- /usr/bin/git --version ---"
        /usr/bin/git --version 2>&1 || true
        echo "=== Homebrew installer output begins ==="
    } > "$BREW_INSTALL_LOG"

    set +e
    # CX-25 (2026-05-24, Studio retest #19): Homebrew's official curl|bash
    # installer aborts at have_sudo_access() UNCONDITIONALLY -- even when
    # the prefix is pre-chowned and no sudo is actually needed. From the
    # captured log: "Need sudo access on macOS (e.g. the user needs to
    # be an Administrator)!" despite andy being in the admin group and
    # /opt/homebrew being owned by andy:admin.
    #
    # Manual tarball install sidesteps the official script's sudo check
    # entirely. /opt/homebrew is pre-chowned by the parent .app at install
    # start, so we have write access to the prefix without sudo. Homebrew
    # docs document this as a supported install path -- "Just clone or
    # unpack the source tarball wherever you want it".
    #
    # https://docs.brew.sh/Installation#untar-anywhere-unsupported
    if [[ "${OSTLER_GUI:-0}" == "1" ]] && [[ -d /opt/homebrew ]] && [[ -w /opt/homebrew ]]; then
        echo "Using manual tarball install (prefix is pre-chowned)" >> "$BREW_INSTALL_LOG"
        curl -fsSL https://github.com/Homebrew/brew/tarball/master 2>>"$BREW_INSTALL_LOG" \
            | tar xz --strip 1 -C /opt/homebrew 2>>"$BREW_INSTALL_LOG"
        BREW_EXIT=${PIPESTATUS[0]:-0}
        # If curl succeeded, validate via brew --version. If brew is
        # broken (bad tarball, missing files), this catches it.
        if [[ $BREW_EXIT -eq 0 ]]; then
            if [[ -x /opt/homebrew/bin/brew ]]; then
                /opt/homebrew/bin/brew --version >> "$BREW_INSTALL_LOG" 2>&1
                BREW_EXIT=$?
            else
                echo "FAIL: /opt/homebrew/bin/brew not found after tarball extract" >> "$BREW_INSTALL_LOG"
                BREW_EXIT=1
            fi
        fi
    else
        # Fallback: official installer (used in dev mode where /opt/homebrew
        # is not pre-chowned, OR if pre-chown silently failed).
        echo "Falling back to official installer (prefix not pre-chowned)" >> "$BREW_INSTALL_LOG"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$BREW_INSTALL_LOG" 2>&1
        BREW_EXIT=$?
    fi
    set -e

    if [[ $BREW_EXIT -ne 0 ]]; then
        warn "$(printf "$MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT" "$BREW_EXIT")"
        warn "$MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES"
        # Surface the last 30 lines via warn() so the GUI's prefix-aware
        # log parser actually renders them in the customer log. The
        # earlier tail|sed pattern emitted plain stdout lines that the
        # GUI dropped (CX-24 retest #19 caught this -- the diagnostic
        # text was there in the file but invisible in the GUI).
        while IFS= read -r line; do
            warn "    $line"
        done < <(tail -30 "$BREW_INSTALL_LOG")
        fail_with_code "ERR-04-HOMEBREW-INSTALL" "$MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED"
    fi

    if [[ "$ARCH" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "$MSG_OK_HOMEBREW_INSTALLED"
fi

# ── DMG #48 post-Homebrew verification ─────────────────────────────
#
# Studio retest of DMG #47 (2026-05-27) silently flowed past this
# point even though /opt/homebrew/bin/brew did not exist on disk.
# Walk the post-condition byte-by-byte per
# [[feedback-silent-bail-regression-test-shape]]: a future regression
# (e.g. CX-25 tarball install partial-success, sudo cache eviction
# mid-curl, network drop) MUST stop the install here rather than
# leave colima/tailscale/ollama to silent-no-op downstream.
if ! [[ -x /opt/homebrew/bin/brew ]]; then
    fail_with_code "ERR-04-DMG48-HOMEBREW-MISSING-AFTER-INSTALL" \
        "$(printf "$MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL" "${BREW_INSTALL_LOG:-$INSTALL_LOG}")"
fi
if ! command -v brew &>/dev/null; then
    fail_with_code "ERR-04-DMG48-HOMEBREW-NOT-ON-PATH" "$MSG_FAIL_HOMEBREW_NOT_ON_PATH"
fi

# ── 3.1b GNU coreutils (gtimeout) ──────────────────────────────────
#
# Stock macOS ships NO `timeout` and NO `gtimeout`. The hydrate_*
# phases later in the install each pick a timeout wrapper
# (gtimeout > timeout > empty) and, when both are absent, run the
# ingest UNBOUNDED. An iMessage backfill has been observed running
# 27 minutes (1647s) silently, which reads as a frozen GUI row and
# the customer force-quits a still-healthy install.
#
# Homebrew is guaranteed present by this point (Phase 3.1 hard-fails
# above if it is not), so install GNU coreutils now -- BEFORE the
# first hydrate phase -- so `gtimeout` exists and the existing
# wrap-pickers actually fire. Non-fatal: if the formula cannot be
# poured the hydrate caps simply stay no-ops as before, but the
# heartbeat added to the long hydrate steps still keeps the GUI
# from looking hung.
if ! command -v gtimeout &>/dev/null; then
    info "$MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT"
    brew install coreutils >/tmp/ostler-coreutils-install.log 2>&1 || true
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    if command -v gtimeout &>/dev/null; then
        ok "$MSG_OK_COREUTILS_GTIMEOUT_INSTALLED"
    else
        warn "$MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE"
    fi
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
        # DMG #48 silent-bail hardening: brew install can exit 0 even
        # when a formula fails to deploy its binary (tap conflict,
        # symlink clash, network drop mid-pour). Walk the
        # post-condition byte-by-byte.
        if ! command -v colima &>/dev/null; then
            fail_with_code "ERR-06-DMG48-COLIMA-MISSING-AFTER-BREW" \
                "$(printf "$MSG_FAIL_COLIMA_MISSING_AFTER_BREW" "$INSTALL_LOG")"
        fi
        if ! command -v docker &>/dev/null; then
            fail_with_code "ERR-06-DMG48-DOCKER-CLI-MISSING-AFTER-BREW" \
                "$(printf "$MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW" "$INSTALL_LOG")"
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

            # CX-80 (task #509, v1.0.1): the lima hostagent that
            # backs Colima discovers + forwards the guest's Docker
            # socket port asynchronously after `colima start` returns.
            # On a cold first boot the hostagent port-discovery can
            # race: `colima start` either exits non-zero ("error at
            # instance: failed to get the host agent ... no forwarded
            # port") OR exits 0 but leaves ${HOME}/.colima/default/
            # docker.sock unforwarded, so the very next `docker info`
            # cannot reach the daemon. The DMG #46 Studio retest hit
            # exactly this: containers never came up and :8044 wiki
            # was unreachable. The old single-shot `colima start ||
            # fallback` had no retry, so one transient port-discovery
            # miss dropped the customer straight to the Docker Desktop
            # fallback (or a hard fail) even though a plain retry
            # recovers it 100% of the time in practice.
            #
            # Self-heal: try up to COLIMA_START_MAX_ATTEMPTS times with
            # a short backoff. Between attempts run `colima stop` to
            # clear the half-started instance so the next `colima
            # start` begins from a clean state rather than tripping on
            # "instance already running but socket not forwarded". Log
            # each attempt. Only after the bounded retries are
            # exhausted do we fall through to the Docker Desktop
            # fallback / hard fail. Readiness is the `docker info`
            # wait loop further below; here we just need ONE clean
            # start that leaves the socket reachable.
            COLIMA_START_MAX_ATTEMPTS=3
            COLIMA_START_BACKOFF=5
            colima_started=0
            for colima_attempt in $(seq 1 "$COLIMA_START_MAX_ATTEMPTS"); do
                info "$(printf "$MSG_INFO_COLIMA_START_ATTEMPT" "$colima_attempt" "$COLIMA_START_MAX_ATTEMPTS")"
                # Allocate enough resources for 3 containers.
                if colima start --cpu 2 --memory 4 --disk 30 2>/dev/null \
                    && docker info &>/dev/null 2>&1; then
                    colima_started=1
                    break
                fi
                if [[ "$colima_attempt" -lt "$COLIMA_START_MAX_ATTEMPTS" ]]; then
                    warn "$(printf "$MSG_WARN_COLIMA_START_RETRY" "$COLIMA_START_BACKOFF")"
                    # Clear the half-started instance so the next
                    # attempt re-runs port-discovery from scratch.
                    colima stop --force 2>/dev/null || colima stop 2>/dev/null || true
                    sleep "$COLIMA_START_BACKOFF"
                fi
            done

            if [[ "$colima_started" -ne 1 ]]; then
                warn "$MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP"
                if [[ -d "/Applications/Docker.app" ]]; then
                    open -a Docker 2>/dev/null || true
                else
                    fail_with_code "ERR-06-DOCKER-COLIMA-FAIL" "$MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD"
                fi
            fi
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
        fail_with_code "ERR-06-DOCKER-NOT-AVAILABLE" "$MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER"
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

# CX-43 / Ollama-runner fix (2026-06-02). Install the CASK
# (Ollama.app), not the Homebrew FORMULA.
#
# The formula's `ollama` (0.30.0) ships ONLY an MLX runner and NO
# llama-server, so every GGUF model (nomic-embed-text, the qwen
# conversation models) returns HTTP 500 "llama-server not found":
# the embedding pipeline dies, Qdrant stays empty, the People card /
# iOS People tab / semantic search / browsing all come up blank, and
# the assistant is mute. The cask bundles llama-server (validated on
# the Studio: /api/embed -> 200, 768-dim). The formula cannot serve
# our models at all -- this is a hard blocker, not a preference.
#
# CX-14 E1 (2026-05-23) originally chose the formula to dodge the
# cask's Gatekeeper "downloaded from internet" quarantine dialog on
# the .app's first GUI launch. We honour E1's actual goal (no
# mid-install dialog) by a DIFFERENT mechanism, not by reverting to
# the broken formula:
#   1. We never `open -a Ollama` (a GUI launch is what triggers the
#      app-launch quarantine dialog). We run the inner CLI binary
#      headless -- /Applications/Ollama.app/Contents/Resources/ollama
#      serve -- under our own com.ostler.ollama LaunchAgent. Launching
#      the inner binary never fires the app-launch dialog (Studio:
#      no prompt, embed 200).
#   2. We defensively strip the quarantine xattr from the bundle after
#      install, so even a stricter Gatekeeper cannot block the exec.
# Net: no mid-install dialog (E1's real concern) AND a working
# llama-server (the bug E1 did not know about).

OLLAMA_APP_BIN="/Applications/Ollama.app/Contents/Resources/ollama"

# Detect the CASK specifically. A bare `command -v ollama` is
# satisfied by a pre-existing broken FORMULA on PATH and would wrongly
# skip the cask install, so path-match the app binary instead.
if [[ -x "$OLLAMA_APP_BIN" ]]; then
    ok "$MSG_OK_OLLAMA_INSTALLED"
else
    # If the broken formula is present it shadows the cask binary on
    # PATH and its brew-services launchd respawns it onto :11434 even
    # after a pkill, so tear the service down AND uninstall the formula
    # before the cask goes in.
    if brew list --formula 2>/dev/null | grep -qx ollama; then
        info "$MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA"
        brew services stop ollama 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/homebrew.mxcl.ollama" 2>/dev/null || true
        brew uninstall --formula ollama 2>/dev/null || true
    fi

    info "$MSG_INFO_INSTALLING_OLLAMA"
    brew install --cask ollama-app
    # Belt-and-braces de-quarantine (CX-14 E1's concern, neutralised).
    xattr -dr com.apple.quarantine /Applications/Ollama.app 2>/dev/null || true
    # DMG #48 silent-bail hardening: verify the CASK binary exists
    # before declaring success (not a bare `command -v`).
    if [[ ! -x "$OLLAMA_APP_BIN" ]]; then
        fail_with_code "ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW" \
            "$(printf "$MSG_FAIL_OLLAMA_MISSING_AFTER_BREW" "$INSTALL_LOG")"
    fi
    ok "$MSG_OK_OLLAMA_INSTALLED"
fi

if curl -s http://localhost:11434/api/tags &>/dev/null; then
    ok "$MSG_OK_OLLAMA_RUNNING"
else
    info "$MSG_INFO_STARTING_OLLAMA"
    # Serve headless via our own LaunchAgent running the cask's inner
    # binary (NOT `open -a Ollama`, NOT brew services). This persists
    # across reboots and avoids the GUI app-launch quarantine dialog.
    OLLAMA_LOG_DIR="${LOGS_DIR:-${HOME}/.ostler/logs}"
    mkdir -p "$OLLAMA_LOG_DIR" "${HOME}/Library/LaunchAgents"
    OLLAMA_PLIST="${HOME}/Library/LaunchAgents/com.ostler.ollama.plist"

    # Resource-tier governor (v1.0.3): OLLAMA_NUM_PARALLEL scales to the
    # hardware tier. A second decode slot reserves chat headroom against
    # background enrichment, but on the FLOOR tier (sub-16GB / <=4 P-core)
    # the extra KV cache is RAM the machine cannot spare, so it drops to 1
    # (chat queues briefly behind a background decode rather than swapping).
    # LOW (16GB floor that ships today) and HIGH keep 2. Fail-safe: if the
    # tier lib is missing we keep the historic 2.
    OSTLER_NUM_PARALLEL=2
    _ostler_tier_lib="${HOME}/.ostler/lib/ostler-resource-tier.sh"
    if [[ -f "$_ostler_tier_lib" ]]; then
        # shellcheck source=/dev/null
        . "$_ostler_tier_lib"
        if command -v ostler_resource_tier_detect >/dev/null 2>&1; then
            ostler_resource_tier_detect
            if [[ "${OSTLER_TIER:-}" == "floor" ]]; then
                OSTLER_NUM_PARALLEL=1
            fi
            info "$(printf '    resource tier: %s (RAM %sGB, %s cores) -- OLLAMA_NUM_PARALLEL=%s' "${OSTLER_TIER:-?}" "${OSTLER_RAM_GB:-?}" "${OSTLER_CPU_CORES:-?}" "$OSTLER_NUM_PARALLEL")"
        fi
    fi

    cat > "$OLLAMA_PLIST" <<OLLAMAPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OLLAMA_APP_BIN}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <!--
        The Hub runs ONE shared local model slot. Live chat and the
        background conversation feeds (iMessage / email / WhatsApp /
        spoken) all summarise through it. Two settings keep chat snappy
        on a fresh install while the historic backlog is still draining:

          OLLAMA_NUM_PARALLEL (2 on LOW/HIGH, 1 on the FLOOR tier) --
            serve two requests against the one loaded model concurrently.
            Combined with the single-flight lock the conversation feeds
            take (they never run more than one summary at a time), this
            reserves a slot so a chat turn never queues behind a
            minute-long backfill summary. It is
            RAM-cheap: the model weights are shared across slots; only a
            second (small, 4K-context) KV cache is added -- safe even on
            a 16GB Mac.

          OLLAMA_KEEP_ALIVE=-1 -- keep the model resident instead of
            unloading it after each idle gap. Stops the cold-reload
            thrash that made the first chat after a quiet spell take
            tens of seconds.
    -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_NUM_PARALLEL</key>
        <string>${OSTLER_NUM_PARALLEL}</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>-1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${OLLAMA_LOG_DIR}/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>${OLLAMA_LOG_DIR}/ollama.err</string>
</dict>
</plist>
OLLAMAPLIST
    launchctl bootstrap "gui/$(id -u)" "$OLLAMA_PLIST" 2>/dev/null || \
        launchctl load "$OLLAMA_PLIST" 2>/dev/null || true
    # Wait up to 90 seconds for Ollama to be ready
    OLLAMA_WAIT=0
    while ! curl -s http://localhost:11434/api/tags &>/dev/null; do
        if [[ $OLLAMA_WAIT -ge 90 ]]; then
            warn "$MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY"
            info "$(printf "$MSG_INFO_OLLAMA_MANUAL_START_HINT" "$OLLAMA_PLIST")"
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
    fail_with_code "ERR-08-PYTHON-BIN-UNSET" "PYTHON3_BIN is unset at Phase 3.4; the Phase 2.99 Python check should have set it. This is a script bug."
fi

# ── 3.5 Write config ──────────────────────────────────────────────

progress "Saving your configuration" "config_save"

cat > "${CONFIG_DIR}/.env" <<ENVEOF
# Ostler configuration – generated by installer
USER_ID="${USER_ID}"
USER_NAME="${USER_NAME}"
# CX-81 B6: derived from USER_NAME (or DETECTED_FIRST when the me-card
# resolved it). Read by CM044's wiki compiler at compile time to
# template the site_name + nav label ({first_name}pedia). Empty values
# fall back to "Personal wiki" per BRAND_SPEC_V1.1 §8.
USER_FIRST_NAME="${USER_FIRST_NAME}"
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

# Wiki title propagation (#5). docker compose interpolates the literal
# ${USER_FIRST_NAME:-} in docker-compose.yml (a quoted heredoc) at `up` time,
# reading the compose-dir .env (THIS file) -- NOT config/.env, and not an
# unexported shell var. USER_FIRST_NAME is captured to config/.env for the
# host tools, but unless it also lands here the wiki-site title falls back to
# "Personal wiki" instead of "{first_name}pedia". Write it to the compose .env
# so every compose invocation (install-time up + the recompile LaunchAgent)
# resolves it. Idempotent: replace any prior line, preserve the rest.
umask_ufn_orig=$(umask)
umask 0077
touch "$OSTLER_ENV_FILE"
chmod 600 "$OSTLER_ENV_FILE"
if grep -q '^USER_FIRST_NAME=' "$OSTLER_ENV_FILE" 2>/dev/null; then
    sed -i.bak '/^USER_FIRST_NAME=/d' "$OSTLER_ENV_FILE"
    rm -f "${OSTLER_ENV_FILE}.bak"
fi
printf 'USER_FIRST_NAME=%s\n' "${USER_FIRST_NAME:-}" >> "$OSTLER_ENV_FILE"

# Operator self-identity for the wiki self/me-card exclusion (CM044 PR #92).
# The wiki compiler drops the operator's OWN person node from Featured
# Contact / top Frequent Collaborator / Upcoming Birthdays by matching:
#   - WIKI_OPERATOR_EMAILS: comma-separated operator email addresses (exact
#     match against the person node's emails). Primary signal.
#   - WIKI_OPERATOR_NAME:   the operator's full display name. Fallback match.
# Both are interpolated into the wiki-compiler env block (docker-compose.yml)
# from THIS compose .env at `compose run` time, exactly like USER_FIRST_NAME.
# Source values are the me-card identity captured at Q3: USER_EMAIL (me-card
# email) + USER_NAME (me-card full name). Empty values are safe -- the
# compiler treats "" as "no self-exclusion" and renders normally.
#
# WIKI_OPERATOR_EMAILS = me-card email plus any email-shaped self-handles,
# de-duplicated, no leading/trailing commas. ASSISTANT_SELF_HANDLES is built
# later (iMessage self-echo guard), so we assemble the email list inline here
# from the values already in scope.
_wiki_operator_emails=""
for _wiki_op_email in "${USER_EMAIL:-}"; do
    _wiki_op_email="${_wiki_op_email# }"; _wiki_op_email="${_wiki_op_email% }"
    [[ -n "$_wiki_op_email" ]] || continue
    # email-shaped only (must contain an @); skip anything phone-like.
    [[ "$_wiki_op_email" == *"@"* ]] || continue
    case ",${_wiki_operator_emails}," in
        *",${_wiki_op_email},"*) continue ;;  # already present (de-dup)
    esac
    if [[ -z "$_wiki_operator_emails" ]]; then
        _wiki_operator_emails="$_wiki_op_email"
    else
        _wiki_operator_emails="${_wiki_operator_emails},${_wiki_op_email}"
    fi
done
unset _wiki_op_email
if grep -q '^WIKI_OPERATOR_NAME=' "$OSTLER_ENV_FILE" 2>/dev/null; then
    sed -i.bak '/^WIKI_OPERATOR_NAME=/d' "$OSTLER_ENV_FILE"
    rm -f "${OSTLER_ENV_FILE}.bak"
fi
printf 'WIKI_OPERATOR_NAME=%s\n' "${USER_NAME:-}" >> "$OSTLER_ENV_FILE"
if grep -q '^WIKI_OPERATOR_EMAILS=' "$OSTLER_ENV_FILE" 2>/dev/null; then
    sed -i.bak '/^WIKI_OPERATOR_EMAILS=/d' "$OSTLER_ENV_FILE"
    rm -f "${OSTLER_ENV_FILE}.bak"
fi
printf 'WIKI_OPERATOR_EMAILS=%s\n' "${_wiki_operator_emails}" >> "$OSTLER_ENV_FILE"
unset _wiki_operator_emails

chmod 600 "$OSTLER_ENV_FILE"
umask "$umask_ufn_orig"
unset umask_ufn_orig

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

    # ── Customer identity (CX-81 B6) ────────────────────────────
    #
    # Two display names the customer chose during the setup wizard.
    # Both fields are Option<String> on the daemon side
    # (crates/zeroclaw-config/src/schema.rs::Config); the daemon
    # injects them into the system prompt + exposes them via
    # GET /api/identity. The Tauri Hub + iOS Companion read the
    # endpoint to populate the chat header + the
    # {first_name}pedia wiki nav label.
    #
    # The two fields do NOT fall back to each other -- see
    # BRAND_SPEC_V1.1 §8 #2 for the asymmetric fallback rule.
    # user_first_name controls the wiki-side surfaces; null →
    # "Personal wiki". user_assistant_name controls the chat side;
    # null → "Your assistant". Setting one does not synthesise the
    # other.
    #
    # Both fields are written as TOML strings. Empty strings are
    # treated as "not set" by the daemon (serde defaults to None
    # on missing keys; we emit empty strings for visibility).
    _user_first_name_esc="${USER_FIRST_NAME//\"/\\\"}"
    _assistant_name_esc="${ASSISTANT_NAME//\"/\\\"}"
    echo
    echo "# Customer identity (BRAND_SPEC_V1.1 §8 -- non-symmetric fallback)."
    echo "user_first_name = \"${_user_first_name_esc}\""
    echo "user_assistant_name = \"${_assistant_name_esc}\""

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
    # the Ollama server URL the installer wired up in Phase 3.3
    # (brew install --cask ollama-app, served headless via the
    # com.ostler.ollama LaunchAgent). The model is the
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
    # NO /v1 suffix. The "ollama" provider key resolves to the daemon's
    # NATIVE Ollama provider (create_provider_with_url_and_options ->
    # "ollama" arm in zeroclaw-providers/src/lib.rs), which POSTs to
    # `{base_url}/api/chat` and carries the API-level `think` field. With a
    # `/v1` suffix the native provider POSTs to the malformed
    # `.../v1/api/chat` (its normalize_base_url strips `/api`+`/api/chat`
    # but NOT `/v1`), so the qwen3.x think:false switch never lands and
    # interactive chat returns empty/1-token replies. The `/v1`-stripping
    # fix (commit 286ede80) only covers the `custom:` provider arm, not
    # this `ollama` arm, so the base MUST be the bare host here. The `/v1`
    # OpenAI-compatible surface is only for non-native custom: providers.
    # Box-proven dead chat on the v1.0.0 .144 walk; see
    # launch/BRIEF_chat_thinking_mode_v1.0.0.md.
    echo "base_url = \"http://localhost:11434\""
    echo "model = \"${_ai_model_esc}\""
    echo "timeout_secs = 300"

    # ── Runtime: disable hidden chain-of-thought (#600) ─────────
    #
    # The daemon's Ollama provider only force-disables thinking for
    # the gemma4:* family (effective_think() in
    # crates/zeroclaw-providers/src/ollama.rs hardcodes Some(false)
    # for "gemma4:" tags). Every other model -- the qwen3.5:9b mid
    # tier and the qwen3.6:35b-a3b high tier the installer selects
    # for 24GB+ and 48GB+ machines -- falls through to the operator
    # config, which defaults to None == provider default == thinking
    # ON. That makes the assistant emit and stream a long hidden
    # reasoning pass before every interactive reply: on the 9B at
    # the ~13 tok/s the Mac Mini benchmarks (HR015
    # BENCHMARKS_2026-04-21.md), that is tens of seconds of dead air
    # before the customer sees a single word.
    #
    # Setting runtime.reasoning_enabled = false makes
    # effective_think() return Some(false) for ALL models (it passes
    # the operator value straight through for non-gemma4 tags), so
    # the daemon sends `think: false` on every Ollama request and
    # replies start streaming immediately. Schema field:
    # RuntimeConfig.reasoning_enabled: Option<bool> in
    # crates/zeroclaw-config/src/schema.rs. The customer can flip it
    # back on by editing this section post-install.
    echo
    echo "[runtime]"
    echo "reasoning_enabled = false"

    # ── HTTP request tool: reach the local personal-graph API ───
    #
    # The assistant answers "who is X / when did I last see X" from a
    # baseline CONTEXT.md digest injected into every prompt, and for
    # specifics not in the digest it fetches live from the local
    # ical-server with the http_request tool
    # (GET 127.0.0.1:8090/api/v1/people/search, /people/context).
    #
    # `enabled` already defaults true on the daemon side, but
    # `allow_private_hosts` defaults FALSE for SSRF protection -- and
    # 127.0.0.1 is a private host, so without this the tool refuses
    # the loopback call and the assistant says "I have no access to
    # your data" (the #608 launch blocker). The schema gates RFC1918 +
    # loopback + link-local behind this single flag; there is no
    # loopback-only knob. Acceptable here: the Hub is a single-machine
    # product and the only private host the assistant is guided to
    # call is the read-only loopback ical-server.
    echo
    echo "[http_request]"
    echo "enabled = true"
    echo "allow_private_hosts = true"

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

    # CX-61 (DMG #36, 2026-05-24): only write the assistant daemon's
    # [channels.email] section when CUSTOM IMAP is the chosen source.
    # Apple Mail FDA path is drained independently by the
    # email-ingest LaunchAgent (HR015 mbox reader); the daemon's
    # channel adds nothing in Apple-Mail-only mode, and its health
    # endpoint mis-reports "not-ready" against an empty IMAP config
    # (Studio retest #28 cosmetic). Skipping the section entirely
    # makes the daemon's channel state honest. Customer can still
    # opt into custom IMAP later by re-running the installer and
    # answering yes to the Custom IMAP prompt.
    _email_section_active=false
    if [[ "$CHANNEL_EMAIL_ENABLED" == true \
          && "$CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED" == true ]]; then
        _email_section_active=true
    fi

    if [[ "$_email_section_active" == true ]]; then
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
    unset _email_section_active

    # #134 (v1.0.1): the Apple Mail COMMS channel -- email the assistant from
    # your OWN address (the email analogue of the iMessage Note-to-Self) and
    # get a reply. Distinct from the [channels.email] INGEST flags above, which
    # only drain mail INTO the graph. The daemon activates this channel from
    # [channels.apple_mail] (AppleMailConfig: default enabled=false, deny-all
    # allowed_senders), so WITHOUT this block the channel ships inert. Enable
    # it out-of-the-box only when the customer opted into Apple Mail AND we know
    # their own address: owner-only allowed_senders means the assistant replies
    # solely to mail FROM the operator (no third-party auto-reply). Local Full
    # Disk Access read of Apple Mail's Envelope Index; no IMAP/SMTP creds.
    # When USER_EMAIL is unknown we omit the block entirely (absent = inert),
    # never enabling a deny-all reply loop with an unknown owner.
    #
    # v0.4.17 GATE (2026-06-18, Andy decision): the Apple Mail COMMS *reply*
    # channel is held OFF for this cut. The live .157 walk exposed three
    # defects in the daemon channel (ostler-assistant), all of which must be
    # fixed + verified before re-enable:
    #   (A) a NoReply outcome still emitted an outbound email whose body was
    #       the internal "[No reply sent: ...]" history marker;
    #   (B) no self-echo / owner-loop guard, so an auto-reply landing back in
    #       the watched local mailbox can re-trigger -> a reply loop into the
    #       operator's own inbox;
    #   (C) on connect the channel processed the existing mail backlog
    #       (~3 min/email, pegging Ollama) instead of only mail arriving after
    #       start; needs a high-water-mark.
    # We omit the [channels.apple_mail] block so the daemon ships it inert
    # (AppleMailConfig default enabled=false). Email INGEST ([channels.email]
    # apple_mail = true, above) is UNAFFECTED and still drains mail into the
    # graph. Flip OSTLER_APPLE_MAIL_COMMS_GATE back to "on" (or remove this
    # guard) once A+B+C are fixed. Tracked in ARCHIE_TNM_CHANNEL.
    OSTLER_APPLE_MAIL_COMMS_GATE="${OSTLER_APPLE_MAIL_COMMS_GATE:-off}"
    if [[ "$OSTLER_APPLE_MAIL_COMMS_GATE" == on \
       && "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true && -n "${USER_EMAIL:-}" ]]; then
        _apple_mail_owner_esc=$(printf '%s' "$USER_EMAIL" | sed 's/"/\\"/g')
        echo
        echo "[channels.apple_mail]"
        echo "enabled = true"
        echo "allowed_senders = [\"${_apple_mail_owner_esc}\"]"
        unset _apple_mail_owner_esc
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
    # CX-59 (DMG #34, 2026-05-24): pin the gateway port to 8000.
    # Without an explicit `port =` here, zeroclaw's binary default
    # of 42617 wins, and Ostler.app's polling, the installer's
    # success-screen pairing QR fetch (CX-56), and CM031's iOS
    # pairing flow ALL hit localhost:8000 and get "connection
    # refused" forever. Caught in Studio retest #29 2026-05-24
    # after the CX-58 assistant-agent bundling fix surfaced the
    # daemon successfully but on the wrong port.
    echo "port = 8000"
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
    # CX-68 (DMG #39, 2026-05-25): deliver briefs via iMessage,
    # not WhatsApp.
    #
    # The customer install path writes a [channels.whatsapp] block
    # with `enabled = true` but no backend selector (no
    # session_path / pair_phone / phone_number_id). The daemon's
    # WhatsAppConfig::backend_type() defaults to "cloud" in that
    # case, then is_cloud_config() returns false because the Cloud
    # API creds are missing, and the channel never registers in
    # the cron-delivery registry. The startup readiness sweep
    # marks the cron-delivery health component as error after 60s
    # ("channels not ready after 60s grace: 'whatsapp'"). Even if
    # the customer pairs WhatsApp Web later, getting that off the
    # ground requires UX surface we do not have for v1.0
    # (pair_code display, session_path bootstrap, keepalive cron).
    #
    # iMessage already works end-to-end on a fresh install once
    # the user grants Full Disk Access to the assistant daemon
    # (CX-60 + CX-66). It is the cleanest default-on delivery
    # channel for v1.0 briefs.
    #
    # Customers who prefer WhatsApp can edit
    # ${OSTLER_DIR}/assistant-config/config.toml after install:
    # change channel to "whatsapp" + add session_path / pair_phone
    # and pair via the Hub UI. A Doctor surface for this is
    # queued for v1.0.1.
    #
    # The brief recipient is the first entry of the user's
    # allowed_contacts list (their own iMessage address or phone),
    # which install.sh seeds from the imessage_allowed prompt.
    #
    # tz is set from the wizard-captured USER_TZ so the brief
    # lands at 09:00 customer-local rather than UTC. The schema's
    # default scheduler is UTC if tz is absent.
    #
    # best_effort = false (NOT true): a delivery failure surfaces
    # as a hard error in cron history rather than getting swallowed
    # as a WARN. Per memory/feedback_no_silent_security_fallback.md
    # new customers default-fail-loud so any regression surfaces
    # in Doctor immediately.
    #
    # Prompt copy is plain prose, British English, deliberately
    # short. The agent runtime prepends a memory-recall context
    # block (zeroclaw-runtime/src/cron/scheduler.rs::run_agent_job),
    # so we do not have to spell out "look at yesterday's data"
    # twice. Customers can edit the prompt after install by hand
    # in ${OSTLER_DIR}/assistant-config/config.toml.
    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true && -n "$CHANNEL_IMESSAGE_ALLOWED" ]]; then
        # Pick the first allowed contact as the brief recipient.
        # The allowed_contacts list is comma-separated; trim
        # whitespace around the first entry.
        _imsg_brief_recipient="${CHANNEL_IMESSAGE_ALLOWED%%,*}"
        _imsg_brief_recipient="${_imsg_brief_recipient# }"
        _imsg_brief_recipient="${_imsg_brief_recipient% }"
        _imsg_brief_recipient_esc="${_imsg_brief_recipient//\"/\\\"}"
        _user_tz_esc="${USER_TZ//\"/\\\"}"
        _morning_prompt="You are the user's personal assistant. Write a concise morning brief in plain prose for delivery as a short message. Summarise the most relevant items from yesterday's conversations, meetings and emails. Aim for three or four short sentences. If yesterday was quiet, say so warmly without padding. British English. No headings, no lists, no markdown. Output only the brief itself."
        _evening_prompt="You are the user's personal assistant. Write a concise evening wrap in plain prose for delivery as a short message. Reflect on the most notable items from today's conversations, meetings and emails. Aim for three or four short sentences. If today was quiet, say so warmly without padding. British English. No headings, no lists, no markdown. Output only the wrap itself."
        _morning_prompt_esc="${_morning_prompt//\"/\\\"}"
        _evening_prompt_esc="${_evening_prompt//\"/\\\"}"
        echo
        echo "[[cron.jobs]]"
        echo "id = \"morning-brief\""
        echo "name = \"Morning brief\""
        echo "job_type = \"agent\""
        echo "schedule = { kind = \"cron\", expr = \"0 9 * * *\", tz = \"${_user_tz_esc}\" }"
        echo "prompt = \"${_morning_prompt_esc}\""
        echo "delivery = { mode = \"announce\", channel = \"imessage\", to = \"${_imsg_brief_recipient_esc}\", best_effort = false }"
        echo
        echo "[[cron.jobs]]"
        echo "id = \"evening-wrap\""
        echo "name = \"Evening wrap\""
        echo "job_type = \"agent\""
        echo "schedule = { kind = \"cron\", expr = \"0 18 * * *\", tz = \"${_user_tz_esc}\" }"
        echo "prompt = \"${_evening_prompt_esc}\""
        echo "delivery = { mode = \"announce\", channel = \"imessage\", to = \"${_imsg_brief_recipient_esc}\", best_effort = false }"
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

# ── 3.5b Assistant identity belt-and-braces (B1, v1.0.0 LAST-CUT) ──
#
# The daemon seeds workspace/IDENTITY.md and workspace/SOUL.md on its
# first run, templated from user_assistant_name. But its seeder only
# writes when the file is absent (Rust: if !path.exists()), so a stale
# workspace that pre-dates the customer rename keeps the old engine
# codename and the assistant introduces itself by it. The installer
# guarantees a fresh, codename-free identity here: write both files
# from ${ASSISTANT_NAME} when they are absent OR still carry the old
# codename. Never emit an engine or product word as the assistant's
# identity; fall back to a neutral phrase when no name was chosen.
ASSISTANT_WORKSPACE_DIR="${ASSISTANT_CONFIG_DIR}/workspace"
_identity_name="${ASSISTANT_NAME:-your assistant}"
mkdir -p "$ASSISTANT_WORKSPACE_DIR"
for _idf in IDENTITY.md SOUL.md; do
    _idf_path="${ASSISTANT_WORKSPACE_DIR}/${_idf}"
    if [[ -f "$_idf_path" ]] && ! grep -qi 'zeroclaw' "$_idf_path" 2>/dev/null; then
        continue
    fi
    if [[ "$_idf" == "IDENTITY.md" ]]; then
        cat > "$_idf_path" <<IDENTITYEOF
# IDENTITY.md -- Who Am I?

I am ${_identity_name}, your personal assistant.

## Traits
- Helpful, precise, and safety-conscious
- I prioritise clarity and correctness
IDENTITYEOF
    else
        cat > "$_idf_path" <<SOULEOF
# SOUL.md -- Who You Are

You are ${_identity_name}, the user's personal assistant.

## Core Principles
- Be helpful and accurate
- Respect user intent and boundaries
- Ask before taking destructive actions
- Prefer safe, reversible operations
SOULEOF
    fi
done
unset _idf _idf_path _identity_name
ok "$(printf "%s" "Assistant identity seeded for ${ASSISTANT_NAME:-your assistant}")"

# ── 3.6 Security setup ────────────────────────────────────────────

progress "Encrypting your databases" "encrypt_db"

# Install SQLCipher
if ! brew list sqlcipher &>/dev/null 2>&1; then
    info "$MSG_INFO_INSTALLING_SQLCIPHER"
    brew install sqlcipher
    # DMG #48 silent-bail hardening: verify sqlcipher binary is on
    # PATH before continuing. ostler_security pysqlcipher3 build
    # later in the install depends on it; a silent miss here turns
    # into a confusing pip-install error 200 lines downstream.
    if ! command -v sqlcipher &>/dev/null; then
        fail_with_code "ERR-08-DMG48-SQLCIPHER-MISSING-AFTER-BREW" \
            "$(printf "$MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW" "$INSTALL_LOG")"
    fi
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
        fail_with_code "ERR-09-SQLCIPHER-MISSING" "$MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN"
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
            fail_with_code "ERR-09-PASSKEY-SETUP" "$MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH"
        fi
    else
        # Inner `|| true`: a grep no-match (marker absent) returns non-zero
        # and, under set -E, would fire the ERR trap INSIDE this $(...)
        # subshell and abort a successful encryption (same class as
        # CX-122 / #640). An empty RECOVERY_KEY is handled downstream by
        # the `[[ -n "$RECOVERY_KEY" ]]` guard before the show-once render.
        RECOVERY_KEY=$(echo "$SETUP_OUTPUT" | grep "^RECOVERY_PHRASE=" | cut -d= -f2- || true)
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
        fail_with_code "ERR-09-NO-PASSKEY" "$MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY"
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
#
# FDA_ASSIST_TRIGGER (DMG #48d, 2026-05-28): the assist block at lines
# ~4915-4988 below MUST fire BEFORE the Python run_all() invocation at
# the bottom of this step opens any FDA-gated SQLite DB. Ordering
# invariant: FDA_ASSIST_TRIGGER marker appears in install.sh BEFORE the
# `progress "Extracting data from your Mac"` line and BEFORE the
# `from ostler_fda.extract_all import run_all` heredoc. The regression
# test at tests/test_fda_assist_ordering.sh locks this at CI level
# (DMG #48c's broken probe at lines ~4892-4897 returned false-positive
# FDA_GRANTED=true on every fresh Mac, silently skipping the assist;
# the read-probe at lines ~4901-4937 below replaces that with an honest
# first-byte read of Safari/Messages/Mail DBs that genuinely need FDA).

progress "Extracting data from your Mac (the instant bit)" "fda_extract"

if [[ "$HAS_FDA_MODULE" == true ]]; then
    # CX-101 (DMG #48j, 2026-05-29): pre-launch gate now checks
    # POPULATION not EXISTENCE. The pre-CX-101 gate checked whether the
    # directory existed, but `~/Library/Calendars/` and `~/Library/Mail/V*/`
    # can exist as EMPTY scaffolding from a prior install / first-launch-
    # then-quit event without the local store containing any actual
    # data. On Andy's Studio the directories existed (Mail.app had been
    # briefly opened then closed, never adding accounts), so the gate
    # skipped pre-launch -- which meant the rest of the install
    # proceeded against EMPTY iCloud-not-yet-synced stores. New rule:
    # if the source-of-truth Accounts4.sqlite shows accounts configured
    # but the local derived store is empty, force a pre-launch so the
    # app starts syncing. If accounts are 0, no benefit to opening the
    # app -- the customer has nothing to sync yet.
    APPS_TO_OPEN=()
    # Calendar: open if CalDAV / iCloud calendar account exists AND
    # local Calendar Cache / Calendar.sqlitedb is empty.
    if ! _store_populated_calendar && [[ "$(_accountsdb_count_calendar)" -gt 0 ]]; then
        APPS_TO_OPEN+=("Calendar")
    fi
    # Mail: open if mail account exists AND no .emlx / Envelope Index
    # rows yet. The _store_populated_mail helper covers both.
    if ! _store_populated_mail && [[ "$(_accountsdb_count_mail)" -gt 0 ]]; then
        APPS_TO_OPEN+=("Mail")
    fi
    # Contacts: open if CardDAV / iCloud contacts exist AND no
    # populated .abcddb yet.
    if ! _store_populated_contacts && [[ "$(_accountsdb_count_contacts)" -gt 0 ]]; then
        APPS_TO_OPEN+=("Contacts")
    fi
    # Reminders + Notes still use existence checks; they're system
    # apps (no Accounts4.sqlite source row) and their stores create
    # on first launch from iCloud. CX-101 leaves these as-is for v1.0.
    [[ ! -d "$HOME/Library/Group Containers/group.com.apple.reminders" ]] && APPS_TO_OPEN+=("Reminders")
    [[ ! -f "$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite" ]] && APPS_TO_OPEN+=("Notes")

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
    # FDA_ASSIST_TRIGGER (DMG #48d, 2026-05-28): the FDA assist below
    # MUST fire BEFORE the Python extractor at run_all() reads any
    # FDA-gated SQLite DB. DMG #48c's heuristic ([[ -r ~/Library/Mail ]]
    # || ls ~/Library/Application Support/com.apple.TCC/TCC.db) was a
    # false-positive trap: ~/Library/Mail is a user-owned directory that
    # passes -r even without FDA, and `ls` on a file only needs read on
    # the parent dir (not the file itself). The previous heuristic
    # therefore returned FDA_GRANTED=true on every fresh customer Mac,
    # the assist block at lines ~4915-4974 was skipped, and the
    # extractor ran without FDA -- producing "unable to open database
    # file" for safari_history, imessage, apple_notes and apple_mail
    # and an empty wiki post-install. Studio install log 2026-05-28
    # showed exactly this shape: "Full Disk Access detected" at log
    # line 606 followed by FDA grant 463 lines later at line 1083,
    # after extraction had already completed with zero data.
    #
    # Real probe: attempt to actually read the FIRST BYTE of an
    # FDA-gated SQLite DB. macOS TCC denies open() on these paths
    # without FDA, so `head -c 1` returns non-zero and the probe is
    # honest about the posture. Safari + Messages are the canonical
    # FDA-gated user files; both must succeed for FDA_GRANTED=true.
    # If either DB is missing on this Mac (user has never opened
    # Safari / Messages), we fall back to a Mail-history probe which
    # is also FDA-gated, and finally to the assist if no probe
    # succeeded -- prompting the user once is the safe default.
    _fda_read_probe() {
        # Returns 0 if the first byte of $1 can be read, 1 otherwise.
        # Uses `head -c 1` because it returns EPERM-equivalent
        # non-zero exit on TCC denial, unlike `[[ -r ]]` and `ls`
        # which only check directory-entry permissions.
        [[ -e "$1" ]] && head -c 1 "$1" >/dev/null 2>&1
    }
    FDA_PROBE_PATHS=(
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Messages/chat.db"
        "$HOME/Library/Mail/V10/MailData/Envelope Index"
    )
    FDA_PROBE_TRIED=0
    FDA_PROBE_SUCCEEDED=0
    for probe in "${FDA_PROBE_PATHS[@]}"; do
        [[ -e "$probe" ]] || continue
        FDA_PROBE_TRIED=$((FDA_PROBE_TRIED + 1))
        if _fda_read_probe "$probe"; then
            FDA_PROBE_SUCCEEDED=$((FDA_PROBE_SUCCEEDED + 1))
        fi
    done
    # Conservative posture: only believe FDA is granted when at least
    # one probe attempt was made AND every attempted probe succeeded.
    # If no probe path exists (clean Mac, no Safari / Messages / Mail
    # ever opened), default to false so the assist fires once -- a
    # spurious prompt is recoverable; missing extraction is not.
    if [[ $FDA_PROBE_TRIED -gt 0 && $FDA_PROBE_SUCCEEDED -eq $FDA_PROBE_TRIED ]]; then
        FDA_GRANTED=true
        # CX-87 (DMG #48g): FDA was already granted (customer is
        # re-running on a Mac where they granted it previously, or
        # has just relaunched after a Quit & Reopen). Promote the
        # pre-FDA staging tree onto ~/.ostler/ so the rest of the
        # install writes to the canonical location.
        _ostler_promote_prelaunch_tree
    else
        FDA_GRANTED=false
    fi
    if [[ "$FDA_GRANTED" == false ]]; then
        warn "$MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL"
        warn "$MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM"

        # DMG #48c launch-blocker fix (2026-05-27): fire the FDA grant
        # dialog HERE, before run_all() runs the extractor below.
        # Pre-fix, the installer's FDA dialog only fired via the
        # iMessage assist path much later (~Phase 4 health_check), so
        # this extraction step ran without FDA and every macOS-DB
        # source (safari_history, imessage, apple_notes,
        # safari_bookmarks) failed with "unable to open database
        # file". Mirroring the CX-66 iMessage assist shape: open
        # System Settings to the FDA pane, present a blocking
        # osascript modal that returns when the customer clicks Done,
        # then re-probe. If granted, the extractor downstream runs
        # with full FDA. Gated on OSTLER_GUI=1; TTY-only installs
        # fall through to the previous text-only message.
        #
        # WALK-1 (Wave 2.1): the FULL grant assist (pre-warn + pane
        # refresh + blocking modal) now also requires INSTALLER_FDA_SHOWN_EARLY
        # to be UNSET. The grant is hoisted into the Phase-2 questions
        # block (search "9-fda. Full Disk Access (installer)"), so on the
        # normal walk-away path this late assist is suppressed -- it only
        # fires for a reuse install / GUI-toggled-late edge where the
        # upfront block did not run. Either way, an UNCONDITIONAL re-probe
        # plus a short recovery modal run BELOW (outside this guard) so a
        # deferred / declined / relaunch-settled grant is always recovered.
        if [[ "${OSTLER_GUI:-0}" == "1" && -z "${INSTALLER_FDA_SHOWN_EARLY:-}" ]]; then
            # CX-87 (DMG #48g, 2026-05-29): pre-warn modal before the
            # FDA grant flow. Same shape as the CX-47
            # (Downloads/Desktop/Documents) and CX-55 (iMessage
            # Automation) pre-warns. The crucial guidance is the
            # "Quit & Reopen" hint -- macOS will fire that dialog
            # straight after the customer toggles FDA on for
            # OstlerInstaller.app, and a click on Later silently
            # breaks the grant for the current process.
            info "$MSG_INFO_INSTALLER_FDA_PREWARN"
            _prewarn_msg="$(printf '%s\n\n%s\n\n%s' \
                "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1" \
                "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2" \
                "$MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3")"
            _prewarn_msg_esc="${_prewarn_msg//\"/\\\"}"
            _prewarn_title_esc="${MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE//\"/\\\"}"
            _prewarn_button_esc="${MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON//\"/\\\"}"
            _prewarn_icon_path=""
            if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
                _prewarn_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
                _prewarn_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
            elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
                _prewarn_icon_path="${SCRIPT_DIR}/AppIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
                _prewarn_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
            fi
            if [[ -n "$_prewarn_icon_path" ]]; then
                _prewarn_icon_path_esc="${_prewarn_icon_path//\"/\\\"}"
                _prewarn_icon_clause="with icon file POSIX file \"${_prewarn_icon_path_esc}\""
            else
                _prewarn_icon_clause="with icon note"
            fi
            osascript \
                -e 'tell application "System Events" to activate' \
                -e "tell application \"System Events\" to display dialog \"${_prewarn_msg_esc}\" with title \"${_prewarn_title_esc}\" buttons {\"${_prewarn_button_esc}\"} default button \"${_prewarn_button_esc}\" ${_prewarn_icon_clause}" \
                >/dev/null 2>&1 || true
            unset _prewarn_msg _prewarn_msg_esc _prewarn_title_esc \
                  _prewarn_button_esc _prewarn_icon_path \
                  _prewarn_icon_path_esc _prewarn_icon_clause

            info "$MSG_INFO_INSTALLER_FDA_ASSIST_OPENING"
            # FDA_PANE_REFRESH (#572, 2026-06-09): force a fresh System
            # Settings load before pointing the customer at the FDA pane.
            # A Settings window left open from an earlier prompt (e.g.
            # Internet Accounts) can show a STALE Full Disk Access list
            # that predates the OstlerInstaller entry primed at install
            # start -- so the entry looks "missing" until the pane
            # happens to refresh (the ~30-60s lag customers reported).
            # killall + reopen guarantees the list is current. Best-effort;
            # covers both the "System Settings" (macOS 13+) and legacy
            # "System Preferences" process names.
            killall "System Settings" >/dev/null 2>&1 || true
            killall "System Preferences" >/dev/null 2>&1 || true
            sleep 1
            open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

            _installer_fda_msg="$(printf '%s\n\n%s\n%s' \
                "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1" \
                "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2" \
                "$MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3")"
            _installer_fda_msg_esc="${_installer_fda_msg//\"/\\\"}"
            _installer_fda_title_esc="${MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE//\"/\\\"}"
            _installer_fda_button_esc="${MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON//\"/\\\"}"

            # Use the same DialogIcon resolution as CX-81 B8b.
            _installer_fda_icon_path=""
            if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
                _installer_fda_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
                _installer_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
            elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
                _installer_fda_icon_path="${SCRIPT_DIR}/AppIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
                _installer_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
            fi
            if [[ -n "$_installer_fda_icon_path" ]]; then
                _installer_fda_icon_path_esc="${_installer_fda_icon_path//\"/\\\"}"
                _installer_fda_icon_clause="with icon file POSIX file \"${_installer_fda_icon_path_esc}\""
            else
                _installer_fda_icon_clause="with icon note"
            fi

            # Pause briefly to let System Settings finish its window
            # animation before raising the modal, then activate +
            # display so the dialog renders in front of Settings
            # (same z-order fix as CX-66).
            sleep 1
            osascript \
                -e 'tell application "System Events" to activate' \
                -e "tell application \"System Events\" to display dialog \"${_installer_fda_msg_esc}\" with title \"${_installer_fda_title_esc}\" buttons {\"${_installer_fda_button_esc}\"} default button \"${_installer_fda_button_esc}\" ${_installer_fda_icon_clause}" \
                >/dev/null 2>&1 || true
            unset _installer_fda_msg _installer_fda_msg_esc \
                  _installer_fda_title_esc _installer_fda_button_esc \
                  _installer_fda_icon_path _installer_fda_icon_path_esc \
                  _installer_fda_icon_clause

            # Re-probe. macOS refreshes the TCC posture for the
            # caller binary as soon as the user toggles it on, so a
            # direct probe of one of the FDA-gated paths returns
            # the live state without needing to re-exec. Use the
            # same honest read-probe as the initial check so a false
            # positive cannot creep back in.
            sleep 2
            FDA_REPROBE_TRIED=0
            FDA_REPROBE_SUCCEEDED=0
            for probe in "${FDA_PROBE_PATHS[@]}"; do
                [[ -e "$probe" ]] || continue
                FDA_REPROBE_TRIED=$((FDA_REPROBE_TRIED + 1))
                if _fda_read_probe "$probe"; then
                    FDA_REPROBE_SUCCEEDED=$((FDA_REPROBE_SUCCEEDED + 1))
                fi
            done
            if [[ $FDA_REPROBE_TRIED -gt 0 && $FDA_REPROBE_SUCCEEDED -eq $FDA_REPROBE_TRIED ]]; then
                FDA_GRANTED=true
            fi
            if [[ "$FDA_GRANTED" == true ]]; then
                info "$MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED"
            else
                info "$MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED"
            fi
            # CX-87 (DMG #48g): promote the staging tree onto
            # ~/.ostler/ now that the FDA grant flow is behind us
            # (grant accepted OR declined; both paths past the
            # Quit & Reopen risk window). The rest of the install
            # writes to the canonical location.
            _ostler_promote_prelaunch_tree
        else
            echo ""
            echo "  To grant Full Disk Access:"
            echo "    1. Open System Settings > Privacy & Security > Full Disk Access"
            echo "    2. Click + and add Terminal (or whichever terminal you ran this in)"
            echo "    3. Toggle it ON"
            echo "    4. Re-run the installer"
            echo ""
            echo "  Continuing without FDA - Ostler will work, just with less data"
            echo "  (no iMessage / Mail history; just contacts / calendars / GDPR exports)."
            echo ""
        fi
    fi

    # WALK-1 (Wave 2.1): UNCONDITIONAL re-probe before run_all(). The
    # upfront Phase-2 grant (9-fda) may have been DEFERRED by the
    # customer, or macOS may have needed the Quit & Reopen relaunch to
    # settle the toggle -- in both cases FDA can be live now even though
    # the early FDA_GRANTED came back false (and the guarded assist above
    # was suppressed). Re-read the live TCC posture here so the extractor
    # below sees the truth, never a stale "false". Same honest read-probe.
    if [[ "$HAS_FDA_MODULE" == true ]]; then
        FDA_FINAL_REPROBE_TRIED=0
        FDA_FINAL_REPROBE_SUCCEEDED=0
        for probe in "${FDA_PROBE_PATHS[@]}"; do
            [[ -e "$probe" ]] || continue
            FDA_FINAL_REPROBE_TRIED=$((FDA_FINAL_REPROBE_TRIED + 1))
            if _fda_read_probe "$probe"; then
                FDA_FINAL_REPROBE_SUCCEEDED=$((FDA_FINAL_REPROBE_SUCCEEDED + 1))
            fi
        done
        if [[ $FDA_FINAL_REPROBE_TRIED -gt 0 && $FDA_FINAL_REPROBE_SUCCEEDED -eq $FDA_FINAL_REPROBE_TRIED ]]; then
            FDA_GRANTED=true
        fi
        unset FDA_FINAL_REPROBE_TRIED FDA_FINAL_REPROBE_SUCCEEDED

        # WALK-1 (Wave 2.1, spec 3.5): one targeted late recovery modal,
        # and ONLY for the customer who saw the early ask but did not grant
        # (INSTALLER_FDA_SHOWN_EARLY set, still not granted). This is the
        # single honest late prompt we accept -- it never fires on the
        # normal walk-away path (where FDA was granted upfront) and never
        # fires for the reuse / GUI-late edge (which got the full assist
        # above instead). The customer can grant now or continue with less
        # data; deferring still completes the install (graceful degrade
        # below is unchanged).
        if [[ "$FDA_GRANTED" == false && -n "${INSTALLER_FDA_SHOWN_EARLY:-}" && "${OSTLER_GUI:-0}" == "1" ]]; then
            info "$MSG_INFO_INSTALLER_FDA_ASSIST_OPENING"
            killall "System Settings" >/dev/null 2>&1 || true
            killall "System Preferences" >/dev/null 2>&1 || true
            sleep 1
            open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

            _fda_recover_msg="$(printf '%s\n\n%s' \
                "$MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1" \
                "$MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2")"
            _fda_recover_msg_esc="${_fda_recover_msg//\"/\\\"}"
            _fda_recover_title_esc="${MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE//\"/\\\"}"
            _fda_recover_button_esc="${MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON//\"/\\\"}"
            _fda_recover_icon_path=""
            if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
                _fda_recover_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
                _fda_recover_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
            elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
                _fda_recover_icon_path="${SCRIPT_DIR}/AppIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
                _fda_recover_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
            fi
            if [[ -n "$_fda_recover_icon_path" ]]; then
                _fda_recover_icon_path_esc="${_fda_recover_icon_path//\"/\\\"}"
                _fda_recover_icon_clause="with icon file POSIX file \"${_fda_recover_icon_path_esc}\""
            else
                _fda_recover_icon_clause="with icon note"
            fi
            sleep 1
            osascript \
                -e 'tell application "System Events" to activate' \
                -e "tell application \"System Events\" to display dialog \"${_fda_recover_msg_esc}\" with title \"${_fda_recover_title_esc}\" buttons {\"${_fda_recover_button_esc}\"} default button \"${_fda_recover_button_esc}\" ${_fda_recover_icon_clause}" \
                >/dev/null 2>&1 || true
            unset _fda_recover_msg _fda_recover_msg_esc _fda_recover_title_esc \
                  _fda_recover_button_esc _fda_recover_icon_path \
                  _fda_recover_icon_path_esc _fda_recover_icon_clause

            # Final re-probe after the recovery grant.
            sleep 2
            FDA_RECOVER_TRIED=0
            FDA_RECOVER_SUCCEEDED=0
            for probe in "${FDA_PROBE_PATHS[@]}"; do
                [[ -e "$probe" ]] || continue
                FDA_RECOVER_TRIED=$((FDA_RECOVER_TRIED + 1))
                if _fda_read_probe "$probe"; then
                    FDA_RECOVER_SUCCEEDED=$((FDA_RECOVER_SUCCEEDED + 1))
                fi
            done
            if [[ $FDA_RECOVER_TRIED -gt 0 && $FDA_RECOVER_SUCCEEDED -eq $FDA_RECOVER_TRIED ]]; then
                FDA_GRANTED=true
                info "$MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED"
            else
                info "$MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED"
            fi
            unset FDA_RECOVER_TRIED FDA_RECOVER_SUCCEEDED
        fi
    fi

    # CX-87 (DMG #48g): catch-all promotion of the staging tree.
    # The branches above call _ostler_promote_prelaunch_tree from
    # within their happy paths; this idempotent re-call guarantees
    # we promote even on the TTY-no-GUI path and on any future
    # branch that skips the inner promote. The function returns
    # immediately if OSTLER_PRELAUNCH_PROMOTED is already true.
    _ostler_promote_prelaunch_tree
    if [[ "$FDA_GRANTED" == true ]]; then
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
    # #48g (2026-05-29): set 5-year backfill windows so the
    # install-time extract pulls a meaningful customer history, not
    # just 12 months. The 5-year cap is the explicit ceiling from the
    # spec: older data is rare on a primary Mac and inflates install
    # runtime. Customer can backfill further from Doctor later.
    #
    # OSTLER_IMESSAGE_BACKFILL_DAYS: read by extract_all.py
    # OSTLER_BROWSER_BACKFILL_DAYS:  read by extract_all.py (chrome arm)
    # OSTLER_SAFARI_BACKFILL_DAYS:   new env var, hard-coded extract
    #                                 (safari_history.py reads it now)
    # OSTLER_WHATSAPP_BACKFILL_DAYS: new env var, hard-coded extract
    #                                 (whatsapp_history extract_all
    #                                  branch reads it now)
    # OSTLER_MAIL_BACKFILL_DAYS:    #260 -- Apple Mail history window.
    #                                 Previously hard-coded at 365 days
    #                                 in extract_all.py, so a fresh
    #                                 customer only ever got the last 12
    #                                 months of mail in the graph. Now
    #                                 configurable + defaults to 5 years
    #                                 like the other sources. Customers
    #                                 can extend further post-install via
    #                                 `ostler-fda` with a larger value
    #                                 (the "extend now?" affordance).
    : "${OSTLER_IMESSAGE_BACKFILL_DAYS:=1825}"
    : "${OSTLER_BROWSER_BACKFILL_DAYS:=1825}"
    : "${OSTLER_SAFARI_BACKFILL_DAYS:=1825}"
    : "${OSTLER_WHATSAPP_BACKFILL_DAYS:=1825}"
    : "${OSTLER_MAIL_BACKFILL_DAYS:=1825}"

    set +e
    FDA_OUTPUT=$(OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES}" \
                 OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}" \
                 OSTLER_IMESSAGE_BACKFILL_DAYS="${OSTLER_IMESSAGE_BACKFILL_DAYS}" \
                 OSTLER_BROWSER_BACKFILL_DAYS="${OSTLER_BROWSER_BACKFILL_DAYS}" \
                 OSTLER_SAFARI_BACKFILL_DAYS="${OSTLER_SAFARI_BACKFILL_DAYS}" \
                 OSTLER_WHATSAPP_BACKFILL_DAYS="${OSTLER_WHATSAPP_BACKFILL_DAYS}" \
                 OSTLER_MAIL_BACKFILL_DAYS="${OSTLER_MAIL_BACKFILL_DAYS}" \
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

    # #259: Apple Mail no-content guidance. The apple_mail extractor
    # arm now reports status "empty_no_content" when Mail is in the
    # source set but the local store holds no messages in the window
    # (no accounts connected, or accounts configured but never synced).
    # Without this, the install records a silent zero and the customer
    # never learns why their email surfaces are blank. Surface a calm,
    # informational message pointing them at Apple Mail; this is not a
    # hard failure and the install continues. Bracket with set +e so a
    # grep miss under pipefail can never abort the install.
    set +e
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]] \
       && printf '%s' "$FDA_OUTPUT" | grep -q '"apple_mail"[^}]*"empty_no_content"'; then
        info "$MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT"
        info "$MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN"
    fi
    set -e

    # #260 / #639: the Mail history window was chosen UPFRONT in Phase 2
    # (OSTLER_MAIL_BACKFILL_DAYS) and already applied by the FDA extraction
    # above, so there is NO prompt here -- a walk-away install must never
    # block mid-run. Just confirm which window was applied, when Apple Mail
    # actually produced content (status "ok"). Bracket with set +e so a
    # grep miss under pipefail can never abort the install.
    set +e
    if [[ "$CHANNEL_EMAIL_APPLE_MAIL_ENABLED" == true ]] \
       && printf '%s' "$FDA_OUTPUT" | grep -q '"apple_mail"[^}]*"status": "ok"'; then
        if [[ "${OSTLER_MAIL_BACKFILL_DAYS:-1825}" -gt 1825 ]]; then
            ok "$MSG_OK_MAIL_EXTENDING_FULL_HISTORY"
        else
            ok "$MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY"
        fi
    fi
    set -e

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
    # CX-87 (DMG #48g): even though we skipped the FDA grant flow
    # entirely, the staging tree needs to be promoted to ~/.ostler/
    # for the rest of the install to write to the canonical
    # location. Idempotent.
    _ostler_promote_prelaunch_tree
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
    image: ghcr.io/ostler-ai/ostler-wiki-site@sha256:252cce952937adefc5bf72ecd07092281abec578d4839217b198e853b1fe328e
    container_name: ostler-wiki-site
    ports:
      - "127.0.0.1:8044:8000"
    # CX-81 B6: pass the customer's first name through so the wiki-site
    # entrypoint can render the site title to {{first_name}}pedia. Unset
    # / empty falls back to "Personal wiki" inside
    # compiler.identity_label.first_name_to_pedia_label.
    environment:
      USER_FIRST_NAME: "${USER_FIRST_NAME:-}"
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
    image: ghcr.io/ostler-ai/ostler-wiki-compiler@sha256:1b0b4bedb9011bbca05db5f820d4699d32df6f506188736714a1a8f398b20748
    container_name: ostler-wiki-compiler
    profiles: [compile]
    volumes:
      - wiki-docs:/wiki
      - ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}:/wiki/obsidian
      - ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}/_images:/wiki/obsidian/_images:ro
      - oxigraph_data:/app/oxigraph:ro
      - qdrant_data:/app/qdrant:ro
      # Hydration status hand-off (CM044 #624). The compiler writes a
      # small JSON progress file here; the host-side CM041 ical-server
      # hydration endpoint reads it cross-process to drive the live
      # dashboard panel. It must NOT live inside the wiki-docs named
      # volume (host-invisible), so it is bind-mounted from the host
      # state dir. The compiler writes to /state inside the container
      # (WIKI_HYDRATION_STATUS_FILE below); that lands at ~/.ostler/state
      # on the host where the endpoint reads it.
      - ${HOME}/.ostler/state:/state
    environment:
      # Inside-container path the compiler writes the MkDocs source
      # to. Pinned to /wiki to match the wiki-docs:/wiki mount above.
      - WIKI_OUTPUT_DIR=/wiki
      # Inside-container path the Obsidian post-processor writes to.
      # Pinned to /wiki/obsidian to match the bind-mount above.
      - WIKI_OBSIDIAN_DIR=/wiki/obsidian
      # Absolute path (inside the container) of the hydration status
      # file. Bind-mounted to ~/.ostler/state on the host above, so the
      # host-side CM041 ical-server hydration endpoint reads the same
      # file the compiler writes. See compiler/hydration.py::status_path.
      - WIKI_HYDRATION_STATUS_FILE=/state/wiki_hydration.json
      # CM044 productisation knobs (set by CM044 PR #22). Empty
      # defaults are intentional: the compiler treats "" as "no
      # operator-specific filter" and emits a generic wiki rather
      # than failing. Operators override per-machine via
      # ~/.ostler/.env or the env block at install time.
      - PWG_USER_ID=${PWG_USER_ID:-}
      - PWG_AI_CHAT_WINGS=${PWG_AI_CHAT_WINGS:-}
      # Operator self-identity for the wiki self/me-card exclusion (CM044
      # PR #92). Without these the operator's OWN person node surfaces as the
      # #1 Featured Contact / top Frequent Collaborator (meetings with self)
      # / in Upcoming Birthdays. Sourced from the me-card identity (USER_NAME
      # full name + USER_EMAIL) and written to the compose .env by the
      # installer alongside USER_FIRST_NAME. Empty = no self-exclusion (safe).
      - WIKI_OPERATOR_NAME=${WIKI_OPERATOR_NAME:-}
      - WIKI_OPERATOR_EMAILS=${WIKI_OPERATOR_EMAILS:-}
      - OSTLER_PII_OPERATOR_HK_PHONE_DIGITS=${OSTLER_PII_OPERATOR_HK_PHONE_DIGITS:-}
      - OSTLER_PII_OPERATOR_UK_PHONE_DIGITS=${OSTLER_PII_OPERATOR_UK_PHONE_DIGITS:-}
      - OSTLER_PII_SCAN_MODE=${OSTLER_PII_SCAN_MODE:-fail}
      # #606: the compiler runs as a one-shot container on this compose
      # network. Without these it defaults (compiler/config.py) to
      # localhost:7878 / localhost:6333, which inside the container is
      # its OWN loopback -> httpx.ConnectError in load_people() ->
      # People / Orgs / Topics / Places never build -> /people/ 404s.
      # Reach the data services by their compose service names, and
      # Ollama (a host process, not a compose service) via the host
      # gateway.
      - OXIGRAPH_URL=http://oxigraph:7878
      - QDRANT_URL=http://qdrant:6333
      - OLLAMA_URL=http://host.docker.internal:11434
    extra_hosts:
      # macOS / Colima-friendly way to surface the host gateway so the
      # OLLAMA_URL above resolves to the host's Ollama.
      - "host.docker.internal:host-gateway"

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
# ── Cold-VM hardening for the graph DB bring-up ───────────────────
# TNM 2026-06-15 (ERR-99-INSTALL-ABORT-L7105 on a fresh-wipe Studio
# install). On a genuinely FRESH install the Colima VM has only just
# cold-booted. The earlier "Docker running" gate proves the daemon
# socket answers, but NOT that the guest VM's network is routable yet
# -- and the FIRST docker operation at this phase is an image PULL of
# qdrant / oxigraph / redis over that not-yet-warm network (these are
# pulled from the registry, not bundled in the DMG). The bare
# `docker compose up -d` below coupled the flaky pull to the bring-up
# with NO retry, so a single cold-VM network blip failed under
# `set -e` -> ERR trap -> the whole install aborted ~90% in. The
# Qdrant readiness loop further down runs AFTER `up`, so it never
# protected the pull.
#
# Fix, three guarded steps (each `if cmd; then` form so a non-zero
# never trips errexit/the ERR trap until retries are exhausted):
#   (1) re-confirm the daemon is reachable HERE-and-NOW (it may have
#       been minutes since the install-docker phase),
#   (2) PULL the three images separately with retry/backoff so a
#       transient cold-VM network failure retries instead of aborting,
#   (3) `up -d` (images cached now, so effectively instant) also with
#       a short retry. Only a genuine, repeated failure is fatal, and
#       then via fail_with_code (curated code + actionable recovery),
#       never the synthetic ERR-99.
#
# Post-launch hardening (NOT done here, tracked v1.0.1): bundling the
# 3 images into the DMG (docker save -> docker load) would remove this
# net pull, but the install already pulls multi-GB from the net anyway
# (the Ollama conversation model + the ~3.6 GB Vane image), so it would
# not remove the network dependency. Making the pull resilient is the
# proportionate v1.0.0 fix.

# (1) Daemon reachable here-and-now (cold-VM socket forwarding can lag).
_gdb_docker_ready=false
for _ in $(seq 1 40); do
    if docker info &>/dev/null 2>&1; then _gdb_docker_ready=true; break; fi
    sleep 3
done
if [[ "$_gdb_docker_ready" != true ]]; then
    fail_with_code "ERR-06-GRAPH-DB-DOCKER" "$MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY"
fi
unset _gdb_docker_ready

# (2) Pull the data images with retry/backoff (the flaky cold-VM step).
info "$MSG_INFO_PULLING_GRAPH_DB_IMAGES"
_gdb_pulled=false
_gdb_backoff=10
for _gdb_attempt in 1 2 3 4 5; do
    if docker compose pull qdrant oxigraph redis; then
        _gdb_pulled=true; break
    fi
    if (( _gdb_attempt < 5 )); then
        warn "$(printf "$MSG_WARN_GRAPH_DB_PULL_RETRY" "$_gdb_attempt" "5" "$_gdb_backoff")"
        sleep "$_gdb_backoff"
        _gdb_backoff=$(( _gdb_backoff * 2 ))
    fi
done
if [[ "$_gdb_pulled" != true ]]; then
    fail_with_code "ERR-06-GRAPH-DB-PULL" "$MSG_FAIL_GRAPH_DB_PULL_FAILED"
fi
unset _gdb_pulled _gdb_backoff _gdb_attempt

# (3) Bring them up (images cached now -> fast) with a short retry.
_gdb_up=false
for _gdb_up_attempt in 1 2 3; do
    if docker compose up -d qdrant oxigraph redis; then
        _gdb_up=true; break
    fi
    if (( _gdb_up_attempt < 3 )); then
        warn "$(printf "$MSG_WARN_GRAPH_DB_UP_RETRY" "$_gdb_up_attempt" "3")"
        sleep 5
    fi
done
if [[ "$_gdb_up" != true ]]; then
    fail_with_code "ERR-06-GRAPH-DB-UP" "$MSG_FAIL_GRAPH_DB_UP_FAILED"
fi
unset _gdb_up _gdb_up_attempt
ok "$MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878"

# ── Pre-create optional Qdrant collections (#606) ────────────────
#
# The wiki compiler reads several Qdrant collections at compile time.
# On a fresh install `people` is written first by the contact hydrate
# (hydrate_graph, contact_syncer) and then topped up by the people
# ingest (hydrate_people), and `preferences` by the CM019 ingest, but
# conversations / evernote_knowledge (and preferences when no prefs
# data lands) are never created until their source data first arrives,
# which may be never on day one. A bare read of a missing collection
# 404s, and CM044's person_pages reader treats a conversations 404 as
# fatal, aborting the whole compile so /people/ 404s. Pre-creating the
# collections empty makes every read return an empty set instead.
#
# `people` is pre-created here as belt-and-braces (#638). The contact
# syncer now self-creates `people` before its first upsert (so the
# hydrate no longer 404s mid-run on a fresh box), but pre-creating it
# as well means an early reader never 404s in the window before the
# first contact write, and a Mac with no contacts at all still leaves
# an empty `people` for the wiki to read instead of a missing one.
#
# nomic-embed-text (the embedder used across the graph ingest paths) is
# 768-dim, Cosine, unnamed vectors -- matching the people collection
# the ingest builds, so a later real ingest into these collections is
# consistent. Idempotent: GET first, only PUT when absent, so an
# already-populated collection is never clobbered. Best-effort and
# non-fatal: a transient Qdrant hiccup must not fail the whole install
# (CM044's reader is being hardened to tolerate a 404 in parallel).
_qdrant_url="${QDRANT_URL:-http://localhost:6333}"
_qdrant_ready=false
for _ in $(seq 1 30); do
    if curl -sf -m 2 "${_qdrant_url}/readyz" &>/dev/null \
       || curl -sf -m 2 "${_qdrant_url}/collections" &>/dev/null; then
        _qdrant_ready=true
        break
    fi
    sleep 1
done

if [[ "$_qdrant_ready" == true ]]; then
    for _coll in people conversations preferences evernote_knowledge; do
        # Already present? Leave it untouched (never clobber real data).
        if curl -sf -m 5 "${_qdrant_url}/collections/${_coll}" &>/dev/null; then
            continue
        fi
        if curl -sf -m 10 -X PUT "${_qdrant_url}/collections/${_coll}" \
            -H 'Content-Type: application/json' \
            -d '{"vectors": {"size": 768, "distance": "Cosine"}}' &>/dev/null; then
            info "$(printf "$MSG_INFO_QDRANT_COLLECTION_PRECREATED" "${_coll}")"
        else
            warn "$(printf "$MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED" "${_coll}")"
        fi
    done
    unset _coll
else
    warn "$MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED"
fi
unset _qdrant_url _qdrant_ready

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
        fail_with_code "ERR-13-MODEL-PULL-NOMIC" "$MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT"
    fi
    ok "$MSG_OK_EMBEDDING_MODEL_READY"
fi

# CX-43 / #177 -- prove the embedding engine actually returns vectors
# before anything relies on it. A running Ollama with a broken runner
# (the old formula) pulls the model fine but returns HTTP 500 on
# /api/embed, which silently left Qdrant empty: hydrate_people reported
# status=ok while landing 0 points. Assert HTTP 200 AND a non-empty
# embeddings[0], and fail loudly otherwise.
info "$MSG_INFO_VERIFYING_EMBEDDINGS"
EMBED_HEALTH_BODY="$(mktemp -t ostler-embed-healthcheck)"
EMBED_HEALTH_CODE=$(curl -s --max-time 90 -o "$EMBED_HEALTH_BODY" -w '%{http_code}' \
    -X POST http://localhost:11434/api/embed \
    -H 'Content-Type: application/json' \
    -d '{"model":"nomic-embed-text","input":"healthcheck"}' 2>/dev/null || true)
if [[ "$EMBED_HEALTH_CODE" != "200" ]] || \
   ! grep -Eq '"embeddings":[[:space:]]*\[[[:space:]]*\[[[:space:]]*-?[0-9]' "$EMBED_HEALTH_BODY" 2>/dev/null; then
    rm -f "$EMBED_HEALTH_BODY"
    fail_with_code "ERR-13-EMBED-HEALTHCHECK" \
        "$(printf "$MSG_FAIL_EMBED_HEALTHCHECK" "$INSTALL_LOG")"
fi
rm -f "$EMBED_HEALTH_BODY"
ok "$MSG_OK_EMBEDDINGS_VERIFIED"

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
            fail_with_code "ERR-13-MODEL-PULL-AI" "$(printf "$MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS" "${AI_MODEL}")"
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
    # CX-81 B1 (2026-05-26): meeting_syncer + identity_resolver join
    # contact_syncer in the bundled set so install.sh's hydrate_graph
    # sub-phase (added at the same time, see Phase 3.X below) can run
    # both. identity_resolver is a sibling package both syncer.py
    # files import via a sys.path hack -- without it the
    # contact_syncer.syncer + meeting_syncer.syncer entry points
    # raise ImportError at install time.
    [[ -d "${SCRIPT_DIR}/meeting_syncer" ]] && cp -R "${SCRIPT_DIR}/meeting_syncer" "$PIPELINE_DIR/"
    [[ -d "${SCRIPT_DIR}/identity_resolver" ]] && cp -R "${SCRIPT_DIR}/identity_resolver" "$PIPELINE_DIR/"
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
        fail_with_code "ERR-14-IMPORT-PIPELINE" "$MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER"
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
        # CX-31 (2026-05-24): capture pip install output to a log so a
        # cryptography / wheel / network failure surfaces a real error
        # instead of silently set -e'ing the script. Pre-CX-31 a pip
        # failure here died invisible (audit ref: Studio retest #20
        # diagnosis CX-30 trail). Surface tail via warn() per-line so
        # the GUI prefix-aware parser actually renders the body.
        PIPELINE_PIP_LOG="/tmp/ostler-pipeline-pip.log"
        set +e
        .venv/bin/pip install --quiet -r "$PIPELINE_REQS" > "$PIPELINE_PIP_LOG" 2>&1
        PIPELINE_PIP_EXIT=$?
        set -e
        if [[ $PIPELINE_PIP_EXIT -ne 0 ]]; then
            warn "$(printf "$MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT" "$PIPELINE_PIP_EXIT")"
            warn "$MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES"
            while IFS= read -r line; do
                warn "    $line"
            done < <(tail -30 "$PIPELINE_PIP_LOG")
            fail_with_code "ERR-14-PIPELINE-PIP" "$MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED"
        fi
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

progress "Setting up conversation memory" "cm048_setup"

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
    fail_with_code "ERR-15-CM048-PIPELINE" "$MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN"
fi

if [[ "$CM048_SOURCE_OK" == true && -f "$CM048_DIR/pyproject.toml" ]]; then
    info "$(printf "$MSG_INFO_CREATING_PYTHON_VENV" "$CM048_VENV")"
    "$PYTHON3_BIN" -m venv "$CM048_VENV"

    info "$MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV"
    "$CM048_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null || true

    # ostler_security is a HARD dependency of CM048's pipeline -- src/
    # ingest.py imports ostler_security.database + ostler_security.posture
    # at module load and refuses to run without them, yet CM048's
    # pyproject.toml does NOT declare it (the two repos are deliberately
    # decoupled on disk -- productisation Rule 0.5). Install the vendored
    # source the same way the Hub venv does (Phase 3 ~L3352), BEFORE the
    # pipeline so the dep is resolvable. Without this every conversation
    # bundle exhausts at step 07, qdrant `conversations` stays at zero,
    # and the wiki /Conversations/ section ships permanently empty.
    if [[ -d "${SCRIPT_DIR}/ostler_security" && -f "${SCRIPT_DIR}/ostler_security/pyproject.toml" ]]; then
        info "$MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV"
        if ! "$CM048_VENV/bin/pip" install --quiet "${SCRIPT_DIR}/ostler_security" 2>/tmp/ostler-cm048-security-pip.log; then
            warn "$MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048"
            if [[ -s /tmp/ostler-cm048-security-pip.log ]]; then
                sed -e 's/^/    /' /tmp/ostler-cm048-security-pip.log | tail -5
            fi
        fi
    else
        warn "$MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048"
    fi

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
        # Under OSTLER_GUI=1 (Option B) /usr/local/bin has already
        # been chowned to the user by the parent .app's
        # AuthorizationHelper, so a plain `ln -sf` writes
        # user-side with no further sudo prompt. Matches the
        # ostler-knowledge symlink pattern below.
        if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
            ln -sf "$CM048_BIN" "$CM048_SYMLINK" \
                || sudo ln -sf "$CM048_BIN" "$CM048_SYMLINK"
        else
            sudo ln -sf "$CM048_BIN" "$CM048_SYMLINK"
        fi

        # Health check. Two gates, both must pass:
        #
        #   1. `pwg-convo --help` exercises the argparse entrypoint and
        #      confirms PATH-side wiring + venv binding (pwg-convo has no
        #      --version flag; --help exits 0).
        #
        #   2. `import src.ingest` inside the CM048 venv actually loads
        #      the pipeline module, which hard-imports ostler_security.
        #      The bare --help probe PASSES even with ostler_security
        #      missing -- argparse never touches src.ingest -- so on its
        #      own it logged `cm048_setup status=ok` for a dead pipeline
        #      (every conversation bundle then exhausting at step 07).
        #      This second gate makes a missing dependency FAIL the step.
        if "$CM048_SYMLINK" --help >/dev/null 2>&1 \
           && "$CM048_VENV/bin/python3" -c 'import src.ingest' >/tmp/ostler-cm048-import.log 2>&1; then
            ok "$MSG_OK_CM048_PIPELINE_READY"
        else
            warn "$MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP"
            if [[ -s /tmp/ostler-cm048-import.log ]]; then
                sed -e 's/^/    /' /tmp/ostler-cm048-import.log | tail -5
            fi
        fi
    else
        warn "$(printf "$MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML" "$CM048_BIN")"
    fi
elif [[ "$CM048_SOURCE_OK" == true ]]; then
    warn "$MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML"
fi

# ── 3.10b-models CM048 settings.yaml (RAM-aware conversation models) ──
#
# CM048's pipeline defaults its enrich/fact/relationship/coach steps to
# qwen3.5:35b-a3b, which needs ~18-20GB resident and cannot run on a 16GB
# box (and is a brutal squeeze on 24GB). The installer's RAM-aware picker
# already chose the model it actually pulled ($AI_MODEL: 35b-a3b only on
# 48GB+, 9b on 24-48GB, gemma4:e2b below), so point every conversation
# step at THAT model rather than a default no normal box can serve. Big-
# memory boxes opt into 35b-a3b automatically because that is what their
# picker selected; CM048's code default stays at 35b-a3b as the quality
# aspiration. Without this, conversations dispatch, classify, then die at
# 02_enrich with an Ollama 404 for the unpulled 35b-a3b model.
#
# CM048 auto-loads ~/.ostler/settings.yaml (ostler_paths.settings_yaml_
# path). The file also carries user_id so a manual pwg-convo run works
# without the bundle-agent env. Never clobber an existing file: a re-run
# or an operator edit wins.
_cm048_settings="${OSTLER_DIR}/settings.yaml"
_cm048_model="${AI_MODEL:-qwen3.5:9b}"
if [[ -f "$_cm048_settings" ]]; then
    info "$(printf "$MSG_INFO_CM048_SETTINGS_KEPT" "$_cm048_settings")"
else
    mkdir -p "$OSTLER_DIR"
    {
        printf 'user_id: %s\n' "${USER_ID:-ostler}"
        printf 'ollama_url: %s\n' "${OLLAMA_URL:-http://127.0.0.1:11434}"
        printf 'ollama_classify_model: %s\n' "$_cm048_model"
        printf 'ollama_enrich_model: %s\n' "$_cm048_model"
        printf 'ollama_fact_model: %s\n' "$_cm048_model"
        printf 'ollama_relationship_model: %s\n' "$_cm048_model"
        printf 'ollama_coach_model: %s\n' "$_cm048_model"
    } > "$_cm048_settings"
    chmod 0600 "$_cm048_settings"
    info "$(printf "$MSG_INFO_CM048_SETTINGS_WRITTEN" "$_cm048_model" "${RAM_GB:-?}")"
fi

# ── 3.10c Calendar / Gmail bridge for ical-server.py ─────────────
#
# Phase 3.10c installs the two binaries that ical-server.py
# (the local API on :8089, wired earlier in vendor/cm041/assistant_api/)
# expects at hard-coded paths:
#
#   1. /usr/local/bin/gws -- the Google Workspace CLI (Apache-2.0,
#      official Google build). Used by ical-server for Google
#      Calendar event listings + Gmail subject/snippet probes.
#      Source: https://github.com/googleworkspace/cli
#      The customer's first Gmail / Google Calendar call would
#      otherwise raise FileNotFoundError and the call silently
#      returns empty (try/except in ical-server.py swallows it).
#      See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F4.
#
#   2. ~/.ostler/ical/ical-query.sh -- a shell wrapper that ical-server
#      invokes for iCloud / CalDAV events. Without it the wrapper
#      shell-out raises FileNotFoundError and the iCloud calendar
#      returns empty events (same silent-degrade pattern as gws).
#      See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F5.
#
# Both are best-effort: a failure here logs WARN and continues so
# the rest of the install is unaffected. The customer-visible impact
# is that the iOS Companion's calendar / mail surfaces show empty
# until the bridge is repaired.

# 1. gws (Google Workspace CLI) -- download + SHA256-verify + install.
#
# Pinned to v0.22.5 (the version Andy runs on his Mac Mini). The
# release archives are signed by Google's release infrastructure
# and notarised by Apple; we pin the SHA256 of each architecture's
# tarball to guard against download tampering. If the customer is
# offline at install time the install logs WARN and continues; the
# Gmail / Calendar features stay degraded until the customer re-runs
# install.sh online.
GWS_VERSION="0.22.5"
progress "Installing Google Workspace CLI (gws v${GWS_VERSION})" "gws_install"


GWS_BIN_DEST="/usr/local/bin/gws"
GWS_BASE_URL="https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}"
GWS_SHA256_ARM64="1d2a9ffd5bc9b2c2c4b48630daf082fad13d9e57d741988a2c248eed562f7dac"
GWS_SHA256_X86_64="51f9bd731404d4bba26c36e2e30dd68c56dccd1f834c01252cb0b14d6a6544b2"

# Architecture detection. Apple Silicon ships aarch64; older Intel
# Macs ship x86_64. Universal2 binary is not produced upstream so
# we install the matching arch.
case "$(uname -m)" in
    arm64|aarch64)
        GWS_ARCH_LABEL="aarch64-apple-darwin"
        GWS_EXPECTED_SHA256="$GWS_SHA256_ARM64"
        ;;
    x86_64)
        GWS_ARCH_LABEL="x86_64-apple-darwin"
        GWS_EXPECTED_SHA256="$GWS_SHA256_X86_64"
        ;;
    *)
        GWS_ARCH_LABEL=""
        ;;
esac

if [[ -z "$GWS_ARCH_LABEL" ]]; then
    warn "$MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED"
elif [[ -x "$GWS_BIN_DEST" ]] && "$GWS_BIN_DEST" --version 2>/dev/null | grep -q "$GWS_VERSION"; then
    # Idempotency: a prior install at the matching version stays put.
    ok "$(printf "$MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION" "$GWS_VERSION")"
elif ! command -v curl >/dev/null 2>&1; then
    warn "$MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED"
else
    GWS_TMPDIR="$(mktemp -d -t ostler-gws.XXXXXX)"
    GWS_ARCHIVE="${GWS_TMPDIR}/gws.tar.gz"
    GWS_ARCHIVE_URL="${GWS_BASE_URL}/google-workspace-cli-${GWS_ARCH_LABEL}.tar.gz"
    if curl -fsSL --max-time 60 "$GWS_ARCHIVE_URL" -o "$GWS_ARCHIVE" 2>"${GWS_TMPDIR}/curl.log"; then
        GWS_ACTUAL_SHA256="$(shasum -a 256 "$GWS_ARCHIVE" | awk '{print $1}')"
        if [[ "$GWS_ACTUAL_SHA256" == "$GWS_EXPECTED_SHA256" ]]; then
            # Extract + install. Phase 3 already chowned /usr/local/bin
            # to the install user (Option B), so we do not need sudo.
            mkdir -p "${GWS_TMPDIR}/extracted"
            if tar -xzf "$GWS_ARCHIVE" -C "${GWS_TMPDIR}/extracted" 2>/dev/null \
               && [[ -f "${GWS_TMPDIR}/extracted/gws" ]]; then
                mkdir -p "$(dirname "$GWS_BIN_DEST")"
                cp "${GWS_TMPDIR}/extracted/gws" "$GWS_BIN_DEST"
                chmod 755 "$GWS_BIN_DEST"
                # The archive ships pre-codesigned + notarised by
                # Google; no further codesign step needed. Strip
                # any quarantine xattr from the curl-download so
                # Gatekeeper does not block first launch.
                /usr/bin/xattr -d com.apple.quarantine "$GWS_BIN_DEST" 2>/dev/null || true
                if "$GWS_BIN_DEST" --version >/dev/null 2>&1; then
                    ok "$(printf "$MSG_OK_GWS_INSTALLED_AT_VERSION_DEST" "$GWS_VERSION" "$GWS_BIN_DEST")"
                else
                    warn "$(printf "$MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED" "$GWS_BIN_DEST")"
                fi
            else
                warn "$MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED"
            fi
        else
            warn "$(printf "$MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT" "$GWS_EXPECTED_SHA256" "$GWS_ACTUAL_SHA256")"
        fi
    else
        warn "$(printf "$MSG_WARN_GWS_DOWNLOAD_FAILED_URL" "$GWS_ARCHIVE_URL")"
        if [[ -s "${GWS_TMPDIR}/curl.log" ]]; then
            warn "$MSG_WARN_CURL_SAID"
            sed -e 's/^/    /' "${GWS_TMPDIR}/curl.log" | head -5
        fi
    fi
    rm -rf "$GWS_TMPDIR"
fi

# 2. ~/.ostler/ical/ical-query.sh -- shell wrapper that ical-server
# invokes for iCloud / CalDAV calendar events.
#
# This used to live under ~/.zeroclaw/ -- a leak of the upstream
# runtime's codename into a customer-visible path (the dir is created
# and the path is printed in the install log pane). Repointed to
# ~/.ostler/ical/ so nothing customer-facing references the codename.
# ical-server.py reads its wrapper path from the ICAL_SCRIPT env var
# (defaulting to the old ~/.zeroclaw path), so the launchd plist below
# sets ICAL_SCRIPT to this new location explicitly -- the server still
# finds the wrapper after the move.
#
# The wrapper hands off to a Python module under the customer's
# Ostler venv. We write a stub that exits non-zero with a clear
# message until the customer has paired their iCloud account via
# the assistant UI (Phase 3.5b already wired the OSTLER_ICLOUD_USER
# / OSTLER_ICLOUD_APP_PASSWORD env vars when present). Once those
# env vars are set, the wrapper shells out to the python-caldav
# library to fetch upcoming events as raw iCal text.
ICAL_WRAPPER_DIR="${OSTLER_DIR}/ical"
ICAL_WRAPPER="${ICAL_WRAPPER_DIR}/ical-query.sh"
# ical-server.py also defaults INGEST_DIR and SYNC_STATE_DIR under the
# ~/.zeroclaw/ codename dir. Repointing ICAL_SCRIPT alone left those two
# defaults intact, so a ~/.zeroclaw/ dir still grew on the customer's
# disk. Pin both to ~/.ostler/ical/ subdirs and pre-create them; the
# launchd plist below exports the matching env vars so the server uses
# these paths and never touches ~/.zeroclaw/.
ICAL_INGEST_DIR="${ICAL_WRAPPER_DIR}/ingest"
ICAL_SYNC_STATE_DIR="${ICAL_WRAPPER_DIR}/sync-state"
mkdir -p "$ICAL_WRAPPER_DIR" "$ICAL_INGEST_DIR" "$ICAL_SYNC_STATE_DIR"
cat > "$ICAL_WRAPPER" <<'ICALWRAPEOF'
#!/usr/bin/env bash
# ostler ical-query wrapper. Generated by install.sh.
# Invoked by ical-server.py (vendor/cm041/assistant_api/ical-server.py)
# as: ical-query.sh <days>
#
# Reads OSTLER_ICLOUD_USER + OSTLER_ICLOUD_APP_PASSWORD from
# ${HOME}/.ostler/config/.env when present and uses python-caldav
# (installed into the Ostler venv) to fetch upcoming events from
# iCloud. Emits raw iCalendar lines (DTSTART/DTEND/SUMMARY/...) that
# ical-server.py's parse_ical_output() expects.
#
# British English throughout. No em-dashes in customer-facing output.
set -euo pipefail
DAYS="${1:-14}"
OSTLER_DIR="${HOME}/.ostler"
PYBIN="${OSTLER_DIR}/.venv/bin/python3"
ENV_FILE="${OSTLER_DIR}/config/.env"

if [[ ! -x "$PYBIN" ]]; then
    echo "ical-query: Ostler Python environment not found at $PYBIN" >&2
    exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

if [[ -z "${OSTLER_ICLOUD_USER:-}" || -z "${OSTLER_ICLOUD_APP_PASSWORD:-}" ]]; then
    # iCloud not paired yet. Exit 0 with empty output so ical-server
    # treats the calendar as "no events" rather than degraded.
    exit 0
fi

"$PYBIN" - "$DAYS" <<'PYEOF'
import os
import sys
from datetime import datetime, timedelta, timezone

try:
    import caldav  # noqa: F401
except ImportError:
    # caldav lib not installed in the Ostler venv; surface a clear
    # error to stderr so Doctor / healthz can flag it. ical-server
    # silently consumes stdout so stderr is the right channel.
    sys.stderr.write(
        "ical-query: python-caldav not installed. Run "
        ".venv/bin/pip install caldav inside ~/.ostler/.\n"
    )
    sys.exit(1)

import caldav  # second import after the guard above

days = int(sys.argv[1]) if len(sys.argv) > 1 else 14
user = os.environ.get("OSTLER_ICLOUD_USER", "")
pwd = os.environ.get("OSTLER_ICLOUD_APP_PASSWORD", "")
url = os.environ.get("OSTLER_ICLOUD_URL", "https://caldav.icloud.com/")

now = datetime.now(timezone.utc)
end = now + timedelta(days=days)

try:
    client = caldav.DAVClient(url=url, username=user, password=pwd)
    principal = client.principal()
    calendars = principal.calendars()
except Exception as exc:
    sys.stderr.write(f"ical-query: CalDAV login failed: {exc}\n")
    sys.exit(1)

for cal in calendars:
    try:
        events = cal.search(start=now, end=end, event=True, expand=True)
    except Exception:
        continue
    for ev in events:
        try:
            raw = ev.data
        except Exception:
            continue
        # Print only the lines parse_ical_output looks for.
        for line in raw.splitlines():
            stripped = line.strip()
            if stripped.startswith((
                "DTSTART",
                "DTEND",
                "LOCATION",
                "SUMMARY",
                "ATTENDEE",
                "ORGANIZER",
                "UID",
            )):
                print(stripped)
PYEOF
ICALWRAPEOF
chmod 755 "$ICAL_WRAPPER"

# Smoke-test the wrapper is executable + at the expected path. Do not
# actually exec it (no CalDAV creds yet at this point in install).
if [[ -x "$ICAL_WRAPPER" ]]; then
    ok "$(printf "$MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT" "$ICAL_WRAPPER")"
else
    warn "$(printf "$MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT" "$ICAL_WRAPPER")"
fi

# ── 3.11 Run GDPR import ─────────────────────────────────────────
# The install-time import now routes through the shared ostler-import
# fan-out (CM041 contacts + CM019 preferences). ostler-import must be
# created first (phase 3.12) and the CM019 venv must exist (phase
# 3.11b), so the import EXECUTION moved just below them to phase 3.12b.
# Same pipeline-setup region, same import_data progress step + messaging
# + guards; only the invocation changed (shared importer, not a direct
# contact_syncer call) and the preferences drop-zone joined EXPORTS_DIR.

# ── 3.11b Preference enrichment pipeline (CM019) ─────────────────
#
# Sets up the vendored CM019 ingest + enrich pipeline in its OWN venv at
# ~/.ostler/services/cm019/.venv (Ollama embedder, 768-dim, no torch).
# This is the venv the shared ostler-import importer (next phase), the
# install-time preferences hydrate, and the export watcher all run the
# CLI from. Setup is idempotent (skipped if the venv already exists) and
# non-fatal: a missing bundle or pip failure degrades to the wiki
# empty-state, it never aborts the install.

progress "Setting up preference enrichment" "cm019_setup"

CM019_BUNDLE="${SCRIPT_DIR}/cm019_preferences"
CM019_DIR="${OSTLER_DIR}/services/cm019"
CM019_VENV="${CM019_DIR}/.venv"
CM019_PY="${CM019_VENV}/bin/python"

# Always ensure the canonical drop-zone exists so onboarding can point
# at it and the watcher/hydrate can scan it even before any exports land.
mkdir -p "${OSTLER_DIR}/imports/preferences"

if [[ -d "$CM019_BUNDLE" && -f "$CM019_BUNDLE/requirements.txt" ]]; then
    if [[ ! -x "$CM019_PY" ]]; then
        info "$MSG_CM019_SETUP_STARTED"
        rm -rf "$CM019_DIR"
        mkdir -p "$CM019_DIR"
        cp -R "${CM019_BUNDLE}/" "$CM019_DIR/"
        "$PYTHON3_BIN" -m venv "$CM019_VENV"
        "$CM019_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
        if "$CM019_VENV/bin/pip" install --quiet -r "${CM019_DIR}/requirements.txt" 2>/tmp/ostler-cm019-pip.log; then
            ok "$MSG_CM019_SETUP_DONE"
        else
            warn "$MSG_CM019_SETUP_FAILED"
            if [[ -s /tmp/ostler-cm019-pip.log ]]; then
                sed -e 's/^/    /' /tmp/ostler-cm019-pip.log | tail -5
            fi
        fi
    else
        info "$MSG_CM019_SETUP_EXISTS"
    fi
else
    info "$MSG_CM019_SETUP_SKIPPED"
fi

# ── 3.12 ostler-import command ──────────────────────────────────

IMPORT_SCRIPT="${OSTLER_DIR}/bin/ostler-import"
mkdir -p "${OSTLER_DIR}/bin"

if [[ -f "${SCRIPT_DIR}/ostler-import.sh" ]]; then
    cp "${SCRIPT_DIR}/ostler-import.sh" "$IMPORT_SCRIPT"
else
    cat > "$IMPORT_SCRIPT" <<'IMPORTEOF'
#!/usr/bin/env bash
# Ostler shared export importer.
#
# Fans one or more export directories to THREE consumers:
#   - the people graph   (CM041 contact_syncer.import_all)
#   - the preference wiki (CM019 ingest-dir + enrich --all -> `preferences`)
#   - the universal importer (ostler_fda.universal_import) -- sniffs each
#     dir for a recognised export shape (Facebook Messenger, WhatsApp,
#     Apple Notes, a Google Takeout / .mbox, ...) and routes it to its
#     parser. Conversation exports (Facebook Messenger) additionally
#     persist to the conversations store via the CM048 pwg-convo pipeline.
#
# It is the SINGLE ingest path. Three entry points call it:
#   1. install.sh's install-time hydrate (Downloads + the drop-zone),
#   2. the Downloads export watcher (auto-run on detection), and
#   3. a power-user fallback (run it by hand).
#
# Safe to re-run over the same dir: contact_syncer dedupes (identity
# resolver + DedupDetector), the CM019 preferences upsert is keyed by
# stable id, and the CM048 conversation pipeline keys by conversation_id
# (a re-run overwrites the same bundle), so a second pass is a no-op
# rather than a duplicate.
#
# Non-fatal by design: a missing/!ready pipeline is skipped, not a hard
# error, so one consumer being unavailable never blocks the others.
set -uo pipefail
OSTLER_DIR="${HOME}/.ostler"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"
CM019_DIR="${OSTLER_DIR}/services/cm019"
CM019_PY="${CM019_DIR}/.venv/bin/python"
# The universal importer (ostler_fda.universal_import) runs from the
# email-ingest venv, the one venv on the box that pip-installs ostler_fda,
# with the staged fda-module on sys.path as a belt-and-braces fallback.
# pwg-convo (the conversation sink it persists through) is resolved by
# universal_import itself, honouring OSTLER_PWG_CONVO_CMD.
UIMPORT_PY="${OSTLER_DIR}/services/email-ingest/.venv/bin/python"
UIMPORT_FDA_DIR="${OSTLER_DIR}/fda-module"

USER_NAME_ARG=""
USER_ID_ARG=""
VERBOSE=""
DIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-name) USER_NAME_ARG="${2:-}"; shift 2 ;;
        --user-id)   USER_ID_ARG="${2:-}"; shift 2 ;;
        --verbose)   VERBOSE="--verbose"; shift ;;
        -h|--help)
            echo "Usage: ostler-import <exports-dir> [<exports-dir>...] [--user-name \"Name\"] [--user-id slug] [--verbose]"
            echo ""
            echo "Imports GDPR / app exports into your people graph, your"
            echo "preferences, and (for recognised exports like Facebook"
            echo "Messenger) your conversation memory. Ostler runs this for you"
            echo "automatically; you only need it by hand to re-import a folder"
            echo "Ostler did not pick up."
            exit 0 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "Usage: ostler-import <exports-dir> [<exports-dir>...] [--user-name \"Name\"] [--user-id slug] [--verbose]"
    exit 1
fi

if [[ -f "${OSTLER_DIR}/config/.env" ]]; then
    set -a; source "${OSTLER_DIR}/config/.env"; set +a
fi
# CM019 tags points by user slug; prefer an explicit flag, then the
# installed-user env, then a neutral default.
CM019_USER="${USER_ID_ARG:-${OSTLER_USER:-ostler}}"

rc=0
for d in "${DIRS[@]}"; do
    [[ -d "$d" ]] || continue

    # ── People graph (CM041 contacts) ──────────────────────────────
    if [[ -d "$PIPELINE_DIR/contact_syncer" && -x "$PIPELINE_DIR/.venv/bin/python3" ]]; then
        CS_ARGS=(--exports-dir "$d")
        [[ -n "$USER_NAME_ARG" ]] && CS_ARGS+=(--user-name "$USER_NAME_ARG")
        [[ -n "$VERBOSE" ]] && CS_ARGS+=("$VERBOSE")
        ( cd "$PIPELINE_DIR" && .venv/bin/python3 -m contact_syncer.import_all "${CS_ARGS[@]}" ) || rc=$?
    fi

    # ── Preference wiki (CM019 ingest + enrich) ────────────────────
    if [[ -x "$CM019_PY" ]]; then
        ( cd "$CM019_DIR" && QDRANT_COLLECTION=preferences \
            "$CM019_PY" -m services.ingest.src.cli ingest-dir "$d" -u "$CM019_USER" ) || rc=$?
        ( cd "$CM019_DIR" && QDRANT_COLLECTION=preferences \
            "$CM019_PY" -m services.enrich.src.cli enrich --all -u "$CM019_USER" ) || rc=$?
    fi

    # ── Universal importer (ostler_fda.universal_import) ───────────
    # Sniff the dir for a recognised export shape and route it to its
    # parser. This is the leg that wires the previously-orphan P3 path
    # into the real install: a dropped Facebook Messenger export now
    # parses AND persists to the conversations store (via pwg-convo),
    # not just stages JSON under ~/.ostler/imports/fda/. ADDITIVE: it
    # runs AFTER P1/P2 over the same dir and shares no state with them,
    # so it cannot regress contacts or preferences. Skip-if-absent: no
    # email-ingest venv (so no ostler_fda) -> the leg is skipped, never
    # an error. universal_import is itself non-crashing (an unknown drop
    # is reported, not raised) so a stray folder cannot fail the import.
    if [[ -x "$UIMPORT_PY" ]]; then
        ( PYTHONPATH="${UIMPORT_FDA_DIR}:${PYTHONPATH:-}" \
            "$UIMPORT_PY" -m ostler_fda.universal_import "$d" ) || rc=$?
    fi
done
exit $rc
IMPORTEOF
fi

chmod +x "$IMPORT_SCRIPT"

# ── 3.12b Install-time import (shared fan-out) ──────────────────
#
# Relocated from phase 3.11: the install-time import now runs through
# the shared ostler-import (just created above) over any exports the
# customer ALREADY has -- detected in Downloads (EXPORTS_DIR) and/or
# dropped in the preferences drop-zone -- so the first wiki compile has
# real content. One pass, both pipelines: CM041 contacts AND CM019
# preferences. Later arrivals are caught by the Downloads watcher (3.13).
#
# Behaviour-preserving for contacts: ostler-import makes the identical
# contact_syncer.import_all call over the same EXPORTS_DIR; only the
# invocation is now via the shared importer. Guarded + non-fatal:
# skips cleanly when there is nothing to import and never aborts the
# install (ostler-import is set -uo, no -e). Counts-only readback.

_PREFS_DROPZONE="${OSTLER_DIR}/imports/preferences"
_IMPORT_DIRS=()
[[ -n "${EXPORTS_DIR:-}" && -d "${EXPORTS_DIR}" ]] && _IMPORT_DIRS+=("$EXPORTS_DIR")
# CX-126: the install-time detector (line ~3554) now matches the current
# 2026 export filenames (your_friends.json, tweets.js), so it seeds
# EXPORTS_DIR to the actual export directory for every platform -- which
# the importer then rglobs (bounded to that export dir). An earlier draft
# of this fix also appended ~/Downloads + ~/Desktop here as a backstop,
# but that made the importer rglob the ENTIRE Downloads/Desktop trees
# (unbounded, ~10 patterns, plus a per-dir enrich pass) -- a multi-minute
# install-time stall on a large Downloads folder, and redundant now that
# the detector seeds correctly. Reverted: keep the bounded EXPORTS_DIR
# root only. (Adversarial review finding D, CX-126.)
if [[ -d "$_PREFS_DROPZONE" ]] \
   && find "$_PREFS_DROPZONE" -type f ! -name '.*' -print -quit 2>/dev/null | grep -q .; then
    _IMPORT_DIRS+=("$_PREFS_DROPZONE")
fi

# ── Mailbox correspondents -> people graph (v1.0.3 mailbox-ingest leg) ──
# Seed the universal_import P3 leg with any RAW MAILBOX the operator has,
# so its correspondents (who they email, how often) land as Person nodes
# in the people graph -- the biggest untapped GDPR enrichment. The leg
# itself (already wired above) sniffs each dir and routes a Gmail .mbox or
# an Apple Mail .emlx tree to ostler_fda.universal_import, which persists
# people-graph facts via pwg_ingest (email BODIES are never persisted --
# people-only, normal People privacy level). BOUNDED by design (the CX-126
# lesson): we seed ONLY specific, already-confirmed mailbox roots, never an
# unbounded Downloads rglob.
#   1. The Gmail Takeout mbox the customer already confirmed in 9.4
#      (OSTLER_TAKEOUT_PATH) -- pass its containing dir so the leg sniffs
#      the single .mbox, not a whole tree.
#   2. An explicit OSTLER_MAILBOX_DIR (Apple Mail .emlx export or a loose
#      .mbox the operator points us at). No hardcoded paths; skip-if-absent.
if [[ -n "${OSTLER_TAKEOUT_PATH:-}" && -f "${OSTLER_TAKEOUT_PATH}" ]]; then
    _IMPORT_DIRS+=("$(dirname "${OSTLER_TAKEOUT_PATH}")")
fi
if [[ -n "${OSTLER_MAILBOX_DIR:-}" && -d "${OSTLER_MAILBOX_DIR}" ]]; then
    _IMPORT_DIRS+=("${OSTLER_MAILBOX_DIR}")
fi

if [[ ${#_IMPORT_DIRS[@]} -gt 0 && -x "$IMPORT_SCRIPT" ]]; then
    progress "Importing your data (building your knowledge graph)" "import_data"
    info "$MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES"
    if "$IMPORT_SCRIPT" "${_IMPORT_DIRS[@]}" \
        --user-name "$USER_NAME" --user-id "$USER_ID" --verbose 2>&1 \
        | while IFS= read -r line; do echo "  $line"; done; then
        ok "$MSG_OK_GDPR_IMPORT_COMPLETE"
    else
        warn "$MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN"
        warn "$(printf "$MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE" "${_IMPORT_DIRS[0]}" "${USER_NAME}")"
    fi
    # Counts-only preferences readback; no item content leaves the process.
    _PREFS_POINTS="$(
        curl -sf -m 5 "${QDRANT_URL:-http://localhost:6333}/collections/preferences" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(((d.get("result") or {}).get("points_count")) or 0))
except Exception:
    print(0)' 2>/dev/null
    )"
    _PREFS_POINTS="${_PREFS_POINTS:-0}"
    if [[ "$_PREFS_POINTS" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_PREFERENCES_DONE" "$_PREFS_POINTS")"

        # ── Category coverage guard (CX: silent-blank Food / Music) ─────
        # Preferences landed, but the headline wiki pages (Food, Music,
        # Professional) and every Topic page read a `category` field off the
        # Qdrant payload. If points arrive carrying no/wrong category they
        # reach NO page, so the wiki renders "Nothing here yet" while the
        # service is green -- exactly the failure that hid food=0 / music=0
        # behind a healthy install. Surface it loudly here rather than
        # leaving the operator to discover blank pages later. Counts-only,
        # no item content leaves the process; non-fatal (warn, never abort).
        _cat_count() {
            # Count points whose payload.category == $1. Empty/!ready -> 0.
            curl -sf -m 5 -H 'Content-Type: application/json' \
                -X POST "${QDRANT_URL:-http://localhost:6333}/collections/preferences/points/count" \
                -d "{\"exact\":true,\"filter\":{\"must\":[{\"key\":\"category\",\"match\":{\"value\":\"$1\"}}]}}" \
                2>/dev/null \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(((d.get("result") or {}).get("count")) or 0))
except Exception:
    print(0)' 2>/dev/null
        }
        _FOOD_POINTS="$(_cat_count food)";          _FOOD_POINTS="${_FOOD_POINTS:-0}"
        _MUSIC_POINTS="$(_cat_count music)";         _MUSIC_POINTS="${_MUSIC_POINTS:-0}"
        _PROF_POINTS="$(_cat_count professional)";   _PROF_POINTS="${_PROF_POINTS:-0}"

        # Count points with no category at all (orphans that reach no Topic
        # page). Qdrant `is_empty` matches null/absent payload keys.
        _UNCAT_POINTS="$(
            curl -sf -m 5 -H 'Content-Type: application/json' \
                -X POST "${QDRANT_URL:-http://localhost:6333}/collections/preferences/points/count" \
                -d '{"exact":true,"filter":{"must":[{"is_empty":{"key":"category"}}]}}' \
                2>/dev/null \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(((d.get("result") or {}).get("count")) or 0))
except Exception:
    print(0)' 2>/dev/null
        )"
        _UNCAT_POINTS="${_UNCAT_POINTS:-0}"

        # All three headline categories empty despite points landing = the
        # category-mapping/ingest leg dropped them. Loud warning.
        if [[ "$_FOOD_POINTS" -eq 0 && "$_MUSIC_POINTS" -eq 0 && "$_PROF_POINTS" -eq 0 ]]; then
            warn "$(printf "$MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES" "$_PREFS_POINTS")"
            warn "$MSG_WARN_PREFS_HEADLINE_HINT"
        fi

        # >25% of points with no category at all = mapping gap; they will
        # never surface on a Topic page. Integer maths (no bc dependency).
        if [[ "$_UNCAT_POINTS" -gt 0 ]] \
           && [[ $(( _UNCAT_POINTS * 100 / _PREFS_POINTS )) -gt 25 ]]; then
            warn "$(printf "$MSG_WARN_PREFS_UNCATEGORISED" \
                "$_UNCAT_POINTS" "$_PREFS_POINTS" \
                "$(( _UNCAT_POINTS * 100 / _PREFS_POINTS ))")"
        fi

        unset -f _cat_count
        unset _FOOD_POINTS _MUSIC_POINTS _PROF_POINTS _UNCAT_POINTS
    fi
    unset _PREFS_POINTS
elif [[ -n "${EXPORTS_DIR:-}" ]]; then
    info "$MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE"
    info "$(printf "$MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM" "${EXPORTS_DIR}")"
fi
unset _PREFS_DROPZONE _IMPORT_DIRS

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

# Create a self-removing contact re-sync wrapper. Re-runs the CM041
# contact_syncer against the LOCAL AddressBook store -- specifically the
# Full-Disk-Access-gated AddressBook-v22.abcddb fallback, NOT the
# Contacts.app osascript export that needs Automation -- so contacts that
# iCloud finishes syncing AFTER the install window still reach the graph.
# Idempotent: the syncer dedupes by identity, so re-runs only add what is
# new. Driven by the com.ostler.contact-resync LaunchAgent, which the
# hydrate step schedules ONLY when it saw configured accounts but imported
# zero (the iCloud-sync timing race). The wrapper boots out its own agent
# once it imports at least one contact, or after CONTACT_RESYNC_MAX_TRIES
# attempts, so a Mac that never finishes syncing can never keep a re-sync
# agent alive indefinitely.
cat > "${OSTLER_DIR}/bin/ostler-contact-resync" <<'CRSEOF'
#!/usr/bin/env bash
set -euo pipefail

OSTLER_DIR="${HOME}/.ostler"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"
PIPELINE_PY="${PIPELINE_DIR}/.venv/bin/python"
OXIGRAPH_URL="${OXIGRAPH_URL:-http://localhost:7878}"
LOGS_DIR="${OSTLER_DIR}/logs"
STATE_DIR="${OSTLER_DIR}/state"
LABEL="com.ostler.contact-resync"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
TRIES_FILE="${STATE_DIR}/contact-resync.tries"
LOG_FILE="${LOGS_DIR}/contact-resync.log"
CONTACT_RESYNC_MAX_TRIES="${CONTACT_RESYNC_MAX_TRIES:-48}"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

remove_self() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TRIES_FILE"
}

# Bounded retry: bump the attempt counter and, once it exceeds the cap,
# give up and remove the agent. Belt-and-braces against a Mac that never
# finishes syncing contacts.
tries=0
[[ -f "$TRIES_FILE" ]] && tries="$(cat "$TRIES_FILE" 2>/dev/null || echo 0)"
[[ "$tries" =~ ^[0-9]+$ ]] || tries=0
tries=$((tries + 1))
printf '%s' "$tries" >"$TRIES_FILE"
if [[ "$tries" -gt "$CONTACT_RESYNC_MAX_TRIES" ]]; then
    log "giving up after ${CONTACT_RESYNC_MAX_TRIES} attempts; removing agent"
    remove_self
    exit 0
fi

if [[ ! -x "$PIPELINE_PY" ]]; then
    log "import-pipeline venv missing at ${PIPELINE_PY}; will retry (attempt ${tries})"
    exit 0
fi

# Force the AddressBook-v22.abcddb fallback by pointing --vcf at a path we
# never create: the syncer logs "vCard file not found" and reads the
# now-synced local AddressBook directly (Full Disk Access only).
FORCE_ABCDDB_VCF="${OSTLER_DIR}/imports/.contact-resync-force-abcddb.vcf"
rm -f "$FORCE_ABCDDB_VCF" 2>/dev/null || true

json="$(
    cd "$PIPELINE_DIR" && \
    "$PIPELINE_PY" -m contact_syncer.syncer \
        --vcf "$FORCE_ABCDDB_VCF" \
        --graph-endpoint "$OXIGRAPH_URL" 2>>"$LOG_FILE" \
    | tail -n 1
)" || json=""

count="$(
    printf '%s' "$json" | python3 -c 'import json,sys
try:
    print(int(json.loads(sys.stdin.read()).get("imported", 0)))
except Exception:
    print(0)' 2>/dev/null
)"
count="${count:-0}"

if [[ "$count" -gt 0 ]]; then
    log "contact re-sync imported ${count} contact(s) on attempt ${tries}; removing agent"
    # New contacts have just landed in the graph. The install-time wiki
    # compile (Phase 3.16) ran before iCloud finished syncing, so on a
    # fresh Mac it saw a near-empty People graph. Kick the existing
    # wiki-recompile tick now so the wiki reflects the contacts that have
    # just arrived, rather than waiting for the daily LaunchAgent. Fired
    # non-fatally and backgrounded: a recompile failure (or a missing tick
    # on an older layout) must never break the re-sync or hold the agent
    # open. Guarded on the tick being present so an older install that
    # predates wiki-recompile degrades quietly.
    #
    # Known limitation (v1.0.1, out of scope here): this does NOT re-run
    # the Qdrant people search-index embed (hydrate_people), so the newly
    # imported people render on their wiki PAGES (read from Oxigraph) but
    # may be momentarily absent from wiki SEARCH until the next embed.
    if [[ -x "${OSTLER_DIR}/bin/wiki-recompile-tick.sh" ]]; then
        log "new contacts imported; rebuilding your wiki in the background"
        nohup "${OSTLER_DIR}/bin/wiki-recompile-tick.sh" >/dev/null 2>&1 &
    fi
    remove_self
else
    log "contacts still not synced (attempt ${tries}/${CONTACT_RESYNC_MAX_TRIES}); will retry"
fi
exit 0
CRSEOF
chmod +x "${OSTLER_DIR}/bin/ostler-contact-resync"

# Create an export watcher script -- scans Downloads for new GDPR exports
cat > "${OSTLER_DIR}/bin/ostler-scan-exports" <<'SCANEOF'
#!/usr/bin/env bash
# Scans ~/Downloads for recognised exports and imports them automatically.
# Runs via launchd. NO Terminal step: on detecting a new export set it
# invokes the shared ostler-import (CM041 contacts + CM019 preferences)
# and shows a friendly notification. Re-run safe: ostler-import dedupes
# (contacts) and upserts by stable id (preferences).
set -uo pipefail

OSTLER_DIR="${HOME}/.ostler"
SCAN_STATE="${OSTLER_DIR}/state/scan_state.json"
DOWNLOADS="${HOME}/Downloads"
IMPORT_SCRIPT="${OSTLER_DIR}/bin/ostler-import"

mkdir -p "${OSTLER_DIR}/state"

_notify() {
    # $1 = message, $2 = subtitle
    osascript -e "display notification \"$1\" with title \"Ostler\" subtitle \"$2\"" 2>/dev/null || true
}

# Recognised export shapes. FOUND holds paths; FOUND_LABELS the platform
# names (for a friendly notification). Order people-graph first, then
# preference exports.
FOUND=()
FOUND_LABELS=()
_add() { [[ -e "$1" ]] && { FOUND+=("$1"); FOUND_LABELS+=("$2"); }; }

# People graph (contacts / social)
for f in "$DOWNLOADS"/Basic_LinkedInDataExport_*/ "$DOWNLOADS"/linkedin_*.zip "$DOWNLOADS"/LinkedInDataExport_*.zip; do _add "$f" "LinkedIn"; done
for f in "$DOWNLOADS"/facebook-*/ "$DOWNLOADS"/facebook_*.zip; do _add "$f" "Facebook"; done
for f in "$DOWNLOADS"/instagram-*/ "$DOWNLOADS"/instagram_*.zip; do _add "$f" "Instagram"; done
for f in "$DOWNLOADS"/takeout-*.zip "$DOWNLOADS"/Takeout/; do _add "$f" "Google"; done
for f in "$DOWNLOADS"/twitter-*/ "$DOWNLOADS"/twitter-*.zip "$DOWNLOADS"/x-*.zip; do _add "$f" "X"; done

# Preference exports (music / film / shopping)
for f in "$DOWNLOADS"/my_spotify_data*.zip "$DOWNLOADS"/Spotify*.zip "$DOWNLOADS"/SpotifyExtendedStreamingHistory*.zip; do _add "$f" "Spotify"; done
for f in "$DOWNLOADS"/netflix-*.zip "$DOWNLOADS"/NetflixViewingHistory*.csv; do _add "$f" "Netflix"; done
for f in "$DOWNLOADS"/Apple_Media_Services*.zip "$DOWNLOADS"/AppleMediaServices*.zip "$DOWNLOADS"/apple*media*services*.zip; do _add "$f" "Apple"; done
for f in "$DOWNLOADS"/amazon*.zip "$DOWNLOADS"/"Your Orders"*.zip; do _add "$f" "Amazon"; done

# #657: supplement the name-glob matches above with the SAME signature-based
# detector the install-time scan uses, so renamed / "Complete" / still-zipped
# exports dropped here later are caught too (not just the exact 2026 names).
# Strictly ADDITIVE with a fallback: if the detector lib is unreadable this
# block is skipped entirely, leaving behaviour byte-identical to the name-glob
# path above -- a missing/failed lib read can never regress a working install.
_OSTLER_DETECT="${OSTLER_DIR}/lib/ostler-detect-exports.sh"
if [[ -r "$_OSTLER_DETECT" ]]; then
    while IFS=$'\t' read -r _lbl _pth; do
        [[ -n "$_pth" ]] && _add "$_pth" "$_lbl"
    done < <(bash "$_OSTLER_DETECT" "$DOWNLOADS" --unzip 2>/dev/null || true)
fi

[[ ${#FOUND[@]} -eq 0 ]] && exit 0

# Guard: skip while anything is still downloading -- partial-download
# markers (Safari .download, Chrome .crdownload, Firefox .part). The
# next tick retries once the download completes.
for p in "$DOWNLOADS"/*.download "$DOWNLOADS"/*.crdownload "$DOWNLOADS"/*.part; do
    [[ -e "$p" ]] && exit 0
done

# Belt-and-braces: if any found FILE is still growing, wait for next tick.
for f in "${FOUND[@]}"; do
    if [[ -f "$f" ]]; then
        s1=$(stat -f%z "$f" 2>/dev/null || echo 0)
        sleep 2
        s2=$(stat -f%z "$f" 2>/dev/null || echo 0)
        [[ "$s1" != "$s2" ]] && exit 0
    fi
done

# Dedupe: same export set already imported? (FOUND_HASH in scan_state)
FOUND_HASH=$(printf '%s\n' "${FOUND[@]}" | sort | shasum | cut -d' ' -f1)
if [[ -f "$SCAN_STATE" ]] && grep -q "$FOUND_HASH" "$SCAN_STATE" 2>/dev/null; then
    exit 0
fi

# Importer not installed yet (mid-install race) -- try again next tick.
[[ -x "$IMPORT_SCRIPT" ]] || exit 0

# Auto-import. ostler-import fans to BOTH pipelines over the whole
# Downloads folder and is re-run safe.
_first="${FOUND_LABELS[0]}"
if [[ ${#FOUND[@]} -gt 1 ]]; then
    _notify "Ostler found your ${_first} export and $(( ${#FOUND[@]} - 1 )) more, and is adding them to your world." "Importing"
else
    _notify "Ostler found your ${_first} export and is adding it to your world." "Importing"
fi

if "$IMPORT_SCRIPT" "$DOWNLOADS" >/dev/null 2>&1; then
    _notify "Your latest export is now part of your world." "Done"
else
    _notify "Imported your latest export. Some parts will finish in the background." "Done"
fi

# Record only after a real import attempt, so a failed/partial run is
# retried next tick rather than silently marked done.
echo "$FOUND_HASH" >> "$SCAN_STATE"

if [[ -t 1 ]]; then
    echo "Imported ${#FOUND[@]} export(s):"
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

# ── Pre-meeting brief sender ───────────────────────────────────────
#
# Every 10 min during waking hours (07:00 - 21:00 local), poll the
# Hub's GET /api/v1/meeting/upcoming?within_minutes=20 endpoint and
# ship a WhatsApp message for any meeting whose brief has not yet
# been sent. Idempotency via ~/.ostler/state/sent_briefs.db keyed by
# (meeting UID + scheduled start).
#
# v1.0 ships WhatsApp only; future v1.0.1 / v1.1 may add iMessage +
# email channels. The bin script reuses the daily-brief delivery
# code path on the ostler-assistant side via the assistant's
# announcement REST API (no Rust changes required in v1.0).
#
# Feature-flagged OFF for v1.0: the Hub endpoint
# /api/v1/meeting/upcoming and the assistant's /announce target
# do not exist yet. The agent would silently exit 0 on every poll
# and never deliver a brief. v1.0.1 will ship both endpoints and
# flip INSTALL_MEETING_BRIEF_LAUNCHAGENT=true.

INSTALL_MEETING_BRIEF_LAUNCHAGENT="${INSTALL_MEETING_BRIEF_LAUNCHAGENT:-false}"
if [ "$INSTALL_MEETING_BRIEF_LAUNCHAGENT" = "true" ]; then
cat > "${OSTLER_DIR}/bin/ostler-meeting-brief-sender" <<'BRIEFEOF'
#!/usr/bin/env bash
# Poll the Hub's pre-meeting brief endpoint and ship unsent briefs
# via WhatsApp. Idempotent via a SQLite-backed sent-briefs cache.
#
# Designed to be safe under launchd: any hard failure exits 0 with
# a stderr log line so the LaunchAgent does not get throttled.
set -uo pipefail

OSTLER_DIR="${HOME}/.ostler"
STATE_DIR="${OSTLER_DIR}/state"
SENT_DB="${STATE_DIR}/sent_briefs.db"
LOG_FILE="${OSTLER_DIR}/logs/meeting-brief-sender.log"
HUB_HOST="${OSTLER_HUB_HOST:-http://localhost:8089}"
ASSISTANT_URL="${OSTLER_ASSISTANT_URL:-http://localhost:8090}"
WITHIN_MINUTES="${OSTLER_BRIEF_WITHIN_MINUTES:-20}"

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

# Quiet hours guard. Default 07:00 - 21:00 local; overridable via env
# for operators on shifted schedules.
HOUR_NOW=$(date +%H)
QUIET_START="${OSTLER_BRIEF_QUIET_START:-21}"
QUIET_END="${OSTLER_BRIEF_QUIET_END:-7}"
if (( 10#${HOUR_NOW} >= 10#${QUIET_START} || 10#${HOUR_NOW} < 10#${QUIET_END} )); then
    echo "$(date -u +%FT%TZ) skip: quiet hours (hour=${HOUR_NOW})" >> "${LOG_FILE}"
    exit 0
fi

# Bootstrap the sent-briefs DB on first run.
sqlite3 "${SENT_DB}" <<'SQLINIT' 2>>"${LOG_FILE}" || true
CREATE TABLE IF NOT EXISTS sent_briefs (
    key TEXT PRIMARY KEY,
    meeting_uid TEXT NOT NULL,
    scheduled_start TEXT NOT NULL,
    sent_at TEXT NOT NULL
);
SQLINIT

# Fetch upcoming meetings from the Hub. Curl returns 200 even on
# degraded payloads so we check `degraded` server-side and skip
# delivery rather than emitting stale messages.
RESPONSE=$(curl -sS -m 8 \
    "${HUB_HOST}/api/v1/meeting/upcoming?within_minutes=${WITHIN_MINUTES}" \
    2>>"${LOG_FILE}") || {
    echo "$(date -u +%FT%TZ) skip: hub fetch failed" >> "${LOG_FILE}"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    echo "$(date -u +%FT%TZ) skip: empty hub response" >> "${LOG_FILE}"
    exit 0
fi

# Degraded short-circuit. The hub returns degraded=true when the
# People Graph is unreachable; we do not want to ship a brief with
# missing attendee facts.
DEGRADED=$(printf '%s' "${RESPONSE}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("degraded", False))' \
    2>>"${LOG_FILE}") || DEGRADED="False"
if [[ "${DEGRADED}" == "True" ]]; then
    echo "$(date -u +%FT%TZ) skip: hub degraded" >> "${LOG_FILE}"
    exit 0
fi

# Iterate meetings. Each meeting's idempotency key is UID + start;
# the assistant's announcement endpoint is the WhatsApp arm.
printf '%s' "${RESPONSE}" | python3 - "${SENT_DB}" "${ASSISTANT_URL}" "${LOG_FILE}" <<'PYEOF'
import json, sqlite3, subprocess, sys, time
from datetime import datetime, timezone

db_path, assistant_url, log_path = sys.argv[1:]
payload = json.load(sys.stdin)
meetings = payload.get("meetings") or []

def _log(msg):
    with open(log_path, "a") as fh:
        fh.write(f"{datetime.now(timezone.utc).isoformat()} {msg}\n")

if not meetings:
    _log(f"no meetings in window")
    sys.exit(0)

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    for m in meetings:
        uid = m.get("uid") or ""
        start = m.get("start_iso") or m.get("start") or ""
        if not uid or not start:
            _log(f"skip: missing uid/start in meeting {m.get('meeting', '?')}")
            continue
        key = f"{uid}|{start}"
        cur.execute("SELECT 1 FROM sent_briefs WHERE key = ?", (key,))
        if cur.fetchone():
            _log(f"skip: already sent {key}")
            continue

        # Render plain-text message client-side. The renderer lives
        # on the brief module side (CM041) for v1.0.1; here we build
        # a minimal echo so the LaunchAgent does not depend on a
        # Python import path matching the source tree layout.
        title = m.get("meeting") or "Upcoming meeting"
        when = m.get("start") or ""
        attendees = m.get("attendees") or []
        names = ", ".join(
            (a.get("name") or a.get("email") or "Unknown")
            for a in attendees[:3]
        )
        lines = [f"Meeting: {title}"]
        if when:
            lines[0] += f" at {when}"
        lines[0] += "."
        if m.get("maps_url"):
            lines.append(f"Location: {m.get('location', '')} {m['maps_url']}")
        if names:
            lines.append(f"With: {names}.")
        first = attendees[0] if attendees else {}
        if first.get("wiki_url"):
            lines.append(f"Wiki: {first['wiki_url']}")
        if first.get("last_discussion_url"):
            lines.append(f"Last chat: {first['last_discussion_url']}")
        open_todos = []
        for a in attendees:
            for t in (a.get("outstanding_todos") or [])[:3]:
                open_todos.append(t)
        if open_todos:
            short = []
            for t in open_todos[:3]:
                owner = t.get("owner_display") or t.get("owner") or ""
                owner_label = f"{owner}: " if owner else ""
                deadline = f" (by {t['deadline']})" if t.get("deadline") else ""
                short.append(f"{owner_label}{t.get('text', '')}{deadline}")
            lines.append("Open: " + " | ".join(short))
        message = "\n".join(lines)

        # Ship to the assistant. The assistant's announce endpoint
        # is the WhatsApp arm reused from the daily-brief delivery
        # path. Failure here is non-fatal (we just retry next tick
        # because the row was not written to sent_briefs).
        body = json.dumps({
            "channel": "whatsapp",
            "kind": "meeting_brief",
            "message": message,
            "meeting_uid": uid,
        }).encode()
        try:
            res = subprocess.run([
                "curl", "-sS", "-m", "6", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--data-binary", body.decode(),
                f"{assistant_url}/announce",
            ], capture_output=True, timeout=10)
            if res.returncode != 0:
                _log(f"deliver failed key={key} rc={res.returncode}")
                continue
        except Exception as exc:
            _log(f"deliver exception key={key} err={exc}")
            continue

        cur.execute(
            "INSERT OR REPLACE INTO sent_briefs "
            "(key, meeting_uid, scheduled_start, sent_at) VALUES (?,?,?,?)",
            (key, uid, start, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
        _log(f"sent key={key}")
finally:
    conn.close()
PYEOF

exit 0
BRIEFEOF
chmod +x "${OSTLER_DIR}/bin/ostler-meeting-brief-sender"

# Install the LaunchAgent. StartInterval 600 s = 10 min; combined
# with the 20-min look-ahead in the bin script gives 10-30 min
# notice on every meeting without spamming.
mkdir -p "${HOME}/Library/LaunchAgents"
BRIEF_PLIST="${HOME}/Library/LaunchAgents/com.ostler.meeting-brief-sender.plist"
cat > "$BRIEF_PLIST" <<MBSPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.meeting-brief-sender</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/ostler-meeting-brief-sender</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/meeting-brief-sender.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/meeting-brief-sender.err</string>
</dict>
</plist>
MBSPLIST
launchctl bootstrap "gui/$(id -u)" "$BRIEF_PLIST" 2>/dev/null || \
    launchctl load "$BRIEF_PLIST" 2>/dev/null || true
ok "$MSG_OK_MEETING_BRIEF_SENDER_INSTALLED"
else
    info "$MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED"
fi

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
else
    # Surface a missing-bundle warning. The deferred-register agent
    # is a belt-and-braces retry path; the primary registration runs
    # during install via the GUI. Worst-case impact is the customer
    # silently consuming a device slot without retry if the install-
    # time POST failed. See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F9.
    warn "$MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED"
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
echo "    - Doctor, export watcher, hub power, email-ingest, conversation feeds"
echo "      (whatsapp-bundle, email-bundle, spoken-bundle, imessage-bundle),"
echo "      wiki-recompile, assistant, and RemoteCapture launchd services"
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
launchctl bootout "gui/$(id -u)/com.ostler.ollama" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.ollama.plist" 2>/dev/null || true
brew uninstall --cask ollama-app 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.doctor" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.ical-server" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.ical-server.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.editor.frontpage" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.editor.frontpage.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.export-scan" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.fda-rerun" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.contact-resync" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.contact-resync.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.deferred-register-device" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.colima" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.colima.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.email-ingest" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.whatsapp-bundle" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-bundle.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.email-bundle" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-bundle.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.spoken-bundle" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.spoken-bundle.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.imessage-bundle" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.imessage-bundle.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.ostler.imessage-bridge" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.imessage-bridge.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.wiki-recompile" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.wiki-recompile-catchup" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile-catchup.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.dedupe-catchup" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.dedupe-catchup.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.whatsapp-keepalive" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler-remotecapture" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.ollama.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.ical-server.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.editor.frontpage.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.contact-resync.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-bundle.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-bundle.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.spoken-bundle.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.imessage-bundle.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.imessage-bridge.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile-catchup.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.dedupe-catchup.plist"
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
        fail_with_code "ERR-17-DOCTOR-MISSING" "$MSG_FAIL_DOCTOR_INSTALL_REQUIRED"
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
    # CX-32 (2026-05-24): mirror CX-31 -- capture pip install output to a
    # log and surface tail via warn() per-line on failure. Pre-CX-32 a
    # doctor-pip failure died invisible (same axis as CX-30 / CX-31).
    DOCTOR_PIP_LOG="/tmp/ostler-doctor-pip.log"
    set +e
    "${DOCTOR_DIR}/.venv/bin/pip" install --quiet -r "${DOCTOR_DIR}/requirements.txt" > "$DOCTOR_PIP_LOG" 2>&1
    DOCTOR_PIP_EXIT=$?
    set -e
    if [[ $DOCTOR_PIP_EXIT -ne 0 ]]; then
        warn "$(printf "$MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT" "$DOCTOR_PIP_EXIT")"
        warn "$MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES"
        while IFS= read -r line; do
            warn "    $line"
        done < <(tail -30 "$DOCTOR_PIP_LOG")
        fail_with_code "ERR-17-DOCTOR-PIP" "$MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED"
    fi
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
        <!-- CX-P0A (2026-05-26): forward the iOS /api/v1/* paths to
             the loopback-bound ical-server on 127.0.0.1:8090. Without
             this list Doctor 404s every iOS Companion call beyond
             /api/v1/auth/chat-token + /api/v1/wiki/correct. The two
             path-parameter routes use FastAPI {slug}/{id} syntax so the
             proxy's request.url.path forwarding substitutes them.
             #680 (2026-06-19): /api/v1/health/day is the read-back for
             the opt-in Apple Health path. The phone (and the assistant)
             POST health_daily_summary points to /api/v1/ingest/ios
             (already proxied) where the ical-server writes a per-day
             pwg:HealthObservation into the graph; the GET reads that
             day's physiology back joined to its life-context. Without
             this entry the Doctor 404s the read-back even once the
             CM041 health branch ships, so the write lands but nothing
             can query it across the auth boundary. -->
        <key>DOCTOR_PROXY_PATHS</key>
        <string>/api/safari/ingest,/api/v1/hub/health,/api/v1/timeline,/api/v1/people,/api/v1/people/search,/api/v1/people/context,/api/v1/people/stale,/api/v1/people/recent,/api/v1/people/birthdays,/api/v1/suggestions,/api/v1/calendar,/api/v1/calendar/today,/api/v1/conversation/process,/api/v1/conversation/status/{id},/api/v1/email/recent,/api/v1/ingest/ios,/api/v1/health/day,/api/v1/recording/active,/api/v1/coach/recent,/api/v1/people/{slug}/forget,/api/v1/hydration/status</string>
        <key>DOCTOR_GATEWAY_URL</key>
        <string>http://127.0.0.1:8090</string>
        <!-- #652 (THE FIX): point the Doctor's chat-token mint at the SAME
             port the daemon's [gateway] is pinned to (8000, see CX-59 at
             ~L5840). chat_token.py's _zeroclaw_port() defaults to zeroclaw's
             binary default 42617; the internal mint (_internal_gateway_url)
             then POSTs /api/pairing/initiate to 127.0.0.1:42617 where nothing
             listens -> Connection refused -> 503 -> chat 401 on EVERY fresh
             install. OSTLER_CHAT_GATEWAY_PORT is the only lever that retargets
             the internal mint (the _URL override only changes the public iOS
             URL). Setting 8000 also makes the iOS public chat_base_url use
             :8000, which is correct since the daemon is pinned there. Keep in
             lockstep with the `port = 8000` echo in the [gateway] config. -->
        <key>OSTLER_CHAT_GATEWAY_PORT</key>
        <string>8000</string>
        <!-- #652 (hardening, not the root cause): pin the admin-token path to
             the ABSOLUTE file install.sh seeded (~L5460) so read_admin_token()
             can never resolve a divergent Path.home()/.ostler under a different
             launchd HOME. Box-confirmed token-read works without this, but it
             removes a latent class of failure. -->
        <key>OSTLER_CHAT_ADMIN_TOKEN_FILE</key>
        <string>${OSTLER_DIR}/secrets/zeroclaw_admin_token</string>
    </dict>
</dict>
</plist>
DOCEOF

    # Use bootstrap on Sequoia+ (load is deprecated), fall back to load
    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "$MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089"
fi

# ── 3.13-editor  The Editor Front Page refresh agent ────────────
#
# Stages the vendored Editor sources, then registers the hourly Front
# Page emitter LaunchAgent (com.ostler.editor.frontpage). The agent
# re-runs `python -m compiler.emit_frontpage` from ${EDITOR_DIR} so
# ~/.ostler/editor/front_page.{json,html} stays fresh and the Hub
# Doctor's /frontpage route always serves a current feed.
#
# Two legs, both here:
#   1. SOURCE-STAGING: copy the vendored CM059 sources (bundled at
#      ${SCRIPT_DIR}/cm059_editor by gui/project.yml, mirroring the
#      cm048 pipeline) into ${EDITOR_DIR}. The emitter is stdlib-only
#      (urllib/csv/json/hashlib/...), so there is NO pip install -- the
#      bundled interpreter runs it directly. Without this leg the plist
#      below would point at an empty dir and the tick would thrash
#      ModuleNotFoundError every hour.
#   2. AGENT: sed-substitute the plist's two placeholders and load it,
#      mirroring the Doctor / ical-server agents.
#
# Gated on the vendored sources (or an already-staged editor dir) being
# present. A cut that predates the Editor bundles nothing, so the hook
# no-ops cleanly. Best-effort throughout: a copy/load failure warns but
# never fails the install.
EDITOR_DIR="${OSTLER_EDITOR_DIR:-${OSTLER_DIR}/editor}"

# Leg 1: stage the vendored Editor sources into ${EDITOR_DIR}. The
# bundle lands at ${SCRIPT_DIR}/cm059_editor (.app code path) or, on a
# dev checkout, at ${SCRIPT_DIR}/../vendor/cm059_editor. A legacy
# ${SCRIPT_DIR}/editor layout is also accepted for forward-compat.
EDITOR_SRC=""
for _ed_cand in "${SCRIPT_DIR}/cm059_editor" \
                "${SCRIPT_DIR}/../vendor/cm059_editor" \
                "${SCRIPT_DIR}/editor"; do
    if [[ -f "${_ed_cand}/compiler/emit_frontpage.py" ]]; then
        EDITOR_SRC="$_ed_cand"
        break
    fi
done
if [[ -n "$EDITOR_SRC" ]]; then
    info "$(printf "$MSG_INFO_EDITOR_FRONTPAGE_STAGING" "${EDITOR_DIR}")"
    mkdir -p "${EDITOR_DIR}"
    # Copy WITHOUT -p so source xattrs (com.apple.provenance / quarantine)
    # do not propagate. Refresh on re-install so a newer cut's emitter
    # replaces the staged copy.
    if cp -R "${EDITOR_SRC}/compiler" "${EDITOR_DIR}/" 2>/dev/null \
       && cp -R "${EDITOR_SRC}/deploy" "${EDITOR_DIR}/" 2>/dev/null; then
        /usr/bin/xattr -cr "${EDITOR_DIR}" 2>/dev/null || true
    else
        warn "$MSG_WARN_EDITOR_FRONTPAGE_STAGING_FAILED"
    fi
fi
unset EDITOR_SRC _ed_cand

# Leg 2: resolve the staged plist + register the agent.
EDITOR_FRONTPAGE_PLIST_SRC=""
if [[ -f "${EDITOR_DIR}/deploy/com.ostler.editor.frontpage.plist" ]]; then
    EDITOR_FRONTPAGE_PLIST_SRC="${EDITOR_DIR}/deploy/com.ostler.editor.frontpage.plist"
fi

if [[ -n "$EDITOR_FRONTPAGE_PLIST_SRC" && -f "${EDITOR_DIR}/compiler/emit_frontpage.py" ]]; then
    # The emitter is stdlib-only, so the bundled interpreter runs it
    # directly -- no venv. A pre-staged editor venv is still honoured if
    # a future cut ships one.
    EDITOR_PYTHON="$PYTHON3_BIN"
    if [[ -x "${EDITOR_DIR}/.venv/bin/python3" ]]; then
        EDITOR_PYTHON="${EDITOR_DIR}/.venv/bin/python3"
    fi

    mkdir -p "${HOME}/Library/LaunchAgents"
    EDITOR_FRONTPAGE_PLIST="${HOME}/Library/LaunchAgents/com.ostler.editor.frontpage.plist"
    # Escape & / \ for the sed replacement. __PYTHON__ and
    # __EDITOR_REPO__ are disjoint tokens (neither is a substring of the
    # other) so substitution order is not load-bearing.
    esc_editor_py="$(printf '%s' "$EDITOR_PYTHON" | sed 's/[&/\]/\\&/g')"
    esc_editor_repo="$(printf '%s' "$EDITOR_DIR" | sed 's/[&/\]/\\&/g')"
    sed \
        -e "s/__EDITOR_REPO__/$esc_editor_repo/g" \
        -e "s/__PYTHON__/$esc_editor_py/g" \
        "$EDITOR_FRONTPAGE_PLIST_SRC" > "$EDITOR_FRONTPAGE_PLIST"
    chmod 0644 "$EDITOR_FRONTPAGE_PLIST"

    launchctl bootout "gui/$(id -u)/com.ostler.editor.frontpage" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$EDITOR_FRONTPAGE_PLIST" 2>/dev/null \
       || launchctl load "$EDITOR_FRONTPAGE_PLIST" 2>/dev/null; then
        ok "$MSG_OK_EDITOR_FRONTPAGE_AGENT_INSTALLED"
    else
        warn "$MSG_WARN_EDITOR_FRONTPAGE_PLIST_LOAD_FAILED"
    fi
    unset esc_editor_py esc_editor_repo EDITOR_PYTHON EDITOR_FRONTPAGE_PLIST
fi
unset EDITOR_DIR EDITOR_FRONTPAGE_PLIST_SRC

# ── 3.13a Assistant API (ical-server.py) ────────────────────────
#
# CX-P0A (2026-05-26): without this block, 11 of 13 iOS Companion
# /api/v1/* endpoints 404 on every customer install since v0.1
# (Hub status, timeline, people, calendar, suggestions,
# conversation upload, GDPR Article 17 forget). Doctor on :8089
# proxies these paths to the loopback-bound assistant API on
# :8090 via DOCTOR_PROXY_PATHS (rendered into the Doctor plist
# above).
#
# The ical-server.py source lives at ${SCRIPT_DIR}/assistant_api/
# (the .app build's postBuildScript bundles vendor/cm041/assistant_api/
# into Contents/Resources/assistant_api/; the tarball build copies
# it via release.sh + ICAL_SERVER_SOURCES). When neither lands the
# source we follow the doctor / hub-power / email-ingest skip
# pattern: warn + carry on. The 11 iOS endpoints stay broken in
# that case, but install does not hard-fail (Andy may dev-test
# against a tarball that has not been re-cut since this PR).
#
# We bind 127.0.0.1:8090 (loopback only) on purpose:
#   - Doctor is the single auth boundary (CM019 PR 8 posture);
#     direct LAN exposure of :8090 would re-introduce a second
#     externally-reachable port.
#   - OSTLER_API_PORT=8090 + OSTLER_API_BIND=127.0.0.1 env vars are
#     consumed by vendor/cm041/assistant_api/ical-server.py's main
#     block (env-override added in the same PR as this install
#     phase; pre-fix PORT was hardcoded 8089).
#
# Reuse the OSTLER_VENV that already has ostler_security
# pip-installed (Phase 7). ical-server.py hard-fails at import
# without ostler_security, and standing up a second venv would
# duplicate the sqlcipher + cryptography deps for no gain.

progress "Setting up Assistant API (ical-server)" "ical_server_setup"

ICAL_SERVER_DIR="${OSTLER_DIR}/services/ical-server"

if [[ -d "${SCRIPT_DIR}/assistant_api" && -f "${SCRIPT_DIR}/assistant_api/ical-server.py" ]]; then
    info "$MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER"

    # Wipe + recopy so a re-install picks up the latest vendored
    # source rather than stacking on a stale tree.
    rm -rf "$ICAL_SERVER_DIR"
    mkdir -p "$ICAL_SERVER_DIR"
    cp -R "${SCRIPT_DIR}/assistant_api/." "$ICAL_SERVER_DIR/"

    # Verify ostler_security is importable under OSTLER_VENV (Phase 7
    # is the install site). Refuse to render the plist if not: an
    # ical-server that hard-fails on every launchd boot wastes log
    # space and confuses the diagnostic dashboard.
    if "$OSTLER_PYTHON" -c "from ostler_security.database import get_db_connection" 2>/dev/null; then
        mkdir -p "${HOME}/Library/LaunchAgents"
        ICAL_PLIST="${HOME}/Library/LaunchAgents/com.ostler.ical-server.plist"
        cat > "$ICAL_PLIST" <<ICALPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.ical-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_PYTHON}</string>
        <string>${ICAL_SERVER_DIR}/ical-server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ICAL_SERVER_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/ical-server.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/ical-server.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OSTLER_API_PORT</key>
        <string>8090</string>
        <key>OSTLER_API_BIND</key>
        <string>127.0.0.1</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>USER_ID</key>
        <string>${USER_ID}</string>
        <key>ICAL_SCRIPT</key>
        <string>${OSTLER_DIR}/ical/ical-query.sh</string>
        <key>INGEST_DIR</key>
        <string>${OSTLER_DIR}/ical/ingest</string>
        <key>SYNC_STATE_DIR</key>
        <string>${OSTLER_DIR}/ical/sync-state</string>
    </dict>
</dict>
</plist>
ICALPLISTEOF

        # Use bootstrap on Sequoia+ (load is deprecated). Do NOT
        # `bootout` first -- per CLAUDE.md a bootout on a customer
        # GUI session can kick them back to the login screen. The
        # bootstrap call is idempotent enough for the first-install
        # path; re-install relies on the uninstaller bootout below.
        launchctl bootstrap "gui/$(id -u)" "$ICAL_PLIST" 2>/dev/null || \
            launchctl load "$ICAL_PLIST" 2>/dev/null || \
            warn "$MSG_WARN_ICAL_SERVER_FAILED"
        ok "$MSG_OK_ICAL_SERVER_INSTALLED"
    else
        warn "$MSG_WARN_ICAL_SERVER_FAILED"
    fi
else
    info "$MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED"
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

progress "Setting up Knowledge service" "knowledge_setup"

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
        fail_with_code "ERR-20-EMAIL-INGEST-VENDOR" "$MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN"
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

# ── 3.14b-pre-venv  Email-ingest venv with ostler_fda installed ───
#
# The email-ingest LaunchAgent's first tick (RunAtLoad=true) imports
# ostler_fda.apple_mail_mbox. Prior to this change the tick used the
# system python3 (/Library/Developer/CommandLineTools/usr/bin/python3
# on first-install Macs without a `brew install python`), which does
# not have ostler_fda installed -- ModuleNotFoundError, exit 1, and
# the install step surfaced a hard failure at step 17/21.
#
# Fix: bundle ostler_fda as a pip-installable package (pyproject.toml
# alongside the .py sources in vendor/ostler_fda/) and install it
# into a dedicated venv under ${OSTLER_DIR}/services/email-ingest/.
# Mirrors the cm048 / knowledge / doctor venv patterns. The venv's
# python3 is rendered into the LaunchAgent plist via the snippet's
# placeholder substitution (OSTLER_PYTHON_PATH).

EMAIL_INGEST_VENV_DIR="${OSTLER_DIR}/services/email-ingest"
EMAIL_INGEST_VENV="${EMAIL_INGEST_VENV_DIR}/.venv"
EMAIL_INGEST_VENV_PYTHON="${EMAIL_INGEST_VENV}/bin/python3"
# Absolute path to CM021's pwg-email-ingest console script inside the
# venv. Set ONLY after the CM021 pip-install below succeeds, then passed
# to the snippet so the LaunchAgent plist's PWG_EMAIL_INGEST env resolves
# the binary under launchd's minimal PATH. Empty until proven installed,
# so we never render a path to a binary that is not there (the tick's
# LOUD guard then fails loudly rather than dropping harvested mail).
EMAIL_INGEST_VENV_BIN=""
OSTLER_FDA_SRC=""

if [[ -d "${SCRIPT_DIR}/ostler_fda" && -f "${SCRIPT_DIR}/ostler_fda/pyproject.toml" ]]; then
    OSTLER_FDA_SRC="${SCRIPT_DIR}/ostler_fda"
elif [[ -d "${SCRIPT_DIR}/../vendor/ostler_fda" && -f "${SCRIPT_DIR}/../vendor/ostler_fda/pyproject.toml" ]]; then
    # Dev path: install.sh run from gui/scripts/ checkout
    OSTLER_FDA_SRC="${SCRIPT_DIR}/../vendor/ostler_fda"
fi

if [[ -n "$OSTLER_FDA_SRC" ]]; then
    info "$(printf "$MSG_INFO_CREATING_PYTHON_VENV" "$EMAIL_INGEST_VENV")"
    mkdir -p "$EMAIL_INGEST_VENV_DIR"
    "$PYTHON3_BIN" -m venv "$EMAIL_INGEST_VENV"

    info "$MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV"
    "$EMAIL_INGEST_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    if "$EMAIL_INGEST_VENV/bin/pip" install --quiet "$OSTLER_FDA_SRC" 2>/tmp/ostler-fda-pip.log; then
        ok "$MSG_OK_OSTLER_FDA_INSTALLED_VENV"
    else
        warn "$MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL"
        if [[ -s /tmp/ostler-fda-pip.log ]]; then
            sed -e 's/^/    /' /tmp/ostler-fda-pip.log | tail -5
        fi
        EMAIL_INGEST_VENV_PYTHON=""
    fi

    # CX-83: also install CM021 (pwg-email-intelligence) into the
    # same venv. CM021 provides the `pwg-email-ingest` console
    # script that vendor/email_ingest/bin/email-ingest-tick.sh has
    # been calling since shipping. Until this lift, that command
    # was a phantom: tick.sh ran `command -v pwg-email-ingest`,
    # found nothing, exited 127 every hourly tick. So the hourly
    # mail ingestion has never run on a customer install.
    #
    # Source path mirrors OSTLER_FDA_SRC: productised path is
    # ${SCRIPT_DIR}/cm021 (staged by gui/project.yml postBuildScript),
    # dev path is ${SCRIPT_DIR}/../vendor/cm021.
    #
    # Failure here is non-fatal: the email-ingest venv keeps the
    # ostler_fda emitter, so the customer's mbox files still land
    # under ~/.ostler/imports/email/ on each hourly tick. They just
    # don't get ingested into Oxigraph. Doctor's backfill-progress
    # diagnostic surfaces this.
    if [[ -n "$EMAIL_INGEST_VENV_PYTHON" ]]; then
        CM021_SRC=""
        if [[ -d "${SCRIPT_DIR}/cm021" && -f "${SCRIPT_DIR}/cm021/pyproject.toml" ]]; then
            CM021_SRC="${SCRIPT_DIR}/cm021"
        elif [[ -d "${SCRIPT_DIR}/../vendor/cm021" && -f "${SCRIPT_DIR}/../vendor/cm021/pyproject.toml" ]]; then
            CM021_SRC="${SCRIPT_DIR}/../vendor/cm021"
        fi

        if [[ -n "$CM021_SRC" ]]; then
            if "$EMAIL_INGEST_VENV/bin/pip" install --quiet "$CM021_SRC" 2>/tmp/ostler-cm021-pip.log; then
                ok "$MSG_OK_PWG_EMAIL_INGEST_INSTALLED"
                # CM021's [project.scripts] entry point lands the console
                # script here. Record the absolute path so the snippet can
                # render it into the LaunchAgent plist's PWG_EMAIL_INGEST
                # env var (the launchd-PATH-independence fix). Only set on
                # success so a failed install leaves it empty.
                if [[ -x "$EMAIL_INGEST_VENV/bin/pwg-email-ingest" ]]; then
                    EMAIL_INGEST_VENV_BIN="$EMAIL_INGEST_VENV/bin/pwg-email-ingest"
                fi
            else
                warn "$MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST"
                if [[ -s /tmp/ostler-cm021-pip.log ]]; then
                    sed -e 's/^/    /' /tmp/ostler-cm021-pip.log | tail -5
                fi
                # Don't unset EMAIL_INGEST_VENV_PYTHON -- the
                # LaunchAgent still gets the ostler_fda emitter,
                # just no ingest leg.
            fi
        else
            warn "$MSG_WARN_CM021_SOURCE_NOT_FOUND"
        fi
        unset CM021_SRC
    fi
else
    warn "$MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST"
    EMAIL_INGEST_VENV_PYTHON=""
fi

if [[ -n "$EMAIL_INGEST_SNIPPET" && -f "$EMAIL_INGEST_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$EMAIL_INGEST_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       OSTLER_VENV_PYTHON="$EMAIL_INGEST_VENV_PYTHON" \
       OSTLER_EMAIL_INGEST_BIN="$EMAIL_INGEST_VENV_BIN" \
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

# ── 3.14c  Conversation-memory body feeds (4-artefact, shared installer) ──
#
# The CONVERSATION-MEMORY feature (v1.0.0 GATE): for each wired human
# channel, read its local store WITH message bodies, render a cleaned
# transcript + CM048 metadata, and hand each conversation to pwg-convo,
# which emits the four artefacts under
# ${USER_FACING_ROOT}/Conversations/<date>/<slug>-<id>/.
#
# All four feeds (WhatsApp / iMessage / email / meeting-voice) share the
# same read->render->pwg-convo shape; only the package, module-staging,
# venv deps, labels and strings differ. _install_conversation_feed is the
# single shared installer so there are not five hand-maintained copies to
# drift. Each feed is one gated call below.
#
# SEPARATE from the hydrate_* sub-phases (people-graph FACTS, metadata
# only, shared email-ingest venv). The body feeds read BODIES, each has
# its OWN dedicated venv, distinct label/wrapper/state/output, so they
# never collide. Reads are local-file-only; nothing leaves the Mac.
#
# Warn-not-abort throughout: a per-feed failure must never abort the
# install. The CM048 pwg-convo setup above already hard-guarantees the
# pipeline exists (ERR-15).
#
# _install_conversation_feed <feed_key> <stage_subpath> <venv_deps>
#   feed_key      whatsapp|imessage|email|spoken. Derives the service dir
#                 (${OSTLER_DIR}/services/<feed_key>-source), the bundle
#                 label/wrapper/plist (com.creativemachines.ostler.<feed_key>-bundle),
#                 the progress step id (<feed_key>_bundle) and the MSG_*
#                 keys (MSG_{PROGRESS,OK,INFO,WARN}_<UC>_*).
#   stage_subpath relative path under the service dir to stage the package
#                 into. Top-level feeds pass "<feed_key>_source"; iMessage
#                 passes "services/imessage_source" (its module is
#                 services.imessage_source.pipeline).
#   venv_deps     space-separated pip deps. The literal "ostler_fda" is
#                 resolved to the bundled OSTLER_FDA_SRC; every other token
#                 is a plain pip name (e.g. "pyyaml"). Per-feed: WhatsApp /
#                 email need ostler_fda; iMessage / spoken do not.
# The caller owns the gate (channel+consent for WhatsApp; source-present
# for the others), so this function is gate-agnostic.
_install_conversation_feed() {
    local feed_key="$1" stage_subpath="$2" venv_deps="$3"
    local uc; uc="$(printf '%s' "$feed_key" | tr '[:lower:]' '[:upper:]')"
    local pkg_dir="${stage_subpath##*/}"
    local label="com.creativemachines.ostler.${feed_key}-bundle"
    local wrapper="${feed_key}-bundle-tick.sh"
    local plist="${label}.plist"
    local base="${OSTLER_DIR}/services/${feed_key}-source"
    local venv="${base}/.venv"
    local venv_python="${venv}/bin/python3"

    # The caller emits the `progress "..." "<feed_key>_bundle"` step marker
    # with a LITERAL id (so the install<->GUI contract extractor, a static
    # parser, sees it and matches StepCatalog.canonicalOrder). This shared
    # core does everything after the marker. MSG_* keys are derived from
    # the uppercased feed_key (defined per feed in install.sh.strings.*.sh;
    # no inline English here, Rule 0.9).
    local k_ok_src="MSG_OK_${uc}_SOURCE_INSTALLED"
    local k_warn_src="MSG_WARN_${uc}_SOURCE_FAILED"
    local k_warn_fda="MSG_WARN_${uc}_SOURCE_SRC_NOT_FOUND"
    local k_ok_loaded="MSG_OK_${uc}_BUNDLE_LOADED"
    local k_info_tick="MSG_INFO_${uc}_BUNDLE_TICK"
    local k_info_logs="MSG_INFO_${uc}_BUNDLE_LOGS"
    local k_warn_failed="MSG_WARN_${uc}_BUNDLE_FAILED"
    local k_warn_vendor="MSG_WARN_${uc}_BUNDLE_VENDOR_MISSING"

    # 1. Resolve the vendored package (bundled in the .app, or the dev
    #    checkout's vendor/ tree). No clone fallback: the body feeds ship
    #    inside the .app; a raw dev install without the vendor warns and
    #    skips (gated feature, never fatal). Keyed on the wrapper.
    local src=""
    if [[ -f "${SCRIPT_DIR}/${pkg_dir}/bin/${wrapper}" ]]; then
        src="${SCRIPT_DIR}/${pkg_dir}"
    elif [[ -f "${SCRIPT_DIR}/../vendor/${pkg_dir}/bin/${wrapper}" ]]; then
        src="${SCRIPT_DIR}/../vendor/${pkg_dir}"
    fi
    if [[ -z "$src" ]]; then
        warn "${!k_warn_vendor}"
        return 0
    fi

    # 2. Stage the package under the service dir at stage_subpath so the
    #    wrapper's SOURCE_DIR (the service dir) is stable and the module
    #    resolves (top-level for most; services/ namespace for iMessage).
    local pkg_dest="${base}/${stage_subpath}"
    rm -rf "${base:?}/${stage_subpath%%/*}"
    mkdir -p "$pkg_dest"
    cp -R "${src}/." "$pkg_dest/"

    # 3. Dedicated venv with the feed's deps. Decoupled from the
    #    email-ingest venv so a single-channel install still works. The
    #    "ostler_fda" token resolves to the bundled source; others are
    #    plain pip names. Feeds with no ostler_fda dep carry their own
    #    reader and only need pyyaml (optional contacts/label map).
    local fda_src=""
    if [[ -d "${SCRIPT_DIR}/ostler_fda" && -f "${SCRIPT_DIR}/ostler_fda/pyproject.toml" ]]; then
        fda_src="${SCRIPT_DIR}/ostler_fda"
    elif [[ -d "${SCRIPT_DIR}/../vendor/ostler_fda" && -f "${SCRIPT_DIR}/../vendor/ostler_fda/pyproject.toml" ]]; then
        fda_src="${SCRIPT_DIR}/../vendor/ostler_fda"
    fi
    local pip_args=() dep needs_fda=0
    for dep in $venv_deps; do
        if [[ "$dep" == "ostler_fda" ]]; then
            needs_fda=1
            if [[ -n "$fda_src" ]]; then
                pip_args+=("$fda_src")
            fi
        else
            pip_args+=("$dep")
        fi
    done
    if [[ "$needs_fda" -eq 1 && -z "$fda_src" ]]; then
        warn "${!k_warn_fda}"
        venv_python=""
    elif [[ "${#pip_args[@]}" -gt 0 ]]; then
        info "$(printf "$MSG_INFO_CREATING_PYTHON_VENV" "$venv")"
        mkdir -p "$base"
        "$PYTHON3_BIN" -m venv "$venv"
        "$venv/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
        local pip_log="/tmp/ostler-${feed_key}-source-pip.log"
        if "$venv/bin/pip" install --quiet "${pip_args[@]}" 2>"$pip_log"; then
            ok "${!k_ok_src}"
        else
            warn "${!k_warn_src}"
            if [[ -s "$pip_log" ]]; then
                sed -e 's/^/    /' "$pip_log" | tail -5
            fi
            venv_python=""
        fi
    fi

    # 4. PWG_CONVO_CMD: the CM048 venv pwg-convo binary (absolute, no PATH
    #    dependency under launchd). The pipeline appends
    #    "process <transcript> <metadata>" itself, so this is the bare
    #    invocation. Falls back to the /usr/local/bin symlink, then PATH.
    local pwg="${CM048_VENV}/bin/pwg-convo"
    if [[ ! -x "$pwg" ]]; then
        if [[ -x "/usr/local/bin/pwg-convo" ]]; then
            pwg="/usr/local/bin/pwg-convo"
        else
            pwg="pwg-convo"
        fi
    fi

    # 5. Copy the wrapper (sed its SOURCE_DIR placeholder) and render the
    #    plist (7 placeholders). The wrapper ships otherwise verbatim; the
    #    plist EnvironmentVariables carry python / pwg-convo / source-dir /
    #    user-name so the agent never falls through to a bare PATH python.
    local bin_dir="${OSTLER_DIR}/bin"
    mkdir -p "$bin_dir" "$LOGS_DIR" "${OSTLER_DIR}/workspace"
    local esc_base; esc_base="$(printf '%s' "$base" | sed 's/[&/\]/\\&/g')"
    sed "s/OSTLER_SOURCE_DIR_PLACEHOLDER/$esc_base/g" \
        "${pkg_dest}/bin/${wrapper}" > "${bin_dir}/${wrapper}"
    chmod 0755 "${bin_dir}/${wrapper}"

    local la="${HOME}/Library/LaunchAgents"
    mkdir -p "$la"
    local rendered="${la}/${plist}"
    local py_val="${venv_python:-python3}"
    local e_bin e_home e_logs e_py e_pwg e_user e_user_id
    e_bin="$(printf '%s' "$bin_dir" | sed 's/[&/\]/\\&/g')"
    e_home="$(printf '%s' "$HOME" | sed 's/[&/\]/\\&/g')"
    e_logs="$(printf '%s' "$LOGS_DIR" | sed 's/[&/\]/\\&/g')"
    e_py="$(printf '%s' "$py_val" | sed 's/[&/\]/\\&/g')"
    e_pwg="$(printf '%s' "$pwg" | sed 's/[&/\]/\\&/g')"
    e_user="$(printf '%s' "${USER_NAME:-You}" | sed 's/[&/\]/\\&/g')"
    # OSTLER_USER_ID scopes pwg-convo. USER_ID is :?-guaranteed non-empty
    # well before this phase, so the bundle agent never renders a blank
    # user_id (which would make CM048's fail-loud guard kill every tick).
    e_user_id="$(printf '%s' "${USER_ID:-}" | sed 's/[&/\]/\\&/g')"
    # _VALUE/_PATH-suffixed placeholders before bare ones, so a bare token
    # is never a substring of a longer placeholder (byte-safe render).
    sed \
        -e "s/OSTLER_PYTHON_PATH/$e_py/g" \
        -e "s/PWG_CONVO_CMD_VALUE/$e_pwg/g" \
        -e "s/OSTLER_SOURCE_DIR_VALUE/$esc_base/g" \
        -e "s/OSTLER_USER_DISPLAY_NAME_VALUE/$e_user/g" \
        -e "s/OSTLER_USER_ID_VALUE/$e_user_id/g" \
        -e "s/OSTLER_BIN/$e_bin/g" \
        -e "s/OSTLER_HOME/$e_home/g" \
        -e "s/OSTLER_LOGS/$e_logs/g" \
        "${pkg_dest}/launchd/${plist}" > "$rendered"
    chmod 0644 "$rendered"

    # 6. Load via launchctl bootstrap (bootout first; not idempotent alone).
    local domain="gui/$(id -u)"
    launchctl bootout "${domain}/${label}" 2>/dev/null || true
    if launchctl bootstrap "$domain" "$rendered"; then
        ok "${!k_ok_loaded}"
        info "${!k_info_tick}"
        info "$(printf "${!k_info_logs}" "$LOGS_DIR")"
    else
        warn "${!k_warn_failed}"
    fi
}

# WhatsApp body feed -- the gating floor. Rides the SAME consent the
# hydrate sub-phase rides (reading bodies is strictly more sensitive than
# the metadata the hydrate reads, so never a weaker gate). Needs ostler_fda
# (its reader reuses ostler_fda.whatsapp_history) plus pyyaml (contacts).
if [[ "$CHANNEL_WHATSAPP_ENABLED" == true && "$CHANNEL_WHATSAPP_CONSENT_ACCEPTED" == true ]]; then
    progress "$MSG_PROGRESS_WHATSAPP_BUNDLE" "whatsapp_bundle"
    _install_conversation_feed whatsapp whatsapp_source "ostler_fda pyyaml"
fi

# Email body feed. Reads OTHER PEOPLE'S message content (Apple Mail's
# local store), so it is gated on the third-party-data consent (Q14),
# never source-presence alone -- reading others' bodies is predicated on
# that acknowledgement (declined wipes ~/.ostler/imports). Needs
# ostler_fda (reader reuses ostler_fda.apple_mail_mbox) + pyyaml.
if [[ -d "${HOME}/Library/Mail" && "$OSTLER_CONSENT_THIRD_PARTY_DECISION" == "accepted" ]]; then
    progress "$MSG_PROGRESS_EMAIL_BUNDLE" "email_bundle"
    _install_conversation_feed email email_source "ostler_fda pyyaml"
fi

# Meeting / voice body feed. These are the customer's OWN CM042
# recordings, consented at capture time (CM042 consent_log), so the gate
# is source-presence (the Transcripts dir), NOT the third-party ack --
# over-gating own-recordings would be wrong. Self-contained reader
# (no ostler_fda); pyyaml for the optional contacts/label map.
if [[ -d "${USER_FACING_ROOT}/Transcripts" ]]; then
    progress "$MSG_PROGRESS_SPOKEN_BUNDLE" "spoken_bundle"
    _install_conversation_feed spoken spoken_source "pyyaml"
fi

# iMessage body feed. Reads OTHER PEOPLE'S message content
# (~/Library/Messages/chat.db), same sensitivity as WhatsApp/email
# bodies, so it rides the third-party-data consent, never source-presence
# alone. Self-contained chat.db reader (no ostler_fda); pyyaml for the
# optional contacts/label map. Module is services.imessage_source.pipeline,
# so the package stages under services/ (stage_subpath services/imessage_source).
if [[ -f "${HOME}/Library/Messages/chat.db" && "$OSTLER_CONSENT_THIRD_PARTY_DECISION" == "accepted" ]]; then
    progress "$MSG_PROGRESS_IMESSAGE_BUNDLE" "imessage_bundle"
    _install_conversation_feed imessage services/imessage_source "pyyaml"
fi

# ── 3.14d Install-time DATA STEP (citations / Knowledge / conversations) ──
#
# The render-without-data fix (HR015 BUGS-023/024/028). The renderers for
# three flagship wiki features ship and run, but on a fresh box the DATA
# they read is empty because the install only SET UP the producers (the
# CM024 CLI, the CM048 pipeline, the conversation-feed launchd ticks) and
# never RAN them. So:
#   - Citations    read pwg048 Facts (urn:pwg:Fact triples in Oxigraph),
#   - Knowledge    reads the `evernote_knowledge` Qdrant collection,
#   - Conversations / Open Commitments read the `conversations` collection,
# all shipped at zero until a background tick eventually fired (hours, or
# never if the feed kept yielding the shared Ollama slot).
#
# This phase runs ONE synchronous producer pass at install time for the
# sources that are already on the Mac, then asserts the resulting count.
# It is SOURCE-CONDITIONAL: a producer is only run when its source export
# is present, and a zero count is only a hard failure when the source WAS
# present (the genuine bug) -- never when the machine simply has no export
# (the EMPTY-SOURCE case, which logs and continues).
#
# STRICT vs lenient: OSTLER_STRICT_DATA_STEP (default 1) makes a
# present-source-but-zero-output a hard fail so the box-walk gate catches a
# dead producer. Set OSTLER_STRICT_DATA_STEP=0 to downgrade to a warning
# (parity with --allow-plaintext: a developer escape hatch, not the
# customer default). Either way the rest of the install is never blocked by
# the absence of source data.
#
# Skipped entirely on --allow-plaintext (the same CI/dev escape hatch the
# CM048 setup honours) and when graph services are not up.
_STRICT_DATA_STEP="${OSTLER_STRICT_DATA_STEP:-1}"
_DATA_STEP_QDRANT="${QDRANT_URL:-http://localhost:6333}"
_DATA_STEP_OXIGRAPH="${OXIGRAPH_URL:-http://localhost:7878}"

# Counts-only Qdrant points reader. Echoes an integer (0 on any error) so
# the caller never has to parse JSON inline. No item content is read.
_data_step_qdrant_count() {
    local _coll="$1"
    curl -sf -m 8 "${_DATA_STEP_QDRANT}/collections/${_coll}" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(((d.get("result") or {}).get("points_count")) or 0))
except Exception:
    print(0)' 2>/dev/null || echo 0
}

# Counts-only SPARQL COUNT reader for pwg048 Facts (urn:pwg:Fact). Echoes
# an integer (0 on any error). No fact content is read.
_data_step_fact_count() {
    curl -sf -m 8 -G "${_DATA_STEP_OXIGRAPH}/query" \
        --data-urlencode 'query=SELECT (COUNT(?f) AS ?c) WHERE { ?f a <urn:pwg:Fact> }' \
        -H 'Accept: application/sparql-results+json' 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    b=(d.get("results") or {}).get("bindings") or []
    print(int(b[0]["c"]["value"]) if b else 0)
except Exception:
    print(0)' 2>/dev/null || echo 0
}

# present-source-but-zero -> hard fail (strict) or loud warn (lenient).
# True when strict mode is on (so the caller must hard-fail); false when the
# operator opted out, so the caller warns instead. The ERR code stays a
# LITERAL at each callsite (the test_every_fail_call_has_error_code guard
# rejects a variable code), so this helper only decides strict-vs-lenient,
# it never calls fail_with_code itself.
_data_step_strict() {
    [[ "$_STRICT_DATA_STEP" == "1" && "$ALLOW_PLAINTEXT" != "1" ]]
}

if [[ "$ALLOW_PLAINTEXT" == "1" ]]; then
    info "$MSG_INFO_DATA_STEP_INTRO"
elif ! curl -sf -m 5 "${_DATA_STEP_QDRANT}/collections" >/dev/null 2>&1; then
    # Graph services are not reachable (an earlier phase already warned).
    # The producers cannot write anywhere, so skip rather than fail.
    info "$MSG_INFO_DATA_STEP_INTRO"
else
    progress "$MSG_PROGRESS_DATA_STEP" "data_step"
    info "$MSG_INFO_DATA_STEP_INTRO"

    # ── 3.14d.1 Knowledge (CM024 Evernote convert -> embed) ─────────
    # Source: any .enex export already on the Mac. We look in the same
    # places the GDPR export detector uses (the confirmed EXPORTS_DIR and
    # the customer's Downloads / Desktop), BOUNDED to .enex files so we
    # never rglob unbounded trees (the CX-126 lesson). EMPTY-SOURCE (no
    # .enex) logs and continues; a present export that yields zero embedded
    # notes is the bug we hard-fail on.
    _KN_VENV_PY="${KNOWLEDGE_VENV}/bin/python3"
    _KN_STAGE="${KNOWLEDGE_STAGING_DIR:-${OSTLER_DIR}/data/knowledge-staging}"
    _KN_VAULT="${_KN_STAGE}/vault"
    _KN_DB="${_KN_STAGE}/metadata.db"
    _KN_ENEX=()
    if [[ -x "$_KN_VENV_PY" ]]; then
        # Bounded search roots: the confirmed export dir first, then the two
        # usual drop folders at depth 2 only (a Mac's Downloads can be huge).
        _kn_roots=()
        [[ -n "${EXPORTS_DIR:-}" && -d "${EXPORTS_DIR}" ]] && _kn_roots+=("$EXPORTS_DIR")
        [[ -d "${HOME}/Downloads" ]] && _kn_roots+=("${HOME}/Downloads")
        [[ -d "${HOME}/Desktop" ]] && _kn_roots+=("${HOME}/Desktop")
        for _kn_root in "${_kn_roots[@]}"; do
            while IFS= read -r _kn_f; do
                [[ -n "$_kn_f" ]] && _KN_ENEX+=("$_kn_f")
            done < <(find "$_kn_root" -maxdepth 2 -type f -iname '*.enex' 2>/dev/null)
        done
    fi

    if [[ "${#_KN_ENEX[@]}" -eq 0 ]]; then
        info "$MSG_INFO_DATA_STEP_KNOWLEDGE_NO_EXPORT"
    elif [[ ! -x "$_KN_VENV_PY" ]]; then
        # Producer never installed (warned in 3.13b); nothing to run.
        warn "$MSG_WARN_DATA_STEP_KNOWLEDGE_CONVERT_FAILED"
    else
        info "$(printf "$MSG_INFO_DATA_STEP_KNOWLEDGE_CONVERTING" "${#_KN_ENEX[@]}")"
        mkdir -p "$_KN_VAULT"
        _KN_CONVERT_LOG=/tmp/ostler-data-step-knowledge-convert.log
        _KN_EMBED_LOG=/tmp/ostler-data-step-knowledge-embed.log
        # convert: classify privacy so the embed step can cap L3 out of the
        # searchable collection (--max-compartment-level 2 below). LLM
        # classification is left OFF here to keep the install-time pass off
        # the shared Ollama slot for the heavier per-note calls; the
        # embedder still uses nomic-embed-text, which is cheap.
        if ( cd "$KNOWLEDGE_DIR" && "$_KN_VENV_PY" -m src.cli convert \
                "${_KN_ENEX[@]}" -o "$_KN_VAULT" --classify --overwrite \
                ) >"$_KN_CONVERT_LOG" 2>&1; then
            if ( cd "$KNOWLEDGE_DIR" && \
                    OSTLER_QDRANT_URL="$_DATA_STEP_QDRANT" \
                    OSTLER_OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}" \
                    "$_KN_VENV_PY" -m src.cli embed "$_KN_VAULT" \
                        --db-path "$_KN_DB" \
                        --collection evernote_knowledge \
                        --embedding-model "${EMBED_MODEL:-nomic-embed-text}" \
                        --max-compartment-level 2 \
                    ) >"$_KN_EMBED_LOG" 2>&1; then
                _KN_POINTS="$(_data_step_qdrant_count evernote_knowledge)"
                _KN_POINTS="${_KN_POINTS:-0}"
                if [[ "$_KN_POINTS" -gt 0 ]]; then
                    ok "$(printf "$MSG_OK_DATA_STEP_KNOWLEDGE_DONE" "$_KN_POINTS")"
                else
                    [[ -s "$_KN_EMBED_LOG" ]] && sed -e 's/^/    /' "$_KN_EMBED_LOG" | tail -5
                    if _data_step_strict; then
                        fail_with_code "ERR-30-DATA-STEP-KNOWLEDGE" "$MSG_FAIL_DATA_STEP_KNOWLEDGE_ZERO"
                    else
                        warn "$MSG_WARN_DATA_STEP_KNOWLEDGE_ZERO_NONSTRICT"
                    fi
                fi
            else
                warn "$MSG_WARN_DATA_STEP_KNOWLEDGE_EMBED_FAILED"
                [[ -s "$_KN_EMBED_LOG" ]] && sed -e 's/^/    /' "$_KN_EMBED_LOG" | tail -5
            fi
        else
            warn "$MSG_WARN_DATA_STEP_KNOWLEDGE_CONVERT_FAILED"
            [[ -s "$_KN_CONVERT_LOG" ]] && sed -e 's/^/    /' "$_KN_CONVERT_LOG" | tail -5
        fi
    fi

    # ── 3.14d.2 Conversations + citations (iMessage LIGHT first pass) ──
    # BUG-037: this used to run the FULL per-conversation enrichment
    # synchronously (~6 qwen calls per conversation over ~250 conversations)
    # = hours of blocking grind with a static bar, indistinguishable from a
    # crash. Andy-agreed fix: do a small, BOUNDED first pass here so the
    # installer reaches Pair-QR in seconds AND the Conversations/citations
    # pages are not dark on day one, then HAND the rest of the backlog to
    # the iMessage body-feed LaunchAgent (already installed above) to drain
    # over hours. The wiki "still settling in" panel reads the per-channel
    # hydration_progress.json the feed emits and shows real, climbing
    # progress with a falling ETA (BUG-039).
    #
    # The light pass is capped at OSTLER_DATA_STEP_MAX_CONVOS sessions (a
    # handful) so it finishes in seconds; the feed's watermark means the
    # later unbounded ticks never re-dispatch the same sessions. We run the
    # EXACT module the tick wrapper runs, with the same env, synchronously
    # and OUTSIDE the feed's single-flight lock (no other feed runs during
    # the installer, so there is no slot to contend for).
    _CONV_IMSG_BASE="${OSTLER_DIR}/services/imessage-source"
    _CONV_IMSG_PY="${_CONV_IMSG_BASE}/.venv/bin/python3"
    _CONV_PWG="${CM048_VENV}/bin/pwg-convo"
    [[ -x "$_CONV_PWG" ]] || _CONV_PWG="/usr/local/bin/pwg-convo"
    # How many conversations the synchronous light pass drains. Small so the
    # installer never grinds; the LaunchAgent finishes the rest. Operator
    # override for a deeper first pass on a fast box.
    _CONV_MAX="${OSTLER_DATA_STEP_MAX_CONVOS:-8}"
    if [[ ! -f "${HOME}/Library/Messages/chat.db" \
          || "$OSTLER_CONSENT_THIRD_PARTY_DECISION" != "accepted" ]]; then
        info "$MSG_INFO_DATA_STEP_CONV_NO_SOURCE"
    elif [[ ! -x "$_CONV_IMSG_PY" || ! -x "$_CONV_PWG" ]]; then
        # The feed or the CM048 pipeline did not install; both warned above.
        warn "$MSG_WARN_DATA_STEP_CONV_FAILED"
    else
        info "$MSG_INFO_DATA_STEP_CONV_RUNNING"
        _CONV_LOG=/tmp/ostler-data-step-conversations.log
        # --since-days 30 matches the feed's fresh-install clamp;
        # --max-sessions caps the light pass so it is fast. --no-progress is
        # NOT passed: the pass seeds hydration_progress.json with the real
        # iMessage backlog (queued) and the few it drains (done), so the
        # settling panel has a true denominator from the first paint.
        #
        # Backgrounded with a per-conversation liveness heartbeat (mirrors
        # the dedupe heartbeat) so the install bar/log never look frozen,
        # plus a hard per-pass timeout so a stuck qwen call can never hang
        # the installer. The watermark makes a timed-out pass safe to resume.
        _CONV_TIMEOUT="${OSTLER_DATA_STEP_CONV_TIMEOUT:-180}"
        ( cd "$_CONV_IMSG_BASE" \
            && PWG_CONVO_CMD="$_CONV_PWG" \
               OSTLER_USER_DISPLAY_NAME="${USER_NAME:-You}" \
               OSTLER_USER_ID="${USER_ID:-}" \
               OSTLER_INGEST_OFFPEAK_ONLY=0 \
               "$_CONV_IMSG_PY" -m services.imessage_source.pipeline \
                   --user-name "${USER_NAME:-You}" --since-days 30 \
                   --max-sessions "$_CONV_MAX" \
        ) >"$_CONV_LOG" 2>&1 &
        _CONV_PID=$!
        # Heartbeat: chirp every 5s while the light pass runs, and abort it
        # if it overruns the timeout (the LaunchAgent will resume the rest).
        _CONV_WAITED=0
        while kill -0 "$_CONV_PID" 2>/dev/null; do
            sleep 5
            _CONV_WAITED=$((_CONV_WAITED + 5))
            if [[ "$_CONV_WAITED" -ge "$_CONV_TIMEOUT" ]]; then
                # Kill the whole subtree, not just the ( ) subshell: the
                # actual "python3 -m ...pipeline" (where a stuck qwen call
                # would hang) is a GRANDCHILD, so killing only $_CONV_PID
                # would orphan it and it would keep draining. Reap the
                # subshell's descendants first (the python), then the
                # subshell itself, so the timeout claim holds. macOS has no
                # setsid, so use pkill -P to walk the child tree.
                pkill -P "$_CONV_PID" 2>/dev/null || true
                kill "$_CONV_PID" 2>/dev/null || true
                # Belt-and-braces: a second sweep catches any python that
                # was re-parented in the brief race between the two kills.
                pkill -P "$_CONV_PID" 2>/dev/null || true
                warn "$MSG_WARN_DATA_STEP_CONV_TIMEOUT"
                break
            fi
            info "$MSG_INFO_DATA_STEP_CONV_HEARTBEAT"
            gui_emit PCT "step=data_step" "pct=62"
        done
        if wait "$_CONV_PID"; then
            _CONV_POINTS="$(_data_step_qdrant_count conversations)"
            _CONV_POINTS="${_CONV_POINTS:-0}"
            _CONV_FACTS="$(_data_step_fact_count)"
            _CONV_FACTS="${_CONV_FACTS:-0}"
            if [[ "$_CONV_POINTS" -gt 0 || "$_CONV_FACTS" -gt 0 ]]; then
                ok "$(printf "$MSG_OK_DATA_STEP_CONV_DONE" "$_CONV_POINTS" "$_CONV_FACTS")"
                info "$MSG_INFO_DATA_STEP_CONV_BACKGROUND"
            else
                [[ -s "$_CONV_LOG" ]] && sed -e 's/^/    /' "$_CONV_LOG" | tail -5
                if _data_step_strict; then
                    fail_with_code "ERR-31-DATA-STEP-CONVERSATIONS" "$MSG_FAIL_DATA_STEP_CONV_ZERO"
                else
                    warn "$MSG_WARN_DATA_STEP_CONV_ZERO_NONSTRICT"
                fi
            fi
        else
            # A non-zero exit (including the heartbeat's timeout-kill) is not
            # fatal: the feed LaunchAgent drains the backlog post-install, and
            # the settling panel surfaces the in-progress state. Warn + log.
            warn "$MSG_WARN_DATA_STEP_CONV_FAILED"
            [[ -s "$_CONV_LOG" ]] && sed -e 's/^/    /' "$_CONV_LOG" | tail -5
        fi
    fi

    # ── 3.14d.3 Seed the "ready now" channels for the settling panel ──
    # BUG-039: the wiki settling panel reads hydration_progress.json (the
    # same file the conversation feed writes its iMessage slice into). The
    # fast install-time hydrate has ALREADY populated contacts + calendar by
    # this point, so seed those channels as "ready now" and reflect whether
    # an Evernote export was present for the notes channel. Best-effort: a
    # failure here never blocks the install. The conversation feeds own
    # their own channel keys, so this seed never clobbers them.
    _PROGRESS_FILE="${OSTLER_DIR}/state/hydration_progress.json"
    _CONTACTS_N="$(_data_step_qdrant_count people)"; _CONTACTS_N="${_CONTACTS_N:-0}"
    _NOTES_N="$(_data_step_qdrant_count evernote_knowledge)"; _NOTES_N="${_NOTES_N:-0}"
    # calendar count: meetings live in Oxigraph; a coarse "ready" marker is
    # enough for the panel (it shows state, not a precise meeting tally).
    OSTLER_HYDRATION_PROGRESS_FILE="$_PROGRESS_FILE" \
    OSTLER_SEED_CONTACTS="$_CONTACTS_N" \
    OSTLER_SEED_NOTES="$_NOTES_N" \
        python3 - <<'PYSEED' 2>/dev/null || true
import json, os, sys, tempfile
from datetime import datetime, timezone
path = os.environ["OSTLER_HYDRATION_PROGRESS_FILE"]
try:
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        doc = {}
except Exception:
    doc = {}
doc.setdefault("version", 1)
chans = doc.setdefault("channels", {})
def _seed(key, n, ready_if_any):
    n = int(n or 0)
    state = "ready" if (ready_if_any and n > 0) else ("ready" if n > 0 else "absent")
    chans[key] = {"queued": n, "done": n, "state": state}
# Contacts + calendar are populated by the fast hydrate -> ready now.
_seed("contacts", os.environ.get("OSTLER_SEED_CONTACTS", "0"), True)
# Calendar: mark ready (meetings hydrated) with a nominal count of 1 so the
# panel shows it green; an exact tally is not needed for the plain copy.
chans["calendar"] = {"queued": 1, "done": 1, "state": "ready"}
# Notes: ready only if an Evernote export was embedded, else absent.
_seed("notes", os.environ.get("OSTLER_SEED_NOTES", "0"), True)
# Preserve any channel keys the feeds already wrote (imessage/whatsapp/...).
for k in ("imessage", "whatsapp", "email", "spoken"):
    chans.setdefault(k, {"queued": 0, "done": 0, "state": "absent"})
done = sum(int(c.get("done", 0)) for c in chans.values() if isinstance(c, dict))
total = sum(int(c.get("queued", 0)) for c in chans.values() if isinstance(c, dict))
doc["overall"] = {"done": done, "total": total}
doc["updated_utc"] = datetime.now(timezone.utc).isoformat()
d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".hydprog_", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
os.replace(tmp, path)
PYSEED
fi

# ── 3.14a-probe Mail content probe + sidecar (#259) ─────────────
#
# Writes the install-time half of ~/.ostler/state/pipeline_signals.json
# so the Doctor agent can decide whether to surface the "no local
# Mail content yet" banner.
#
# CX-35 (2026-05-24, Studio retest #21): the whole block is wrapped
# in `set +e` / `set -e` because Studio retest #21 died silently here
# (between line 6143 "Logs:" info and the next progress() call for
# wiki-recompile) with no warn/error marker reaching the GUI log.
# Root cause was not pinpointable from static read -- some command
# in this block exits non-zero under set -e/u/pipefail and the
# diagnostic gets dropped. Until next retest tells us which line,
# treat the whole probe as best-effort: it writes a Doctor sidecar,
# its failure means Doctor falls back to safe defaults but the
# install should NEVER die here. Checkpoint info lines below
# pinpoint the death on next retest if it recurs.
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

info "CX-35 checkpoint: entering Mail content probe block"
set +e  # CX-35: probe is best-effort; never kill the install from here
_mail_probe_failure_line=""

MAIL_ACCOUNTS_FOUND=0
MAIL_HAS_FETCHED="false"
APPLE_MAIL_VERSION_DIR=""

# CX-100 (DMG #48j, 2026-05-29): Mail account count now reads
# ~/Library/Accounts/Accounts4.sqlite (source of truth written by
# accountsd when the customer adds an account in System Settings
# -> Internet Accounts) instead of ~/Library/Mail/V<N>/MailData/
# Accounts.plist (derived store, only materialised after Mail.app
# has been launched and synced). The old probe silently returned
# 0 on every clean install where the customer configured iCloud
# but had not opened Mail.app yet -- which on Andy's Studio
# triggered the "Apple Mail does not appear to hold any local
# messages" copy + the wrong "no mail accounts" flow downstream,
# despite Internet Accounts holding 2 active mail accounts.
#
# The MAIL_HAS_FETCHED probe (.emlx walk / Envelope Index) is the
# load-bearing "has Mail.app actually pulled anything?" signal --
# kept as-is, but split from account count so the three-state
# classification (state 1 vs state 2 vs state 3) becomes possible.
info "CX-100 checkpoint: pre Mail.app version dir find"
if [[ -d "${HOME}/Library/Mail" ]]; then
    # set -E propagates the abort-on-error ERR trap INTO the $(...)
    # subshell, so a non-zero find/sort here would fire _ostler_on_err
    # before the outer `||` runs, false-failing a healthy install (same
    # class as CX-122 / #640). Suppress the trap for just this probe; the
    # `|| _mail_probe_failure_line=...` breadcrumb is preserved.
    _saved_err_trap=$(trap -p ERR)
    trap - ERR
    APPLE_MAIL_VERSION_DIR=$(find "${HOME}/Library/Mail" -maxdepth 1 -type d -name 'V[0-9]*' 2>/dev/null | sort -V | tail -1) || _mail_probe_failure_line="find Mail/V* dir"
    eval "${_saved_err_trap:-}"
fi
info "CX-100 checkpoint: Mail.app version dir = [${APPLE_MAIL_VERSION_DIR}]"

# Source-of-truth account count via Accounts4.sqlite. Falls back to
# 0 on schema variation / missing db; the count is informational
# only, but unlike the old Accounts.plist read, this returns the
# truth on a clean iCloud-signed-in Mac whether or not Mail.app
# has ever opened.
MAIL_ACCOUNTS_FOUND="$(_accountsdb_count_mail)"
MAIL_ACCOUNTS_FOUND="${MAIL_ACCOUNTS_FOUND:-0}"
info "CX-100 checkpoint: Accounts4.sqlite mail accounts = ${MAIL_ACCOUNTS_FOUND}"

# Has Mail.app actually pulled a message yet? Reuse the three-state
# helper so the same answer drives the install-time banner AND the
# state-2 wait-for-populate prompt below.
if _store_populated_mail; then
    MAIL_HAS_FETCHED="true"
fi

# Sidecar -- atomic write, 0600 perms. Preserves first_ingest_complete_ts
# if a prior tick has populated it (reinstall case). The JSON-merge
# logic lives in lib/write_pipeline_signals.py so it can be unit-tested.
info "CX-35 checkpoint: setting up sidecar paths + mkdir state dir"
PIPELINE_SIGNALS_DIR="${OSTLER_DIR}/state"
PIPELINE_SIGNALS_FILE="${PIPELINE_SIGNALS_DIR}/pipeline_signals.json"
mkdir -p "$PIPELINE_SIGNALS_DIR" || _mail_probe_failure_line="mkdir state dir"

# ── Doctor first-run flag (B7 belt-and-braces, v1.0.0 LAST-CUT) ──
#
# The Doctor first-run wizard is gated on ${OSTLER_DIR}/.setup-complete
# (doctor/agent/first_run.py::is_first_run). On the productised
# single-machine install the services + hydrate are set up by this
# installer, so by the time the customer opens Doctor the setup IS
# complete -- pre-clear the flag here so they land on the real
# dashboard, not the Docker-oriented first-run Setup Wizard. This is
# the install-side guarantee that complements the Doctor's own
# docker-binary detection fix. Idempotent and non-fatal (the if/else
# keeps it set -e safe): a write failure must never abort the install.
if [[ ! -f "${OSTLER_DIR}/.setup-complete" ]]; then
    if printf 'completed\n' > "${OSTLER_DIR}/.setup-complete" 2>/dev/null; then
        info "Doctor setup-complete flag written; dashboard shown on first open"
    else
        info "could not write ${OSTLER_DIR}/.setup-complete; Doctor may show the first-run wizard"
    fi
fi

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
    # CX-100 three-state copy: accounts==0 -> state 1 (no source);
    # accounts>0 + fetched -> state 3 (synced); accounts>0 + not
    # fetched -> state 2 (configured but not pulled yet -- the case
    # the old install collapsed into "no local messages").
    if [[ "$MAIL_HAS_FETCHED" == "true" ]]; then
        info "$MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST"
    elif [[ "$MAIL_ACCOUNTS_FOUND" -gt 0 ]]; then
        info "$(printf "$MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED" "${MAIL_ACCOUNTS_FOUND}")"
    else
        info "$MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD"
    fi
    gui_emit MAIL_ACCOUNTS_FOUND "count=${MAIL_ACCOUNTS_FOUND}" "has_fetched=${MAIL_HAS_FETCHED}"

    # CX-100 state-2 wait-for-populate prompt. When accounts > 0
    # AND Mail.app has not pulled anything yet, offer to open Mail
    # and wait while it syncs. Suppressed if GUI is off (TTY / CI)
    # so headless tests don't block. If the customer declines OR
    # the wait times out, we fall through to the existing
    # "configured but empty" copy + Doctor follow-up.
    #
    # CX-130 (v1.0.1): skip this Phase-3 interactive wait if the early
    # Phase-2 prompt already offered it. MAIL_POPULATE_PROMPT_SHOWN_EARLY
    # is set by the questions-phase populate probe (mirrors CX-37's
    # MAIL_PROMPT_SHOWN_EARLY for the account prompt) so the autonomous
    # Phase-3 stretch never blocks on this dialog. The detection +
    # sidecar write above still ran, so Doctor sees the correct state.
    # This block remains as the fallback for installs where the early
    # prompt did not run (FDA not yet granted at question time, GUI
    # toggled on after Phase 2, etc.).
    if [[ "$MAIL_ACCOUNTS_FOUND" -gt 0 ]] \
       && [[ "$MAIL_HAS_FETCHED" != "true" ]] \
       && [[ "${OSTLER_GUI:-0}" == "1" ]] \
       && [[ -z "${MAIL_POPULATE_PROMPT_SHOWN_EARLY:-}" ]]; then
        _open_mail_help="$(printf "$MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP" "${MAIL_ACCOUNTS_FOUND}")"
        # CX-110 (DMG #48l, 2026-05-29): pass "Mail" not "Apple Mail" to
        # the LaunchServices `open -a` path. LaunchServices fuzzy-matches
        # "Apple Mail" today on Sequoia but the canonical app bundle name
        # is "Mail.app", and future macOS versions may tighten the fuzzy-
        # match against the on-disk name. Customer-facing copy still
        # reads "Apple Mail" via the prompt help string -- only the open
        # -a argument changes.
        if _three_state_wait_for_populate \
            "mail" \
            "Mail" \
            "" \
            "$MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE" \
            "$_open_mail_help"; then
            # Wait succeeded -- update MAIL_HAS_FETCHED + re-write
            # the sidecar so Doctor sees the new state too.
            MAIL_HAS_FETCHED="true"
            python3 "$_pipeline_writer" \
                --output "$PIPELINE_SIGNALS_FILE" \
                --accounts "$MAIL_ACCOUNTS_FOUND" \
                --has-fetched "$MAIL_HAS_FETCHED" || true
            gui_emit MAIL_ACCOUNTS_FOUND "count=${MAIL_ACCOUNTS_FOUND}" "has_fetched=${MAIL_HAS_FETCHED}"
        fi
        unset _open_mail_help
    fi

    # Interactive remediation prompt when Apple Mail has zero accounts
    # connected on this Mac. The existing detection writes
    # MAIL_ACCOUNTS_FOUND + MAIL_HAS_FETCHED to pipeline_signals.json and
    # Doctor surfaces a follow-up after 24 hours (HR015 #109), but at
    # install time a customer who has not yet added a mail account
    # would otherwise have no idea Ostler's email-ingest path is empty.
    # We give them one chance, in-line, to pop System Settings >
    # Internet Accounts before the install moves on. Skip is fine: the
    # Doctor follow-up still ships.
    #
    # Suppressed when OSTLER_GUI is unset (TTY / CI / curl|bash) so
    # tests and headless re-runs don't block on input.
    # CX-37 (DMG #30, 2026-05-24): skip the Phase 4 prompt if the
    # earlier Phase 2 prompt already asked. MAIL_PROMPT_SHOWN_EARLY is
    # set by the Apple-Mail-branch probe in the questions phase --
    # asking twice mid-install would be a worse experience than asking
    # once early.
    if [[ "$MAIL_ACCOUNTS_FOUND" -eq 0 ]] \
       && [[ "${OSTLER_GUI:-0}" == "1" ]] \
       && [[ -z "${MAIL_PROMPT_SHOWN_EARLY:-}" ]]; then
        _mail_remediation_answer="$(gui_read \
            "$MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE" \
            yesno \
            "n" \
            "$MSG_PROMPT_MAIL_NOT_CONNECTED_HELP" \
            "" \
            "mail_not_connected")"
        case "${_mail_remediation_answer:-n}" in
            y|Y|yes|YES|Yes)
                ok "$MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS"
                # System Settings deep-link reliably opens the
                # Internet Accounts pane on macOS 13+; older macOS
                # versions silently fall back to the top-level pane,
                # which is acceptable for v1.0.
                open "x-apple.systempreferences:com.apple.preferences.internetaccounts" 2>/dev/null || true
                ;;
            *)
                ok "$MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS"
                ;;
        esac
        unset _mail_remediation_answer
    fi
else
    warn "$MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON"
fi

unset MAIL_ACCOUNTS_FOUND MAIL_HAS_FETCHED APPLE_MAIL_VERSION_DIR ACCOUNTS_PLIST
unset PIPELINE_SIGNALS_DIR PIPELINE_SIGNALS_FILE _pipeline_writer
# CX-35: re-enable strict mode + surface any probe failure to the customer log
set -e
if [[ -n "$_mail_probe_failure_line" ]]; then
    warn "Mail content probe: non-fatal failure at: $_mail_probe_failure_line"
    warn "Doctor's empty-Mail diagnostic will fall back to safe defaults."
fi
unset _mail_probe_failure_line
info "CX-35 checkpoint: exiting Mail content probe block cleanly"

# ── 3.14c iMessage bridge LaunchAgent (DISABLED in single-machine v1.0) ──
#
# Status: DISABLED for v1.0 customer installs (single-machine
# architecture per memory/feedback_single_machine_architecture.md).
#
# Background: bridge.py was added 2026-04-01 for Andy's personal
# DUAL-USER deployment on the Mac Mini, where the assistant ran as
# a separate macOS user (different chat.db). The bridge polled the
# *assistant* user's chat.db and shuttled inbound messages to the
# assistant runtime via /Users/Shared/imessage-bridge/inbox.jsonl.
#
# In v1.0 customer installs the assistant runs under the SAME macOS
# user as everything else (single-machine architecture). The Rust
# listener in crates/zeroclaw-channels/src/imessage.rs already polls
# ~/Library/Messages/chat.db directly. Running bridge.py on the same
# user is duplicative AND triggers a self-talk loop:
#
#   1. bridge.py and the listener both see every new inbound message
#      => assistant generates 2 replies per inbound (visible doubling).
#   2. On first install, bridge.py's state.json is missing => it
#      starts at last_rowid = 0 and dumps the ENTIRE chat.db history
#      (LIMIT 500 per 30s tick) into inbox.jsonl. The listener then
#      tries to reply to every historical inbound. Mass-send of old
#      conversation lines, observed 2026-05-28 as the "Marvin talking
#      to itself" symptom across two threads on Andy's number (one
#      cleanly contact-matched, one labelled with Apple's "Maybe:"
#      contact-disambiguation prefix).
#
# Fix: skip the LaunchAgent install AND actively bootout / remove any
# stale agent + bin + state from a previous install. The Rust listener
# remains functional because it reads chat.db directly. The bridge
# code path is also gated OFF by default in the Rust listener under
# OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE=1 (see ostler-assistant PR).
#
# If a future split-identity install brings back a separate assistant
# user, the bridge.py vendor still exists at vendor/imessage_bridge/
# and can be re-wired then. Do NOT delete the vendor directory in
# this PR; just stop installing the LaunchAgent.

progress "$MSG_INFO_IMESSAGE_BRIDGE_STARTED" "imessage_bridge"

# Defensive cleanup: if a previous installer ran the bridge LaunchAgent,
# unload it and remove the rendered plist + staged producer + state +
# inbox so we do not leave a duplicate poller running on the customer's
# Mac after they upgrade through this fix.
_imb_label="com.ostler.imessage-bridge"
_imb_domain="gui/$(id -u)"
launchctl bootout "${_imb_domain}/${_imb_label}" 2>/dev/null \
    || launchctl unload "${HOME}/Library/LaunchAgents/${_imb_label}.plist" 2>/dev/null \
    || true
rm -f "${HOME}/Library/LaunchAgents/${_imb_label}.plist"
rm -f "${OSTLER_DIR}/bin/bridge.py"
rm -f /Users/Shared/imessage-bridge/inbox.jsonl
rm -f /Users/Shared/imessage-bridge/state.json
rm -f /Users/Shared/imessage-bridge/state.json.tmp

# Sanity: an empty /Users/Shared/imessage-bridge/ is harmless. Do not
# rmdir the directory because earlier installs may have set perms on
# it and a future split-identity install will recreate it.

info "iMessage bridge LaunchAgent disabled in v1.0 single-machine mode"
ok "iMessage handled directly by assistant chat.db poller (no bridge)"

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
    # No bundled scripts AND no clone fallback configured. On a real
    # customer install (no HUB_POWER_REPO env var) this is the silent-
    # bail path the deep-dive audit flagged: surface it as a WARN
    # instead of info, so the next retest's log shows the gap rather
    # than the customer noticing their wiki has stopped refreshing
    # days later. See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F2.
    warn "$MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED"
    warn "$MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL"
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

# ── 3.14d-bis Wiki recompile FIRST-DAY catch-up LaunchAgent ──────
#
# Safety net for ANY late-landing source, not just contacts. The
# contact-resync trigger added alongside this only covers contacts;
# calendar / email / WhatsApp / iCloud data can also finish syncing
# minutes-to-hours AFTER the install-time compile, which would
# otherwise leave the wiki sparse until the DAILY recompile agent
# fires (up to 24h later).
#
# Shape mirrors the bounded ostler-contact-resync agent: a self-
# removing wrapper that counts its runs against a cap and boots out
# its own agent once the cap is reached. It reuses the existing
# wiki-recompile-tick.sh (NO duplicated compile logic); incremental
# compiles are cheap because unchanged sections are skipped, so a
# handful of extra ticks over the first few hours is harmless. The
# steady-state DAILY agent installed above is left untouched -- this
# is purely a first-day quick-heal that then removes itself.
#
# Defaults: every 1800s (30 min), capped at 24 tries (~12 hours),
# both overridable via env for testing.
if [[ -x "${OSTLER_DIR}/bin/wiki-recompile-tick.sh" ]]; then
    progress "Setting up first-day wiki catch-up LaunchAgent" "wiki_recompile_catchup_agent"

    WIKI_CATCHUP_INTERVAL_S="${WIKI_CATCHUP_INTERVAL_S:-1800}"
    WIKI_CATCHUP_MAX_TRIES="${WIKI_CATCHUP_MAX_TRIES:-24}"
    WIKI_CATCHUP_LABEL="com.creativemachines.ostler.wiki-recompile-catchup"
    WIKI_CATCHUP_PLIST="${HOME}/Library/LaunchAgents/${WIKI_CATCHUP_LABEL}.plist"

    # Self-removing, bounded catch-up wrapper. Single-quoted heredoc:
    # no install-time expansion -- it resolves OSTLER_DIR at run time
    # exactly like ostler-contact-resync does.
    cat > "${OSTLER_DIR}/bin/ostler-wiki-recompile-catchup" <<'WCUEOF'
#!/usr/bin/env bash
set -euo pipefail

OSTLER_DIR="${HOME}/.ostler"
LOGS_DIR="${OSTLER_DIR}/logs"
STATE_DIR="${OSTLER_DIR}/state"
LABEL="com.creativemachines.ostler.wiki-recompile-catchup"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
TRIES_FILE="${STATE_DIR}/wiki-recompile-catchup.tries"
LOG_FILE="${LOGS_DIR}/wiki-recompile-catchup.log"
WIKI_CATCHUP_MAX_TRIES="${WIKI_CATCHUP_MAX_TRIES:-24}"
TICK="${OSTLER_DIR}/bin/wiki-recompile-tick.sh"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

remove_self() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TRIES_FILE"
}

# Bounded run counter: once we exceed the cap, give up and remove the
# agent so the first-day catch-up can never run forever. The daily
# recompile agent remains the long-term steady state.
tries=0
[[ -f "$TRIES_FILE" ]] && tries="$(cat "$TRIES_FILE" 2>/dev/null || echo 0)"
[[ "$tries" =~ ^[0-9]+$ ]] || tries=0
tries=$((tries + 1))
printf '%s' "$tries" >"$TRIES_FILE"
if [[ "$tries" -gt "$WIKI_CATCHUP_MAX_TRIES" ]]; then
    log "first-day catch-up complete after ${WIKI_CATCHUP_MAX_TRIES} ticks; removing agent (daily recompile continues)"
    remove_self
    exit 0
fi

if [[ ! -x "$TICK" ]]; then
    log "wiki-recompile-tick.sh missing at ${TICK}; removing catch-up agent"
    remove_self
    exit 0
fi

# Reuse the existing tick (no duplicated compile logic). Non-fatal:
# a failed tick just gets retried on the next interval until the cap.
log "first-day catch-up tick ${tries}/${WIKI_CATCHUP_MAX_TRIES}: rebuilding wiki against current state"
"$TICK" >>"$LOG_FILE" 2>&1 || log "catch-up tick ${tries} returned non-zero; will retry"
exit 0
WCUEOF
    chmod +x "${OSTLER_DIR}/bin/ostler-wiki-recompile-catchup"

    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$WIKI_CATCHUP_PLIST" <<WCUPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WIKI_CATCHUP_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/ostler-wiki-recompile-catchup</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>WIKI_CATCHUP_MAX_TRIES</key>
        <string>${WIKI_CATCHUP_MAX_TRIES}</string>
    </dict>
    <key>StartInterval</key>
    <integer>${WIKI_CATCHUP_INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/wiki-recompile-catchup.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/wiki-recompile-catchup.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>5</integer>
</dict>
</plist>
WCUPLIST
    chmod 0644 "$WIKI_CATCHUP_PLIST"

    launchctl bootout "gui/$(id -u)/${WIKI_CATCHUP_LABEL}" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$WIKI_CATCHUP_PLIST" 2>/dev/null || \
       launchctl load "$WIKI_CATCHUP_PLIST" 2>/dev/null; then
        ok "$MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED"
    else
        warn "$MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED"
    fi
else
    info "$MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK"
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
# Default tracks the last-known-good upstream release. If a future
# bump (e.g. v0.4.2 not yet published) raises 404, the inline
# fallback below retries against ASSISTANT_FALLBACK_VERSION so the
# install completes on the proven-good binary.
#
# Open question: there is no zeroclaw subcommand for "encrypt the
# plaintext password the wizard just wrote" -- the secrets store
# auto-migrates legacy enc: values to enc2: on read but does not
# bootstrap from plaintext. The TOML stays mode 0600 in the
# meantime. A `config encrypt-secrets` subcommand would close the
# window; flagged as a follow-up Rust PR (or roll into Phase E).

progress "Setting up ostler-assistant binary (v${OSTLER_ASSISTANT_VERSION:-0.4.19})" "ostler_assistant"

OSTLER_ASSISTANT_VERSION="${OSTLER_ASSISTANT_VERSION:-0.4.19}"
# Hard-coded last-known-good release. The fallback path below
# retries against this version if the primary URL returns 404 /
# non-200, so a missing tag never strands the customer on an
# un-installable Hub.
#
# v0.4.3+ ships the daemon as OstlerAssistant.app in the release
# tarball (instead of a bare Mach-O at the tar root) so macOS TCC
# can read the bundle's Info.plist + Resources/icon.icns and
# render the Ostler v4 oxblood squircle next to the Full Disk
# Access entry. The extraction + path logic below detects which
# shape the tarball ships and stages both correctly, so the same
# install.sh works against a fallback v0.4.1 tarball (bare
# binary) AND the new v0.4.3 tarball (app bundle). v0.4.2 was
# never published per task #507 -- the version was burned on a
# pre-release dry-run.
ASSISTANT_FALLBACK_VERSION="0.4.1"
# Customer-facing distribution.
#
# CX-88 (DMG #48g, 2026-05-29): the daemon ships from the public
# release repo ostler-ai/ostler-releases, NOT the private source
# repo ostler-ai/ostler-assistant (which 404s for every customer).
# Tags are component-prefixed: the daemon release tag is `hub-vX.Y.Z`
# (not bare `vX.Y.Z`) so a single release repo can host multiple
# component release streams. Pre-fix the install.sh default pointed
# at the source repo, which is private + would 404 on every clean
# install whose bundled-daemon tarball was missing (silent-warn-skip
# pattern caught 2026-05-29).
#
# The primary install path is the bundled-in-DMG tarball at
# ${SCRIPT_DIR}/assistant-agent/OstlerAssistant.app (see CX-79b
# below). This URL is the recovery-only fallback for customers
# whose DMG is corrupted or whose extraction step dropped the
# bundled payload.
OSTLER_ASSISTANT_REPO="${OSTLER_ASSISTANT_REPO:-ostler-ai/ostler-releases}"
OSTLER_ASSISTANT_TARGET="${OSTLER_ASSISTANT_TARGET:-aarch64-apple-darwin}"
OSTLER_ASSISTANT_DIR="${OSTLER_DIR}/assistant-agent"
# .app bundle path (v0.4.3+ shape). The bundle wrapper carries
# CFBundleIconFile + icon.icns, so macOS TCC and Activity Monitor
# render the Ostler v4 oxblood squircle next to the daemon.
ASSISTANT_APP_BUNDLE="${OSTLER_DIR}/OstlerAssistant.app"
# Inner Mach-O path: the LaunchAgent and `ostler-assistant doctor`
# / `setup channels` / etc. invocations target this directly.
# Whether the tarball shipped as a bare binary (legacy v0.4.1
# shape) or as an .app bundle (v0.4.3+ shape), this variable
# always points at an executable Mach-O after the staging logic
# below.
ASSISTANT_BINARY="${ASSISTANT_APP_BUNDLE}/Contents/MacOS/ostler-assistant"
# Legacy bare-binary path. Kept here for the fallback-to-v0.4.1
# code path further down: if the tarball does not contain an .app
# bundle (older release), the binary lands at this path instead
# and ASSISTANT_BINARY is rewritten to point here. Quoted symbol
# `_LEGACY_` makes a grep for `bin/ostler-assistant` easy if a
# future migration wants to flatten the dual-shape support.
ASSISTANT_BINARY_LEGACY="${OSTLER_DIR}/bin/ostler-assistant"

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

_ostler_assistant_set_urls() {
    OSTLER_ASSISTANT_VERSION="$1"
    ASSISTANT_ARCHIVE_NAME="ostler-assistant-${OSTLER_ASSISTANT_TARGET}-v${OSTLER_ASSISTANT_VERSION}.tar.gz"
    # CX-88 (2026-05-29): tag is `hub-vX.Y.Z` -- the release repo at
    # ostler-ai/ostler-releases uses component-prefixed tags so it can
    # host multiple release streams (hub, remote-capture, iOS, etc.)
    # under one repository.
    ASSISTANT_ARCHIVE_URL="https://github.com/${OSTLER_ASSISTANT_REPO}/releases/download/hub-v${OSTLER_ASSISTANT_VERSION}/${ASSISTANT_ARCHIVE_NAME}"
    ASSISTANT_CHECKSUM_URL="${ASSISTANT_ARCHIVE_URL}.sha256"
}

_ostler_assistant_set_urls "${OSTLER_ASSISTANT_VERSION}"

# ASSISTANT_TMPDIR is declared in the Phase 3 composite_cleanup
# block; this allocator sets it. composite_cleanup will rm -rf
# the dir if we exit before the explicit cleanups below fire.
ASSISTANT_TMPDIR="$(mktemp -d)"

ASSISTANT_BINARY_INSTALLED=false

# CX-79b (DMG #46, 2026-05-25): prefer the daemon binary bundled in
# Resources/assistant-agent/ over the GitHub release download.
# The bundled binary is built from the same commit that defines the
# DMG signing + notarisation posture, so version skew between the
# customer's daemon and the rest of the install is impossible. The
# DMG bundling also makes the install network-independent for the
# critical-path binary (a customer with flaky DNS / GitHub outage /
# Tailscale rerouting still gets a working daemon).
#
# Falls through to the curl path if no bundled artefact is present
# (older DMGs predating this bundling, or a corrupted install
# extraction). OSTLER_ASSISTANT_FORCE_DOWNLOAD=1 env-var override
# forces the curl path even when bundled is present -- used in CI
# to exercise the customer-network code path.
#
# v0.4.3+ shape: the DMG bundles OstlerAssistant.app at
# assistant-agent/OstlerAssistant.app/. Legacy DMGs bundled a bare
# binary at assistant-agent/bin/ostler-assistant. Probe for the
# .app first (preferred), then fall back to the bare-binary path.
# Both paths are then staged into ~/.ostler/OstlerAssistant.app/
# downstream (the bare-binary shape gets wrapped in a minimal .app
# locally so the TCC icon works regardless of which shape the
# operator's DMG was cut from).
ASSISTANT_BUNDLED_APP="${SCRIPT_DIR}/assistant-agent/OstlerAssistant.app"
ASSISTANT_BUNDLED_BIN="${SCRIPT_DIR}/assistant-agent/bin/ostler-assistant"

# Determine whether a bundled artefact (.app or bare bin) is
# present in the DMG. The .app shape is preferred (v0.4.3+); the
# bare-binary shape stays supported for older DMGs.
_assistant_bundled_shape=""
if [[ -z "${OSTLER_ASSISTANT_FORCE_DOWNLOAD:-}" ]]; then
    if [[ -x "${ASSISTANT_BUNDLED_APP}/Contents/MacOS/ostler-assistant" ]]; then
        _assistant_bundled_shape="app"
    elif [[ -x "$ASSISTANT_BUNDLED_BIN" ]]; then
        _assistant_bundled_shape="bin"
    fi
fi

# Try the primary download URL, then fall back once to
# ASSISTANT_FALLBACK_VERSION (last-known-good). The fallback only
# activates when (a) no bundled artefact is present in the DMG
# and (b) the primary URL returns non-200. v0.4.2 of
# ostler-assistant was never published to ostler-ai/ostler-installer
# (default bumped in error pre-DMG#48; caught on a clean Studio
# install). If the primary URL 404s, the install still completes
# on a proven-good binary rather than stranding the customer at
# the launch step.
_assistant_download_ok=false
if [[ -z "$_assistant_bundled_shape" ]]; then
    if curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" "$ASSISTANT_ARCHIVE_URL" 2>"$ASSISTANT_TMPDIR/curl.log" \
       && curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME.sha256" "$ASSISTANT_CHECKSUM_URL" 2>>"$ASSISTANT_TMPDIR/curl.log"; then
        _assistant_download_ok=true
    elif [[ "${OSTLER_ASSISTANT_VERSION}" != "${ASSISTANT_FALLBACK_VERSION}" ]]; then
        warn "$(printf "$MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_ARCHIVE_URL}")"
        warn "Retrying with last-known-good v${ASSISTANT_FALLBACK_VERSION}..."
        _ostler_assistant_set_urls "${ASSISTANT_FALLBACK_VERSION}"
        rm -f "$ASSISTANT_TMPDIR"/*
        if curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" "$ASSISTANT_ARCHIVE_URL" 2>"$ASSISTANT_TMPDIR/curl.log" \
           && curl -fSL --retry 2 --retry-delay 2 -o "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME.sha256" "$ASSISTANT_CHECKSUM_URL" 2>>"$ASSISTANT_TMPDIR/curl.log"; then
            _assistant_download_ok=true
        fi
    fi
fi

if [[ "$_assistant_bundled_shape" == "app" ]]; then
    # DMG bundled the v0.4.3+ shape: an .app bundle. Copy the
    # whole bundle tree to ~/.ostler/OstlerAssistant.app/. ditto
    # preserves Apple-specific filesystem metadata (extended
    # attributes, ACLs, signature resources) that a plain cp -R
    # can occasionally strip on edge filesystems; this matters
    # because a signed bundle's _CodeSignature dir is part of the
    # signature envelope.
    info "$MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY"
    rm -rf "$ASSISTANT_APP_BUNDLE"
    mkdir -p "$(dirname "$ASSISTANT_APP_BUNDLE")"
    ditto "$ASSISTANT_BUNDLED_APP" "$ASSISTANT_APP_BUNDLE"
    chmod 0755 "$ASSISTANT_BINARY"
    # Clear quarantine from the whole bundle tree. The DMG itself
    # was already Gatekeeper-cleared by the customer at install
    # time, so this is not a security downgrade. -r recurses so
    # the inner Mach-O + the Resources/icon.icns both lose the
    # quarantine flag.
    xattr -rd com.apple.quarantine "$ASSISTANT_APP_BUNDLE" 2>/dev/null || true
    ok "$(printf "$MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_APP_BUNDLE}")"
    ASSISTANT_BINARY_INSTALLED=true
elif [[ "$_assistant_bundled_shape" == "bin" ]]; then
    # DMG bundled the legacy bare-binary shape. Stage the binary
    # into the .app bundle structure locally so the TCC icon
    # surface stays consistent regardless of which DMG cut the
    # customer is installing from. The local-wrap uses the same
    # Info.plist + icon.icns shipped in the DMG Resources/ so the
    # customer sees the Ostler v4 icon in System Settings even on
    # an older daemon build.
    info "$MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY"
    rm -rf "$ASSISTANT_APP_BUNDLE"
    mkdir -p "$ASSISTANT_APP_BUNDLE/Contents/MacOS"
    mkdir -p "$ASSISTANT_APP_BUNDLE/Contents/Resources"
    cp "$ASSISTANT_BUNDLED_BIN" "$ASSISTANT_BINARY"
    chmod 0755 "$ASSISTANT_BINARY"
    # Synthesise a minimal Info.plist for the locally-wrapped
    # bundle. The bundle ID matches the daemon's TCC client
    # identifier so a future v0.4.3+ upgrade preserves the FDA
    # grant. CFBundleIconFile=icon + the icns copied below give
    # macOS what it needs to render the Ostler v4 mark.
    cat > "$ASSISTANT_APP_BUNDLE/Contents/Info.plist" <<INFOPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ostler-assistant</string>
    <key>CFBundleIdentifier</key>
    <string>ai.ostler.assistant</string>
    <key>CFBundleName</key>
    <string>Ostler Assistant</string>
    <key>CFBundleDisplayName</key>
    <string>Ostler</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${OSTLER_ASSISTANT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${OSTLER_ASSISTANT_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Creative Machines Limited. All rights reserved.</string>
</dict>
</plist>
INFOPLISTEOF
    # Copy the v4 oxblood squircle icns into the bundle.
    # Resolution order matches the FDA dialog icon path used
    # downstream: prefer the DMG's Resources, then fall back to
    # the installed-app Resources/ if the operator ran an unusual
    # SCRIPT_DIR path. If neither is present we leave
    # CFBundleIconFile dangling -- macOS falls back to the
    # generic icon, which is the same outcome as not wrapping;
    # better than failing the install over a missing icns.
    _local_wrap_icon_src=""
    if [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
        _local_wrap_icon_src="${SCRIPT_DIR}/AppIcon.icns"
    elif [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
        _local_wrap_icon_src="${SCRIPT_DIR}/DialogIcon.icns"
    elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
        _local_wrap_icon_src="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
    elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
        _local_wrap_icon_src="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
    fi
    if [[ -n "$_local_wrap_icon_src" ]]; then
        cp "$_local_wrap_icon_src" "$ASSISTANT_APP_BUNDLE/Contents/Resources/icon.icns"
        chmod 0644 "$ASSISTANT_APP_BUNDLE/Contents/Resources/icon.icns"
    fi
    unset _local_wrap_icon_src
    # Clear quarantine from the freshly-staged bundle.
    xattr -rd com.apple.quarantine "$ASSISTANT_APP_BUNDLE" 2>/dev/null || true
    ok "$(printf "$MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED" "${OSTLER_ASSISTANT_VERSION}" "${ASSISTANT_APP_BUNDLE}")"
    ASSISTANT_BINARY_INSTALLED=true
elif [[ "$_assistant_download_ok" == "true" ]]; then

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

    # Extract the tarball into a private staging dir first so we
    # can inspect the shape (bare binary vs .app bundle) before
    # committing to a final layout. v0.4.3+ tarballs contain
    # OstlerAssistant.app at the tar root; legacy v0.4.1
    # tarballs contain a bare ostler-assistant binary. The
    # release-pipeline rename plan is described in the
    # companion ostler-assistant PR (Path A).
    _assistant_extract_dir="$(mktemp -d)"
    if tar xzf "$ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME" -C "$_assistant_extract_dir"; then
        if [[ -d "$_assistant_extract_dir/OstlerAssistant.app" ]]; then
            # v0.4.3+ shape: tarball contained OstlerAssistant.app
            # at the root. Stage it into ~/.ostler/.
            rm -rf "$ASSISTANT_APP_BUNDLE"
            mkdir -p "$(dirname "$ASSISTANT_APP_BUNDLE")"
            ditto "$_assistant_extract_dir/OstlerAssistant.app" "$ASSISTANT_APP_BUNDLE"
        elif [[ -f "$_assistant_extract_dir/ostler-assistant" ]]; then
            # Legacy v0.4.1 shape: tarball contained a bare
            # binary. Wrap it in a minimal .app locally so the
            # TCC icon surface stays consistent regardless of
            # which release the customer is installing.
            rm -rf "$ASSISTANT_APP_BUNDLE"
            mkdir -p "$ASSISTANT_APP_BUNDLE/Contents/MacOS"
            mkdir -p "$ASSISTANT_APP_BUNDLE/Contents/Resources"
            cp "$_assistant_extract_dir/ostler-assistant" "$ASSISTANT_BINARY"
            cat > "$ASSISTANT_APP_BUNDLE/Contents/Info.plist" <<INFOPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ostler-assistant</string>
    <key>CFBundleIdentifier</key>
    <string>ai.ostler.assistant</string>
    <key>CFBundleName</key>
    <string>Ostler Assistant</string>
    <key>CFBundleDisplayName</key>
    <string>Ostler</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${OSTLER_ASSISTANT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${OSTLER_ASSISTANT_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Creative Machines Limited. All rights reserved.</string>
</dict>
</plist>
INFOPLISTEOF
            _curl_wrap_icon_src=""
            if [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
                _curl_wrap_icon_src="${SCRIPT_DIR}/AppIcon.icns"
            elif [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
                _curl_wrap_icon_src="${SCRIPT_DIR}/DialogIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
                _curl_wrap_icon_src="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
            elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
                _curl_wrap_icon_src="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
            fi
            if [[ -n "$_curl_wrap_icon_src" ]]; then
                cp "$_curl_wrap_icon_src" "$ASSISTANT_APP_BUNDLE/Contents/Resources/icon.icns"
                chmod 0644 "$ASSISTANT_APP_BUNDLE/Contents/Resources/icon.icns"
            fi
            unset _curl_wrap_icon_src
        else
            # Tarball shape we don't understand. Leave
            # ASSISTANT_APP_BUNDLE absent; the Mach-O check below
            # will mark it corrupt + skip the launch agent.
            warn "Tarball at $ASSISTANT_TMPDIR/$ASSISTANT_ARCHIVE_NAME contained neither OstlerAssistant.app nor a bare ostler-assistant binary at the root."
            warn "Skipping LaunchAgent install. Re-download once the release pipeline is back online."
        fi
        rm -rf "$_assistant_extract_dir"
        chmod 0755 "$ASSISTANT_BINARY" 2>/dev/null || true

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
                # Operator-installed daemons under
                # ~/.ostler/OstlerAssistant.app are explicitly
                # trusted by the install they just authorised;
                # quarantine adds friction without buying
                # anything beyond what FileVault and the SHA
                # verify above already cover. -r recurses so the
                # inner Mach-O + Resources/icon.icns both lose
                # the xattr.
                xattr -rd com.apple.quarantine "$ASSISTANT_APP_BUNDLE" 2>/dev/null || true
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
#
# v0.4.3+ shape: the DMG may bundle OstlerAssistant.app under
# assistant-agent/. That bundle was already staged into
# ~/.ostler/OstlerAssistant.app/ above, so we skip it here to
# avoid a redundant ~20MB copy under assistant-agent/. Same for
# the legacy bin/ directory if a customer is installing from an
# older DMG that still bundled the bare binary there. Everything
# else (INSTALL_SNIPPET.sh + launchd/) is needed at the
# ~/.ostler/assistant-agent/ path.
if [[ -d "${SCRIPT_DIR}/assistant-agent" && -f "${SCRIPT_DIR}/assistant-agent/INSTALL_SNIPPET.sh" ]]; then
    mkdir -p "$OSTLER_ASSISTANT_DIR"
    # rsync -a --exclude lets us cherry-pick what gets copied
    # without writing a per-file enumeration. rsync ships with
    # macOS so no extra dependency.
    rsync -a \
        --exclude='OstlerAssistant.app' \
        --exclude='bin' \
        "${SCRIPT_DIR}/assistant-agent/" \
        "$OSTLER_ASSISTANT_DIR/"
else
    # Surface a missing-bundle warning so a future buried-failure
    # retest catches the gap. Without this assets stage, the LaunchAgent
    # never loads and the customer's daily briefs + WhatsApp keepalive
    # silently never fire. See CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md F1.
    warn "$MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED"
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

    # #646 (v1.0 launch blocker): assemble the customer's OWN iMessage
    # handles for the assistant's self-echo loop guard. The daemon's
    # is_self_handle (crates/zeroclaw-channels/src/imessage.rs) reads
    # OSTLER_IMESSAGE_SELF_HANDLES and drops inbound from the user's own
    # handles, so the assistant cannot reply to its own output echoing
    # back (shared Apple ID / cross-account routing). Source = the me-card
    # identity (USER_PHONE + USER_EMAIL captured at Q3), NOT
    # CHANNEL_IMESSAGE_ALLOWED, which may include OTHER people the
    # assistant is allowed to talk to -- self-handles must be only the
    # user's own addresses. Empty when iMessage is off or no handle was
    # captured: the snippet then renders an empty value and the guard
    # stays inactive (the daemon's content-based backstop still applies).
    ASSISTANT_SELF_HANDLES=""
    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ]]; then
        for _self_h in "${USER_PHONE:-}" "${USER_EMAIL:-}"; do
            _self_h="${_self_h# }"; _self_h="${_self_h% }"
            [[ -n "$_self_h" ]] || continue
            if [[ -z "$ASSISTANT_SELF_HANDLES" ]]; then
                ASSISTANT_SELF_HANDLES="$_self_h"
            else
                ASSISTANT_SELF_HANDLES="${ASSISTANT_SELF_HANDLES},${_self_h}"
            fi
        done
    fi

    # CX-77 (DMG #44, 2026-05-25): wrap the snippet invocation in a
    # retry loop and tee stderr into install.log. The snippet failed
    # on auto-run during DMG #43 Studio retest but succeeded when
    # Andy re-ran the SAME command manually moments later --
    # consistent with launchctl-bootstrap timing or a transient env
    # issue. The previous one-shot invocation hid the stderr inside
    # ostler-assistant.err which the GUI never surfaced, so the
    # customer saw a bare "See output above" warning with no output
    # above to look at. Retry 3 times with 2 s gaps, capture stderr
    # to a temp file we can both tee to install.log and dump into
    # the warn message on final failure. cwd pinned to
    # OSTLER_ASSISTANT_DIR; explicit env passthrough.
    _snippet_stderr=$(mktemp -t ostler-assistant-snippet-stderr.XXXXXX)
    _snippet_ok=false
    for _snippet_attempt in 1 2 3; do
        if (
            cd "$OSTLER_ASSISTANT_DIR" || exit 1
            OSTLER_INSTALL_ROOT="$OSTLER_ASSISTANT_DIR" \
            OSTLER_DIR="$OSTLER_DIR" \
            LOGS_DIR="$LOGS_DIR" \
            ASSISTANT_CONFIG_DIR="$ASSISTANT_CONFIG_DIR" \
            INSTALL_WHATSAPP_KEEPALIVE="$ASSISTANT_INSTALL_KEEPALIVE" \
            OSTLER_IMESSAGE_SELF_HANDLES="$ASSISTANT_SELF_HANDLES" \
            OSTLER_ASSISTANT_DEFER_BOOTSTRAP="1" \
            bash "${OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh" 2>"$_snippet_stderr"
        ); then
            _snippet_ok=true
            break
        fi
        # Capture stderr from this attempt into install.log so the
        # GUI log drawer surfaces the failure mode -- not just the
        # bare "See output above" warning.
        if [[ -s "$_snippet_stderr" ]]; then
            info "$(printf "$MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED" "${_snippet_attempt}")"
            sed -e 's/^/    /' "$_snippet_stderr" | head -20
        fi
        if [[ "$_snippet_attempt" -lt 3 ]]; then
            sleep 2
        fi
    done
    if [[ "$_snippet_ok" == "true" ]]; then
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
        # Make the err log path visible even on first failure so the
        # customer (or Andy on a retest) can grep what went wrong.
        warn "$(printf "$MSG_WARN_ASSISTANT_ERR_LOG_PATH" "${LOGS_DIR}/ostler-assistant.err")"
        if [[ -s "$_snippet_stderr" ]]; then
            warn "$MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR"
            sed -e 's/^/    /' "$_snippet_stderr" | head -30
        fi
    fi
    rm -f "$_snippet_stderr"
    unset _snippet_stderr _snippet_ok _snippet_attempt
fi

# ── 3.14e-probe iMessage FDA probe (CX-60) ──────────────────────
#
# After the assistant LaunchAgent has had a chance to start, probe
# whether the daemon binary can read ~/Library/Messages/chat.db.
# macOS TCC grants Full Disk Access per-binary; the FDA the customer
# granted to OstlerInstaller.app does NOT transfer to the
# ostler-assistant binary that the LaunchAgent runs.
#
# Strategy: attempt a read-only sqlite3 open of chat.db from inside
# install.sh. install.sh inherits OstlerInstaller.app's TCC posture,
# which is the closest unprivileged proxy we have for whether FDA is
# granted to anything on this Mac. False positives (probe succeeds,
# daemon still can't read) are tolerable -- the Doctor card's live
# auto-dismiss probe (status_collector + diagnostic_rules.
# check_imessage_fda) re-evaluates on every refresh and clears the
# card if the live state is healthy.
#
# We write the result to pipeline_signals.json so the Doctor card
# only appears post-install (no false positives on fresh installs
# of older builds that lack this probe). The writer call uses the
# additive --imessage-fda-needed flag and preserves the mail half.
#
# Best-effort: any failure in this block leaves install.sh trucking
# on. Doctor falls back to its safe-default "no card" path.

# ── CX-90 (fresh-install P0): daemon-identity TCC test as a helper ──
#
# The authoritative question for the iMessage channel is whether the
# *daemon* (ai.ostler.assistant, or the legacy bare-binary client)
# holds Full Disk Access -- NOT whether install.sh's own TCC posture
# can read chat.db. install.sh inherits OstlerInstaller.app's identity,
# so its own sqlite3 read is only a weak hint and must never on its own
# decide "FDA is granted". This helper queries the system TCC.db for
# the daemon client ids and echoes "granted" only when auth_value == 2.
# Best-effort: if sudo would prompt (cache expired) or sqlite3 fails it
# echoes nothing, so callers fall through to the assist/dialog path --
# no worse than the pre-CX-90 behaviour.
_imessage_daemon_fda_granted() {
    local _auth=""
    if command -v sudo >/dev/null 2>&1; then
        _auth="$(
            sudo -n sqlite3 \
                "/Library/Application Support/com.apple.TCC/TCC.db" \
                "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client IN ('ai.ostler.assistant', '${ASSISTANT_BINARY_LEGACY}') LIMIT 1;" \
                2>/dev/null || true
        )"
    fi
    if [[ "$_auth" == "2" ]]; then
        echo "granted"
    fi
}

# ── Serialised daemon bootstrap (mid-install permission-glut fix) ──
#
# The assistant LaunchAgent is RENDERED earlier (INSTALL_SNIPPET.sh,
# invoked with OSTLER_ASSISTANT_DEFER_BOOTSTRAP=1) but its bootstrap is
# deferred to here so the daemon's own async "read your Messages" TCC
# prompt fires ALONE, after our one-line pre-warn, and not concurrently
# with the System Settings + Finder + osascript Full Disk Access cluster
# below. The plist keeps RunAtLoad=true, so login persistence is
# unchanged -- only the FIRST start during install is gated.
#
# Idempotent: bootstraps at most once per install (guard flag), so the
# happy-path call (before the FDA modal) and the safety-net call (after
# the probe, for non-GUI / no-chat.db paths) cannot double-start it.
# Best-effort: any launchctl failure is swallowed (the probe runs under
# set +e) and surfaced as a warn so a missing daemon is still visible.
_ASSISTANT_DAEMON_BOOTSTRAPPED=0
_ostler_bootstrap_assistant_daemon() {
    [[ "${_ASSISTANT_DAEMON_BOOTSTRAPPED:-0}" == "1" ]] && return 0
    local _plist="${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
    [[ -f "$_plist" ]] || return 0
    launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$_plist" 2>/dev/null \
       || launchctl load "$_plist" 2>/dev/null; then
        _ASSISTANT_DAEMON_BOOTSTRAPPED=1
    else
        warn "$MSG_WARN_ASSISTANT_DAEMON_BOOTSTRAP_DEFERRED_FAILED"
        _ASSISTANT_DAEMON_BOOTSTRAPPED=1  # don't retry-thrash; daemon also starts at next login (RunAtLoad)
    fi
}

info "$MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN"
set +e  # CX-60: probe is best-effort; never kill the install from here
_imessage_fda_probe_failure_line=""

if [[ "${ASSISTANT_BINARY_INSTALLED:-false}" != "true" ]]; then
    info "$MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON"
else
    # ── Serialise the daemon's first boot vs the FDA cluster (Job 1) ──
    #
    # The LaunchAgent was rendered-but-not-bootstrapped earlier (deferred
    # via OSTLER_ASSISTANT_DEFER_BOOTSTRAP). Bootstrap it HERE, behind a
    # single honest pre-warn, so the daemon's own "read your Messages"
    # TCC prompt fires alone -- before, not on top of, the System Settings
    # + Finder + osascript Full Disk Access modal further down. Booting it
    # now (rather than after the modal) also means the daemon has touched
    # chat.db by the time the modal shows, so it appears in the Full Disk
    # Access list and the modal's "Find Ostler and turn it on" copy is
    # accurate. One thing on screen at a time: the pre-warn modal blocks,
    # the user acknowledges, then the macOS Messages prompt surfaces alone
    # during the settle below.
    # The "read your Messages" pre-warn only makes sense when the customer
    # enabled the iMessage channel -- that is the only configuration in
    # which the daemon polls chat.db and macOS raises the Messages TCC
    # prompt. With iMessage off we still bootstrap the daemon (it runs for
    # every channel) but skip the Messages-specific pre-warn + long settle.
    if [[ "${OSTLER_GUI:-0}" == "1" && "${CHANNEL_IMESSAGE_ENABLED:-false}" == "true" ]]; then
        info "$MSG_INFO_ASSISTANT_DAEMON_PREWARN"
        _prewarn_msg="$(printf '%s\n\n%s' \
            "$MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_LINE1" \
            "$MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_LINE2")"
        _prewarn_msg_esc="${_prewarn_msg//\"/\\\"}"
        _prewarn_title_esc="${MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_TITLE//\"/\\\"}"
        _prewarn_button_esc="${MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_BUTTON//\"/\\\"}"
        osascript \
            -e 'tell application "System Events" to activate' \
            -e "tell application \"System Events\" to display dialog \"${_prewarn_msg_esc}\" with title \"${_prewarn_title_esc}\" buttons {\"${_prewarn_button_esc}\"} default button \"${_prewarn_button_esc}\" with icon note" \
            >/dev/null 2>&1 || true
        unset _prewarn_msg _prewarn_msg_esc _prewarn_title_esc _prewarn_button_esc
        _prewarn_shown=1
    else
        _prewarn_shown=0
    fi
    # Start the daemon now (idempotent). With the pre-warn dismissed, its
    # async Messages TCC prompt fires alone during the settle.
    _ostler_bootstrap_assistant_daemon

    _imessage_chat_db_path="${HOME}/Library/Messages/chat.db"
    _imessage_fda_needed="true"  # conservative default

    # Grace period: let the freshly-bootstrapped daemon attempt its first
    # chat.db open so its own "read your Messages" prompt surfaces ALONE,
    # before we open the FDA modal. Longer when we just pre-warned the user
    # (a prompt can appear) than otherwise. The probe itself is independent
    # (install.sh opens chat.db directly); this also avoids racing the
    # LaunchAgent.
    if [[ "$_prewarn_shown" == "1" ]]; then
        sleep 5
    else
        sleep 2
    fi
    unset _prewarn_shown

    if [[ -f "$_imessage_chat_db_path" ]]; then
        # ── CX-90 (fresh-install P0): daemon-identity test is FIRST ──
        #
        # The authoritative test is whether the *daemon*
        # (ai.ostler.assistant / legacy bare-binary client) holds
        # Full Disk Access. We query the system TCC.db for the
        # daemon client ids up front, unconditionally. Only the
        # daemon client returning auth_value == 2 sets needed=false
        # and prints the GRANTED line. install.sh's own chat.db read
        # below is demoted to an informational hint -- it inherits
        # OstlerInstaller.app's TCC posture, NOT the daemon's, so it
        # must never on its own decide "FDA is granted".
        #
        # v0.4.3+ shape: the daemon is launched from inside
        # OstlerAssistant.app/Contents/MacOS/, so macOS TCC keys the
        # client column by the bundle identifier (ai.ostler.assistant)
        # -- the same value the bundle declares in Info.plist
        # CFBundleIdentifier. The helper checks both the bundle-ID form
        # (v0.4.3+) AND the legacy bare-binary path (in case a customer
        # still has an old FDA grant against the bare-binary client).
        # Either form returning 2 means "granted".
        if [[ "$(_imessage_daemon_fda_granted)" == "granted" ]]; then
            _imessage_fda_needed="false"
            info "$MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED"
            launchctl kickstart -k "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
        else
            # The daemon-identity test above reported not-granted.
            # We still run install.sh's own read of chat.db as a
            # best-effort hint, but a success here does NOT prove the
            # daemon has FDA (it inherits OstlerInstaller.app's TCC
            # identity, not the daemon's), so it must NOT set
            # needed=false nor print the "channel will work" line. We
            # keep its outcome to a non-committal log only.
            if sqlite3 -readonly \
                    "file:${_imessage_chat_db_path}?mode=ro" \
                    "SELECT 1 LIMIT 1;" >/dev/null 2>&1; then
                : # installer identity can read chat.db; not authoritative for the daemon
            fi
            info "$MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT"
            # Fall straight through to the assisted-grant flow below.
            if true; then
                # ── CX-66 (DMG #37, 2026-05-24): assisted FDA grant ─────
                #
                # macOS TCC grants Full Disk Access per-binary; there's
                # no public API to add a binary programmatically. The
                # cleanest customer experience we can build on stock
                # macOS is a guided drag-add: open System Settings to
                # the Full Disk Access pane, reveal the daemon binary
                # in Finder so the customer can drag it directly, and
                # show a modal that blocks install.sh until they're
                # done. After the modal dismisses, re-probe chat.db.
                # If readable, write needed=false (Doctor card never
                # appears). If still not readable, the CX-60 Doctor
                # card takes over as the persistent reminder.
                #
                # Gated on OSTLER_GUI=1: the assist requires the GUI
                # session (System Settings + Finder + AppleScript
                # dialog all need a windowed environment).
                if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
                    info "$MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING"

                # FDA_PANE_REFRESH (daemon parity for #572): force a fresh
                # System Settings load before pointing the customer at the FDA
                # pane. #572 added this to the INSTALLER FDA grant only; the
                # daemon (OstlerAssistant) grant here never got it. The daemon
                # pane usually opens with System Settings ALREADY open from the
                # earlier installer grant, so it shows a STALE Full Disk Access
                # list and OstlerAssistant looks "missing" for ~30-60s until the
                # pane happens to refresh (the blank-window customers reported).
                # killall + reopen guarantees the list is current. Best-effort;
                # covers both the "System Settings" (macOS 13+) and legacy
                # "System Preferences" process names.
                killall "System Settings" >/dev/null 2>&1 || true
                killall "System Preferences" >/dev/null 2>&1 || true
                sleep 1

                # Open System Settings to the Full Disk Access pane.
                # The URL scheme is stable on macOS 13+; older macOS
                # falls back to Privacy & Security top-level which
                # is acceptable. The 2>/dev/null swallows the rare
                # "scheme not registered" warning on stripped builds.
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

                # (mid-install permission-glut fix) The stray Finder
                # reveal of the daemon .app bundle used to fire HERE,
                # concurrently with the System Settings pane and the
                # osascript modal -- three windows at once. It is now
                # removed from the concurrent path: the daemon was
                # bootstrapped before this block, so it has already
                # touched chat.db and appears in the Full Disk Access
                # list, which makes the modal's "Find Ostler and turn
                # it on" copy accurate without any drag-add. A guarded
                # Finder reveal is fired AFTER the modal, and only if
                # the grant still didn't land, as a drag-add fallback
                # (see below). The reveal therefore never piles on top
                # of the modal again.

                # Modal that blocks install.sh until the customer
                # dismisses it. The osascript dialog is reliable
                # in the Phase 4 context (we're already running
                # under user UI session via OstlerInstaller.app).
                # Build the message body from per-line catalogue
                # strings to keep Rule 0.9 happy (no literal \n
                # in catalogue values).
                # CX-78c (DMG #45): copy tightened to 4 lines + dropped
                # the "denied -- which is what put it in the list"
                # apology. LINE5 was retired with the rewrite.
                # CX-81 B8 (DMG #46+): copy tightened again to 3 lines
                # (LINE4 retired). Title swaps binary name for product
                # name; LINE2 quotes the binary name so the customer
                # can pattern-match it in the System Settings list.
                _imessage_fda_dialog_msg="$(printf '%s\n\n%s\n%s' \
                    "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1" \
                    "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2" \
                    "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3")"
                # Escape any embedded double-quotes for the
                # AppleScript string literal. Then pass through
                # osascript -e. Failures (user clicks the close
                # widget instead of OK) are swallowed -- the
                # re-probe below settles the question regardless.
                _imessage_fda_dialog_msg_esc="${_imessage_fda_dialog_msg//\"/\\\"}"
                _imessage_fda_title_esc="${MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE//\"/\\\"}"
                _imessage_fda_button_esc="${MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON//\"/\\\"}"
                # CX-81 B8 (DMG #46+): replace the generic system "note"
                # icon (tan square with exclamation mark) with an Ostler
                # brand icon to reinforce trust at the most trust-sensitive
                # moment of the install.
                #
                # CX-81 B8b: prefer DialogIcon.icns (oxblood circle + white
                # "O", edge-to-edge canvas) over AppIcon.icns. AppIcon was
                # designed with internal padding so macOS can apply its
                # squircle mask on Dock / Launchpad / Finder, but
                # osascript's `display dialog` does NOT apply that mask.
                # In dialog context AppIcon's full square canvas shows --
                # the cream squircle background reads as a visible
                # bounding-box / "feint square outline" around the marque.
                # DialogIcon is a dialog-specific .icns where the brand
                # mark fills the canvas with no padding, so the dialog
                # renders the oxblood circle cleanly against the dialog
                # chrome with no halo.
                #
                # Resolution order:
                #   1. ${SCRIPT_DIR}/DialogIcon.icns -- sibling of install.sh
                #      inside OstlerInstaller.app/Contents/Resources/.
                #      Always present in DMG installs cut after B8b.
                #   2. /Applications/OstlerInstaller.app/Contents/Resources/
                #      DialogIcon.icns -- fallback if SCRIPT_DIR is unusual
                #      (tarball install with assets stripped).
                #   3. ${SCRIPT_DIR}/AppIcon.icns + /Applications/.../AppIcon.icns
                #      -- secondary fallback for any in-flight DMG cut that
                #      shipped pre-B8b (still better than `with icon note`
                #      since AppIcon at least carries the product mark).
                #   4. `with icon note` fallback -- preserves the existing
                #      sub-optimal-but-functional icon on dev/CI/headless
                #      paths so a missing icns file never breaks the
                #      osascript dialog (no silent broken release).
                _imessage_fda_icon_path=""
                if [[ -f "${SCRIPT_DIR}/DialogIcon.icns" ]]; then
                    _imessage_fda_icon_path="${SCRIPT_DIR}/DialogIcon.icns"
                elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns" ]]; then
                    _imessage_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns"
                elif [[ -f "${SCRIPT_DIR}/AppIcon.icns" ]]; then
                    _imessage_fda_icon_path="${SCRIPT_DIR}/AppIcon.icns"
                elif [[ -f "/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns" ]]; then
                    _imessage_fda_icon_path="/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns"
                fi
                if [[ -n "$_imessage_fda_icon_path" ]]; then
                    # AppleScript POSIX file paths cannot contain unescaped
                    # double-quotes; the icns paths above are controlled by
                    # our own bundle layout so this is paranoia, not a real
                    # risk, but we escape anyway for symmetry with the other
                    # _esc variables above.
                    _imessage_fda_icon_path_esc="${_imessage_fda_icon_path//\"/\\\"}"
                    _imessage_fda_icon_clause="with icon file POSIX file \"${_imessage_fda_icon_path_esc}\""
                else
                    _imessage_fda_icon_clause="with icon note"
                fi
                # CX-66 z-order fix: System Settings was opened above, so
                # without an explicit `activate` the dialog would render
                # behind it. Wrapping the display dialog inside a
                # `tell application "System Events"` block + activate
                # brings the modal to the front of every other window
                # so the customer can't miss it. We also pause briefly
                # before display to let System Settings finish its
                # window animation -- racing a half-rendered Settings
                # pane was the original z-order risk.
                sleep 1
                osascript \
                    -e 'tell application "System Events" to activate' \
                    -e "tell application \"System Events\" to display dialog \"${_imessage_fda_dialog_msg_esc}\" with title \"${_imessage_fda_title_esc}\" buttons {\"${_imessage_fda_button_esc}\"} default button \"${_imessage_fda_button_esc}\" ${_imessage_fda_icon_clause}" \
                    >/dev/null 2>&1 || true
                unset _imessage_fda_dialog_msg _imessage_fda_dialog_msg_esc \
                      _imessage_fda_title_esc _imessage_fda_button_esc \
                      _imessage_fda_icon_path _imessage_fda_icon_path_esc \
                      _imessage_fda_icon_clause

                # Re-probe the daemon's actual TCC posture (CX-90):
                # what matters for the customer's downstream
                # experience is whether the *daemon* now holds Full
                # Disk Access, not whether install.sh's own identity
                # can read chat.db. Re-run the same daemon-identity
                # TCC query used at the top of this block so the
                # re-probe and the initial test agree on what
                # "granted" means. Imperfect timing (TCC.db can lag a
                # second after the grant) is covered by the Doctor
                # card's live re-probe (status_collector +
                # check_imessage_fda) on next refresh.
                sleep 2
                if [[ "$(_imessage_daemon_fda_granted)" == "granted" ]]; then
                    _imessage_fda_needed="false"
                    info "$MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED"
                    # Kick the assistant LaunchAgent to pick up the
                    # new FDA grant. launchctl kickstart -k restarts
                    # the agent without un/re-loading, so the new
                    # TCC posture takes effect immediately.
                    launchctl kickstart -k "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
                else
                    info "$MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED"
                    # (mid-install permission-glut fix) Drag-add fallback:
                    # only NOW, after the modal is dismissed AND the grant
                    # still didn't land, reveal the daemon .app bundle in
                    # Finder so the customer can drag it straight into the
                    # still-open Full Disk Access list. Fired here -- never
                    # concurrently with the modal -- it is the last-resort
                    # path for the rare case where "Find Ostler and turn it
                    # on" did not work (e.g. the daemon had not yet been
                    # listed). The persistent Doctor card still backstops
                    # this on the next refresh.
                    open -R "$ASSISTANT_APP_BUNDLE" 2>/dev/null || true
                fi
                fi  # closes inner `if OSTLER_GUI` (CX-78c nesting)
            fi  # closes `if true` assist wrapper (CX-90 reorder)
        fi
    else
        # No chat.db on this Mac at all (e.g. Messages.app never
        # signed in to iMessage). Card would be a false positive --
        # default to false so it stays quiet.
        _imessage_fda_needed="false"
        info "$MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED"
    fi

    # Re-resolve the writer + sidecar path. The mail-content probe
    # already mkdir'd PIPELINE_SIGNALS_DIR earlier in Phase 3, but
    # that scope unset the variables. Resolve fresh + idempotently.
    _imessage_pipeline_dir="${OSTLER_DIR}/state"
    _imessage_pipeline_file="${_imessage_pipeline_dir}/pipeline_signals.json"
    mkdir -p "$_imessage_pipeline_dir" \
        || _imessage_fda_probe_failure_line="mkdir state dir"

    _imessage_writer=""
    if [[ -n "${OSTLER_PIPELINE_SIGNALS_WRITER:-}" \
          && -f "${OSTLER_PIPELINE_SIGNALS_WRITER}" ]]; then
        _imessage_writer="${OSTLER_PIPELINE_SIGNALS_WRITER}"
    elif [[ -f "${SCRIPT_DIR}/lib/write_pipeline_signals.py" ]]; then
        _imessage_writer="${SCRIPT_DIR}/lib/write_pipeline_signals.py"
    elif [[ -f "${HOME}/.ostler/lib/write_pipeline_signals.py" ]]; then
        _imessage_writer="${HOME}/.ostler/lib/write_pipeline_signals.py"
    fi

    if [[ -n "$_imessage_writer" ]]; then
        if ! python3 "$_imessage_writer" \
                --output "$_imessage_pipeline_file" \
                --imessage-fda-needed "$_imessage_fda_needed"; then
            warn "$MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED"
        fi
    else
        warn "$MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED"
    fi

    unset _imessage_chat_db_path _imessage_fda_needed \
          _imessage_pipeline_dir _imessage_pipeline_file _imessage_writer
fi

set -e
if [[ -n "$_imessage_fda_probe_failure_line" ]]; then
    warn "iMessage FDA probe: non-fatal failure at: $_imessage_fda_probe_failure_line"
fi
unset _imessage_fda_probe_failure_line

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

OSTLER_REMOTECAPTURE_VERSION="${OSTLER_REMOTECAPTURE_VERSION:-0.1.1}"
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
        fail_with_code "ERR-24-CM042-SHA-MISMATCH" "$MSG_FAIL_CM042_SIGNATURE_FAILED"
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

        # CX-36 (2026-05-24, Studio retest #22): the upstream tarball at
        # ostler-ai/ostler-releases/remote-capture-v0.1.0 contains
        # `RemoteCapture.app/` at the root, NOT `Ostler RemoteCapture.app/`
        # as install.sh originally expected. Rather than re-cut the upstream
        # release (which would require coordinating the CM042 build pipeline
        # rename), rename the extracted bundle locally on the customer Mac.
        # The Info.plist CFBundleName still reads "RemoteCapture" -- that is
        # a separate branding follow-up. v1.0 just needs the install to
        # complete; bundle filename match (REMOTECAPTURE_APP_PATH) is what
        # subsequent codesign/spctl/LaunchAgent steps key off.
        if [[ ! -d "$REMOTECAPTURE_APP_PATH" ]] && [[ -d "/Applications/RemoteCapture.app" ]]; then
            mv "/Applications/RemoteCapture.app" "$REMOTECAPTURE_APP_PATH" 2>/dev/null \
                || sudo mv "/Applications/RemoteCapture.app" "$REMOTECAPTURE_APP_PATH" 2>/dev/null \
                || true
        fi

        if [[ ! -d "$REMOTECAPTURE_APP_PATH" ]]; then
            err "$(printf "$MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT" "${REMOTECAPTURE_APP_PATH}")"
            if [[ -s "${REMOTECAPTURE_TMPDIR}/tar.log" ]]; then
                sed -e 's/^/    /' "${REMOTECAPTURE_TMPDIR}/tar.log" | head -5
            fi
            # CX-36: dump what /Applications actually has so the customer
            # log shows whether tar landed nothing, or landed with a name
            # we did not expect (different layout in a future release).
            echo "    /Applications/ entries matching RemoteCapture:"
            ls -la "/Applications/" 2>/dev/null | grep -i "remote\|ostler" | sed -e 's/^/      /'
            rm -rf "$REMOTECAPTURE_TMPDIR"
            REMOTECAPTURE_TMPDIR=""
            fail_with_code "ERR-24-CM042-EXTRACT" "$MSG_FAIL_CM042_SIGNATURE_FAILED"
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
            fail_with_code "ERR-24-CM042-SIGNATURE" "$MSG_FAIL_CM042_SIGNATURE_FAILED"
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

# CX-76 (DMG #44, 2026-05-25): when a DMG-bundled Ostler.app is
# available, prefer it ABSOLUTELY over any pre-existing copy at
# $HUB_APP_DEST. The previous order set HUB_APP_SOURCE = HUB_APP_DEST
# whenever /Applications/Ostler.app existed, which left customers
# running stale binaries across re-installs -- DMG #43 retest landed
# the CX-72 port fix in a new Tauri bundle, but install.sh skipped
# the staging step and the old Ostler.app survived. That hid CX-72
# behind a manual swap. New order: SCRIPT_DIR > parent dir > existing
# install. The "existing install" fallback only fires for re-runs
# without a DMG (e.g. install.sh --repair from ~/.ostler/) so we keep
# verifying the in-place copy rather than failing the customer.
if [[ -d "${SCRIPT_DIR}/Ostler.app" ]]; then
    HUB_APP_SOURCE="${SCRIPT_DIR}/Ostler.app"
elif [[ -d "${SCRIPT_DIR}/../Ostler.app" ]]; then
    HUB_APP_SOURCE="${SCRIPT_DIR}/../Ostler.app"
elif [[ -d "$HUB_APP_DEST" ]]; then
    HUB_APP_SOURCE="$HUB_APP_DEST"
fi

if [[ -n "$HUB_APP_SOURCE" ]]; then
    # Stage into /Applications when the source is not already there.
    # Pre-existing install: kill the running process (so the bundle
    # is not in use), then remove + copy. Sudo fallback for the rare
    # corporate-imaged Mac where /Applications is admin-owned.
    if [[ "$HUB_APP_SOURCE" != "$HUB_APP_DEST" ]]; then
        info "$(printf "$MSG_INFO_HUB_APP_STAGING" "${HUB_APP_SOURCE}")"
        if [[ -d "$HUB_APP_DEST" ]]; then
            # CX-76: kill any running Ostler.app instance before
            # overwriting. Without this the cp/rm races against the
            # live process and can leave a half-replaced bundle.
            pkill -f "${HUB_APP_DEST}/Contents/MacOS" 2>/dev/null || true
            sleep 0.5
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
#
# CX-81 Tailscale step (2026-05-26):
#   - Dedicated full-screen GUI view (TailscaleConnectView.swift) with
#     two big buttons + collapsible mini-FAQ, dispatched from
#     OnboardingQuestionView when prompt id is "tailscale_connect".
#   - STEP_BEGIN emission so the sidebar progress shows a dedicated row.
#   - Root-cause fix: was `open -gj -a Tailscale` (LAUNCH HIDDEN) so
#     the sign-in window never appeared for first-time users. Now
#     `open -a Tailscale` brings the window to the foreground.
#   - Periodic 30-second progress updates inside the 180-second
#     IP-detection loop so the customer sees the installer is alive.
#   - Post-write .env verification (grep) so a silent persist failure
#     no longer leaves the iOS Companion unreachable.

progress "Connect your iPhone and Watch" "tailscale_connect"

OSTLER_TAILSCALE_IP=""

# WALK-1 (Wave 2.1): the setup/skip DECISION is now collected upfront in
# the Phase-2 questions block (search "10b-ts. Tailscale DECISION") and
# carried here via TAILSCALE_CONFIRM + TAILSCALE_CONFIRM_SHOWN_EARLY, so
# the autonomous middle never surfaces a surprise prompt. Only if the
# early prompt did NOT run (e.g. Phase 2 was skipped on a reuse install,
# or the GUI was off then on) do we fall back to asking here -- the same
# belt-and-braces shape the Mail probes use. The actual install + browser
# sign-in below was pre-announced in Phase 2.
if [[ -z "${TAILSCALE_CONFIRM_SHOWN_EARLY:-}" ]]; then
    TAILSCALE_CONFIRM="$(gui_read "$MSG_PROMPT_TAILSCALE_CONFIRM_TITLE" choice "setup" "$MSG_PROMPT_TAILSCALE_CONFIRM_HELP" "setup,skip" "tailscale_confirm")"
fi

if [[ "${TAILSCALE_CONFIRM:-setup}" == "setup" ]]; then
    # ── Path A: Homebrew FORMULA + userspace networking (#604) ──────
    #
    # #604 (2026-06-02, Studio v1.0.0 install): `brew install --cask
    # tailscale` now resolves to the `tailscale-app` GUI cask (1.98.x),
    # which ships a kernel/system extension and a sudo-driven `.pkg`.
    # The installer's non-interactive sudo cannot complete that pkg (it
    # also needs an interactive System Settings extension approval), so
    # `installer -pkg ... exited with 1`, the step only warned, and the
    # install finished with Tailscale absent and never launched. (NOT
    # the old CX-25/CX-105 shallow-brew git-history issue, which is
    # fixed -- the cask resolves and downloads fine now.)
    #
    # Fix: the `tailscale` FORMULA instead. It is the CLI + tailscaled
    # with no kext and no .app, so it installs headless with no sudo.
    # We run tailscaled in userspace-networking mode (--tun=userspace-
    # networking: no TUN device, no kernel extension, no root) under a
    # per-user LaunchAgent, authenticate with `tailscale up`, and use
    # `tailscale serve` to expose the Hub's local ports on the tailnet
    # so the iOS Companion reaches this Mac off-LAN -- all without any
    # system-extension approval the installer cannot drive.
    #
    # CONSTRAINT (Studio gate, not yet proven here): userspace mode does
    # not route the tailnet IP to local services at the OS layer the way
    # kernel mode does; inbound reach depends on `tailscale serve`
    # proxying each port. This must be proven to carry real inbound
    # iPhone->Hub traffic before Path A is declared done (see PR body).
    TS_STATE_DIR="${OSTLER_DIR}/tailscale"
    TS_SOCK="${TS_STATE_DIR}/tailscaled.sock"
    mkdir -p "$TS_STATE_DIR"

    if ! command -v tailscale &>/dev/null; then
        info "$MSG_INFO_INSTALLING_TAILSCALE"
        if brew install tailscale 2>&1; then
            ok "$MSG_OK_TAILSCALE_INSTALLED"
        else
            warn "$MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL"
            OSTLER_TAILSCALE_SKIPPED=1
        fi
    else
        ok "$MSG_OK_TAILSCALE_ALREADY_INSTALLED"
    fi

    TS_CLI="$(command -v tailscale || true)"
    TS_DAEMON="$(command -v tailscaled || true)"

    if [[ -n "$TS_CLI" && -n "$TS_DAEMON" ]]; then
        # ── Userspace tailscaled under a per-user LaunchAgent ───────
        # --tun=userspace-networking: no TUN, no kext, no root. State +
        # socket live under the user's ~/.ostler so the CLI (run as the
        # same user) reaches them via --socket. KeepAlive keeps the
        # tailnet up across reboots.
        TS_LAUNCH_AGENT="${HOME}/Library/LaunchAgents/com.creativemachines.ostler.tailscaled.plist"
        mkdir -p "${HOME}/Library/LaunchAgents" "$LOGS_DIR"
        cat > "$TS_LAUNCH_AGENT" <<TSPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.creativemachines.ostler.tailscaled</string>
    <key>ProgramArguments</key>
    <array>
        <string>${TS_DAEMON}</string>
        <string>--tun=userspace-networking</string>
        <string>--state=${TS_STATE_DIR}/tailscaled.state</string>
        <string>--statedir=${TS_STATE_DIR}</string>
        <string>--socket=${TS_SOCK}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/tailscaled.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/tailscaled.err</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
TSPLIST
        chmod 0644 "$TS_LAUNCH_AGENT"
        launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.tailscaled" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$TS_LAUNCH_AGENT" 2>/dev/null; then
            ok "$MSG_OK_TAILSCALED_USERSPACE_STARTED"
        else
            warn "$MSG_WARN_TAILSCALED_USERSPACE_START_FAILED"
        fi
        # Wait for the daemon to create its control socket (max ~15s).
        TS_SOCK_WAIT=0
        while [[ ! -S "$TS_SOCK" && $TS_SOCK_WAIT -lt 15 ]]; do
            sleep 1; TS_SOCK_WAIT=$((TS_SOCK_WAIT + 1))
        done

        # ── Browser auth: `tailscale up` prints a login URL ─────────
        # No GUI app to click, so capture the URL tailscale prints and
        # open it in the default browser. up runs in the background so
        # the installer can poll for the assigned IP while the customer
        # completes OAuth.
        info "$MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN"
        TS_UP_LOG="${LOGS_DIR}/tailscale-up.log"
        # TS_SAFARI_WARM (2026-06-09): start warming Safari HERE, before
        # `tailscale up` and the URL-poll loop below, so the browser gets
        # the entire 2-30s poll window to finish a cold launch instead of
        # the fixed 2s the old code allowed at delivery time. Under heavy
        # fresh-install load (Colima + Ollama + importer) Safari's cold
        # start routinely outran that 2s, so the open-URL event landed on
        # a still-bouncing Safari and was dropped (~40% on a clean Mac --
        # the prior #644 mitigation reduced but did not close this race).
        # Priming during the already-existing wait costs nothing.
        # Best-effort, backgrounded (-g) so it does not steal focus.
        open -g -a Safari >/dev/null 2>&1 || true
        # Register the Hub under a stable, predictable tailnet name so the
        # iOS app can always reach it at ostler-hub.<tailnet>.ts.net,
        # regardless of the customer's Mac hostname. Without --hostname,
        # the node inherits the Mac's local name (random per customer).
        # Tailscale auto-suffixes (-1, -2) only on a collision within the
        # same tailnet, which a single-Hub customer tailnet will not hit.
        ( "$TS_CLI" --socket="$TS_SOCK" up --hostname=ostler-hub >"$TS_UP_LOG" 2>&1 || true ) &
        # Surface + open the login URL once tailscale prints it.
        TS_URL=""
        TS_URL_WAIT=0
        while [[ -z "$TS_URL" && $TS_URL_WAIT -lt 30 ]]; do
            TS_URL="$(grep -Eo 'https://login\.tailscale\.com/[a-zA-Z0-9/._-]+' "$TS_UP_LOG" 2>/dev/null | head -1 || true)"
            [[ -n "$TS_URL" ]] && break
            # Already authenticated installs print no URL; stop waiting
            # once an IP exists.
            [[ -n "$("$TS_CLI" --socket="$TS_SOCK" ip --4 2>/dev/null | head -1 || true)" ]] && break
            sleep 2; TS_URL_WAIT=$((TS_URL_WAIT + 2))
        done
        if [[ -n "$TS_URL" ]]; then
            # The URL is ALWAYS surfaced as plain text first (via info,
            # which the GUI renders in its log pane), so the copy/paste
            # sign-in path never depends on a browser launching at all.
            info "$(printf "$MSG_INFO_TAILSCALE_SIGN_IN_URL" "$TS_URL")"
            # Auto-open is best-effort. A bare `open <url>` against a
            # COLD-launching browser intermittently drops the open-URL
            # Apple event -- or wedges Safari outright -- under the heavy
            # CPU/IO load of a fresh install (Colima VM + Ollama + the
            # importer all running). Observed ~1 in 4 on a clean Mac with
            # the prior fixed-2s-sleep mitigation; still seen ~40%.
            # Safari was already warmed above (before the URL-poll loop),
            # so it has had the full poll window to finish launching.
            # Deliver the URL via Safari specifically and ATOMICALLY:
            # `open -a Safari <url>` hands LaunchServices a single
            # launch-if-needed-THEN-open-URL request, so it cannot fire
            # the URL at a half-launched Safari the way the old bare
            # `open <url>` (a separate LS request racing the launch) did.
            # Fall back to the default-handler form if Safari is somehow
            # unavailable, then re-issue once in the background as a
            # dropped-event safety net. The URL is also printed as plain
            # text above, so copy/paste always works even if every
            # auto-open is dropped.
            open -a Safari "$TS_URL" >/dev/null 2>&1 || open "$TS_URL" >/dev/null 2>&1 || true
            ( sleep 4; open -a Safari "$TS_URL" >/dev/null 2>&1 || true ) &
        fi

        # 180s window: a non-technical user reading the prompt, opening
        # the login URL, completing OAuth (Apple/Google/Microsoft with
        # possible 2FA) and returning easily eats 2-3 minutes.
        info "$MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3"
        TS_WAIT=0
        TS_NEXT_TICK=30
        while [[ -z "$OSTLER_TAILSCALE_IP" && $TS_WAIT -lt 180 ]]; do
            OSTLER_TAILSCALE_IP=$("$TS_CLI" --socket="$TS_SOCK" ip --4 2>/dev/null | head -1 || true)
            if [[ -z "$OSTLER_TAILSCALE_IP" ]]; then
                sleep 3
                TS_WAIT=$((TS_WAIT + 3))
                if [[ $TS_WAIT -ge $TS_NEXT_TICK ]]; then
                    info "$(printf "$MSG_INFO_TAILSCALE_STILL_WAITING" "$TS_WAIT")"
                    TS_NEXT_TICK=$((TS_NEXT_TICK + 30))
                fi
            fi
        done

        if [[ -n "$OSTLER_TAILSCALE_IP" ]]; then
            # ── Expose the Hub's local ports on the tailnet ─────────
            # In userspace mode the tailnet IP does not reach local
            # listeners without an explicit proxy, so serve each Hub
            # port: 8089 (Doctor API the iOS Companion uses) and 8044
            # (the wiki). --bg keeps the forwarder running after the
            # installer exits. Best-effort: a serve failure is surfaced
            # but does not fail the install (on-LAN pairing still works).
            for _ts_port in 8089 8044; do
                if "$TS_CLI" --socket="$TS_SOCK" serve --bg --tcp="$_ts_port" "tcp://localhost:${_ts_port}" >/dev/null 2>&1; then
                    info "$(printf "$MSG_INFO_TAILSCALE_SERVE_PORT" "$_ts_port")"
                else
                    warn "$(printf "$MSG_WARN_TAILSCALE_SERVE_PORT_FAILED" "$_ts_port")"
                fi
            done
            unset _ts_port
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
                # CX-81 Tailscale step verify (2026-05-26): grep the
                # written value back so a silent persist failure (e.g.
                # .env permission flip, partial mv) is caught rather
                # than leaving the iOS Companion unreachable.
                if grep -q "^OSTLER_TAILSCALE_IP=\"${OSTLER_TAILSCALE_IP}\"" "$ENV_FILE"; then
                    ok "$MSG_OK_TAILSCALE_ENV_PERSISTED"
                else
                    warn "$MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED"
                fi
            fi
        else
            warn "$MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN"
            warn "$MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED"
        fi
    else
        warn "$MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU"
    fi
else
    info "$MSG_INFO_TAILSCALE_SKIPPED"
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

# ── 3.X HYDRATE GRAPH (CX-81 B1) ──────────────────────────────────
#
# Populate the personal graph from local Apple-side sources BEFORE
# the first wiki compile so the customer's Hub opens onto a wiki
# with People + Timeline already populated (not empty).
#
# Two parallel-safe imports:
#   1. Contacts -- from the iCloud Contacts vCard export written
#      earlier (${OSTLER_DIR}/imports/icloud-contacts.vcf). The
#      contact_syncer.syncer CLI was extended (CX-81 B1 / CM041 PR
#      #30) with a --vcf <path> flag plus a single-line JSON status
#      emitter on stdout. install.sh parses ``.imported`` for the
#      customer-visible count.
#   2. Calendar -- via the ical-server (already running by this
#      phase: Phase 3.8 brought up the graph DBs + Phase 3.X-1
#      started the assistant_api launchd agent). meeting_syncer
#      backfills the last 90 days of events with attendees.
#
# Behaviour on edge cases (per CX-81 B1 AC4):
#   - vcf missing / empty -> emit MSG_HYDRATE_SKIPPED_NO_CONTACTS,
#     continue. Install does NOT fail.
#   - ical-server unreachable / zero events -> emit
#     MSG_HYDRATE_SKIPPED_NO_EVENTS, continue.
#   - syncer raises -> log the failure, continue. The wiki_compile
#     that follows still runs and emits a skeleton wiki.
#
# Privacy: both syncers are local-only. No network calls leave the
# customer's Mac. Contact data + calendar data are read locally
# (vCard file + localhost ical-server) and written locally
# (Oxigraph at :7878, Qdrant at :6333). No telemetry of volumes.

progress "Hydrating your graph from iCloud" "hydrate_graph"

# #48g historical backfill idempotency (CX-84/85/86, 2026-05-29).
# Each per-source hydrate_* block drops a sentinel file once it
# completes (success or no-data both count -- the customer choice was
# honoured + we ran the path). A subsequent install.sh re-run skips
# the hydrate block when the sentinel is fresh, so the customer's
# graph is not double-emitted with a second copy of every Person
# triple. The sentinel TTL is 7 days so a manual "redo my install"
# (rare) still picks up new data; the Doctor source-repair flow
# bypasses install.sh entirely.
_HYDRATE_SENTINEL_DIR="${OSTLER_DIR}/state/hydrate"
mkdir -p "$_HYDRATE_SENTINEL_DIR"

# Returns 0 if the sentinel for $1 is present + fresher than 7 days.
# Use as: if _hydrate_sentinel_fresh imessage; then continue; fi
_hydrate_sentinel_fresh() {
    local sentinel="${_HYDRATE_SENTINEL_DIR}/$1.done"
    [[ -f "$sentinel" ]] || return 1
    # macOS stat: -f%m yields unix mtime
    local mtime now age
    mtime=$(stat -f%m "$sentinel" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    # 7 days = 604800s. Sentinel older than that -> re-run.
    [[ "$age" -lt 604800 ]]
}

# Records the sentinel + a single-line JSON payload with whatever the
# hydrate step produced (count, status, etc). The payload is
# customer-local; we never log its contents off-machine.
# Use as: _hydrate_sentinel_record imessage '{"people":123,"status":"ok"}'
_hydrate_sentinel_record() {
    local source="$1"
    local payload="${2:-}"
    local sentinel="${_HYDRATE_SENTINEL_DIR}/${source}.done"
    {
        printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'source=%s\n' "$source"
        if [[ -n "$payload" ]]; then
            printf 'payload=%s\n' "$payload"
        fi
    } > "$sentinel"
}

# Progress heartbeat for the long-running hydrate phases.
#
# Even with the gtimeout cap in place (coreutils installed in Phase
# 3.1b), a single hydrate step can legitimately churn for many minutes
# on a Mac with years of history. Without a periodic progress line the
# GUI sidebar row sits silent and reads as a frozen install. These two
# helpers bracket the blocking ingest command-sub with a backgrounded
# ticker that emits one progress line every _HYDRATE_HEARTBEAT_EVERY_S
# seconds. Host-tooling-independent (pure bash + sleep), so it works
# whether or not gtimeout is present.
#
# Usage:
#   _hydrate_heartbeat_start "$MSG_HYDRATE_IMESSAGE_HEARTBEAT"
#   ...blocking ingest command-sub...
#   _hydrate_heartbeat_stop
_HYDRATE_HEARTBEAT_EVERY_S="${OSTLER_HYDRATE_HEARTBEAT_EVERY_S:-30}"
_HYDRATE_HEARTBEAT_PID=""
_hydrate_heartbeat_start() {
    local msg="${1:-}"
    [[ -n "$msg" ]] || return 0
    # Disable job-control chatter for the backgrounded ticker.
    (
        local waited=0
        while true; do
            sleep "$_HYDRATE_HEARTBEAT_EVERY_S"
            waited=$((waited + _HYDRATE_HEARTBEAT_EVERY_S))
            info "$(printf "$msg" "$waited")"
        done
    ) &
    _HYDRATE_HEARTBEAT_PID=$!
}
_hydrate_heartbeat_stop() {
    [[ -n "$_HYDRATE_HEARTBEAT_PID" ]] || return 0
    kill "$_HYDRATE_HEARTBEAT_PID" >/dev/null 2>&1 || true
    wait "$_HYDRATE_HEARTBEAT_PID" 2>/dev/null || true
    _HYDRATE_HEARTBEAT_PID=""
}

# ── Deferred whole-graph dedupe converge (v1.0.2, P0) ─────────────
#
# Installs a bounded, self-removing LaunchAgent that finishes the
# identity-resolver converge pass in the BACKGROUND after install, so the
# install critical path is never blocked for the ~25-60 min a full
# converge can take on a large address book. Modelled byte-for-byte on
# the wiki-recompile catch-up agent (3.14d-bis): a wrapper that runs the
# pass to completion (via the same `--execute --converge` fixpoint the
# install used), writes a .done marker so it can self-remove, triggers a
# wiki recompile so late merges surface, and boots out its own agent once
# the converge completes (or a try-cap is hit so it can never loop
# forever). Reuses the wiki-recompile-tick.sh that already exists; adds
# NO new merge logic. Non-fatal throughout: a failed agent just leaves
# the daily recompile + the resolver's own incremental passes to catch up.
#
# Called from the install-time converge block ONLY when that block did
# not fully complete within the install budget (no .done marker). When
# the install pass already converged, this agent is never installed.
_install_dedupe_catchup_agent() {
    local label="com.creativemachines.ostler.dedupe-catchup"
    local plist="${HOME}/Library/LaunchAgents/${label}.plist"
    local interval_s="${OSTLER_DEDUPE_CATCHUP_INTERVAL_S:-600}"
    local max_tries="${OSTLER_DEDUPE_CATCHUP_MAX_TRIES:-12}"
    local wrapper="${OSTLER_DIR}/bin/ostler-dedupe-catchup"

    mkdir -p "${OSTLER_DIR}/bin" "${HOME}/Library/LaunchAgents" 2>/dev/null || true

    # Self-removing, bounded catch-up wrapper. Single-quoted heredoc: no
    # install-time expansion -- it resolves OSTLER_DIR / PIPELINE_DIR at
    # run time, exactly like ostler-wiki-recompile-catchup does. The
    # PIPELINE_DIR location is the resolver's home; resolve it the same
    # way the install body does (it lives under the assistant pipeline).
    cat > "$wrapper" <<'DCUEOF'
#!/usr/bin/env bash
set -euo pipefail

OSTLER_DIR="${HOME}/.ostler"
LOGS_DIR="${OSTLER_DIR}/logs"
STATE_DIR="${OSTLER_DIR}/state"
LABEL="com.creativemachines.ostler.dedupe-catchup"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
TRIES_FILE="${STATE_DIR}/dedupe-catchup.tries"
DONE_MARKER="${STATE_DIR}/dedupe-converge.done"
LOG_FILE="${LOGS_DIR}/dedupe-catchup.log"
MAX_TRIES="${OSTLER_DEDUPE_CATCHUP_MAX_TRIES:-12}"
PIPELINE_DIR="${OSTLER_PIPELINE_DIR:-${OSTLER_DIR}/import-pipeline}"
TICK="${OSTLER_DIR}/bin/wiki-recompile-tick.sh"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

remove_self() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TRIES_FILE"
}

# Already converged (install finished it, or a previous tick did): nothing
# left to do; remove the agent.
if [[ -f "$DONE_MARKER" ]]; then
    log "converge already complete (.done present); removing catch-up agent"
    remove_self
    exit 0
fi

# Bounded run counter so a perpetually-failing converge can never loop
# forever. The resolver's own incremental passes + the daily recompile
# remain the long-term steady state.
tries=0
[[ -f "$TRIES_FILE" ]] && tries="$(cat "$TRIES_FILE" 2>/dev/null || echo 0)"
[[ "$tries" =~ ^[0-9]+$ ]] || tries=0
tries=$((tries + 1))
printf '%s' "$tries" >"$TRIES_FILE"
if [[ "$tries" -gt "$MAX_TRIES" ]]; then
    log "dedupe catch-up gave up after ${MAX_TRIES} ticks; removing agent (daily recompile + incremental resolve continue)"
    remove_self
    exit 0
fi

if [[ ! -d "$PIPELINE_DIR/identity_resolver" || ! -x "$PIPELINE_DIR/.venv/bin/python3" ]]; then
    log "resolver not found at ${PIPELINE_DIR}; removing dedupe catch-up agent"
    remove_self
    exit 0
fi

log "dedupe catch-up tick ${tries}/${MAX_TRIES}: finishing whole-graph converge"
# Same fixpoint pass the install used. --converge is idempotent: if the
# graph is already merged it does one detect round, finds nothing, and
# exits cleanly -> we mark done and remove ourselves.
if ( cd "$PIPELINE_DIR" && \
     OXIGRAPH_URL="${OXIGRAPH_URL:-http://localhost:7878}" \
     QDRANT_URL="${QDRANT_URL:-http://localhost:6333}" \
     .venv/bin/python3 -m identity_resolver.batch_resolver \
         --execute --converge \
         --output /tmp/ostler-dedupe-report.yaml \
   ) >>"$LOG_FILE" 2>&1; then
    log "converge completed cleanly; marking done + triggering wiki recompile"
    : >"$DONE_MARKER"
    if [[ -x "$TICK" ]]; then
        "$TICK" >>"$LOG_FILE" 2>&1 || log "post-converge wiki recompile returned non-zero; daily agent will catch up"
    fi
    remove_self
    exit 0
else
    log "converge tick ${tries} returned non-zero; will retry on next interval"
    exit 0
fi
DCUEOF
    chmod +x "$wrapper"

    cat > "$plist" <<DCUPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${wrapper}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>OSTLER_DEDUPE_CATCHUP_MAX_TRIES</key>
        <string>${max_tries}</string>
        <key>OSTLER_PIPELINE_DIR</key>
        <string>${PIPELINE_DIR}</string>
    </dict>
    <key>StartInterval</key>
    <integer>${interval_s}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/dedupe-catchup.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/dedupe-catchup.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
DCUPLIST
    chmod 0644 "$plist"

    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || \
       launchctl load "$plist" 2>/dev/null; then
        ok "$MSG_OK_DEDUPE_CATCHUP_LOADED"
    else
        warn "$MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED"
    fi
}

_HYDRATE_VCF="${OSTLER_DIR}/imports/icloud-contacts.vcf"
_HYDRATE_API="${PWG_ICAL_SERVER_URL:-http://localhost:8089}"
_HYDRATE_OXIGRAPH="${OXIGRAPH_URL:-http://localhost:7878}"
_HYDRATE_PIPELINE_PY="${PIPELINE_DIR}/.venv/bin/python"

# CX-92/93/94 (DMG #48g, 2026-05-29): historical-data backfill windows.
# Pre-fix the calendar pulled 90 days and the email pulled 30 days,
# so a customer with multi-year mail / calendar history saw an
# almost-empty wiki on install completion + a long tail of "Doctor
# is still backfilling" warnings for weeks afterwards. Bumping to
# 5 years gets the customer onto a fully-populated wiki within the
# install window. The values are env-overridable so a customer with
# a constrained / slow Mac can still narrow the window from the
# install command line. 5 years = 1825 days as a constant so we
# don't drift on leap years.
OSTLER_HYDRATE_BACKFILL_DAYS="${OSTLER_HYDRATE_BACKFILL_DAYS:-1825}"

# Schedule the self-removing contact re-sync agent. Called from the
# pending-state branches below (accounts configured but the import came
# back empty -- iCloud had not finished its first contact sync inside the
# install window). The agent fires every CONTACT_RESYNC_INTERVAL_S seconds
# and runs bin/ostler-contact-resync, which re-reads the now-synced local
# AddressBook (FDA fallback) and removes its own agent once contacts land.
# Idempotent: if the plist already exists we leave it (it self-removes on
# success), so two pending branches firing never double-schedule.
_schedule_contact_resync() {
    local plist="${HOME}/Library/LaunchAgents/com.ostler.contact-resync.plist"
    local interval_s="${CONTACT_RESYNC_INTERVAL_S:-1800}"
    [[ -f "$plist" ]] && return 0
    [[ -x "${OSTLER_DIR}/bin/ostler-contact-resync" ]] || return 0
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$plist" <<CRSPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.contact-resync</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/bin/ostler-contact-resync</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval_s}</integer>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/contact-resync.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/contact-resync.err</string>
</dict>
</plist>
CRSPLIST
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || \
        launchctl load "$plist" 2>/dev/null || true
    info "$MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED"
}

# Contact hydration ------------------------------------------------
#
# CX-453 (task #453, v1.0.1): read contacts through the Full-Disk-Access
# AddressBook store (the abcddb fallback), NOT a Contacts.app osascript
# export. The osascript re-export here used to fire the AppleEvent
# Automation prompt (blue "wants to control Contacts"); we removed it so
# the customer never sees that second prompt. The same applies to the
# Phase-2 me-card site, which no longer reads Contacts at all.
#
# This is the moment the contacts actually reach the graph (the Phase-2
# VCF export was dropped, so there is no pre-written vcf): by hydrate
# (post-FDA-grant, post-encrypt, post-Docker = several minutes in) iCloud
# has typically finished its first contact sync, so the local
# AddressBook-v22.abcddb is populated. We force contact_syncer onto that
# abcddb read by pointing --vcf at a path we never create -- the same
# proven pattern bin/ostler-contact-resync uses. NO Automation prompt;
# only the Full Disk Access the installer already pre-warmed and granted.
mkdir -p "$(dirname "$_HYDRATE_VCF")"

# State-2 nudge: if accounts are configured but the local AB has no rows
# yet (iCloud still syncing), offer to open Contacts.app so the sync
# kicks. GUI-only; never an osascript Contacts read.
_hydrate_contacts_accounts="$(_accountsdb_count_contacts)"
_hydrate_contacts_accounts="${_hydrate_contacts_accounts:-0}"
if [[ "$_hydrate_contacts_accounts" -gt 0 ]] \
   && ! _store_populated_contacts \
   && [[ "${OSTLER_GUI:-0}" == "1" ]]; then
    _open_contacts_help="$(printf "$MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP" "${_hydrate_contacts_accounts}")"
    _three_state_wait_for_populate \
        "contacts" \
        "Contacts" \
        "" \
        "$MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE" \
        "$_open_contacts_help" || true
    unset _open_contacts_help
fi

if [[ -x "$_HYDRATE_PIPELINE_PY" ]]; then
    info "$MSG_HYDRATE_CONTACTS_STARTED"
    # Force the AddressBook-v22.abcddb fallback: point --vcf at a path we
    # never create, so contact_syncer.syncer logs "vCard file not found"
    # and reads the local AddressBook directly (Full Disk Access only, no
    # Automation). It emits a single-line JSON status on stdout; progress
    # goes to stderr so the final stdout line is parseable.
    _HYDRATE_FORCE_ABCDDB_VCF="${OSTLER_DIR}/imports/.hydrate-force-abcddb.vcf"
    rm -f "$_HYDRATE_FORCE_ABCDDB_VCF" 2>/dev/null || true
    _HYDRATE_CONTACTS_JSON="$(
        cd "$PIPELINE_DIR" && \
        "$_HYDRATE_PIPELINE_PY" -m contact_syncer.syncer \
            --vcf "$_HYDRATE_FORCE_ABCDDB_VCF" \
            --graph-endpoint "$_HYDRATE_OXIGRAPH" 2>>/tmp/ostler-hydrate-contacts.log \
        | tail -n 1
    )" || _HYDRATE_CONTACTS_JSON=""
    _HYDRATE_CONTACTS_COUNT="$(
        printf '%s' "$_HYDRATE_CONTACTS_JSON" \
        | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("imported", 0)))
except Exception:
    print(0)' 2>/dev/null
    )"
    _HYDRATE_CONTACTS_COUNT="${_HYDRATE_CONTACTS_COUNT:-0}"

    # FDA is the ONLY permission this path needs. Read the conservative
    # Phase-4 result; treat anything other than an explicit "true" that
    # comes with a 0-count as a denial worth surfacing (default to "true"
    # only so an unset var on some path cannot wrongly cry "denied").
    if [[ "$_HYDRATE_CONTACTS_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CONTACTS_DONE" "$_HYDRATE_CONTACTS_COUNT")"
        # EMAIL-COVERAGE GUARD (post-hydrate): contacts landed, but a
        # phone-only export looks identical to success at the count level.
        # The card->email coverage bug (card->phone ~97%, card->email ~1%)
        # shipped silently for exactly this reason. Compare phone vs email
        # identifier counts in the graph and warn LOUDLY when phones are
        # plentiful but emails are essentially absent, so the next person to
        # read the install log sees the drop instead of an apparently clean
        # "Imported N contacts". Best-effort: a SPARQL/curl hiccup must not
        # fail the install, so every step is guarded and defaults to silent.
        _guard_email_coverage() {
            command -v curl >/dev/null 2>&1 || return 0
            local q_phone q_email phones emails
            q_phone='PREFIX pwg: <https://pwg.dev/ontology#> SELECT (COUNT(DISTINCT ?id) AS ?n) WHERE { ?id pwg:identifierType "phone" }'
            q_email='PREFIX pwg: <https://pwg.dev/ontology#> SELECT (COUNT(DISTINCT ?id) AS ?n) WHERE { ?id pwg:identifierType "email" }'
            phones="$(curl -s --max-time 15 --data-urlencode "query=${q_phone}" \
                -H "Accept: text/csv" "${_HYDRATE_OXIGRAPH}/query" 2>/dev/null \
                | tail -n 1 | tr -dc '0-9')"
            emails="$(curl -s --max-time 15 --data-urlencode "query=${q_email}" \
                -H "Accept: text/csv" "${_HYDRATE_OXIGRAPH}/query" 2>/dev/null \
                | tail -n 1 | tr -dc '0-9')"
            phones="${phones:-0}"
            emails="${emails:-0}"
            # Only meaningful when there is a real phone population to compare
            # against. Threshold: >=20 phones present, but emails under 5% of
            # the phone count -> the phone-only-export signature.
            if [[ "$phones" -ge 20 ]] \
               && [[ $((emails * 20)) -lt "$phones" ]]; then
                warn "$(printf "$MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW" \
                    "$_HYDRATE_CONTACTS_COUNT" "$phones" "$emails")"
            fi
        }
        _guard_email_coverage || true
        unset -f _guard_email_coverage 2>/dev/null || true
    elif [[ "${FDA_GRANTED:-true}" != "true" ]] || ! _has_fda; then
        # Fail LOUD on FDA denial -- never a silent 0-contact pass. The
        # abcddb read needs Full Disk Access; without it nothing can be
        # read. Tell the customer exactly what to grant, and schedule the
        # self-removing re-sync so contacts land once FDA is granted.
        warn "$MSG_HYDRATE_CONTACTS_DENIED"
        _schedule_contact_resync
    elif _store_populated_contacts; then
        # SILENT-ZERO GUARD (the failure mode that has burned us): FDA is
        # granted AND the local AddressBook store HAS contact rows on
        # disk, yet the abcddb import returned 0. That is NOT "iCloud
        # still syncing" -- the contacts are right there. Surface it as a
        # distinct, loud read failure (never report success), and still
        # schedule the re-sync so a transient read recovers.
        warn "$MSG_HYDRATE_CONTACTS_READ_FAILED"
        _schedule_contact_resync
    elif [[ "$_hydrate_contacts_accounts" -gt 0 ]]; then
        # FDA granted, accounts configured, but the local store is still
        # empty: iCloud has not finished its first contact sync yet.
        # Surface it and schedule the self-removing re-sync so late-syncing
        # contacts still reach the graph.
        warn "$MSG_HYDRATE_CONTACTS_PENDING"
        _schedule_contact_resync
    else
        # No contacts source configured at all.
        warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
    fi
    unset _HYDRATE_FORCE_ABCDDB_VCF
else
    # Import-pipeline venv missing -- cannot read contacts at all. Loud,
    # not silent: the venv build earlier should have hard-failed, but if
    # we reach here, say so rather than imply zero contacts.
    warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
fi
unset _hydrate_contacts_accounts

# Calendar hydration -----------------------------------------------
#
# CX-101 (DMG #48j, 2026-05-29): SWITCHED FROM meeting_syncer ->
# CalDAV path TO FDA path (ostler_fda.calendar + pwg_ingest.
# ingest_calendar). The old meeting_syncer path went via the
# localhost ical-server which invoked ~/.ostler/ical/ical-query.sh
# against caldav.icloud.com using OSTLER_ICLOUD_USER +
# OSTLER_ICLOUD_APP_PASSWORD -- env vars install.sh NEVER captures.
# Consequence: every clean install with default config hit the
# wrapper's "creds missing, exit 0 empty" branch, meeting_syncer
# parsed zero events, and the customer's wiki Calendar page was
# empty by design. Diagnostic: launch/DIAGNOSTIC_hydrate_empty_2026-05-29.md.
#
# The FDA path is the same shape as iMessage hydrate (which works):
# the FDA extractor (Phase 3.7) reads the local ~/Library/Calendars/
# Calendar Cache DB and writes calendar_events.json under ~/.ostler/
# imports/fda/. pwg_ingest.ingest_calendar() consumes that JSON +
# emits Person triples per attendee + lastContactCalendar markers.
# No CalDAV app-password needed; Calendar.app's local cache covers
# every account configured in System Settings -> Internet Accounts.
#
# Three-state handling matches the Mail/Contacts shape. If
# Accounts4.sqlite shows calendar accounts but the local cache is
# empty, we offer to open Calendar.app and wait while iCloud syncs
# before reading the cache. Per
# launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
#
# OSTLER_HYDRATE_BACKFILL_DAYS (5 years default) controls the
# extract_events since_days. The Phase 3.7 extract_all run used
# since_days=365 (snappy first onboarding); here at hydrate time
# we want the full backfill window so the wiki populates with the
# customer's full calendar history. We re-run the extractor inline
# with the longer window, overwriting the existing JSON.
#
# CX-106 (DMG #48l, 2026-05-29): for CALENDAR specifically we keep
# the install-time window at 90 days. The hourly fda-rerun
# LaunchAgent (scheduled +12h at Phase 3.7) walks the 5-year window
# in the background. Studio retest of DMG #48k showed customers
# with multi-year calendar history hitting silent timeouts on the
# install-time path because the Calendar Cache query was scanning
# years of recurring-event expansions inside the 180s wall-clock cap.
OSTLER_HYDRATE_CALENDAR_DAYS="${OSTLER_HYDRATE_CALENDAR_DAYS:-90}"
# Calendar extraction + ingest import ostler_fda (ostler_fda.calendar and
# ostler_fda.pwg_ingest). ostler_fda is pip-installed into the email-ingest
# venv (Phase 3.14b), NOT into the contact-syncer import-pipeline venv
# ($_HYDRATE_PIPELINE_PY), which only carries the contact_syncer package.
# The sibling browsing / imessage / people ingests already run their
# ostler_fda.pwg_ingest calls under the email-ingest venv for exactly this
# reason. The calendar steps were the only ones still pointed at the
# pipeline venv, so their imports raised ModuleNotFoundError and calendar
# silently never landed (Studio 2026-06-03: Oxigraph calendar events = 0,
# mislabelled "Calendar app has not synced yet"). Run them under the same
# email-ingest venv the siblings use.
_HYDRATE_CALENDAR_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_CALENDAR_PY="${_HYDRATE_CALENDAR_VENV}/bin/python"
if [[ -x "$_HYDRATE_CALENDAR_PY" ]]; then
    info "$MSG_HYDRATE_CALENDAR_STARTED"

    # State-2 wait: if accounts configured but cache empty, offer to
    # open Calendar.app and poll for population (up to 60s default).
    _hydrate_cal_accounts="$(_accountsdb_count_calendar)"
    _hydrate_cal_accounts="${_hydrate_cal_accounts:-0}"
    if [[ "$_hydrate_cal_accounts" -gt 0 ]] \
       && ! _store_populated_calendar \
       && [[ "${OSTLER_GUI:-0}" == "1" ]]; then
        _open_cal_help="$(printf "$MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP" "${_hydrate_cal_accounts}")"
        _three_state_wait_for_populate \
            "calendar" \
            "Calendar" \
            "" \
            "$MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE" \
            "$_open_cal_help" || true
        unset _open_cal_help
    fi

    # Re-extract calendar events with the full backfill window. The
    # Phase 3.7 run wrote calendar_events.json with since_days=365;
    # here we overwrite with the 5-year window so the hydrate
    # consumer sees full history. The OSTLER_FDA_OUTPUT_DIR env
    # var threads through to the writer.
    _HYDRATE_CALENDAR_EXTRACT="$(OSTLER_FDA_OUTPUT_DIR="${OSTLER_DIR}/imports/fda" \
    "$_HYDRATE_CALENDAR_PY" - <<EOF 2>>/tmp/ostler-hydrate-calendar.log
import json, os, sys
from pathlib import Path
out_dir = Path(os.environ["OSTLER_FDA_OUTPUT_DIR"])
out_dir.mkdir(parents=True, exist_ok=True)
try:
    from ostler_fda.calendar import extract_events
    from dataclasses import asdict
    events = extract_events(since_days=${OSTLER_HYDRATE_CALENDAR_DAYS}, future_days=30)
    (out_dir / "calendar_events.json").write_text(
        json.dumps([asdict(e) for e in events], indent=2, default=str)
    )
    print(json.dumps({"status": "ok", "events": len(events)}))
except PermissionError as e:
    print(json.dumps({"status": "no_fda", "error": str(e)}))
except FileNotFoundError as e:
    print(json.dumps({"status": "not_found", "error": str(e)}))
except Exception as e:
    print(json.dumps({"status": "error", "error": str(e)}))
EOF
)" || _HYDRATE_CALENDAR_EXTRACT=""

    # Ingest the JSON into Oxigraph via the existing pwg_ingest path.
    # ingest_calendar reads calendar_events.json and emits triples
    # per attendee. The return dict has {events_processed,
    # unique_attendees} which we surface as "Imported %s events".
    _HYDRATE_CALENDAR_JSON="$(
        "$_HYDRATE_CALENDAR_PY" - <<EOF 2>>/tmp/ostler-hydrate-calendar.log
import json, os, sys
from pathlib import Path
os.environ.setdefault("OXIGRAPH_URL", "$_HYDRATE_OXIGRAPH")
try:
    from ostler_fda.pwg_ingest import ingest_calendar
    result = ingest_calendar(Path("${OSTLER_DIR}/imports/fda"))
    # Normalise output to {imported: N} for the parser below.
    imported = int(result.get("events_processed", 0) or 0)
    print(json.dumps({"imported": imported, **result}, default=str))
except Exception as e:
    print(json.dumps({"imported": 0, "status": "error", "error": str(e)}))
EOF
    )" || _HYDRATE_CALENDAR_JSON=""
    _HYDRATE_CALENDAR_COUNT="$(
        printf '%s' "$_HYDRATE_CALENDAR_JSON" \
        | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("imported", 0)))
except Exception:
    print(0)' 2>/dev/null
    )"
    _HYDRATE_CALENDAR_COUNT="${_HYDRATE_CALENDAR_COUNT:-0}"
    # Parse the extract + ingest "status" so a genuine extractor failure
    # (a raised exception -- e.g. ModuleNotFoundError if ostler_fda is not
    # importable in the venv, or a bug in calendar.py / pwg_ingest) is told
    # apart from the empty-iCloud "Calendar not synced" state. Conflating
    # the two is exactly how a dead import masqueraded as a sync state on
    # the 2026-06-03 Studio install (silent-bail rule).
    _hydrate_cal_status_of() {
        printf '%s' "$1" | python3 -c 'import json,sys
try:
    print(json.loads(sys.stdin.read()).get("status",""))
except Exception:
    print("")' 2>/dev/null
    }
    _HYDRATE_CALENDAR_EXTRACT_STATUS="$(_hydrate_cal_status_of "${_HYDRATE_CALENDAR_EXTRACT:-}")"
    _HYDRATE_CALENDAR_INGEST_STATUS="$(_hydrate_cal_status_of "${_HYDRATE_CALENDAR_JSON:-}")"
    unset -f _hydrate_cal_status_of
    if [[ "$_HYDRATE_CALENDAR_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CALENDAR_DONE" "$_HYDRATE_CALENDAR_COUNT")"
    elif [[ "$_HYDRATE_CALENDAR_EXTRACT_STATUS" == "error" \
            || "$_HYDRATE_CALENDAR_INGEST_STATUS" == "error" ]]; then
        # The extractor or ingest raised -- this is NOT an empty calendar.
        # Surface it as a failure (with the log path) instead of the
        # "not synced" state so the two are never conflated.
        warn "$MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED"
    elif [[ "$_hydrate_cal_accounts" -gt 0 ]]; then
        # State 2 -- accounts configured but cache empty (wait-for-
        # populate either declined or timed out).
        info "$MSG_HYDRATE_CALENDAR_PENDING"
    else
        # State 1 -- no calendar accounts configured at all.
        info "$MSG_HYDRATE_SKIPPED_NO_EVENTS"
    fi
    unset _hydrate_cal_accounts _HYDRATE_CALENDAR_EXTRACT \
          _HYDRATE_CALENDAR_EXTRACT_STATUS _HYDRATE_CALENDAR_INGEST_STATUS
else
    info "$MSG_HYDRATE_SKIPPED_NO_EVENTS"
fi

# Email hydration --------------------------------------------------
#
# CX-94 (DMG #48g, 2026-05-29): backfill window bumped from 30 days
# to 5 years (1825 days). Pulls correspondents from Apple Mail
# into the People graph as a one-shot install-time tick. Without
# this the customer waits up to 60 minutes for the hourly
# LaunchAgent to fire its first run; with it the wiki shows
# correspondents within ~5 minutes of install completion.
#
# Wall-clock cap (180s, doubled from the pre-CX-94 90s) keeps the
# install moving on huge mailboxes. If the cap is hit we emit
# MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES and let the hourly agent
# finish the crawl. The customer still gets contacts + calendar
# (B1) plus whatever email landed in the time window. The hourly
# LaunchAgent inherits OSTLER_BACKFILL_DAYS via Phase 3.X above and
# will pick up the rest progressively.
#
# Behaviour on edge cases (per CX-81 B2 + B1 AC4):
#   - email-ingest venv not set up / pwg-email-ingest missing ->
#     emit MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING, continue.
#   - mbox emit produces no messages (empty mailbox / FDA pending)
#     -> emit MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT, continue.
#   - 180s timeout -> emit MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES,
#     continue. The hourly tick takes it from there.
#
# Privacy AC6: pwg-email-ingest's --json output is counts only.
# Subjects, bodies, and from-addresses never cross the install.sh
# process boundary.
# CX-106 (DMG #48l, 2026-05-29): install-time email window is narrowed
# to 90 days. The pre-CX-106 path used the full 5-year backfill window
# here -- which on a busy mailbox blew the 180s wall-clock cap every
# time, leaving the customer with ZERO email people in the wiki at
# install completion. 90 days is enough to surface the customer's
# recent correspondents (the "is this thing working?" check) while
# staying well inside the timeout. The hourly email-ingest LaunchAgent
# (Phase 3.14, line ~8207) walks the rest of the 5-year history in
# the background -- the wiki backfills progressively over the first
# few hours rather than blocking install completion. Override:
# OSTLER_HYDRATE_EMAIL_DAYS=365 ./install.sh for a longer first pull.
OSTLER_HYDRATE_EMAIL_DAYS="${OSTLER_HYDRATE_EMAIL_DAYS:-90}"

_HYDRATE_EMAIL_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_EMAIL_PY="${_HYDRATE_EMAIL_VENV}/bin/python"
_HYDRATE_EMAIL_BIN="${_HYDRATE_EMAIL_VENV}/bin/pwg-email-ingest"
_HYDRATE_EMAIL_MBOX_DIR="${OSTLER_DIR}/imports/email"
_HYDRATE_OXIGRAPH_EMAIL="${OXIGRAPH_URL:-http://localhost:7878}"

if [[ -x "$_HYDRATE_EMAIL_PY" ]] && [[ -x "$_HYDRATE_EMAIL_BIN" ]]; then
    info "$MSG_HYDRATE_EMAIL_STARTED"

    # Pick a timeout wrapper. brew coreutils ships gtimeout; some
    # toolchains ship plain `timeout`. If neither is present we
    # run unbounded -- on a fresh install with a small backfill
    # window the FDA emit is fast enough that the absence rarely
    # bites in practice.
    _HYDRATE_EMAIL_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_EMAIL_TIMEOUT_WRAP="gtimeout 180"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_EMAIL_TIMEOUT_WRAP="timeout 180"
    fi

    mkdir -p "$_HYDRATE_EMAIL_MBOX_DIR"
    _HYDRATE_EMAIL_MBOX="${_HYDRATE_EMAIL_MBOX_DIR}/install-time-$(date +%Y%m%dT%H%M%S).mbox.txt"
    _HYDRATE_EMAIL_TIMED_OUT=false
    _HYDRATE_EMAIL_LOG=/tmp/ostler-hydrate-email.log

    # Step 1: drain Apple Mail into a fresh mbox. ostler_fda is
    # pip-installed in the email-ingest venv by Phase 3.X above.
    # CX-94: backfill window now $OSTLER_HYDRATE_BACKFILL_DAYS (5y default).
    # Chunk size kept at 30d so the apple_mail_mbox reader can stream
    # progress + recover from a per-chunk failure without restarting
    # the whole multi-year scan.
    _hydrate_heartbeat_start "$MSG_HYDRATE_EMAIL_HEARTBEAT"
    if OSTLER_HOME="$HOME" $_HYDRATE_EMAIL_TIMEOUT_WRAP \
       "$_HYDRATE_EMAIL_PY" -m ostler_fda.apple_mail_mbox \
           --emit-mbox "$_HYDRATE_EMAIL_MBOX" \
           --backfill-days "$OSTLER_HYDRATE_EMAIL_DAYS" \
           --backfill-chunk-days 30 \
           >>"$_HYDRATE_EMAIL_LOG" 2>&1; then
        _hydrate_heartbeat_stop
        :
    else
        rc=$?
        _hydrate_heartbeat_stop
        # gtimeout returns 124 (signalled SIGTERM) or 137 (signalled
        # SIGKILL) when the cap is hit. Any other non-zero is a real
        # emit failure (e.g. FDA permission denied).
        if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
            _HYDRATE_EMAIL_TIMED_OUT=true
        fi
    fi

    if [[ "$_HYDRATE_EMAIL_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES"
    elif [[ -s "$_HYDRATE_EMAIL_MBOX" ]]; then
        # Step 2: ingest the mbox into Oxigraph. The CLI's --json
        # output is counts only; install.sh parses people_extracted
        # for the customer-facing OK line.
        _HYDRATE_EMAIL_JSON="$(
            "$_HYDRATE_EMAIL_BIN" mbox "$_HYDRATE_EMAIL_MBOX" \
                --backfill-days "$OSTLER_HYDRATE_EMAIL_DAYS" \
                --graph-endpoint "$_HYDRATE_OXIGRAPH_EMAIL" \
                --json 2>>"$_HYDRATE_EMAIL_LOG" \
            | tail -n 1
        )" || _HYDRATE_EMAIL_JSON=""
        _HYDRATE_EMAIL_COUNT="$(
            printf '%s' "$_HYDRATE_EMAIL_JSON" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_extracted", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_EMAIL_COUNT="${_HYDRATE_EMAIL_COUNT:-0}"
        if [[ "$_HYDRATE_EMAIL_COUNT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_EMAIL_DONE" "$_HYDRATE_EMAIL_COUNT")"
        else
            info "$MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT"
        fi
        # Tidy: the install-time mbox is one-shot. The hourly
        # LaunchAgent writes to its own date-bucketed filenames so
        # there is no collision risk; deleting just keeps disk clean.
        rm -f "$_HYDRATE_EMAIL_MBOX"
    else
        info "$MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT"
    fi

    unset _HYDRATE_EMAIL_MBOX _HYDRATE_EMAIL_TIMED_OUT _HYDRATE_EMAIL_JSON
    unset _HYDRATE_EMAIL_COUNT _HYDRATE_EMAIL_TIMEOUT_WRAP _HYDRATE_EMAIL_LOG
else
    info "$MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING"
fi

unset _HYDRATE_EMAIL_VENV _HYDRATE_EMAIL_PY _HYDRATE_EMAIL_BIN
unset _HYDRATE_EMAIL_MBOX_DIR _HYDRATE_OXIGRAPH_EMAIL

# WhatsApp hydration (CX-85) ---------------------------------------
#
# Reads the macOS WhatsApp Desktop client's local ChatStorage.sqlite
# and classifies each chat into one of three tiers:
#
#   T1 DM:                 1:1 chat. Ingest the DM partner + lastContactWhatsApp.
#                          Confidence 1.0 implicit. Source tier "whatsapp_dm".
#   T2 intimate-or-active: group with < 10 participants OR engaged in 90d
#                          (>= 20 user-sent OR >= 2% relative ratio).
#                          Ingest all active members + lastContactWhatsApp.
#                          Confidence 0.7 explicit. Tier "whatsapp_group_*".
#   T3 large-passive:      group with >= 10 participants AND below both
#                          engagement floors. SKIP -- no Person nodes,
#                          no triples, invisible to the graph.
#
# Threshold lock-ins (Andy 2026-05-26): intimate cutoff < 10, window 90d,
# abs floor >= 20 user-sent, rel floor >= 0.02 (2%), T2 confidence 0.7,
# T3 = complete skip. See ostler_fda/whatsapp_history.py for full docstring.
#
# 90s wall-clock cap, enforced by the gtimeout wrapper that Phase 3.1b
# guarantees is present (GNU coreutils is brew-installed early so the
# wrap-picker below actually fires; if coreutils is somehow absent the
# step runs unbounded but the heartbeat keeps the GUI from looking
# hung). On timeout we emit MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES and let
# any subsequent run (Doctor-triggered rescan, future hourly tick)
# finish the job. The customer's wiki still gets contacts + calendar
# (B1) + email (B2) plus whatever WhatsApp landed in the 90s window.
#
# Behaviour on edge cases:
#   - email-ingest venv not set up / ostler_fda missing -> emit
#     MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING, continue.
#   - WhatsApp Desktop not installed / ChatStorage.sqlite missing
#     -> emit MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP, continue.
#   - 90s timeout -> emit MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES.
#
# Privacy AC (mirror of B2 AC6): the --json output is counts only --
# no JIDs, no message bodies, no group names cross the install.sh
# process boundary. The classifier writes whatsapp_conversations.json
# under ~/.ostler/imports/fda/ with participant lists (those are
# customer-local artefacts, never logged off-machine).
_HYDRATE_WHATSAPP_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_WHATSAPP_PY="${_HYDRATE_WHATSAPP_VENV}/bin/python"
_HYDRATE_WHATSAPP_DB="${HOME}/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
_HYDRATE_OXIGRAPH_WA="${OXIGRAPH_URL:-http://localhost:7878}"

if _hydrate_sentinel_fresh "whatsapp"; then
    info "$MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS"
elif [[ -x "$_HYDRATE_WHATSAPP_PY" ]] && [[ -f "$_HYDRATE_WHATSAPP_DB" ]]; then
    info "$MSG_HYDRATE_WHATSAPP_STARTED"

    # Same timeout picker as hydrate_email (brew coreutils gtimeout
    # preferred; system timeout fallback; unbounded if neither).
    _HYDRATE_WHATSAPP_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_WHATSAPP_TIMEOUT_WRAP="gtimeout 90"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_WHATSAPP_TIMEOUT_WRAP="timeout 90"
    fi

    _HYDRATE_WHATSAPP_LOG=/tmp/ostler-hydrate-whatsapp.log
    _HYDRATE_WHATSAPP_TIMED_OUT=false

    # Step 1: extract + classify. Writes whatsapp_conversations.json
    # under ~/.ostler/imports/fda/ for the pwg_ingest step to read.
    # T3 chats are filtered at the extractor's JSON-write boundary,
    # so a subsequent ingest cannot accidentally emit T3 triples.
    _HYDRATE_WHATSAPP_JSON="$(
        OXIGRAPH_URL="$_HYDRATE_OXIGRAPH_WA" $_HYDRATE_WHATSAPP_TIMEOUT_WRAP \
        "$_HYDRATE_WHATSAPP_PY" -m ostler_fda.whatsapp_history \
            --json \
            --since-days 365 \
            2>>"$_HYDRATE_WHATSAPP_LOG" \
        | tail -n 1
    )"
    rc=$?
    if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
        _HYDRATE_WHATSAPP_TIMED_OUT=true
    fi

    if [[ "$_HYDRATE_WHATSAPP_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES"
    else
        # Step 2: ingest the JSON into Oxigraph. pwg_ingest.main() runs
        # every ingest_* for which a JSON file exists; since only
        # whatsapp_conversations.json was just written, only
        # ingest_whatsapp will do work. Other ingests return their
        # "no data" skip status without touching Oxigraph.
        "$_HYDRATE_WHATSAPP_PY" -m ostler_fda.pwg_ingest \
            --fda-dir "${OSTLER_DIR}/imports/fda" \
            >>"$_HYDRATE_WHATSAPP_LOG" 2>&1 || true

        # Parse people_added for the customer-facing message. The CLI
        # contract guarantees this field exists in --json output.
        _HYDRATE_WHATSAPP_COUNT="$(
            printf '%s' "$_HYDRATE_WHATSAPP_JSON" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_added", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_WHATSAPP_COUNT="${_HYDRATE_WHATSAPP_COUNT:-0}"

        if [[ "$_HYDRATE_WHATSAPP_COUNT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_WHATSAPP_DONE" "$_HYDRATE_WHATSAPP_COUNT")"
        else
            info "$MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS"
        fi
    fi

    # #48g sentinel record: dedupes re-runs within a 7-day window. The
    # payload is a counts-only snapshot; never logged off-machine.
    _hydrate_sentinel_record "whatsapp" "people_added=${_HYDRATE_WHATSAPP_COUNT:-0}"

    unset _HYDRATE_WHATSAPP_TIMED_OUT _HYDRATE_WHATSAPP_JSON
    unset _HYDRATE_WHATSAPP_COUNT _HYDRATE_WHATSAPP_TIMEOUT_WRAP
    unset _HYDRATE_WHATSAPP_LOG
elif [[ ! -x "$_HYDRATE_WHATSAPP_PY" ]]; then
    info "$MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING"
else
    info "$MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP"
    # Record the sentinel even for "no app" so re-runs don't re-probe;
    # if the customer installs WhatsApp Desktop later, they re-trigger
    # via Doctor's source-repair flow, not by re-running install.sh.
    _hydrate_sentinel_record "whatsapp" "status=no_app"
fi

unset _HYDRATE_WHATSAPP_VENV _HYDRATE_WHATSAPP_PY _HYDRATE_WHATSAPP_DB
unset _HYDRATE_OXIGRAPH_WA

unset _HYDRATE_VCF _HYDRATE_API _HYDRATE_OXIGRAPH _HYDRATE_PIPELINE_PY \
      _HYDRATE_CALENDAR_VENV _HYDRATE_CALENDAR_PY
unset _HYDRATE_CONTACTS_JSON _HYDRATE_CONTACTS_COUNT
unset _HYDRATE_CALENDAR_JSON _HYDRATE_CALENDAR_COUNT

# Browser hydration (CX-86 Gap A + Gap C) --------------------------
#
# Streams safari_history.json + chrome_history.json (written by the
# Phase 3 FDA extract_all step) through the CM019 gateway. The
# gateway writes to the `safari_history` Qdrant collection (renamed
# from `safari_browsing` in CX-86 Gap B) so the CM044 wiki Browsing
# page populates with the customer's visits.
#
# Bearer auth: token from ~/.ostler/secrets/service_token (written
# by the install.sh auth_tokens phase earlier). Blocklist (Q3
# sign-off): banking / medical / etc. URLs are rejected with HTTP
# 422 and counted as "skipped_sensitive". needs_reprocessing=true
# (Q2 sign-off): backfilled rows land with empty topics/category;
# the gateway's background enrichment tick chews through them.
#
# 90s wall-clock cap via the gtimeout wrapper (coreutils guaranteed by
# Phase 3.1b; unbounded-but-heartbeated if absent), same as
# hydrate_email + hydrate_whatsapp. On timeout we emit
# MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES and let the agent finish.
#
# Privacy AC mirror B2 + CX-85: the --json output is counts only,
# pinned by the privacy contract test in HR015 #134. No URLs, no
# titles, no domain names cross the install.sh process boundary.

progress "Hydrating your browsing history" "hydrate_browsing"

_HYDRATE_BROWSING_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_BROWSING_PY="${_HYDRATE_BROWSING_VENV}/bin/python"
_HYDRATE_BROWSING_FDA_DIR="${OSTLER_DIR}/imports/fda"
_HYDRATE_BROWSING_SAFARI="${_HYDRATE_BROWSING_FDA_DIR}/safari_history.json"
_HYDRATE_BROWSING_CHROME="${_HYDRATE_BROWSING_FDA_DIR}/chrome_history.json"

if _hydrate_sentinel_fresh "browsing"; then
    info "$MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA"
elif [[ -x "$_HYDRATE_BROWSING_PY" ]] && \
   { [[ -s "$_HYDRATE_BROWSING_SAFARI" ]] || [[ -s "$_HYDRATE_BROWSING_CHROME" ]]; }; then
    info "$MSG_HYDRATE_BROWSING_STARTED"

    _HYDRATE_BROWSING_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_BROWSING_TIMEOUT_WRAP="gtimeout 90"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_BROWSING_TIMEOUT_WRAP="timeout 90"
    fi

    _HYDRATE_BROWSING_LOG=/tmp/ostler-hydrate-browsing.log
    _HYDRATE_BROWSING_TIMED_OUT=false

    # Stream the JSON through ingest_browser_history. Inline python
    # invocation lets us call ingest_browser_history directly so we
    # don't trigger the other ingest_* functions in ingest_all
    # (which would re-emit triples the per-source hydrate_* blocks
    # already wrote). Output is the counts-only JSON pinned by
    # HR015 #134's privacy contract test.
    # #640-class guard -- THE .145 box-walk install-FAILURE site. This
    # command-sub runs inline python importing ostler_fda.pwg_ingest; under
    # the global `set -Eeuo pipefail` + errtrace (-E) the ERR trap propagates
    # INTO the $(...) subshell, so ANY non-zero there (the undeclared httpx
    # that aborted this install, a malformed record, the absent `timeout`
    # returning 127) fires _ostler_on_err -> gui_done fail and kills the WHOLE
    # install. Browser/iMessage/People hydration is best-effort enrichment and
    # must never be fatal. Suppress the ERR trap + errexit for just this
    # capture, preserve rc for the timeout check, then restore both (mirrors
    # the doctor-probe guard at ~13565).
    _saved_err_trap=$(trap -p ERR); trap - ERR; set +e
    _HYDRATE_BROWSING_JSON="$(
        $_HYDRATE_BROWSING_TIMEOUT_WRAP \
        "$_HYDRATE_BROWSING_PY" -c "
import json
from pathlib import Path
from ostler_fda.pwg_ingest import ingest_browser_history, ingest_bookmarks
fda = Path('${_HYDRATE_BROWSING_FDA_DIR}')
result = ingest_browser_history(fda)
# Day-one Reading-page bookmark signal (clean follow-up to #524's
# Social graft): turn the Safari safari_bookmarks.json (same FDA dir,
# Recommended source) into category=bookmark preference points so the
# CM044 Reading page is populated on a fresh install. Best-effort -- a
# bookmarks failure must not lose the browsing-history ingest above, so
# it is isolated and its status is folded into the same JSON line.
try:
    result['bookmarks'] = ingest_bookmarks(fda)
except Exception as exc:
    result['bookmarks'] = {'status': 'error', 'error': type(exc).__name__}
print(json.dumps(result))
" 2>>"$_HYDRATE_BROWSING_LOG" | tail -n 1
    )"
    rc=$?
    set -e; eval "${_saved_err_trap:-}"
    if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
        _HYDRATE_BROWSING_TIMED_OUT=true
    fi

    if [[ "$_HYDRATE_BROWSING_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES"
    elif [[ -n "$_HYDRATE_BROWSING_JSON" ]]; then
        # Parse 'sent' for the customer-facing count. The JSON keys
        # are pinned by the HR015 #134 privacy contract test, so
        # this parse is stable across releases.
        _HYDRATE_BROWSING_SENT="$(
            printf '%s' "$_HYDRATE_BROWSING_JSON" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("sent", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_BROWSING_SKIPPED="$(
            printf '%s' "$_HYDRATE_BROWSING_JSON" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("skipped_sensitive", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_BROWSING_SENT="${_HYDRATE_BROWSING_SENT:-0}"
        _HYDRATE_BROWSING_SKIPPED="${_HYDRATE_BROWSING_SKIPPED:-0}"
        if [[ "$_HYDRATE_BROWSING_SENT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_BROWSING_DONE" "$_HYDRATE_BROWSING_SENT")"
            if [[ "$_HYDRATE_BROWSING_SKIPPED" -gt 0 ]]; then
                info "$(printf "$MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE" "$_HYDRATE_BROWSING_SKIPPED")"
            fi
        else
            info "$MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA"
        fi
    else
        info "$MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA"
    fi

    # #48g sentinel record: dedupes re-runs within a 7-day window.
    _hydrate_sentinel_record "browsing" "sent=${_HYDRATE_BROWSING_SENT:-0},skipped=${_HYDRATE_BROWSING_SKIPPED:-0}"

    unset _HYDRATE_BROWSING_TIMED_OUT _HYDRATE_BROWSING_JSON
    unset _HYDRATE_BROWSING_SENT _HYDRATE_BROWSING_SKIPPED
    unset _HYDRATE_BROWSING_TIMEOUT_WRAP _HYDRATE_BROWSING_LOG
elif [[ ! -x "$_HYDRATE_BROWSING_PY" ]]; then
    info "$MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING"
else
    info "$MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA"
    _hydrate_sentinel_record "browsing" "status=no_data"
fi

unset _HYDRATE_BROWSING_VENV _HYDRATE_BROWSING_PY
unset _HYDRATE_BROWSING_FDA_DIR _HYDRATE_BROWSING_SAFARI _HYDRATE_BROWSING_CHROME

# Email-preferences hydration (v1.0.3) -----------------------------
#
# Ingests a pre-extracted ParsedPreference JSONL file (CM021 email
# intelligence output, category brand/topic/career/person) into the
# `preferences` Qdrant collection + Oxigraph, via the vendored CM019
# ingest CLI. This is the operator's biggest single preference payload,
# so on a wipe/baseline reinstall it must regenerate from the source
# file rather than being a lost one-off manual load. It runs in the
# hydrate region so Qdrant (6333) + Oxigraph (7878) are already up
# (started in Phase "graph_db_start") and the CM019 venv is already
# built (Phase 3.11b "cm019_setup").
#
# Source-file resolution (NO hardcoded operator path -- productisation
# + security rule 4): two opt-in env vars, default unset.
#   OSTLER_EMAIL_PREFERENCES_FILE  -- absolute path to the JSONL file.
#                                     Takes precedence if set.
#   OSTLER_SOCIAL_ARCHIVES_DIR     -- a social-media-archives root; the
#                                     file is read from the known
#                                     relative path
#                                     email/preferences_v4.jsonl under it.
# On a customer install neither is set, so the step SKIPS cleanly with
# an informative log and never fails the install (the whole hydrate
# region is best-effort enrichment).
#
# Timeout: the payload can be large (hundreds of thousands of records),
# so the cap is generous (default 1800s, overridable via
# OSTLER_HYDRATE_EMAIL_PREFERENCES_TIMEOUT). On timeout we emit
# MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES and leave whatever
# committed in place; a later manual re-run (or top-up) finishes it.
#
# Privacy: the customer-facing line is a count only. Subjects, bodies,
# brand/person names never cross the install.sh process boundary -- we
# read the ingest CLI's "Preferences created" tally from its stderr.

progress "Loading your email preferences" "hydrate_email_preferences"

_HYDRATE_EMAILPREFS_CM019_DIR="${OSTLER_DIR}/services/cm019"
_HYDRATE_EMAILPREFS_PY="${_HYDRATE_EMAILPREFS_CM019_DIR}/.venv/bin/python"
_HYDRATE_EMAILPREFS_REL="email/preferences_v4.jsonl"
_HYDRATE_EMAILPREFS_USER="${USER_ID:-${OSTLER_USER:-ostler}}"
_HYDRATE_EMAILPREFS_QDRANT="${QDRANT_URL:-http://localhost:6333}"
_HYDRATE_EMAILPREFS_OXIGRAPH="${OXIGRAPH_URL:-http://localhost:7878}"

# Resolve the source file from the opt-in env vars. Explicit file path
# wins; otherwise look under the archives dir at the known relative path.
_HYDRATE_EMAILPREFS_FILE=""
if [[ -n "${OSTLER_EMAIL_PREFERENCES_FILE:-}" ]]; then
    _HYDRATE_EMAILPREFS_FILE="${OSTLER_EMAIL_PREFERENCES_FILE}"
elif [[ -n "${OSTLER_SOCIAL_ARCHIVES_DIR:-}" ]]; then
    _HYDRATE_EMAILPREFS_FILE="${OSTLER_SOCIAL_ARCHIVES_DIR%/}/${_HYDRATE_EMAILPREFS_REL}"
fi

if _hydrate_sentinel_fresh "email_preferences"; then
    info "$MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE"
elif [[ -z "$_HYDRATE_EMAILPREFS_FILE" ]]; then
    # The customer case: no archive configured. Skip cleanly.
    info "$MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE"
elif [[ ! -x "$_HYDRATE_EMAILPREFS_PY" ]]; then
    info "$MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING"
elif [[ ! -s "$_HYDRATE_EMAILPREFS_FILE" ]]; then
    # The env var was set but the file is missing or empty -- treat as
    # "nothing to load" rather than an error, and tell the operator
    # which path we looked at so they can fix the env var.
    info "$(printf "$MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT" "$_HYDRATE_EMAILPREFS_FILE")"
else
    info "$MSG_HYDRATE_EMAIL_PREFERENCES_STARTED"

    # Same timeout picker as the other hydrate phases (brew coreutils
    # gtimeout preferred; system timeout fallback; unbounded if neither).
    _HYDRATE_EMAILPREFS_CAP="${OSTLER_HYDRATE_EMAIL_PREFERENCES_TIMEOUT:-1800}"
    _HYDRATE_EMAILPREFS_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_EMAILPREFS_TIMEOUT_WRAP="gtimeout $_HYDRATE_EMAILPREFS_CAP"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_EMAILPREFS_TIMEOUT_WRAP="timeout $_HYDRATE_EMAILPREFS_CAP"
    fi

    _HYDRATE_EMAILPREFS_LOG=/tmp/ostler-hydrate-email-preferences.log
    _HYDRATE_EMAILPREFS_TIMED_OUT=false

    _hydrate_heartbeat_start "$MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT"

    # Run the vendored CM019 ingest CLI against the JSONL file. The
    # pipeline connects to Qdrant + Oxigraph (both up by now) inside
    # pipeline.initialize(). cd into the CM019 service dir so the
    # `services.ingest.src.cli` module path resolves, mirroring the
    # ostler-import importer's invocation. Counts-only readback below.
    if (
        cd "$_HYDRATE_EMAILPREFS_CM019_DIR" \
        && QDRANT_COLLECTION=preferences \
           QDRANT_URL="$_HYDRATE_EMAILPREFS_QDRANT" \
           OXIGRAPH_URL="$_HYDRATE_EMAILPREFS_OXIGRAPH" \
           $_HYDRATE_EMAILPREFS_TIMEOUT_WRAP \
           "$_HYDRATE_EMAILPREFS_PY" -m services.ingest.src.cli ingest-email \
               "$_HYDRATE_EMAILPREFS_FILE" \
               -u "$_HYDRATE_EMAILPREFS_USER" \
           >>"$_HYDRATE_EMAILPREFS_LOG" 2>&1
    ); then
        _hydrate_heartbeat_stop
        :
    else
        rc=$?
        _hydrate_heartbeat_stop
        if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
            _HYDRATE_EMAILPREFS_TIMED_OUT=true
        fi
    fi

    if [[ "$_HYDRATE_EMAILPREFS_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES"
    else
        # The ingest CLI prints "Preferences created: <n>" to stderr (now
        # in the log). Parse the count for the customer-facing line; the
        # name/value pairs themselves never leave the process.
        _HYDRATE_EMAILPREFS_COUNT="$(
            grep -aE 'Preferences created:' "$_HYDRATE_EMAILPREFS_LOG" 2>/dev/null \
            | tail -n 1 \
            | tr -dc '0-9'
        )"
        _HYDRATE_EMAILPREFS_COUNT="${_HYDRATE_EMAILPREFS_COUNT:-0}"
        if [[ "$_HYDRATE_EMAILPREFS_COUNT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_EMAIL_PREFERENCES_DONE" "$_HYDRATE_EMAILPREFS_COUNT")"
        else
            info "$MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE"
        fi
        # Sentinel dedupes a re-run within the 7-day window.
        _hydrate_sentinel_record "email_preferences" "preferences_created=${_HYDRATE_EMAILPREFS_COUNT:-0}"
    fi

    unset _HYDRATE_EMAILPREFS_CAP _HYDRATE_EMAILPREFS_TIMEOUT_WRAP
    unset _HYDRATE_EMAILPREFS_LOG _HYDRATE_EMAILPREFS_TIMED_OUT
    unset _HYDRATE_EMAILPREFS_COUNT
fi

unset _HYDRATE_EMAILPREFS_CM019_DIR _HYDRATE_EMAILPREFS_PY _HYDRATE_EMAILPREFS_REL
unset _HYDRATE_EMAILPREFS_USER _HYDRATE_EMAILPREFS_QDRANT _HYDRATE_EMAILPREFS_OXIGRAPH
unset _HYDRATE_EMAILPREFS_FILE

# iMessage hydration (CX-84) ---------------------------------------
#
# Reads imessage_conversations.json (written by the Phase 3 FDA
# extract_all step when "imessage" is in OSTLER_FDA_SOURCES) and
# emits Person + lastContactIMessage triples into Oxigraph. Only
# the people-count is surfaced to the customer -- no handles, phone
# numbers, or message text leaves the local process.
#
# 90s wall-clock cap via the gtimeout wrapper (coreutils guaranteed by
# Phase 3.1b; unbounded-but-heartbeated if absent), same as the other
# hydrate_* blocks. iMessage is the worst offender for long backfills
# (a multi-year chat.db has been observed at 27 minutes pre-cap), so
# the cap + the progress heartbeat both matter here most. On timeout
# we emit MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES and let the
# hourly tick (or Doctor-triggered rescan) finish whatever was
# still pending.
#
# Backfill window: extract_all.py honours OSTLER_IMESSAGE_BACKFILL_DAYS
# (default 365). The JSON has already been written at fda_extract
# time, so this block just walks the JSON -- no env reach-through
# is needed here.
#
# Behaviour on edge cases:
#   - email-ingest venv not present / ostler_fda missing -> emit
#     MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING, continue.
#   - imessage_conversations.json missing or empty (FDA denied at
#     extract time, or user un-ticked iMessage) -> emit
#     MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA, continue.
#   - 90s timeout -> emit MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES.
#
# Privacy AC (mirror of B2/CX-85/CX-86): the ingest_imessage return
# dict is counts-only (status / people_created / people_enriched);
# install.sh sums the two created+enriched counts for the customer
# message and never logs any participant identifiers.

progress "Hydrating iMessage contacts" "hydrate_imessage"

_HYDRATE_IMESSAGE_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_IMESSAGE_PY="${_HYDRATE_IMESSAGE_VENV}/bin/python"
_HYDRATE_IMESSAGE_FDA_DIR="${OSTLER_DIR}/imports/fda"
_HYDRATE_IMESSAGE_JSON_FILE="${_HYDRATE_IMESSAGE_FDA_DIR}/imessage_conversations.json"

if _hydrate_sentinel_fresh "imessage"; then
    info "$MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA"
elif [[ -x "$_HYDRATE_IMESSAGE_PY" ]] && [[ -s "$_HYDRATE_IMESSAGE_JSON_FILE" ]]; then
    info "$MSG_HYDRATE_IMESSAGE_STARTED"

    _HYDRATE_IMESSAGE_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_IMESSAGE_TIMEOUT_WRAP="gtimeout 90"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_IMESSAGE_TIMEOUT_WRAP="timeout 90"
    fi

    _HYDRATE_IMESSAGE_LOG=/tmp/ostler-hydrate-imessage.log
    _HYDRATE_IMESSAGE_TIMED_OUT=false

    # Inline python so we only run ingest_imessage and don't
    # re-emit triples for whatsapp / browser_history / etc whose
    # JSON also lives in the same fda_dir. Mirrors hydrate_browsing's
    # invocation shape (CX-86 #181).
    # #640-class guard (best-effort hydrate; see the browsing block above for
    # the full rationale): suppress the errtrace ERR trap + errexit around the
    # pwg_ingest command-sub so an in-subshell crash degrades to "skipped"
    # instead of aborting the whole install. Preserve rc for the timeout check.
    _saved_err_trap=$(trap -p ERR); trap - ERR; set +e
    _hydrate_heartbeat_start "$MSG_HYDRATE_IMESSAGE_HEARTBEAT"
    _HYDRATE_IMESSAGE_JSON_OUT="$(
        $_HYDRATE_IMESSAGE_TIMEOUT_WRAP \
        "$_HYDRATE_IMESSAGE_PY" -c "
import json
from pathlib import Path
from ostler_fda.pwg_ingest import ingest_imessage, ingest_social
fda = Path('${_HYDRATE_IMESSAGE_FDA_DIR}')
result = ingest_imessage(fda)
# Day-one Social wiki signal (Prefs Piece 3, #524): turn the same
# iMessage JSON into category=social preference points so the CM044
# Social page is populated on a fresh install. Best-effort -- a social
# failure must not lose the people-graph ingest above, so it is
# isolated and its status is folded into the same JSON line.
try:
    result['social'] = ingest_social(fda)
except Exception as exc:
    result['social'] = {'status': 'error', 'error': type(exc).__name__}
print(json.dumps(result))
" 2>>"$_HYDRATE_IMESSAGE_LOG" | tail -n 1
    )"
    rc=$?
    _hydrate_heartbeat_stop
    set -e; eval "${_saved_err_trap:-}"
    if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
        _HYDRATE_IMESSAGE_TIMED_OUT=true
    fi

    if [[ "$_HYDRATE_IMESSAGE_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES"
    elif [[ -n "$_HYDRATE_IMESSAGE_JSON_OUT" ]]; then
        # ingest_imessage returns people_created + people_enriched.
        # Sum the two for the customer-facing count -- both forms
        # represent "this person now shows iMessage on their wiki
        # card" (enriched = pre-existing Person from B1/B2 gaining
        # an iMessage identifier; created = brand-new contact who
        # only exists in chat.db).
        _HYDRATE_IMESSAGE_COUNT="$(
            printf '%s' "$_HYDRATE_IMESSAGE_JSON_OUT" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_created", 0)) + int(d.get("people_enriched", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_IMESSAGE_COUNT="${_HYDRATE_IMESSAGE_COUNT:-0}"

        if [[ "$_HYDRATE_IMESSAGE_COUNT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_IMESSAGE_DONE" "$_HYDRATE_IMESSAGE_COUNT")"
        else
            info "$MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA"
        fi
    else
        info "$MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA"
    fi

    # #48g sentinel record: dedupes re-runs within a 7-day window.
    _hydrate_sentinel_record "imessage" "people=${_HYDRATE_IMESSAGE_COUNT:-0}"

    unset _HYDRATE_IMESSAGE_TIMED_OUT _HYDRATE_IMESSAGE_JSON_OUT
    unset _HYDRATE_IMESSAGE_COUNT _HYDRATE_IMESSAGE_TIMEOUT_WRAP
    unset _HYDRATE_IMESSAGE_LOG
elif [[ ! -x "$_HYDRATE_IMESSAGE_PY" ]]; then
    info "$MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING"
else
    info "$MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA"
    _hydrate_sentinel_record "imessage" "status=no_data"
fi

unset _HYDRATE_IMESSAGE_VENV _HYDRATE_IMESSAGE_PY
unset _HYDRATE_IMESSAGE_FDA_DIR _HYDRATE_IMESSAGE_JSON_FILE

# ── Conversation-ingest landing guard (CM044 fix) ──────────────────
#
# THE silent-100%-drop tripwire. The conversation pipeline has two legs
# per channel and BOTH have failed silently in the field:
#   1. Synchronous (here): hydrate_whatsapp / hydrate_imessage run
#      ostler_fda.pwg_ingest, which turns the extract JSONs into
#      people-graph FACTS (Person nodes + chat identifiers) in Oxigraph.
#   2. Asynchronous (launchd bundle ticks): the whatsapp/imessage body
#      feeds drive CM048 -> Qdrant `conversations` points + structured
#      facts. Those run AFTER install on their own schedule.
#
# This guard asserts the SYNCHRONOUS contract loudly: if a channel's
# extract JSON carried >0 conversations but ZERO chat-identifier facts
# reached Oxigraph, something is structurally broken (not "no data") and
# we must say so rather than let a customer believe their messages are in
# the graph. It is a loud WARN (not fatal): hydrate is best-effort and
# the async leg may still drain, but a green install must never HIDE a
# total drop. The async Qdrant leg is verified post-install by Doctor's
# conversation-feed probe (it cannot be asserted at install time because
# the first bundle tick has not run yet).
_CONV_GUARD_FDA_DIR="${OSTLER_DIR}/imports/fda"
_CONV_GUARD_OX="${OXIGRAPH_URL:-http://localhost:7878}"
_conv_guard_check() {
    # $1 = channel label, $2 = extract json filename, $3 = identifierLabel
    local _label="$1" _json="${_CONV_GUARD_FDA_DIR}/$2" _idlabel="$3"
    [[ -s "$_json" ]] || return 0
    # How many conversations did extraction emit?
    local _n
    _n="$(python3 -c "
import json,sys
try:
    d=json.load(open('$_json'))
    print(len(d) if isinstance(d,list) else int(d.get('conversations',d.get('count',0)) or 0))
except Exception:
    print(0)" 2>/dev/null)"
    _n="${_n:-0}"
    [[ "$_n" -gt 0 ]] || return 0
    # How many chat-identifier facts landed in Oxigraph for this channel?
    local _q _landed
    _q="PREFIX pwg: <https://pwg.dev/ontology#> SELECT (COUNT(?id) AS ?c) WHERE { ?id a pwg:PersonIdentifier ; pwg:identifierLabel \"${_idlabel}\" . }"
    _landed="$(curl -s --get "${_CONV_GUARD_OX}/query" \
        --data-urlencode "query=${_q}" \
        -H 'Accept: application/sparql-results+json' 2>/dev/null \
        | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d['results']['bindings'][0]['c']['value'])
except Exception:
    print(0)" 2>/dev/null)"
    _landed="${_landed:-0}"
    if [[ "$_landed" -eq 0 ]]; then
        warn "Conversation-ingest guard: ${_label} extraction emitted ${_n} conversation(s) but ZERO ${_label} chat-identity facts reached the graph. The ${_label} leg landed nothing -- this is a structural break, not 'no data'. See /tmp/ostler-hydrate-${_label}.log."
    else
        info "Conversation-ingest guard: ${_label} ${_landed} chat-identity fact(s) in the graph (extract had ${_n})."
    fi
}
# Only meaningful when Oxigraph is reachable; a down graph is reported
# elsewhere and must not double-fire here.
if curl -s -o /dev/null --max-time 5 "${_CONV_GUARD_OX}/" 2>/dev/null; then
    _conv_guard_check whatsapp whatsapp_conversations.json WHATSAPP
    _conv_guard_check imessage imessage_conversations.json IMESSAGE
fi
unset _CONV_GUARD_FDA_DIR _CONV_GUARD_OX

# Whole-graph dedupe consolidation (#4) ----------------------------
#
# All person-populating sources (iCloud contacts/calendar + iMessage
# Person nodes) are now in Oxigraph. The resolver's whole-graph converge
# pass merges same-person duplicates that never shared an incremental
# batch. --converge loops detect -> execute to a fixpoint so transitive
# 3+ node clusters collapse fully. This is pure orchestration over the
# existing resolver: it changes no merge rule, threshold, or flag -- the
# hard-conflict veto (two-Stuart-Baileys guard) and duplicates.yaml
# decisions still apply every round. Oxigraph is the source of truth and
# the people-search sweep below rebuilds the Qdrant `people` collection
# from the merged graph, so a best-effort Qdrant merge here is enough.
# Non-fatal: a dedupe hiccup must never block the install.
#
# v1.0.2 INSTALL-TIME BUDGET CAP + DEFER-TO-BACKGROUND (P0):
# On the .153/.155 cold-wipe walks the FULL converge pass sat silent for
# ~25-60 minutes on a large address book and dominated the install
# critical path (one ~1h50 install was almost entirely this step). The
# converge is a fixpoint loop that gets *more* expensive the more
# duplicates exist, so it is precisely the wrong thing to make the
# customer wait for synchronously.
#
# The fix mirrors the wiki AI-summaries split (baseline now, enrichment
# in the background): we run a HARD-TIME-CAPPED best-effort converge on
# the critical path -- enough to land the obvious merges so the first
# wiki/search build is not littered with duplicates -- then hand the
# *completion* of the converge to a self-removing post-install LaunchAgent
# (ostler-dedupe-catchup, modelled on the wiki-recompile catch-up agent
# above). The agent finishes the fixpoint loop in the background at low
# priority and triggers a wiki recompile so late merges surface without
# the customer waiting. Install critical path for this step is capped at
# OSTLER_DEDUPE_INSTALL_BUDGET_S (default 300s / 5 min).
if [[ -d "$PIPELINE_DIR/identity_resolver" && -x "$PIPELINE_DIR/.venv/bin/python3" ]]; then
    info "Merging duplicate contacts across your sources"
    _DEDUPE_LOG=/tmp/ostler-hydrate-dedupe.log
    _DEDUPE_BUDGET_S="${OSTLER_DEDUPE_INSTALL_BUDGET_S:-300}"
    _DEDUPE_DONE_MARKER="${OSTLER_DIR}/state/dedupe-converge.done"
    mkdir -p "${OSTLER_DIR}/state" 2>/dev/null || true
    rm -f "$_DEDUPE_DONE_MARKER" 2>/dev/null || true

    # Run the converge pass in the BACKGROUND so we can (a) emit a liveness
    # heartbeat while it works and (b) enforce a hard time cap. The pass
    # writes all stdout to $_DEDUPE_LOG, so without a heartbeat the GUI
    # shows one line and then nothing for the whole run. On the .153
    # cold-wipe walk this step sat silent and read as a frozen install.
    # Heartbeat-only + cap: it does NOT change any merge rule, threshold,
    # or the non-fatal posture; the cap just bounds how long the customer
    # waits before the rest is finished in the background.
    (
        cd "$PIPELINE_DIR" && \
        OXIGRAPH_URL="${OXIGRAPH_URL:-http://localhost:7878}" \
        QDRANT_URL="${QDRANT_URL:-http://localhost:6333}" \
        .venv/bin/python3 -m identity_resolver.batch_resolver \
            --execute --converge \
            --output /tmp/ostler-dedupe-report.yaml \
        && touch "$_DEDUPE_DONE_MARKER"
    ) >>"$_DEDUPE_LOG" 2>&1 &
    _DEDUPE_PID=$!
    _DEDUPE_WAITED=0
    _DEDUPE_TIMED_OUT=false
    while kill -0 "$_DEDUPE_PID" 2>/dev/null; do
        sleep 30
        _DEDUPE_WAITED=$(( _DEDUPE_WAITED + 30 ))
        # Hard cap: once we exceed the install-time budget, stop waiting
        # synchronously. Kill the in-flight pass (a single converge round
        # is itself idempotent + non-destructive: it only merges nodes the
        # rules already approve, so terminating mid-loop just leaves the
        # remaining rounds for the background catch-up agent). The
        # batch_resolver --execute commits each merge as it goes, so no
        # work done so far is lost.
        if [[ "$_DEDUPE_WAITED" -ge "$_DEDUPE_BUDGET_S" ]] && kill -0 "$_DEDUPE_PID" 2>/dev/null; then
            _DEDUPE_TIMED_OUT=true
            kill "$_DEDUPE_PID" 2>/dev/null || true
            # Give it a moment to unwind, then hard-kill if still alive.
            sleep 2
            kill -9 "$_DEDUPE_PID" 2>/dev/null || true
            break
        fi
        # Guard with `if` (not `&&`) so a process that finished during the
        # sleep emits no stray line, and so a false result cannot trip the
        # script's `set -e` / ERR trap.
        if kill -0 "$_DEDUPE_PID" 2>/dev/null; then
            info "$(printf "$MSG_INFO_DEDUPE_STILL_MERGING" "${_DEDUPE_WAITED}")"
        fi
    done
    # The child has exited (or was capped); reap it for its real status.
    # `wait` in an `if` condition is errexit-exempt, so a non-zero exit
    # stays non-fatal.
    if [[ "$_DEDUPE_TIMED_OUT" == "true" ]]; then
        wait "$_DEDUPE_PID" 2>/dev/null || true
        info "$MSG_INFO_DEDUPE_DEFERRED_BACKGROUND"
    elif wait "$_DEDUPE_PID"; then
        info "$MSG_INFO_DEDUPE_MERGED"
    else
        warn "$(printf "$MSG_WARN_DEDUPE_INCOMPLETE" "$_DEDUPE_LOG")"
    fi

    # Defer-to-background: if the converge did NOT fully complete within
    # the install budget, install a bounded, self-removing LaunchAgent to
    # finish it post-install and trigger a wiki recompile. If it DID
    # complete (the .done marker exists), skip the agent entirely -- there
    # is nothing left to do.
    if [[ ! -f "$_DEDUPE_DONE_MARKER" ]]; then
        _install_dedupe_catchup_agent
    else
        info "$MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP"
    fi

    unset _DEDUPE_LOG _DEDUPE_PID _DEDUPE_WAITED _DEDUPE_BUDGET_S
    unset _DEDUPE_TIMED_OUT _DEDUPE_DONE_MARKER
fi

# People search index (#600) ---------------------------------------
#
# Populate the Qdrant `people` collection from Oxigraph. MUST run after
# the Oxigraph-populating steps above (hydrate_graph contacts/calendar +
# hydrate_imessage Person nodes): the sweep reads every pwg:Person from
# Oxigraph, embeds the display name with local Ollama, and upserts into
# `people` via ingest_people_to_qdrant, which self-creates the collection
# at 768-dim. The wiki People pages read Oxigraph directly and are
# unaffected; this is what makes the iOS People tab + Hub People-card +
# semantic search (which read the Qdrant `people` collection, filtered on
# contact_type == "person") show the customer's contacts instead of
# nothing. Counts-only stdout; no display names cross the boundary.
progress "Indexing your people for search" "hydrate_people"

_HYDRATE_PEOPLE_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_HYDRATE_PEOPLE_PY="${_HYDRATE_PEOPLE_VENV}/bin/python"

if _hydrate_sentinel_fresh "people"; then
    info "$MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA"
elif [[ -x "$_HYDRATE_PEOPLE_PY" ]]; then
    info "$MSG_HYDRATE_PEOPLE_STARTED"

    _HYDRATE_PEOPLE_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _HYDRATE_PEOPLE_TIMEOUT_WRAP="gtimeout 90"
    elif command -v timeout >/dev/null 2>&1; then
        _HYDRATE_PEOPLE_TIMEOUT_WRAP="timeout 90"
    fi

    _HYDRATE_PEOPLE_LOG=/tmp/ostler-hydrate-people.log
    _HYDRATE_PEOPLE_TIMED_OUT=false

    # Inline python so we call ingest_people_to_qdrant directly: it reads
    # pwg:Person from Oxigraph, embeds + upserts to Qdrant `people`, and
    # self-creates the collection. Output is the counts-only JSON.
    # #640-class guard (best-effort hydrate; see the browsing block above for
    # the full rationale): suppress the errtrace ERR trap + errexit around the
    # pwg_ingest command-sub so an in-subshell crash degrades to "skipped"
    # instead of aborting the whole install. Preserve rc for the timeout check.
    _saved_err_trap=$(trap -p ERR); trap - ERR; set +e
    _HYDRATE_PEOPLE_JSON="$(
        $_HYDRATE_PEOPLE_TIMEOUT_WRAP \
        "$_HYDRATE_PEOPLE_PY" -c "
import json
from ostler_fda.pwg_ingest import ingest_people_to_qdrant
result = ingest_people_to_qdrant()
print(json.dumps(result))
" 2>>"$_HYDRATE_PEOPLE_LOG" | tail -n 1
    )"
    rc=$?
    set -e; eval "${_saved_err_trap:-}"
    if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
        _HYDRATE_PEOPLE_TIMED_OUT=true
    fi

    if [[ "$_HYDRATE_PEOPLE_TIMED_OUT" == "true" ]]; then
        info "$MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES"
    elif [[ -n "$_HYDRATE_PEOPLE_JSON" ]]; then
        # Parse 'sent' for the customer-facing count. Counts-only dict.
        _HYDRATE_PEOPLE_SENT="$(
            printf '%s' "$_HYDRATE_PEOPLE_JSON" \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("sent", 0)))
except Exception:
    print(0)' 2>/dev/null
        )"
        _HYDRATE_PEOPLE_SENT="${_HYDRATE_PEOPLE_SENT:-0}"
        if [[ "$_HYDRATE_PEOPLE_SENT" -gt 0 ]]; then
            ok "$(printf "$MSG_HYDRATE_PEOPLE_DONE" "$_HYDRATE_PEOPLE_SENT")"
        else
            info "$MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA"
        fi
    else
        info "$MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA"
    fi

    # #48g sentinel record: dedupes re-runs within a 7-day window.
    _hydrate_sentinel_record "people" "sent=${_HYDRATE_PEOPLE_SENT:-0}"

    unset _HYDRATE_PEOPLE_TIMED_OUT _HYDRATE_PEOPLE_JSON
    unset _HYDRATE_PEOPLE_SENT _HYDRATE_PEOPLE_TIMEOUT_WRAP _HYDRATE_PEOPLE_LOG
else
    info "$MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING"
fi

unset _HYDRATE_PEOPLE_VENV _HYDRATE_PEOPLE_PY

# Preferences install-time ingest now runs earlier, at phase 3.12b,
# through the shared ostler-import fan-out (CM041 contacts + CM019
# preferences) over Downloads + the drop-zone -- collapsed there so
# there is one importer and one ingest path, not a second standalone
# block here. The Downloads watcher (3.13) catches later arrivals.

# ══════════════════════════════════════════════════════════════════════
# initial_hydrate (CX-106, DMG #48l, 2026-05-29)
# ──────────────────────────────────────────────────────────────────────
# Synchronous "first-load" sweep that guarantees the customer's
# wiki has at least SOME real content (not just scaffolding) before
# wiki_compile runs. The per-source hydrate_* blocks above each
# write to Oxigraph (graph triples); they DO NOT guarantee that
# Qdrant collections exist. Without Qdrant collections the Ostler.app
# Hub readiness probe never flips green and the customer stares at
# "Hub starting up..." indefinitely.
#
# What this step does:
#   1. Probes Qdrant /collections. If at least one collection exists,
#      we trust the per-source hydrate_* runs above and short-circuit.
#   2. If Qdrant is empty, re-runs ostler_fda.pwg_ingest.
#      ingest_browser_history (which POSTs through the gateway, which
#      writes to Qdrant). The Safari history JSON is the most reliable
#      Qdrant-populating source -- almost every Mac has months of
#      Safari history and 4,000+ visits is typical.
#   3. Polls Qdrant /collections again after the ingest to confirm
#      at least one collection landed. Time-capped (90s) so a busted
#      gateway never blocks install.
#   4. Emits explicit log markers (CX106_QDRANT_*, CX106_BROWSER_*) the
#      GUI sidebar parses to surface the step's state to the customer.
#
# Total install-time delta: 0-90s depending on gateway responsiveness.
# Healthy gateway + already-populated Qdrant short-circuits in <1s.
# This is a noticeable but acceptable extension to the install runtime;
# the alternative is shipping with "Hub starting up..." indefinite as
# customer-facing first-impression UX, which is unshippable for v1.0.
progress "Loading your data into Ostler" "initial_hydrate"

_INITIAL_HYDRATE_QDRANT="${QDRANT_URL:-http://localhost:6333}"
_INITIAL_HYDRATE_FDA_DIR="${OSTLER_DIR}/imports/fda"
_INITIAL_HYDRATE_VENV="${OSTLER_DIR}/services/email-ingest/.venv"
_INITIAL_HYDRATE_PY="${_INITIAL_HYDRATE_VENV}/bin/python"
_INITIAL_HYDRATE_LOG=/tmp/ostler-initial-hydrate.log
: >"$_INITIAL_HYDRATE_LOG"

# Probe Qdrant collections count. The /collections endpoint returns
# {"result": {"collections": [{...}, ...]}, ...} on a healthy Qdrant.
# Counts-only -- no name leakage off-machine.
_initial_hydrate_qdrant_count() {
    local raw count
    raw="$(curl -sf -m 5 "${_INITIAL_HYDRATE_QDRANT}/collections" 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
        printf '0'
        return 0
    fi
    count="$(printf '%s' "$raw" \
        | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(len((d.get("result") or {}).get("collections") or []))
except Exception:
    print(0)' 2>/dev/null)"
    count="${count:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s' "$count"
}

_INITIAL_HYDRATE_COLLECTIONS_BEFORE="$(_initial_hydrate_qdrant_count)"
gui_emit CX106_QDRANT_BEFORE "count=${_INITIAL_HYDRATE_COLLECTIONS_BEFORE}"
info "$(printf "$MSG_INITIAL_HYDRATE_QDRANT_BEFORE" "${_INITIAL_HYDRATE_COLLECTIONS_BEFORE}")"

# Re-run the gateway-driven browser history ingest if Qdrant is empty.
# The first hydrate_browsing call (line ~10889) may have raced ahead
# of the gateway's first-collection setup; this is the deliberate retry
# inside install completion, with a long enough timeout that a slow
# gateway start (Docker image cold-start, first-request JIT) does not
# silently leave Qdrant empty.
if [[ "$_INITIAL_HYDRATE_COLLECTIONS_BEFORE" -eq 0 ]] \
   && [[ -x "$_INITIAL_HYDRATE_PY" ]] \
   && { [[ -s "${_INITIAL_HYDRATE_FDA_DIR}/safari_history.json" ]] \
        || [[ -s "${_INITIAL_HYDRATE_FDA_DIR}/chrome_history.json" ]]; }; then
    info "$MSG_INITIAL_HYDRATE_BROWSER_RETRY"

    _INITIAL_HYDRATE_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _INITIAL_HYDRATE_TIMEOUT_WRAP="gtimeout 90"
    elif command -v timeout >/dev/null 2>&1; then
        _INITIAL_HYDRATE_TIMEOUT_WRAP="timeout 90"
    fi

    $_INITIAL_HYDRATE_TIMEOUT_WRAP \
    "$_INITIAL_HYDRATE_PY" -c "
import json
from pathlib import Path
from ostler_fda.pwg_ingest import ingest_browser_history
try:
    result = ingest_browser_history(Path('${_INITIAL_HYDRATE_FDA_DIR}'))
    print(json.dumps(result))
except Exception as exc:
    print(json.dumps({'status': 'error', 'error': type(exc).__name__}))
" >>"$_INITIAL_HYDRATE_LOG" 2>&1 || true

    # Poll Qdrant for up to 30s while the gateway writes through. The
    # first POST creates the collection lazily, so the count flips from
    # 0 to >=1 only after the first successful upsert is committed.
    _INITIAL_HYDRATE_POLL_ELAPSED=0
    while [[ "$_INITIAL_HYDRATE_POLL_ELAPSED" -lt 30 ]]; do
        if [[ "$(_initial_hydrate_qdrant_count)" -gt 0 ]]; then
            break
        fi
        sleep 2
        _INITIAL_HYDRATE_POLL_ELAPSED=$((_INITIAL_HYDRATE_POLL_ELAPSED + 2))
    done
    unset _INITIAL_HYDRATE_POLL_ELAPSED _INITIAL_HYDRATE_TIMEOUT_WRAP
fi

_INITIAL_HYDRATE_COLLECTIONS_AFTER="$(_initial_hydrate_qdrant_count)"
gui_emit CX106_QDRANT_AFTER "count=${_INITIAL_HYDRATE_COLLECTIONS_AFTER}"

if [[ "$_INITIAL_HYDRATE_COLLECTIONS_AFTER" -gt 0 ]]; then
    ok "$(printf "$MSG_INITIAL_HYDRATE_QDRANT_READY" "${_INITIAL_HYDRATE_COLLECTIONS_AFTER}")"
else
    # Qdrant still empty -- Hub readiness will be deferred to first-run
    # background ingest. Doctor will pick it up and surface the gap.
    # We do NOT fail install here; the rest of the system is fine and
    # the wiki + LaunchAgents continue to work.
    info "$MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED"
fi

# DEDUPE_MERGE (#661, RULE 1, 2026-06-09): after every person-creating
# writer above (hydrate_graph contacts/calendar, the per-source FDA
# ingest, contact_syncer, and initial_hydrate) and BEFORE wiki_compile
# below, fold any Person nodes that share an EXACT identifier value (same
# email or phone string) into one -- regardless of source or display
# name. This is the only place the cross-source case gets merged: the
# iMessage / WhatsApp ingest (pwg_ingest) mints its own uuid5 Person URIs
# and never consults the identity resolver, so its people stay split from
# the Contacts people until this graph-level sweep folds them. Running it
# here means the wiki, the iOS People view and the Doctor API all render
# merged people. Best-effort + idempotent (a re-run finds nothing): a
# failure is logged and install continues. The fuzzy no-shared-identifier
# case (BW-2) is deliberately NOT touched. Output goes to the install log,
# not a user-facing string -- internal plumbing.
if [[ -x "$_INITIAL_HYDRATE_PY" ]]; then
    "$_INITIAL_HYDRATE_PY" -c "
from ostler_fda.dedupe_merge import run
import json
try:
    print('dedupe_merge:', json.dumps(run()))
except Exception as exc:
    print('dedupe_merge failed:', type(exc).__name__, exc)
" >>"$_INITIAL_HYDRATE_LOG" 2>&1 || true
fi

unset _INITIAL_HYDRATE_QDRANT _INITIAL_HYDRATE_FDA_DIR
unset _INITIAL_HYDRATE_VENV _INITIAL_HYDRATE_PY _INITIAL_HYDRATE_LOG
unset _INITIAL_HYDRATE_COLLECTIONS_BEFORE _INITIAL_HYDRATE_COLLECTIONS_AFTER

# PLACES INGEST (CM044 Places section, 2026-06-19). The wiki Places page
# (CM044 compiler/pages/place_pages.py) reads ONLY the Qdrant `preferences`
# collection filtered to category=place. Nothing ever wrote those points, so
# the page always rendered its empty state even though the graph holds real
# location signals: every meeting carries a pwg:meetingLocation literal (96
# meetings / dozens of distinct strings on Andy's box) and nothing ever
# promoted those into a browsable Place. This step closes that leg with NO
# CM044 change: it reads pwg:meetingLocation (+ pwg:photoPlace if present)
# back out of Oxigraph, de-dupes by normalised string, and upserts one
# area_preference point per distinct place into preferences/category=place
# with the exact payload shape place_pages.py reads.
#
# Ordering: runs AFTER every Oxigraph writer above (hydrate_graph
# contacts/calendar -> meeting locations land here) and the dedupe_merge
# sweep, and BEFORE wiki_compile, so the first wiki compile already sees a
# populated Places section. The contact_syncer.places_ingest module ships in
# the import-pipeline venv (${PIPELINE_DIR}/.venv) alongside contact_syncer.syncer
# -- same venv that carries httpx + qdrant-client. Best-effort + idempotent
# (deterministic uuid5 point IDs): a failure is logged and install continues;
# a re-run upserts the same points rather than duplicating them.
#
# Guard on the venv python derived from $PIPELINE_DIR (the in-scope var the
# body's `cd "$PIPELINE_DIR" && .venv/bin/python` already uses), NOT a bare
# $PIPELINE_PY: that name is only ever assigned inside the generated
# ostler-contact-resync heredoc, never in this script's own scope, so under
# `set -u` the test aborted the whole install (ERR-99 initial_hydrate). The
# ${PIPELINE_DIR:-} default keeps the test set -u-safe even if unset.
if [[ -x "${PIPELINE_DIR:-}/.venv/bin/python" ]]; then
    info "$MSG_HYDRATE_PLACES_STARTED"
    _PLACES_EMBED_URL="${EMBED_OLLAMA_URL:-http://localhost:11434}"
    _PLACES_EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
    _PLACES_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _PLACES_TIMEOUT_WRAP="gtimeout 120"
    elif command -v timeout >/dev/null 2>&1; then
        _PLACES_TIMEOUT_WRAP="timeout 120"
    fi
    # Capture the exit code explicitly (do NOT collapse to `&& ok || info`):
    # the module exits 0 for BOTH success AND the benign no-signals case, and
    # exits non-zero ONLY on a real failure -- its own loud guard
    # (status=error_empty_result: signals present but 0 Place points), a
    # config error, or an unexpected crash. Mapping every non-zero to the
    # benign "no signals yet" message silenced exactly the silent-failure
    # class the guard exists for. So: branch on the exit code, and on failure
    # grep the log for the guard signature to choose a precise, VISIBLE warn.
    # `|| _places_rc=$?` keeps `set -e` from aborting the install on a
    # non-zero places exit (this step is best-effort + non-fatal); _places_rc
    # defaults to 0 and is overwritten only on failure.
    _places_rc=0
    (
        cd "$PIPELINE_DIR" \
        && OXIGRAPH_URL="${OXIGRAPH_URL:-http://localhost:7878}" \
           QDRANT_URL="${QDRANT_URL:-http://localhost:6333}" \
           EMBED_OLLAMA_URL="$_PLACES_EMBED_URL" \
           EMBED_MODEL="$_PLACES_EMBED_MODEL" \
           $_PLACES_TIMEOUT_WRAP \
           .venv/bin/python -m contact_syncer.places_ingest --verbose
    ) >>/tmp/ostler-places-ingest.log 2>&1 || _places_rc=$?
    # The log is appended across runs (>>); only this run's tail is relevant,
    # so scope the signature greps to the tail rather than the whole file.
    _places_log_tail="$(tail -n 40 /tmp/ostler-places-ingest.log 2>/dev/null)"
    if [[ "$_places_rc" -eq 0 ]]; then
        # Success. Distinguish "built some Places" from the genuinely benign
        # "no location signals yet" case (module prints "0 meeting locations
        # + 0 photo places") so the no-signals message stays honest.
        if printf '%s' "$_places_log_tail" \
                | grep -q "from 0 meeting locations + 0 photo places"; then
            info "$MSG_HYDRATE_PLACES_SKIPPED"
        else
            ok "$MSG_HYDRATE_PLACES_DONE"
        fi
    elif printf '%s' "$_places_log_tail" | grep -q "PLACES INGEST GUARD"; then
        # The module's own loud guard fired: signals exist but no Places were
        # produced/written. Surface it loudly (non-fatal: a re-run is safe).
        warn "$MSG_HYDRATE_PLACES_GUARD_WARN"
    else
        # Non-zero exit with no guard line = config error / unexpected crash.
        # Still non-fatal, but visible -- not mislabelled as "no signals yet".
        warn "$MSG_HYDRATE_PLACES_ERROR_WARN"
    fi
    _hydrate_sentinel_record "places" "status=run rc=$_places_rc"
    unset _PLACES_EMBED_URL _PLACES_EMBED_MODEL _PLACES_TIMEOUT_WRAP \
          _places_rc _places_log_tail
fi

info "$MSG_HYDRATE_WIKI_RECOMPILE"

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
# v1.0.1 -- background the wiki summaries so the install completes fast.
#
# The first compile generates ~340 synchronous LLM summaries (top people
# + orgs + topics) at ~10-13s each: 30-60 min on a large address book,
# during which the installer used to sit frozen at 100%. We now split it:
#
#   1. BASELINE compile with OSTLER_WIKI_SKIP_LLM=1 (honoured by the CM044
#      compiler): renders every page skeleton with NO LLM calls, finishes
#      in ~1-2 min. This is the one that gates the install -- it is fast
#      and must succeed.
#   2. Bring wiki-site up immediately so :8044 serves the baseline wiki.
#   3. The install completes here. The customer has a browsable wiki.
#   4. Kick the FULL summary compile (summaries ON) in the BACKGROUND,
#      fully detached. It writes .hydration_status.json live so the
#      homepage panel reflects progress; the summaries replace the
#      skeletons as they land. Its exit code NEVER gates the install -- a
#      background failure leaves the already-serving baseline wiki intact.
#
# `-T </dev/null` cures the `compose run --rm` exit-hang (see the
# wiki-recompile LaunchAgent). The baseline pipe is wrapped in set +e so
# its real exit code (PIPESTATUS[0], not tail's) gates the install under
# `set -euo pipefail`.
set +e
docker compose --profile compile run --rm -T \
    -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler </dev/null 2>&1 | tail -10
WIKI_BASELINE_RC=${PIPESTATUS[0]:-0}
set -e
if [ "$WIKI_BASELINE_RC" -eq 0 ]; then
    # Publish the baseline. The wiki-site container now runs a static server
    # (CM044 docker/wiki-site-serve.py) that builds the HTML off the serving
    # path and picks up a finished compile by polling the compiler's
    # .compile-complete marker -- so a plain `up -d` suffices and NO
    # --force-recreate is needed. The old force-recreate existed only because
    # `mkdocs serve` could not see cross-container volume writes via inotify and
    # had to be restarted (#598); that restart WAS the recompile-window 000 the
    # static server removes. Identical publish primitive to
    # wiki-recompile-tick.sh.
    if docker compose up -d wiki-site 2>&1 | tail -3; then
        WIKI_FIRST_COMPILE_OK=true
        ok "$MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044"
        # Detached full summary compile (summaries ON -- no skip flag).
        # nohup + </dev/null + disown so it survives install.sh exit and
        # its exit code can never gate install completion.
        WIKI_BG_LOG="${LOGS_DIR}/wiki-background-compile.log"
        # --- Shared background-LLM slot lock (v1.0.0 chat-saturation fix) --
        # This first-run full-summary compile is the single biggest Ollama
        # producer on the box. It MUST share the one background-LLM slot lock
        # with the conversation feeds (*-bundle-tick.sh). Without it, the
        # backfill + one conversation feed run at once, fill both
        # OLLAMA_NUM_PARALLEL=2 slots, and live chat (app AND iMessage /
        # WhatsApp / email replies -- all go through the daemon's /api/chat)
        # starves: measured 277s + truncated under load vs 1.5s idle on the
        # .149 box. Holding the lock for the whole compile keeps background
        # Ollama concurrency at 1, so the 2nd parallel slot is always free for
        # a live reply.
        #
        # Blocking acquire with PID-LIVENESS reclaim (NOT a time-based steal):
        # a real summary compile legitimately runs for hours, so any time
        # threshold would let a conversation tick wrongly steal the lock mid
        # compile. We reclaim only when the recorded holder PID is dead.
        # ${OSTLER_INGEST_LOCK} is the identical path the tick wrappers use.
        _wiki_slot="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
        nohup bash -c '
            set -u
            _slot="$1"; _wd="$2"
            cd "$_wd" || exit 1
            mkdir -p "$(dirname "$_slot")" 2>/dev/null || true
            while ! mkdir "$_slot" 2>/dev/null; do
                _h="$(cat "$_slot/pid" 2>/dev/null || true)"
                if [ -n "${_h:-}" ] && kill -0 "$_h" 2>/dev/null; then
                    sleep 10
                else
                    rm -rf "$_slot" 2>/dev/null || true
                fi
            done
            printf "%s\n" "$$" > "$_slot/pid"
            trap "rm -rf \"$_slot\" 2>/dev/null || true" EXIT
            docker compose --profile compile run --rm -T wiki-compiler </dev/null
        ' _ "$_wiki_slot" "$OSTLER_DIR" >"$WIKI_BG_LOG" 2>&1 &
        disown 2>/dev/null || true
        info "$MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED"
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

# CX-48 (DMG #29, 2026-05-24): also fire gui_step_begin so the
# sidebar's `health_check` row flips from empty-circle to spinning,
# then to ok-check when the trailing gui_step_end at the script's
# tail closes it. Pre-fix the row stayed at "○" for the entire
# Phase 4 (`step` only sets the phase title, not the per-step state)
# then jumped straight to "Done" -- confusing because the customer
# sees the row never visibly complete.
if [[ -n "${__OSTLER_STEP_ID:-}" ]]; then
    gui_step_end ok
fi
__OSTLER_STEP_ID="health_check"
gui_step_begin "health_check" "$MSG_STEP_RUNNING_HEALTH_CHECK" 3 "$CURRENT_STEP" "$TOTAL_STEPS"

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

# ── Personal-context digest refresh (#608) ──────────────────────
#
# Wires the context-refresh LaunchAgent. generate_pwg_context.py
# (vendored from ostler-assistant) queries the loopback ical-server
# (now populated by the hydrate steps above) and writes CONTEXT.md
# into the assistant-config dir. The assistant daemon injects
# CONTEXT.md into every system prompt, so the chat assistant has
# baseline awareness of the customer's people, meetings and
# preferences. Without this the assistant answers "I have no access
# to your data" -- the #608 launch blocker.
#
# Sourced HERE (after initial_hydrate) on purpose: the ical-server is
# up from Phase 3.13a, but only carries data once the graph is
# hydrated. Installing the LaunchAgent now means its RunAtLoad fires a
# FIRST, POPULATED digest immediately, rather than an empty one that
# waits for the next scheduled fire.
#
# Bundled-with-installer pattern mirrors wiki-recompile. A missing
# bundle is a warn, not a hard fail: the assistant still answers via
# live http_request lookups ([http_request] allow_private_hosts was
# enabled in the wizard config above); the digest is the always-on
# baseline that saves a lookup round-trip on common questions.

OSTLER_CONTEXT_REFRESH_DIR="${OSTLER_DIR}/context-refresh"
CONTEXT_REFRESH_SNIPPET=""

if [[ -d "${SCRIPT_DIR}/context-refresh" && -f "${SCRIPT_DIR}/context-refresh/INSTALL_SNIPPET.sh" ]]; then
    mkdir -p "$OSTLER_CONTEXT_REFRESH_DIR"
    cp -R "${SCRIPT_DIR}/context-refresh/"* "$OSTLER_CONTEXT_REFRESH_DIR/"
    CONTEXT_REFRESH_SNIPPET="${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh"
    ok "$MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED"
elif [[ -f "${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh" ]]; then
    CONTEXT_REFRESH_SNIPPET="${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh"
    info "$(printf "$MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH" "${OSTLER_CONTEXT_REFRESH_DIR}")"
else
    warn "$MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED"
fi

if [[ -n "$CONTEXT_REFRESH_SNIPPET" && -f "$CONTEXT_REFRESH_SNIPPET" ]]; then
    if OSTLER_INSTALL_ROOT="$OSTLER_CONTEXT_REFRESH_DIR" \
       OSTLER_DIR="$OSTLER_DIR" \
       LOGS_DIR="$LOGS_DIR" \
       bash "${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh"; then
        ok "$MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED"
        info "$(printf "$MSG_INFO_CONTEXT_REFRESH_LOGS" "${LOGS_DIR}")"
    else
        warn "$MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED"
    fi
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
    # .152 walk (2026-06-16): the assistant's outbound-iMessage bridge
    # drives the MAIN Messages.app via AppleScript. When Messages.app is
    # not running, the send AppleEvent waits for it to cold-launch and
    # times out with "AppleEvent timed out (-1712)" -- the welcome
    # iMessage (and every later brief) silently never leaves the box.
    # Warm Messages.app now so it is already up for the Automation probe
    # below (a cold Messages can also -1712 the probe's `count of
    # accounts`) and for the post-install welcome message. `-g` keeps it
    # in the background (no focus steal mid-install) and `-a Messages`
    # launches the main app via LaunchServices. Best-effort + non-fatal:
    # a failure here must never abort the install.
    open -ga Messages 2>/dev/null || true

    # CX-55 (DMG #30, 2026-05-24): pre-warn the customer that the
    # next step will trigger macOS's "OstlerInstaller wants to control
    # Messages" Automation permission dialog. Without warning, the
    # dialog appears unannounced + customers think the installer has
    # gone rogue. Blocking ack means they read it, then know to click
    # Allow on the popup that follows. Suppressed under TTY/CI.
    #
    # CX-DMG44 timing separation (DMG #44, 2026-05-25): when the
    # iMessage FDA assist dialog (line ~6940) closed moments ago,
    # firing this Automation pre-warn within 200 ms left the
    # customer flat-staring at two stacked modals. Add a short
    # cooldown + status line so the transition reads as deliberate
    # rather than as a second dialog ambushing the user.
    #
    # v1.0.2 (P1): when the Automation prompt was already FRONT-LOADED in
    # Phase 2 (IMESSAGE_AUTOMATION_PRIMED_EARLY), skip the pre-warn modal
    # here -- the grant is already given, so the read-only probe below
    # fires NO new prompt. This block then only RE-records the
    # authoritative posture snapshot; it never ambushes the customer with
    # a second "wants to control Messages" dialog after the success banner.
    if [[ "${OSTLER_GUI:-0}" == "1" && "${IMESSAGE_AUTOMATION_PRIMED_EARLY:-false}" != "true" ]]; then
        info "$MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION"
        sleep 3
        _="$(gui_read \
            "$MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE" \
            acknowledge \
            "" \
            "$MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP" \
            "" \
            "imessage_automation_incoming_ack")"
    fi
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
            # CX-112 (DMG #48l, 2026-05-29): surface a clear post-install
            # nudge in GUI installs so the customer is not left guessing
            # whether iMessage is wired up. The Phase 4 health-check ran
            # tcc-denied silently before -- only the warn lines above
            # appeared, with no actionable next step. Now we open the
            # Automation pane directly and emit a structured GUI marker
            # so the install completion screen can render a "iMessage
            # isn't connected -- grant access" callout. v1.0.1 will
            # add a non-blocking "Grant now" modal here; for v1.0 we
            # stop short of an extra modal so we don't risk regressing
            # the install completion flow this close to launch.
            if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" \
                    >/dev/null 2>&1 || true
                gui_emit IMESSAGE_TCC_DENIED "status=denied" "remediation=automation_pane"
                info "$MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED"
            fi
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
    # Pick a timeout wrapper, mirroring the hydrate_* steps. brew
    # coreutils ships gtimeout; some toolchains ship plain timeout. Stock
    # macOS ships NEITHER -- the old bare `timeout 10` was always a
    # command-not-found there, so this probe never actually ran doctor.
    # Empty wrapper -> call the daemon directly (its own startup is fast).
    _DOCTOR_TIMEOUT_WRAP=""
    if command -v gtimeout >/dev/null 2>&1; then
        _DOCTOR_TIMEOUT_WRAP="gtimeout 10"
    elif command -v timeout >/dev/null 2>&1; then
        _DOCTOR_TIMEOUT_WRAP="timeout 10"
    fi
    # The daemon may still be booting, so a non-zero `doctor` here is
    # expected and deferred (the `||` fallback handles it). The load-
    # bearing bit: `set -E` (errtrace) propagates the abort-on-error ERR
    # trap INTO the $(...) command-substitution subshell, so ANY non-zero
    # inside it (a warming daemon, or -- on stock macOS -- the absent
    # `timeout` returning 127) fires _ostler_on_err -> gui_done fail FROM
    # the subshell, false-failing an otherwise-successful install
    # (CX-122 / #640; reproduced + verified on Studio bash 3.2.57, no
    # timeout, via the ERR-trap ledger). The outer `||` only guards the
    # parent assignment, not the inherited in-subshell trap. Suppress the
    # ERR trap for exactly this probe, then restore the abort handler.
    _saved_err_trap=$(trap -p ERR)
    trap - ERR
    DOCTOR_OUTPUT=$($_DOCTOR_TIMEOUT_WRAP "${ASSISTANT_BINARY}" doctor 2>&1) || \
        DOCTOR_OUTPUT="__DOCTOR_INVOCATION_FAILED__"
    eval "${_saved_err_trap:-}"

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
    # CX-53 (DMG ship, 2026-05-24): emit a structured RECOVERY_KEY
    # marker for the GUI installer BEFORE rendering anything to the
    # TTY. The Swift coordinator pulls the value into a dedicated
    # @Published property and renders a RecoveryKeyView sheet with
    # Copy / Save PDF / Print + confirm-checkbox controls; the TTY
    # path keeps the YELLOW BOLD echo below for terminal customers.
    # We DELIBERATELY do NOT emit a LOG marker carrying the recovery
    # key value -- LOG markers land in the GUI Log drawer (visible
    # to anyone the customer hands the laptop to). The RECOVERY_KEY
    # marker bypasses logLines on the Swift side.
    gui_emit RECOVERY_KEY "value=$RECOVERY_KEY"
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
            # First-launch registration: Safari only surfaces a Web Extension
            # after its containing app has been launched at least once
            # (LaunchServices registration). Launch it headlessly (-gj: in the
            # background, hidden) so the extension appears in Safari Settings ->
            # Extensions without the user hunting for it. Fire and forget;
            # macOS will not let an installer programmatically enable the
            # extension -- the user must tick the box themselves (see below).
            if [[ -d "$SAFARI_APP_INSTALL_PATH" ]]; then
                open -gj -a "$SAFARI_APP_INSTALL_PATH" 2>/dev/null || true
            fi
            # The enable step is a macOS-mandated MANUAL action and cannot be
            # automated; point the user straight at the toggle.
            echo "     $MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE"
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

# ── First-month-free subscription activation (G2) ─────────────────
#
# The GUI verified the customer's Ed25519-signed licence file before
# exec'ing this script (see the "Licence / activation check" block
# higher up + LicenseVerifier.swift). By the time we reach this
# point install.sh has run to completion against a verified licence,
# so this is the canonical "after licence verification succeeds"
# mount point in the post-install lifecycle. Wire the customer's Hub
# to 30 days of Ostler Pro for free per the G0 subscription_gate
# contract (PR #190) -- single source of truth for whether ongoing
# intelligence runs.
#
# Fail-open posture: if the Python call fails for ANY reason
# (vendored helper missing, state dir not writable, disk full), the
# install MUST continue. The customer can re-activate via the iOS
# Companion once paired. We never block a legitimate customer on a
# subscription-state write failure.
info "$MSG_INFO_FIRST_MONTH_FREE_ACTIVATING"
if python3 -c "
import sys, os
# The .app build (gui/project.yml postBuildScript L487-514) intentionally
# strips the 'vendor/cm041/' wrapper and bundles assistant_api/ directly
# at SCRIPT_DIR root, matching the ical-server staging convention at
# install.sh L6886. Tarball / dev-tree runs still ship the wrapper, so we
# try the bundled path first, then fall back to the dev layout.
_bundled = os.path.join('${SCRIPT_DIR}', 'assistant_api')
_dev = os.path.join('${SCRIPT_DIR}', 'vendor', 'cm041', 'assistant_api')
for _p in (_bundled, _dev):
    if os.path.isdir(_p):
        sys.path.insert(0, _p)
        break
from subscription_gate import activate_first_month_free
from datetime import datetime, timezone
activate_first_month_free(datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
" 2>&1; then
    ok "$MSG_OK_FIRST_MONTH_FREE_ACTIVATED"
else
    # NON-FATAL: install continues. Customer can re-activate via
    # Companion later. Per fail-open: never block install on
    # subscription-state write failure.
    warn "$MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL"
fi

# ── Final assistant-daemon restart (FDA inheritance) ───────────────
#
# .152 walk (2026-06-16): iMessage was DEAD on a fresh install until
# the assistant daemon was manually restarted. macOS evaluates Full
# Disk Access at PROCESS LAUNCH. The assistant LaunchAgent is loaded
# during the assistant-setup phase (~L11146), which runs BEFORE the
# customer has dragged OstlerAssistant.app into the FDA pane during
# the in-context FDA assist (~L11321). So the long-lived daemon spawns
# WITHOUT FDA and keeps failing to open chat.db ("unable to open
# database file: chat.db; restarting") for the rest of its life.
#
# The in-context assist DOES kickstart the daemon (~L11475), but only
# when its post-grant re-probe reports "granted". TCC.db can lag a
# second or two behind the customer's drag-grant, so on a slow fresh
# Mac that re-probe routinely reports "still pending", the conditional
# kickstart is skipped, and the daemon never inherits the access the
# customer just granted. The Doctor card then re-probes live and reads
# "granted", but nothing has restarted the daemon process itself.
#
# Fix: one unconditional, idempotent kickstart at the very end of the
# install -- after every permission flow (installer FDA, daemon FDA,
# iMessage Automation, the Phase 4 health-check) has had its turn.
# `launchctl kickstart -k` restarts the agent in place so the freshly
# granted TCC posture takes effect; it is a no-op if the agent is not
# loaded. Gated on the iMessage channel being enabled (the only channel
# that needs daemon-level FDA on chat.db) and best-effort / non-fatal so
# it can never abort a successful install.
if [[ "${CHANNEL_IMESSAGE_ENABLED:-false}" == true ]]; then
    info "$MSG_INFO_ASSISTANT_FINAL_RESTART_FDA"
    launchctl kickstart -k "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
fi

# ── Summary ────────────────────────────────────────────────────────

# CX-123 (#643): everything from here to `gui_done ok` below is the
# DISPLAY-ONLY success recap. An unset OPTIONAL variable in here must NEVER
# be able to abort the install before the DONE marker is emitted: a
# `set -u` abort exits the script with no `gui_done ok`, so the GUI infers
# a failure on a fully-successful install. This has false-failed cut after
# cut on a different unguarded var each path (CONTACT_COUNT at L13455,
# EXPORTS_DIR, FV_ENABLED, the channel flags, ...). Disabling nounset for
# the whole recap neutralises ALL of them at once, including any bare echo
# var. errexit (-e) and the ERR trap stay ACTIVE, so a genuine command
# failure still aborts correctly; only the unbound-variable abort is
# suppressed. nounset is restored immediately after gui_done ok.
_cx123_nounset_was_on=0
case "$-" in *u*) _cx123_nounset_was_on=1 ;; esac
set +u

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

# Subscription pricing hint -- surfaces the $9.99 USD/mo post-trial
# pricing so the customer is never surprised when their first 30
# days expire and the iOS Companion offers a subscription. Routed
# through info() so it lands in both the TTY log and the GUI sidebar.
# USD is canonical for v1.0 launch (locked 2026-05-27).
info "$MSG_INFO_SUBSCRIPTION_PRICING_HINT"
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
        echo -e "        ${BOLD}${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant setup channels --interactive whatsapp${NC}"
        echo "     3. Enter the 8-digit code shown by the assistant into"
        echo "        the WhatsApp app on your phone."
    fi
elif [[ -n "${CHANNEL_CHOICE:-}" && "$CHANNEL_CHOICE" == "4" ]]; then
    echo ""
    echo "  No channels configured. Set one up later via:"
    echo "     ${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant setup channels --interactive"
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

# CX-123 (#643): restore nounset now the display-only recap + the DONE
# marker are emitted. The remaining post-success steps (icon cache-bust,
# Dock restart, browser open) are loop-local / ${VAR:-} guarded, so they
# run safely under set -u again.
[[ "${_cx123_nounset_was_on:-0}" == 1 ]] && set -u

# ── App-icon cache-bust ────────────────────────────────────────────
# The .app bundles are placed by the DMG drag-install, so macOS can
# show a stale soft icon from the iconservices cache. Touch each
# bundle to bump its mtime and nudge Dock to re-read the icons. This
# is best-effort and non-destructive (no cache deletion); every step
# is guarded so it can never abort the install.
for app in "/Applications/Ostler.app" "/Applications/Ostler RemoteCapture.app" "/Applications/OstlerInstaller.app"; do
    [[ -d "$app" ]] && touch "$app" 2>/dev/null || true
done
killall Dock 2>/dev/null || true

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

# CX-41 (DMG #27, 2026-05-24): launch Ostler.app at the end of a
# successful install so the customer knows the Hub UI exists.
# Without this they finish the installer + close the .app + have no
# obvious way to know there's an Ostler app to interact with. Open
# is best-effort -- if for any reason /Applications/Ostler.app
# isn't there (warn-only from earlier phase), this no-ops silently.
if [[ -d "/Applications/Ostler.app" ]]; then
    open -gj "/Applications/Ostler.app" 2>/dev/null || true
fi
