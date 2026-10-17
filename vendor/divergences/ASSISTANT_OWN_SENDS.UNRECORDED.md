# The assistant's own sends are dropped by the conversation readers

**Hand-built 2026-10-14. Location and shape only, never content.**

Trees: `imessage_source`, `whatsapp_source`, `email_source` (this file), and
`ostler_fda` (recorded in `WRITER_READER_MISMATCHES.UNRECORDED.md`, the record
that tree already points at).

## What changed, per file

| tree | file | change |
|---|---|---|
| `imessage_source` | `reader.py` | new `ASSISTANT_SEND_PREFIX`, `ASSISTANT_SEND_MARKER`, `is_assistant_send()`; `extract_messages` skips rows it matches and logs a count |
| `ostler_fda` | `imessage.py` | the same constants and predicate; `extract_messages` skips matching rows |
| `whatsapp_source` | `reader.py` | imports `is_assistant_send` from `ostler_fda.imessage`; `_read_bodies_for_chat` skips matching bodies |
| `email_source` | `reader.py` | imports the same predicate; `read_messages` skips a message whose body matches |

## Why

The morning brief and the evening wrap go out by iMessage to the owner's own
number, from the owner's Apple ID, so chat.db stores them as `is_from_me=1`
and the readers bundled them as the owner speaking. Walk #27 (Mini16,
2026-10-14): 141 such sends plus 148 inbound copies, 9 bundles, 7 facts.

The marker is what the sender stamps: ostler-assistant
`crates/zeroclaw-channels/src/imessage.rs` prefixes every outbound iMessage
with the identity prefix (default the robot emoji), and its own echo guard
already treats a leading robot emoji as the assistant's. The invisible
`ASSISTANT_SEND_MARKER` is appended at send time by ostler-assistant (separate
PR) so a customer who empties the visible prefix is still covered.

## The rule (revised in review, same PR)

`is_assistant_send(text, from_owner)`: the invisible marker counts in any
direction; the robot-emoji prefix counts only on a row the owner's own
account sent (iMessage `is_from_me=1` or the inbound copy in the owner's
self-chat; WhatsApp `ZISFROMME=1`; email From the owner's address, passed as
`read_messages(user_address=...)`). A contact's message that opens with the
same emoji is kept.

## Why there is no patch

`scripts/regenerate_divergence_patch.sh <tree>` was run (dry) on 2026-10-14
with `HR015` and `CM040` pointed at local checkouts:

