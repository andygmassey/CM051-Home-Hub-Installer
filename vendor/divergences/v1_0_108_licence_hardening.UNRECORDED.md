# v1.0.108 licence hardening: divergences the patch tool cannot record here

**DECLARED 2026-10-17 (v1.0.108 licence hardening, CM051).** Location and shape
only, never content.

These are hand grafts made in the vendored trees for the v1.0.108 "Pro =
Proactive, Hub = base" enforcement. The divergence patches CANNOT be
regenerated on the pull request that introduces them: the upstream source
repos (CM041, CM048, HR015, the doctor source) are not resolvable on a PUBLIC
repo's PR runner (#1961), so `regenerate_divergence_patch.sh` has no source@pin
to diff against. This file is the honest record route (c) for every tree
below, so the next `sync_vendor.sh` cannot delete these edits silently.

It is a record, not an instrument: nothing reads it and it cannot be applied.

## Trees and the shape of each edit

- **spoken_source** -- `bin/spoken-bundle-tick.sh`, the Rule 0.8 gate block
  only. Was fail-OPEN on a missing/erroring gate module; now FAILS CLOSED
  (stops ingesting, exit non-zero) and writes a gate_posture marker for a
  Doctor-red row. The answered-pause (exit 3) path is unchanged.
- **imessage_source** -- `bin/imessage-bundle-tick.sh`, same Rule 0.8
  fail-closed graft, same shape.
- **email_source** -- `bin/email-bundle-tick.sh`, same Rule 0.8 fail-closed
  graft, same shape.
- **whatsapp_source** -- `bin/whatsapp-bundle-tick.sh`, same Rule 0.8
  fail-closed graft, same shape.
- **email_ingest** -- `bin/email-ingest-tick.sh`, same Rule 0.8 fail-closed
  graft (log() variant, $OSTLER_DIR-derived gate path), placed before the mbox
  read so a paused checkpoint cannot skip unread mail.
- **cm048_pipeline** -- `src/reminders_push.py`, function
  `apply_push_status_to_todos` and the new `_subscription_paused` helper only:
  the proactive Apple Reminders push now pauses when Ostler Pro is inactive,
  checked after the demo-mode short-circuit and before the mapping DB opens.
- **cm052_ai_conversations** -- `src/cm052/subscription_gate.py`, the shared
  "Pro paused" signal file (`subscription_gated.json`) + the Leak B unverified
  refusal. Kept byte-identical to the cm041 twin (test_the_trial Limb E4 pins
  them equal; cm041's copy is VENDOR_ONLY).
- **doctor** -- `agent/diagnostic_rules.py`, the new rule
  `check_subscription_gate_health` (+ its registration in ALL_RULES): turns a
  gate_posture `gate_unavailable` marker into a critical Doctor row. doctor is
  regenerate_forbidden, so a patch could never have carried it.

Detail of the behaviour lives in the CM051 v1.0.108 licence-hardening commits;
this file only records that these trees legitimately diverge and why the patch
tool could not capture it in this diff.
