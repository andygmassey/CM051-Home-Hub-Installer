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
#               `errors` is ALWAYS present too and counts [ERROR] lines
#               raised anywhere in the run. It answers a DIFFERENT
#               question from failed_steps: a run can close every step
#               cleanly and still have raised errors. Printed even when
#               zero, for the same reason.
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

# ── WHERE A MARKER GOES, AND WHY IT IS NOT STDERR ANY MORE ─────────
#
# THE DEFECT THIS REPLACES
#
# gui_emit used to write every marker to stderr. install.sh then does,
# at the top of the run:
#
#     exec > >(${_OSTLER_TEE_CMD} -a "${INSTALL_LOG}") 2>&1
#
# `2>&1` folds stderr into the tee, so EVERY marker field was appended
# verbatim to ~/.ostler/logs/install.log and kept for the life of the
# machine. That includes the fields that exist only because the GUI
# needs them: prompt titles, help copy, pre-filled defaults, and the
# recovery key on the RECOVERY_KEY marker.
#
# Measured on main, 2026-08-19: 6 of 103 emitter call sites in
# install.sh carry customer-identifying values into a marker payload
# -- the Contacts me-card full name (install.sh:3846), the derived
# first name (3888), the me-card phone (4392), the me-card phone +
# email (4453), the customer name in a warn() (13681), and the
# plaintext recovery key (21368). All six are first-party on main.
# CM051 #399 then added a `calendar_owner` help string carrying up to
# three verbatim calendar event titles from shared and family
# calendars, plus an `identity_namesake` title carrying a third
# party's real display name. That is the shape this routing exists to
# make impossible, rather than asking each future author to remember.
#
# THE SHAPE OF THE FIX
#
# install.sh dups the pre-tee stderr onto fd 9 BEFORE installing the
# tee, and exports OSTLER_MARKER_FD=9. Markers are written there. The
# tee never sees them, so they cannot reach the durable log by any
# route, including routes nobody has written yet.
#
# The Swift coordinator attaches a pipe to BOTH stdout and stderr
# (InstallerCoordinator.launchInstaller: proc.standardOutput /
# proc.standardError) and feeds both to the same ProgressDecoder, so
# fd 9 lands on the stderr pipe and the GUI is unaffected. The two
# original reasons for stderr both still hold: `$()` does not capture
# it, and the decoder reads it.
#
# The durable log keeps a REDACTED trace instead -- field names and
# value lengths, never values -- written straight to ${INSTALL_LOG}.
# Straight to the file rather than to stderr for two reasons: stderr
# is the tee, which is what we are getting off; and a line on stderr
# would also reach the GUI Log drawer and duplicate every info() line
# there, which is the `[INFO ] [info]` noise Andy reported on
# 2026-05-19.
#
# THE REDACTION IS DEFAULT-DENY
#
# _ostler_marker_field_is_public lists the field names that may appear
# verbatim. Everything else is redacted. A field invented next year is
# redacted without its author knowing this function exists, which is
# the whole point: the guarantee is a property of the emitter, not a
# rule each caller has to remember.
#
# WHAT IS DELIBERATELY NOT REDACTED, AND WHY
#
# `msg` on LOG / WARN is the operator narrative. On the TTY path
# install.sh echoes exactly that text and the tee writes it to the log
# anyway; under OSTLER_GUI=1 the echo is suppressed (see info() /
# warn() in install.sh) and the marker is the only copy. Redacting it
# would empty the support log for every GUI install, which is the one
# thing install.sh:1897 exists to prevent. The boundary this fix draws
# is: redact what the GUI marker path UNIQUELY persists, keep what the
# log would have contained regardless.

