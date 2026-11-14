# ostler_fda: divergence not captured by the patch (ingest contract, 2026-10-22)

`ostler_fda` has a generated patch (`ostler_fda.patch`). This file records ONE
further hand edit made after it, so the divergence gate has something to find.
Regenerating the patch was not attempted: its source ($HR015/ostler_fda) has
advanced past the pinned sha, which `regenerate_divergence_patch.sh` refuses as
a re-pin and not a graft.

## What changed

`vendor/ostler_fda/pwg_ingest.py`:

- New helpers `_compartment_int`, `_owner_user_id`, `_iso_or_none`, directly
  after `DEFAULT_PRIVACY`.
- `ingest_bookmarks`: `compartment_level` is an int (was the string "L2"),
  `observed_at` is the bookmark's `date_added` or None (was the import time),
  `extra.observed_at_known` added, `user_id` set when the owner is known.
- `ingest_social`: same level and owner change; `observed_at` is the latest
  `last_message` over the handle's 1:1 conversations (was the import time).

## Why it matters

Derivation decays from `observed_at` and attributes by `user_id`. Measured on
a walk box 2026-10-22: 4,723 bookmark points and 37 iMessage points carried
the import time as their event time, had no `user_id`, and stored the level as
a string while every CM019 writer stores an int.

## Owed upstream

Yes: HR015 `ostler_fda/pwg_ingest.py`. Retire this file when the same change
lands there and the tree is re-pinned past it.

## 2026-10-24: I22, the calendar ingest writes the calendar's all-day flag

`vendor/ostler_fda/pwg_ingest.py`, `ingest_calendar`, in the Meeting-node triples right
after `pwg:meetingDate`. When the extract row carries a bool `is_all_day` (every row
`extract_all.py` writes does, from `CalendarEvent.is_all_day`), the node gains
`pwg:meetingAllDay "true"|"false"^^xsd:boolean`. Nothing else changes.

