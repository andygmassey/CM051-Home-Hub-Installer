#!/usr/bin/env bash
# ============================================================================
# THE PICKER MUST PERSIST WHAT THE OWNER DECLINED, WHERE THE ASSISTANT READS IT.
#
# WHY. The assistant's morning brief drops calendar or message facts only on an
# explicit owner decline. Its first guard read the hydrate <name>.done markers
# instead; those are written in every outcome (no_data, error, cannot_run) and
# never from the picker, so an owner who unticked Calendar still got calendar
# facts, and a box with no marker lost them. The picker result lived only in
# the OSTLER_FDA_SOURCES variable. install.sh now writes
# ~/.ostler/config/sources_declined (one picker id per line: the calendar and
# message sources NOT enabled). Reader: ostler-assistant
# crates/zeroclaw-runtime/src/brief/connected.rs.
#
# This EXECUTES the real section 9.5 / 9.5b region lifted out of install.sh with
# gui_read stubbed and HOME pointed at a temp dir, and reads the file back.
#
# Exit: 0 pass | 1 fail | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$INSTALL_SH" ] || cannot "install.sh not readable at $INSTALL_SH"

START="$(grep -n '^cat <<MENU$' "$INSTALL_SH" | cut -d: -f1 | head -1)"
END="$(grep -nE '^( {4})?unset (_declined_dir )?_declined_tmp _src$' "$INSTALL_SH" | cut -d: -f1 | tail -1)"
B95="$(grep -n '^# ── 9.5b Persist' "$INSTALL_SH" | cut -d: -f1 | head -1)"
[ -n "$START" ] || cannot "anchor 'cat <<MENU' not found; the preset menu moved"
[ -n "$END" ]   || { bad "install.sh has no declined-sources writer (anchor 'unset _declined_tmp _src' not found)"; finish; }
[ "$START" -lt "$END" ] || cannot "anchors out of order (${START}/${END})"
END=$((END + 1))   # the closing fi of the picker-ran guard

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REGION="${WORK}/region.sh"
sed -n "${START},${END}p" "$INSTALL_SH" > "$REGION"
bash -n "$REGION" || cannot "the lifted region does not parse"
# 9.5b alone, for the "picker was not asked" arms.
WRITER="${WORK}/writer.sh"
[ -n "$B95" ] || cannot "anchor '9.5b Persist' not found"
sed -n "${B95},${END}p" "$INSTALL_SH" > "$WRITER"
bash -n "$WRITER" || cannot "the lifted 9.5b writer does not parse"
# The REAL promote and the helpers it needs, lifted by name.
FUNCS="${WORK}/funcs.sh"
: > "$FUNCS"
for fn in _ostler_set_paths _ostler_lock_home_dir _ostler_promote_prelaunch_tree; do
    awk -v f="${fn}() {" '$0 == f { p = 1 } p { print } p && /^}/ { exit }' "$INSTALL_SH" >> "$FUNCS"
done
[ "$(grep -c '^_ostler_promote_prelaunch_tree() {' "$FUNCS")" -eq 1 ] || cannot "could not lift the real promote"
bash -n "$FUNCS" || cannot "the lifted promote functions do not parse"

# $1 preset, $2 yes/no answer for every toggle, $3 HAS_WHATSAPP_DESKTOP,
# $4 HOME override, $5 optional: "break" makes the staging config path a file.
# First-install layout: OSTLER_DIR/CONFIG_DIR are the prelaunch staging tree,
# then the REAL _ostler_promote_prelaunch_tree runs. Prints the FINAL
# ~/.ostler/config/sources_declined ("<absent>" if none).
drive() {
    local home="$4"
    mkdir -p "$home"
    OSTLER_FDA_SOURCES="" HOME="$home" \
    HAS_CHROME=false HAS_WHATSAPP_DESKTOP="$3" BREAK="${5:-}" \
    _PRESET_ANSWER="$1" _YN_ANSWER="$2" \
    bash -c '
        set -uo pipefail
        gui_read() {
            case "$2" in
                choice) printf "%s" "$_PRESET_ANSWER" ;;
                yesno)  printf "%s" "$_YN_ANSWER" ;;
                *)      printf "" ;;
            esac
        }
        ok() { :; }; warn() { printf "WARN %s\n" "$*" >&2; }; info() { :; }
        fail_with_code() { printf "FAIL_WITH_CODE %s\n" "$*" >&2; exit 9; }
        _ostler_quiesce_interval_agents() { :; }
        _ostler_repair_venv_after_promote() { :; }
        _ostler_promote_venv_note() { :; }
        _ostler_verify_runtime_ready() { return 2; }
        HAS_APPLE_MAIL_GMAIL=true
        OSTLER_TAKEOUT_PATH=""
        MSG_PROMPT_FDA_PRESET_TITLE=t; MSG_PROMPT_FDA_PRESET_HELP=h
        MSG_OK_RECOMMENDED_SOURCES_SELECTED=x
        MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL=x
        MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED=x
        MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP=x
        . "$1"
        OSTLER_FINAL_DIR="${HOME}/.ostler"
        mkdir -p "${OSTLER_FINAL_DIR}/config"          # a prior tree, as on a re-run
        OSTLER_PRELAUNCH_DIR="$(mktemp -d "${OSTLER_FINAL_DIR}/.ostler-prelaunch.XXXXXX")"
        OSTLER_PRELAUNCH_PROMOTED=false
        _ostler_set_paths "$OSTLER_PRELAUNCH_DIR"
        mkdir -p "$DATA_DIR"
        if [ -n "$BREAK" ]; then : > "$CONFIG_DIR"; else mkdir -p "$CONFIG_DIR"; fi
        . "$2" >/dev/null 2>&1
        _ostler_promote_prelaunch_tree >/dev/null 2>&1
    ' _ "$FUNCS" "$REGION"
    local f="${home}/.ostler/config/sources_declined"
    if [ -f "$f" ]; then tr '\n' ',' < "$f"; else printf '<absent>'; fi
}

