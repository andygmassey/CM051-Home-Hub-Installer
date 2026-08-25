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

# Axis 3: the wrapper must be self-removing AND bounded, so a Mac that
# never finishes syncing can never keep the agent alive forever.
if ! grep -q 'remove_self' "$INSTALL_SH"; then
    failure "wrapper does not self-remove its agent on success"
fi
if ! grep -q 'CONTACT_RESYNC_MAX_TRIES' "$INSTALL_SH"; then
    failure "wrapper does not bound its retries -- could run indefinitely"
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

# Axis 5: the scheduler must be GATED on the pending state, i.e. called
# from inside a branch, not unconditionally at top level. Assert it is
# invoked next to the pending message, never on the success branch.
if ! grep -B3 '_schedule_contact_resync$' "$INSTALL_SH" | grep -q 'MSG_HYDRATE_CONTACTS_PENDING'; then
    failure "_schedule_contact_resync is not gated on the contacts-pending state"
fi
# Guard against scheduling on the happy path: the DONE branch must not
# schedule a re-sync.
if grep -A2 'MSG_HYDRATE_CONTACTS_DONE' "$INSTALL_SH" | grep -q '_schedule_contact_resync'; then
    failure "re-sync is scheduled even when contacts imported successfully"
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
if ! awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/,/^\)/' "$INSTALL_SH" \
        | grep -qE '^[[:space:]]*com\.ostler\.contact-resync[[:space:]]*$'; then
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
echo "test_contact_resync_scheduled: contact re-sync wired (wrapper + abcddb fallback + self-removing/bounded agent + pending-gated + string + uninstaller)"
