#!/usr/bin/env bash
#
# tests/test_cx453_no_osascript_contacts.sh
#
# Regression test for the CX-453 (task #453, v1.0.1) fix: install.sh must
# never read Contacts via `osascript -e 'tell application "Contacts"'`,
# which fires the macOS AppleEvent Automation consent prompt (the blue
# "OstlerInstaller wants to control Contacts" dialog) on top of the
# Contacts/FDA permission the customer already grants.
#
# The fix removes all three osascript Contacts read sites:
#   1. me-card auto-detect (Phase 2)  -> dropped; the customer types
#      their name + country as plain questions.
#   2. count + backup VCF export (Phase 2) -> dropped; contacts are
#      ingested later via the Full-Disk-Access abcddb read.
#   3. hydrate-time re-export -> replaced by forcing contact_syncer onto
#      the AddressBook-v22.abcddb read (point --vcf at a path we never
#      create), which needs only FDA, no Automation.
#
# Per the silent-bail regression-test discipline this walks install.sh
# and pins the EXACT shape so a future edit that reintroduces an
# osascript Contacts read (or a silent 0-contact pass) trips this test.
#
# Synthetic only. Pure bash + standard tools.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail_test "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || fail_test "strings file not found at $STRINGS_FILE"

bash -n "$INSTALL_SH" || fail_test "install.sh fails bash -n parse check"
echo "PASS: install.sh parses"

# ── 1. No EXECUTABLE osascript Contacts read (comments allowed) ──
# Strip comment lines (leading-whitespace + '#') before grepping, so the
# explanatory comment that documents the OLD pattern does not trip us.
# Scope is Contacts ONLY: System Events / Messages / Calendar osascripts
# may legitimately remain.
noncomment_contacts="$(grep -nE 'tell application "Contacts"' "$INSTALL_SH" \
    | grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$noncomment_contacts" ]]; then
    fail_test "executable osascript Contacts read still present:
$noncomment_contacts"
fi
echo "PASS: no executable 'tell application \"Contacts\"' osascript read remains"

# A Calendar osascript prewarm is fine and should still be here (proves
# we scoped to Contacts, not nuke-all-osascript).
grep -qE "tell application \"Calendar\"" "$INSTALL_SH" \
    || echo "NOTE: no Calendar osascript found (not required, just a scope sanity check)"

# ── 2. me-card site: dropped read, plain-question fallback ──────
grep -q 'MSG_INFO_CONTACT_CARD_WILL_ASK' "$INSTALL_SH" \
    || fail_test "me-card site does not emit the 'we will ask' message (MSG_INFO_CONTACT_CARD_WILL_ASK)"
# The old Phase-2 VCF export must be gone.
grep -q 'CONTACTS_BACKUP=' "$INSTALL_SH" \
    && fail_test "Phase-2 CONTACTS_BACKUP osascript export still present"
echo "PASS: me-card site reads nothing; Phase-2 VCF export removed"

# ── 3. hydrate forces the FDA abcddb read ───────────────────────
HYD="$(awk '/Contact hydration ----/{c=1} c{print} /^unset _hydrate_contacts_accounts/{if(c)exit}' "$INSTALL_SH")"
[[ -n "$HYD" ]] || fail_test "could not isolate the contact-hydration block"
grep -q 'contact_syncer.syncer' <<<"$HYD" || fail_test "hydrate no longer invokes contact_syncer.syncer"
grep -q '_HYDRATE_FORCE_ABCDDB_VCF' <<<"$HYD" || fail_test "hydrate does not force the abcddb read (no _HYDRATE_FORCE_ABCDDB_VCF)"
grep -qE 'rm -f "\$_HYDRATE_FORCE_ABCDDB_VCF"' <<<"$HYD" \
    || fail_test "the forced-abcddb vcf path is not removed before use (so it would not force the fallback)"
echo "PASS: hydrate forces the Full-Disk-Access abcddb read"

# ── 4. fail-loud on FDA denial + non-zero assertion ─────────────
grep -qE 'FDA_GRANTED|_has_fda' <<<"$HYD" || fail_test "hydrate does not check FDA grant state to fail loud on denial"
grep -q 'MSG_HYDRATE_CONTACTS_DENIED' <<<"$HYD" || fail_test "no FDA-denied warning surfaced"
grep -q '_schedule_contact_resync' <<<"$HYD" || fail_test "no self-removing re-sync scheduled for the late-sync / FDA-grant case"
grep -q 'MSG_HYDRATE_CONTACTS_DONE' <<<"$HYD" || fail_test "no success (non-zero count) branch"
# SILENT-ZERO guard: FDA granted + local store populated + 0 imported
# must be its own loud failure, never a "pending" or a silent pass.
grep -q 'MSG_HYDRATE_CONTACTS_READ_FAILED' <<<"$HYD" \
    || fail_test "no silent-zero guard: a populated store importing 0 contacts must fail loud (MSG_HYDRATE_CONTACTS_READ_FAILED)"
grep -q '_store_populated_contacts' <<<"$HYD" \
    || fail_test "silent-zero guard does not check _store_populated_contacts"
# The denial copy must reference Full Disk Access, not Automation.
denied_line="$(grep '^MSG_HYDRATE_CONTACTS_DENIED=' "$STRINGS_FILE")"
grep -qi 'Full Disk Access' <<<"$denied_line" || fail_test "MSG_HYDRATE_CONTACTS_DENIED still references Automation, not Full Disk Access:
$denied_line"
echo "PASS: FDA denial fails loud (FDA wording + resync), and a non-zero-count success branch exists"

# ── 5. strings present ──────────────────────────────────────────
for key in MSG_INFO_CONTACT_CARD_WILL_ASK MSG_HYDRATE_CONTACTS_DENIED MSG_HYDRATE_CONTACTS_PENDING MSG_HYDRATE_CONTACTS_DONE MSG_HYDRATE_CONTACTS_READ_FAILED; do
    grep -q "^${key}=" "$STRINGS_FILE" || fail_test "locale catalogue missing key: $key"
done
echo "PASS: locale keys present"

echo "ALL PASS: test_cx453_no_osascript_contacts.sh"
