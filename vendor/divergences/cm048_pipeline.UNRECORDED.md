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


## CM048 #82 graft: resuming from the dispatcher's failed_step no longer raises (CM051 v1.0.107 #11)

Tree `cm048_pipeline`: `src/processor.py` (`process()` normalises an unknown
`resume_from_step` to None) and `src/schemas.py` (`PipelineState.from_dict`
ignores unknown keys). Mirrors CM048 #82, squash sha `6e0c670ee2f9b0c39a30ee23b0b38431ea9f7d3e`, acked in `hold_ack_shas`.

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

## CM048 #83 graft: participants sent as strings no longer crash 01_classify (CM051 v1.0.107 #12)

Tree `cm048_pipeline`: new `src/participants.py` (`normalise_participants`:
a dict passes through, a non-empty str becomes `{"display": s}`, anything
else is dropped); every `metadata["participants"]` reader in
`src/processor.py` (10 sites), `src/ingest.py`, `src/bulk_classifier.py`,
`src/seed.py` and `src/outstanding_todos.py` goes through it; `process()`
normalises in place on entry so `00_metadata.json` persists the dict shape.
`src/channel_adapter.py` already accepted strings and is unchanged. The
changed lines are identical to CM048 PR #83 (`andygmassey/CM048-PWG-
Conversation-Processing#83`), squash sha
`1737cab02b1e97ea41487dffb3162cacaa192006`, acked in `hold_ack_shas`.

