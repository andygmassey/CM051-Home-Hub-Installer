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

## The first iMessage bundle window widens when the default holds too little (#30)

Tree `imessage_source`, `vendor/imessage_source/pipeline.py`: new `_widen_first_window`, `_install_running` and the `FIRST_WINDOW_*` constants, and one call in `process_imessage`. Not an assistant-send change; recorded here because this is the record the manifest declares for this tree. The conversation bundles are read from chat.db with `--since-days 30` and a forward watermark, so a sparse owner got 0 on day one; on the FIRST tick only, if the window holds under 2,000 messages and under 50 threads it widens backwards until either is met (not during the install, not past 180 s, not when OSTLER_IMESSAGE_SINCE_DAYS is pinned).

### What a future sync must preserve

`_widen_first_window` and its call. Guarded by `tests/test_first_window_end_to_end.py`. Retire by landing the change upstream (CM040) and re-pinning.
