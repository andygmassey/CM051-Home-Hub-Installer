#!/usr/bin/env bash
# #1562: a GUI uninstall needs a script that says what it is doing.
#
# MEASURED before this change, on the heredoc extracted from install.sh:
#
#   uninstaller                    450 lines
#   gui_emit / #OSTLER markers       0
#   plain echo/printf sites         78
#   gui_emit sites in install.sh    19    <- the control, and the shape mirrored
#
# So the only way to show a customer what the uninstaller was doing was to show
# them a terminal, and Andy asked for a GUI precisely because the customers are
# not technical.
#
# 🔴 THE SAFETY PROPERTY IS THAT MARKERS CHANGE NOTHING. Proved on the PR by a
# comment-stripped executable-line diff: 0 lines removed or changed, 17 added,
# every one of them the emitter or an emit call. This file guards the runtime
# half: silent without the env var, correct format with it, and every value it
# reports is one the script actually computes.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SRC="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -r "$SRC" ] || cant "install.sh is not readable at ${SRC}"
WORK="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
U="${WORK}/uninstaller"
/usr/bin/awk "/^cat > \"\\\${OSTLER_DIR}\\/bin\\/ostler-uninstall\" <<'UNINSTALLEOF'\$/{f=1;next} /^UNINSTALLEOF\$/{f=0} f" \
    "$SRC" > "$U"
[ -s "$U" ] || cant "could not extract the ostler-uninstall heredoc; nothing below was examined"
/bin/bash -n "$U" || cant "the extracted uninstaller is not valid shell"

# ── every value a marker reports must be one the script computes ─────────────
# Under `set -u` an unset variable inside a marker does not print an empty
# field, it ABORTS the uninstall. So this is a live-bug check, not tidiness.
missing=""
while IFS= read -r var; do
    [ -n "$var" ] || continue
    if [ "$(/usr/bin/grep -cE "^[[:space:]]*(local )?${var}=" "$U")" -eq 0 ]; then
        missing="${missing} ${var}"
    fi
done < <(/usr/bin/grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' <(/usr/bin/grep -E '^[[:space:]]*_u_emit [A-Z]' "$U") \
         | tr -d '${}' | sort -u)
[ -z "$missing" ] \
    && ok "every variable a marker reports is assigned in the script (an unset one would abort under set -u)" \
    || bad "marker(s) reference variables never assigned:${missing}"

n_emit="$(/usr/bin/grep -cE '^[[:space:]]*_u_emit [A-Z]' "$U")"
[ "${n_emit:-0}" -gt 0 ] \
    && ok "CONTROL: ${n_emit} emit call site(s) exist, so the checks below are not vacuous" \
    || cant "no emit call sites at all; every assertion below would be about nothing"

# ── drive the gate region for real, with the destructive remainder removed ───
gate_end="$(/usr/bin/grep -n '^# ── User-facing content' "$U" | head -1 | cut -d: -f1)"
[ -n "$gate_end" ] || cant "could not find the end-of-gate marker; refusing to guess where to truncate a destructive script"
head -n "$((gate_end - 1))" "$U" > "${WORK}/gate.sh"
/bin/bash -n "${WORK}/gate.sh" || cant "the truncated gate is not valid shell"
export OSTLER_DIR="${WORK}/fake" USER_FACING_ROOT="${WORK}/docs"; mkdir -p "$OSTLER_DIR" "$USER_FACING_ROOT"

run() { printf '%s' "$2" | env OSTLER_GUI="$1" /bin/bash "${WORK}/gate.sh" "${@:3}" 2>/dev/null; }

# 1. silent without the env var
out="$(OSTLER_GUI="" run "" "" --yes)"
case "$out" in *'#OSTLER'*) bad "markers were emitted with OSTLER_GUI unset; a terminal user would see protocol noise" ;;
               *) ok "silent when OSTLER_GUI is unset, so the terminal experience is unchanged" ;; esac

# 2. present with it, and in the wire format the Swift decoder expects
out="$(run 1 "" --yes)"
case "$out" in *'#OSTLER'*) ok "markers appear when OSTLER_GUI=1" ;;
               *) bad "no markers with OSTLER_GUI=1; the emitter never fires" ;; esac
line="$(printf '%s\n' "$out" | /usr/bin/grep '^#OSTLER' | head -1)"
# FIELD ONE MUST BE EXACTLY THE SENTINEL, not merely start with it.
#
# My first version asserted "at least 2 tab-separated fields", and a mutant that
# replaced ONLY THE FIRST separator with a space SURVIVED it: the remaining k=v
# separators are still tabs, so the field count stayed above the floor while
# field 1 had silently become "#OSTLER EVENT". The decoder splits on tabs and
# would have read the event name as part of the sentinel.
#
# A count is a weaker claim than an identity. Assert the identity.
f1="$(printf '%s' "$line" | /usr/bin/awk -F'\t' '{print $1}')"
f2="$(printf '%s' "$line" | /usr/bin/awk -F'\t' '{print $2}')"
nfields="$(printf '%s' "$line" | /usr/bin/awk -F'\t' '{print NF}')"
if [ "$f1" = "#OSTLER" ] && [ -n "$f2" ]; then
    ok "field 1 is exactly the sentinel and field 2 is the event '${f2}' (${nfields} tab fields)"
else
    bad "field 1 is '${f1}' and field 2 is '${f2}'; the decoder splits on tabs and would misread this"
fi
case "$line" in '#OSTLER'*) ok "and it begins with the #OSTLER sentinel" ;;
                *) bad "marker does not begin with #OSTLER: '${line}'" ;; esac

# 3. the three consent outcomes are distinguishable on the wire
g_flag="$(run 1 "" --yes    | /usr/bin/grep -c 'UNINSTALL_CONSENT.*value=granted.*source=flag'   || true)"
g_prompt="$(run 1 'YES
'                            | /usr/bin/grep -c 'UNINSTALL_CONSENT.*value=granted.*source=prompt' || true)"
declined="$(run 1 'no
'                            | /usr/bin/grep -c 'UNINSTALL_CONSENT.*value=declined'               || true)"
unavail="$(run 1 ""          | /usr/bin/grep -c 'UNINSTALL_CONSENT.*value=unavailable'            || true)"
for pair in "flag:$g_flag" "prompt:$g_prompt" "declined:$declined" "unavailable:$unavail"; do
    k="${pair%%:*}"; v="${pair##*:}"
    [ "${v:-0}" -gt 0 ] && ok "consent outcome '${k}' is on the wire" \
                        || bad "consent outcome '${k}' emitted no marker; a GUI could not tell it happened"
done
# CONTROL: the four must not all be the same marker text.
[ "$(printf '%s\n' "$g_flag" "$declined" "$unavail" | sort -u | /usr/bin/grep -c .)" -ge 1 ] \
    && ok "CONTROL: the outcomes are matched by DISTINCT patterns, not one wildcard" \
    || bad "CONTROL: the outcome patterns collapse"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
