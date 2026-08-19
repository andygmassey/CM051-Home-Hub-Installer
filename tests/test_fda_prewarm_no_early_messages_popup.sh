#!/usr/bin/env bash
#
# test_fda_prewarm_no_early_messages_popup.sh
#
# Regression test for the .149-walk fix (2026-06-13): the early
# FDA_PREWARM block (top of install) must NOT read FDA-gated databases
# whose first-byte read fires a user-facing TCC dialog -- specifically
# the Messages chat.db ("Allow Ostler to read your messages") and the
# Mail Envelope Index. Prewarming those there popped the dialog ~30s into
# the install, decoupled from the in-context FDA guidance.
#
# Contract this locks:
#   1. The early FDA_PREWARM block reads Safari History.db (silent, keeps
#      the Files entry warm).
#   2. The early FDA_PREWARM block does NOT read Messages/chat.db.
#   3. The early FDA_PREWARM block does NOT read the Mail Envelope Index.
#   4. The in-context FDA probe (FDA_ASSIST_TRIGGER, downstream) STILL
#      reads chat.db -- so the messages prompt fires there, with the
#      grant assist + System Settings pane refresh around it.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# Extract the early FDA_PREWARM block: from its marker to the unset that
# closes it (unique to that block). Strip comment lines -- the rationale
# comment legitimately NAMES chat.db/Mail when explaining why they are no
# longer prewarmed, and we only want to assert on the actual CODE reads.
PREWARM_BLOCK="$(awk '/FDA_PREWARM \(#572/{f=1} f{print} /unset _fda_prime/{if(f) exit}' "$INSTALL_SH" | grep -v '^[[:space:]]*#')"

if [[ -z "$PREWARM_BLOCK" ]]; then
    fail "could not locate the early FDA_PREWARM block"
else
    # 1. Safari stays.
    if printf '%s\n' "$PREWARM_BLOCK" | grep -q 'Library/Safari/History.db'; then
        pass "early prewarm keeps the silent Safari History.db read"
    else
        fail "early prewarm no longer reads Safari History.db (registration lost)"
    fi
    # 2 + 3. Messages + Mail must NOT be prewarmed early (they pop a dialog).
    if printf '%s\n' "$PREWARM_BLOCK" | grep -q 'Library/Messages/chat.db'; then
        fail "early prewarm reads Messages chat.db -- fires the 'read your messages' TCC dialog 30s too early"
    else
        pass "early prewarm does NOT read Messages chat.db"
    fi
    if printf '%s\n' "$PREWARM_BLOCK" | grep -qi 'Mail/.*Envelope Index'; then
        fail "early prewarm reads the Mail Envelope Index -- fires a Mail TCC dialog early"
    else
        pass "early prewarm does NOT read the Mail Envelope Index"
    fi
fi

# 4. The in-context probe must STILL read chat.db (so the messages prompt
#    fires there, with the assist + pane refresh). Look in the
#    FDA_PROBE_PATHS array downstream.
PROBE_BLOCK="$(awk '/FDA_PROBE_PATHS=\(/{f=1} f{print} f && /^[[:space:]]*\)[[:space:]]*$/{exit}' "$INSTALL_SH")"
if printf '%s\n' "$PROBE_BLOCK" | grep -q 'Library/Messages/chat.db'; then
    pass "in-context FDA probe still reads chat.db (messages prompt fires in-context)"
else
    fail "in-context FDA probe no longer reads chat.db -- the messages prompt + registration would be lost"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
