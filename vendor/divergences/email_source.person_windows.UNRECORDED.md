# email_source: person_windows added in the CM051 vendor tree (2026-11-15)

New files, not an edit to an upstream file:
- vendor/email_source/person_windows.py (aggregate core, same algorithm and contract as CM040 imessage_source/person_windows.py and CM048 src/person_signals.py; plus windows_from_emails)
- vendor/email_source/tests/test_person_windows_email.py
- vendor/email_source/tests/test_person_windows_algorithm_email.py
- vendor/email_source/tests/fixtures/person_windows_contract.json (byte-identical to the CM048 and CM040 fixtures)

Upstream: the pin is HR015 5d31073 (branch gone; commit reachable). This file is not in that pin. Owed upstream when the email source is next re-homed.

Not wired: nothing calls windows_from_emails yet. The wiring into the reply-debt snapshot writer happens at the post-tag re-vendor (BACKLOG POST-TAG-2).
