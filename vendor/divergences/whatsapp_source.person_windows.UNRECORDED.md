# whatsapp_source: person_windows added in the CM051 vendor tree (2026-11-15)

New files only, no upstream edit:
- vendor/whatsapp_source/person_windows.py (aggregate core, same algorithm and contract as the CM040, CM048 and CM051 email aggregates; plus windows_from_whatsapp)
- vendor/whatsapp_source/tests/test_person_windows_whatsapp.py
- vendor/whatsapp_source/tests/test_person_windows_algorithm_whatsapp.py
- vendor/whatsapp_source/tests/fixtures/person_windows_contract.json (byte-identical to the shared fixture)

Upstream pin: HR015 af4ae658 (branch gone; commit reachable). Not in that pin. Owed upstream when re-homed.

Not wired: nothing calls windows_from_whatsapp yet. Wiring happens at the post-tag re-vendor (BACKLOG POST-TAG-2).
