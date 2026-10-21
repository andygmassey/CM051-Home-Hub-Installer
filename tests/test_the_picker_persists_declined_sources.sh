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
END="$(grep -n '^unset _declined_tmp _src$' "$INSTALL_SH" | cut -d: -f1 | head -1)"
[ -n "$START" ] || cannot "anchor 'cat <<MENU' not found; the preset menu moved"
[ -n "$END" ]   || { bad "install.sh has no declined-sources writer (anchor 'unset _declined_tmp _src' not found)"; finish; }
[ "$START" -lt "$END" ] || cannot "anchors out of order (${START}/${END})"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REGION="${WORK}/region.sh"
sed -n "${START},${END}p" "$INSTALL_SH" > "$REGION"
bash -n "$REGION" || cannot "the lifted region does not parse"

# $1 preset, $2 yes/no answer for every toggle, $3 HAS_WHATSAPP_DESKTOP,
# $4 HOME override. Prints the sources_declined file ("<absent>" if none).
drive() {
    local home="$4"
    mkdir -p "$home"
    OSTLER_FDA_SOURCES="" HOME="$home" \
    HAS_CHROME=false HAS_WHATSAPP_DESKTOP="$3" \
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
        HAS_APPLE_MAIL_GMAIL=true
        OSTLER_TAKEOUT_PATH=""
        MSG_PROMPT_FDA_PRESET_TITLE=t; MSG_PROMPT_FDA_PRESET_HELP=h
        MSG_OK_RECOMMENDED_SOURCES_SELECTED=x
        MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL=x
        MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED=x
        MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP=x
        . "$0" >/dev/null 2>&1
    ' "$REGION"
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
RO="${WORK}/h4"; mkdir -p "${RO}/.ostler"; : > "${RO}/.ostler/config"   # a file where the dir should be
OUT="$(drive customise N true "$RO")"
[ "$OUT" = "<absent>" ] \
    && ok "an unwritable config dir leaves no file" \
    || bad "unwritable config dir produced '$OUT'"

finish
