#!/usr/bin/env bash
# A recovery key must never be left undisclosed across runs.
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
# #1540 fixed this by moving the reveal to sit right next to the mint (this
# file used to assert ADJACENCY between the two: the disclosure reachable
# from the mint without 15,490 lines of install crossing between them).
#
# #1540b (THIS UPDATE) moves the reveal back to the end of the install, next
# to the Keychain-save decision it belongs beside -- the owner's explicit,
# non-negotiable instruction. Re-imposing 15,000+ lines of "anything here can
# eat the key" between mint and reveal makes the OLD adjacency assertion
# false BY DESIGN, but the property it protected is not retired, it is
# stronger: a mint that a failing run never got to disclose must not be
# silently forgotten by the run after it. Two things now do that job instead
# of adjacency:
#
#   1. A persisted delivery marker (RECOVERY_DELIVERY_MARKER), written ONLY
#      at the moment the reveal actually renders, so a later run reads a
#      FACT rather than inferring one from keychain.json's mere presence.
#   2. A re-run check that treats "keychain.json exists, no marker" as the
#      dangerous state and DISCLOSES it -- loudly, every time -- instead of
#      taking the old silent `:` skip.
#
# WHAT THIS TEST ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
# It asserts that the reveal, the delivery flag, and the persisted marker are
# one inseparable unit (so nothing can record delivery without having shown
# the key, or show the key without recording it) and that the re-run check
# actually discloses the dangerous state rather than skipping it -- by
# LIFTING that check out of install.sh and EXECUTING it under each state,
# the same technique
# test_the_summary_never_claims_a_recovery_path_that_was_not_handed_over.sh
# uses, for the same reason: a source grep for the warning text would pass
# while the call sat behind a condition that never fires. It does NOT assert
# that a disclosure happened on any particular run -- that is a transcript
# property and belongs to the box-walk probe, not here.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
SWIFT="${REPO}/gui/OstlerInstaller/Views/HintPanelView.swift"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no install.sh.strings.en-GB.sh at ${STRINGS}" >&2; exit 2; }
[ -f "$SWIFT" ]   || { echo "CANNOT-RUN: no HintPanelView.swift at ${SWIFT}" >&2; exit 2; }

# How far apart the reveal and its OWN bookkeeping (the delivered flag, then
# the persisted marker write) may sit. The point is "nothing that can fail
# runs between showing the key and recording that it was shown"; line
# distance is the cheap proxy for it, same idea the old adjacency check used,
# now pointed at the pairing this design actually depends on.
ADJACENT_MAX=40

# ── Readers. Each prints a line number, or nothing. ──────────────────────
_reveal_line()   { /usr/bin/grep -nF 'gui_emit RECOVERY_KEY' "$1" | head -1 | cut -d: -f1; }
_reveal_count()  { /usr/bin/grep -cF 'gui_emit RECOVERY_KEY' "$1"; }
_delivered_line(){ /usr/bin/grep -nF 'RECOVERY_KEY_DELIVERED=true' "$1" | head -1 | cut -d: -f1; }
_marker_line()   { /usr/bin/grep -nF 'RECOVERY_DELIVERY_MARKER' "$1" | /usr/bin/grep -F 'OSTLER_PYTHON' | head -1 | cut -d: -f1; }

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
    # 🔴 THIS COUNTED BRACES IN COMMENTS AND STRING LITERALS, AND TNM BROKE IT.
    #
    # The first version ran gsub over the RAW line. One stray `}` inside a
    # comment closed the branch early, everything after it read as `outside`,
    # and a mutant that put `.sheet(` GENUINELY back inside `finished == .ok`
    # scored 7 pass / 0 fail while printing the sentence claiming the opposite.
    # The Swift half of #1540 could have been reintroduced by anyone and this
    # arm would have applauded.
    #
    # Blank the string literals FIRST, then strip `//` comments, then count.
    # That order matters: stripping comments first mangles a `//` inside a
    # string. Escaped quotes go before either, or `\"` splits a literal in two.
    /usr/bin/awk '
        {
            line = $0
            gsub(/\\"/, "", line)
            gsub(/"[^"]*"/, "\"\"", line)
            sub(/\/\/.*/, "", line)
        }
        line ~ /if coordinator\.finished == \.ok \{/ && !seen { seen = 1; depth = 1; next }
        seen && depth > 0 {
            n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
            depth += n - m
            if (index(line, ".sheet(") > 0) inside = 1
            if (depth <= 0) { seen = 2 }
            next
        }
        seen == 2 && index(line, ".sheet(") > 0 { outside = 1 }
        END {
            if (!seen) { print "nofind"; exit }
            if (inside)  { print "inside";  exit }
            if (outside) { print "outside"; exit }
            print "nofind"
        }
    ' "$1"
}

