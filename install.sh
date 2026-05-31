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
# Conversations/ is intentionally absent for now; it lands in a
# follow-up PR once the brief's zoning question is resolved.
USER_TREE_SUBDIRS=("Wiki" "Transcripts" "Daily-Briefs" "Captures" "Exports")

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
    gui_active()      { return 1; }
    gui_needs_sudo()  { :; }
    gui_needs_fda()   { :; }
fi
unset _ostler_emitter_candidate

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
# .ics file inside. macOS Sequoia 15.x writes to ~/Library/Calendars/
# Calendar Cache; older macOS uses Calendar.sqlitedb. Both checked.
_store_populated_calendar() {
    local cal_dir="${HOME}/Library/Calendars"
    [[ -d "$cal_dir" ]] || return 1
    local cache="$cal_dir/Calendar Cache"
    local sqlitedb="$cal_dir/Calendar.sqlitedb"
    local probe_db=""
    [[ -f "$cache" ]] && probe_db="$cache"
    [[ -z "$probe_db" && -f "$sqlitedb" ]] && probe_db="$sqlitedb"
    if [[ -n "$probe_db" ]]; then
        local n
        n="$(sqlite3 "file:${probe_db}?mode=ro" -bail \
            "SELECT COUNT(*) FROM CalendarItem LIMIT 1" 2>/dev/null || echo 0)"
        n="${n:-0}"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [[ "$n" -gt 0 ]] && return 0
    fi
    # Fallback: any .ics under any .calendar bundle
    if find "$cal_dir" -maxdepth 3 -type f -name '*.ics' -print -quit 2>/dev/null | grep -q .; then
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
echo -e "    7. ${BOLD}Full Disk Access (installer)${NC}     Read Safari, Notes etc."
echo -e "    8. ${BOLD}Full Disk Access (daemon)${NC}        Read iMessage history"
echo -e "    9. ${BOLD}Messages automation${NC}    Send + receive iMessages as you"
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

cat <<MENU

  Three presets, or pick each one yourself:

    [1] Recommended  Safari history + bookmarks, Notes, Calendar,
                     Reminders, iMessage, Apple Mail. The everyday
                     sources -- privacy-friendly, all local.

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

# EVERYTHING adds whatsapp_history + chrome_history conditionally -- the
# extractors throw FileNotFoundError if the source DB is missing, so it
# is safe to list them, but skipping the listing when the app isn't
# installed keeps the post-install summary honest ("Found 0 WhatsApp
# people" reads as a bug; not listing the source reads as fine).
EVERYTHING="${RECOMMENDED},photos_metadata"
if [[ "$HAS_WHATSAPP_DESKTOP" == true ]]; then
    EVERYTHING="${EVERYTHING},whatsapp_history"
fi
if [[ "$HAS_CHROME" == true ]]; then
    EVERYTHING="${EVERYTHING},chrome_history"
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
    until /usr/bin/xcode-select -p &>/dev/null; do
        if [[ $XCODE_WAIT -ge $XCODE_TIMEOUT ]]; then
            fail_with_code "ERR-02-PREREQ-XCODE-CLI" "$MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID"
        fi
        sleep 10
        XCODE_WAIT=$((XCODE_WAIT + 10))
        # Heartbeat every 30s so the GUI watchdog stays quiet + customer
        # sees progress. Without this, install.sh emits nothing for the
        # entire CLT download and the watchdog fires WARN/ERROR.
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
            # Allocate enough resources for 3 containers
            colima start --cpu 2 --memory 4 --disk 30 2>/dev/null || {
                warn "$MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP"
                if [[ -d "/Applications/Docker.app" ]]; then
                    open -a Docker 2>/dev/null || true
                else
                    fail_with_code "ERR-06-DOCKER-COLIMA-FAIL" "$MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD"
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

if command -v ollama &>/dev/null; then
    ok "$MSG_OK_OLLAMA_INSTALLED"
else
    # CX-14 Section E1 (2026-05-23). Install the FORMULA, not the
    # cask. The cask installs Ollama.app + ships a notarised .app
    # bundle whose first launch triggers a Gatekeeper "downloaded
    # from internet" dialog (xattr com.apple.quarantine), which
    # mid-installs the customer either fights through or ignores
    # (and then later wonders why the Hub cannot reach Ollama).
    #
    # The formula installs `ollama` as a CLI binary into Homebrew's
    # bin (no .app to quarantine, no Gatekeeper dialog). It serves
    # on the SAME port (11434) and uses the SAME on-disk layout for
    # models (~/.ollama/), so every downstream wire path (Hub
    # agents, embedding pipeline, the model-pull retries below) is
    # unchanged. The only difference is start-on-boot: we use
    # `brew services start ollama` to wire a launchd plist for
    # persistence (cask's `open -a Ollama` path is no longer
    # available; brew services is the formula's native equivalent).
    info "$MSG_INFO_INSTALLING_OLLAMA"
    brew install ollama
    # DMG #48 silent-bail hardening: verify ollama binary is on PATH
    # before declaring the formula installed.
    if ! command -v ollama &>/dev/null; then
        fail_with_code "ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW" \
            "$(printf "$MSG_FAIL_OLLAMA_MISSING_AFTER_BREW" "$INSTALL_LOG")"
    fi
    ok "$MSG_OK_OLLAMA_INSTALLED"
fi

if curl -s http://localhost:11434/api/tags &>/dev/null; then
    ok "$MSG_OK_OLLAMA_RUNNING"
else
    info "$MSG_INFO_STARTING_OLLAMA"
    # Formula path: prefer `brew services start ollama` so the
    # launchd plist persists across reboots (cask used to do this
    # via the .app's built-in LaunchAgent; formula needs the
    # explicit brew-services wire). Fall back to a backgrounded
    # `ollama serve` if brew services is unavailable (e.g. a
    # Homebrew install that did not wire services for some reason).
    brew services start ollama 2>/dev/null || ollama serve &>/dev/null &
    # Wait up to 30 seconds for Ollama to be ready
    OLLAMA_WAIT=0
    while ! curl -s http://localhost:11434/api/tags &>/dev/null; do
        if [[ $OLLAMA_WAIT -ge 90 ]]; then
            warn "$MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY"
            echo "  Run 'brew services start ollama' from Terminal to start it manually,"
            echo "  then re-run the installer."
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
        if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
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
    : "${OSTLER_IMESSAGE_BACKFILL_DAYS:=1825}"
    : "${OSTLER_BROWSER_BACKFILL_DAYS:=1825}"
    : "${OSTLER_SAFARI_BACKFILL_DAYS:=1825}"
    : "${OSTLER_WHATSAPP_BACKFILL_DAYS:=1825}"

    set +e
    FDA_OUTPUT=$(OSTLER_FDA_SOURCES="${OSTLER_FDA_SOURCES}" \
                 OSTLER_TAKEOUT_PATH="${OSTLER_TAKEOUT_PATH:-}" \
                 OSTLER_IMESSAGE_BACKFILL_DAYS="${OSTLER_IMESSAGE_BACKFILL_DAYS}" \
                 OSTLER_BROWSER_BACKFILL_DAYS="${OSTLER_BROWSER_BACKFILL_DAYS}" \
                 OSTLER_SAFARI_BACKFILL_DAYS="${OSTLER_SAFARI_BACKFILL_DAYS}" \
                 OSTLER_WHATSAPP_BACKFILL_DAYS="${OSTLER_WHATSAPP_BACKFILL_DAYS}" \
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
    image: ghcr.io/ostler-ai/ostler-wiki-site:0.1
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
        fail_with_code "ERR-13-MODEL-PULL-NOMIC" "$MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT"
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
#   2. ~/.zeroclaw/ical-query.sh -- a shell wrapper that ical-server
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

# 2. ~/.zeroclaw/ical-query.sh -- shell wrapper that ical-server
# invokes for iCloud / CalDAV calendar events. The path is a legacy
# artefact of how the bridge was first wired on Andy's instance;
# rather than patching every call site we materialise the wrapper
# at the path ical-server.py defaults to.
#
# The wrapper hands off to a Python module under the customer's
# Ostler venv. We write a stub that exits non-zero with a clear
# message until the customer has paired their iCloud account via
# the assistant UI (Phase 3.5b already wired the OSTLER_ICLOUD_USER
# / OSTLER_ICLOUD_APP_PASSWORD env vars when present). Once those
# env vars are set, the wrapper shells out to the python-caldav
# library to fetch upcoming events as raw iCal text.
ICAL_WRAPPER_DIR="${HOME}/.zeroclaw"
ICAL_WRAPPER="${ICAL_WRAPPER_DIR}/ical-query.sh"
mkdir -p "$ICAL_WRAPPER_DIR"
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
# Fans one or more export directories to BOTH consumers:
#   - the people graph   (CM041 contact_syncer.import_all)
#   - the preference wiki (CM019 ingest-dir + enrich --all -> `preferences`)
#
# It is the SINGLE ingest path. Three entry points call it:
#   1. install.sh's install-time hydrate (Downloads + the drop-zone),
#   2. the Downloads export watcher (auto-run on detection), and
#   3. a power-user fallback (run it by hand).
#
# Safe to re-run over the same dir: contact_syncer dedupes (identity
# resolver + DedupDetector) and the CM019 preferences upsert is keyed by
# stable id, so a second pass is a no-op rather than a duplicate.
#
# Non-fatal by design: a missing/!ready pipeline is skipped, not a hard
# error, so one consumer being unavailable never blocks the other.
set -uo pipefail
OSTLER_DIR="${HOME}/.ostler"
PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"
CM019_DIR="${OSTLER_DIR}/services/cm019"
CM019_PY="${CM019_DIR}/.venv/bin/python"

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
            echo "Imports GDPR / app exports into both your people graph and your"
            echo "preferences. Ostler runs this for you automatically; you only need"
            echo "it by hand to re-import a folder Ostler did not pick up."
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
if [[ -d "$_PREFS_DROPZONE" ]] \
   && find "$_PREFS_DROPZONE" -type f ! -name '.*' -print -quit 2>/dev/null | grep -q .; then
    _IMPORT_DIRS+=("$_PREFS_DROPZONE")
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
launchctl bootout "gui/$(id -u)/com.ostler.ical-server" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.ical-server.plist" 2>/dev/null || true
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
launchctl bootout "gui/$(id -u)/com.ostler.imessage-bridge" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.ostler.imessage-bridge.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.wiki-recompile" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.whatsapp-keepalive" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-keepalive.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler-remotecapture" 2>/dev/null || \
    launchctl unload "${HOME}/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.doctor.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.ical-server.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.export-scan.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.fda-rerun.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.deferred-register-device.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.colima.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist"
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist"
rm -f "${HOME}/Library/LaunchAgents/com.ostler.imessage-bridge.plist"
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
        <!-- CX-P0A (2026-05-26): forward the 13 iOS /api/v1/* paths to
             the loopback-bound ical-server on 127.0.0.1:8090. Without
             this list Doctor 404s every iOS Companion call beyond
             /api/v1/auth/chat-token + /api/v1/wiki/correct. The two
             path-parameter routes use FastAPI {slug}/{id} syntax so the
             proxy's request.url.path forwarding substitutes them. -->
        <key>DOCTOR_PROXY_PATHS</key>
        <string>/api/safari/ingest,/api/v1/hub/health,/api/v1/timeline,/api/v1/people/search,/api/v1/people/context,/api/v1/people/stale,/api/v1/people/recent,/api/v1/people/birthdays,/api/v1/suggestions,/api/v1/calendar,/api/v1/calendar/today,/api/v1/conversation/process,/api/v1/conversation/status/{id},/api/v1/email/recent,/api/v1/ingest/ios,/api/v1/recording/active,/api/v1/coach/recent,/api/v1/people/{slug}/forget</string>
        <key>DOCTOR_GATEWAY_URL</key>
        <string>http://127.0.0.1:8090</string>
    </dict>
</dict>
</plist>
DOCEOF

    # Use bootstrap on Sequoia+ (load is deprecated), fall back to load
    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "$MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089"
fi

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
    APPLE_MAIL_VERSION_DIR=$(find "${HOME}/Library/Mail" -maxdepth 1 -type d -name 'V[0-9]*' 2>/dev/null | sort -V | tail -1) || _mail_probe_failure_line="find Mail/V* dir"
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
    if [[ "$MAIL_ACCOUNTS_FOUND" -gt 0 ]] \
       && [[ "$MAIL_HAS_FETCHED" != "true" ]] \
       && [[ "${OSTLER_GUI:-0}" == "1" ]]; then
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

progress "Setting up ostler-assistant binary (v${OSTLER_ASSISTANT_VERSION:-0.4.4})" "ostler_assistant"

OSTLER_ASSISTANT_VERSION="${OSTLER_ASSISTANT_VERSION:-0.4.4}"
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

info "$MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN"
set +e  # CX-60: probe is best-effort; never kill the install from here
_imessage_fda_probe_failure_line=""

if [[ "${ASSISTANT_BINARY_INSTALLED:-false}" != "true" ]]; then
    info "$MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON"
else
    _imessage_chat_db_path="${HOME}/Library/Messages/chat.db"
    _imessage_fda_needed="true"  # conservative default

    # Brief grace period: even with the LaunchAgent loaded, the
    # daemon's iMessage channel needs a moment to attempt its first
    # chat.db open. The probe itself is independent (install.sh
    # opens chat.db directly), but waiting briefly avoids a noisy
    # log entry from racing the LaunchAgent.
    sleep 2

    if [[ -f "$_imessage_chat_db_path" ]]; then
        # sqlite3 ships with macOS. URI mode + ro lets us probe
        # without locking the database against Messages.app.
        if sqlite3 -readonly \
                "file:${_imessage_chat_db_path}?mode=ro" \
                "SELECT 1 LIMIT 1;" >/dev/null 2>&1; then
            _imessage_fda_needed="false"
            info "$MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED"
        else
            info "$MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT"
            # ── CX-78c (DMG #45, 2026-05-25): daemon-TCC pre-probe ──
            #
            # The chat.db probe above runs as install.sh, which
            # inherits OstlerInstaller.app's TCC posture — *not*
            # ostler-assistant's. If the customer granted FDA to
            # the daemon on a previous install but never to
            # OstlerInstaller.app, the probe returns a false
            # negative and the assist dialog fires unnecessarily.
            # Query the system TCC.db directly via sudo to read
            # the daemon's actual auth_value. auth_value 2 means
            # allowed. Best-effort: if sudo prompt would be
            # needed (cache expired) we silently fall through to
            # the dialog path; net effect is no worse than the
            # pre-CX-78c behaviour.
            #
            # v0.4.3+ shape: the daemon is launched from inside
            # OstlerAssistant.app/Contents/MacOS/, so macOS TCC
            # keys the client column by the bundle identifier
            # (ai.ostler.assistant) -- the same value the bundle
            # declares in Info.plist CFBundleIdentifier. We
            # check both the bundle-ID form (v0.4.3+) AND the
            # legacy bare-binary path (in case a customer still
            # has an old FDA grant against the bare-binary
            # client). Either form returning 2 means "granted".
            _daemon_fda_auth=""
            if command -v sudo >/dev/null 2>&1; then
                _daemon_fda_auth="$(
                    sudo -n sqlite3 \
                        "/Library/Application Support/com.apple.TCC/TCC.db" \
                        "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client IN ('ai.ostler.assistant', '${ASSISTANT_BINARY_LEGACY}') LIMIT 1;" \
                        2>/dev/null || true
                )"
            fi
            if [[ "$_daemon_fda_auth" == "2" ]]; then
                _imessage_fda_needed="false"
                info "$MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED"
                launchctl kickstart -k "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
                unset _daemon_fda_auth
            else
                unset _daemon_fda_auth
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

                # Open System Settings to the Full Disk Access pane.
                # The URL scheme is stable on macOS 13+; older macOS
                # falls back to Privacy & Security top-level which
                # is acceptable. The 2>/dev/null swallows the rare
                # "scheme not registered" warning on stripped builds.
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

                # Reveal the daemon .app bundle in Finder so the
                # customer can drag it directly into System
                # Settings without navigating to ~/.ostler/
                # themselves. The -R flag selects the bundle in
                # the parent folder; macOS Finder renders the
                # bundle with the Ostler v4 icon (read from
                # OstlerAssistant.app/Contents/Resources/icon.icns)
                # so the customer sees the product mark from the
                # moment Finder opens.
                open -R "$ASSISTANT_APP_BUNDLE" 2>/dev/null || true

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

                # Re-probe chat.db. The TCC cache for the install.sh
                # binary (which inherits OstlerInstaller.app's
                # posture) doesn't reflect grants made to the
                # ostler-assistant binary -- but for the customer's
                # downstream experience, what matters is whether
                # the daemon binary itself can read chat.db on its
                # next LaunchAgent restart. We can't probe that
                # directly from this process. Best signal: if
                # install.sh's own probe of chat.db now succeeds
                # (it inherited OstlerInstaller.app's FDA, which
                # was almost certainly the binary the customer just
                # added in System Settings AS WELL), that's a strong
                # heuristic that the daemon binary also has FDA.
                # Imperfect; the Doctor card's live re-probe
                # (status_collector + check_imessage_fda) gives the
                # ground truth on next refresh.
                sleep 2
                if sqlite3 -readonly \
                        "file:${_imessage_chat_db_path}?mode=ro" \
                        "SELECT 1 LIMIT 1;" >/dev/null 2>&1; then
                    _imessage_fda_needed="false"
                    info "$MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED"
                    # Kick the assistant LaunchAgent to pick up the
                    # new FDA grant. launchctl kickstart -k restarts
                    # the agent without un/re-loading, so the new
                    # TCC posture takes effect immediately.
                    launchctl kickstart -k "gui/$(id -u)/com.creativemachines.ostler.assistant" 2>/dev/null || true
                else
                    info "$MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED"
                fi
                fi  # closes inner `if OSTLER_GUI` (CX-78c nesting)
            fi  # closes outer `if daemon-TCC granted / else` (CX-78c)
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

TAILSCALE_CONFIRM="$(gui_read "$MSG_PROMPT_TAILSCALE_CONFIRM_TITLE" choice "setup" "$MSG_PROMPT_TAILSCALE_CONFIRM_HELP" "setup,skip" "tailscale_confirm")"

if [[ "${TAILSCALE_CONFIRM:-setup}" == "setup" ]]; then
    if ! command -v tailscale &>/dev/null && [[ ! -d "/Applications/Tailscale.app" ]]; then
        info "$MSG_INFO_INSTALLING_TAILSCALE"
        # CX-105 (DMG #48k, 2026-05-29): Tailscale install via
        # `brew install --cask` fails on fresh Macs because the
        # CX-25 manual-tarball Homebrew install path leaves brew
        # as "shallow or no git repository", which breaks cask
        # tap resolution. Tailscale is recoverable: the iOS
        # Companion works on the local LAN without it, and the
        # customer can install Tailscale from tailscale.com any
        # time. Convert the fail-loud to warn-and-continue so the
        # rest of the install can complete; surface a clear next
        # step rather than blocking shipping. Proper fix in v1.0.1
        # (replace tarball brew with git-clone or skip brew for
        # this step entirely).
        if brew install --cask tailscale 2>&1; then
            ok "$MSG_OK_TAILSCALE_INSTALLED"
        else
            warn "$MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL"
        fi
        if [[ ! -d "/Applications/Tailscale.app" ]]; then
            warn "$MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL"
            OSTLER_TAILSCALE_SKIPPED=1
        fi
    else
        ok "$MSG_OK_TAILSCALE_ALREADY_INSTALLED"
    fi

    # Open the Tailscale app -- first launch prompts for sign-in.
    # CX-81 Tailscale step root-cause fix (2026-05-26):
    # was `open -gj -a Tailscale` where `-g` skips foreground and
    # `-j` launches HIDDEN -- the sign-in window never appeared for
    # customers who had never signed into Tailscale on this Mac.
    # `open -a Tailscale` brings the app to the foreground so the
    # sign-in window is actually visible. For already-signed-in
    # customers, this just brings the menu-bar app forward briefly,
    # which is acceptable.
    if [[ -d "/Applications/Tailscale.app" ]]; then
        info "$MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN"
        open -a Tailscale 2>/dev/null || true
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
        # 180s window: a non-technical user reading the prompt, switching
        # to the GUI, completing OAuth (Apple/Google/Microsoft sign-in
        # with possible 2FA), and returning easily eats 2-3 minutes.
        # 60s is too short and was the most-tripped Phase-3 timeout in
        # the install audit (~2026-05-01).
        info "$MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3"
        info "$MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH"
        TS_WAIT=0
        # Periodic progress update threshold: emit at 30s/60s/90s/120s/150s
        # so the customer sees the installer is alive while they finish
        # the OAuth dance in the Tailscale window.
        TS_NEXT_TICK=30
        while [[ -z "$OSTLER_TAILSCALE_IP" && $TS_WAIT -lt 180 ]]; do
            OSTLER_TAILSCALE_IP=$("$TS_CLI" ip --4 2>/dev/null | head -1 || true)
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

# Contact hydration ------------------------------------------------
#
# CX-93 (DMG #48g): re-export from Contacts.app at hydrate time as
# well as at the Phase-2 me-card capture. On a fresh Mac the
# Phase-2 export can run BEFORE iCloud finishes the first contact
# sync (Phase 2 is the very first thing that happens; iCloud sync
# can take 30-90 seconds after sign-in). By the time we get to
# hydrate (post-FDA, post-encrypt, post-Docker bring-up = several
# minutes later), iCloud has typically caught up. Re-exporting here
# means the customer's local AB + freshly-synced iCloud contacts
# BOTH land in the import. If the Phase-2 vcf already has content
# we keep it -- this is purely additive.
if [[ ! -s "$_HYDRATE_VCF" ]]; then
    info "$MSG_HYDRATE_CONTACTS_REEXPORT"
    mkdir -p "$(dirname "$_HYDRATE_VCF")"

    # CX-101 (DMG #48j, 2026-05-29): state-2 wait + non-swallowing
    # stderr capture. The old code piped osascript stderr to
    # /dev/null + appended || true, so a Contacts Automation TCC
    # denial AND a "Contacts hasn't synced yet" empty-store result
    # were both indistinguishable from genuine "no contacts".
    # Three improvements:
    #   1. Pre-prompt offer to open Contacts.app if accounts are
    #      configured but the local AB is empty (state 2).
    #   2. Capture osascript stderr into /tmp log file so the install
    #      log records the actual error.
    #   3. After the osascript fails, classify the error: TCC denial
    #      (-1743 / errAEEventNotPermitted) -> state-denied copy;
    #      empty store -> state-pending copy.
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

    _CONTACTS_STDERR="/tmp/ostler-hydrate-contacts-osascript.stderr"
    : > "$_CONTACTS_STDERR"
    osascript -e "
tell application \"Contacts\"
    set vcfData to vcard of every person
    set fp to POSIX file \"${_HYDRATE_VCF}\"
    set fRef to open for access fp with write permission
    write vcfData to fRef
    close access fRef
end tell" 2>"$_CONTACTS_STDERR" || true

    # If osascript wrote a known TCC-denial marker into stderr, set a
    # flag so the downstream hydrate result picks the right copy.
    # macOS denial codes: -1743 (Not authorised), errAEEventNotPermitted.
    _CONTACTS_TCC_DENIED=false
    if grep -qE 'Not authori[sz]ed|-1743|errAEEventNotPermitted' \
        "$_CONTACTS_STDERR" 2>/dev/null; then
        _CONTACTS_TCC_DENIED=true
    fi
fi

if [[ -s "$_HYDRATE_VCF" ]] && [[ -x "$_HYDRATE_PIPELINE_PY" ]]; then
    info "$MSG_HYDRATE_CONTACTS_STARTED"
    # contact_syncer.syncer --vcf emits a single-line JSON status on
    # stdout when it finishes. Progress lines go to stderr so the
    # final stdout line is parseable.
    _HYDRATE_CONTACTS_JSON="$(
        cd "$PIPELINE_DIR" && \
        "$_HYDRATE_PIPELINE_PY" -m contact_syncer.syncer \
            --vcf "$_HYDRATE_VCF" \
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
    if [[ "$_HYDRATE_CONTACTS_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CONTACTS_DONE" "$_HYDRATE_CONTACTS_COUNT")"
    elif [[ "${_CONTACTS_TCC_DENIED:-false}" == "true" ]]; then
        # Contacts Automation TCC denied -- the customer either
        # declined the Automation prompt or the prompt has not
        # appeared yet. Tell them how to grant it.
        warn "$MSG_HYDRATE_CONTACTS_DENIED"
    elif [[ "$(_accountsdb_count_contacts)" -gt 0 ]]; then
        # State 2 -- accounts configured but local AB empty.
        warn "$MSG_HYDRATE_CONTACTS_PENDING"
    else
        # State 1 -- no contacts source configured at all.
        warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
    fi
else
    # No vcf written OR pipeline venv missing. Classify between
    # TCC denial and genuinely empty using the same probe shape.
    if [[ "${_CONTACTS_TCC_DENIED:-false}" == "true" ]]; then
        warn "$MSG_HYDRATE_CONTACTS_DENIED"
    elif [[ "$(_accountsdb_count_contacts)" -gt 0 ]]; then
        warn "$MSG_HYDRATE_CONTACTS_PENDING"
    else
        warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
    fi
fi
unset _CONTACTS_STDERR _CONTACTS_TCC_DENIED _hydrate_contacts_accounts

# Calendar hydration -----------------------------------------------
#
# CX-101 (DMG #48j, 2026-05-29): SWITCHED FROM meeting_syncer ->
# CalDAV path TO FDA path (ostler_fda.calendar + pwg_ingest.
# ingest_calendar). The old meeting_syncer path went via the
# localhost ical-server which invoked ~/.zeroclaw/ical-query.sh
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
if [[ -x "$_HYDRATE_PIPELINE_PY" ]]; then
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
    OSTLER_FDA_OUTPUT_DIR="${OSTLER_DIR}/imports/fda" \
    "$_HYDRATE_PIPELINE_PY" - <<EOF 2>>/tmp/ostler-hydrate-calendar.log || true
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

    # Ingest the JSON into Oxigraph via the existing pwg_ingest path.
    # ingest_calendar reads calendar_events.json and emits triples
    # per attendee. The return dict has {events_processed,
    # unique_attendees} which we surface as "Imported %s events".
    _HYDRATE_CALENDAR_JSON="$(
        "$_HYDRATE_PIPELINE_PY" - <<EOF 2>>/tmp/ostler-hydrate-calendar.log
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
    if [[ "$_HYDRATE_CALENDAR_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CALENDAR_DONE" "$_HYDRATE_CALENDAR_COUNT")"
    elif [[ "$_hydrate_cal_accounts" -gt 0 ]]; then
        # State 2 -- accounts configured but cache empty (wait-for-
        # populate either declined or timed out).
        info "$MSG_HYDRATE_CALENDAR_PENDING"
    else
        # State 1 -- no calendar accounts configured at all.
        info "$MSG_HYDRATE_SKIPPED_NO_EVENTS"
    fi
    unset _hydrate_cal_accounts
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
    if OSTLER_HOME="$HOME" $_HYDRATE_EMAIL_TIMEOUT_WRAP \
       "$_HYDRATE_EMAIL_PY" -m ostler_fda.apple_mail_mbox \
           --emit-mbox "$_HYDRATE_EMAIL_MBOX" \
           --backfill-days "$OSTLER_HYDRATE_EMAIL_DAYS" \
           --backfill-chunk-days 30 \
           >>"$_HYDRATE_EMAIL_LOG" 2>&1; then
        :
    else
        rc=$?
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
# Same 90s wall-clock cap as hydrate_email (Q6 forward-look). On
# timeout we emit MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES and let
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

unset _HYDRATE_VCF _HYDRATE_API _HYDRATE_OXIGRAPH _HYDRATE_PIPELINE_PY
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
# Same 90s wall-clock cap as hydrate_email + hydrate_whatsapp. On
# timeout we emit MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES and
# let the agent finish.
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
    _HYDRATE_BROWSING_JSON="$(
        $_HYDRATE_BROWSING_TIMEOUT_WRAP \
        "$_HYDRATE_BROWSING_PY" -c "
import json
from pathlib import Path
from ostler_fda.pwg_ingest import ingest_browser_history
result = ingest_browser_history(Path('${_HYDRATE_BROWSING_FDA_DIR}'))
print(json.dumps(result))
" 2>>"$_HYDRATE_BROWSING_LOG" | tail -n 1
    )"
    rc=$?
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

# iMessage hydration (CX-84) ---------------------------------------
#
# Reads imessage_conversations.json (written by the Phase 3 FDA
# extract_all step when "imessage" is in OSTLER_FDA_SOURCES) and
# emits Person + lastContactIMessage triples into Oxigraph. Only
# the people-count is surfaced to the customer -- no handles, phone
# numbers, or message text leaves the local process.
#
# Same 90s wall-clock cap as the other hydrate_* blocks. On timeout
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
    _HYDRATE_IMESSAGE_JSON_OUT="$(
        $_HYDRATE_IMESSAGE_TIMEOUT_WRAP \
        "$_HYDRATE_IMESSAGE_PY" -c "
import json
from pathlib import Path
from ostler_fda.pwg_ingest import ingest_imessage
result = ingest_imessage(Path('${_HYDRATE_IMESSAGE_FDA_DIR}'))
print(json.dumps(result))
" 2>>"$_HYDRATE_IMESSAGE_LOG" | tail -n 1
    )"
    rc=$?
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

unset _INITIAL_HYDRATE_QDRANT _INITIAL_HYDRATE_FDA_DIR
unset _INITIAL_HYDRATE_VENV _INITIAL_HYDRATE_PY _INITIAL_HYDRATE_LOG
unset _INITIAL_HYDRATE_COLLECTIONS_BEFORE _INITIAL_HYDRATE_COLLECTIONS_AFTER

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
    if [[ "${OSTLER_GUI:-0}" == "1" ]]; then
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