# _ostler_marker_field_is_public <field-name>
#
# 0 (true) when the field's value may be written to the durable log
# verbatim. Default-deny: anything not named here is redacted.
_ostler_marker_field_is_public() {
    case "$1" in
        # Stable ids and enumerations. Authored in install.sh, never
        # derived from customer data -- gui_read's one derivation path
        # (a slug of the title when no id is passed) is handled by
        # __OSTLER_PROMPT_ID_DERIVED below rather than trusted here.
        id|step|name|kind|level|status|has_fetched|code|remediation)
            [[ "$1" == "id" && "${__OSTLER_PROMPT_ID_DERIVED:-0}" == "1" ]] && return 1
            return 0
            ;;
        # Machine numerics.
        pct|idx|total|phase|elapsed_s|rc|count|failed_steps|errors|total_permissions)
            return 0
            ;;
        # Operator narrative -- see "WHAT IS DELIBERATELY NOT REDACTED".
        msg)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Set to 1 by gui_read for the single gui_emit call that follows, when
# the prompt id was derived from the prompt TITLE rather than passed by
# the caller. A title is the field most likely to carry a person's name
# (CM051 #399 `identity_namesake`), so a title-derived id must not ride
# the `id` allowlist into the log.
__OSTLER_PROMPT_ID_DERIVED=0

# One-shot latch so a broken marker fd is reported once, not per marker.
__OSTLER_MARKER_FD_WARNED=0

