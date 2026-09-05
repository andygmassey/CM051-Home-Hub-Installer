#!/usr/bin/env bash
# The recovery key must be handed over by the run that MINTS it.
#
# WHY THIS EXISTS. MEASURED on archie2 (a virgin account) on the Mini 16,
# 2026-09-05, walking the v1.0.68 DMG. The install ended
# `DONE status=ok failed_steps=0 errors=0` and the customer never saw a
# recovery key. Andy: "Finished, but didn't offer to save the recovery key".
#
# THE KEY IS DELIBERATELY NEVER STORED. keychain.json holds a verifier and the
# DEK wrapped under the key, which is correct, and which is exactly what makes
# a missed disclosure permanent. There is no second chance:
#
#   * install.sh minted the key at one line and revealed it 15,490 lines later.
#   * The GUI presented the reveal sheet only inside `finished == .ok`, and
#     `recoveryKey` is an in-memory @Published property.
#   * Every LATER run takes install.sh's "already configured" skip, emits no
#     marker, and can no longer disclose anything.
#
# So a run that mints and then fails destroys the key. That is not a
# hypothesis. On this box an attempt at 10:43:53Z minted the keychain and
# failed; the attempt at 11:04:08Z finished clean, skipped, and printed a
# summary line promising a recovery passphrase that had been unreachable for
# twenty minutes. `ostler-recovery` ships and can never succeed for that
# install.
#
# WHAT THIS TEST ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
# It asserts ADJACENCY on both surfaces: the disclosure is reachable from the
# mint without crossing the rest of the install. It does NOT assert that a
# disclosure happened on any particular run -- that is a transcript property
# and it belongs to the box-walk probe, not here. A source test that demanded
# a disclosure on a run which minted nothing would be demanding the impossible,
# and the only way to satisfy it is to print a key nobody knows.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
SWIFT="${REPO}/gui/OstlerInstaller/Views/HintPanelView.swift"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
[ -f "$SWIFT" ]   || { echo "CANNOT-RUN: no HintPanelView.swift at ${SWIFT}" >&2; exit 2; }

# How far apart the mint and the reveal may sit. The point is "nothing that can
# fail runs in between", and line distance is the cheap proxy for it. 60 is
# generous for a guard plus a comment block and nowhere near the 15,490 the
# defect had.
ADJACENT_MAX=60

# ── Readers. Each prints a line number, or nothing. ──────────────────────
_mint_line()   { /usr/bin/grep -nF 'RECOVERY_KEY=$(echo "$SETUP_OUTPUT"' "$1" | head -1 | cut -d: -f1; }
_reveal_line() { /usr/bin/grep -nF 'gui_emit RECOVERY_KEY' "$1" | head -1 | cut -d: -f1; }
_reveal_count(){ /usr/bin/grep -cF 'gui_emit RECOVERY_KEY' "$1"; }

# Is the reveal still behind the emptiness guard? Look backwards from the
# reveal for the nearest `if [[ -n "$RECOVERY_KEY" ]]` within the window.
_guarded() {
    local f="$1" rl="$2" from
    from=$(( rl > 30 ? rl - 30 : 1 ))
    /usr/bin/sed -n "${from},${rl}p" "$f" | /usr/bin/grep -qF 'if [[ -n "$RECOVERY_KEY" ]]; then'
}

# Swift: is the `.sheet(` that presents the key INSIDE the `finished == .ok`
# branch? Brace-count from the `if` to its matching close, then compare.
# Prints "inside" or "outside", or "nofind".
_sheet_placement() {
    /usr/bin/awk '
        /if coordinator\.finished == \.ok \{/ && !seen { seen = 1; depth = 1; next }
        seen && depth > 0 {
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
            depth += n - m
            if (index($0, ".sheet(") > 0) inside = 1
            if (depth <= 0) { seen = 2 }
            next
        }
        seen == 2 && index($0, ".sheet(") > 0 { outside = 1 }
        END {
            if (!seen) { print "nofind"; exit }
            if (inside)  { print "inside";  exit }
            if (outside) { print "outside"; exit }
            print "nofind"
        }
    ' "$1"
}

_report() {
    local label="$1" f="$2" ml rl d n
    ml="$(_mint_line "$f")"; rl="$(_reveal_line "$f")"; n="$(_reveal_count "$f")"
    if [ -z "$ml" ] || [ -z "$rl" ]; then printf 'NOSITE|%s|%s|%s' "$ml" "$rl" "$n"; return; fi
    d=$(( rl - ml ))
    printf '%s|%s|%s|%s' "$d" "$ml" "$rl" "$n"
}

echo "── subject: this tree ──"

_r="$(_report subject "$SUBJECT")"
_d="${_r%%|*}"; _n="${_r##*|}"
case "$_d" in
    NOSITE) echo "CANNOT-RUN: could not find the mint and the reveal in ${SUBJECT}." >&2; exit 2 ;;
