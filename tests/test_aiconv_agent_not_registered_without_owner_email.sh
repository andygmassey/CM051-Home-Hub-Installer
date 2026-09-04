#!/usr/bin/env bash
# An AI-conversations agent must NEVER be registered with an empty
# CM052_USER_EMAIL.
#
# WHY THIS EXISTS. MEASURED on the Mini 16 during the v1.0.63 walk,
# 2026-09-04. USER_EMAIL comes from exactly one place: DETECTED_EMAIL, read
# from the macOS me-card via osascript. On a Mac where Contacts.app has never
# been launched that call returns "Application isn't running. (-600)", so
# USER_EMAIL was empty and install.sh wrote:
#
#     <key>CM052_USER_EMAIL</key>
#     <string></string>
#
# cm052.cli then refused every hour, forever ("CM052_USER_EMAIL is not set"),
# ai_conversations read `not_run` permanently, and the same rc=2 folded into
# health_check and reddened the step. One empty string, two symptoms, and
# neither of them named the cause.
#
# A COLD MAC IS THE NORMAL CUSTOMER MAC -- a wiped machine restoring from
# iCloud or Time Machine has no warm GUI apps, which is exactly when the
# installer runs. So this is the default path, not an edge case.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. A check that could not run has
# not passed.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

# ── The predicate, applied to any tree ────────────────────────────────────
# Returns 0 when the tree GUARDS the plist write, 1 when it does not.
# Operates on the region between the plist path assignment and the heredoc
# terminator, so an unrelated USER_EMAIL test elsewhere cannot satisfy it.
# Accepts EITHER form of the guard: the condition written inline, or the
# shared `_aiconv_owner_email_known` predicate that later replaced it once a
# second consumer (the install-time drain) needed the same answer. This test
# asserts the PROPERTY -- the plist write is guarded on a known owner address
# -- not one spelling of it. A syntactic predicate fails the moment the code
# it guards is refactored correctly, which is a test reporting on itself.
#
# Both branches of the alternation are exercised by the controls below: the
# subject matches via the helper, deecd9fc via the inline condition. An
# alternation with a dead branch is a pattern nobody has proved.
_guards_owner_email() {
    local file="$1" region
    region="$(awk '/_AICONV_RESUME_PLIST=/{f=1} f{print} /^AICONVPLIST$/{if(f)exit}' "$file")"
    [ -n "$region" ] || return 2
    printf '%s' "$region" \
        | grep -qE '^[[:space:]]*if (\[\[ -z "\$\{USER_EMAIL:-\}" \]\]|! _aiconv_owner_email_known); then'
}

echo "── subject: this tree ──"
_guards_owner_email "$SUBJECT"; _rc=$?
case "$_rc" in
    0) ok "the aiconv plist write is guarded on a non-empty USER_EMAIL" ;;
    1) bad "the aiconv plist is written with NO guard on USER_EMAIL -- an empty required var can reach a shipped plist" ;;
    2) echo "CANNOT-RUN: could not locate the aiconv plist region in ${SUBJECT}" >&2; exit 2 ;;
esac

# The declared reason must be recorded, or the customer gets `not_run` with
# no explanation -- which is the state this fix exists to replace.
if awk '/_AICONV_RESUME_PLIST=/{f=1} f{print} /^AICONVPLIST$/{if(f)exit}' "$SUBJECT" \
   | grep -qF 'owner_email_unknown_agent_not_registered'; then
    ok "a DECLARED reason is recorded, so the source says why rather than only that it did not run"
else
    bad "no declared reason recorded -- ai_conversations would read not_run with no cause"
fi

# ── NEGATIVE CONTROL, pinned to a tree that CARRIES the defect ────────────
# Pinned to a fixed sha, never a moving branch: a control that reads
# origin/main inverts the moment this very fix merges, and then silently
# passes forever. 45126e9a is the v1.0.63 cut commit -- the blob that shipped
# to the Mini 16 and produced the measured failure.
_CONTROL_SHA="45126e9a"
echo "── negative control: ${_CONTROL_SHA} (the tree that shipped the defect) ──"
_ctl="$(mktemp)"; trap 'rm -f "$_ctl"' EXIT
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it; fetch it before scanning. Scanning" >&2
    echo "  nothing must not read as a passing control." >&2
    exit 2
fi
_guards_owner_email "$_ctl"; _crc=$?
case "$_crc" in
    1) ok "control: ${_CONTROL_SHA} is correctly detected as UNGUARDED (the predicate can fail)" ;;
    0) bad "control: ${_CONTROL_SHA} reports GUARDED. It is not -- that tree shipped the empty var to the Mini 16. The predicate matches something other than the fix." ;;
    2) echo "CANNOT-RUN: the aiconv region was not found in the control blob." >&2; exit 2 ;;
esac

# ── POSITIVE CONTROL: the inline branch of the predicate must still match ──
# The predicate above accepts two spellings of the same guard. The subject
# exercises the helper spelling; nothing else in this file would ever
# exercise the inline one, and an alternation branch that is never matched is
# a branch nobody has proved works. deecd9fc carries the guard written
# inline, so it must read as GUARDED.
_PCONTROL_SHA="deecd9fc"
echo "── positive control: ${_PCONTROL_SHA} (guard present, written inline) ──"
_pctl="$(mktemp)"
if ! git -C "$REPO" cat-file -e "${_PCONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_PCONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_PCONTROL_SHA}:install.sh" > "$_pctl" 2>/dev/null; then
    rm -f "$_pctl"
    echo "CANNOT-RUN: positive-control blob ${_PCONTROL_SHA}:install.sh is unreadable." >&2
    exit 2
fi
_guards_owner_email "$_pctl"; _prc=$?
rm -f "$_pctl"
case "$_prc" in
    0) ok "positive control: ${_PCONTROL_SHA} reads as GUARDED, so the inline branch of the predicate is live" ;;
    1) bad "positive control: ${_PCONTROL_SHA} reads as UNGUARDED. That tree DOES guard the plist -- the inline branch of the predicate no longer matches anything." ;;
    2) echo "CANNOT-RUN: the aiconv region was not found in the positive-control blob." >&2; exit 2 ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
