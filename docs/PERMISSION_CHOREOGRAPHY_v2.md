# Permission Choreography v2 — serial, completion-detected, daemon-gated

Status: DESIGN (for sign-off) · Target: next cut (NOT this cut) · British English
Author: agent build (design-first) · Date: 2026-06-29

> This is the design Andy reviews before any box-walk. It supersedes the
> timing-based serialisation (`feat/install-permission-glut-and-editor-hook`,
> commit `d034fa4`) which sequenced prompts by `sleep` and **failed** on the
> clean-box walk: multiple permission windows still stacked at ~76%.

---

## 1. The bug, precisely

On a clean-box install, at roughly 76% (the `ostler_assistant` install step,
`install.sh:13193+`), up to four things appear on screen at once:

1. The daemon's native **"OstlerAssistant wants access to Messages"** TCC
   prompt (the *Automation* prompt — `kTCCServiceAppleEvents`, target Messages).
2. **System Settings → Privacy & Security → Full Disk Access**, opened for the
   *daemon's* FDA grant (a separate TCC subject from the installer app).
3. The installer's osascript **"find Ostler, turn it on, Done"** instruction
   card (`MSG_PROMPT_IMESSAGE_FDA_ASSIST_*`).
4. The installer window itself.

### Why it happens (root cause)

- **Two TCC subjects need FDA, not one.** macOS keys Full Disk Access by code
  signature. `OstlerInstaller.app` and the `ai.ostler.assistant` daemon are
  *different* binaries → *different* FDA entries. The installer's up-front FDA
  gate (`CX-87`, `FullDiskAccessGateView`) grants the **installer** FDA. The
  **daemon** still needs its own FDA, and that ask currently fires mid-install.

