# doctor: background engine size row (CM051, 2026-11-14)

Hand-recorded. Location and shape only.

Edits to the vendored Doctor (`vendor/doctor/agent/`):
- `vm_size_row.py` is NEW (a vendor-only graft).
- `status_collector.py`: the `vm_size_row` import, the `background_engine` field on `SystemSnapshot`, and one line in `collect_full_snapshot`.
- `diagnostic_rules.py`: `check_background_engine_size` and its entry in `ALL_RULES`.

Source of truth is HR015 `doctor/agent/`. These edits are NOT yet ported there. Until they are, `scripts/verify_vendor_fresh.sh` will report drift on the two shared files. The fix is to port them to HR015 and run `scripts/sync_vendor.sh doctor --regen-patch`. Do not hand-edit a patch.
