"""The usage-journal writer, vendored for the assistant API server.

``usage_journal.py`` in this directory is a BYTE-IDENTICAL copy of
``vendor/ostler_fda/usage_journal.py`` in this same repo. sha256 of both is

    27cae1e3c764dc4f7cbcd06b7355a557c7e9638a4c2abbbc4dfd26053400bc5e

DO NOT EDIT usage_journal.py IN PLACE; re-copy it from
vendor/ostler_fda/usage_journal.py instead. The equality is asserted by
tests/test_cm041_usage_journal_producer.sh, so an edit here goes red rather
than silently forking this copy from the one that is proven by execution in
tests/test_vendored_fda_writes_the_usage_journal.sh.

WHY A COPY AND NOT AN IMPORT. ical-server.py runs from ICAL_SERVER_DIR under a
launchd agent. ostler_fda is not staged there -- the only repo-root companions
install.sh places beside this tree are pwg_privacy.py and ostler_hygiene/. So
the writer has to travel with the server that calls it.

The upstream CM041 copy carries a two-line vendoring header and therefore
hashes differently (33f1d8a5...) while its BODY is identical. This copy omits
that header so the whole-file digest is checkable directly against its source.
"""
