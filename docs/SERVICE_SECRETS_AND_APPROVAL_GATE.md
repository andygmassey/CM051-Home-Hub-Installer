# Service secrets and the approval gate (v1.0.103 security pass)

**Status:** design. Written 2026-09-26 from measurements on a working install
(macstudio). Nothing here is built except where it says so. Source of the ask:
the Muse comparison in HR015 `launch/PROACTIVE_ASSISTANT_NOTE_2026-09-26.md`.

Two threats, kept apart because they need different fixes:

- **Another account on the same Mac** (see `THREAT_MODEL_LOCAL_USERS.md`).
  MERGED in this PR where it was measured open: `~/.ostler` 0700 on every path
  (#2407), the assistant LaunchAgent plist 0600 (#2408).
- **The assistant itself, hijacked** (prompt injection through a message,
  email or web page). It runs as the customer's own uid. This is the Muse
  "secrets outside the cell" property, and Ostler does not have it today.

## 1. Where every service secret is, and who reads it

Measured on macstudio by searching `~/.ostler`, `~/Library/LaunchAgents` and
the assistant config for each secret's VALUE (values never printed):

| secret | plaintext copies | consumers |
|---|---|---|
| `secrets/oxigraph_token` | `secrets/store-curl.conf`, `ostler-store-auth.conf` | nginx store proxy INSIDE the colima VM (reads the conf file), `lib/ostler_store_auth.py`, cm059 editor, walk probes |
| `secrets/qdrant_api_key` | `.env`, `config/.env`, `secrets/store-curl.conf` | docker compose interpolation into the qdrant container (VM), cm059 editor, walk probes |
| `secrets/redis_password` | `.env` (`REDIS_AUTH_ARGS`), `config/.env` | docker compose (valkey in the VM), Doctor `web_ui.py` |
| `secrets/service_token` | 3 LaunchAgent plists (assistant, doctor, ical-server) as `PWG_SERVICE_TOKEN` | daemon pwg_* tools (env, file fallback), ical-server, Doctor proxy, cm052 wire, cm059 editor, context-refresh, walk probes |
| `secrets/zeroclaw_admin_token` | `assistant-config/config.toml` `[gateway].paired_tokens` | the daemon (reads the TOML), Doctor `chat_token.py`, walk probes |
| `JWT_SECRET` in `.env` | none other | cm019 ingest `api.py` (not running on the measured box: 0 processes) |

## 2. Why nothing moved to the Keychain today (#2412)

Moving a file into the Keychain removes a plaintext copy only if EVERY copy
moves. Every secret above has a consumer that cannot read the Keychain as
shipped: the store proxy and the containers live inside the colima VM and read
files or compose-time env; the daemon reads its token from `config.toml`; three
Python services take the token from launchd env. Moving the `secrets/` file
alone would leave the same value in plaintext elsewhere and break a consumer
this pass cannot prove on a box today. Per the brief, each is left and listed.

The Keychain would also not stop the hijacked-assistant threat. The shipped
Seatbelt policy allows `mach-lookup` of `com.apple.SecurityServer`, and any
item a launchd wrapper can read through `/usr/bin/security` can be read the
same way by a sandboxed shell running as the same uid. So "move to Keychain"
buys "not plaintext at rest", not "outside the cell". (Instrument limit: the
login Keychain refuses writes over ssh, "User interaction is not allowed", so
the Keychain half of that claim is reasoned from the policy text, NOT
INSTRUMENTED on the box.)

## 3. What actually lets the assistant reach the secrets (#2411, measured)

The daemon builds its Seatbelt policy with the workspace set to its CURRENT
DIRECTORY, and the LaunchAgent sets `WorkingDirectory` to `$HOME`. The policy
also allows reading every dot-path in every home folder (a regex on the Users root followed by a dot). Probed on macstudio with the
policy rendered from `crates/zeroclaw-runtime/src/security/seatbelt.rs` and
workspace = `$HOME` (the value measured in the live policy file):

| under `sandbox-exec` with the shipped policy | result |
|---|---|
| read `~/.ostler/secrets/service_token` | 64 of 64 bytes |
| read the `JWT_SECRET` line of `~/.ostler/.env` | 1 line |
| read the assistant LaunchAgent plist | readable |
| write into `~/Library/LaunchAgents` | ALLOWED |
| CONTROL: read the macOS Shared folder (outside the allow-list) | denied |
| CONTROL: network to example.com | denied |

The sandbox is live (both controls denied) but it covers the whole home
folder. Today's exposure is limited because Hub chat and the messaging
channels exclude `shell` (`[autonomy].non_cli_excluded_tools`, #2385), so this
is reachable from the CLI and from any path that still offers `shell`.

**MERGED in ostler-ai/ostler-assistant#419** (merged 9dcce771; it reaches customers
only in a hub build pinned into a cut). The sandbox now takes the CONFIGURED
workspace, never the process's cwd, and refuses `$HOME`, `/`, and any ancestor
of `~/.ostler`. The policy denies `~/.ostler`, `~/.ssh` and `~/.gnupg`, then
re-allows a workspace inside `~/.ostler`, and ends with the secret denials and
the LaunchAgents write denial. Same probes, new policy: 0 bytes from every
secret, `~/.ssh` 0 entries, and writes to LaunchAgents, next to the daemon
binary, to a home dotfile and to `~/.ostler/bin` all denied. Workspace and
`/tmp` writes are still allowed, and both controls are still denied.

## 4. Out-of-process approval gate (#2413, design only, not built)

Today tool approval is a function inside the assistant
(`crates/zeroclaw-runtime/src/approval/mod.rs`, called from
`agent/tool_execution.rs`). A hijacked assistant process is also its own
approver.

Design:

1. **A separate small process, `ostler-sentinel`**, its own LaunchAgent, its
   own binary, no model, no network. It listens on a Unix socket in a 0700
   directory the assistant can connect to but not read around.
2. **It holds the outbound credentials, not the assistant.** Sending a
   message, email or HTTP request with a service token goes THROUGH the
   sentinel: the assistant sends an intent (`send_message{channel, to,
   text}`), the sentinel applies policy and performs the action with a
   credential the assistant never sees. This is what makes it more than a
   second opinion: a hijacked assistant that skips the sentinel has no
   credential to act with.
3. **Policy lives with the sentinel**, in a file the assistant's sandbox
   cannot write: allow-listed recipients (the customer's own handles, known
   contacts) pass; a new recipient, a bulk send, any outbound to a host not on
   the egress inventory, or anything the privacy level marks L3 is held and
   the customer is asked on a surface the assistant does not draw (a macOS
   notification from the sentinel, or the Hub app).
4. **Every decision is appended to a log the assistant cannot write**, so a
   customer can see what was sent and what was stopped.
5. **Fail closed:** sentinel down means outbound actions are refused and the
   assistant says so; it never falls back to acting directly.

Order of work: (a) the policy fix in section 3 (merged, #419); (b) the sentinel for outbound messaging, the highest-harm action; (c)
move service tokens behind it, at which point the Keychain question in
section 2 becomes "the sentinel's Keychain item, readable only by the
sentinel's signed binary", which is the version that actually keeps secrets
outside the cell.
