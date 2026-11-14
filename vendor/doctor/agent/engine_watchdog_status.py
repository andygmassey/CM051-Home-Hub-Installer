"""Background engine row for Ostler Doctor: did the VM's logind get restarted?

The engine supervisor (bin/ostler-engine-supervisor.sh) probes systemd-logind
inside the colima VM once per tick and writes its verdict to
~/.ostler/state/engine-supervisor/logind_health.json. This module renders that
file as one row. It reads the file only: no subprocess, no network, no colima.

Rows, each distinct:

* restarted   the supervisor restarted a busy logind at a recorded time.
              "Background engine: a system service was stuck and was restarted at <time>."
* running     the last check found logind healthy, nothing needed restarting.
* couldn't check   the check could not run (probe failed, timed out, unparseable),
              the file is missing or unreadable, or the last check is stale
              (the supervisor has not run for a while). Never shown as "running".

Nothing here is a customer secret. The file holds a verdict, a time and a count.
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


def default_path() -> str:
    base = os.environ.get("OSTLER_STATE_DIR") or os.path.join(
        os.environ.get("OSTLER_DIR") or os.path.join(os.path.expanduser("~"), ".ostler"),
        "state")
    return os.path.join(base, "engine-supervisor", "logind_health.json")


def read_engine_watchdog_status(path: str | None = None, now: float | None = None) -> dict:
    """Return {"state": ..., "restarted_at": epoch|None, "checked_at": epoch|None}.

    state is one of: restarted, running, cannot_check.
    Any read or parse problem is cannot_check. It is never running.
    """
    now = time.time() if now is None else now
    p = path or default_path()
    try:
        with open(p, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict):
            raise ValueError("not an object")
        verdict = str(doc.get("verdict", ""))
        checked = doc.get("checked")
        checked_at = _parse_iso(checked)
        last_restart = int(doc.get("last_restart_epoch") or 0)
    except FileNotFoundError:
        return {"state": "cannot_check", "reason": "no record yet", "restarted_at": None, "checked_at": None}
    except Exception as exc:  # noqa: BLE001 - any unreadable record is "couldn't check"
        return {"state": "cannot_check", "reason": type(exc).__name__, "restarted_at": None, "checked_at": None}

    if checked_at is None or now - checked_at > STALE_AFTER_S:
        return {"state": "cannot_check", "reason": "last check is stale",
                "restarted_at": last_restart or None, "checked_at": checked_at}
    if verdict not in ("HEALTHY", "WEDGED"):
        # CANNOT-RUN, or anything the supervisor did not define.
        return {"state": "cannot_check", "reason": "last probe could not run",
                "restarted_at": last_restart or None, "checked_at": checked_at}
    if last_restart > 0:
        return {"state": "restarted", "reason": "", "restarted_at": last_restart, "checked_at": checked_at}
    return {"state": "running", "reason": "", "restarted_at": None, "checked_at": checked_at}


def _parse_iso(value) -> float | None:
    # The supervisor writes UTC with a Z suffix (now_iso). timegm reads it as UTC.
    if not isinstance(value, str) or not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


def _local_time(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).strftime("%H:%M on %d %b")


def render_engine_watchdog_status(status: dict | None = None) -> str:
    try:
        st = status if status is not None else read_engine_watchdog_status()
    except Exception as exc:  # noqa: BLE001
        return ('<div class="section"><h2>Background engine</h2>'
                f'<p class="muted">Background engine: couldn\'t check ({html.escape(type(exc).__name__)}).</p></div>')
    if st.get("state") == "restarted" and st.get("restarted_at"):
        line = ("Background engine: a system service was stuck and was restarted at "
                f"{html.escape(_local_time(st['restarted_at']))}.")
    elif st.get("state") == "running":
        line = "Background engine: running normally."
    else:
        line = "Background engine: couldn't check."
    return f'<div class="section"><h2>Background engine</h2><p>{line}</p></div>'
