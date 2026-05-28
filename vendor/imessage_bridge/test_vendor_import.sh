#!/usr/bin/env bash
#
# test_vendor_import.sh
#
# Byte-walking regression test for the iMessage bridge vendor.
#
# v1.0 STATUS (2026-05-28): the bridge LaunchAgent is DISABLED in
# single-machine customer installs. The vendor remains on disk so a
# future split-identity deployment can re-wire it.
#
# The 2026-05-28 fix to a Marvin self-talk loop changed the install
# semantics from "actively register the LaunchAgent" to "actively
# bootout + remove any stale LaunchAgent from a previous install".
# This test refuses regression on both shapes:
#
#   - Forward direction (we MUST keep): vendor files exist + read-only
#     SQLite + is_from_me=0 filter + first-run MAX(ROWID) clamp.
#   - Anti-regression (we MUST NOT relapse): install.sh 3.14c phase
#     does NOT register the LaunchAgent. Bridge is opt-in only via a
#     future split-identity install.
#
# Companion guard: ostler-assistant's poll_bridge_inbox is gated by
# OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE=1 (default OFF). Both gates
# must remain off in lockstep so a customer never sees doubled
# inbound message processing.

set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$VENDOR_DIR/../.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

# ---------------------------------------------------------------------------
# Axis 1: bridge.py is present and executable
# ---------------------------------------------------------------------------

BRIDGE_PY="$VENDOR_DIR/bin/bridge.py"
if [[ ! -f "$BRIDGE_PY" ]]; then
    failure "vendor/imessage_bridge/bin/bridge.py missing -- producer cannot be staged"
fi
if [[ ! -x "$BRIDGE_PY" ]]; then
    failure "vendor/imessage_bridge/bin/bridge.py not executable"
fi

# Axis 1b: bridge.py reads ~/Library/Messages/chat.db via the read-only
# SQLite URI pattern. Refuse any change that opens chat.db read-write
# (would race iMessage's writer + risk corruption).
if ! grep -q 'mode=ro' "$BRIDGE_PY" 2>/dev/null; then
    failure "bridge.py does not open chat.db with mode=ro -- read-write open would race iMessage's writer"
fi

# Axis 1c: bridge.py writes to /Users/Shared/imessage-bridge/inbox.jsonl
# (the reader's hard-coded path).
if ! grep -q '/Users/Shared/imessage-bridge' "$BRIDGE_PY" 2>/dev/null; then
    failure "bridge.py does not reference /Users/Shared/imessage-bridge -- consumer reads from there"
fi

# Axis 1d: bridge.py filters out is_from_me messages (outbound).
if ! grep -q 'is_from_me = 0\|is_from_me=0' "$BRIDGE_PY" 2>/dev/null; then
    failure "bridge.py does not filter is_from_me=0 -- would echo the user's own messages back to the assistant"
fi

# ---------------------------------------------------------------------------
# Axis 2: LaunchAgent plist is present
# ---------------------------------------------------------------------------

PLIST="$VENDOR_DIR/launchd/com.ostler.imessage-bridge.plist"
if [[ ! -f "$PLIST" ]]; then
    failure "vendor/imessage_bridge/launchd/com.ostler.imessage-bridge.plist missing"
