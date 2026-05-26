# iMessage bridge `inbox.jsonl` contract

This document is the single source of truth for the on-disk wire shape
the assistant-user iMessage bridge uses. Both the producer
(`bin/bridge.py` in this directory) and the consumer (the reader in
`ostler-assistant/crates/zeroclaw-channels/src/imessage.rs`) write to
this contract. Anything not specified here is undefined behaviour.

## Files

| Path | Owner | Mode | Writer | Reader |
|------|-------|------|--------|--------|
| `/Users/Shared/imessage-bridge/inbox.jsonl` | install user | `0664` | producer (`bridge.py`) | consumer (ostler-assistant) |
| `/Users/Shared/imessage-bridge/state.json` | install user | `0644` | producer (`bridge.py`) | producer only |

## `inbox.jsonl` record

One JSON object per line, UTF-8, newline-terminated. Trailing whitespace
or blank lines are tolerated and skipped by the reader.

```json
{
  "rowid": 12345,
  "sender": "+447700900100",
  "text": "Hello.",
  "timestamp": 1716712345
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `rowid` | integer | yes | iMessage `message.ROWID`. Used by the producer for de-dup + ordering. The reader prefixes message IDs with `bridge-` for downstream tracing. |
| `sender` | string | yes | Phone number (E.164 or local) or email address of the remote party. Must be non-empty; the reader drops records with an empty sender. |
| `text` | string | yes | Message body. Must be non-empty after trimming; the reader drops attachment-only or whitespace-only records. |
| `timestamp` | integer | optional | Unix epoch seconds. If absent, the reader stamps the current wall-clock time at consume. |

## Drain semantics

The reader drains the file every poll cycle and truncates the file in
place. Producers MUST append in 'a' mode (POSIX append; atomic per
`write(2)`) and MUST NOT delete or move `inbox.jsonl`.

A truncated file (`size == 0`) is equivalent to "no new messages" and
the producer is free to append immediately on the next tick.

## Producer idempotency

The producer persists the highest emitted `rowid` to `state.json` after
each successful append, so a restart never re-emits history the
consumer has already drained.

```json
{ "last_rowid": 12345 }
```

If `state.json` is missing or unreadable, the producer resumes from
ROWID 0 (effectively re-emit all inbound messages on next tick). The
reader is then responsible for de-duplicating via its own seen-id set
if duplicates would harm downstream state.

## Privacy

Neither the producer nor the consumer logs message bodies, phone
numbers, or email addresses at INFO level. INFO-level logs contain
counts only. Trace-level logs may include sender for diagnostics on a
developer machine; production launchd output is INFO and above only.

## British English

All log output and inline documentation is British English. No em-dashes
in any customer-visible string.