| tree | outcome |
|---|---|
| `whatsapp_source` | **REFUSED**: the proposed patch carries an email-shaped value on the source side |
| `imessage_source` | would record ~500 lines of earlier, unrelated, unrecorded drift (tick throttle, #789) as deliberate; not mine to bless |
| `email_source` | same shape as `imessage_source` |

Test: `tests/test_assistant_sends_are_not_owner_input.py`.
Upstream mirror owed: CM040 `services/imessage_source/reader.py`, HR015
`whatsapp_source/reader.py`, `email_source/reader.py`, `ostler_fda/imessage.py`.

---

## whatsapp_source: the read window is remembered per chat (status-honesty sweep V6)

`vendor/whatsapp_source/pipeline.py`: state gains `windows` (chat id to the
`since_days` it was last dispatched with). A chat whose newest message is
already bundled is still re-dispatched when the tick's window is wider than the
recorded one (0 means no limit); a chat with no recorded window is re-read once
by a tick of 30 days or more, never by the 2-day daytime clamp. WHY: the clamp
moved the watermark to the newest message, so the busiest chats kept 2 days.

### What a future sync must preserve

The `windows` state key and the widen test. Guarded by
`vendor/whatsapp_source/tests/test_whatsapp_clamp_window.py` (workflow
`status-honesty-ingest.yml`).
## Reply-debt snapshot written by the signed feed (CM051 #30, studio29), tree imessage_source

Tree `imessage_source`, file `vendor/imessage_source/pipeline.py`. Recorded by
hand: this tree's divergence is already carried here, so a regenerated patch
would mix this change with the assistant-send graft above.

- NEW `REPLY_DEBT_SNAPSHOT_SCHEMA`, `reply_debt_snapshot_path()`,
  `_write_snapshot_atomic()`, `build_reply_debt_snapshot()` and
  `write_reply_debt_snapshot()` above `process_imessage`;
- `process_imessage` gains `snapshot_path=None` and, unless `dry_run`, writes
  the snapshot BEFORE the dispatch loop (own 90-day window, not the throttled
  `since_days`). With an explicit `state_path` and no `snapshot_path` it writes
  beside the state file, so a test never writes into the real engine room.

WHY: ical-server's `/api/v1/reply-debt` opened `~/Library/Messages/chat.db` from
a bare python3.11, which TCC attributes to python3.11 and denies (the customer
was asked to grant Full Disk Access to "python3.11"). This feed already runs as
`ostler-assistant run-source imessage`, under the signed assistant's grant, so
it now writes the last message per recent thread (text capped at 500 chars,
direction, sender handle, timestamp) to
`~/.ostler/state/reply_debt/imessage_threads.json` (0600, dir 0700). An
unreadable chat.db is written as `status: unreadable`, never as an empty list.

Guarded by `tests/test_reply_debt_never_opens_protected_data.py`, wired into
`.github/workflows/reply-debt-never-reads-protected-data.yml`. Upstream: CM040
needs the same change, or a re-sync of this tree deletes the producer and the
Hub reports "couldn't check" forever.
## Full-history catch-up adapters (v1.0.108, catch-up 2/6)

Two NEW vendor-side files, no change to any existing file in either tree:

- Tree `imessage_source`: `vendor/imessage_source/catchup.py`. Walks every
  chat in chat.db back to its first message for `lib/ostler_catchup.py`,
  starting below the forward feed's newest-2,000 window for a chat it has a
  watermark for. Sessions are cut by `threader.thread_messages` (same ids as
  the forward feed), assistant sends dropped by the reader's own predicate,
  dispatched through `pipeline._dispatch_to_cm048`.
- Tree `whatsapp_source`: `vendor/whatsapp_source/catchup.py`. Same walk per
  in-tier (T1/T2) chat below the forward bundle's window; one bundle per
  6-hour-gap session; ids from `renderer.conversation_id_for`. T3 stays
  skipped.

Neither has an upstream counterpart yet (CM040 `services/imessage_source`,
HR015 `whatsapp_source`). Guarded by `tests/test_catchup_messages.py`, wired
in `.github/workflows/catchup-messages.yml`. A future sync must keep both files.
## The first iMessage bundle window widens when the default holds too little (#30)

Tree `imessage_source`, `vendor/imessage_source/pipeline.py`: new `_widen_first_window`, `_install_running` and the `FIRST_WINDOW_*` constants, and one call in `process_imessage`. Not an assistant-send change; recorded here because this is the record the manifest declares for this tree. The conversation bundles are read from chat.db with `--since-days 30` and a forward watermark, so a sparse owner got 0 on day one; on the FIRST tick only, if the window holds under 2,000 messages and under 50 threads it widens backwards until either is met (not during the install, not past 180 s, not when OSTLER_IMESSAGE_SINCE_DAYS is pinned).

### What a future sync must preserve

`_widen_first_window` and its call. Guarded by `tests/test_first_window_end_to_end.py`. Retire by landing the change upstream (CM040) and re-pinning.

## The first mail BUNDLE window widens when the default holds too little (#30)

Tree `email_source`, `vendor/email_source/pipeline.py`: new `_widen_first_window`, `_install_running` and the `FIRST_WINDOW_*` constants, and one call in `process_email`. Not an assistant-send change; recorded here because this is the record the manifest declares for this tree. The mail bundle tick reads `--since-days 30` (2 in the daytime clamp), so a sparse mailbox got 0 thread bundles on day one. On the FIRST tick only, if the window holds under 2,000 messages and under 50 threads it widens backwards until either is met (not during the install, not past 180 s, not when OSTLER_EMAIL_SINCE_DAYS is pinned).

### What a future sync must preserve

`_widen_first_window` and its call. Guarded by `tests/test_first_window_end_to_end.py` (wired in `.github/workflows/catchup-machinery.yml`). Retire by landing the change upstream and re-pinning.

## v1.0.108 licence hardening (DECLARED 2026-10-17)

Three trees that point here also diverge for v1.0.108 in their bundle tick
wrappers (Rule 0.8 now FAILS CLOSED on a missing/erroring gate + writes a
Doctor-red gate_posture marker; the answered-pause exit-3 path is unchanged):

- email_source -- bin/email-bundle-tick.sh
- imessage_source -- bin/imessage-bundle-tick.sh
- whatsapp_source -- bin/whatsapp-bundle-tick.sh

Patch not regenerable on the PR runner (#1961). Full record + shape:
vendor/divergences/v1_0_108_licence_hardening.UNRECORDED.md.
