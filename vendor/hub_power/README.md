# Hub power policy (MacBook-as-Hub)

This directory implements the power-state policy described in
[`HUB_PORTABILITY_PLAN.md`](../HUB_PORTABILITY_PLAN.md) – specifically the
"Power policy – the Docker / Ollama dilemma" section.

When Ostler runs on a MacBook instead of an always-on Mac Mini, the
Docker stack + Ollama will drain the battery fast. These scripts pause and
resume services based on AC / battery state and battery percentage, and
bring things back up cleanly after sleep.

## Architecture

A LaunchAgent polls `pmset -g batt` once a minute via
`bin/hub-power-watch.sh`. The watcher:

1. Reads `POWER_SOURCE`, `BATTERY_PCT`, and `LID` from `pmset` + `ioreg`.
2. Loads the user's `~/.ostler/power.conf` (`POWER_POLICY=normal|aggressive|eco`).
3. Maps those to a **tier**: `ac`, `battery_high`, `battery_mid`, `battery_low`.
4. Detects a **long gap** since the last tick (>120 s) and infers that the
   Mac woke from sleep, invoking `hub-wake.sh`.
5. Dispatches the right transition script on tier change.

macOS does not emit pmset events as filesystem notifications. Polling with a
60-second `StartInterval` keeps the implementation simple and dependency-free
(no `sleepwatcher`, no third-party helper).

## Scripts

| Script | Purpose |
|---|---|
| `hub-power-state.sh` | Shared state reader. Parses `pmset -g batt`, derives the tier, loads the user's policy file. Exposes helpers when sourced; prints state lines when run. |
| `hub-power-actions.sh` | Shared library of service-control functions (PWG pause / unpause, Ollama stop / start, ZeroClaw stop / start, ical-server verify). All actions respect `DRY_RUN=1`. |
| `hub-power-watch.sh` | The LaunchAgent entry point. Polls state, detects transitions, dispatches. |
| `hub-power-ac.sh` | Called on AC / `battery_high`. Ensures everything is running. |
| `hub-power-battery.sh` | Called on any battery tier. Dispatches to the right sub-script. |
| `hub-power-battery-low.sh` | Battery ≤ mid threshold. Pauses PWG, stops Ollama. Keeps ZeroClaw + ical-server. |
| `hub-power-battery-critical.sh` | Battery ≤ critical threshold. Also stops ZeroClaw. Only ical-server is left. |
| `hub-sleep.sh` | Pre-sleep hook. Records `last-awake` timestamp, exits quickly. |
| `hub-wake.sh` | Post-wake hook. Brings services back up in order (ical → ZeroClaw → Ollama → PWG) with 5 s gaps, then triggers an assistant catch-up. |

## Policy table

Matches the design doc exactly.

| Power state | PWG Docker | Ollama | ZeroClaw | ical-server |
|---|---|---|---|---|
| AC / lid anything | Running | Running | Running | Running |
| Battery > 30 % | Running | Running | Running | Running |
| Battery ≤ 30 % | **Paused** | **Stopped** | Running | Running |
| Battery ≤ 15 % | Paused | Stopped | **Stopped** | Running |
| Sleep | (macOS pauses everything) | – | – | – |
| Wake | resume in order: ical-server → ZeroClaw → Ollama → PWG (5 s between) | – | – | – |

Thresholds shift with `POWER_POLICY`:

| Policy | `mid` threshold | `low` threshold |
|---|---|---|
| `normal` (default) | 30 % | 15 % |
| `eco` | 50 % | 20 % |
| `aggressive` | 0 % (never triggers) | 0 % (never triggers) |

## User override

Edit `~/.ostler/power.conf`:

```
POWER_POLICY=normal    # or "aggressive" or "eco"
```

The watcher reads this file on every tick, so changes take effect within a
minute with no restart required.

## Catch-up on wake

`hub-wake.sh` writes `~/.zeroclaw/catchup_requested` with the wake timestamp
and restarts ZeroClaw. ZeroClaw does not currently poll for the marker file –
that's a ZeroClaw-side change still to be wired in. For v1, the restart is
the actual catch-up path: ZeroClaw drains its inbound iMessage / WhatsApp /
email queues on startup, so messages that arrived while the Mac was asleep
get answered once the daemon comes back.

See the "Open question" note in the task report for what the ZeroClaw side
needs for a proper poll-driven catch-up.

## Logging

Every script appends a one-line, ISO-8601 UTC timestamped entry to
`~/.ostler/hub-power.log`. The log is trimmed to the last 10 000 lines on
each write (naive but bounded).

To follow along live:

```
tail -f ~/.ostler/hub-power.log
```

launchd itself also writes to `~/.ostler/hub-power.launchd.log` (stdout +
stderr of the watcher process).

## Testing

Unit tests:

```
./tests/test_hub_power_state.sh             # state parser + policy resolution
./tests/test_hub_power_actions.sh           # hpa_bounded helper
./tests/test_hub_power_dispatch.sh          # tier-dispatch case-statement coverage
./tests/test_ollama_health_check.sh         # ollama spawn health-check loop
./tests/test_hub_power_ac.sh                # hub-power-ac.sh resume sequence
./tests/test_hub_power_battery_low.sh       # mid-tier throttle (pwg + ollama)
./tests/test_hub_power_battery_critical.sh  # critical throttle (pwg + ollama + zeroclaw)
./tests/test_hub_sleep.sh                   # pre-sleep hook + last-awake marker
./tests/test_hub_wake.sh                    # post-wake tier-dependent restoration
```

Full transition integration run (with stubbed service control):

```
DRY_RUN=1 ./test-run.sh
```

See `test-run.sh` for the manual smoke-test recipe on a real MacBook.

## Install

Sourced by the CM051 installer. To install manually (dev testing only):

```
cd hub-power
OSTLER_INSTALL_ROOT="$(pwd)" bash ./INSTALL_SNIPPET.sh
```

## Uninstall

```
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power"
rm ~/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist
```

Leave `~/.ostler/power.conf` if you intend to reinstall – the user's
policy choice survives reinstalls.

## Known quirks

- `pmset -g batt` on a desktop Mac (no battery) reports `Now drawing from
  'AC Power'` with no percentage line. We detect this as tier `ac` and do
  nothing, which is the right behaviour.
- `ioreg` lid state (`AppleClamshellState`) is not always present on every
  model. We treat absent as `unknown` and never gate on lid in the current
  policy – the design doc only ever uses AC / battery / percentage, not
  lid state.
- If the user's Mac has never set a timezone, the log's UTC timestamps are
  still correct because we call `date -u`.
- `launchctl bootstrap` is macOS 10.10+; older macOS falls back to the
  legacy `launchctl load` path in `INSTALL_SNIPPET.sh`.