Why: `meetingDate` is the full start. Without the flag the Timeline could not tell a timed
meeting from an all-day item, and the app showed every past meeting as "All day" (I22, F&F
TestFlight walk 2026-10-24). The reader half is the cm041/assistant_api graft of the same date.

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, the same seven lines (HR015 PR linked
from CM051's I22 PR). Retire when it lands there and the tree is re-pinned past it.

## 2026-10-24: I22b, one-time all-day backfill for Meeting nodes written before I22

New file `vendor/ostler_fda/allday_backfill.py`, called once from the hourly tick in
`install.sh` after `ingest_all`, only when that tick's calendar extract was `ok`. It adds
`pwg:meetingAllDay` to `pwg:Meeting` nodes that have none, matched to a wide (5 year)
re-read of the calendar by the same uuid5 `ingest_calendar` uses. Adds only: no deletes,
no rewrite of an existing flag, no new Meeting or Person. Marker
`~/.ostler/state/allday_backfill_v1.done`; failures write no marker and retry next tick.

Why: the tick re-ingests only the extract window, so older all-day Meetings stay unflagged
and the Timeline shows them as timed.

Owed upstream: yes, HR015 `ostler_fda/allday_backfill.py`. Retire when it lands there and
the tree is re-pinned past it.

## 2026-10-24: strip tracking params at ingest (CM051 #3043; upstream HR015 #1176, OPEN)

Pin NOT moved. Grafted ahead of the upstream merge. Upstream head at graft:
HR015 #1176 5c9f5eae.

- `url_clean.py`: NEW file, byte-identical to `ostler_fda/url_clean.py` at 5c9f5eae
  (diff -q against the upstream blob: identical, 106 lines). `strip_tracking(url)`
  removes known tracking params (utm_*, fbclid, gclid, host-scoped si/spm, text
  fragments); a URL with nothing to strip is returned byte-identical.
- `chrome_history.py`, `safari_history.py`, `safari_bookmarks.py`: one import of
  `strip_tracking` and the read of each row's url wrapped in it (one line each).
- `pwg_ingest.py`: one import; `ingest_browser_history` and the bookmarks ingest wrap
  the url read in `strip_tracking`, so the point id (the dedupe key) is the cleaned
  url, which also cleans JSON files written by an older extractor.
- Proof: `tests/test_url_clean.py` (copy parity with the cm041 copy, readers, sink
  dedupe, 4 mutants) and `tests/test_backfill_strip_tracking_urls.py`, wired in
  `url-clean.yml`.
- Retire: when HR015 #1176 merges, re-pin past it; these edits are then source.

## ingest_food (2026-10-23, food evidence for smart preferences)

- `pwg_ingest.py`: new `ingest_food(fda_dir)` and one `_INGEST_DISPATCH` entry
  `("food", "ingest_food")`, placed after `bookmarks`. It writes NO point itself. It links
  (symlink, no copy of the large mail export) exactly the extracts the CM019
  `food_evidence` parser claims (`calendar_events.json`, `apple_mail.json`,
  `safari_history.json`, `safari_bookmarks.json`, and `imports/email/*.mbox.txt`) into a temp
  dir and calls the existing `apple_music_refresh.run_cm019_ingest` once. The writer, the
  privacy filter and the embed stay CM019's: one writer path.
- Counts only: status ok, error or no_data, and the number staged.
- Proof: `tests/test_vendored_food_evidence_reaches_smart_preferences.py` (wired in
  `derived-preferences.yml`), RED on main (no `ingest_food`), GREEN here.
- Retire: when the same function lands in HR015 `ostler_fda/pwg_ingest.py` (follow-up, size S)
  and the tree is re-pinned past it.

## 2026-10-24: I22, the calendar ingest writes the calendar's all-day flag

`vendor/ostler_fda/pwg_ingest.py`, `ingest_calendar`, in the Meeting-node triples right
after `pwg:meetingDate`. When the extract row carries a bool `is_all_day` (every row
`extract_all.py` writes does, from `CalendarEvent.is_all_day`), the node gains
`pwg:meetingAllDay "true"|"false"^^xsd:boolean`. Nothing else changes.

Why: `meetingDate` is the full start. Without the flag the Timeline could not tell a timed
meeting from an all-day item, and the app showed every past meeting as "All day" (I22, F&F
TestFlight walk 2026-10-24). The reader half is the cm041/assistant_api graft of the same date.

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, the same seven lines (HR015 PR linked
from CM051's I22 PR). Retire when it lands there and the tree is re-pinned past it.

## 2026-10-29: NEW-119, ingest_imessage reports the volume it read

`vendor/ostler_fda/pwg_ingest.py`, `ingest_imessage`, return dict only. Two new keys,
`conversations_read` (conversations in `imessage_conversations.json`) and `messages_read`
(sum of their `message_count`). `people_created` / `people_enriched` and every write are
unchanged.

Why: install.sh's iMessage sentinel was built from people_created + people_enriched only, so a
run that read messages and met nobody new recorded `status=no_data`. Measured, Mini 16 diag118
rerun A, 2026-10-29: 54 conversations / 84,826 messages read, `imessage.done` said no_data.
install.sh now puts both counts in the sentinel payload, so a non-zero read records `ok`.
Proof: `tests/test_read_messages_are_not_no_data.py` (hydrate-sentinel.yml).

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, the same return keys. Retire when it
lands there and the tree is re-pinned past it.

## 2026-10-30 (v1.0.121): dedupe_merge email-twin pass

Tree `ostler_fda`, file `dedupe_merge.py`. New `merge_email_twins`, called at
the end of `run()` (result keys `email_twins_merged`,
`email_twins_shared_refused`, `email_twins_name_differs`,
`email_twins_unreadable`). An address-only Person (the email ingest's shape:
bare `pwg:email`, provisional name, no `pwg:hasIdentifier`) folds into the ONE
live person holding that address as an `email` identifier, when its name is
not human or is the same full name. A shared address or a different human
name joins nobody. Measured on the v1.0.120 walk box (Mini16, counts only):
691 live address-only nodes, 33 sharing their address with a live
identifier-holding node; the walk's People check failed on one of them.

Every fold is a merge like the others: journalled BEFORE the first write
through `identity_resolver.merge_journal.record_merge` (found in the import
pipeline; no journal, no fold), then the `mergedInto` tombstone, then the
twin's people vector deleted (`merge_journal.delete_person_points`, CM051
#3235). `tick_email_twins()` runs the pass from the hourly fda-rerun tick
(the python block install.sh writes into `~/.ostler/bin/ostler-fda`), so
twins minted after install are folded within the hour, not at the next
upgrade. The tick is capped (`TICK_MAX_EMAIL_TWIN_FOLDS` = 25, override
`OSTLER_EMAIL_TWIN_MAX_FOLDS`): at most 25 folds a tick, the rest deferred
and counted on the tick's line. Names compare by `_name_key` (casefold plus
whitespace collapse), so a case- or whitespace-only difference is the same
name and a suffix ("Jr") is a different one.

Proof: `tests/test_email_named_twin_folds_into_the_card_holder.py` and
`tests/test_fda_tick_folds_a_post_install_email_twin.py` (both wired in
`.github/workflows/dedupe-merge-rule-2.yml`).

Owed upstream: yes, HR015 `ostler_fda/dedupe_merge.py`, the same pass. Retire
when it lands there and the tree is re-pinned past it.

## 2026-10-30: v1.0.121, the install-time call can defer food and names what failed

`vendor/ostler_fda/pwg_ingest.py`:

- `DEFERRABLE_AT_INSTALL = frozenset({"food"})`, and `ingest_all(fda_dir, defer=())`:
  a deferred dispatch entry is not called and is recorded as
  `{"status": "deferred", "reason": "runs_on_the_hourly_ingest_tick"}`.
- `main()` gains `--defer <name>` (choices: `DEFERRABLE_AT_INSTALL`) and
  `--failed-out <path>`, which writes the failing dispatch keys one per line
  (empty file when none). Exit codes are unchanged.
- `_timing_line`: `ingest_all` prints `[ingest-timing] source=<k> phase=start|end|deferred
  at=<UTC> [elapsed_s=<n> status=<s>]` to stdout for every dispatch entry, so the
  hourly tick's fda-rerun.log carries each source's duration.

Why: the v1.0.120 cold walk (16 GB Mac) ran the whole dispatch inside the install's
WhatsApp hydrate leg; `ingest_food` hit the 900 s CM019 ingest cap, the CLI exited 1,
hydrate_graph closed rc 1 and the warning blamed WhatsApp. install.sh now passes
`--defer food` and names failures from `--failed-out`. The hourly tick
(com.ostler.fda-rerun) still calls `ingest_all(fda_dir)` with nothing deferred.
Proof: tests/test_hydrate_graph_food_deferred.sh (bash32-compat.yml).

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`.

### v1.0.121 addendum: food cadence

`food_due(ostler_dir, now=None)` with `FOOD_MIN_INTERVAL_S` (24 h) and
`FOOD_FIRST_AFTER_INSTALL_S` (6 h): reads `state/install_completed_at` (epoch,
written once at the end of install) and `last_run_at`/`last_status` from
`state/source_activity/food.tsv`, never an mtime. The fda-rerun tick (install.sh,
between `# food-gate-begin` and `# food-gate-end`) drops food from its dispatch when
not due, so no food row is written and the last completed stamp survives.

## 2026-10-30: repair_overmerged_contact_cards.py DELETED (RULE 2 exception ratified)

`vendor/ostler_fda/repair_overmerged_contact_cards.py` is deleted, with its test
`tests/test_repair_overmerged_contact_cards.py` and its only workflow
`.github/workflows/contact-card-repair.yml`. Last commit that touched the file:
`d1b0367d3f6b5d0a93fbdd8cc9c055ccc1f3e298` (recover it with
`git show d1b0367d3f6b5d0a93fbdd8cc9c055ccc1f3e298:vendor/ostler_fda/repair_overmerged_contact_cards.py`).

Why: on 2026-10-30 Andy ratified the exact-identifier exception to RULE 2 (two
Contacts cards with the same full name sharing an email, a person-specific phone
or a LinkedIn URL are one person and merge). This module un-merged EVERY Person
node carrying 2+ distinct icloud_contact_uid, so wired to anything it would undo
ratified merges. It was dormant (no caller; DORMANT row in
scripts/fda_unwired_modules.tsv), and dormant code that undoes a ratified rule is
a landmine (Archie, 2026-10-30).

Also removed: its VENDOR_ONLY.tsv row, its fda_unwired_modules.tsv row (the
dormant count in tests/test_fda_module_reachable.sh drops 5 -> 4), and its
new-file hunk in `ostler_fda.patch`, so a sync cannot restore it.

Upstream: none. The file was vendor-only and exists in no HR015 commit, so
nothing is owed upstream.

## 2026-11-04: food reads each mbox once; fail-closed prune of consumed mboxes (v1.0.123)

Regeneration REFUSED, measured 2026-11-04: `bash scripts/regenerate_divergence_patch.sh
ostler_fda --write` printed "could not verify ostler_fda: source repo not found
(/ostler_fda)" and "CANNOT RUN -- source repo for ostler_fda is not available".
Same refusal shape as the entries above, so this hand edit is recorded here.

`vendor/ostler_fda/pwg_ingest.py`:

- New constants `FOOD_STATE_REL`, `EMAIL_INGEST_LOG_REL`, `FOOD_TIMEOUT_BASE_S`,
  `FOOD_TIMEOUT_PER_GB_S`, `FOOD_TIMEOUT_CAP_S`, `_HOURLY_MBOX`, `_EMAIL_LOG_LINE`,
  `_MBOX_PATH`, `_INGESTED_OK`, and helpers `food_timeout_s`, `_mbox_key`,
  `_load_food_state`, `_save_food_state`, `_consumed`,
  `email_ingest_last_outcome`, `prune_consumed_mboxes`, directly above
  `ingest_food`.
- `ingest_food`: stages only mboxes not recorded as consumed (name + inode +
  size + mtime_ns), passes a byte-scaled timeout to `run_cm019_ingest`, records
  consumption and prunes only after an ok run, and returns `staged_bytes` and
  `pruned` beside `status` and `staged`.

`vendor/ostler_fda/apple_music_refresh.py` (vendor-only, VENDOR_ONLY.tsv):
`run_cm019_ingest` takes an optional `timeout_s` (default unchanged, 900 s).

Why: walk122 (Mini16 scale fixture), `~/.ostler/imports/email` held 12 GB and
grew ~140 MB an hour with nothing removing it; the daily food step re-read all
of it and timed out under load (fda-rerun exit 1). Tests:
`tests/test_food_mbox_consumed_and_pruned.py`, wired in derived-preferences.yml.

## 2026-11-04: the people index keeps the Contacts card it mirrors (v1.0.123)

Regeneration REFUSED, measured 2026-11-04 (same refusal as the section above:
"source repo for ostler_fda is not available"), so this hand edit is recorded here.

`vendor/ostler_fda/pwg_ingest.py`:

- `_load_people_from_oxigraph`: collects each person's `icloud_contact_uid`
  identifier (`card_by_uri`) and returns it as `icloud_uid`.
- `ingest_people_to_qdrant`: the point payload carries `icloud_uid`; new
  helpers `_PRIVACY_RANK`, `_privacy_rank`, `_merge_people_payload` above it.
  The sweep reads the stored points first (`_qdrant_scroll_points`; None means
  the read failed and the sweep returns error `could_not_read_existing` without
  writing), and each upserted payload is the computed one laid over the stored
  one: keys the sweep does not compute (icloud_uid, profile_photo_path,
  created_at, updated_at, ...) are carried over, an empty computed value never
  blanks a stored one, and privacy_level is the stricter of stored and computed
  (unparseable ranks as L3).
- `_qdrant_scroll_points`: a 404 on the first page (no such collection) returns
  `[]` (nothing stored) instead of None (could not look), so a fresh install's
  sweep is not refused before its first write.

Why: walk v1.0.122 diag on Mini16, people_count_agreement FAILED by 100 (graph
11365, Qdrant 11265). This sweep upserts at uuid5(person_uri), the same point
id contact_syncer writes, and a Qdrant upsert replaces the payload, so the card
contact_syncer stamped was erased: 2178 carded graph people, 1 carded point of
11370. 101 of the 105 Qdrant-hidden people differed from the graph ONLY in
has_card. Proof: `tests/test_people_index_keeps_the_contacts_card.py`, wired in
dedupe-merge-rule-2.yml.

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, if HR015 is ever again the
source this tree is cut from.

## 2026-11-06: the people index embeds only who is new or changed (v1.0.126, item h)

Regeneration not attempted, for the reason recorded in the sections above (the
source has advanced past the pin, and HR015's `ingest_people_to_qdrant` is a
different, older implementation), so this hand edit is recorded here.

`vendor/ostler_fda/pwg_ingest.py`:

- New `PEOPLE_EMBED_HASH_KEY` ("embed_text_sha256"), `PEOPLE_INDEX_CHUNK` (200,
  env-overridable), `_embed_text_hash`, `_people_payload` (the payload block moved
  out of the loop unchanged), `_qdrant_set_payloads` (POST
  `/collections/{c}/points/payload`, the call vendored CM041 browsing_enrich already
  makes), and the backlog record helpers `_people_index_state_path`,
  `_people_index_record`, `_people_index_finish` (state/people-index.json, or
  `OSTLER_PEOPLE_INDEX_STATE`).
- `ingest_people_to_qdrant`: reads the stored points FIRST; a person whose stored
  hash equals the hash of the text it would embed is not embedded (its payload is
  still merged and written, payload only, when a non-embedded field moved). New
  people (no point) are embedded before changed ones (hash absent or different), in
  chunks that land as they go. `sent` keeps its meaning for install.sh: people
  whose point is current after the pass. New result keys: `embedded`,
  `already_current`, `payload_refreshed`, `backlog`. Deleted people: the PRUNE is
  unchanged; it now projects from every person in the graph rather than from the
  upserted points, the same set as before.

Why: v1.0.125 walk, the people without a vector grew 240 -> 1789 in 4200 s on a
first-run box because every hourly pass re-embedded every person. Proof:
`tests/test_people_index_embeds_only_what_changed.py`, wired in
dedupe-merge-rule-2.yml.

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, if HR015 is ever again the
source this tree is cut from.

## 2026-11-06: the people prune runs on a partial landing (v1.0.126, Archie on #3367)

`vendor/ostler_fda/pwg_ingest.py`, `ingest_people_to_qdrant`: the PRUNE block moved
unchanged (bar its guard 1 comment) from after the zero-landing and partial-landing
returns to just before them, and `pruned` joins every result through `counts`. The
prune reads the graph only (snapshot and fresh read), so a person whose embed failed
is never stale; holding it back kept deleted and merged-away people searchable while
any backlog persisted. Failed Qdrant calls (ensure, upsert) still return earlier and
prune nothing. Proof: `tests/test_people_index_embeds_only_what_changed.py` (two
prune arms) and the reversed arm in
`tests/test_people_sweep_partial_landing_is_not_success.py`. Owed upstream: as above.

## 2026-11-11: every Python settling writer emits an explicit terminal marker (CM051 #3426, CM044 #429)

`vendor/ostler_fda/calendar.py`, `imessage.py`, `whatsapp_history.py` (and, in the same
PR, the shared helper `settling_progress.py`: `complete` / `skip_reason` params, the
terminal-state block, `status`). CM044's reader now counts ONLY `complete` and `skip_reason`
as terminal, so a final `done == total` emit left the Setting-up bar at 99 on a real box.

- calendar: final emit `complete=True` (only when N > 0). `skip_reason`: `no_calendar`
  (db missing), `permission_denied` (FDA refusal), `no_events` (zero rows). `_emit_settling`
  gains `complete` and `skip_reason`.
- imessage: final emit `complete=True`. `skip_reason`: `no_chat_db`, `permission_denied`,
  `no_messages`. `_emit_settling` gains `complete`.
- whatsapp: final emit `complete=True`. `needs_source=True` on a missing db or FDA denial
  replaced by `skip_reason` `whatsapp_not_installed` / `permission_denied` (a customer
  action nobody revisits must not hold the bar). `_emit_settling` gains `complete`.
- Closes B3 in `docs/setup_progress_terminal_map.md`: a run that finished its window is
  terminal even when `since_days` excluded older rows.

Proof: `tests/test_settling_writers_end_to_end.py` (every writer over a synthetic input in a
temp HOME; the CM044 reader reads exactly 100; with markers stripped it reads 99) and
`tests/test_settling_denominator_terminal_writes.sh` (no Python allowlist).

Owed upstream: yes, HR015 `ostler_fda/` (same four files plus tests): andygmassey/HR015-Gaming-PC#1418, linked from #3426.
Retire this section when it lands and the tree is re-pinned past it.

## v1.0.132: notification and organisation senders are left out of the people index

Walk 131 triage item 2. Not captured by `ostler_fda.patch`; recorded here by hand.

### `vendor/ostler_fda/pwg_ingest.py`

- New module-level block after `DEFAULT_PRIVACY`: the `_SVC_*` regexes and
  `service_sender_reason(name, phones)`, a copy of the rule the walk's
  people-phrasing probe measures (`scripts/box_walk_probes/lib/customer_read.py`
  `service_sender`). A row with a phone is exempt.
- `ingest_people_to_qdrant()`: rows the rule flags are removed from `people`
  right after `_load_people_from_oxigraph()`, BEFORE the embed. The existing
  prune then removes any point they already held. Logged as a count only.

Shape: one helper block, one filter. No I/O boundary moved, no collection,
point id or vector size changed.

### Why

On the 131 walk box one People row named "<Shop> Receipts"-shaped was a
`pwg:Person` in Oxigraph, was embedded, and surfaced as a person (the probe
read 1 of 8063 at walk time; live 2 of 8571, both two-word, one with an email).

### Owed upstream

Yes: the source of `ostler_fda/pwg_ingest.py` (HR015 `ostler_fda/`). The same
filter is to be made there so the next sync does not revert it. Retire this
section when the upstream commit lands and `sync_vendor.sh ostler_fda` re-pins.

### Pinned by

`tests/test_people_projection_service_senders.py`: the end-to-end projection
drops service senders, keeps synthetic real names and keeps a phone-carrying
card. On the unfixed vendor tree the projection test is red.
