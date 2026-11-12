# Setting-up bar: terminal map

Every source in the Setting-up denominator, the code that writes its shard,
every terminal write with its file:line, the condition that fires it, and the
skip reasons. Measured by reading code at `38c8cf21` (+ this PR). Line numbers
are for that tree.

The fixed channel set (the bar's denominator) is `lib/settling_channels.json`,
installed to `~/.ostler/state/settling_channels.json`. It is the only list of
channels in CM051. CM044 `compiler/hydration.py` reads the same file at runtime,
and `tests/test_settling_denominator_terminal_writes.sh` fails with DISAGREE if
the file and the writer MANIFEST name different channels.

The bar is the MEAN of per-channel fractions over that fixed set. A channel
with no shard counts as open at 0. A terminal channel counts as 1. Any other
channel counts as `max(running max, done/total)`, so the bar never falls when a
total grows. The running max is persisted in `~/.ostler/state/settling_bar.json`
and resets only on a fresh install. 100 only when every fixed channel is
terminal. Shards outside the fixed set (notes, today) are listed, not counted.

## BLOCKERS

**B1. RESOLVED in CM044 (PR #429).** The reader no longer clamps to 99 when every fixed channel is terminal, and counts ONLY explicit markers (`complete`, `skip_reason`) as terminal. That is why every Python writer below must emit a marker: `done == total` alone reads open and holds the bar at 99.

**B2. Emails has no progress writer, so it cannot advance during a walk.**
The emails shard is written only by the hourly tick's terminal calls
(`email-bundle-tick.sh:373` complete, `:371`/`:227`/`:362`/`:363` skip).
Nothing writes an intermediate `done`. On a box with a backlog (Mini16:
17080 of 121262) `setup_progress_advancing` **FAILs emails by design** until
the backlog clears or the tick completes. The producer needs per-tick `done`
writes from `email_source.pipeline`. Not in this PR.

**B3. RESOLVED here.** The final iMessage and WhatsApp emits now carry `complete=True`, so a run that finished its window is terminal even when `since_days` excluded older rows (`done < total`). Older chats are not ingested by that run; a later run that measures a larger total re-opens the shard. Proof: `tests/test_settling_writers_end_to_end.py` (a fixture with one out-of-window chat per source reads exactly 100).

**B4. A later zero-count write can falsely complete a shard (found, not fixed).**
`lib/settling_progress.sh` (`settling_report`, the non-terminal branch) sets
`total = max(OSTLER_SETTLING_TOTAL, done)`. It ignores `prev_total`. Measured:
`settling_report emails 17080 121262` then `settling_report emails 0 0 true`
leaves `done=17080 total=17080`, which reads 100%. The install calls
`settling_report emails 0 0 true` at `install.sh:37118`, `:37127`, `:37230`.
A re-run install over a box that already has a backlog shard hits this. The
fix is one line (`total = max(total_in, prev_total, done)`), outside this PR's
scope.

**B5. STALE (corrected 2026-11-12): notes DOES have a writer, and it never marks the shard terminal.** The Evernote import writes `notes.json` (`vendor/doctor/agent/import_evernote_runner.py:~271`, `vendor/doctor/agent/import_evernote.py:339`) with `done == total` and no `complete=True`, so the shard stays open after a successful import. The probe no longer judges it (notes is not in `lib/settling_channels.json`); the writer fix is owed to v1.0.131. The original text follows and is wrong about "no writer".

**B5 (original, superseded). Notes has no writer in any reachable repo.** No producer in CM051,
CM044 or CM041 writes `notes.json`. The Evernote producer, if any, lives in
HR015, which is not checked out here. Absent shard = not in the denominator.
If HR015 writes `notes` with `needs_source:true` and `total:0`, it does not
move the bar. It does fail the walk probe (not terminal, not advancing).

## Sources

### 1. contacts  (one producer in this tree)

| Terminal write | file:line | Condition |
|---|---|---|
| `settling_report_measured contacts <PROCESSED> false` then `settling_complete contacts` | `install.sh:36416`, `:36417` | `_HYDRATE_CONTACTS_COUNT -gt 0` (`:36415`). Measured total from the address book (`lib/settling_progress.sh` `settling_source_total contacts`). |
| `settling_skip contacts no_contacts` | `install.sh:36419` | `_HYDRATE_CONTACTS_COUNT` is 0. Also taken when the count is **unmeasured** (`:36370`, sets count to 0). Caveat: an unmeasured count is recorded as `no_contacts`. |

Reachable: yes, every time the contacts phase runs. Non-terminal writes: none.
Skip reasons: `no_contacts` (only).

Note: CM041 upstream (`~/Developer/orm/CM041/contact_syncer/syncer.py:57,69`)
also writes `contacts.json`. The CM051 vendored copy (`vendor/cm041`) does not.
If upstream is re-vendored, the one-producer rule breaks.

### 2. emails  (one terminal producer: the hourly tick)

| Terminal write | file:line | Condition |
|---|---|---|
| `settling_skip emails mail_absent` | `email-bundle-tick.sh:227` | no `~/Library/Mail` before the pipeline runs |
| `settling_skip emails mail_absent` | `:362` | pipeline rc 1 (FileNotFoundError) |
| `settling_skip emails mail_unreadable` | `:363` | pipeline rc 2 (PermissionError, no Full Disk Access) |
| `settling_skip emails no_messages` | `:371` | rc 0, not clamped, summary `threads_scanned == 0` |
| `settling_complete emails` | `:373` | rc 0, not clamped, `threads_scanned > 0`, and `dispatched + seeded + failed == 0` |

Non-terminal (no write, or a write that stays open):
- Clamped daytime run (`:201-207`, window outside `OSTLER_INGEST_QUIET_START`..`END`, default 23:00-07:00). Terminal writes are suppressed (`:365`).
- Pending work (`dispatched`, `seeded` or `failed` > 0): no write.
- Other pipeline rc (`:379` `exit "$_ostler_rc"`): no write.
- Installer `settling_report emails 0 0 true` at `install.sh:37118`, `:37127`, `:37230` (needs_source, `total:0`). See B4.
- Installer `settling_report_measured emails <MSGS> false` at `install.sh:37105`, `:37112`: sets a measured `total`, not terminal.
- Counter-unmeasured arm (`install.sh:37060`): writes **nothing**, by design (comment `:37064`).

Reachable: only on an overnight, unclamped run with nothing pending. On a backlog
the shard stays open (B2).

Skip reasons: `mail_absent`, `mail_unreadable`, `no_messages`.

### 3. calendar  (python, one producer: `vendor/ostler_fda/calendar.py`)

| Write | Where | Condition |
|---|---|---|
| `skip_reason="no_calendar"` | `extract_events`, db not found | no Calendar database; raises FileNotFoundError after |
| `skip_reason="permission_denied"` | `extract_events`, FDA refusal | raises PermissionError after |
| `skip_reason="no_events"` | after the query | zero rows in the window |
| `_emit_settling(done=0, total=N)` | start | N > 0 |
| throttled `_emit_settling(done=i, total=N)` | per row | every row at `done == total` or 30 s |
| final `_emit_settling(done=N, total=N, complete=True)` | end of extract | **terminal**, always on a completed extract with N > 0 |

An exception between the start emit and the final leaves the shard open at `i/N`.

### 4. messages.imessage  (python: `vendor/ostler_fda/imessage.py`)

| Write | Where | Condition |
|---|---|---|
| `skip_reason="no_chat_db"` | db not found | raises FileNotFoundError after |
| `skip_reason="permission_denied"` | FDA refusal | raises PermissionError after |
| `skip_reason="no_messages"` | zero messages | terminal |
| `_emit_settling(done=0, total=T)` | start | |
| throttled `_emit_settling(done=d, total=T)` | per chat | `done == total` or 30 s |
| final `_emit_settling(done=d, total=T, complete=True)` | end of extract | **terminal** (B3 resolved) |

### 5. messages.whatsapp  (python: `vendor/ostler_fda/whatsapp_history.py`)

| Write | Where | Condition |
|---|---|---|
| `skip_reason="whatsapp_not_installed"` | ChatStorage.sqlite missing | terminal. Was `needs_source` (waits for a customer action nobody revisits). Raises FileNotFoundError after. |
| `skip_reason="permission_denied"` | FDA denied | terminal. Raises PermissionError after. |
| `skip_reason="no_messages"` | DB present, no sessions | terminal |
| `_emit_settling(done=0, total=T)` | start | |
| throttled `_emit_settling(done=d, total=T)` | per chat | `done == total` or 30 s |
| final `_emit_settling(done=d, total=T, complete=True)` | end of extract | **terminal** (B3 resolved) |

Dropped T1 chats (`status@broadcast` et al.) are removed from `total`, so they cannot hold the bar.

A skip is not sticky: a later run that finds work overwrites it with counts.

## Shard rule

TERMINAL = `complete:true` | `skip_reason` non-empty. Nothing else: not `done >= total`, not `total == 0`.
`0/0` with no marker is `discovering`, which is open. The static gate
(`tests/test_settling_denominator_terminal_writes.sh`) has no Python allowlist: each Python
writer file must carry `complete=True` and a `skip_reason="<code>"` emit.

## Not reachable from this tree

- Notes producer (B5).
- Any CM044 or HR015 writer. Only the reader is in CM044 (see B1).
