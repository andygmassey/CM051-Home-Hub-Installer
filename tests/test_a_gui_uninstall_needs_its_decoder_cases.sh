#!/usr/bin/env bash
# The uninstaller emits three marker events the GUI decoder does not know.
#
# MEASURED on origin/main:
#
#   uninstall marker events emitted   UNINSTALL_CONSENT, UNINSTALL_PHASE,
#                                     UNINSTALL_DONE          (#1568)
#   of those, known to ProgressProtocol.swift             0
#   unknown events decode to                              .unknown
#   what the coordinator does with .unknown               surfaces an
#                                                         "Unrecognised marker"
#                                                         warning
#
# ProgressProtocol.swift's own comment: unknown "must never round to fine".
#
# 🔴 THIS IS INERT TODAY AND THAT IS EXACTLY WHY IT NEEDS A GATE. Nothing runs
# the uninstaller with OSTLER_GUI=1 -- the only callers are two ttywalk.sh sites
# on a terminal -- so the markers are silent and no warning appears. The day
# someone wires a GUI button to the uninstaller (#1562's app half, which Andy
# asked for), every marker it emits becomes a warning, and the person wiring the
# button is not necessarily the person who knows that.
#
# So: the moment the app gains a way to RUN the uninstaller, the decoder must
# already know the vocabulary. This file fails at that moment and not before.
#
# It deliberately does NOT require the cases today. Landing placeholder decoder
# cases would invent GUI behaviour that belongs to the app half, and would be a
# second thing to remove later.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SRC="${REPO}/install.sh"
PROTO="${REPO}/gui/OstlerInstaller/ProgressProtocol.swift"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -r "$SRC" ]   || cant "install.sh is not readable at ${SRC}"
[ -r "$PROTO" ] || cant "ProgressProtocol.swift is not readable at ${PROTO}"

# ── the vocabulary the uninstaller actually emits ────────────────────────────
WORK="$(mktemp -d)" || cant "mktemp failed"; trap 'rm -rf "$WORK"' EXIT
U="${WORK}/u"
/usr/bin/awk "/^cat > \"\\\${OSTLER_DIR}\\/bin\\/ostler-uninstall\" <<'UNINSTALLEOF'\$/{f=1;next} /^UNINSTALLEOF\$/{f=0} f" \
    "$SRC" > "$U"
[ -s "$U" ] || cant "could not extract the uninstaller heredoc; the anchors moved"

EVENTS="$(/usr/bin/grep -oE '_u_emit [A-Z][A-Z0-9_]*' "$U" | awk '{print $2}' | sort -u)"
n_events="$(printf '%s\n' "$EVENTS" | /usr/bin/grep -c . || true)"
if [ "${n_events:-0}" -eq 0 ]; then
    ok "the uninstaller emits no structured events, so there is no vocabulary to teach"
    echo; echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="; exit 0
fi
ok "CONTROL: the uninstaller emits ${n_events} distinct event name(s), so the check below has a subject"

# ── can the app RUN the uninstaller? that is the trigger ────────────────────
# Anything in the Swift sources naming the uninstaller binary or its script.
runs="$(/usr/bin/grep -rlE 'ostler-uninstall|uninstall\.sh' "${REPO}/gui" --include='*.swift' 2>/dev/null | /usr/bin/grep -c . || true)"
echo "  swift sources referencing the uninstaller: ${runs:-0}"

known=0; unknown_list=""
while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    if [ "$(/usr/bin/grep -c "\"${ev}\"" "$PROTO" || true)" -gt 0 ]; then
        known=$((known + 1))
    else
        unknown_list="${unknown_list} ${ev}"
    fi
done <<< "$EVENTS"
echo "  of those, known to ProgressProtocol.swift: ${known} of ${n_events}"

if [ "${runs:-0}" -eq 0 ]; then
    if [ "$known" -eq "$n_events" ]; then
        ok "the app cannot run the uninstaller yet, and the decoder already knows every event anyway"
    else
        ok "the app cannot run the uninstaller yet, so the${unknown_list} event(s) are inert. This gate fires the moment that changes."
    fi
else
    if [ "$known" -eq "$n_events" ]; then
        ok "the app can run the uninstaller AND the decoder knows all ${n_events} event(s)"
    else
        bad "the app can now run the uninstaller (${runs} swift file(s) name it) but the decoder does NOT know:${unknown_list}. Every one of those markers will decode to .unknown and surface as an 'Unrecognised marker' warning -- ProgressProtocol.swift's own comment says unknown must never round to fine. Add the cases in the same change that wires the button."
    fi
fi

# ── CONTROL: the known-check must be able to say YES ─────────────────────────
# A predicate that can only ever answer "not known" would make the arm above
# unfailable in the direction that matters.
for probe in DONE STEP PCT; do
    if [ "$(/usr/bin/grep -c "\"${probe}\"" "$PROTO" || true)" -gt 0 ]; then
        ok "CONTROL: the same predicate finds the existing '${probe}' event, so 'not known' is a measurement"
        break
    fi
done

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
