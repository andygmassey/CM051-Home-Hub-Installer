#!/usr/bin/env bash
#
# test_export_scan_plist_bootstrap_race_217.sh
#
# Regression gate for HR015 #217. The com.ostler.export-scan LaunchAgent's
# ProgramArguments[0] is ${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant
# and its RunAtLoad key is true. On a fresh install this plist is written
# and bootstrapped in install.sh several thousand lines BEFORE the signed
# daemon .app is staged (staging happens inside _finalise_daemon_staging),
# so a bare launchctl bootstrap at plist-write time makes launchd fire the
# tick against a not-yet-existent binary and record last-exit-code = 78
# (EX_CONFIG) with zero-byte stdout/stderr log files. This is exactly the
# fault the box reproduced.
#
# The fix has two structural properties this test asserts:
#
#   (A) The initial launchctl bootstrap for SCAN_PLIST is gated on the
#       daemon binary being on-disk (guards the fresh-install race).
#
#   (B) _finalise_daemon_staging calls _ostler_ensure_export_scan_bootstrap
#       on its success path (picks up the fresh-install case where the
#       initial bootstrap was skipped, and re-kicks any stale
#       EX_CONFIG(78) job that predates the fix).
#
# Runnable standalone:  bash tests/test_export_scan_plist_bootstrap_race_217.sh
# Exits non-zero on any missing structural property.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing at $INSTALL_SH"
    echo "test_export_scan_plist_bootstrap_race_217: FAILED" >&2
    exit 1
fi

# --- Sanity: locate the SCAN_PLIST block and the initial-bootstrap line ---

