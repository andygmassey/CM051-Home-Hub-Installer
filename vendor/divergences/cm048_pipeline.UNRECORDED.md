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

## Participants roster: display names only (walk #23)

`vendor/cm048_pipeline/src/enrichment_validation.py` gains
`sanitise_participants_section`, called in `src/processor.py` at both enrich
paths just before `strip_reminders_sidecar`. The prompts show the model
`{user_name} (user)` / `{other_name} (...)` as a roster shape; the model copied
the tags and an unresolved participant's display is its raw number, so the wiki
(which renders the summary verbatim; CM044 adds no tags) showed
"Owner (user) (user) +<number> (other_name) (new acquaintance, ...".
The roster bullets are now de-duplicated display names: owner as "You", a
number or address resolved through `metadata.participants` display, else
"an unknown contact". Not in the patch (source has advanced past the pin).
Test: `tests/test_cm048_participants_line_display_names_only.py`.

## Body scaffolding scrub (shape sweep 2026-10-12), tree cm048_pipeline

`enrichment_validation.scrub_scaffolding` runs inside
`sanitise_participants_section` (so processor.py is untouched). It strips
Ostler's own copied role tags (exact "(user)", "(other)", "(other_name)",
"(user_name)", "(other:<slug>)") from the whole enrichment body, and replaces a
participant's raw number/address, only when it equals a metadata participant
identifier, with that participant's resolved display name or "an unknown
contact". Other numbers/addresses and other parentheticals are left alone.
Not in the patch (source has advanced past the pin).
Test: `tests/test_customer_leak_shapes.py`.

## Reminder thread_key from counterpart HANDLES, matching the assistant daemon (walk #25, 2026-10-13)

Tree `cm048_pipeline`:

- `src/conversation_writer.py`: `ConversationBundle.participant_handles`
  (tuple, default empty; never rendered into an artefact).
- `src/channel_adapter.py`: the iMessage adapter fills it from the
  threader's participant dicts (`handle` / `jid`, role `user` skipped) via
  new `_counterpart_handles`.
- `src/reminders_push.py`: `thread_key_for` hashes the handles (else the
  handle inside a 1:1 chat guid `<service>;-;<handle>`, else the labels as
  before); `_norm_identity` uses ASCII digits only.

WHY: ostler-assistant's follow-up sweep (`thread_key_for_identities`,
crates/ostler-reminders/src/followup.rs) hashes chat.db's counterpart
handles. CM048 hashed slugged display names, so walk #25's
`followup_keys_match_chat_threads` found 0 of 6 keyed rows matching any
thread and "mark done when the owner follows up" could never fire.

### What a future sync must preserve

