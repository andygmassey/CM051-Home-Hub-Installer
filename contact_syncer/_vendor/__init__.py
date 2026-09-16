"""CM051-local vendored dependencies for the contact_syncer package.

This directory is a CM051 GRAFT. It does not exist in CM041 at this tree's
pinned_sha, and it is deliberately nested INSIDE the package rather than
sitting beside it.

WHY NESTED, when upstream CM041 puts ``_vendor/`` at its repo root.
install.sh stages this pipeline by copying NAMED directories into
PIPELINE_DIR -- ``contact_syncer``, ``meeting_syncer``, ``identity_resolver``,
``pwg_privacy.py`` and ``requirements.txt``, and nothing else (install.sh
around the contact_syncer staging block). A repo-root sibling called
``_vendor`` would therefore never be copied, and the import would fail at
runtime on a customer Mac while passing every check in this repo. Nesting it
inside ``contact_syncer/`` means the existing ``cp -R contact_syncer`` carries
it with no install.sh change at all.

The consequence is the import spelling: ``contact_syncer._vendor...`` here,
where upstream writes ``_vendor...``. See contact_syncer/usage.py.
"""
