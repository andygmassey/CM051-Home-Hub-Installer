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

## 2026-11-11: user-facing root moved to ~/Ostler (CM051 #3429), email_source

Not in the patch (`email_source.patch` is not changed by #3429). Each edit is one line of path text, `~/Documents/Ostler` becoming `~/Ostler`:

- `INSTALL_HANDOFF_SPEC.md`, `__init__.py`, `pipeline.py`: one docstring or prose line each.
- `bin/email-bundle-tick.sh`: one comment line.
- `launchd/com.creativemachines.ostler.email-bundle.plist`: one plist text line.

Upstream: NO PR. The pin `5d31073d` is not on HR015's `main`. It lives only in the archived tag `archive/2026-08-06/feat/4-artefact-email-source`. A PR would mean re-adding the archived tree to main; not done here.