The three edits above, byte-identical normalisation to the Rust
`norm_identity`, and the reference vectors in
`tests/test_cm048_thread_key_matches_the_daemon.py` (computed from oa
644b6137; the regeneration command is in that file's docstring).
Upstream CM048 needs the same change.


## A gateway chat's assistant turns are not extracted about the owner (CM051 v1.0.107 F&F blocker, Mini16 #27)

Tree `cm048_pipeline`, file `src/processor.py`:

- new `_is_gateway_conversation`, `_gateway_assistant_labels`,
  `_owner_turns_only` and `_extraction_transcript`, plus `import re`;
- `_step_facts` passes the raw transcript through `_extraction_transcript`
  before building the 05 prompt;
- `_step_enrich` passes its transcript through `_extraction_transcript`
  before chunking and building the 02 prompts;
- `_step_bundle` passes `_extraction_transcript(transcript, metadata)` to
  `bundle_extractor.extract`. The `transcript` handed to
  `channel_adapter.make_bundle` (the rendered transcript artefact) is
  unchanged, as is `00_raw_transcript.md`.

WHY: a gateway conversation (metadata `source: gateway`, provenance
`source_kind: zeroclaw_gateway`, ids `zg-*`) is the owner chatting with their
own assistant. Fact extraction read the whole transcript, so the assistant's
replies, guesses and test-persona answers included, were extracted as facts
with subject=user and chat repeated them back. Measured by Archie on the box:
66 gateway facts, 45 subject=user, 15 located only in Assistant turns, 0 of
those in User turns. Turns are identified from the producer's structure
(CM052 `wire.render_transcript`: one `**<label>:**` header per message), and
only headers naming a real speaker open a turn.

SHARED INPUT, DECIDED: the bundle's summary, topics and todos come from ONE
LLM call on one input, so for gateway all three read the owner's turns only.
Chosen over leaving the bundle unfiltered because its topics are written into
the graph (`topic_writer`) where the assistant's topics tool reads them back,
which is the same defect class. `_step_enrich` (step 02) reads the same
filtered transcript (Archie, #2865 review): its Action items table becomes the
`outstanding_todos` sidecar and its text seeds the step 09 topics, so an
unfiltered enrichment would carry an assistant guess into both.

Not attempted against the regeneration tool: this tree is `verify = "skip"`,
see the first section. Guarded by
`tests/test_cm048_gateway_extracts_owner_turns_only.py`, wired into
`.github/workflows/cm048-participants-as-strings.yml`. Upstream: no CM048 PR
opened with this graft (the gate does not require one); an upstream mirror is
owed before this tree is re-pinned, or a re-pin deletes the fix.

## A fact about another person's family is theirs, not the owner's (DMG #27)

NEW FILE `vendor/cm048_pipeline/src/attribution.py` (`speaker_turns`,
`speaker_of`, `reattribute`); `vendor/cm048_pipeline/src/processor.py` imports
it and `_step_facts` calls `attribution.reattribute(facts, raw_transcript,
metadata)` straight after `_fix_speaker_subjects`.

WHY: the walk's assistant summarised another person's family event as the
owner's own parent's. The local model labels a first-person line ("my dad's
...") `subject: "user"` whoever wrote it. The post-check moves a
`subject: "user"` fact to `other:<id>` only when its evidence is found in
exactly one known non-owner participant's turns and is first person without
second person, or when the owner's own line names another participant's
relative ("Bob's mum"); the owner's name in the fact text is replaced by the
person concerned's. Everything ambiguous is left as the model produced it.
Turns are read from the producers' shapes (iMessage `**Name** (ts): body`,
WhatsApp `**Name** (ts):` + body lines, gateway `**label:** body`).

Guarded by `tests/test_cm048_third_party_facts_keep_their_subject.py`, wired
into `.github/workflows/cm048-participants-as-strings.yml`. Upstream: no CM048
PR opened; an upstream mirror is owed before this tree is re-pinned, or a
re-pin deletes the fix.

## Reply debt reads the signed feed's snapshot, never chat.db (CM051 #30, studio29)

Tree `cm048_pipeline`. Files `vendor/cm048_pipeline/src/reply_debt_adapters.py`
and `vendor/cm048_pipeline/src/reply_debt_service.py`.

- `reply_debt_adapters.py`: the chat.db reader (`sqlite3.connect` on
  `~/Library/Messages/chat.db`, `CHAT_DB_DEFAULT`, `_apple_ts_to_dt`) is
  REMOVED. NEW `ReplyDebtSourceUnavailable(reason, detail)`,
  `imessage_snapshot_path()`, `load_imessage_threads()`; `iter_imessage_threads`
  keeps its name and now loads the snapshot eagerly. Missing, unreadable,
  malformed, stale (default 6h, `OSTLER_REPLY_DEBT_MAX_AGE_HOURS`) or
  `status: unreadable` snapshots RAISE; `status: absent` (no chat.db on the Mac)
  is a true zero.
- `reply_debt_adapters.py`, review follow-up: NEW `imessage_connection_state()`
  (+ `IMESSAGE_CONSENT_TICKBOX`, `IMESSAGE_FEED_LABEL`,
  `imessage_feed_plist_path()`). Before the snapshot is read, the install's
  own decision is read: the durable consent record
  (`ostler_security.consent.read_consent("third_party_data_personal_records")`,
  decision `accepted`) and the feed LaunchAgent
  `~/Library/LaunchAgents/com.creativemachines.ostler.imessage-bundle.plist`.
  Either missing raises reason `imessage_not_connected` (never "couldn't
  check"); an unreadable registry raises `imessage_connection_unknown`.
- `reply_debt_service.py`: `compute_reply_debts` no longer logs and skips a
  failing source (that is what turned "could not look" into "nothing owed");
  it re-raises as `ReplyDebtSourceUnavailable`. `reply_debt_payload` carries
  `degraded: False`; NEW `degraded_payload()`; the `handle_reply_debt` shim
  returns `degraded: true` + `reason` and no all-clear.

WHY: this code runs inside ical-server, a bare python3.11 under launchd, so its
chat.db open was attributed by TCC to python3.11 and denied, and the endpoint
then said "you're all caught up". Not attempted against the regeneration tool:
this tree is `verify = "skip"`. Guarded by
`tests/test_reply_debt_never_opens_protected_data.py`, wired into
`.github/workflows/reply-debt-never-reads-protected-data.yml`. Upstream: CM048
needs the same change before this tree is re-pinned, or a re-pin restores the
chat.db read.
## `pwg-convo process` exits 75 when the model or gateway cannot be reached (CM051 #2903, Ostler #30, 2026-10-15)

Tree `cm048_pipeline`, files `src/processor.py` and `src/cli.py`:

- new `SinkUnavailableError(RuntimeError)` and `_is_sink_unreachable(exc)`
  (refused or reset connection, connect timeout, 502/503/504);
  `_run_step` raises it in place of the generic `RuntimeError` for those;
- `cmd_process` catches it and returns 75 (EX_TEMPFAIL). Every other failure
  keeps its old exit code, so 1 still means "this item was rejected".

WHY: the catch-up adapters count a non-zero exit as one poison attempt toward
quarantine. An outage of Ollama or the gateway therefore quarantined history
windows after a few ticks. 75 lets them stop without counting an attempt.
Test: `tests/test_cm048_exit_75_when_the_sink_is_unreachable.py`.


## A single-speaker capture is a memo, and pipeline-known frontmatter is stamped (Mini16 2026-10-15, v1.0.108)

Tree `cm048_pipeline`:

- new `src/capture_truth.py`: `speaker_labels`, `is_single_speaker_capture`,
  `as_memo`, `utc_now_iso`, `stamp_frontmatter`, `scrub_solo_body`;
- new prompt `prompts/02_enrich_voice_memo.md`, its heading list in
  `src/enrichment_validation.py` (`EXPECTED_HEADINGS_BY_PROMPT`), and the
  `shape == "memo"` route in `src/prompts.py` (`enrichment_prompt_name_for`);
- `src/schemas.py`: `Shape` gains `"memo"`;
- `src/processor.py`: `process()` overrides and persists the classification of
  a single-speaker capture; `_should_run_relationship` / `_should_run_coach`
  skip a memo; `_step_enrich_inner` calls `_stamp_capture_truth` before both
  `out_path.write_text(rendered)` sites; `_build_enrichment_input` names no
  "other" for a memo and its SECTION STRUCTURE REMINDER now lists the routed
  variant's own headings (it hard-coded work_one-on-one's eight for every
  variant).
- `src/capture_truth.py` `stamp_frontmatter` also writes `participants` from
  the capture's roster for EVERY conversation that sent one (the prompt's
  example roster gives each person a copied role).
- `src/channel_adapter.py`: `_resolve_timestamps` reads the CM031 envelope's
  `start_time` / `end_time` before the date-only fallback; the spoken
  adapter's `source_subtype` defaults to `voice_memo`, not `meeting`, for a
  memo.
- `src/processor.py` `process()`: a single-speaker capture with any words in
  it is ALWAYS kept; a model answer of `processing_depth: none` is overridden
  to `full`. `prompts/01_classify.md` no longer tells the model to skip a solo
  voice memo (it did, so a memo the model obeyed on was silently never
  written).
- `src/capture_truth.py` `has_speech` / `speech_words`: a spoken capture
  with fewer than two spoken words once labels, markers and Whisper's
  silence phrases are stripped is held at `processing_depth: none` by
  `process()`, whatever the model said. A solo memo's speaker is written as
  the owner (`settings.user_display_name`, else "You"), not "S1".
- `_stamp_capture_truth` runs right after heading validation, so the
  placeholder strip stays within 15 lines of each write
  (`tests/test_placeholder_strip.sh`).

WHY: a one-speaker iPhone voice memo on Mini16 was written to
`~/Documents/Ostler/Conversations/<id>.md` (verbatim copy of 02_enrichment.md
by `ingest._write_conversation_md`) as a two-person call: a second participant
with a role copied from the social_casual prompt's roster example, an inferred
"voice call" location, `enrichment_completed_at` padded to midnight,
`enrichment_model` copied from the prompt template (a 35B label on a box whose
settings and Ollama had only a 2B model), and `conversation_id: N/A`.

Not attempted against the regeneration tool: this tree is `verify = "skip"`,
see the first section. No upstream CM048 PR yet; port it with the other #30
divergences (v108 BOARD row "port #30 vendor divergences upstream").

### What a future sync must preserve

All of the above. Guarded by `tests/test_cm048_single_speaker_capture_is_a_memo.py`
(drives `processor.process` and `ingest._write_conversation_md`), wired into
`.github/workflows/cm048-participants-as-strings.yml`.

## 2026-10-17 v1.0.108 batch 1: cm048_pipeline handle resolution (CM048 #87, ec77efbb), grafted with synthetic examples

Tree: `cm048_pipeline`. Pin HELD at 436c89c1; ec77efbb added to `hold_ack_shas` (grafted, pin held).

- new file `vendor/cm048_pipeline/src/handle_resolver.py`: upstream `src/handle_resolver.py` at ec77efbb, except two docstring values.
- `vendor/cm048_pipeline/src/processor.py`: the upstream ec77efbb hunk (import plus the post-privacy, non-L3 `_handle_resolver.resolve` call) applied with patch(1), except two comment values.
- The replaced values are a real contact's name and phone number that upstream quotes as its motivating example. This repo is public, so they are the approved cast name and an Ofcom drama-range number. No code token differs from upstream.
- Why not `sync_vendor.sh`: a sync to ec77efbb would copy the real values into this public tree, and the regenerated patch would carry them on its minus side.
- Retire: CM048 #88 makes the same substitution upstream. When it merges, the vendored files equal upstream byte-for-byte; re-pin past #88 and this section is history.
- Proof: `tests/test_cm048_handle_resolver.py` (15 tests: synthetic port of upstream's 13 plus a real-HTTP arm against a loopback store, 200 and 401). Red on the pre-graft tree: collection error without `handle_resolver.py`, and the non-L3 resolution test fails without the processor hook.
