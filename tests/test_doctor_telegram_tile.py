#!/usr/bin/env python3
"""The Doctor's Telegram tile: renders what the daemon's status file says, and
nothing it does not. The fixture is the CONTRACT with ostler-assistant
`telegram_ostler::TelegramStatus` (the same file is asserted there).
Exit 0 all pass, 1 any fail."""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "doctor" / "agent"))
import telegram_status as ts  # noqa: E402

import os, subprocess  # noqa: E402
dead = subprocess.Popen([sys.executable, "-c", "pass"]); dead.wait()
LIVE_ASSISTANT = 999_999_001  # the fixture's pid; the fake inspector calls it the live assistant
real_inspector = getattr(ts, "assistant_pid_alive", None)
ts.assistant_pid_alive = lambda pid: pid == LIVE_ASSISTANT

FIX = json.loads((ROOT / "tests" / "fixtures" / "telegram_channel_status.json").read_text())
NOW = datetime(2026, 10, 18, 6, 5, tzinfo=timezone.utc)
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -- {detail}"))
    fails += 0 if cond else 1


def render(obj) -> str:
    d = Path(tempfile.mkdtemp())
    p = d / "telegram_channel.json"
    if obj is not None:
        p.write_text(obj if isinstance(obj, str) else json.dumps(obj))
    return ts.render_telegram_status(now_dt=NOW, path=p)


out = render(FIX)
check("contract fixture renders Connected", "Connected" in out, out)
check("shows the bot", "@synthetic_test_bot" in out, out)
check("shows when the owner last wrote", "5 minutes ago" in out, out)
check("shows the ignored count", "Ignored 3 messages from other people" in out, out)
check("no setup hint when connected", "ostler-telegram-setup" not in out, out)
check("every fixture key is one the reader knows",
      set(FIX) == {"status", "bot_username", "last_owner_message_at", "non_owner_dropped",
                   "last_dropped_at", "last_error", "updated_at", "daemon_pid"}, str(sorted(FIX)))

err = dict(FIX, status="config_error", last_error="Telegram is switched on but has no bot token (synthetic).")
out = render(err)
check("config_error says Not running", "Not running" in out, out)
check("config_error shows the daemon's reason", "has no bot token (synthetic)" in out, out)
check("config_error says how to fix", "ostler-telegram-setup" in out, out)
check("config_error is never shown as Connected", "Connected" not in out, out)

out = render(dict(FIX, status="api_error", last_error="Telegram did not accept the bot token."))
check("api_error is red-labelled as refused", "Telegram refused the connection" in out, out)

check("no file = no tile", render(None) == "")
check("unknown status = no tile, not rendered verbatim", render(dict(FIX, status="totally_fine")) == "")
check("garbage file = no tile, no exception", render("{not json") == "")
check("html in the reason is escaped", "<script>" not in render(dict(err, last_error="<script>x</script>")))
out = render(dict(FIX, non_owner_dropped=0, last_owner_message_at=None))
check("zero drops: no ignored line", "Ignored" not in out, out)
check("never messaged: says so", "No message from you yet" in out, out)

# ── stale "Connected" (Archie #2980): the file alone is not the truth ──
check("tile has a daemon-liveness inspector", callable(real_inspector))
if callable(real_inspector):
    check("inspector: a dead pid is not alive", real_inspector(dead.pid) is False)
    check("inspector: a live pid that is not the assistant is not alive", real_inspector(os.getpid()) is False)

out = render(dict(FIX, daemon_pid=dead.pid))
check("dead daemon: never says Connected", "Connected" not in out, out)
check("dead daemon: says it could not check", "Could not check" in out, out)
out = render(dict(FIX, daemon_pid=os.getpid()))
check("pid reused by another process: never says Connected", "Connected" not in out, out)
out = render({k: v for k, v in FIX.items() if k != "daemon_pid"})
check("no daemon pid (older daemon): never says Connected", "Connected" not in out, out)
out = render(dict(FIX, daemon_pid=LIVE_ASSISTANT))
check("live assistant wrote it: Connected", "Connected" in out, out)
out = render(dict(FIX, status="off", daemon_pid=dead.pid))
check("off: says Off, even with the daemon stopped", "Off" in out and "Connected" not in out, out)
check("off: says how to switch it on", "ostler-telegram-setup" in out, out)
print(f"\n{fails} failed")
sys.exit(1 if fails else 0)