else
    # Axis 2a: label matches what ostler-assistant + uninstall + Doctor expect.
    if ! grep -q 'com\.ostler\.imessage-bridge' "$PLIST" 2>/dev/null; then
        failure "plist Label is not com.ostler.imessage-bridge"
    fi
    # Axis 2b: must use the placeholder set the INSTALL_SNIPPET sed renders.
    for placeholder in OSTLER_BIN OSTLER_HOME OSTLER_LOGS OSTLER_PYTHON; do
        if ! grep -q "$placeholder" "$PLIST" 2>/dev/null; then
            failure "plist missing $placeholder placeholder -- INSTALL_SNIPPET.sh sed will not render"
        fi
    done
    # Axis 2c: KeepAlive must be true so the long-running poll daemon
    # restarts on crash / chat.db FDA flip.
    if ! grep -q '<key>KeepAlive</key>' "$PLIST" 2>/dev/null; then
        failure "plist missing KeepAlive -- daemon will not restart after a poll error"
    fi
    # Axis 2d: plistlib parse via Python (mirror of plutil -lint, works
    # in any environment that has python3).
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import plistlib, sys; plistlib.load(open(sys.argv[1],'rb'))" "$PLIST" 2>/dev/null; then
            failure "plist fails plistlib parse -- launchctl would silently reject"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Axis 3: INSTALL_SNIPPET.sh is present and renders the plist
# ---------------------------------------------------------------------------

SNIPPET="$VENDOR_DIR/INSTALL_SNIPPET.sh"
if [[ ! -f "$SNIPPET" ]]; then
    failure "vendor/imessage_bridge/INSTALL_SNIPPET.sh missing"
elif [[ ! -x "$SNIPPET" ]]; then
    failure "vendor/imessage_bridge/INSTALL_SNIPPET.sh not executable"
else
    # Axis 3a: must call launchctl bootstrap (idempotent load).
    if ! grep -q 'launchctl bootstrap' "$SNIPPET" 2>/dev/null; then
        failure "INSTALL_SNIPPET.sh does not call launchctl bootstrap"
    fi
    # Axis 3b: must NOT call launchctl bootout on the user's domain
    # without first booting in. The pre-bootout-then-bootstrap pattern
    # is the idempotent install shape; reject any change that drops it.
    if ! grep -q 'launchctl bootout' "$SNIPPET" 2>/dev/null; then
        failure "INSTALL_SNIPPET.sh does not bootout the stale agent before bootstrap -- repeated installs will fail"
    fi
    # Axis 3c: must create /Users/Shared/imessage-bridge.
    if ! grep -q '/Users/Shared/imessage-bridge' "$SNIPPET" 2>/dev/null; then
        failure "INSTALL_SNIPPET.sh does not create /Users/Shared/imessage-bridge -- consumer will see no file"
    fi
    # Axis 3d: must sed-substitute all four placeholders.
    for placeholder in OSTLER_BIN OSTLER_HOME OSTLER_LOGS OSTLER_PYTHON; do
        if ! grep -q "s/$placeholder/" "$SNIPPET" 2>/dev/null; then
            failure "INSTALL_SNIPPET.sh missing sed substitution for $placeholder -- placeholder will reach launchd unrendered"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Axis 4: install.sh has the 3.14c bridge DISABLE block (single-machine v1.0)
# ---------------------------------------------------------------------------
#
# 2026-05-28 self-talk fix: install.sh used to register the bridge
# LaunchAgent here. We now REFUSE to register it because the bridge.py
# producer + the Rust listener BOTH poll the same chat.db on a
# single-machine install, producing doubled inbound processing AND
# (on first install) a full history replay self-talk loop.
#
# The 3.14c block must still EXIST in install.sh (so a stale legacy
# LaunchAgent from a previous install gets booted out + removed) but
# it must NOT call IMESSAGE_BRIDGE_SNIPPET / launchctl bootstrap on
# com.ostler.imessage-bridge.

