#!/usr/bin/env bash
#
# tests/test_marker_payloads_never_reach_install_log.sh
#
# WHAT THIS MEASURES, AND WHY THE OTHER SCANNER CANNOT
# ----------------------------------------------------
# bin/operator-pii-scan.sh reads SOURCE. It answers "does a literal
# person's name appear in a tracked file?". It is green on this defect and
# always was, because the defect is not in the source: it is in what the
# source PRODUCES at runtime.
#
# The defect, measured on install.sh at main:
#
#   install.sh        exec > >(${_OSTLER_TEE_CMD} -a "${INSTALL_LOG}") 2>&1
#                     (line 1930 at 641e274, the commit this gate was
#                      first proved red against)
#   progress_emitter  gui_emit writes every #OSTLER marker to stderr
#
# stderr is folded into stdout by that redirection, so EVERY marker
# payload -- prompt titles, help copy, pre-filled defaults, the recovery
# key -- is appended verbatim to ~/.ostler/logs/install.log and kept
# forever. CM051 #399 is the concrete case: a `calendar_owner` help
# string carrying up to three verbatim calendar event titles (shared and
# family calendars included) and an `identity_namesake` title carrying a
# third party's real display name.
#
# So the gate and the defect must share a surface, and the surface is the
# LOG FILE, not the source tree. This test drives the emitter through
# install.sh's OWN durable-log construction and then reads the log that
# construction produced.
#
# THE CONSTRUCTION IS NOT REIMPLEMENTED HERE. It is extracted from
# install.sh between two anchors and sourced, so a change to install.sh's
# logging block is a change to what this gate exercises. If someone
# deletes the marker-fd setup, this gate runs the deleted version and
# goes red. A reimplementation would have drifted and passed.
#
# CANARIES ARE SYNTHETIC AND MUST BE FOUND, NOT FORGIVEN
# ------------------------------------------------------
# Every planted value is invented or drawn from a reserved range:
#   - person names are fabricated (no real person carries them)
#   - the phone number is inside Ofcom's 01632 960xxx drama-only range
#   - the email address is under the RFC 2606 .invalid TLD
#   - the recovery key is a fixed literal, not a generated key
# They are planted by this script, so the scanner knows exactly what it
# must find. It is not asked to recognise a name it has never seen.
#
# THREE CONTROLS KEEP THE ABSENCE HONEST
# --------------------------------------
#   1. POSITIVE LOG CONTROL. A distinctive literal is echoed on the
#      ordinary stream. It MUST appear in install.log. If it does not,
#      the harness never ran or the scanner is reading the wrong file,
#      and "no canaries found" is a fake absence. That is exit 2.
#   2. GUI-CHANNEL CONTROL. Every canary MUST still appear on what the
#      GUI process would read (its stdout pipe, its stderr pipe, or
#      both). A "fix" that stops the customer being asked the question
#      is not a fix, and this control fails it.
#   3. DENOMINATORS. Markers emitted, log lines scanned, marker lines
#      found in the log, payload fields examined, canaries checked. Any
#      denominator that must be non-zero and is zero is exit 2, never a
#      pass.
#
# EXIT CODES
#   0  no marker payload reached the durable log
#   1  a marker payload reached the durable log (the defect)
#   2  could not run, or a control failed (never treat as a pass)
#
# macOS bash 3.2.57 + BSD userland compatible. No associative arrays, no
# `grep -P`, no `sed \b`. British English; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

RC_CANNOT_RUN=2
RC_LEAK=1

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  A gate that could not measure anything is not a passing gate." >&2
    exit "$RC_CANNOT_RUN"
}

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at ${INSTALL_SH}"
[[ -f "$EMITTER" ]]    || cannot_run "lib/progress_emitter.sh not found at ${EMITTER}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-markergate.XXXXXX")" \
    || cannot_run "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

# ── Extract install.sh's real durable-log construction ─────────────
#
# Anchors chosen because both are unique, whole-line matches on main.
# Uniqueness is asserted: two matches means install.sh grew a second
# logging block and this gate is measuring the wrong one.
START_ANCHOR='mkdir -p "${LOGS_DIR}" 2>/dev/null || true'
END_ANCHOR='export INSTALL_LOG'

