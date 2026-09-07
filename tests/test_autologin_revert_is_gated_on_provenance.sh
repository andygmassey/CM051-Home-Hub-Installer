#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_autologin_revert_is_gated_on_provenance.sh
#
# Uninstalling Ostler must turn automatic login back off and delete
# /etc/kcpassword WHEN OSTLER TURNED IT ON, and must touch neither when the
# customer had already enabled it themselves.
#
# WHY THIS IS NOT SIMPLY "REVERT IT"
# ---------------------------------------------------------------------------
# install.sh enables macOS automatic login so the hub reaches a logged-in
# session after a power cut: every Ostler runtime is a per-user LaunchAgent
# and those only load inside an active GUI session, so without it the hub
# stays dark after a reboot. Enabling it makes macOS write the customer's
# LOGIN PASSWORD to /etc/kcpassword, scrambled with the fixed 11-byte
# loginwindow cipher -- obfuscation, not encryption.
#
# Leaving both behind on an uninstalled machine is the worst outcome: the
# customer believes Ostler is gone and their password is still recoverable
# on disk. But install.sh:11952 RETURNS EARLY when auto-login is already on
# for this user, so the installer never learns whose setting it is looking
# at. Reverting unconditionally would switch off an auto-login the customer
# configured and delete a kcpassword that was never ours.
#
# So the install writes a provenance marker at the only moment anyone can
# know the answer -- the branch where it actually enables it -- and the
# uninstall acts only on that.
#
# ARM 6 IS THE ONE THAT MATTERS. A revert that fires with NO marker is
# exactly the defect this design exists to avoid, and it would pass every
# other arm here. If arm 6 goes red, the gate is wrong and not this test.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/autolog.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# The generated uninstaller, extracted the way the other uninstall tests do.
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-uninstall" <<.UNINSTALLEOF.$/{f=1;next} /^UNINSTALLEOF$/{f=0} f' \
    "$INSTALL_SH" > "${WORK}/uninstaller"
[[ -s "${WORK}/uninstaller" ]] || { echo "CANNOT-RUN: could not extract the uninstaller heredoc (exit 2)" >&2; exit 2; }

echo "axis A: the marker is written where it is knowable, read where it is used"

# 1. the install side records it
if grep -q 'autoLoginEnabledByOstler -bool true' "$INSTALL_SH"; then
    ok "1 install.sh writes the provenance marker"
else
    bad "1 install.sh never writes the marker"
fi

# 2. and it is NOT written by the uninstaller (that would be self-certifying)
if grep -q 'autoLoginEnabledByOstler -bool true' "${WORK}/uninstaller"; then
    bad "2 the UNINSTALLER writes the marker it then reads -- self-certifying"
else
    ok "2 the marker is written only by the installer"
fi

# 3. the uninstaller reads it
if grep -q 'autoLoginEnabledByOstler' "${WORK}/uninstaller"; then
    ok "3 the uninstaller reads the marker"
else
    bad "3 the uninstaller never reads the marker"
fi

# 4. THE REVERT IS GATED. Both destructive calls must sit inside a branch,
#    never at the top level of the teardown. Checked by indentation, because
#    an unconditional revert is the regression this whole file guards.
_kc_line="$(grep -n 'rm -f /etc/kcpassword' "${WORK}/uninstaller" | head -1 | cut -d: -f2-)"
_al_line="$(grep -n 'defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser' "${WORK}/uninstaller" | head -1 | cut -d: -f2-)"
if [[ "$_kc_line" =~ ^[[:space:]]+ ]] && [[ "$_al_line" =~ ^[[:space:]]+ ]]; then
    ok "4 both reverts are indented, i.e. inside a conditional branch"
else
    bad "4 a revert sits at the top level -- it would fire unconditionally"
fi

echo "axis B: it reverts when the marker says ours, and NOT when it does not"

# The revert block, driven with a stubbed sudo so nothing real is touched.
sed -n '/Automatic login: revert ONLY what we can prove we did/,/com.creativemachines.ostler.plist/p' \
    "${WORK}/uninstaller" > "${WORK}/block"
[[ -s "${WORK}/block" ]] || { echo "CANNOT-RUN: could not slice the revert block (exit 2)" >&2; exit 2; }

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/sudo" <<'SUDO'
#!/bin/bash
# Record every privileged call, execute none of them.
printf '%s\n' "$*" >> "${CALLS}"
case "$*" in
    *"defaults read"*autoLoginEnabledByOstler*)
        if [ "${MARKER:-absent}" = "present" ]; then echo 1; exit 0; fi
        exit 1 ;;   # `defaults read` on a missing key exits non-zero
esac
exit 0
SUDO
chmod +x "${WORK}/bin/sudo"

run_block() { # $1 = present|absent  -> echoes the call log
    CALLS="${WORK}/calls.$1"; : > "$CALLS"
    MARKER="$1" CALLS="$CALLS" PATH="${WORK}/bin:$PATH" \
        /bin/bash "${WORK}/block" >/dev/null 2>&1
    cat "$CALLS"
}

_present="$(run_block present)"
_absent="$(run_block absent)"

# 8. CONTROL first: the harness must actually be capturing calls, or every
#    "did not fire" below is vacuously true.
if [[ -n "$_present" ]]; then
    ok "5 CONTROL: the stub captured $(grep -c . <<< "$_present") privileged call(s)"
else
    bad "5 CONTROL: the stub captured NOTHING -- arms 6-8 would be vacuous"
fi

# 6. marker present -> both reverts happen
if grep -q 'rm -f /etc/kcpassword' <<< "$_present" \
   && grep -q 'defaults delete .*autoLoginUser' <<< "$_present"; then
    ok "6 marker present -> auto-login disabled AND kcpassword removed"
else
    bad "6 marker present -> the revert did not happen"
fi

# 7. THE CONTROL THAT MUST NOT FIRE. No marker means the setting was never
#    ours, and a teardown that guesses about a customer's login security is
#    a worse defect than the one it is fixing.
_kc_absent=0; grep -q 'rm -f /etc/kcpassword' <<< "$_absent" && _kc_absent=1
_al_absent=0; grep -q 'defaults delete .*autoLoginUser' <<< "$_absent" && _al_absent=1
if [[ "$_kc_absent" -eq 1 || "$_al_absent" -eq 1 ]]; then
    bad "7 NO marker and it reverted anyway -- it guessed at provenance"
else
    ok "7 no marker -> auto-login and kcpassword both left alone"
fi

# 8. the marker plist is ours, so it goes in both cases
if grep -q 'com.creativemachines.ostler.plist' <<< "$_present" \
   && grep -q 'com.creativemachines.ostler.plist' <<< "$_absent"; then
    ok "8 the marker plist is removed either way"
else
    bad "8 the marker plist survives the uninstall"
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