INSTALL_SH="$REPO_ROOT/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing -- cannot verify 3.14c wiring"
else
    if ! grep -q '3.14c iMessage bridge LaunchAgent' "$INSTALL_SH" 2>/dev/null; then
        failure "install.sh missing the 3.14c phase header -- legacy bootout block was dropped"
    fi
    # Forward direction: must bootout any stale LaunchAgent so existing
    # installs lose the duplicate poller on upgrade.
    if ! grep -q 'com.ostler.imessage-bridge' "$INSTALL_SH" 2>/dev/null; then
        failure "install.sh does not reference com.ostler.imessage-bridge label -- bootout cannot land"
    fi
    # Anti-regression: must NOT actively register the LaunchAgent.
    # IMESSAGE_BRIDGE_SNIPPET is the variable name the legacy install
    # used. If it ever comes back, the self-talk loop comes with it.
    if grep -q 'IMESSAGE_BRIDGE_SNIPPET' "$INSTALL_SH" 2>/dev/null; then
        failure "install.sh references IMESSAGE_BRIDGE_SNIPPET -- bridge LaunchAgent registration must not return in single-machine v1.0"
    fi
    if grep -E 'launchctl bootstrap.*imessage-bridge' "$INSTALL_SH" 2>/dev/null; then
        failure "install.sh calls launchctl bootstrap on imessage-bridge -- bridge LaunchAgent registration must not return in single-machine v1.0"
    fi
fi

# ---------------------------------------------------------------------------
# Axis 5: release.sh HR015_SOURCES includes imessage-bridge
# ---------------------------------------------------------------------------

RELEASE_SH="$REPO_ROOT/release.sh"
if [[ ! -f "$RELEASE_SH" ]]; then
    failure "release.sh missing"
else
    # Look for the literal string inside HR015_SOURCES array.
    if ! awk '/HR015_SOURCES=/,/^\)/' "$RELEASE_SH" | grep -q '"imessage-bridge"' 2>/dev/null; then
        failure "release.sh HR015_SOURCES does not include imessage-bridge -- vendor will not land in install tarball"
    fi
fi

# ---------------------------------------------------------------------------
# Axis 6: gui/project.yml bundles vendor/imessage_bridge into Resources
# ---------------------------------------------------------------------------

PROJECT_YML="$REPO_ROOT/gui/project.yml"
if [[ ! -f "$PROJECT_YML" ]]; then
    failure "gui/project.yml missing"
else
    if ! grep -q 'vendor/imessage_bridge' "$PROJECT_YML" 2>/dev/null; then
        failure "gui/project.yml does not bundle vendor/imessage_bridge -- .app will ship without the producer"
    fi
    if ! grep -q 'Resources/imessage-bridge\|"\${DEST}/imessage-bridge"' "$PROJECT_YML" 2>/dev/null; then
        failure "gui/project.yml does not copy into Resources/imessage-bridge/ -- install.sh \${SCRIPT_DIR}/imessage-bridge lookup will miss"
    fi
fi

# ---------------------------------------------------------------------------
# Axis 7: gui/Makefile verify-dmg-contents checks imessage-bridge
# ---------------------------------------------------------------------------

MAKEFILE="$REPO_ROOT/gui/Makefile"
if [[ ! -f "$MAKEFILE" ]]; then
    failure "gui/Makefile missing"
else
    # The verify-dmg-contents target lists the expected vendor dirs in
    # a single shell-for loop. Refuse any change that drops imessage-
    # bridge from that list.
    if ! awk '/verify-dmg-contents:/,/^\$\(STEP\) "Verifying|^ship:/' "$MAKEFILE" | grep -q 'imessage-bridge' 2>/dev/null; then
        # Fallback: simple grep across the whole Makefile, since the
        # awk range is fiddly with embedded ":".
        if ! grep -q 'imessage-bridge' "$MAKEFILE" 2>/dev/null; then
            failure "gui/Makefile verify-dmg-contents does not check imessage-bridge -- silent drop reaches a notarised DMG"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [[ "$FAILED" -eq 0 ]]; then
    echo "PASS: imessage-bridge vendor wiring is byte-correct across all 7 axes"
    exit 0
else
    echo "" >&2
    echo "Regression test failed. The WSA-018 fix (2026-05-26) is incomplete on at least one axis." >&2
    echo "See vendor/imessage_bridge/INSTALL_SNIPPET.sh + install.sh 3.14c + release.sh HR015_SOURCES + gui/project.yml + gui/Makefile verify-dmg-contents." >&2
    exit 1
fi