SCAN_PLIST_LINE=$(grep -n '^SCAN_PLIST="' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [[ -z "$SCAN_PLIST_LINE" ]]; then
    failure "could not locate SCAN_PLIST= assignment in install.sh (block moved or removed?)"
fi

# The initial bootstrap of SCAN_PLIST -- the one that historically fired
# before the app bundle was staged. Should exist and should sit inside a
# binary-on-disk guard (see property A).
SCAN_BOOTSTRAP_LINE=$(awk '/launchctl bootstrap "gui\/\$\(id -u\)" "\$SCAN_PLIST"/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$SCAN_BOOTSTRAP_LINE" ]]; then
    failure "could not find launchctl bootstrap of \$SCAN_PLIST in install.sh"
fi

# --- Property A: initial SCAN_PLIST bootstrap is gated on the daemon binary ---
#
# We look at the ~12 lines immediately preceding the bootstrap line for an
# [[ -x ...OstlerAssistant.app/Contents/MacOS/ostler-assistant ]] guard
# (either the literal path or a variable expansion of it). Anything less
# specific (e.g. a generic ASSISTANT_BINARY_INSTALLED check that only lands
# later) would let the race back in on a fresh install.

if [[ -n "$SCAN_BOOTSTRAP_LINE" ]]; then
    start=$(( SCAN_BOOTSTRAP_LINE - 12 ))
    (( start < 1 )) && start=1
    window="$(awk -v s="$start" -v e="$SCAN_BOOTSTRAP_LINE" 'NR>=s && NR<=e' "$INSTALL_SH")"
    if grep -Eq '\[\[ +-x +"[^"]*OstlerAssistant\.app/Contents/MacOS/ostler-assistant" +\]\]' <<<"$window"; then
        pass "initial SCAN_PLIST bootstrap is gated on the daemon binary existing on-disk"
    else
        failure "initial SCAN_PLIST bootstrap at line $SCAN_BOOTSTRAP_LINE is not preceded by an [[ -x .../OstlerAssistant.app/Contents/MacOS/ostler-assistant ]] guard -- HR015 #217 race regressed"
    fi
fi

# --- Property B: the deferred-bootstrap helper is defined and wired in ---
#
# The fix introduces _ostler_ensure_export_scan_bootstrap and calls it on
# the success path of _finalise_daemon_staging (right after the daemon
# .app has been signed-and-notarised-verified and ASSISTANT_BINARY_INSTALLED
# is set to true). If either the definition or the call goes missing, the
# fresh-install case never bootstraps the plist and export-scan silently
# never runs.

HELPER_DEF_LINE=$(awk '/^_ostler_ensure_export_scan_bootstrap\(\) \{/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$HELPER_DEF_LINE" ]]; then
    failure "_ostler_ensure_export_scan_bootstrap() is not defined in install.sh (HR015 #217 fix removed?)"
else
    pass "_ostler_ensure_export_scan_bootstrap() defined at line $HELPER_DEF_LINE"
fi

# The call must appear inside the _finalise_daemon_staging function body,
# after ASSISTANT_BINARY_INSTALLED=true is set (i.e. on the success path).
FINALISE_START=$(awk '/^_finalise_daemon_staging\(\) \{/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$FINALISE_START" ]]; then
    failure "_finalise_daemon_staging() is not defined (upstream install.sh moved?)"
fi

if [[ -n "$FINALISE_START" ]]; then
    # Find the matching closing brace at column 0 (function-body end).
    FINALISE_END=$(awk -v s="$FINALISE_START" 'NR>s && /^\}/{print NR; exit}' "$INSTALL_SH")
    if [[ -z "$FINALISE_END" ]]; then
        failure "could not locate the closing '}' of _finalise_daemon_staging()"
    else
        BINARY_INSTALLED_LINE=$(awk -v s="$FINALISE_START" -v e="$FINALISE_END" 'NR>=s && NR<=e && /ASSISTANT_BINARY_INSTALLED=true/{print NR; exit}' "$INSTALL_SH")
        HELPER_CALL_LINE=$(awk -v s="$FINALISE_START" -v e="$FINALISE_END" 'NR>=s && NR<=e && /^[[:space:]]+_ostler_ensure_export_scan_bootstrap[[:space:]]*$/{print NR; exit}' "$INSTALL_SH")

        if [[ -z "$HELPER_CALL_LINE" ]]; then
            failure "_ostler_ensure_export_scan_bootstrap is not called from inside _finalise_daemon_staging() -- the deferred bootstrap will never fire, HR015 #217 stays broken"
        elif [[ -n "$BINARY_INSTALLED_LINE" && "$HELPER_CALL_LINE" -lt "$BINARY_INSTALLED_LINE" ]]; then
            failure "_ostler_ensure_export_scan_bootstrap is called at line $HELPER_CALL_LINE, BEFORE ASSISTANT_BINARY_INSTALLED=true at line $BINARY_INSTALLED_LINE -- must run on the success path only"
        else
            pass "_ostler_ensure_export_scan_bootstrap is called on the success path of _finalise_daemon_staging (line $HELPER_CALL_LINE)"
        fi
    fi
fi

# --- Property C: the helper itself does what its contract says ---
#
# Reject a helper body that lacks the binary-existence guard, or a plist-
# file-exists guard, or a bootstrap fallback path. All three are load-
# bearing: without the plist-exists guard we'd noisily fail on a config
# where export-scan was toggled off; without the binary guard we'd recur
# into the same race on a re-run install where the daemon was rejected;
# without the bootstrap fallback we'd only kickstart already-loaded jobs
# and never bootstrap the fresh case.

if [[ -n "${HELPER_DEF_LINE:-}" ]]; then
    HELPER_END=$(awk -v s="$HELPER_DEF_LINE" 'NR>s && /^\}/{print NR; exit}' "$INSTALL_SH")
    if [[ -n "$HELPER_END" ]]; then
        body="$(awk -v s="$HELPER_DEF_LINE" -v e="$HELPER_END" 'NR>=s && NR<=e' "$INSTALL_SH")"
        grep -q 'com.ostler.export-scan.plist' <<<"$body" || \
            failure "helper body does not reference com.ostler.export-scan.plist -- wrong plist targeted?"
        grep -Eq '\[\[ +-f +"[^"]*com\.ostler\.export-scan\.plist"[^]]*\]\]' <<<"$body" || \
            grep -Eq '\[\[ +-f +"\$_plist" +\]\]' <<<"$body" || \
            failure "helper body does not guard on the plist file existing (would fail loudly when export-scan block was skipped)"
        grep -Eq '\[\[ +-x +"[^"]*OstlerAssistant\.app/Contents/MacOS/ostler-assistant"[^]]*\]\]' <<<"$body" || \
            grep -Eq '\[\[ +-x +"\$_bin" +\]\]' <<<"$body" || \
            failure "helper body does not guard on the daemon binary existing (race can regress if call-site moves)"
        grep -q 'launchctl bootstrap' <<<"$body" || \
            failure "helper body lacks a launchctl bootstrap call -- the fresh-install case never bootstraps"
        # The kickstart may be issued DIRECTLY, or routed through _ks_bounded,
        # which is the shared bounded wrapper. Accept either -- but only after
        # proving the wrapper really does issue a -k kickstart, so this is not
        # a rename that quietly drops the call.
        #
        # WHY THIS ARM WIDENED (2026-08-26). It grepped the helper body for the
        # literal string `launchctl kickstart`. install.sh now routes five call
        # sites through _ks_bounded because BOTH `kickstart` and `kickstart -k`
        # BLOCK on a penalty-boxed job -- measured on real hardware, controls
        # returned in 7s/21s while both subjects were killed at 90s. That fix
        # left the -k behaviour intact and only moved where the call is written,
        # so this arm was failing on the SHAPE while the PROPERTY still held.
        #
        # A test anchored to a call site's spelling rather than its guarantee
        # goes red on a correct refactor and green on a wrong one. So: check the
        # guarantee, and follow the indirection rather than trusting the name.
        if grep -q 'launchctl kickstart' <<<"$body"; then
            :   # issued directly in the helper -- original shape, still fine
        elif grep -Eq '_ks_bounded[^#]*-k' <<<"$body"; then
            # Routed. Now PROVE the wrapper issues -k; a wrapper that dropped
            # the flag would satisfy the grep above and silently reintroduce
            # exactly the stale-EX_CONFIG(78) bug this file exists to catch.
            _ksb_start=$(grep -n '^_ks_bounded() {' "$INSTALL_SH" | head -1 | cut -d: -f1)
            if [[ -z "$_ksb_start" ]]; then
                failure "helper routes through _ks_bounded but _ks_bounded is not defined in install.sh"
            else
                _ksb_body="$(awk -v s="$_ksb_start" -v e="$((_ksb_start + 22))" 'NR>=s && NR<=e' "$INSTALL_SH")"
                grep -q 'launchctl kickstart' <<<"$_ksb_body" || \
                    failure "_ks_bounded does not issue a launchctl kickstart at all -- the routed call is a no-op"
                # 🔴 THE FLAG MUST APPEAR ON THE KICKSTART LINE, NOT MERELY IN
                # 🔴 THE FUNCTION. Mutation-proved: `grep -q '_ksb_flag'` over
                # the whole body SURVIVED the flag being dropped from the
                # kickstart invocation, because _ksb_flag still occurs in the
                # `if [ -n "$_ksb_flag" ]` branch test above it. Presence is
                # not use. A wrapper can test a flag and then not pass it.
                grep -Eq 'launchctl kickstart[[:space:]]+"\$_ksb_flag"' <<<"$_ksb_body" || \
                    failure "_ks_bounded tests its flag but never passes it to launchctl, so the -k from the helper never reaches launchd -- a stale EX_CONFIG(78) on an already-loaded job never clears"
            fi
        else
            failure "helper body lacks a launchctl kickstart -k call (direct or via _ks_bounded) -- a stale EX_CONFIG(78) result on an already-loaded job never clears"
        fi
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_export_scan_plist_bootstrap_race_217: FAILED" >&2
    exit 1
fi
echo "test_export_scan_plist_bootstrap_race_217: PASSED"
exit 0
