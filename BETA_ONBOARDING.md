# Beta Onboarding - Installer Notes

Installer-side onboarding reference. Pairs with the beta-tester invite templates that live at `HR015/BETA_ONBOARDING.md`.

This doc is for the 5-minute "after the installer finishes, what do I tell the tester to check" bit. Keep it focused on what `install.sh` actually sets up.

---

## After a successful install

The final summary tells the user which Hub deployment they're on:

- **Mac Mini / Studio Hub** - always-on AC. No power-state handling, nothing to tune. `hub-power` is installed but idle.
- **MacBook Hub** - Docker + Ollama pause when unplugged, resume when back on mains. Sleep / wake transitions are handled automatically.

Both SKUs get the same installer. The LaunchAgent detects AC vs battery at runtime.

---

## Hub power policy override

`~/.lifeline/power.conf`:

```
POWER_POLICY=normal    # or "aggressive" or "eco"
```

| Policy | When to pick it |
|---|---|
| `normal` (default) | Daily use. Pauses at 30% battery, critical at 15%. |
| `aggressive` | Mac is plugged in but pmset reports flaky. Never throttles; will burn the battery if it really is on battery. |
| `eco` | Long travel day, don't need Marvin alive. Pauses at 50%, critical at 20%. |

Changes take effect within 60 seconds. No restart needed, the watcher reloads the file every tick.

---

## LaunchAgent management (for the tester or you)

Check it's running:

```bash
launchctl list | grep com.creativemachines.lifeline.hub-power
tail -f ~/.lifeline/hub-power.log
```

Reload after editing `power.conf` is **not needed**, but reloading after updating the scripts is:

```bash
launchctl bootout "gui/$(id -u)/com.creativemachines.lifeline.hub-power" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.creativemachines.lifeline.hub-power.plist
```

Fully remove:

```bash
launchctl bootout "gui/$(id -u)/com.creativemachines.lifeline.hub-power"
rm ~/Library/LaunchAgents/com.creativemachines.lifeline.hub-power.plist
rm -rf ~/.lifeline/hub-power
# Keep ~/.lifeline/power.conf if the user may reinstall.
```

---

## Common tester questions

**"My laptop is hot and the fan is on."** Either plugged in (expected, hub-power has nothing to do) or the user picked `aggressive` (explain the trade-off). Check `cat ~/.lifeline/power.conf`.

**"Lifeline stopped working after I unplugged."** Expected, the Docker stack is paused. It resumes within about 60 seconds of going back on AC. Check `~/.lifeline/hub-power.log` for the tier transitions.

**"I want it to always run no matter what."** Set `POWER_POLICY=aggressive`. Warn about battery.

**"Nothing is happening on battery."** They're probably above the threshold (30% on `normal`). Drop battery below 30% or switch to `eco` (50% threshold) to test the transition.

---

## Design reference

The policy matrix, tier definitions, and catch-up-on-wake logic all live in **`HR015/HUB_PORTABILITY_PLAN.md`**. When behaviour looks wrong, start there.

---

## Relationship to HR015's onboarding doc

`HR015/BETA_ONBOARDING.md` covers:

- Beta invite message templates
- GDPR export request checklist
- Install-day coaching
- Feedback-request templates

This CM051 doc covers:

- What `install.sh` sets up for the Hub power policy
- LaunchAgent ops (install, check, reload, remove)
- Common tester questions specific to MacBook Hub

If onboarding guidance consolidates into one repo later, it probably belongs here with the installer.
