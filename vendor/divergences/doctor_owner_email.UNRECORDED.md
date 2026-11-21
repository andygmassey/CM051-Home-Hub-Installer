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
- web_ui.py: POST /api/v1/owner-email, behind the vendored owner gate (not in the public list). The row's email field and Save button (server and live-refresh render paths).
- test_owner_email_row.py: 12 arms. Positive arms run as the owner through the gate; the unauthenticated arm does not patch it. The rendered-page arm covers the row, the submit, the 0600 file, and the cleared row.

Proof: 12 arms green on the vendored tree. Five UI and gate mutants, all killed; control green (run with bytecode writes disabled and __pycache__ cleared per mutant). Vendored Doctor agent suite: 30 passed.

Upstream HR015 #1497 carries the same change with a loopback gate in place of the owner gate, since upstream has no owner gate.
