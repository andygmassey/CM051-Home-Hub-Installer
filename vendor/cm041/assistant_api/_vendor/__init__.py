"""CM051-local vendored dependencies for the assistant API server.

This directory is a CM051 GRAFT. It does not exist in CM041 at this tree's
pinned_sha.

Unlike the contact_syncer copy of this idea, the import spelling here matches
upstream CM041 exactly (``_vendor.ostler_usage_journal.usage_journal``), and
for a reason worth stating rather than leaving to coincidence: ical-server.py
is executed as a SCRIPT, not as a package module, so the directory holding it
is sys.path[0]. install.sh stages this tree with
``cp -R "${SCRIPT_DIR}/assistant_api/." "$ICAL_SERVER_DIR/"``, which copies the
directory CONTENTS, so this ``_vendor`` lands as a sibling of ical-server.py
and resolves as a top-level package. No install.sh change is needed.
"""
