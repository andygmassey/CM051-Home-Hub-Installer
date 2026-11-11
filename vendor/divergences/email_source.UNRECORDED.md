# email_source: divergences not in the patch

## 2026-11-05: the email feed writes the reply-debt snapshot (tree email_source)

Tree `email_source`. Regeneration not used: the dry run
(`HR015=~/Developer/HR015-Gaming-PC scripts/regenerate_divergence_patch.sh email_source`)
would rewrite 1316 lines of the existing patch, not only this change.

- `reader.py`: `EmailMessage` gains `headers` (only List-Id, List-Unsubscribe,
  Auto-Submitted, Precedence, X-Spam-Flag, X-Spam-Status, X-Autoreply,
  X-Auto-Response-Suppress; 200 chars each) and `mailbox` (the `.mbox` folders on
  the file's path, e.g. "Junk").
- `pipeline.py`: new `reply_debt_snapshot_path`, `build_reply_debt_snapshot`,
  `write_reply_debt_snapshot`, `_reply_debt_messages`; `process_email` writes the
  snapshot right after its read (a new `snapshot_path` argument; beside `state_path`
  when that is moved), reading a 14-day window when the tick's own is narrower (the
  daytime clamp is 2 days). Per thread: hashed thread id, subject (200), the last
  message's From/To/Cc addresses, text (1500), time, direction, the headers above,
  mailbox, whether the owner wrote in the thread, the operator's privacy level. Never
  a From display name. A read the tick cannot do is `status: unreadable`.

Read by CM048 `reply_debt_sources` (cm048_pipeline record, same date). Proof:
`tests/test_reply_debt_whatsapp_email.py`. Owed upstream: HR015 email_source.

## 2026-11-11: reply-debt snapshot learns the owner's addresses from Sent folders (tree email_source)

Regeneration not used (same reason as 2026-11-05). `pipeline.py`: new `_is_sent_mailbox`,
`owner_address_set` (configured comma-separated addresses plus the From of every message
filed under a Sent folder); `build_reply_debt_snapshot` uses the set for `owner_wrote`,
`is_from_me`, privacy-level exclusion and `owner_addresses`. Reads From only; no new body
or recipient data enters the snapshot. Test: `vendor/email_source/tests/test_reply_debt_sent_mail.py`.
