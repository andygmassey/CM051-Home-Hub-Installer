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
#   STEP_END    id=<id>  status=ok|warn|timeout|error|fail  elapsed_s=<n>
#               [rc=<n>]
#               `rc=` is present whenever status is not ok, and carries
#               the exit code of the child that produced the status.
#               See "Step status accounting" below for why the status
#               is accumulated rather than passed by the call site.
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
#   DONE        status=ok|fail  failed_steps=<n>
#               `failed_steps` is ALWAYS present and counts the steps
#               that ended with a status other than ok. It is printed
#               even when it is zero, so a reader can tell "no step
#               failed" apart from "this build does not report it".
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
            # ── Value encoding (BW2-2, 2026-07-25) ──
            # The marker line is tab-separated and newline-anchored, so a
            # value MUST NOT contain a literal TAB, CR or LF -- those are
            # structural delimiters. Historically we stripped newlines to a
            # single space, which flattened every multi-paragraph question
            # body (help=) into one dense wall of text on the GUI: the
            # strings already carry "\n\n" paragraph breaks and "•" bullets,
            # but they never survived the wire.
            #
            # Fix: percent-encode newlines instead of destroying them, so
            # the GUI can restore paragraph/bullet structure. Encode "%"
            # first (so the scheme is reversible), then "\n" -> "%0A". TAB
            # and CR stay stripped -- they are never meaningful in copy and
            # TAB is the field delimiter. ProgressDecoder decodes the
            # reverse (%0A -> newline, %25 -> %) at the single parse site.
            kv="${kv//'%'/%25}"
            kv="${kv//$'\t'/ }"
            kv="${kv//$'\r'/ }"
            kv="${kv//$'\n'/%0A}"
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

# ── Step status accounting (#839, 2026-08-18) ──────────────────────
#
# THE DEFECT THIS REPLACES
#
# gui_step_end used to take the status as an argument and default it to
# "ok". Every call site in install.sh passed the literal `ok`:
#
#     progress()          install.sh:7811   gui_step_end ok
#     health_check        install.sh:20732  gui_step_end ok
#     completion markers  install.sh:21988  gui_step_end ok
#
# The status field was therefore a constant, not a measurement. No child
# exit code could reach it by any route, because no route existed. The
# install.sh comment at line ~20607 states the consequence outright:
# "install.sh has no path that ends a step in failure (every
# gui_step_end call site passes `ok`)".
#
# Measured on a v1.0.36 install, 2026-08-18: 40 STEP_END lines, 40 of
# them status=ok, while two of those same steps were killed by their
# 90 s timeout cap and moved no data. Their own completion markers under
# ~/.ostler/state/hydrate/ recorded status=error rc=124 payload=sent=0.
# The marker files were right; the log line was a constant. A reviewer
# grepping the log for ERR- codes found none, because a timeout emits
# none, and reported the install clean.
#
# THE SHAPE OF THE FIX
#
# The status is now ACCUMULATED for the open step and read at close
# time, so it comes from the same rc the marker files already write.
# gui_step_record_rc is the single entry point, and
# _hydrate_sentinel_record_error calls it, so the log line and the
# marker file are produced from one value on one surface. They can no
# longer disagree.
#
# THREE STATES, NEVER TWO
#
#   ok       the step's children all exited 0
#   timeout  a child was killed by its cap (rc 124 SIGTERM / 137 SIGKILL).
#            "We gave up waiting", NOT "it failed". Best-effort hydrate
#            steps legitimately end this way and the customer-facing copy
#            ("Still indexing your people in the background") stays
#            exactly as it is. Only the machine-readable record changes.
#   error    a child exited non-zero for any other reason.
#
# error outranks timeout outranks ok, so a step that both timed out and
# errored reports the error.
__OSTLER_STEP_STATUS="ok"
__OSTLER_STEP_RC=0

# Count of steps closed with a status other than ok. Read by gui_done so
# the single terminal line carries the truth about the whole run.
__OSTLER_FAILED_STEPS=0

# gui_step_record_rc <rc>
#
# Fold a child's exit code into the open step's status. rc 0 is a no-op,
# so this is safe to call unconditionally after any child.
#
# NOTE ON PIPELINES: a pipeline's exit code belongs to its LAST command,
# so `foo | tail -n 1` yields tail's rc, not foo's. Callers must capture
# the rc they mean (`rc=$?` straight after the command substitution, or
# ${PIPESTATUS[0]}) and pass THAT here. Passing a pipeline's own rc
# records a success that was never measured.
gui_step_record_rc() {
    local rc="${1:-0}"
    # Non-numeric rc is a caller bug; treat it as an error rather than
    # silently discarding it, which is the failure mode being fixed.
    if ! [[ "$rc" =~ ^[0-9]+$ ]]; then
        __OSTLER_STEP_STATUS="error"
        __OSTLER_STEP_RC=1
        return 0
    fi
    [[ "$rc" -eq 0 ]] && return 0

    if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
        # timeout must not overwrite an already-recorded error.
        if [[ "$__OSTLER_STEP_STATUS" == "ok" ]]; then
            __OSTLER_STEP_STATUS="timeout"
            __OSTLER_STEP_RC="$rc"
        fi
    else
        __OSTLER_STEP_STATUS="error"
        __OSTLER_STEP_RC="$rc"
    fi
    return 0
}