# gui_emit <EVENT> [k=v ...]
#
# Emit a single marker line. Tab-separated. Values containing tabs or
# newlines are stripped (CI lints step IDs / titles for these too).
# When OSTLER_GUI is not "1", silently no-ops.
gui_emit() {
    [[ "${OSTLER_GUI:-0}" != "1" ]] && return 0
    local event="$1"; shift

    # Resolve the marker fd. A non-numeric value must never reach a
    # `>&` redirection: bash would treat it as a FILENAME and create it.
    local marker_fd="${OSTLER_MARKER_FD:-}"
    if [[ ! "$marker_fd" =~ ^[0-9]+$ ]]; then
        marker_fd=""
    fi

    local kv key val enc wire="" trace=""
    for kv in "$@"; do
        case "$kv" in
            *=*) key="${kv%%=*}"; val="${kv#*=}" ;;
            # A bare token carries no field name to check, so it is
            # redacted rather than guessed at.
            *)   key=""; val="$kv" ;;
        esac

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
        enc="${kv//'%'/%25}"
        enc="${enc//$'\t'/ }"
        enc="${enc//$'\r'/ }"
        enc="${enc//$'\n'/%0A}"
        wire="${wire}"$'\t'"${enc}"

        # The trace records the RAW value's length, so the number means
        # "characters of customer data", not "characters after encoding".
        if [[ -n "$key" ]] && _ostler_marker_field_is_public "$key"; then
            enc="${val//$'\t'/ }"
            enc="${enc//$'\r'/ }"
            enc="${enc//$'\n'/ }"
            trace="${trace} ${key}=${enc}"
        elif [[ -n "$key" ]]; then
            trace="${trace} ${key}=<redacted:${#val}>"
        else
            trace="${trace} <redacted-field:${#val}>"
        fi
    done

    # Print on a fresh line so the GUI can anchor on \n#OSTLER\t.
    # Some upstream commands don't end with newline, so be defensive.
    if [[ -n "$marker_fd" ]] && { : >&"$marker_fd"; } 2>/dev/null; then
        printf '\n#OSTLER\t%s%s\n' "$event" "$wire" >&"$marker_fd"
        if [[ -n "${INSTALL_LOG:-}" ]]; then
            # The braces are load-bearing. Bash applies redirections
            # LEFT TO RIGHT, so in the un-braced form
            #     printf ... >> "$f" 2>/dev/null
            # the append is attempted -- and its failure reported to the
            # still-inherited stderr -- BEFORE 2>/dev/null takes effect.
            # A line written specifically to fail quietly therefore
            # SHOUTS. Measured on a live v1.0.37 walk 2026-08-20: 267
            # copies of "No such file or directory" in the customer's
            # own install log, from this exact statement.
            # Wrapping in a group redirects the GROUP's stderr first, so
            # the inner redirection failure lands in /dev/null where it
            # was always meant to. Verified by probe, all three forms.
            { printf '[gui-marker] %s%s\n' "$event" "$trace" \
                >> "${INSTALL_LOG}"; } 2>/dev/null || true
        fi
    else
        # No usable dedicated channel. Behave exactly as the pre-fix
        # emitter did, because a GUI that never receives a PROMPT marker
        # hangs forever waiting for an answer -- an install that cannot
        # finish is worse than a log entry. This is NOT a silent
        # fallback: when install.sh declared a marker fd and it is not
        # usable, that is an anomaly and it says so, once, in the log.
        if [[ -n "${OSTLER_MARKER_FD:-}" && "${__OSTLER_MARKER_FD_WARNED}" != "1" ]]; then
            __OSTLER_MARKER_FD_WARNED=1
            printf 'WARN: OSTLER-MARKER-FD-UNAVAILABLE fd=%s -- marker payloads are being written to the durable install log unredacted.\n' \
                "${OSTLER_MARKER_FD}" >&2
        fi
        printf '\n#OSTLER\t%s%s\n' "$event" "$wire" >&2
    fi
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
# Message-level error counter. Companion to __OSTLER_FAILED_STEPS, and a
# DIFFERENT question: that one counts steps that ended badly, this one counts
# [ERROR] lines raised anywhere. See gui_log for why both are needed.
__OSTLER_ERROR_LINES=0

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
        # #873: a non-ok status with rc=0 says "it failed with exit code
        # success", which is the DONE line's own defect one level down.
        # It arises when the status was ESCALATED by an argument rather
        # than measured from a child -- the abort close in gui_done below
        # is the case that matters, and on bash 3.2 a `set -u` death can
        # mask the process exit code to 0, so there genuinely is no code
        # to report. 1 here is the CONVENTION for "non-zero, the actual
        # code was not recoverable", NOT a measurement. Every path that
        # knows the real code calls gui_step_record_rc first and that
        # value is what prints.
        local rc="${__OSTLER_STEP_RC:-0}"
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
        [[ "$rc" -eq 0 ]] && rc=1
        gui_emit STEP_END "id=$id" "status=$status" "elapsed_s=$elapsed" \
                          "rc=${rc}"
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
    #
    # The wire behaviour is unchanged (scripts/extract_install_protocol.py
    # mirrors this derivation for the cross-component contract test, and
    # all 49 PROMPT callsites in install.sh pass an explicit id, so this
    # branch is currently dead in the product). What changes is that a
    # title-derived id is FLAGGED, so the redacted log trace does not
    # print it verbatim through the `id` allowlist. A title is the field
    # most likely to carry a person's name -- CM051 #399 shipped an
    # `identity_namesake` prompt whose title was a third party's real
    # display name, and its slug would have carried that name into
    # ~/.ostler/logs/install.log through the one field the trace trusts.
    __OSTLER_PROMPT_ID_DERIVED=0
    if [[ -z "$id" ]]; then
        id="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"
        [[ -z "$id" ]] && id="prompt"
        __OSTLER_PROMPT_ID_DERIVED=1
    fi

    if [[ "${OSTLER_GUI:-0}" == "1" && -n "${OSTLER_GUI_FD:-}" ]]; then
        local args=("id=$id" "kind=$kind" "title=$title")
        [[ -n "$default_value" ]] && args+=("default=$default_value")
        [[ -n "$help_text" ]]     && args+=("help=$help_text")
        [[ -n "$choices_csv" ]]   && args+=("choices=$choices_csv")
        [[ -n "$error_text" ]]    && args+=("error=$error_text")
        gui_emit PROMPT "${args[@]}"
        # Clear immediately. A flag that stays set would stain every
        # later marker's id, which is the mirror image of the defect
        # (see the __OSTLER_STEP_STATUS reset in gui_step_begin).
        __OSTLER_PROMPT_ID_DERIVED=0

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
    # ── The MESSAGE-level error counter (A2's silence sweep, tier 1) ──
    #
    # #839 gave the DONE line failed_steps, which counts STEPS that ended
    # other than ok. That is a real answer to a real question and it is not
    # this one. install.sh's err() only PRINTS: a run can emit any number of
    # [ERROR] lines, close every step cleanly, and produce
    #     status=ok failed_steps=0
    # which is TRUE by the contract above and still tells the customer
    # nothing about the errors. Measured on a real box: an install closed
    # "no errors detected" over 43+ real errors (#270).
    #
    # err() funnels through gui_log at level=error, so this is the one place
    # every error message passes. Counting HERE rather than in install.sh's
    # err() is the same argument #873 makes for closing the open step in this
    # function: the guarantee should be a property of the emitter, not a rule
    # each future caller has to remember.
    #
    # SUBSHELL CAVEAT, STATED RATHER THAN HIDDEN: this is a plain shell
    # variable, so an err() raised inside a $( ) or a pipeline segment
    # increments a copy and is lost. __OSTLER_FAILED_STEPS has carried
    # exactly this limitation since #839 and it is accepted. The count is
    # therefore a FLOOR, not a total -- which is the safe direction, because
    # it can under-report but can never invent an error that did not happen.
    if [[ "$level" == "error" ]]; then
        __OSTLER_ERROR_LINES=$(( ${__OSTLER_ERROR_LINES:-0} + 1 ))
    fi
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

    # ── #873: the run that died INSIDE a step ──────────────────────
    #
    # #839 made the counter honest for every step that is CLOSED, because
    # gui_step_end is the only thing that increments it. An abort never
    # closes its step. All three abort paths in install.sh --
    #
    #     fail()            gui_done fail
    #     _ostler_on_err()  gui_done fail
    #     EXIT backstop     gui_done fail
    #
    # -- reached this function with __OSTLER_STEP_ID still set and the
    # counter still at whatever the closed steps had left it, which on an
    # early abort is zero. A v1.0.43 run therefore terminated with
    #
    #     #OSTLER DONE status=fail failed_steps=0
    #
    # -- a line that says the run failed and that nothing in it failed.
    #
    # The close happens HERE rather than at the three call sites for the
    # reason #839 gives for the redaction allowlist: the guarantee has to
    # be a property of the emitter, not a rule each future abort path has
    # to remember. A fourth abort path added next year gets this for free.
    #
    # THE ATTRIBUTION IS STATED, NOT SMUGGLED. The open step is the last
    # step that began and did not end, so a failure between step N's work
    # finishing and step N+1 opening is attributed to N. That is exactly
    # the attribution install.sh's EXIT backstop already makes when it
    # builds ERR-99-INSTALL-ABORT-<step>; this puts the same claim on the
    # step wire instead of only in an error code, so the reader can see
    # which step it was rather than parsing it out of a code string.
    #
    # `error`, not a new status, because it is a value the Swift decoder
    # already recognises (StepStatus.error). An unrecognised status
    # decodes to .warn there, which would quietly demote a hard abort.
    #
    # A cancel does not come through here (gui_cancelled has its own
    # path), so a deliberate user cancel still counts nothing.
    if [[ "$status" != "ok" && -n "${__OSTLER_STEP_ID:-}" ]]; then
        gui_step_end error
    fi

    # CX-454: record that a terminal DONE marker has gone out, so the
    # install.sh ERR trap + EXIT backstop never double-report or
    # overwrite this with a synthetic mid-script-death failure.
    OSTLER_DONE_EMITTED=1
    if [[ -n "${OSTLER_LAST_ERROR_CODE:-}" ]]; then
        gui_emit DONE "status=$status" "code=${OSTLER_LAST_ERROR_CODE}" \
                      "failed_steps=${__OSTLER_FAILED_STEPS:-0}" \
                      "errors=${__OSTLER_ERROR_LINES:-0}"
    else
        gui_emit DONE "status=$status" \
                      "failed_steps=${__OSTLER_FAILED_STEPS:-0}" \
                      "errors=${__OSTLER_ERROR_LINES:-0}"
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
