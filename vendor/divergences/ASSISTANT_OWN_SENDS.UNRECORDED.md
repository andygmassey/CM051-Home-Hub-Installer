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
