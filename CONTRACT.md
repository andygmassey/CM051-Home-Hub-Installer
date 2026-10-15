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
| `email_assistant.owner_addresses_verified` | string list | Owner addresses that have replied to the hello email. Written EMPTY by the installer; the daemon appends an address when the owner completes the handshake (below). |
| `email_assistant.hello_message_id` | string | The `Message-ID` of the hello email, including the angle brackets, as the installer sent it. Written by the installer only when the hello was sent and the id has the shape `<...>` with no quote, backslash, angle bracket or space inside. Absent means no hello went out, so nobody can be verified (the daemon fails closed). |

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
hello_message_id = "<hello1@icloud.example>"
```

## The handshake

The installer sends "Hello from <name>" to the owner and records its
Message-ID in `hello_message_id`. The daemon marks an owner address verified
ONLY for a message that (a) is from an exact `[channels.email] allowed_senders`
entry, (b) passes the same aligned DMARC/DKIM check as any owner mail, and (c)
has the recorded id in its `In-Reply-To` or `References` header (compared
without angle brackets, case-insensitively). The subject is never consulted.
A reply that cites some other message, or any mail when `hello_message_id` is
absent, is dropped as `not_listed`. On success the daemon appends the address
to `owner_addresses_verified` in place and records `owner_verified_at` in the
status file.

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
temporary file, then rename). The daemon is the ONLY writer. The Doctor reads
it and writes nothing here.

```json
{
  "last_inbound_at": "2026-10-15T09:30:00+00:00",
  "last_reply_at": "2026-10-15T09:31:10+00:00",
  "drops_24h": { "not_listed": 2, "automated": 1 },
  "drop_events": [
    { "at": "2026-10-15T09:20:00+00:00", "reason": "not_listed" }
  ],
  "self_test_result": "ok",
  "self_test_at": "2026-10-15T09:00:00+00:00",
  "owner_verified_at": { "owner@example.test": "2026-10-15T08:00:00+00:00" }
}
```

* `drops_24h` maps a reason to a count over the last 24 hours. It is derived
  from `drop_events`.
* `drop_events` is the rolling 24 hour list the counts come from. The daemon
  reloads it on start, so a restart does not reset the counts. It is capped at
  the newest 2000 events.
* `self_test_result` is `ok`, `timeout`, or an error class: `wrong_password`,
  `two_step_off`, `imap_disabled`, `locked`, `network`, `unknown`.
* Times are ISO 8601 with an offset.

### Drop reasons (canonical, the only set the daemon writes)

| Reason | Meaning |
| --- | --- |
| `not_listed` | The sender is not a verified owner address (and not a valid handshake reply). |
| `failed_auth` | The sender is listed, but the message is not aligned DMARC/DKIM authenticated. |
| `automated` | `Auto-Submitted`, list, bulk, bounce, null sender or no-reply mail. |
| `rate_limited` | Over the inbound flood cap. |

The retired names `not_owner`, `loop_guard`, `auth_failed` and `too_large` are
not written by anything. (`too_large` has no producer: add it to this table, to
the daemon and to the fixture together if a size cap is ever added.) The Doctor
shows an unknown reason as written; it never hides one.

### Self-test: one source of truth

"Test now" does not run a test of its own. The Doctor calls the daemon,
`POST http://127.0.0.1:<gateway port>/api/assistant-mailbox/self-test` with the
admin bearer token (`~/.ostler/secrets/zeroclaw_admin_token`), and shows the
reply. The daemon runs the self-send, writes `self_test_result` and
`self_test_at` into its status file, and the Doctor card reads them from there.
If the daemon cannot be reached the Doctor reports `daemon_unreachable`
("Could not check"), never a pass. `~/.ostler/state/email_assistant_selftest.json`
no longer exists. The installer's own self-test during setup (before the daemon
is running) is the install-time check and records nothing.

## The golden fixture (the contract as code)

`tests/fixtures/assistant_mailbox_contract.json` here and
`crates/zeroclaw-channels/tests/fixtures/assistant_mailbox_contract.json` in
ostler-assistant are the SAME BYTES: a sample config block, a status file, the
drop-reason list and the self-test result list. Each side pins the file's
sha256 in its own test (`FIXTURE_SHA256`) and fails if its copy differs, and
each side runs reader and writer conformance against it: the installer's
`_am_emit_config` must reproduce the config block exactly, the Doctor must read
the status file, the daemon must parse the config block, reload the status file
and re-render it unchanged, and each side's reason list must equal the
fixture's. Nothing is fetched over the network.

SYNC RULE: change the fixture in both repos in the same release, then update
`FIXTURE_SHA256` in both tests. A change to one side only fails that side's
pin; a change to both with different bytes fails whichever pin was not updated.

## Doctor

Card "Assistant's own email" (`vendor/doctor/agent/assistant_mailbox.py`):
address and provider, last inbound and last reply, self-test result and age
(from the daemon's status file), drops in 24 h by reason, whether the owner address is confirmed, and the buttons
**Test now**, **Replace password**, **Turn off / Turn on**.

| Route | Effect |
| --- | --- |
| `GET /api/v1/assistant-mailbox` | The row above. No secret. |
| `POST /api/v1/assistant-mailbox/test-now` | Calls the daemon's self-test endpoint (see above). Up to about 75 s. |
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
  finish setting up", and the installer records that mail's Message-ID as
  `hello_message_id`. The owner's reply (daemon side, see The handshake)
  verifies the address.
* `OSTLER_ASSISTANT_MAILBOX=skip` skips the whole step (for unattended walks).
