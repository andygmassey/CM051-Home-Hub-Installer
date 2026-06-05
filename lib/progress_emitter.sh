#!/usr/bin/env bash
# lib/progress_emitter.sh
#
# Sourced helper file for emitting machine-readable progress markers
# from install.sh, consumed by the Mac Hub installer GUI
# (gui/OstlerInstaller). Gated by the OSTLER_GUI=1 env var so the
# curl|bash TTY path stays 100% byte-for-byte identical when the GUI
# is not in play.
#
# Marker format (tab-separated, one per line, anchored at start of
# line on a fresh line):
#
#   #OSTLER<TAB>EVENT<TAB>k=v<TAB>k=v...
#
# Events:
#   STEP_BEGIN  id=<stable-id>  title=<human>  phase=<n>  idx=<n>  total=<n>
#   PCT         step=<id>       pct=<0..100>
#   LOG         level=info|warn|error  msg=<line>
#   WARN        step=<id>       msg=<line>
#   PROMPT      id=<id>  kind=text|secret|yesno|choice  title=<...>
#               default=<...>  choices=<comma-separated>  help=<...>
#   STEP_END    id=<id>  status=ok|warn|fail  elapsed_s=<n>
#   PHASE       id=<n>   title=<...>
#   NEEDS_FDA   probe=<path>  reason=<...>
#   NEEDS_SUDO  reason=<...>
#   MAIL_ACCOUNTS_FOUND  count=<n>  has_fetched=true|false
#               Install-time Apple Mail probe result (#259). Lets the
#               installer GUI surface an optional empty-mailbox sheet
#               on the success screen. Doctor reads the same data
#               from ~/.ostler/state/pipeline_signals.json directly,
#               so this marker is informational only; installs
#               without GUI handling silently ignore it.
#   DONE        status=ok|fail
#
# Usage in install.sh:
#
#   source "${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/lib && pwd)}/progress_emitter.sh"
#   gui_emit STEP_BEGIN "id=docker_install" "title=Installing Docker" "idx=2" "total=11"
#   gui_emit PCT "step=docker_install" "pct=42"
#   answer="$(gui_read "Choose a passphrase" secret "" "Used to encrypt your databases")"
#
# All emitter calls return successfully when OSTLER_GUI is unset, so
# you can sprinkle them inline without conditional guards.

# ── Marker emission ────────────────────────────────────────────────

# gui_emit <EVENT> [k=v ...]
#
# Emit a single marker line. Tab-separated. Values containing tabs or
# newlines are stripped (CI lints step IDs / titles for these too).
# When OSTLER_GUI is not "1", silently no-ops.
gui_emit() {
    [[ "${OSTLER_GUI:-0}" != "1" ]] && return 0
    local event="$1"; shift

    # ── Why stderr and not stdout ──
    #
    # Marker lines MUST go to stderr because gui_read (and any other
    # helper that emits markers) is routinely wrapped in command
    # substitution:
    #
    #     answer="$(gui_read 'Your name' text)"
    #
    # `$()` captures stdout. If gui_emit writes the PROMPT marker to
    # stdout it gets swallowed into the bash variable and never
    # reaches the Mac Hub installer GUI -- the GUI never knows to
    # render a sheet, so the user is never asked, and gui_read blocks
    # forever on `read -u "${OSTLER_GUI_FD}"`. That's the launch
    # blocker Andy hit on Mac Studio 2026-05-13 PM (brief
    # HR015/launch/TNM_BRIEF_INSTALLER_PROMPT_RENDERING_BUG_2026-05-13.md).
    #
    # Stderr is NOT captured by `$()`, so the marker always reaches
    # the GUI. The Swift side parses both stdout and stderr through
    # the same ProgressDecoder (InstallerCoordinator captures both
    # pipes), so the routing is transparent. The same logic is why
    # the TTY echo at line 167 below uses `>&2`.
    #
    # Print on a fresh line so the GUI can anchor on \n#OSTLER\t.
    # Some upstream commands don't end with newline, so be defensive.
    {
        printf '\n#OSTLER\t%s' "$event"
        local kv
        for kv in "$@"; do
            # Strip tabs and CR/LF from values, replace with single space.
            # The GUI parser will reject malformed lines, so be tolerant.
            kv="${kv//$'\t'/ }"
            kv="${kv//$'\n'/ }"
            kv="${kv//$'\r'/ }"
            printf '\t%s' "$kv"
        done
        printf '\n'
    } >&2
}

# ── Step bookkeeping (optional convenience) ───────────────────────

# Track elapsed time for STEP_END. Pure shell, no associative arrays
# (works on bash 3.x that ships with macOS).
__OSTLER_STEP_ID=""
__OSTLER_STEP_START=0

