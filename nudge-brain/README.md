# Proactive "knows-me" nudge brain (v1.0.1, task #669)

The customer-side half of the proactive meeting-prep nudge (Architecture A). The
**brain** (this Python LaunchAgent) decides WHEN to nudge; the **daemon**
(ostler-assistant `POST /internal/nudge`, branch `feat/v1.0.1-proactive-nudge`)
owns the send path and is authoritative over restraint. The brain never sends
directly — it hands the daemon a nudge — which preserves the prototype's
shadow-safety property.

## Files
- `nudge_brain.py` — entrypoint. `run_once()` per tick: fetch upcoming meetings →
  `judge()` (lead-time window + human counterpart) → resolve person via
  ical-server `/api/v1/people/context` → two-pass `person_brief` → `render_block`
  → `POST /internal/nudge` (or log, in shadow mode).
- `test_nudge_brain.py` — unit tests for the pure pieces (judge, renderer,
  time parsing). 7/7 green. Run: `python3 -c "..."` harness (no pytest needed) or
  `pytest` if available.
- `com.ostler.nudge-brain.plist.template` — LaunchAgent; install.sh substitutes
  `@@PYTHON@@ / @@BRAIN@@ / @@LOGDIR@@`.

## Config (env — the Doctor toggle + tuning)
Brain: `OSTLER_ICAL_BASE`, `OSTLER_NUDGE_ENDPOINT`, `OSTLER_OLLAMA_BASE`,
`OSTLER_NUDGE_MODEL`, `OSTLER_NUDGE_CHANNEL`, `OSTLER_OWNER_NAME`,
`OSTLER_NUDGE_SHADOW`, `OSTLER_NUDGE_LEAD_MIN/MAX`.
Daemon-side restraint (set by the same Doctor toggle): `OSTLER_NUDGE_ENABLED`,
`OSTLER_NUDGE_DAILY_CAP`, `OSTLER_NUDGE_QUIET_START/END`, `OSTLER_NUDGE_TZ`,
`OSTLER_NUDGE_STATE`.

## REMAINING to wire (M5 — for the awake pass / TNM, NOT done here)
1. **install.sh**: add a proactive-messaging **opt-in question** (Phase 2). On
   yes → write the brain LaunchAgent from the template (substitute paths), set
   `OSTLER_NUDGE_SHADOW=0` + `OSTLER_NUDGE_ENABLED=1`; on no → don't install the
   agent (or install with ENABLED=0). Copy `nudge-brain/` into the install payload.
2. **Daemon orchestrator call-site** (ostler-assistant `orchestrator/mod.rs`): the
   one documented seam that calls `nudge::try_match_reply(...)` on the inbound path
   so 1/2/3/👍/👎 replies dispatch. Logic + tests are done on the daemon branch.
3. **Reconcile `person_brief` prompt wording** against the Mini prototype
   (`~/projects/people-graph/meeting_wow.py` / `person_brief.py`) — the prompts
   here are intent-faithful, not byte-copies (Mini was unreachable under the
   no-auth constraint when written, 2026-06-11).
4. **Doctor toggle UI**: a switch that writes `OSTLER_NUDGE_ENABLED` + reloads
   the agent.

## Verification gate (before this ships — from the brief)
A real nudge delivered end-to-end on a clean box: meeting in ~90 min → brain
fires → daemon delivers as the assistant → reply "1" → agenda generated. On the
BOX, not a log. Plus caps/quiet-hours/dedup proven, and L3 content never in a nudge.

## Orchestrator splice (PASTE-READY for the awake pass — daemon repo)

File: `ostler-assistant/crates/zeroclaw-channels/src/orchestrator/mod.rs`
Fn: `process_channel_message(ctx, msg, cancellation_token)` (~line 2482).
Insert AFTER the `on_message_received` hook resolves `msg` (so hooks aren't
bypassed) and BEFORE the LLM/agent dispatch. `msg` fields: `.channel .sender
.content .id .reply_target`.

```rust
// ── Proactive-nudge reply intercept (v1.0.1 #669) ──────────────
// If this message is a 1/2/3/👍/👎 reply to an OPEN nudge we sent this
// sender on this channel, dispatch the action instead of a normal turn.
if let Some(d) = zeroclaw_runtime::nudge::try_match_reply(
    zeroclaw_runtime::nudge::store(),
    &msg.channel, &msg.sender, &msg.content, chrono::Utc::now(),
) {
    match d.reply {
        zeroclaw_runtime::nudge::NudgeReply::No => {
            // dismiss: optional one-line ack; do NOT run the agent.
            tracing::info!(nudge_id = %d.nudge_id, "nudge dismissed by reply");
            return;
        }
        _ => {
            // Numbered/Yes: turn the chosen action into the effective user
            // turn so the EXISTING agent pipeline generates it (agenda /
            // research / history) for `d.person_slug`, then fall through.
            if let Some(action) = d.action_label {
                msg.content = format!(
                    "[proactive nudge action for {}] {}",
                    d.person_slug, action
                );
            }
        }
    }
}
```

Notes: `msg` is already `let mut` at that point (the hook rebinds it). On
Numbered/Yes we rewrite `msg.content` and fall through to the normal pipeline
(simplest, reuses all routing/tools). Add a focused test mirroring the existing
`process_channel_message_*` tests. After splicing: `cargo build --bin zeroclaw`
must stay green, then the on-box end-to-end gate (meeting -> nudge -> "1" -> agenda).