# ── Lift the whole Phase 3.6 mint/re-run-check construct: from the mint's
# opening `if` to its OWN matching `fi`, tracked by depth so the inner
# `if [[ "$ALLOW_PLAINTEXT" == "1" ]] ... fi` does not fool a naive
# first-`^fi$` stop (that inner fi closes 30-odd lines before the real one).
_lift_reruncheck() {
    /usr/bin/awk '
        !f && /^if \[\[ "\$PASSKEY_PRIMED" == true && "\$HAS_SECURITY_MODULE" == true \]\]; then$/ { f = 1 }
        f {
            print
            if ($0 ~ /^[[:space:]]*if .*then$/) depth++
            if ($0 ~ /^[[:space:]]*fi$/) { depth--; if (depth == 0) exit }
        }
    ' "$1"
}

echo "── subject: this tree ──"

_rl="$(_reveal_line "$SUBJECT")"
_dl="$(_delivered_line "$SUBJECT")"
_ml="$(_marker_line "$SUBJECT")"
_n="$(_reveal_count "$SUBJECT")"

# Absence of the reveal or the delivered flag is a CANNOT-RUN precondition
# (both existed long before this fix; if neither is findable the file has
# moved or been renamed out from under this test). Absence of the marker
# write is a real FAIL, not a CANNOT-RUN: that mechanism is exactly what
# this fix adds, so a tree without it must fail this check, and DOES --
# that is the mutation-tested evidence this file was written against the
# pre-fix tree for.
if [ -z "$_rl" ] || [ -z "$_dl" ]; then
    echo "CANNOT-RUN: could not find the reveal (${_rl:-none}) or the delivered flag (${_dl:-none}) in ${SUBJECT}." >&2
    exit 2
fi

[ "$_n" = "1" ] \
    && ok "the reveal marker appears exactly once (${_n}), so there is one place to reason about" \
    || bad "the reveal marker appears ${_n} times. Two reveals means one of them can be the stale one."

if [ "$_dl" -ge "$_rl" ] && [ $(( _dl - _rl )) -le "$ADJACENT_MAX" ]; then
    ok "RECOVERY_KEY_DELIVERED is set $(( _dl - _rl )) lines after the reveal, inside the same block (max ${ADJACENT_MAX})"
else
    bad "RECOVERY_KEY_DELIVERED (line ${_dl}) is not immediately after the reveal (line ${_rl}). It must be set only once the key has actually been shown, and nothing that can fail may run in between."
fi

if [ -z "$_ml" ]; then
    bad "no persisted-delivery marker write found near RECOVERY_KEY_DELIVERED. Without it, delivery is a fact known only to this process, not to the next run -- which is the whole defect this file exists to catch."
elif [ "$_ml" -ge "$_dl" ] && [ $(( _ml - _dl )) -le "$ADJACENT_MAX" ]; then
    ok "the persisted-delivery marker write is $(( _ml - _dl )) lines after RECOVERY_KEY_DELIVERED, inside the same block (max ${ADJACENT_MAX})"
else
    bad "the marker write (line ${_ml}) is too far from RECOVERY_KEY_DELIVERED (line ${_dl}). A gap there is exactly the class of bug this file exists to catch: the in-memory flag can be true while the on-disk fact never gets written."
fi

_guarded "$SUBJECT" "$_rl" \
    && ok "CONTROL: the reveal is still behind [[ -n \$RECOVERY_KEY ]], so a run that minted nothing prints nothing" \
    || bad "the reveal is no longer guarded on emptiness -- a skip-path run would render a blank key as if it were one"

_p="$(_sheet_placement "$SWIFT")"
case "$_p" in
    outside) ok "GUI: the reveal sheet hangs off the whole view, so a FAILED install can still surface the key" ;;
    inside)  bad "GUI: the reveal sheet is inside \`finished == .ok\`. An install that minted the key and then failed holds it in an in-memory property behind a branch that never renders, and drops it on quit. That customer's next act is the re-run that seals it." ;;
    *)       echo "CANNOT-RUN: could not locate the finished==.ok branch in ${SWIFT}." >&2; exit 2 ;;
esac

echo "── subject: the re-run check (lifted and executed) ──"

LIFTED="$(mktemp -t reruncheck.XXXXXX)"
trap 'rm -f "$LIFTED"' EXIT
_lift_reruncheck "$SUBJECT" > "$LIFTED"
if [ ! -s "$LIFTED" ]; then
    echo "CANNOT-RUN: could not lift the re-run check from ${SUBJECT}." >&2
    exit 2
fi
bash -n "$LIFTED" 2>/dev/null || { echo "CANNOT-RUN: the lifted re-run check is not valid bash on its own; the extraction is wrong." >&2; exit 2; }

