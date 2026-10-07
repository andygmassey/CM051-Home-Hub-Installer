# cm048_pipeline -- unrecorded divergences

This file is this tree's `unrecorded_divergence` pointer
(`vendor/VENDOR_MANIFEST.toml`). It exists for edits that cannot be captured
by `vendor/divergences/cm048_pipeline.patch` -- see each entry for why.

## First graft: a WhatsApp LID stops being written as a phone number (CM051 #2578, 2026-10-01)

Tree `cm048_pipeline`, file `vendor/cm048_pipeline/src/ingest.py`:

- new `_whatsapp_jid_is_genuine_phone(local)`, validating with
  `phonenumbers.is_valid_number` rather than `str.isdigit()`;
- `_normalise_chat_identifier`'s WhatsApp branch calls it before formatting
  a JID's local part as a `"+<digits>"` phone;
- `import phonenumbers` added; `phonenumbers>=8.13.0` added to
  `vendor/cm048_pipeline/pyproject.toml`'s `dependencies` (install.sh's
  `pip install "$_dir"` into the cm048 venv picks this up automatically --
  no install.sh change needed).

Not attempted against the regeneration tool for this change: `cm048_pipeline`
is pinned with `verify = "skip"` / `unverifiable_ack = true` already (this
tree's own round-trip cannot be certified at all, independent of this edit),
and the divergence patch at the pin is already a hand-maintained record for
a tree in that state. Recorded here by location and shape instead, same
discipline as the other per-tree UNRECORDED files in this directory.

WHY: `_normalise_chat_identifier` used `local.isdigit()` to decide whether a
WhatsApp JID's local part was a genuine phone number -- true for both a
real phone-rooted JID and a 14-15 digit linked-device id (LID) presented
through the same `@s.whatsapp.net` suffix. Same bug class as CM051 #2543
(ostler_fda's `pwg_ingest.py`, already shipped with the same discriminator)
and CM051 #2545 (CM041's `identity_resolver.normalise.is_valid_phone`).
Mirrors CM048 PR #80's source-side fix (`andygmassey/CM048-PWG-Conversation-
Processing#80`, open at the time of this graft).

### What a future sync must preserve

`_whatsapp_jid_is_genuine_phone` and its call site inside
`_normalise_chat_identifier`'s `channel == "whatsapp"` branch, plus the
`phonenumbers` import and the `pyproject.toml` dependency line. Guarded by
`tests/test_cm048_whatsapp_lid_not_phone.py` (CM051 repo root, following the
same top-level placement `tests/test_every_conversation_produces_all_four_
artefacts.py` already uses for this same vendored tree), wired into
`.github/workflows/cm048-whatsapp-lid-not-phone.yml`. Retire by landing CM048
PR #80 and re-pinning.


## CM048 #11 graft: resuming from the dispatcher's failed_step no longer raises (CM051 v1.0.107 #11)

Tree `cm048_pipeline`: `src/processor.py` (`process()` normalises an unknown
`resume_from_step` to None) and `src/schemas.py` (`PipelineState.from_dict`
ignores unknown keys). Mirrors CM048 branch `fix/resume-from-a-non-pipeline-
failed-step-v1.0.107-11` (open at time of writing).

WHY: the Hub dispatcher records `failed_step="processor"`, a dispatcher label,
not a pipeline step. `retry` / `retry-all` passed it straight to `process()`,
where `_should_run` did `PIPELINE_STEP_ORDER.index("processor")` and raised
ValueError, so the manual retry crashed on exactly the conversations it
exists for (measured by reproducing it against main: `ValueError: tuple.index(x)
not in tuple`). Not attempted against the regeneration tool: this tree is
`verify = "skip"` already, see the preceding section.

### What a future sync must preserve

The guard at the top of `process()` and the `from_dict` filter. Guarded by
`tests/test_cm048_resume_after_dispatcher_failure.py` (CM051 repo root, 4
tests, 3 fail against main), wired into
`.github/workflows/failed-conversations-auto-retry-guard.yml`.