start_hits="$(grep -c -x -F -- "$START_ANCHOR" "$INSTALL_SH")"
end_hits="$(grep -c -x -F -- "$END_ANCHOR" "$INSTALL_SH")"
[[ "$start_hits" == "1" ]] || cannot_run \
    "start anchor matched ${start_hits} times in install.sh (expected exactly 1): ${START_ANCHOR}"
[[ "$end_hits" == "1" ]] || cannot_run \
    "end anchor matched ${end_hits} times in install.sh (expected exactly 1): ${END_ANCHOR}"

start_line="$(grep -n -x -F -- "$START_ANCHOR" "$INSTALL_SH" | cut -d: -f1)"
end_line="$(grep -n -x -F -- "$END_ANCHOR" "$INSTALL_SH" | cut -d: -f1)"
if [[ "$start_line" -ge "$end_line" ]]; then
    cannot_run "anchors out of order in install.sh (start=${start_line} end=${end_line})"
fi

LOGBLOCK="${WORK}/logblock.sh"
sed -n "${start_line},${end_line}p" "$INSTALL_SH" > "$LOGBLOCK"
block_lines="$(wc -l < "$LOGBLOCK" | tr -d ' ')"
[[ "$block_lines" -gt 0 ]] || cannot_run "extracted an empty logging block from install.sh"

