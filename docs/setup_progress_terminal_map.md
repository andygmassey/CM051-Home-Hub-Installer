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

**B1. The bar cannot display 100%.** `CM044/compiler/hydration.py:1087`
`pct = max(1, min(99, pct))`. Every shard can be terminal and the bar still
reads 99. Fix lives in CM044, not here. Not fixed in this PR.

**B2. Emails has no progress writer, so it cannot advance during a walk.**
The emails shard is written only by the hourly tick's terminal calls
(`email-bundle-tick.sh:373` complete, `:371`/`:227`/`:362`/`:363` skip).
Nothing writes an intermediate `done`. On a box with a backlog (Mini16:
17080 of 121262) `setup_progress_advancing` **FAILs emails by design** until
the backlog clears or the tick completes. The producer needs per-tick `done`
writes from `email_source.pipeline`. Not in this PR.

**B3. Windowed iMessage and WhatsApp never reach terminal.** Their final emit
carries the *actual* `done`, not `total`:
- `vendor/ostler_fda/imessage.py:351` `_emit_settling(done=done, total=total)`
- `vendor/ostler_fda/whatsapp_history.py:534` `_emit_settling(done=done, total=total)`

`total` is computed over **all** rows (`imessage.py:287`,
`whatsapp_history.py:475`). Rows outside `since_days` are skipped
(`imessage.py:316`, `whatsapp_history.py:498`) and never added to `done`. So
any window that excludes a row leaves `done < total` for good. Reachable only
when the window covers every row. **Not verified** which `since_days` the
install passes for each. The fix is a product decision (exclude out-of-window
rows from the denominator, as WhatsApp already does for dropped T1 chats at
`whatsapp_history.py:519`), so it is not made here.

**B4. A later zero-count write can falsely complete a shard (found, not fixed).**
`lib/settling_progress.sh` (`settling_report`, the non-terminal branch) sets
`total = max(OSTLER_SETTLING_TOTAL, done)`. It ignores `prev_total`. Measured:
`settling_report emails 17080 121262` then `settling_report emails 0 0 true`
leaves `done=17080 total=17080`, which reads 100%. The install calls
`settling_report emails 0 0 true` at `install.sh:37118`, `:37127`, `:37230`.
A re-run install over a box that already has a backlog shard hits this. The
fix is one line (`total = max(total_in, prev_total, done)`), outside this PR's
scope.

**B5. Notes has no writer in any reachable repo.** No producer in CM051,
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

| Write | file:line | Condition |
|---|---|---|
| `_emit_settling(done=0, total=N)` | `calendar.py:319` | start; N = rows (0 if none) |
| throttled `_emit_settling(done=i, total=N)` | `:329` | every row at `done == total` or 30 s |
| final `_emit_settling(done=N, total=N)` | `:367` | **always** on a completed extract |

Terminal: `:367` sets `done == total` unconditionally. Reachable whenever the
extract finishes. An exception between `:319` and `:367` leaves the shard open
at `i/N`; the exception path is not guarded by a finally.
Skip reasons: none (`total == 0` is terminal by the probe's rule, `nothing to measure`).
Terminal form: done==total, not a `settling_complete` call (see `test_settling_denominator_terminal_writes.sh` allowlist).

### 4. messages.imessage  (python: `vendor/ostler_fda/imessage.py`)

| Write | file:line | Condition |
|---|---|---|
| `_emit_settling(done=0, total=0, needs_source=False)` | `:296` | chat.db has no messages. Terminal by the probe rule. |
| `_emit_settling(done=0, total=T)` | `:302` | start |
| throttled `_emit_settling(done=d, total=T)` | `:344` | `done == total` or 30 s |
| final `_emit_settling(done=d, total=T)` | `:351` | `d` is the in-window count. Terminal only if `d == T`. **B3.** |

Skip reasons: none. The `needs_source` path is not present for iMessage (`:296` writes `False`).

### 5. messages.whatsapp  (python: `vendor/ostler_fda/whatsapp_history.py`)

| Write | file:line | Condition |
|---|---|---|
| `_emit_settling(done=0, total=0, needs_source=True)` | `:409` | ChatStorage.sqlite missing. **Not terminal.** Waits for the customer. |
| `_emit_settling(done=0, total=0, needs_source=True)` | `:421` | FDA denied (PermissionError). **Not terminal.** |
| `_emit_settling(done=0, total=0, needs_source=False)` | `:482` | DB present, no sessions. Terminal by the probe rule. |
| `_emit_settling(done=0, total=T)` | `:486` | start |
| throttled `_emit_settling(done=d, total=T)` | `:526` | `done == total` or 30 s |
| final `_emit_settling(done=d, total=T)` | `:534` | `d` is in-window. Terminal only if `d == T`. **B3.** |

Dropped T1 chats (`status@broadcast` et al.) are removed from `total` (`:519`),
so they cannot hold the bar.

Skip reasons: none. `needs_source` is not terminal, and the probe's rule matches.
A missing WhatsApp app does not move the bar (`total == 0`, see the reader rule
above), but the probe marks it OPEN and FAILs on it.

## Shard rule the probe uses

TERMINAL = `complete:true` | `skip_reason` non-empty | `total>0 and done>=total` |
`total==0 and needs_source false`.

A `needs_source:true, total:0` shard is OPEN to the probe. It is not in the bar's
arithmetic. This is intentional: the probe asks "is the writer finished", not
"does the bar move".

## Not reachable from this tree

- Notes producer (B5).
- Any CM044 or HR015 writer. Only the reader is in CM044 (see B1).
