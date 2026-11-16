"""Background-service row for Ostler Doctor: what the Hub did about a stuck service.

The engine supervisor watches a background service inside the Hub's VM and, when
it is stuck, restarts it. It keeps a record at
~/.ostler/state/engine-supervisor/logind_health.json: the last check, the restart
times in the last 24 hours, and whether it has stopped restarting because
restarting did not help. This module renders that record. It reads a file only:
no subprocess, no network.

Customer copy names what was done and when. It never names internals.

States, each distinct:

* restarted        "restarted a stuck background service at 14:02."
* needs_attention  the budget is spent and the service is still stuck.
* running          the last check was healthy and nothing was restarted today.
* cannot_check     "couldn't check": missing, unreadable, stale, or the last
                   probe could not run. Never shown as running.
"""

from __future__ import annotations

import calendar
import html
import json
import os
import time
from datetime import datetime

# The supervisor ticks every 300 s. Two missed ticks is stale.
STALE_AFTER_S = 900
DAY_S = 86400


def default_path() -> str:
    base = os.environ.get("OSTLER_STATE_DIR") or os.path.join(
        os.environ.get("OSTLER_DIR") or os.path.join(os.path.expanduser("~"), ".ostler"),
        "state")
    return os.path.join(base, "engine-supervisor", "logind_health.json")


def _parse_iso(value) -> float | None:
    # The supervisor writes UTC with a Z suffix. timegm reads it as UTC.
    if not isinstance(value, str) or not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


def _heals_in_window(raw, now: float) -> list[int]:
    out = []
    for part in str(raw or "").split():
        part = part.strip()
        if part.isdigit() and now - int(part) < DAY_S:
            out.append(int(part))
    return sorted(out)


def read_engine_watchdog_status(path: str | None = None, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    p = path or default_path()
    try:
        with open(p, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict):
            raise ValueError("not an object")
        verdict = str(doc.get("verdict", ""))
        checked_at = _parse_iso(doc.get("checked"))
        escalated = doc.get("escalated") is True
        heals = _heals_in_window(doc.get("heal_epochs"), now)
    except FileNotFoundError:
        return {"state": "cannot_check", "count": 0, "last": None}
    except Exception:  # noqa: BLE001 - any unreadable record is "couldn't check"
        return {"state": "cannot_check", "count": 0, "last": None}

    if checked_at is None or now - checked_at > STALE_AFTER_S:
        return {"state": "cannot_check", "count": len(heals), "last": heals[-1] if heals else None}
    if verdict not in ("HEALTHY", "WEDGED"):
        return {"state": "cannot_check", "count": len(heals), "last": heals[-1] if heals else None}
    if escalated:
        return {"state": "needs_attention", "count": len(heals), "last": heals[-1] if heals else None}
    if heals:
        return {"state": "restarted", "count": len(heals), "last": heals[-1]}
    return {"state": "running", "count": 0, "last": None}


def _clock(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).strftime("%H:%M")


def render_engine_watchdog_status(status: dict | None = None) -> str:
    try:
        st = status if status is not None else read_engine_watchdog_status()
    except Exception:  # noqa: BLE001
        st = {"state": "cannot_check"}
    state = st.get("state")
    count = int(st.get("count") or 0)
    if state == "restarted" and st.get("last"):
        times = "" if count <= 1 else " (%d times today)" % count
        line = "Background engine: restarted a stuck background service at %s%s." % (
            html.escape(_clock(st["last"])), times)
    elif state == "needs_attention":
        line = ("Background engine: a background service keeps getting stuck, and restarting it "
                "has not fixed it. It needs attention.")
    elif state == "running":
        line = "Background engine: running normally."
    else:
        line = "Background engine: couldn't check."
    return '<div class="section"><h2>Background engine</h2><p>%s</p></div>' % line
