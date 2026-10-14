#!/usr/bin/env bash
#
# test_contact_resync_scheduled.sh
#
# Byte-walking regression test for the Symptom-3 contact iCloud-sync
# race fix (recut 2026-06-03). Refuses the exact failure shape that left
# a clean Studio install with a near-empty People graph: at install time
# iCloud had not finished its first contact sync, so the hydrate step
# imported zero contacts, printed "Contacts not synced yet", and NOTHING
# re-ran once iCloud caught up (the existing com.ostler.fda-rerun agent
# re-runs the FDA extractor, not contacts). The store later filled to
# ~1700 rows but the graph stayed sparse.
#
# The fix: a self-removing com.ostler.contact-resync LaunchAgent, scheduled
# ONLY on the pending state, that re-runs contact_syncer against the
# now-synced local AddressBook (the FDA-gated AddressBook-v22.abcddb
# fallback, not the Automation-gated Contacts.app export) and boots itself
# out once contacts land or after a bounded number of attempts.
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. install.sh never generates a contact re-sync wrapper
#   2. it never schedules a contact re-sync LaunchAgent
#   3. the re-sync is scheduled unconditionally (not gated on the race)
#   4. the agent never self-removes / never bounds its retries (runs forever)
#   5. the uninstaller leaks the agent
#
# All axes per locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS_SH="$REPO_ROOT/install.sh.strings.en-GB.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_contact_resync_scheduled: FAILED" >&2
    exit 1
fi

# Axis 1: install.sh must generate the bin/ostler-contact-resync wrapper.
if ! grep -q 'bin/ostler-contact-resync" <<' "$INSTALL_SH"; then
    failure "install.sh never generates bin/ostler-contact-resync -- nothing re-runs the contact import after a late iCloud sync"
fi

# Axis 2: the wrapper must use the AddressBook (abcddb) fallback by
# pointing --vcf at a path it never creates, and call contact_syncer.
if ! grep -q 'contact-resync-force-abcddb' "$INSTALL_SH"; then
    failure "wrapper does not force the AddressBook fallback (would need Automation, not just FDA)"
fi
if ! grep -q 'contact_syncer.syncer' "$INSTALL_SH"; then
    failure "wrapper does not invoke contact_syncer.syncer"
fi

# Axis 3 (REWRITTEN for G3, TCC sweep 2026-10-15). This used to require a
# self-removing, bounded agent. That design is what left Contacts with NO
# recurring reader on most Macs: it was scheduled only after a failed install
# read and removed itself on first success. The reader is now permanent, so
# the axis asserts the opposite: it must NOT remove itself, and it must stay
# cheap by syncing only when the address book's signature changes. Its
# behaviour is proven by tests/test_contacts_and_reminders_are_reread.sh.
RESYNC_BODY="$(awk '/bin\/ostler-contact-resync" <</{p=1;next} p&&/^CRSEOF$/{exit} p' "$INSTALL_SH")"
if grep -qE 'launchctl (bootout|unload)' <<<"$RESYNC_BODY"; then
    failure "the contact reader still removes its own agent, so contacts stop being read"
fi
if ! grep -q 'contact-resync.sig' <<<"$RESYNC_BODY"; then
    failure "the contact reader has no change signature, so it would re-sync every contact every tick"
fi

# Axis 4: install.sh must define the scheduler and create the
# com.ostler.contact-resync LaunchAgent with a recurring StartInterval.
if ! grep -q '_schedule_contact_resync()' "$INSTALL_SH"; then
    failure "install.sh does not define _schedule_contact_resync"
fi
if ! grep -q 'com.ostler.contact-resync' "$INSTALL_SH"; then
    failure "install.sh never references the com.ostler.contact-resync agent label"
fi
if ! grep -q 'StartInterval' "$INSTALL_SH"; then
    failure "the re-sync agent has no StartInterval -- it would never retry"
fi

# Axis 5 (REWRITTEN for G3). The reader is scheduled on EVERY install: still
# announced from the pending branches, and quietly after the hydrate when the
# install read worked, so contacts added after today are read too.
if ! grep -B3 '_schedule_contact_resync$' "$INSTALL_SH" | grep -q 'MSG_HYDRATE_CONTACTS_PENDING'; then
    failure "_schedule_contact_resync is no longer announced from the contacts-pending state"
fi
if ! grep -q '^    _schedule_contact_resync quiet$' "$INSTALL_SH"; then
    failure "the contact reader is not scheduled when the install read succeeded, so nothing re-reads contacts"
fi

# Axis 6: the customer-facing string must exist.
if [[ -f "$STRINGS_SH" ]]; then
    if ! grep -q 'MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED=' "$STRINGS_SH"; then
        failure "MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED string is missing"
    fi
else
    failure "install.sh.strings.en-GB.sh missing"
fi

# Axis 7: the uninstaller must boot out AND remove the agent plist.
# These used to grep for two HARD-CODED lines naming this one agent. The
# uninstaller was since refactored to a label ARRAY plus a generic loop, which
# is strictly better -- it cannot forget an agent -- and that refactor is what
# "broke" this test. Asserting an IMPLEMENTATION rather than a BEHAVIOUR is why
# it was marked UNWIRED instead of updated.
#
# Assert the behaviour: the label is in the list, and the list is consumed by a
# loop that boots the agent out AND removes its plist.
# grep -c, NOT grep -q. Under `set -o pipefail` a short-circuiting consumer
# inverts a MATCH into a non-zero pipeline status whenever the producer is still
# writing: it dies EPIPE and pipefail takes its status. This awk emits ~31 lines
# so it currently finishes first and the assertion works -- but that is safety
# by SIZE, not by construction. Grow the label array and this flips to a false
# RED with nobody having touched the assertion.
# See tests/test_pipefail_shortcircuit_inversion.sh.
_resync_in_labels="$(awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/,/^\)/' "$INSTALL_SH" \
    | grep -cE '^[[:space:]]*com\.ostler\.contact-resync[[:space:]]*$' || true)"
if [[ "${_resync_in_labels:-0}" -eq 0 ]]; then
    failure "com.ostler.contact-resync is not in OSTLER_LAUNCHAGENT_LABELS, so the uninstaller loop never sees it"
fi
if ! grep -q 'launchctl bootout "gui/\$(id -u)/\${_label}"' "$INSTALL_SH"; then
    failure "the uninstaller has no generic bootout loop over OSTLER_LAUNCHAGENT_LABELS"
fi
if ! grep -q 'rm -f "\${HOME}/Library/LaunchAgents/\${_label}.plist"' "$INSTALL_SH"; then
    failure "the uninstaller's loop does not remove each agent's plist"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_contact_resync_scheduled: FAILED" >&2
    exit 1
fi
echo "test_contact_resync_scheduled: contact reader wired (wrapper + abcddb fallback + permanent change-signature agent + scheduled on every install + string + uninstaller)"
