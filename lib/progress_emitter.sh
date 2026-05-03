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

    # Print on a fresh line so the GUI can anchor on \n#OSTLER\t.
    # Some upstream commands don't end with newline, so be defensive.
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
#
# The answer is echoed on stdout, so callers can do:
#
#   answer="$(gui_read 'What is your name?' text 'Alex')"
#
# stderr is used for any TTY echo so command substitution doesn't
# swallow the user-visible prompt.

gui_read() {
    local title="$1"
    local kind="${2:-text}"
    local default_value="${3:-}"
    local help_text="${4:-}"
    local choices_csv="${5:-}"
    local id="${6:-}"

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
    gui_emit DONE "status=${1:-ok}"
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
