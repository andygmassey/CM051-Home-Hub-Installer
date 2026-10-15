# CONTRACT: the assistant's own email address (v1.0.108)

What the installer and the Doctor write, and what the assistant daemon reads.
Everything here is synthetic-safe: examples use `example.test` and made-up
accounts only.

## What the feature is

The customer gives the assistant its OWN email address: a NEW account made just
for the assistant (iCloud recommended, Gmail supported), with an app-specific
password. In this version the assistant **answers email from the owner only**
and **replies as itself**, never as the owner. There is no Ostler-hosted address
and no Google OAuth.

## Config keys (`~/.ostler/assistant-config/config.toml`)

Written by `install.sh` (`_am_emit_config`), section `[email_assistant]`:

| Key | Type | Meaning |
| --- | --- | --- |
| `email_assistant.enabled` | bool | Master switch. The Doctor's on/off flips this. The daemon must treat a missing section or `false` as "do nothing". |
| `email_assistant.address` | string | The assistant's own address, lower-case. Also the IMAP/SMTP user name (for Gmail the sign-in name equals the From address; the installer refuses anything else). |
| `email_assistant.provider` | string | `"icloud"` or `"gmail"`. |
| `email_assistant.imap_host` / `imap_port` | string / int | `imap.mail.me.com` / `993`, or `imap.gmail.com` / `993`. Implicit TLS. |
| `email_assistant.smtp_host` / `smtp_port` | string / int | `smtp.mail.me.com` / `587` (STARTTLS), or `smtp.gmail.com` / `465` (implicit TLS). |
| `email_assistant.secret_ref` | string | Where the password is: `keychain:Ostler Assistant Mailbox:<address>`. See below. **There is no password key.** |
| `email_assistant.owner_addresses_verified` | string list | Owner addresses that have replied to the hello email. Written EMPTY by the installer; the daemon appends an address when the owner replies to the "Hello, this is <name>" email from that address. |

Only these two host pairs are accepted for this section. Outlook and every other
host are refused by the installer and must be refused by the daemon. The owner's
own mailbox (`[channels.email]`) keeps its separate rule: no cloud-provider
password is ever collected for it.

Example (synthetic):

```toml
[email_assistant]
enabled = true
address = "tess.assistant@icloud.com"
provider = "icloud"
imap_host = "imap.mail.me.com"
imap_port = 993
smtp_host = "smtp.mail.me.com"
smtp_port = 587
secret_ref = "keychain:Ostler Assistant Mailbox:tess.assistant@icloud.com"
owner_addresses_verified = []
```

## The secret

* Stored in the macOS login Keychain: **service** `Ostler Assistant Mailbox`,
  **account** = the address. The installer writes it with `security -i` (the
  command arrives on stdin, so it is never on a command line).
* Read it with `security find-generic-password -s "Ostler Assistant Mailbox" -a <address> -w`.
* It is never written to config, never logged, never shown by the Doctor, and
  never returned by any Doctor route. App passwords are 16 lower-case letters.
* `secret_ref` must start `keychain:`; the daemon should refuse any other scheme.

## Who the daemon answers

**Owner only.** Accept a message only when its sender is one of the owner's
addresses (`[channels.email] allowed_senders`, which the installer already
collects) AND the message passes the usual loop guards (ignore `Auto-Submitted`,
`Precedence: bulk`, and mail from the assistant's own address). Anything else is
dropped and counted by reason (below). Replies are sent from `address` with
`From: address`, never from the owner's address.

## State the daemon writes (read by the Doctor)

`~/.ostler/state/email_assistant_status.json`, written atomically (write a
temporary file, then rename):

```json
{
  "last_inbound_at": "2026-10-15T09:30:00+00:00",
  "last_reply_at": "2026-10-15T09:31:10+00:00",
  "drops_24h": { "not_owner": 4, "loop_guard": 1 }
}
```

`drops_24h` maps a reason to a count over the last 24 hours. Suggested reasons:
`not_owner`, `loop_guard`, `auth_failed`, `too_large`. Unknown reasons are shown
as written. Times are ISO 8601.

The Doctor's "Test now" writes its own file,
`~/.ostler/state/email_assistant_selftest.json` (`{"result": "ok", "at": "..."}`),
so it never overwrites the daemon's. `result` is `ok`, `timeout`, or an error
class (`wrong_password`, `two_step_off`, `imap_disabled`, `locked`, `network`,
`unknown`).

## Doctor

Card "Assistant's own email" (`vendor/doctor/agent/assistant_mailbox.py`):
address and provider, last inbound and last reply, self-test result and age,
drops in 24 h by reason, whether the owner address is confirmed, and the buttons
**Test now**, **Replace password**, **Turn off / Turn on**.

| Route | Effect |
| --- | --- |
| `GET /api/v1/assistant-mailbox` | The row above. No secret. |
| `POST /api/v1/assistant-mailbox/test-now` | Self-send with a random token, 60 s. |
| `POST /api/v1/assistant-mailbox/replace-password` | Body `{"password": "..."}`; checked live (IMAP + SMTP login) before the Keychain item is replaced. The response never echoes it. |
| `POST /api/v1/assistant-mailbox/on` and `/off` | Flips `email_assistant.enabled`. The daemon must re-read config (restart) to act on it. |

All POSTs require a Hub-local `Host` and refuse cross-site requests.

## Installer behaviour worth knowing

* One screen per task: choose, create account, two-step, app password, paste and
  validate, guards, test, done. Skip is always available; nothing blocks the install.
* Guards: the owner's own addresses are refused; an inbox with more than 200
  messages or any message older than 14 days needs a second explicit confirm
  ("this looks like a real inbox, not a new account"); for Gmail the sign-in name
  must equal the From address.
* Validation does IMAP login + `SELECT INBOX`, then SMTP AUTH with nothing sent,
  each its own result. A network failure says "Could not check".
* Test: a self-send with a random token must arrive within 60 s; then the
  assistant emails the owner "Hello, this is <name>. Reply with any word to
  finish setting up". The owner's reply (daemon side) verifies the address.
* `OSTLER_ASSISTANT_MAILBOX=skip` skips the whole step (for unattended walks).
