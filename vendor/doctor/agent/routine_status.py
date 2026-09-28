"""Live status of every recurring ingest routine (Doctor, v1.0.106).

No FastAPI or httpx imports, so it can be tested and imported alone.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


# ── ROUTINES: every recurring ingest job, measured live (v1.0.106) ─────
#
# Andy, 2026-09-28, second time of asking: a Doctor tab showing which data
# sources are in, which run on a routine, when each last ran and whether it
# is working. /api/v1/sources answers "did it land at install" and merges
# only the fda-rerun activity record, so on the v1.0.105 walk box it said
# email and imessage were no_data 0 while 11,507 emails and every iMessage
# had been read by their own routines. The routines were never on it.
#
# This reads each routine's OWN surfaces, never a sentinel: its LaunchAgent
# plist (label, interval), launchd (loaded, running, last exit code) and its
# log (last run time, and the counts it printed on its last run).

_ROUTINES = (
    # (label, what it keeps up to date, log stem)
    ("com.creativemachines.ostler.email-ingest", "Email (full history)", "email-ingest"),
    ("com.creativemachines.ostler.email-bundle", "Email conversations", "email-bundle"),
    ("com.creativemachines.ostler.imessage-bundle", "iMessage conversations", "imessage-bundle"),
    ("com.creativemachines.ostler.whatsapp-bundle", "WhatsApp conversations", "whatsapp-bundle"),
    ("com.creativemachines.ostler.spoken-bundle", "Spoken (transcripts)", "spoken-bundle"),
    ("com.ostler.fda-rerun", "Calendar, Notes, Photos, Safari, contacts", "fda-rerun"),
    ("com.ostler.aiconv-resume", "AI chats", "aiconv-resume"),
    ("com.ostler.enrich", "Enrichment (people, books, places)", "enrich"),
)
_routine_cache: dict = {"at": 0.0, "rows": []}


def _launchd_state(label: str) -> dict:
    import subprocess
    try:
        out = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception as exc:
        return {"loaded": None, "running": None, "last_exit": None,
                "error": exc.__class__.__name__}
    if out.returncode != 0:
        return {"loaded": False, "running": False, "last_exit": None}
    state = re.search(r"^\s*state = (\S+)", out.stdout, re.M)
    code = re.search(r"^\s*last exit code = (-?\d+)", out.stdout, re.M)
    return {"loaded": True,
            "running": bool(state and state.group(1) == "running"),
            "last_exit": int(code.group(1)) if code else None}


def _latest_counts(log: Path) -> dict:
    """The integer counts the routine printed on its last run: the last JSON
    object in the log tail, else an 'Emitted N' line. Counts only."""
    try:
        with open(log, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 16384))
            tail = fh.read().decode("utf-8", "replace")
    except OSError:
        return {}
    end = tail.rfind("}")
    while end != -1:
        start = tail.rfind("{", 0, end)
        depth_ok = False
        while start != -1:
            try:
                obj = json.loads(tail[start:end + 1])
                depth_ok = True
                break
            except ValueError:
                start = tail.rfind("{", 0, start)
        if depth_ok and isinstance(obj, dict):
            flat = {}
            for k, v in obj.items():
                if isinstance(v, bool):
                    continue
                if isinstance(v, int):
                    flat[k] = v
                elif isinstance(v, dict):
                    for k2, v2 in v.items():
                        if isinstance(v2, int) and not isinstance(v2, bool):
                            flat[f"{k}.{k2}"] = v2
            if flat:
                return flat
        end = tail.rfind("}", 0, end)
    m = re.findall(r"Emitted (\d+) message", tail)
    return {"emitted": int(m[-1])} if m else {}


def read_routine_status(launch_dir: Path | None = None,
                        log_dir: Path | None = None) -> list:
    """One row per recurring ingest routine, measured live (cached 30 s)."""
    import plistlib
    import time as _time
    if launch_dir is None and log_dir is None and _time.time() - _routine_cache["at"] < 30:
        return _routine_cache["rows"]
    launch_dir = launch_dir or (Path.home() / "Library" / "LaunchAgents")
    root = Path(os.environ.get("OSTLER_DIR", str(Path.home() / ".ostler")))
    log_dir = log_dir or (root / "logs")
    now = _time.time()
    rows = []
    for label, keeps, stem in _ROUTINES:
        plist = launch_dir / f"{label}.plist"
        row = {"routine": label, "keeps_up_to_date": keeps,
               "installed": plist.is_file(), "interval_s": None,
               "last_run_at": None, "latest": {}, "health": "not_installed",
               "reason": "no LaunchAgent on this Mac"}
        if not row["installed"]:
            rows.append(row)
            continue
        try:
            row["interval_s"] = plistlib.loads(plist.read_bytes()).get("StartInterval")
        except Exception:
            pass
        row.update(_launchd_state(label))
        mtimes = [f.stat().st_mtime for f in (log_dir / f"{stem}.log", log_dir / f"{stem}.err")
                  if f.is_file()]
        last = max(mtimes) if mtimes else None
        if last:
            row["last_run_at"] = datetime.fromtimestamp(last, timezone.utc).isoformat()
        row["latest"] = _latest_counts(log_dir / f"{stem}.log")
        interval = row["interval_s"] or 3600
        if row.get("loaded") is False:
            row["health"], row["reason"] = "failing", "the routine is not loaded in launchd"
        elif row.get("last_exit") not in (None, 0) and not row.get("running"):
            row["health"], row["reason"] = "failing", f"last run exited with code {row['last_exit']}"
        elif last is None:
            row["health"], row["reason"] = "waiting", "has not run yet"
        elif now - last > 3 * interval + 300:
            row["health"], row["reason"] = "stale", f"no run for {int((now - last) // 60)} min"
        else:
            row["health"], row["reason"] = "ok", "running on schedule"
        rows.append(row)
    if launch_dir == Path.home() / "Library" / "LaunchAgents":
        _routine_cache.update(at=now, rows=rows)
    return rows

