"""The usage-journal writer, vendored for the contact_syncer pipeline.

``usage_journal.py`` in this directory is a BYTE-IDENTICAL copy of
``vendor/ostler_fda/usage_journal.py`` in this same repo. sha256 of both is

    27cae1e3c764dc4f7cbcd06b7355a557c7e9638a4c2abbbc4dfd26053400bc5e

DO NOT EDIT usage_journal.py IN PLACE. It is a copy, and the property that
makes it safe is that it is a copy of a file which already ships and is
already tested (tests/test_vendored_fda_writes_the_usage_journal.sh proves the
ostler_fda copy writes a record BY EXECUTION). Re-copy it from
vendor/ostler_fda/usage_journal.py when that file changes; the equality is
asserted by tests/test_cm041_usage_journal_producer.sh, so an edit here goes
red rather than silently forking the reader and the writer.

WHY A COPY AND NOT AN IMPORT. contact_syncer runs from PIPELINE_DIR and
ostler_fda is never staged there. install.sh says so in its own words at the
settling-progress writer block: "neither has ostler_fda on its path (this
script copies contact_syncer, meeting_syncer and identity_resolver into
PIPELINE_DIR -- never ostler_fda)". So the writer has to travel with the
package that calls it.

NOTE ON THE DIGEST, because upstream's differs. CM041's own copy at
_vendor/ostler_usage_journal/usage_journal.py carries a two-line vendoring
header and therefore hashes differently (33f1d8a5...) while its BODY is
identical. This copy omits that header on purpose, so the whole-file digest
is checkable against the file it was copied from with no offset arithmetic.
"""
