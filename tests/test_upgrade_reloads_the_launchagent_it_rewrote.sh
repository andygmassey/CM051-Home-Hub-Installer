#!/usr/bin/env bash
# An upgrade that rewrites a LaunchAgent plist must make launchd RE-READ it.
#
# THE DEFECT. Phase 3.13a regenerates com.ostler.ical-server.plist in full --
# EnvironmentVariables included -- and then called only:
#
#     launchctl bootstrap "gui/$(id -u)" "$ICAL_PLIST"
#
# install.sh's own comment said that call "is idempotent enough for the
# first-install path". Correct, and exactly the bug: on an UPGRADE the label is
# already bootstrapped, bootstrap is a no-op, and launchd keeps serving the job
# definition it loaded at FIRST INSTALL. The plist just written is never read.
#
# MEASURED on a real box 2026-08-26, after the service token was rotated:
#
#     launchd LOADED job token sha : 4e7620a2320c   (pre-rotation)
#     on-disk plist / secrets  sha : caa3d247d221   (current)
#
# ical-server.py's _authorized() constant-time-compares against its env value
# and FAILS CLOSED, so every non-public /api/v1 route 401'd for every correctly
# configured client. The Doctor fronts that service, so it 401'd too. It
# presented as a client auth fault and was not one.
#
# `launchctl kickstart -k` does NOT fix it -- it restarts the process from the
# LOADED definition. Verified: new pid, same stale token. Only bootout +
# bootstrap reloads the definition.
#
# THIS IS NOT SPECIFIC TO THE TOKEN. Every EnvironmentVariables entry the
# installer delivers through a regenerated plist is inert on upgrade until the
# customer logs out.
#
# WHAT THIS TEST PINS. That the reload exists, that it uses the SAFE form, that
# it cannot disturb a first install, and that the vendored gate's literal
# survives. Each has a control.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL [missing]: $INSTALL_SH not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

LABEL='com.ostler.ical-server'

# ---- 0. CONTROL: the site exists at all -----------------------------------
# Without this, every assertion below could pass vacuously on a file that no
# longer installs this agent.
if grep -q 'ICAL_PLIST=' "$INSTALL_SH"; then
    pass "CONTROL: install.sh still renders the ical-server LaunchAgent"
else
    echo "FAIL [no-site]: install.sh no longer defines ICAL_PLIST; this test is measuring nothing. NOT a pass." >&2
    exit 2
fi

# ---- 1. the reload must exist ---------------------------------------------
if grep -q "launchctl bootout \"gui/\$(id -u)/${LABEL}\"" "$INSTALL_SH"; then
    pass "the upgrade path boots out ${LABEL} so launchd re-reads the plist"
else
    fail "no-reload" "install.sh rewrites ${LABEL}.plist but never boots the label out. bootstrap alone is a no-op on an already-loaded label, so the new EnvironmentVariables are inert until the customer logs out."
fi

# ---- 2. it must come BEFORE the bootstrap ---------------------------------
# Ordering is the whole point: a bootout after the bootstrap would leave the
# service DOWN, which is worse than stale.
BOOTOUT_LN="$(grep -n "launchctl bootout \"gui/\$(id -u)/${LABEL}\"" "$INSTALL_SH" | head -1 | cut -d: -f1)"
BOOTSTRAP_LN="$(grep -n 'launchctl bootstrap "gui/\$(id -u)" "\$ICAL_PLIST"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$BOOTOUT_LN" && -n "$BOOTSTRAP_LN" ]]; then
    if [[ "$BOOTOUT_LN" -lt "$BOOTSTRAP_LN" ]]; then
        pass "bootout (line $BOOTOUT_LN) precedes bootstrap (line $BOOTSTRAP_LN)"
    else
        fail "wrong-order" "bootout at $BOOTOUT_LN comes AFTER bootstrap at $BOOTSTRAP_LN -- that leaves the service down, not reloaded"
    fi
else
    fail "cannot-order" "could not locate both calls (bootout='$BOOTOUT_LN' bootstrap='$BOOTSTRAP_LN'); ordering was NOT verified"
fi

# ---- 3. SAFETY: label form only, never the bare domain form ---------------
# install.sh's own comment records the hazard: a DOMAIN-form bootout on a
# customer GUI session can kick them back to the login screen.
if grep -qE 'launchctl bootout "gui/\$\(id -u\)"[[:space:]]*$' "$INSTALL_SH"; then
    fail "domain-bootout" "a bare DOMAIN-form 'launchctl bootout gui/\$(id -u)' appears in install.sh. That can return a customer to the login screen; only the LABEL form is safe here."
else
    pass "no bare domain-form bootout (the login-screen hazard stays honoured)"
fi

# ---- 4. a first install must not be disturbed -----------------------------
# The bootout has to be guarded on the label already being loaded, or a clean
# install pays for an upgrade's problem.
if grep -B3 "launchctl bootout \"gui/\$(id -u)/${LABEL}\"" "$INSTALL_SH" \
     | grep -q "launchctl print \"gui/\$(id -u)/${LABEL}\""; then
    pass "the bootout is guarded on the label already being loaded"
else
    fail "unguarded" "the bootout is not guarded by a 'launchctl print' check, so a FIRST install would attempt to bootout a label that was never loaded"
fi

# ---- 5. the vendored text-pinned gate must stay green --------------------
# vendor/cm041/assistant_api/test_vendor_import.sh greps this literal. Routing
# around a gate rather than editing it is how red-while-fixed happens; this
# change inserts before it and leaves it intact.
if grep -q 'launchctl bootstrap "gui/\$(id -u)" "\$ICAL_PLIST"' "$INSTALL_SH"; then
    pass "the literal pinned by test_vendor_import.sh is still present"
else
    fail "pin-broken" "the bootstrap literal that vendor/cm041/assistant_api/test_vendor_import.sh pins by text is gone"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo
echo "ALL LAUNCHAGENT RELOAD TESTS PASSED"
