# doctor: owner email row, distinct couldn't-check row, owner-email setter (UNRECORDED)

Graft on vendor/doctor/agent (HR015 #1497 is the upstream change). NOT in any divergence patch.

`scripts/regenerate_divergence_patch.sh` must NOT be run on this tree for this change: the
constraint is that a regenerate re-describes the whole vendored tree and would fold unrelated
drift into a permanent claim. Record it by hand until the re-pin lands.

Files touched:
- banner_copy.py: OWNER_EMAIL_UNKNOWN and OWNER_EMAIL_UNREADABLE copy (no technical words).
- diagnostic_rules.py: check_owner_email, registered in ALL_RULES.
- status_collector.py: SystemSnapshot.owner_addresses_state, read from owner_addresses.json.
- owner_email.py: read and 0600 write of the owner address file. New.
- web_ui.py: POST /api/v1/owner-email, behind the vendored owner gate (not in the public list).
- test_owner_email_row.py: 11 arms. The route arm is adapted to the owner gate, which the upstream tree lacks.

Proof: 11 arms green on the vendored tree. Six mutants, all killed; control green. Vendored Doctor agent suite: 29 passed.
