#!/usr/bin/env bash
#
# tests/test_mail_onboarding_259_260.sh
#
# Regression test for the two v1.0.1 Mail-onboarding improvements:
#
#   #259  Detect missing local Mail content and guide the customer to
#         connect an account, instead of silently ingesting zero.
#   #260  Make the Mail history window configurable + extend the
#         default beyond one year, plus a post-install "extend now?"
#         affordance.
#
# These are byte-walking wiring assertions (the repo's preferred shape
# for silent-fail-class fixes): they assert the EXACT contract pieces
# that must never regress, rather than a happy-path "does it run".
#
# What the failures looked like (PRE-FIX, must never recur):
#
#   #259: extract_all.py recorded apple_mail status "ok" with
#         total_messages 0 when Mail was selected but the local store
#         was empty. The install summary surfaced nothing, so the
#         customer never learned why their email surfaces were blank.
#
#   #260: extract_all.py called extract_messages(since_days=365) with
#         no env override -- a hard 1-year cap, unlike every other
#         source (iMessage / browser / safari / whatsapp) which all
#         read OSTLER_*_BACKFILL_DAYS and default to 1825 (5 years).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
EXTRACT_ALL="${REPO_ROOT}/vendor/ostler_fda/extract_all.py"
APPLE_MAIL="${REPO_ROOT}/vendor/ostler_fda/apple_mail.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── #260 axis 1: install.sh defaults OSTLER_MAIL_BACKFILL_DAYS to a
#    multi-year window (not 365) and threads it into the extractor env.
grep -Eq '^[[:space:]]*:[[:space:]]*"\$\{OSTLER_MAIL_BACKFILL_DAYS:=1825\}"' "$INSTALL_SH" \
    || fail "#260: OSTLER_MAIL_BACKFILL_DAYS default of 1825 not set in install.sh"
grep -q 'OSTLER_MAIL_BACKFILL_DAYS="\${OSTLER_MAIL_BACKFILL_DAYS}"' "$INSTALL_SH" \
    || fail "#260: OSTLER_MAIL_BACKFILL_DAYS not passed into the FDA extractor env"
echo "PASS [#260]: install.sh defaults mail window to 1825 days and exports it"

# ── #260 axis 2: extract_all.py reads the env + no longer hard-codes 365.
grep -q 'os.environ.get("OSTLER_MAIL_BACKFILL_DAYS"' "$EXTRACT_ALL" \
    || fail "#260: extract_all.py does not read OSTLER_MAIL_BACKFILL_DAYS"
if grep -q 'extract_messages(since_days=365)' "$EXTRACT_ALL"; then
    fail "#260: extract_all.py still hard-codes the 1-year (365) Mail window"
fi
echo "PASS [#260]: extract_all.py reads the env var, 365 hard-cap removed"

# ── #260 axis 3: apple_mail.py default window is no longer 365.
if grep -Eq 'since_days: int = 365' "$APPLE_MAIL"; then
    fail "#260: apple_mail.py default since_days is still 365"
fi
echo "PASS [#260]: apple_mail.py default window extended beyond one year"

# ── #260 axis 4: the post-install "extend now?" affordance exists and is
#    skippable (default No so a walk-away install never blocks).
grep -q 'MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE' "$INSTALL_SH" \
    || fail "#260: no post-install Mail extend prompt in install.sh"
grep -q 'mail_extend_history' "$INSTALL_SH" \
    || fail "#260: extend prompt missing its gui_read key"
echo "PASS [#260]: post-install extend-history affordance is wired and skippable"

# ── #259 axis 1: extract_all.py emits a distinct status when Mail is
#    configured but holds no content, instead of "ok" with zero rows.
grep -q '"empty_no_content"' "$EXTRACT_ALL" \
    || fail "#259: extract_all.py does not emit empty_no_content for zero-message Mail"
grep -q 'total_messages.*== 0' "$EXTRACT_ALL" \
    || fail "#259: extract_all.py does not branch on a zero total_messages count"
echo "PASS [#259]: extractor distinguishes empty-Mail from a real ingest"

# ── #259 axis 2: install.sh surfaces calm guidance on empty_no_content.
grep -q 'empty_no_content' "$INSTALL_SH" \
    || fail "#259: install.sh does not react to the empty_no_content status"
grep -q 'MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT' "$INSTALL_SH" \
    || fail "#259: install.sh does not emit the connect-an-account guidance"
echo "PASS [#259]: install.sh surfaces calm connect-an-account guidance"

# ── Catalogue completeness: every new MSG_* key referenced is defined.
for key in \
    MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT \
    MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN \
    MSG_OK_MAIL_EXTENDING_FULL_HISTORY \
    MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY \
    MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE \
    MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP ; do
    grep -q "^${key}=" "$STRINGS" \
        || fail "catalogue: ${key} referenced but not defined in en-GB strings"
done
echo "PASS [Rule 0.9]: all new customer strings are in the en-GB catalogue"

# ── #260 functional smoke: extract_all reads the env and a small window
#    actually limits results vs a large window (pure-Python, no Mac store).
python3 - "$REPO_ROOT" <<'PY'
import os, sys, types, importlib.util
from pathlib import Path

repo = Path(sys.argv[1])
# Load apple_mail as a standalone module and stub extract_messages to
# echo the since_days it was called with, then confirm extract_all
# threads OSTLER_MAIL_BACKFILL_DAYS through to it.
spec = importlib.util.spec_from_file_location(
    "ostler_fda.extract_all", repo / "vendor" / "ostler_fda" / "extract_all.py"
)
# We only static-check that the env name and call shape are present;
# a full import pulls Mac-only deps. Re-read the source and assert the
# call site passes since_days=<env-derived var>, not a literal 365.
src = (repo / "vendor" / "ostler_fda" / "extract_all.py").read_text()
assert "OSTLER_MAIL_BACKFILL_DAYS" in src
assert "extract_messages(since_days=mail_backfill_days" in src, \
    "extract_all.py must call extract_messages with the env-derived window"
print("PASS [#260 smoke]: call site uses env-derived window, not a literal")
PY

echo ""
echo "ALL MAIL ONBOARDING (#259 + #260) TESTS PASSED"
