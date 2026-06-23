#!/usr/bin/env bash
#
# tests/test_mailbox_ingest_leg_wired.sh
#
# Pins the v1.0.3 RAW MAILBOX ingest leg. The universal_import (P3) leg
# (tests/test_universal_import_leg_wired.sh) sniffs each dir handed to
# ostler-import; this leg seeds those dirs with the operator's mailbox so
# their CORRESPONDENTS (who they email, how often) reach the people graph.
#
# Two axes:
#   STATIC  -- install.sh seeds _IMPORT_DIRS with the confirmed Gmail
#              Takeout mbox AND an explicit OSTLER_MAILBOX_DIR, BOUNDED
#              (never an unbounded Downloads rglob -- the CX-126 lesson),
#              and skip-if-absent (guarded on path existence).
#   VENDOR  -- the vendored ostler_fda/universal_import.py carries the
#              mailbox -> people-graph persistence (the Gmail mbox and the
#              Apple Mail .emlx dispatch both persist via pwg_ingest), and
#              stays byte-identical to its HR015 source contract.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
VENDORED_UI="${REPO_ROOT}/vendor/ostler_fda/universal_import.py"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# STATIC: the mailbox seeding is present, bounded, and skip-if-absent.
# ---------------------------------------------------------------------------

# 1. The confirmed Gmail Takeout mbox seeds the import dirs (by its dirname,
#    so the leg sniffs the single .mbox, not a whole tree).
if grep -q 'OSTLER_TAKEOUT_PATH.*-f.*OSTLER_TAKEOUT_PATH' "$INSTALL_SH" \
   && grep -q '_IMPORT_DIRS+=("\$(dirname "\${OSTLER_TAKEOUT_PATH}")")' "$INSTALL_SH"; then
    pass "Gmail Takeout mbox seeds the universal_import leg (by dirname, bounded)"
else
    failure "Gmail Takeout mbox is not seeded into _IMPORT_DIRS"
fi

# 2. An explicit OSTLER_MAILBOX_DIR (Apple Mail .emlx / loose mbox) is
#    seeded, guarded on directory existence (skip-if-absent), no hardcoded
#    path.
if grep -q 'OSTLER_MAILBOX_DIR.*-d.*OSTLER_MAILBOX_DIR' "$INSTALL_SH" \
   && grep -q '_IMPORT_DIRS+=("\${OSTLER_MAILBOX_DIR}")' "$INSTALL_SH"; then
    pass "OSTLER_MAILBOX_DIR seeds the leg, guarded + env-configurable"
else
    failure "OSTLER_MAILBOX_DIR is not seeded into _IMPORT_DIRS"
fi

# 3. No unbounded Downloads rglob was reintroduced for the mailbox seed
#    (the CX-126 regression). The seed must reference only the confirmed
#    Takeout path and the explicit env dir.
if grep -n 'OSTLER_MAILBOX_DIR\|OSTLER_TAKEOUT_PATH' "$INSTALL_SH" \
   | grep -q 'Downloads'; then
    failure "mailbox seed line references Downloads (unbounded rglob risk)"
else
    pass "mailbox seed is bounded (no Downloads rglob)"
fi

# ---------------------------------------------------------------------------
# VENDOR: the persistence is actually present in the vendored module.
# ---------------------------------------------------------------------------

if [[ ! -f "$VENDORED_UI" ]]; then
    failure "vendored universal_import.py is missing"
else
    # Gmail mbox dispatch persists people-graph facts via pwg_ingest.
    if grep -q '_persist_mail_contacts' "$VENDORED_UI" \
       && grep -q 'ingest_mail_contacts' "$VENDORED_UI"; then
        pass "vendored universal_import persists mail correspondents via pwg_ingest"
    else
        failure "vendored universal_import lacks the mail people-graph persistence"
    fi

    # Apple Mail .emlx is detected + dispatched (emlx -> mbox -> people).
    if grep -q '_detect_apple_mail_emlx' "$VENDORED_UI" \
       && grep -q '_dispatch_apple_mail_emlx' "$VENDORED_UI" \
       && grep -q 'apple_mail_emlx' "$VENDORED_UI"; then
        pass "vendored universal_import covers Apple Mail .emlx (emlx -> mbox -> people)"
    else
        failure "vendored universal_import lacks Apple Mail .emlx coverage"
    fi

    # Large-mbox safeguard: a streaming message cap is present.
    if grep -q 'OSTLER_MBOX_MAX_MESSAGES' "$VENDORED_UI" \
       && grep -q '_mbox_message_cap' "$VENDORED_UI"; then
        pass "vendored universal_import has a streaming message cap (large-mbox safety)"
    else
        failure "vendored universal_import lacks the large-mbox streaming cap"
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "FAILED" >&2
    exit 1
fi
echo "PASS: mailbox-ingest leg seeded (bounded, skip-if-absent) + vendored persistence present."
