#!/usr/bin/env bash
# ============================================================================
# A SOURCE A PRESET GIVES YOU MUST ALSO BE TICKABLE, AND THIS TEST DRIVES THE
# PICKER RATHER THAN READING IT.
#
# THE DEFECT THAT PROMPTED IT (2026-09-23, apple_notes). Every layer below the
# picker shipped and was verified: extract_all.py has apple_notes in
# DEFAULT_SOURCES and writes apple_notes.json; the vendored CM024 converter
# registers the apple_notes adapter; install.sh's hydrate leg drives
# `convert --source apple_notes` + embed into apple_notes_knowledge; the
# assistant searches that collection; the Doctor prints an apple_notes row.
# The one missing link was that NO PATH A CUSTOMER CAN TAKE ever put the name
# into OSTLER_FDA_SOURCES. Measured on the v1.0.101 walk:
# state/hydrate/apple_notes.done read `status=no_data item_count=0
# detail=no_export_json` and imports/fda/apple_notes.json did not exist.
#
# WHY A SECOND TEST, GIVEN test_every_default_source_is_requested.sh EXISTS.
# That test greps the RECOMMENDED=/EVERYTHING= assignment LINES. Two things it
# cannot see, and both of them bit:
#
#   1. It reads TEXT, not OUTCOME. A name can appear on an assignment line and
#      still never reach OSTLER_FDA_SOURCES -- the `:-` default inside the
#      config heredoc at install.sh's Phase 3.5 is exactly that: it matches
#      `^OSTLER_FDA_SOURCES=.*apple_notes` and is DEAD, because the picker has
#      already assigned the variable by the time that line is expanded. A
#      sibling gate passed on that line for weeks.
#   2. It never looks at the Customise branch at all. A source added to a
#      preset and not to the picker is worse than dark: the Recommended
#      customer gets it, the Customise customer silently does not, and nothing
#      in the "Enabled sources:" summary says a source was unavailable.
#
# So this test EXECUTES the real section 9.5 region lifted out of install.sh,
# with gui_read stubbed, and asserts on what the variable actually becomes.
#
# Exit: 0 every preset source is tickable | 1 one or more are not | 2 CANNOT RUN
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

echo "== the Customise picker must offer every source a preset can enable =="

# ── 1. LIFT THE REAL REGION ───────────────────────────────────────
# Anchors, and a CANNOT RUN if any has moved. A test that silently lifts the
# wrong lines would answer a question nobody asked.
START="$(grep -n '^cat <<MENU$' "$INSTALL_SH" | cut -d: -f1 | head -1)"
PRESET_LINE="$(grep -n '^PRESET="\$(gui_read' "$INSTALL_SH" | cut -d: -f1 | head -1)"
END="$(grep -n 'Enabled sources:' "$INSTALL_SH" | cut -d: -f1 | head -1)"
[ -n "$START" ]       || cannot "anchor 'cat <<MENU' not found; the preset menu moved"
[ -n "$PRESET_LINE" ] || cannot "anchor 'PRESET=\$(gui_read' not found; the picker moved"
[ -n "$END" ]         || cannot "anchor 'Enabled sources:' not found; the summary moved"
[ "$START" -lt "$PRESET_LINE" ] && [ "$PRESET_LINE" -lt "$END" ] \
    || cannot "the three anchors are out of order (${START}/${PRESET_LINE}/${END}); the region is not what this test thinks it is"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REGION="${WORK}/region.sh"
sed -n "${START},${END}p" "$INSTALL_SH" > "$REGION"
n_region="$(wc -l < "$REGION" | tr -d ' ')"
if [ "$n_region" -ge 80 ]; then
    ok "lifted install.sh lines ${START}..${END} (${n_region} lines)"
else
    bad "the lifted region is only ${n_region} lines. The anchors matched something too small and every verdict below is unfounded."
    finish
fi
bash -n "$REGION" || cannot "the lifted region does not parse; the anchors cut it mid-construct"

# ── 2. DRIVE IT ───────────────────────────────────────────────────
# $1 preset answer, $2 answer to every yes/no toggle, $3 HAS_CHROME,
# $4 HAS_WHATSAPP_DESKTOP. Prints the resulting OSTLER_FDA_SOURCES.
drive() {
    OSTLER_FDA_SOURCES="" \
    HAS_CHROME="$3" HAS_WHATSAPP_DESKTOP="$4" \
    _PRESET_ANSWER="$1" _YN_ANSWER="$2" \
    bash -c '
        set -uo pipefail
        # install.sh calls gui_read "<title>" <type> <default> <help> ...
        # so $2 is the prompt TYPE. Answer by type, which is the only thing
        # this test needs to know about the prompt protocol.
        gui_read() {
            case "$2" in
                choice) printf "%s" "$_PRESET_ANSWER" ;;
                yesno)  printf "%s" "$_YN_ANSWER" ;;
                *)      printf "" ;;
            esac
        }
        ok() { :; }; warn() { :; }; info() { :; }
        HAS_APPLE_MAIL_GMAIL=true
        OSTLER_TAKEOUT_PATH=""
        MSG_PROMPT_FDA_PRESET_TITLE=t
        MSG_PROMPT_FDA_PRESET_HELP=h
        MSG_OK_RECOMMENDED_SOURCES_SELECTED=x
        MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL=x
        MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED=x
        MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP=x
        . "$0" >/dev/null 2>&1
        printf "%s" "${OSTLER_FDA_SOURCES:-}"
    ' "$REGION"
}