# ── The canary plan ────────────────────────────────────────────────
#
# canary <TAB> event <TAB> field <TAB> marker id <TAB> class
# Each row is a payload shape that exists on main today, or that CM051
# #399 proved is one prompt away.
PLAN="${WORK}/plan.tsv"
cat > "$PLAN" <<'PLAN_EOF'
Perpetua Ravensmere-Quilloch	PROMPT	help	calendar_owner	third-party person name in prompt help (CM051 #399 shape)
Ostler Canary Standup Ravensmere	PROMPT	help	calendar_owner	verbatim calendar event title in prompt help (CM051 #399 shape)
Barnabas Threddlewick	PROMPT	title	identity_namesake	third-party display name in prompt title (CM051 #399 shape)
Wilhelmina Quibbleforth	PROMPT	default	user_name	me-card full name pre-fill (install.sh:3846 shape)
+441632960987	PROMPT	default	imessage_allowed	me-card phone pre-fill, Ofcom drama range (install.sh:4453 shape)
quibbleforth@example.invalid	PROMPT	default	imessage_allowed	me-card email pre-fill, RFC 2606 reserved (install.sh:4453 shape)
OSTLER-CANARY-RECOVERY-KEY-4F2A9C	RECOVERY_KEY	value	recovery_key	encryption recovery key (install.sh:21368 shape)
PLAN_EOF

POSITIVE_CONTROL="OSTLER-GATE-POSITIVE-CONTROL-ORDINARY-LOG-LINE"

# ── Drive the emitter through the extracted construction ───────────
#
# stdout and stderr of the harness stand in for the two pipes
# InstallerCoordinator.swift attaches to the install.sh subprocess
# (proc.standardOutput / proc.standardError, both fed to the same
# ProgressDecoder). Capturing them separately lets control 2 assert the
# GUI still receives every payload.
HARNESS="${WORK}/harness.sh"
cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail
WORK="$1"
LOGBLOCK="$2"
EMITTER="$3"
POSITIVE_CONTROL="$4"

LOGS_DIR="${WORK}/logs"
export LOGS_DIR
OSTLER_GUI=1
export OSTLER_GUI

# Answers the GUI would push back down the prompt FIFO, one per
# gui_read. Wired to a real fd so gui_read takes its OSTLER_GUI_FD
# branch rather than the TTY fallback.
cat > "${WORK}/answers.txt" <<'ANS'
Wilhelmina Quibbleforth
+441632960987
personal
yes
ANS
exec 7<"${WORK}/answers.txt"
OSTLER_GUI_FD=7
export OSTLER_GUI_FD

# Everything below this point runs under install.sh's own logging
# construction, sourced verbatim from install.sh.
# shellcheck disable=SC1090
. "$LOGBLOCK"

# shellcheck disable=SC1090
. "$EMITTER"

# Positive log control: an ordinary line, on the ordinary stream.
echo "$POSITIVE_CONTROL"

# Structural markers with no customer data. Present so the gate can
# count a non-zero marker denominator even if every payload marker
# were removed.
gui_step_begin "marker_gate_probe" "Checking your details" 2 3 11
gui_emit PCT "step=marker_gate_probe" "pct=42"
gui_log info "harness: structural markers emitted"

# 1 + 2: the CM051 #399 shape. A help string built from the customer's
# own calendars, carrying a third party's name and verbatim event
# titles.
_calendar_help="Recent events on this calendar: Ostler Canary Standup Ravensmere, Lunch with Perpetua Ravensmere-Quilloch, Dentist"
_="$(gui_read "Which calendar is yours?" choice "personal" "$_calendar_help" "personal,shared" "calendar_owner")"

# 3: the identity_namesake shape. A third party's display name in the
# prompt TITLE.
_="$(gui_read "Is Barnabas Threddlewick the same person as you?" yesno "n" "" "" "identity_namesake")"

# 4: install.sh:3846. The Contacts me-card full name as the default.
_="$(gui_read "Confirm your name" text "Wilhelmina Quibbleforth" "" "" "user_name")"

# 5 + 6: install.sh:4453. Me-card phone and email pre-filled as the
# comma-separated allowlist default.
_="$(gui_read "Who may message your assistant?" text "+441632960987, quibbleforth@example.invalid" "" "" "imessage_allowed")"

# 7: install.sh:21368. The recovery key, emitted as a marker value.
gui_emit RECOVERY_KEY "value=OSTLER-CANARY-RECOVERY-KEY-4F2A9C"

gui_step_end
gui_done ok
HARNESS_EOF

mkdir -p "${WORK}/logs"
/usr/bin/env bash "$HARNESS" "$WORK" "$LOGBLOCK" "$EMITTER" "$POSITIVE_CONTROL" \
    > "${WORK}/gui_stdout.txt" 2> "${WORK}/gui_stderr.txt"
harness_rc=$?

INSTALL_LOG="${WORK}/logs/install.log"

# The tee runs in a process substitution and can outlive the harness
# shell by a few milliseconds. Wait for the positive control to land
# rather than guessing at a sleep duration.
waited=0
while [[ "$waited" -lt 200 ]]; do
    if [[ -f "$INSTALL_LOG" ]] \
       && grep -q -F -- "$POSITIVE_CONTROL" "$INSTALL_LOG" 2>/dev/null; then
        break
    fi
    waited=$((waited + 1))
    sleep 0.05
done

# ── Control 1: the positive log control ────────────────────────────
if [[ ! -f "$INSTALL_LOG" ]]; then
    cannot_run "the harness produced no log at ${INSTALL_LOG} (harness rc=${harness_rc})"
fi
if ! grep -q -F -- "$POSITIVE_CONTROL" "$INSTALL_LOG"; then
    echo "harness stdout:" >&2; sed -n '1,40p' "${WORK}/gui_stdout.txt" >&2
    echo "harness stderr:" >&2; sed -n '1,40p' "${WORK}/gui_stderr.txt" >&2
    cannot_run "positive control '${POSITIVE_CONTROL}' never reached ${INSTALL_LOG}; an absence measured here is fake"
fi

log_lines="$(wc -l < "$INSTALL_LOG" | tr -d ' ')"
[[ "$log_lines" -gt 0 ]] || cannot_run "install.log has 0 lines; nothing was examined"

# ── Denominators ───────────────────────────────────────────────────
markers_on_gui_channel="$(grep -c '^#OSTLER	' "${WORK}/gui_stderr.txt" 2>/dev/null || true)"
markers_on_gui_stdout="$(grep -c '^#OSTLER	' "${WORK}/gui_stdout.txt" 2>/dev/null || true)"
markers_on_gui_channel="${markers_on_gui_channel:-0}"
markers_on_gui_stdout="${markers_on_gui_stdout:-0}"
markers_emitted=$((markers_on_gui_channel + markers_on_gui_stdout))

markers_in_log="$(grep -c '^#OSTLER	' "$INSTALL_LOG" 2>/dev/null || true)"
markers_in_log="${markers_in_log:-0}"
traces_in_log="$(grep -c '^\[gui-marker\] ' "$INSTALL_LOG" 2>/dev/null || true)"
traces_in_log="${traces_in_log:-0}"
canaries_checked="$(grep -c . "$PLAN")"

if [[ "$markers_emitted" -eq 0 ]]; then
    cannot_run "0 #OSTLER markers reached the GUI on either pipe; the emitter did not run, so no absence in the log means anything"
fi
if [[ "$canaries_checked" -eq 0 ]]; then
    cannot_run "the canary plan is empty; 0 of 0 canaries found is not a pass"
fi

echo "DENOMINATOR"
echo "  install.sh logging block   : lines ${start_line}-${end_line} (${block_lines} lines, extracted not reimplemented)"
echo "  durable log examined       : ${INSTALL_LOG}"
echo "  log lines scanned          : ${log_lines}"
echo "  markers emitted to the GUI : ${markers_emitted} (stderr pipe ${markers_on_gui_channel}, stdout pipe ${markers_on_gui_stdout})"
echo "  #OSTLER lines in the log   : ${markers_in_log} (must be 0)"
echo "  [gui-marker] traces in log : ${traces_in_log}"
echo "  synthetic canaries checked : ${canaries_checked}"
echo ""

FAILED=0

# ── Assertion A: no canary value in the durable log ────────────────
#
# Named first because it is the defect. The message names the artefact,
# the line, the marker event and the field, because "PII found" without
# those four is a message that sends a reader hunting.
while IFS=$'\t' read -r canary event field marker_id klass; do
    [[ -n "$canary" ]] || continue
    hits="$(grep -n -F -- "$canary" "$INSTALL_LOG" || true)"
    if [[ -n "$hits" ]]; then
        FAILED=1
        hit_line="$(printf '%s' "$hits" | head -n 1 | cut -d: -f1)"
        evidence="$(printf '%s' "$hits" | head -n 1 | cut -d: -f2- | cut -c1-160)"
        echo "FAIL: a GUI marker payload reached the durable install log."
        echo "  artefact : ${INSTALL_LOG}"
        echo "  line     : ${hit_line}"
        echo "  marker   : ${event}"
        echo "  field    : ${field}   (marker id=${marker_id})"
        echo "  class    : ${klass}"
        echo "  value    : ${canary}   [synthetic canary planted by this test]"
        echo "  evidence : ${evidence}"
        echo "  why      : gui_emit writes markers to stderr, and install.sh:${start_line}-${end_line}"
        echo "             folds stderr into the tee that appends to the log. Route the"
        echo "             full marker to the GUI marker fd and leave a redacted trace"
        echo "             on stderr instead."
        echo ""
    fi
done < "$PLAN"

# ── Assertion B: no #OSTLER marker line in the durable log at all ──
#
# Assertion A can only find what it planted. This one holds for every
# field name, present and future: if no marker line reaches the log,
# no marker payload can. It is the reason a NEW prompt written next
# year is safe without its author knowing this file exists.
if [[ "$markers_in_log" -ne 0 ]]; then
    FAILED=1
    first_hit="$(grep -n '^#OSTLER	' "$INSTALL_LOG" | head -n 1)"
    first_line="$(printf '%s' "$first_hit" | cut -d: -f1)"
    first_event="$(printf '%s' "$first_hit" | cut -d: -f2- | cut -f2)"
    echo "FAIL: raw #OSTLER marker lines are being persisted to the durable install log."
    echo "  artefact       : ${INSTALL_LOG}"
    echo "  marker lines   : ${markers_in_log} of ${log_lines} log lines"
    echo "  first at line  : ${first_line} (event ${first_event})"
    echo "  why it matters : every field of every marker, including fields no"
    echo "                   scanner has been taught about yet, is kept verbatim"
    echo "                   and forever. The log must carry the redacted trace"
    echo "                   ([gui-marker] EVENT field=<redacted:N>), not the marker."
    echo ""
fi

# ── Assertion C: redacted traces carry no payload values ───────────
#
# The trace exists for debuggability, so it is allowed to name fields.
# It is not allowed to carry their values.
PAYLOAD_FIELDS="title help default choices error value probe"
fields_examined=0
if [[ "$traces_in_log" -gt 0 ]]; then
    while IFS= read -r trace_line; do
        for f in $PAYLOAD_FIELDS; do
            case " $trace_line " in
                *" ${f}="*) : ;;
                *) continue ;;
            esac
            fields_examined=$((fields_examined + 1))
            # Everything after "<field>=" up to the next space.
            val="${trace_line#* ${f}=}"
            val="${val%% *}"
            case "$val" in
                '<redacted:'*'>') : ;;
                *)
                    FAILED=1
                    tline="$(grep -n -F -- "$trace_line" "$INSTALL_LOG" | head -n 1 | cut -d: -f1)"
                    echo "FAIL: a redacted marker trace carried a payload value."
                    echo "  artefact : ${INSTALL_LOG}"
                    echo "  line     : ${tline}"
                    echo "  field    : ${f}"
                    echo "  value    : ${val}"
                    echo "  expected : ${f}=<redacted:N>"
                    echo ""
                    ;;
            esac
        done
    done < <(grep '^\[gui-marker\] ' "$INSTALL_LOG")