- **The daemon has no internal gate.** `OSTLER_ASSISTANT_DEFER_BOOTSTRAP`
  (CM051 #395) only defers the *first `launchctl bootstrap`* — a shell-level
  one-shot in `assistant-agent/INSTALL_SNIPPET.sh:159`. Once the daemon is
  booted (and it is RunAtLoad + KeepAlive), the Rust binary **immediately**
  fires its Automation probe (`daemon/mod.rs:248` → `imessage_tcc::probe`,
  `osascript "tell application \"Messages\" to count of accounts"`). There is
  **no check** in the daemon for "is FDA granted yet". So the prompt fires the
  moment the daemon boots, regardless of FDA state.

- **The prior fix serialised by TIMING.** `install.sh` bootstraps the daemon,
  then `sleep 5` / `sleep 2`, then opens the FDA pane + card. A sleep is not a
  gate: if the daemon's async prompt is slow, or the System Settings animation
  is slow, the windows still overlap. Sleep-ordering is exactly what failed.

---

## 2. Andy's directive (the contract this design satisfies)

1. Prompts fire **strictly one at a time**; the next is not raised until the
   user has **dealt with** the previous one.
2. The gate between prompts is **detection of completion** (poll the *real*
   permission state until it flips to granted, or the user hits Done/Skip),
   **never a timer**.
3. The daemon is **forbidden from raising its own TCC prompt until FDA is
   confirmed granted** — gate the daemon's access request behind an explicit
   "FDA granted" signal.
4. **Exactly one** window/instruction visible at any moment.
5. **Front-load** the whole permission sequence to right after the questions
   (with the Tailscale sign-in), so the autonomous middle is hands-off — not
   at ~76%.

---

## 3. Complete inventory of permission asks (current flow)

| # | Permission | Subject | Where it fires now | % now | How raised | Completion-detection available |
|---|-----------|---------|--------------------|-------|-----------|-------------------------------|
| 1 | Full Disk Access | **Installer** | `FullDiskAccessGateView` (launch); `install.sh:2164` early + `7557` `fda_extract` | ~0% (relaunch gate) | System Settings pane + osascript card | `AuthorizationHelper.hasFullDiskAccess()` (read installer TCC.db) / `_fda_read_probe_early` |
| 2 | Contacts (TCC) | Installer | `PermissionsPrewarmer` (launch) | ~0% | `CNContactStore.requestAccess` | callback returns on user decision (await) |
| 3 | Calendar (TCC) | Installer | `PermissionsPrewarmer` | ~0% | `EKEventStore.requestFullAccessToEvents` | await + `authorizationStatus` |
| 4 | Reminders (TCC) | Installer | `PermissionsPrewarmer` | ~0% | `requestFullAccessToReminders` | await + `authorizationStatus` |
| 5 | Photos (TCC) | Installer | `PermissionsPrewarmer` | ~0% | `PHPhotoLibrary.requestAuthorization` | await + `authorizationStatus` |
| 6 | Contacts Automation | Installer | `AppleEventContactsProbe` (launch) + `install.sh:2374` me-card | ~0% | osascript `count of every person` | osascript blocks; `-1743` stderr classifies |
| 7 | Calendar Automation | Installer | `install.sh:2118` | ~0% | osascript `count calendars` | osascript blocks |
| 8 | iMessage Automation | **Installer** | `install.sh:2897` (early) + `16222` health_check | ~0% / ~100% | osascript `count of accounts` | osascript blocks; `-1743` |
| 9 | **Full Disk Access** | **Daemon** | `install.sh:13193+` | **~76%** ⚠️ | System Settings pane + osascript "find Ostler, turn it on, Done" card | **`_imessage_daemon_fda_granted()`** (system TCC.db, `auth_value==2`) |
| 10 | **Messages Automation** | **Daemon** | daemon boot probe at `install.sh:13319` bootstrap | **~76%** ⚠️ | daemon-identity osascript `count of accounts` | TCC.db `kTCCServiceAppleEvents` for `ai.ostler.assistant` (new probe `_imessage_daemon_automation_granted`) |
| — | Screen Recording / Microphone | RemoteCapture app | first launch (post-install) | n/a | native at first launch | out of scope (deferred to first run) |
| — | Tailscale sign-in | (browser) | `install.sh:8150` `tailscale_connect` step | ~18% | Safari login URL, not a TCC prompt | tailnet-IP poll |

**The two rows marked ⚠️ (9 and 10) are the entire bug.** Everything else is
already front-loaded at launch and already one-at-a-time (the four installer
TCC prompts await their callbacks; the osascript probes block). This design
moves rows 9 and 10 into a front-loaded, completion-detected serial block and
makes the daemon physically unable to fire row 10 before row 9 is granted.

---

## 4. Per-permission completion-detection method (directive #2)

The gate between every prompt is the **real OS permission state**, polled until
it flips — never a fixed sleep. Detection method per ask:

| Ask | Detection of "dealt with" | Mechanism |
|-----|---------------------------|-----------|
| Installer FDA | `AuthorizationHelper.hasFullDiskAccess()` returns true | reads a byte of the installer's own TCC.db (denied without FDA). Already a relaunch gate. |
| Installer Contacts/Calendar/Reminders/Photos | the framework `requestAccess` continuation **resumes** | macOS only resumes the callback once the user clicks Allow/Don't Allow → the await *is* the completion gate (state, not timer). The 800 ms gap is a cosmetic breather, not the gate. |
| Installer/Contacts/Calendar/iMessage Automation | `osascript` process **exits** | osascript blocks until the user answers the Automation dialog; its exit + stderr (`-1743`) is the completion signal. |
| **Daemon FDA (row 9)** | `_imessage_daemon_fda_granted` returns `granted` | `sudo -n sqlite3 /Library/.../TCC.db "SELECT auth_value ... service='kTCCServiceSystemPolicyAllFiles' AND client IN ('ai.ostler.assistant', legacy)"` → `2`. **Poll** this on a fixed cadence until granted or the user taps Skip. |
| **Daemon Messages Automation (row 10)** | `_imessage_daemon_automation_granted` returns `granted` | new sibling probe: same TCC.db, `service='kTCCServiceAppleEvents'`, `client='ai.ostler.assistant'`, `indirect_object_identifier` in the Messages bundle ids → `auth_value==2`. **Poll** until granted or Skip. |

### Honest uncertainty (flagged, not papered over)

- **Daemon Automation polling is the least certain detector.** `kTCCServiceAppleEvents`
  rows are keyed by `(client, indirect_object_identifier)` and the
  `indirect_object_identifier` for Messages has historically been
  `com.apple.iChat` (older) vs `com.apple.MobileSMS` / a Messages bundle id on
  newer macOS. The box-walk must confirm the exact value on the target macOS;
  the probe therefore matches a small **set** of candidate ids, and falls back
  to "user taps Done" if the row cannot be read. **This is the one ask whose
  grant may not be cleanly pollable on every macOS version — so its queue step
  carries an explicit user **Done** affordance as the backstop, not just a
  poll.** (Directive: "when unsure whether something can be state-detected vs
  needs a user Done, say so" — this is the one.)
- Reading the **system** TCC.db (`/Library/...`) requires either FDA or root.
  install.sh runs under the installer app's TCC identity (which has FDA by this
  point) and/or with a warm `sudo` cache; if both are unavailable the probe
  returns empty and the step falls through to the user-**Done** backstop. Same
  posture the existing `_imessage_daemon_fda_granted` already takes.

---

## 5. The daemon-side gate (directive #3) — the structural fix

The installer cannot, by itself, guarantee the daemon won't prompt — the daemon
is RunAtLoad + KeepAlive, so launchd can boot it at any time (login, crash
restart). **The only place a "never prompt before FDA" guarantee can live is in
the daemon.**

### Change (ostler-assistant, `crates/zeroclaw-runtime`)

New module `imessage_fda_gate.rs`:

```rust
/// True when the daemon can actually read the Messages store, i.e. Full Disk
/// Access is granted to THIS binary. Mirrors the existing health_check proxy
/// (`~/Library/Messages/chat.db` readability) used by warm_intro. Non-macOS
/// returns true (no gate).
pub fn full_disk_access_ready() -> bool { /* chat.db readable */ }

/// Poll `probe` until it returns true or `cap` elapses. The interval is the
/// re-check cadence (state poll), NOT a substitute for completion: the loop
/// EXITS the instant the state flips. Returns whether FDA became ready.
pub async fn wait_for_full_disk_access<F: Fn() -> bool>(
    probe: F, interval: Duration, cap: Duration) -> bool { ... }

/// Default ON (macOS). Opt out via OSTLER_ASSISTANT_DEFER_TCC_UNTIL_FDA=0
/// (tests, or a deliberate "prompt immediately" build).
pub fn defer_tcc_until_fda_enabled() -> bool { ... }
```

Wire into `daemon/mod.rs` (the boot iMessage TCC probe spawn, currently
unconditional at line 248):

```rust
if imessage_enabled {
    handles.push(tokio::spawn(async move {
        // GATE: never raise the daemon's "control Messages" Automation prompt
        // before FDA is confirmed. Raising it earlier stacks a second dialog
        // on the installer's FDA System-Settings window (the 76% bug). Poll
        // the REAL FDA state and only then fire the one-shot probe.
        if defer_tcc_until_fda_enabled()
            && !wait_for_full_disk_access(full_disk_access_ready,
                                          POLL /*3s*/, CAP /*~20min*/).await {
            tracing::info!("imessage-tcc: FDA not granted within window; \
                deferring Automation probe (re-evaluated on next boot)");
            return;
        }
        // ... existing imessage_tcc::probe + health marker ...
    }));
}
```

Notes:
- The chat.db `listen()` open (`imessage.rs:831`) is **left ungated on
  purpose**: without FDA it fails *silently* (EPERM, no prompt) — and that
  failed read is exactly what **registers the daemon in the FDA list** so the
  installer's "find Ostler, turn it on" card has something to point at. Only
  the *Automation osascript* prompts; only it is gated.
- `cap` is finite (≈20 min) so the task can end; KeepAlive + next-login
  re-evaluate. On an existing install where FDA is already granted, the probe
  returns true on the first poll → behaviour is unchanged (no regression).
- `OSTLER_ASSISTANT_DEFER_BOOTSTRAP` (shell) and
  `OSTLER_ASSISTANT_DEFER_TCC_UNTIL_FDA` (daemon) are complementary: the former
  controls *when launchd first boots* the daemon during install; the latter is
  the daemon's own backstop so it can never prompt before FDA **regardless** of
  when it boots. We keep the former and add the latter.

---

## 6. The front-loaded serial permission queue (directives #1, #4, #5)

### 6.1 New driver — `lib/permission_queue.sh`

A pure, sourceable bash driver. Generic over *steps*; each step is three
function names + a label:

```
permq_run_step <label> <raise_fn> <detect_fn> <skip_prompt_id>
    raise_fn   : raises EXACTLY ONE ask (open pane + show one card, or fire one
                 osascript). Returns immediately.
    detect_fn  : echoes "granted" when the real OS state is granted, else
                 nothing. Called repeatedly.
    Loop: raise once, then poll detect_fn every PERMQ_POLL_SECS. Between polls,
          offer the user a single "I've done it / Skip" acknowledgement (the
          one visible card). Exit the loop the instant detect_fn says granted,
          OR the user acknowledges Done/Skip. NEVER a fixed total sleep.
```

Key properties (all unit-tested, §7):
- **One at a time**: `permq_run` iterates steps sequentially; step N+1's
  `raise_fn` is not called until step N's loop has exited.
- **State, not time**: the loop condition is `detect_fn`'s output. The poll
  interval is only the re-check cadence; a granted state exits immediately. A
  test with a mock `detect_fn` that returns "not granted" K times then
  "granted" proves the loop waits for STATE and exits on the flip (not on a
  timer).
- **One window**: `raise_fn` opens at most one System Settings pane and shows
  one card; the queue never raises the next card while one is up.
- **Skip backstop**: every step accepts a user Done/Skip so a non-pollable
  grant (see §4 uncertainty) still advances.

### 6.2 Where it runs — front-loaded position

Right after the Tailscale sign-in step (`install.sh:8150`,
`tailscale_connect`, ~18%), a new function `_ostler_front_loaded_daemon_permissions`
runs the queue with the two daemon steps:

```
progress "Connect your iPhone and Watch" "tailscale_connect"   # existing, ~18%
... tailscale install + browser sign-in ...

# NEW: front-loaded daemon permission block (one window at a time)
_ostler_front_loaded_daemon_permissions   # ← rows 9 + 10, serial, polled
```

`_ostler_front_loaded_daemon_permissions` does:

1. **Prep (no prompt):** ensure the signed daemon binary is at its final path
   and the plist is rendered with `OSTLER_ASSISTANT_DEFER_BOOTSTRAP=1`
   (already the case post-`INSTALL_SNIPPET`). Bootstrap the daemon **once** via
   `_ostler_bootstrap_assistant_daemon`. The daemon boots, attempts chat.db
   (silent EPERM → **registers in the FDA list**), and — because of the §5
   gate — does **not** fire the Automation prompt yet.
2. **Step DAEMON_FDA** (`raise`: open `Privacy_AllFiles` + show the existing
   "find Ostler, turn it on, Done" card once; `detect`:
   `_imessage_daemon_fda_granted`). Poll until granted or Skip. One window.
3. **Step DAEMON_AUTOMATION** (only if `CHANNEL_IMESSAGE_ENABLED`): once FDA is
   granted, `launchctl kickstart -k` the daemon so its now-ungated boot probe
   fires the **single** "OstlerAssistant wants to control Messages" prompt;
   `detect`: `_imessage_daemon_automation_granted`. Poll until granted or Skip.
   One window — and it physically cannot appear before step 2 finished, because
   the daemon was gated on FDA.
4. Set `DAEMON_PERMS_SHOWN_EARLY=1`.

### 6.3 The legacy 76% block becomes a guarded no-op

The existing block at `install.sh:13193+` is wrapped:

```
if [[ "${DAEMON_PERMS_SHOWN_EARLY:-0}" == "1" ]]; then
    # Already handled in the front-loaded block. Re-probe only (no prompts):
    # if the daemon FDA is still granted, continue silently; otherwise emit a
    # non-blocking Doctor card for post-install follow-up.
    ...
else
    ... existing block (fallback for non-GUI / older paths) ...
fi
```

This mirrors the proven `INSTALLER_FDA_SHOWN_EARLY` / `IMESSAGE_AUTOMATION_PRIMED_EARLY`
idempotency pattern already in the codebase — additive and reversible, not a
rip-out of a 834 KB file we cannot box-walk here.

---

## 7. The resulting front-loaded sequence (one window at a time)

```
LAUNCH
  └─ [1] Installer Full Disk Access  (FullDiskAccessGateView; quit+reopen)   ← relaunch gate, stays
REOPEN
  └─ [2] Contacts → [3] Calendar → [4] Reminders → [5] Photos  (await each)
  └─ [6] Contacts Automation  [7] Calendar Automation          (osascript blocks)
  └─ Licence + admin password
QUESTIONS (onboarding) ───────────────────── one prompt at a time (existing)
  └─ Tailscale sign-in (browser)                                ~18%
  └─ [8]  iMessage Automation (installer identity)              (osascript blocks)
  └─ ┌─────────── NEW front-loaded daemon permission block ──────────┐
     │ [9]  Daemon Full Disk Access  — poll TCC.db until granted/Skip │  one window
     │ [10] Daemon Messages Automation — poll until granted/Skip      │  one window, cannot
     └────────────────────────────────────────────────────────────────┘  precede [9] (gated)
AUTONOMOUS MIDDLE  (graph_db → models → import → wiki_compile → health)   ← HANDS-OFF, no prompts
  └─ ostler_assistant step (~76%): daemon already has FDA+Automation → SILENT
DONE
```

Every transition between `[9]`→`[10]` and into the autonomous middle is gated
on a **detected state flip or an explicit user action**, never a sleep.

---

## 8. Why this is robust where the timing fix was not

| Failure mode of the timing fix | How v2 removes it |
|--------------------------------|-------------------|
| Daemon prompt races the FDA window (sleep too short) | Daemon **cannot** prompt before FDA (§5 gate). No race possible. |
| Two windows because ordering was by `sleep` | Queue raises step N+1 only after step N's **detected** completion (§6.1). |
| Prompt lands at 76% while user walked away | Both daemon asks are **front-loaded** to ~18%, in the attentive window with Tailscale (§6.2). |
| "Granted" assumed after a fixed wait | Grant is **read back** from TCC.db; the loop exits on the real flip (§4). |

---

## 9. Test strategy & the limits of tests

- **Unit-tested (this branch):**
  - `tests/test_permission_queue.sh` — drives `lib/permission_queue.sh` with
    **mock** `detect_fn`s: (a) not-granted×K then granted ⇒ proves the loop
    waits on STATE and exits on the flip; (b) immediate-granted ⇒ no spurious
    wait; (c) Skip ⇒ advances without a grant; (d) two steps ⇒ step 2 never
    raised before step 1 resolved (one-at-a-time).
  - ostler-assistant `imessage_fda_gate` unit tests — `wait_for_full_disk_access`
    with a mock probe: false×K→true returns true after K polls; always-false
    returns false at cap; env parsing of `OSTLER_ASSISTANT_DEFER_TCC_UNTIL_FDA`.
  - Structural `bash -n` / shellcheck on the new lib + install.sh.
- **NOT provable by tests — requires a clean-box box-walk:** that the macOS TCC
  prompts actually appear one at a time, attributed to the right subject, in the
  front-loaded position, and that the daemon-Automation TCC row id matches on
  the target macOS (§4 uncertainty). **Tests prove the choreography logic; only
  a clean-wipe walk proves the choreography.** This design is NOT "fixed" until
  that walk passes.

---

## 10. Open risks / verification checklist for the walk

1. **Daemon binary present at its final signed path by ~18%.** The block needs
   the daemon registered in TCC before raising its FDA card. Confirm the
   staging-tree promote (WALK-2, before `tailscale_connect`) places the *final*
   signed daemon binary, not just stages it. If not, hoist the binary copy.
   The daemon's code-signing designated requirement must be stable at the early
   path (else the FDA grant won't match at the late path).
2. **Daemon Automation TCC row id** (`indirect_object_identifier`) on the target
   macOS — confirm the value; widen the probe's candidate set if needed.
3. **System TCC.db readability** from install.sh at the ~18% point (FDA/sudo
   cache warm). If not, the steps fall to the user-Done backstop — acceptable
   but note it on the walk.
4. **`launchctl kickstart -k`** reliably re-fires the daemon Automation probe
   after FDA — confirm on the walk; if flaky, drive it via a dedicated
   daemon-identity one-shot subcommand instead.