REC="$(drive recommended Y false false)"
REC_APPS="$(drive recommended Y true true)"
EVERY="$(drive everything Y false false)"
EVERY_APPS="$(drive everything Y true true)"
CUST_ALL="$(drive customise Y true true)"
CUST_NONE="$(drive customise N true true)"

has() { case ",${1}," in *",${2},"*) return 0 ;; *) return 1 ;; esac; }

# ── 3. THE HARNESS MUST BE ALIVE ──────────────────────────────────
# Every "not offered" verdict below is worthless if the driver returns nothing.
# safari_history is in every preset and in the picker, so it is the control:
# if it is missing, the stubs failed and this run measured nothing.
live=1
for pair in "recommended:$REC" "everything:$EVERY" "customise-all-Y:$CUST_ALL"; do
    label="${pair%%:*}"; out="${pair#*:}"
    if has "$out" safari_history; then
        ok "CONTROL: the ${label} path ran and yielded safari_history"
    else
        bad "CONTROL FAILED: the ${label} path yielded '${out:-<empty>}'. The driver is dead and every verdict below is meaningless."
        live=0
    fi
done
[ "$live" -eq 1 ] || finish

# A ticked-nothing Customise run must yield nothing. If it yields the
# Recommended list instead, the yes/no stub is not reaching _ask_source and
# the "tick every box" run above proves nothing either.
if [ -z "$CUST_NONE" ]; then
    ok "CONTROL: Customise with every box declined yields an empty list"
else
    bad "CONTROL FAILED: Customise with every box declined yielded '${CUST_NONE}'. The yes/no answer is not reaching _ask_source, so the tick-everything run is not measuring the picker."
    finish
fi

# ── 4. THE JOIN ───────────────────────────────────────────────────
# Union of what the presets hand over, on a box with and without the
# third-party apps, then require each to be reachable via Customise.
PRESET_UNION="$(printf '%s\n' "$REC" "$REC_APPS" "$EVERY" "$EVERY_APPS" \
    | tr ',' '\n' | grep -v '^$' | sort -u)"
n_union="$(printf '%s\n' "$PRESET_UNION" | grep -c . || true)"
if [ "${n_union:-0}" -ge 6 ]; then
    ok "the presets between them enable ${n_union} sources"
else
    bad "the presets enable only ${n_union} sources. The driver is returning a truncated list; the join below would pass vacuously."
    finish
fi

printf '        preset union: %s\n' "$(printf '%s' "$PRESET_UNION" | tr '\n' ' ')"
printf '        customise-all: %s\n' "$CUST_ALL"

while IFS= read -r src; do
    [ -n "$src" ] || continue
    if has "$CUST_ALL" "$src"; then
        ok "tickable in Customise: ${src}"
    else
        bad "NOT TICKABLE: '${src}' is enabled by a preset but the Customise picker never offers it. A customer who picks Customise loses it silently while a Recommended customer keeps it. Add an _ask_source line for it."
    fi
done <<< "$PRESET_UNION"

# ── 5. ANTI-VACUITY ───────────────────────────────────────────────
# Prove the membership predicate can still say no. Without this, a `has()`
# that matched everything would report every source tickable.
if has "$CUST_ALL" definitely_not_a_real_source; then
    bad "ANTI-VACUITY FAILED: the membership test matched a source that does not exist, so every 'tickable' line above is meaningless."
else
    ok "anti-vacuity: a non-existent source is correctly NOT matched"
fi

# Substring safety: 'reminders' must not be satisfied by 'reminders_knowledge'
# and 'photos_metadata' must not satisfy a bare 'photos'. The predicate is
# comma-anchored precisely so a prefix cannot stand in for a member.
if has "safari_history,photos_metadata" photos; then
    bad "ANTI-VACUITY FAILED: 'photos' matched inside 'photos_metadata'. The predicate is doing a substring match, so a source can be reported present on a namesake."
else
    ok "anti-vacuity: membership is comma-anchored, not substring"
fi

# ── 6. THE ONE-WAY-NESS IS DELIBERATE ─────────────────────────────
# The reverse join must NOT be asserted: photos_faces is offered in Customise
# and is in no preset, by design (Art. 9 special category). State it here so a
# later reader does not "fix" the asymmetry.
if has "$CUST_ALL" photos_faces && ! has "$EVERY_APPS" photos_faces; then
    ok "by design: photos_faces is tickable but in no preset (Art. 9 opt-in)"
else
    bad "photos_faces is no longer picker-only. Either it left the picker, or a preset now enables special-category data without an explicit tick. Both need a decision, not a test edit."
fi

finish