WHY: CM031's `APIClient.processEnvelope` sends `metadata.participants` as
`[String]` (the sorted speaker labels); ical-server passes it through, and
`_build_classifier_input` did `p.get(...)` on a str: `AttributeError: 'str'
object has no attribute 'get'` at 01_classify, so every iPhone / Watch
conversation failed (walk #11, live box). Not attempted against the
regeneration tool: this tree is `verify = "skip"` already, see the first
section.

### What a future sync must preserve

`src/participants.py`, the `normalise_participants(...)` call at every
participants reader, and the in-place normalisation at the top of
`process()`. Guarded by `tests/test_cm048_participants_as_strings.py` (CM051
repo root, 4 tests, 4 fail against main), wired into
`.github/workflows/cm048-participants-as-strings.yml`.

## CM048 #85 graft: the reminders_candidates sidecar never reaches the conversation body (CM051 v1.0.107 walk #13)

Tree `cm048_pipeline`: `src/enrichment_validation.py` gains
`strip_reminders_sidecar` (block identical to upstream), and `src/processor.py`
calls it immediately before both `out_path.write_text(rendered)` sites in
`_step_enrich`. Matches CM048 PR #85, squash sha
`6a1858a8df293085e73ae70d21e705fb5d61ee13`, acked in `hold_ack_shas`.

WHY: the enrich prompts ask the model for a `reminders_candidates` sidecar,
and nothing parsed it out of the reply. The key stayed in the Action items
and Commitments body and reached the customer's wiki (People/timeline) as
an internal value. Walk #13 failed `hub_screens_customer_read` on it; the
box carried 21 occurrences in four shapes.

### What a future sync must preserve

`strip_reminders_sidecar` and its two call sites. Guarded by
`tests/test_cm048_reminders_sidecar_never_reaches_the_body.py` (CM051 repo
root, 7 tests; the write-path test fails with the vendored call removed),
wired into `.github/workflows/cm048-participants-as-strings.yml`.

## L2 reminder title drops the raw ISO deadline (CM051, 2026-10-11)

Tree `cm048_pipeline`, file `vendor/cm048_pipeline/src/reminders_push.py`:
`_format_push_title`'s L2 branch returns `base` only. It used to return
`f"{base} -- {todo.deadline}"`, which put "Follow up on conversation --
2026-10-14" in the customer's timeline and wiki digest. The deadline is
unchanged in its own field, `PushDecision.push_deadline` (the reminder's due
date), so nothing is lost. Docstring updated to match.

Not attempted against the regeneration tool: this tree is `verify = "skip"` /
`unverifiable_ack = true`, same state as the grafts above.

### What a future sync must preserve

The L2 branch of `_format_push_title` returning `base` with no deadline
suffix. Guarded by `tests/test_cm048_reminder_title_has_no_iso_date.py` (CM051
repo root, 4 tests, 4 fail against main), wired into
`.github/workflows/cm048-participants-as-strings.yml`.

## A reminder never carries a raw handle, goes to an organisation, or duplicates a thread (CM051, 2026-10-11)

Tree `cm048_pipeline`, file `vendor/cm048_pipeline/src/reminders_push.py`:

- title: private 1:1 L2 whose partner resolves to a person is
  "<Name>: <short text>" (about 60 chars, phone / email / handle / ISO date
  stripped). Unresolved 1:1, multi-party and solo are generic. NEVER a
  handle. L0/L1 titles unchanged. PRIVACY NOTE: by Andy's decision the 1:1
  L2 commitment text now syncs to iCloud with the reminder;
- resolution: `_people_store_record` reads the Qdrant `people` collection
  (the store the Hub People list reads), proxy-free, 3s timeout;
- organisations and automated senders get no push: `is_listed_as_a_person`
  IMPORTS ical-server.py and calls its own predicates
  (`_is_nameless_name`, `_is_role_address_name`, `_is_organisation_name`,
  `_is_automated_or_service_name`, `_is_service_mailbox_name`,
  `_is_non_human_person`) in the order `people_list` applies them. If the
  module cannot be imported the gate FAILS CLOSED (skip reason
  `non_human_predicate_unavailable`, one ERROR log line per run), never "assume a person". Parity with
  `people_list` is pinned by `tests/test_cm048_reminder_push_person_parity.py`;
- dedupe: new `thread_key` column on `reminders_map` (additive ALTER; the
  assistant's REQUIRED_COLUMNS are unaffected), a stable hash of the
  counterpart identities. A todo whose thread already has a pending or
  pushed, not-completed row is skipped (`duplicate_thread`). The key is
  recomputed identically after the map is wiped; the EventKit-side check is
  the assistant repo's half.

WHY: a real-size walk pushed about 65 reminders: 7 of 22 titled with a raw
phone handle, a bank sender and an email handle treated as people, one
person's thread repeated up to 10 times, ~40 bare "Follow up on conversation".

Not attempted against the regeneration tool: `cm048_pipeline` is pinned with
`verify = "skip"` / `unverifiable_ack = true` (see the entry above).
Tests: `tests/test_cm048_reminder_title_has_no_handle.py`,
`tests/test_cm048_reminder_push_thread_and_sender.py`,
`tests/test_cm048_reminder_push_person_parity.py`.

## The People rules load from the INSTALLED layout, and fail OPEN (CM051, 2026-10-12, walk #20 blocker)

Tree `cm048_pipeline`, files `vendor/cm048_pipeline/src/reminders_push.py` and
`vendor/cm048_pipeline/src/ostler_paths.py`:

- `reminders_push` loads the People rules from the stdlib-only
  `people_rules.py` (single source, shared with ical-server.py), laid by
  install.sh 3.10a into `<ostler>/services/shared/`. The path comes from
  `ostler_paths.ostler_root()`, never from `Path(__file__)`: install.sh
  `pip install`s cm048 non-editable into `.venv/lib/python3.X/site-packages`,
  so `__file__.parents[2]` is not the services dir;
- `ostler_root()` now honours `$OSTLER_DIR` like install.sh's own
  `OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"` (default unchanged);
- FAIL OPEN: if the rules cannot load, the todo is still pushed (title uses
  the name when one resolves), the row is flagged `org_filter_unavailable`
  (stored in `skip_reason` on a pending/pushed row), and the run logs ONE
  ERROR naming every path tried, written to stderr AND appended to
  `<ostler>/logs/cm048-reminders.err` (cm048 has no LaunchAgent of its own:
  ical-server captures the CLI's stderr, the bundle ticks each have their
  own .err, so the file is the one findable place). The organisation filter is a quality
  filter, not a privacy one. The `todos_reach_reminders` walk probe FAILs on
  any such row.

Tests: `tests/test_cm048_reminder_push_people_rules_installed_layout.py`
(a temp tree laid out as install.sh does, a fresh interpreter with only
cm048's site-packages; default and overridden OSTLER_DIR) and the parity test
(oracle: the fully imported real ical-server `people_list`).