# Stubs for everything the lifted block calls. PASSKEY_PRIMED/HAS_SECURITY_MODULE
# are forced false in every arm below, so the mint branch (which needs a real
# $OSTLER_PYTHON and a live setup_passphrase()) is never entered -- only the
# elif re-run-detection chain this test cares about runs.
_run_reruncheck() {   # $1=passkey(0|1) $2=keychain(0|1) $3=marker(0|1) -> OUT
    local pk="$1" kc="$2" mk="$3" dir
    dir="$(mktemp -d)"
    [[ "$pk" == "1" ]] && : > "$dir/passkey.json"
    [[ "$kc" == "1" ]] && : > "$dir/keychain.json"
    [[ "$mk" == "1" ]] && : > "$dir/recovery_key_delivered.json"
    OUT="$(
        PASSKEY_PRIMED=false HAS_SECURITY_MODULE=false ALLOW_PLAINTEXT=0 \
        SECURITY_CONFIG_DIR="$dir" \
        RECOVERY_DELIVERY_MARKER="$dir/recovery_key_delivered.json" \
        RED="" BOLD="" NC="" YELLOW="" \
        bash -c "
            source '$STRINGS'
            warn() { echo \"[warn] \$*\"; }
            ok() { :; }
            gui_emit() { :; }
            fail_with_code() { echo \"FAIL_WITH_CODE:\$1:\$2\"; exit 9; }
            source '$LIFTED'
        " 2>&1
    )"
    rm -rf "$dir"
}

# ── arm A: passkey-primary config -- never went through this mint/disclose
# path, so there is nothing to check delivery of. Must stay silent. ────────
_run_reruncheck 1 0 0
if [[ -z "${OUT//[[:space:]]/}" ]]; then
    ok "passkey.json present: the re-run check stays silent"
else
    bad "passkey.json present should print nothing. Got: $OUT"
fi

# ── arm B: keychain.json present, delivery marker present -- the legitimate
# skip. Must stay silent. ───────────────────────────────────────────────────
_run_reruncheck 0 1 1
if [[ -z "${OUT//[[:space:]]/}" ]]; then
    ok "keychain.json + delivery marker present: the legitimate skip is silent"
else
    bad "a delivered recovery key should not re-trigger any warning. Got: $OUT"
fi

# ── arm C: #1540b THE DANGEROUS STATE. keychain.json present, NO delivery
# marker -- nobody can prove the customer has ever seen a key. Must be LOUD,
# not the old silent `:` skip. ──────────────────────────────────────────────
_run_reruncheck 0 1 0
if grep -qi 'never shown to you' <<<"$OUT" && ! [[ -z "${OUT//[[:space:]]/}" ]]; then
    ok "keychain.json present, NO delivery marker: the re-run check discloses the gap instead of skipping silently"
else
    bad "keychain.json with no delivery marker must warn loudly, not skip silently. Got: $OUT"
fi

# ── NEGATIVE CONTROL, pinned to the tree that shipped the loss ───────────
# c066755f0dc9ce9be5d40e24cc4c58897d826573 is main immediately before this
# fix. Pinned to a full sha, never a branch: a control that reads
# origin/main inverts the moment this merges.
_CONTROL_SHA="c066755f0dc9ce9be5d40e24cc4c58897d826573"
echo "── negative control: ${_CONTROL_SHA} (the tree that skips silently) ──"
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }

_ctl_install="${WORK}/ctl_install.sh"
_ctl_strings="${WORK}/ctl_strings.sh"
for pair in "install.sh:${_ctl_install}" "install.sh.strings.en-GB.sh:${_ctl_strings}"; do
    _src="${pair%%:*}"; _dst="${pair#*:}"
    if ! git -C "$REPO" show "${_CONTROL_SHA}:${_src}" > "$_dst" 2>/dev/null; then
        echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:${_src} is unreadable." >&2
        echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
        echo "  as a passing control." >&2
        rm -rf "$WORK"
        exit 2
    fi
done

if grep -qF 'RECOVERY_DELIVERY_MARKER' "$_ctl_install"; then
    echo "CANNOT-RUN: the 'pre-fix' blob already carries this change, so it cannot discriminate." >&2
    rm -rf "$WORK"
    exit 2
fi

CTL_LIFTED="${WORK}/ctl_lifted.sh"
_lift_reruncheck "$_ctl_install" > "$CTL_LIFTED"
if [ ! -s "$CTL_LIFTED" ]; then
    echo "CANNOT-RUN: could not lift the re-run check from the control blob." >&2
    rm -rf "$WORK"
    exit 2
fi
bash -n "$CTL_LIFTED" 2>/dev/null || { echo "CANNOT-RUN: the control lift is not valid bash on its own." >&2; rm -rf "$WORK"; exit 2; }

_ctl_dir="$(mktemp -d)"
: > "$_ctl_dir/keychain.json"
CTL_OUT="$(
    PASSKEY_PRIMED=false HAS_SECURITY_MODULE=false ALLOW_PLAINTEXT=0 \
    SECURITY_CONFIG_DIR="$_ctl_dir" \
    RED="" BOLD="" NC="" YELLOW="" \
    bash -c "
        source '$_ctl_strings'
        warn() { echo \"[warn] \$*\"; }
        ok() { :; }
        gui_emit() { :; }
        fail_with_code() { echo \"FAIL_WITH_CODE:\$1:\$2\"; exit 9; }
        source '$CTL_LIFTED'
    " 2>&1
)"
rm -rf "$_ctl_dir"

if [[ -z "${CTL_OUT//[[:space:]]/}" ]]; then
    ok "CONTROL ${_CONTROL_SHA}: keychain.json with no delivery record was SILENT there too, reproducing the exact defect"
else
    bad "control ${_CONTROL_SHA} was not silent for the dangerous state, so this harness is not measuring the defect. Got: $CTL_OUT"
fi

rm -rf "$WORK"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
