# ostler_fda: Person creation only for two-way mail correspondents (UNRECORDED)

Graft on vendor/ostler_fda (pin 90fb07b). NOT yet in vendor/divergences/ostler_fda.patch.

`scripts/regenerate_divergence_patch.sh ostler_fda` REFUSES this change: it reads
the source-pin gap as a re-pin and will not record it. The patch must be
regenerated after the re-pin lands.

Upstream source of the same change: andygmassey/HR015-Gaming-PC #1494.

Files touched:
- apple_mail.py: `exchange_counts()` (uncapped, both directions, owner from Sent mailboxes or OSTLER_USER_EMAIL) added before `frequent_contacts`.
- pwg_ingest.py: `is_two_way_correspondent()`; `ingest_mail_contacts` reads `apple_mail_exchange.json` and creates a Person only for two-way addresses. The owner, machine, role and forgotten gates still apply. The MAIL_CONTACT_MIN_COUNT inbound rule is removed.
- extract_all.py: writes `apple_mail_exchange.json` beside `apple_mail_contacts.json`.

Known consumer gap: universal_import (mbox takeout) still stages only the sender-count map, so takeout imports create no mail Persons until it stages exchange counts.

Proof: the upstream tests (HR015 #1494, 8 RED on origin/main, 9 with the role-isolation test, six mutants killed) pass against this vendored copy when the store lookups are stubbed. The vendored tree has no tests of its own.