# gui_step_status
#
# Print the status the open step would close with right now. Lets
# install.sh branch on the accumulated state without reaching into the
# private variables.
gui_step_status() {
    printf '%s' "${__OSTLER_STEP_STATUS:-ok}"
}

gui_step_begin() {
    # gui_step_begin <id> <title> [phase] [idx] [total]
    local id="$1" title="$2" phase="${3:-}" idx="${4:-}" total="${5:-}"
    __OSTLER_STEP_ID="$id"
    __OSTLER_STEP_START=$(date +%s)
    # A new step starts clean. Without this reset one failed step would
    # stain every step after it, which is the mirror image of the defect.
    __OSTLER_STEP_STATUS="ok"
    __OSTLER_STEP_RC=0
    local args=("id=$id" "title=$title")
    [[ -n "$phase" ]] && args+=("phase=$phase")
    [[ -n "$idx" ]]   && args+=("idx=$idx")
    [[ -n "$total" ]] && args+=("total=$total")
    gui_emit STEP_BEGIN "${args[@]}"
}

gui_step_end() {
    # gui_step_end [status]
    #
    # With no argument the accumulated status is used. An argument can
    # only ESCALATE: a caller may force a warn/fail, but a literal `ok`
    # can never overwrite a recorded timeout or error. That asymmetry is
    # deliberate. The whole defect was a call site asserting `ok` over a
    # measurement, and a fix that a future call site can undo by passing
    # `ok` again is not a fix.
    local requested="${1:-}"
    local status="${__OSTLER_STEP_STATUS:-ok}"
    if [[ -n "$requested" && "$requested" != "ok" ]]; then
        status="$requested"
    fi

    local id="${__OSTLER_STEP_ID:-unknown}"
    local elapsed=0
    if [[ "$__OSTLER_STEP_START" -gt 0 ]]; then
        elapsed=$(( $(date +%s) - __OSTLER_STEP_START ))
    fi

    if [[ "$status" == "ok" ]]; then
        gui_emit STEP_END "id=$id" "status=$status" "elapsed_s=$elapsed"
    else
        # Count it even when OSTLER_GUI is unset: the counter is
        # bookkeeping, gui_emit is the wire, and only the wire is gated.
        __OSTLER_FAILED_STEPS=$(( __OSTLER_FAILED_STEPS + 1 ))
        gui_emit STEP_END "id=$id" "status=$status" "elapsed_s=$elapsed" \
                          "rc=${__OSTLER_STEP_RC:-1}"
    fi

    __OSTLER_STEP_ID=""
    __OSTLER_STEP_START=0
    __OSTLER_STEP_STATUS="ok"
    __OSTLER_STEP_RC=0
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
    #
    # #839 (2026-08-18): the DONE line now also carries failed_steps.
    # A reviewer greps ONE line and learns whether any step ended other
    # than ok. Before this, `#OSTLER DONE status=ok` was emitted over an
    # install in which two steps were killed by their timeout cap and
    # ingested nothing, and there was no line anywhere in the log that
    # said so.
    #
    # status and failed_steps answer DIFFERENT questions and both are
    # needed. status=ok means the install reached the end. failed_steps
    # counts the steps inside it that did not do their job. A best-effort
    # hydrate step that times out is exactly the case where those two
    # answers differ, and collapsing them is what hid this for 36 cuts.
    #
    # ALWAYS emitted, including the zero. An absent field cannot be told
    # apart from a build too old to report one, so the clean install
    # prints failed_steps=0 and thereby proves the counter ran.
    local status="${1:-ok}"
    # CX-454: record that a terminal DONE marker has gone out, so the
    # install.sh ERR trap + EXIT backstop never double-report or
    # overwrite this with a synthetic mid-script-death failure.
    OSTLER_DONE_EMITTED=1
    if [[ -n "${OSTLER_LAST_ERROR_CODE:-}" ]]; then
        gui_emit DONE "status=$status" "code=${OSTLER_LAST_ERROR_CODE}" \
                      "failed_steps=${__OSTLER_FAILED_STEPS:-0}"
    else
        gui_emit DONE "status=$status" \
                      "failed_steps=${__OSTLER_FAILED_STEPS:-0}"
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