gui_step_begin() {
    # gui_step_begin <id> <title> [phase] [idx] [total]
    local id="$1" title="$2" phase="${3:-}" idx="${4:-}" total="${5:-}"
    __OSTLER_STEP_ID="$id"
    __OSTLER_STEP_START=$(date +%s)
    local args=("id=$id" "title=$title")
    [[ -n "$phase" ]] && args+=("phase=$phase")
    [[ -n "$idx" ]]   && args+=("idx=$idx")
    [[ -n "$total" ]] && args+=("total=$total")
    gui_emit STEP_BEGIN "${args[@]}"
}

gui_step_end() {
    # gui_step_end [status]   defaults to ok
    local status="${1:-ok}"
    local id="${__OSTLER_STEP_ID:-unknown}"
    local elapsed=0
    if [[ "$__OSTLER_STEP_START" -gt 0 ]]; then
        elapsed=$(( $(date +%s) - __OSTLER_STEP_START ))
    fi
    gui_emit STEP_END "id=$id" "status=$status" "elapsed_s=$elapsed"
    __OSTLER_STEP_ID=""
    __OSTLER_STEP_START=0
}

# ── Interactive prompt redirection ────────────────────────────────
#
# When OSTLER_GUI=1, the GUI side opens a pipe and exposes its read
# end via OSTLER_GUI_FD (a file-descriptor number, usually 3 or 4).
# gui_read emits a PROMPT marker, then reads the answer from that fd.
#
# When OSTLER_GUI is unset, gui_read falls back to plain `read` from
# stdin, identical to the existing TTY behaviour.
#
# Args:
#   $1  prompt_text       (visible label / question)
#   $2  kind              text|secret|yesno|choice  (default text)
#   $3  default_value     (optional)
#   $4  help_text         (optional, hint copy)
#   $5  choices_csv       (optional, for kind=choice)
#   $6  prompt_id         (optional, stable id; defaults to slugified title)
#   $7  error_text        (optional, surfaced as a banner above the
#                          input on the GUI side; used by validation
#                          retry loops -- see CX-97 below)
#
# The answer is echoed on stdout, so callers can do:
#
#   answer="$(gui_read 'What is your name?' text 'Alex')"
#
# stderr is used for any TTY echo so command substitution doesn't
# swallow the user-visible prompt.
#
# CX-97 (DMG #48g+1, 2026-05-29): the optional $7 error_text arg lets
# a validation-retry loop (e.g. recovery_passphrase mismatch, email
# password mismatch) surface a clear oxblood banner above the prompt
# input ON THE SAME RE-EMITTED PROMPT ID. The GUI's seenPromptIds
# de-dupe already prevents the X counter from advancing on a re-emit,
# AND the coordinator restores X to the prompt's original index, so
# the customer sees: SAME question number, SAME prompt, with a clear
# "didn't match" banner instead of an apparently-new question that
# fell out of the sky.

gui_read() {
    local title="$1"
    local kind="${2:-text}"
    local default_value="${3:-}"
    local help_text="${4:-}"
    local choices_csv="${5:-}"
    local id="${6:-}"
    local error_text="${7:-}"

    # Slugify a default id from the title if none provided.
    if [[ -z "$id" ]]; then
        id="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"
        [[ -z "$id" ]] && id="prompt"
    fi

    if [[ "${OSTLER_GUI:-0}" == "1" && -n "${OSTLER_GUI_FD:-}" ]]; then
        local args=("id=$id" "kind=$kind" "title=$title")
        [[ -n "$default_value" ]] && args+=("default=$default_value")
        [[ -n "$help_text" ]]     && args+=("help=$help_text")
        [[ -n "$choices_csv" ]]   && args+=("choices=$choices_csv")
        [[ -n "$error_text" ]]    && args+=("error=$error_text")
        gui_emit PROMPT "${args[@]}"

        # Read one line from the GUI fd. `read -u` accepts a numeric
        # variable for the fd. Falls back to default_value if the GUI
        # closed the pipe (read returns non-zero on EOF).
        local answer=""
        if ! IFS= read -r -u "${OSTLER_GUI_FD}" answer; then
            answer="$default_value"
        fi
        printf '%s' "$answer"
        return 0
    fi

    # ── TTY fallback ────────────────────────────────────────────────
    # Match the historical behaviour of `read -p` exactly. For
    # secrets, use `read -s` (no echo). Display the prompt on stderr
    # so command substitution doesn't eat it.
    #
    # 2026-05-20: two new kinds carry GUI-specific controls and
    # degrade in the TTY fallback to plain prompts:
    #   - acknowledge: a button-only confirmation in the GUI; in
    #     TTY we echo the prompt + return the default. Caller code
    #     ignores the returned value (it's just an "I have read this"
    #     primitive) OR uses it as a yes/no equivalent (consent_install).
    #   - folder:      a folder picker in the GUI; in TTY we read a
    #     path string with the default value pre-filled, identical
    #     to a `text` prompt with a default.
    local user_prompt="  ${title}"
    [[ -n "$default_value" ]] && user_prompt="${user_prompt} [${default_value}]"
    user_prompt="${user_prompt}: "

    local answer=""
    if [[ "$kind" == "secret" ]]; then
        # `read -s -p` puts prompt on stderr automatically when given
        # a tty. Echo a trailing newline since -s suppresses the one
        # the user types.
        read -r -s -p "$user_prompt" answer || true
        printf '\n' >&2
    elif [[ "$kind" == "acknowledge" ]]; then
        # Button-only in the GUI; in TTY we just echo the title +
        # wait for Enter. Default value is returned as the answer
        # (typically "INSTALL" for consent_install, empty for
        # informational acknowledgements).
        printf '  %s [Enter to continue]: ' "$title" >&2
        read -r answer || true
        if [[ -z "$answer" && -n "$default_value" ]]; then
            answer="$default_value"
        fi
    else
        read -r -p "$user_prompt" answer || true
    fi

    if [[ -z "$answer" && -n "$default_value" ]]; then
        answer="$default_value"
    fi
    printf '%s' "$answer"
}