echo "== the picker writes sources_declined =="

REC="$(drive recommended Y false "${WORK}/h1")"
[ "$REC" = "whatsapp_history," ] \
    && ok "Recommended, no WhatsApp app: only whatsapp_history is not enabled ($REC)" \
    || bad "Recommended wrote '$REC', want 'whatsapp_history,'"

ALL="$(drive customise Y true "${WORK}/h2")"
[ -z "$ALL" ] \
    && ok "Customise, every box ticked: empty file, nothing declined" \
    || bad "Customise-all-ticked wrote '$ALL', want an empty file"

NONE="$(drive customise N true "${WORK}/h3")"
[ "$NONE" = "calendar,reminders,imessage,apple_mail,whatsapp_history," ] \
    && ok "Customise, every box unticked: all five calendar/message ids declined" \
    || bad "Customise-none wrote '$NONE'"

# CONTROL: the 'unticked' answer must be what changed the file. The same
# harness with every box ticked above wrote an empty file, so a writer that
# ignored OSTLER_FDA_SOURCES would fail one of the two.
[ "$ALL" != "$NONE" ] \
    && ok "CONTROL: ticked and unticked runs differ, so the file follows the picker" \
    || bad "CONTROL FAILED: ticked and unticked runs wrote the same file"

# A failed write is non-fatal and leaves NO file (no file never drops a fact).
OUT="$(drive customise N true "${WORK}/h4" break)"   # staging config path is a file
[ "$OUT" = "<absent>" ] \
    && ok "an unwritable config dir leaves no file" \
    || bad "unwritable config dir produced '$OUT'"

# --- the picker was NOT asked (re-run): never record "everything declined" ----
noask() { # $1 HOME, $2 "seed" to pre-create a file with known content
    local home="$1"
    mkdir -p "${home}/.ostler/config"
    [ "${2:-}" = seed ] && printf 'calendar\n' > "${home}/.ostler/config/sources_declined"
    OSTLER_FDA_SOURCES="" HOME="$home" bash -c '
        set -uo pipefail
        warn() { printf "WARN %s\n" "$*" >&2; }
        CONFIG_DIR="${HOME}/.ostler/config"
        . "$1" >/dev/null 2>&1
    ' _ "$WRITER"
    local f="${home}/.ostler/config/sources_declined"
    if [ -f "$f" ]; then tr '\n' ',' < "$f"; else printf '<absent>'; fi
}
NA="$(noask "${WORK}/h5")"
[ "$NA" = "<absent>" ] \
    && ok "picker not asked, empty OSTLER_FDA_SOURCES, no prior file: nothing written" \
    || bad "picker not asked wrote '$NA'; that is 'everything declined'"
NS="$(noask "${WORK}/h6" seed)"
[ "$NS" = "calendar," ] \
    && ok "picker not asked, prior file: left untouched ($NS)" \
    || bad "picker not asked clobbered the existing file: '$NS'"
# CONTROL: the same lifted writer WITH the flag set does write, so the two
# arms above are held back by the flag and not by a broken harness.
CTL="$(OSTLER_FDA_SOURCES="" HOME="${WORK}/h7" _SOURCES_PICKER_RAN=true bash -c '
    warn() { :; }; mkdir -p "${HOME}/.ostler/config"; CONFIG_DIR="${HOME}/.ostler/config"
    . "$1" >/dev/null 2>&1; tr "\n" "," < "${CONFIG_DIR}/sources_declined"' _ "$WRITER")"
[ "$CTL" = "calendar,reminders,imessage,apple_mail,whatsapp_history," ] \
    && ok "CONTROL: flag set + empty sources writes all five, so the flag is what gated the arms above" \
    || bad "CONTROL FAILED: '$CTL'"

finish
