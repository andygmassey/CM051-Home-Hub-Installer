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