# ── Convenience predicates ────────────────────────────────────────

# Returns 0 if the GUI is driving the install, 1 otherwise. Lets call
# sites suppress redundant TTY-only output when the GUI will render
# its own version.
gui_active() {
    [[ "${OSTLER_GUI:-0}" == "1" ]]
}

# Forward an arbitrary log line as #OSTLER LOG. Multiple lines are
# split. Use this for streamed subprocess output (ollama pull, docker
# pull, mkdocs build).
gui_log() {
    [[ "${OSTLER_GUI:-0}" != "1" ]] && return 0
    local level="${1:-info}"; shift
    local msg="$*"
    gui_emit LOG "level=$level" "msg=$msg"
}

gui_warn() {
    [[ "${OSTLER_GUI:-0}" != "1" ]] && return 0
    local msg="$*"
    local id="${__OSTLER_STEP_ID:-unknown}"
    gui_emit WARN "step=$id" "msg=$msg"
}

# Phase + final-state helpers
gui_phase() {
    # gui_phase <id> <title>
    gui_emit PHASE "id=$1" "title=$2"
}

gui_done() {
    # gui_done [status]
    #
    # CX-17 (2026-05-23): when the script-side OSTLER_LAST_ERROR_CODE
    # is set (via `fail_with_code "ERR-NN-..." "..."`), pass it
    # through to the GUI on the DONE marker so the Swift side can
    # surface it on the failure banner + the auto-copied log header.
    # Empty code (legacy bare `fail "..."`) emits no code= keyword
    # which the parser tolerates -- matches the pre-CX-17 wire shape.
    local status="${1:-ok}"
    # CX-454: record that a terminal DONE marker has gone out, so the
    # install.sh ERR trap + EXIT backstop never double-report or
    # overwrite this with a synthetic mid-script-death failure.
    OSTLER_DONE_EMITTED=1
    if [[ -n "${OSTLER_LAST_ERROR_CODE:-}" ]]; then
        gui_emit DONE "status=$status" "code=${OSTLER_LAST_ERROR_CODE}"
    else
        gui_emit DONE "status=$status"
    fi
}

gui_cancelled() {
    # CX-126: emit a DONE marker with status=cancelled on the deliberate
    # user-cancel / consent-decline exit paths. The GUI routes this to a
    # calm neutral "Installation cancelled" terminal -- NOT the red
    # failure banner (which is what the no-DONE crash fallback now
    # renders). Without this, those clean `exit 0` paths reach the GUI
    # with no DONE marker and get mislabelled as a crash.
    # CX-454: a cancel is a terminal marker too -- record it so the EXIT
    # backstop does not relabel a deliberate cancel as a failure.
    OSTLER_DONE_EMITTED=1
    gui_emit DONE "status=cancelled"
}

# Surface a sudo-required pause to the GUI. install.sh's existing
# keepalive loop (line 1553) handles refreshing the timestamp once the
# initial grant has happened.
gui_needs_sudo() {
    gui_emit NEEDS_SUDO "reason=${1:-Privileged action required}"
}

# Surface an FDA-required pause. Consumed by the GUI to render a
# native sheet with deep-link to System Settings.
gui_needs_fda() {
    # gui_needs_fda <probe-path> [reason]
    local probe="$1"
    local reason="${2:-Full Disk Access required}"
    gui_emit NEEDS_FDA "probe=$probe" "reason=$reason"
}