fi

# ── Control 2: the GUI still receives every payload ────────────────
#
# The cheapest way to make assertion A green is to stop emitting the
# prompt, which would stop the customer being asked. This control
# fails that. A canary must reach at least one of the two pipes the
# Swift coordinator reads.
cat "${WORK}/gui_stdout.txt" "${WORK}/gui_stderr.txt" > "${WORK}/gui_all.txt"
while IFS=$'\t' read -r canary event field marker_id klass; do
    [[ -n "$canary" ]] || continue
    if ! grep -q -F -- "$canary" "${WORK}/gui_all.txt"; then
        echo "CONTROL FAILED: '${canary}' (${event} ${field}, id=${marker_id}) reached neither" >&2
        echo "  the GUI stdout pipe nor the GUI stderr pipe. The customer would never" >&2
        echo "  be shown this. Suppressing the prompt is not a fix for logging it." >&2
        exit "$RC_CANNOT_RUN"
    fi
done < "$PLAN"
echo "CONTROL ok: all ${canaries_checked} payloads still reach the GUI (stdout+stderr pipes)"

if [[ "$FAILED" -eq 0 ]]; then
    # ── Control 3: assertion C must not be vacuous ─────────────────
    #
    # "Every payload field in the trace is redacted" is trivially true of
    # a log with no traces in it. If the redacted trace has vanished, the
    # log has lost its debuggability and assertion C examined nothing --
    # which is a different failure from a clean run, and must not print
    # like one.
    if [[ "$traces_in_log" -eq 0 ]]; then
        cannot_run "no [gui-marker] traces in ${INSTALL_LOG}: assertion C examined 0 fields, so its silence proves nothing"
    fi
    if [[ "$fields_examined" -eq 0 ]]; then
        cannot_run "${traces_in_log} traces in ${INSTALL_LOG} but 0 payload fields in them; assertion C examined nothing"
    fi
    echo "CONTROL ok: positive control reached ${INSTALL_LOG}"
    echo "PASS: 0 of ${canaries_checked} synthetic payloads reached the durable log;"
    echo "      ${markers_in_log} raw #OSTLER lines in ${log_lines} log lines;"
    echo "      ${fields_examined} payload fields examined across ${traces_in_log} redacted traces."
    exit 0
fi

echo "RESULT: marker payloads are reaching ${INSTALL_LOG}."
exit "$RC_LEAK"