esac

[ "$_n" = "1" ] \
    && ok "the reveal marker appears exactly once (${_n}), so there is one place to reason about" \
    || bad "the reveal marker appears ${_n} times. Two reveals means one of them can be the stale one."

if [ "$_d" -ge 0 ] && [ "$_d" -le "$ADJACENT_MAX" ]; then
    ok "the reveal is ${_d} lines after the mint, inside the same block (max ${ADJACENT_MAX})"
elif [ "$_d" -lt 0 ]; then
    bad "the reveal is ${_d} lines BEFORE the mint -- it renders a variable bash has not assigned yet"
else
    bad "the reveal is ${_d} lines after the mint. Anything that fails in that gap destroys the key for good, because the keychain persists and every later run takes the skip path."
fi

_rl="$(_reveal_line "$SUBJECT")"
_guarded "$SUBJECT" "$_rl" \
    && ok "CONTROL: the reveal is still behind [[ -n \$RECOVERY_KEY ]], so a run that minted nothing prints nothing" \
    || bad "the reveal is no longer guarded on emptiness -- a skip-path run would render a blank key as if it were one"

_p="$(_sheet_placement "$SWIFT")"
case "$_p" in
    outside) ok "GUI: the reveal sheet hangs off the whole view, so a FAILED install can still surface the key" ;;
    inside)  bad "GUI: the reveal sheet is inside \`finished == .ok\`. An install that minted the key and then failed holds it in an in-memory property behind a branch that never renders, and drops it on quit. That customer's next act is the re-run that seals it." ;;
    *)       echo "CANNOT-RUN: could not locate the finished==.ok branch in ${SWIFT}." >&2; exit 2 ;;
esac

# ── NEGATIVE CONTROL, pinned to the tree that SHIPPED the loss ───────────
# 18655bca is main immediately before this fix, and it is the lineage of the
# v1.0.68 artefact whose walk produced the measurement at the top of this file.
# Pinned to a fixed sha, never a branch: a control that reads origin/main
# inverts the moment this merges.
_CONTROL_SHA="18655bca"
echo "── negative control: ${_CONTROL_SHA} (the tree whose walk lost the key) ──"
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

for pair in "install.sh:${WORK}/ctl_install.sh" "gui/OstlerInstaller/Views/HintPanelView.swift:${WORK}/ctl_hint.swift"; do
    _src="${pair%%:*}"; _dst="${pair#*:}"
    if ! git -C "$REPO" show "${_CONTROL_SHA}:${_src}" > "$_dst" 2>/dev/null; then
        echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:${_src} is unreadable." >&2
        echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
        echo "  as a passing control." >&2
        exit 2
    fi
done

_c="$(_report control "${WORK}/ctl_install.sh")"
_cd="${_c%%|*}"; _cn="${_c##*|}"
case "$_cd" in
    NOSITE) echo "CANNOT-RUN: the mint or the reveal was not found in the control blob." >&2; exit 2 ;;
esac

if [ "$_cd" -gt "$ADJACENT_MAX" ]; then
    ok "control ${_CONTROL_SHA}: the reveal sat ${_cd} lines from the mint, reproducing the window that lost the key"
else
    bad "control ${_CONTROL_SHA}: the reveal was only ${_cd} lines away there too, so this harness is not measuring the defect."
fi

# CONTROL ON THE CONTROL. The pre-fix tree must still have exactly one marker,
# or its failure above could be "the marker is missing" rather than "the marker
# is in the wrong place", and the two want opposite fixes.
[ "$_cn" = "1" ] \
    && ok "CONTROL ON THE CONTROL: the pre-fix tree HAS the marker (${_cn}), so placement is the discriminator, not absence" \
    || bad "the pre-fix tree has ${_cn} markers; its red above is about presence, not placement"

_cp="$(_sheet_placement "${WORK}/ctl_hint.swift")"
case "$_cp" in
    inside)  ok "control ${_CONTROL_SHA}: the GUI sheet WAS gated on finished==.ok, reproducing the second half of the loss" ;;
    outside) bad "control ${_CONTROL_SHA}: the sheet was already ungated there, so the Swift arm proves nothing." ;;
    *)       echo "CANNOT-RUN: could not locate the finished==.ok branch in the control blob." >&2; exit 2 ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
