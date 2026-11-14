"""Background engine size: what the installer chose, and what is running.

CONTRACT. The CM051 installer records its choice in ~/.ostler/state/vm_size
(lib/ostler-vm-size.sh, ostler_vm_record_size). Keys: cpus=, memory_gib=. The
daemon restarts colima at that size (oa src/main.rs, recorded_vm_size). The
running size comes from `colima list --json`.

WHY (2026-11-14, Mini16). The installer sized the VM at 3 CPU / 6 GiB while
colima.yaml kept 2/4, and a restart shrank it again. A shrunk VM is silent: the
wiki compiler is OOM-killed inside it and nothing says why. So this row says
which size is running, and names the fix when it is smaller than installed.

EVERY OUTCOME IS NAMED. "ok", "smaller", "unrecorded" and "unknown" are the
only states. A missing record or an unanswering colima is "unknown", never ok.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

COLIMA = "/opt/homebrew/bin/colima"
FIX_COMMAND_SMALLER = f"{COLIMA} stop && {COLIMA} start"
FIX_COMMAND_UNKNOWN = f"{COLIMA} list"
_GIB = 1024 ** 3
_LIST_TIMEOUT_S = 10


def record_path() -> Path:
    state = os.environ.get("OSTLER_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ostler", "state")
    return Path(state) / "vm_size"


def parse_record(text: Optional[str]) -> Optional[tuple[int, int]]:
    """(cpus, memory_gib) from the record, or None. A bad record is no size."""
    if not text:
        return None
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    try:
        cpus = int(values["cpus"])
        memory_gib = int(values["memory_gib"])
    except (KeyError, ValueError):
        return None
    if cpus < 1 or memory_gib < 1:
        return None
    return cpus, memory_gib


def parse_running(list_json: Optional[str]) -> Optional[tuple[int, int]]:
    """(cpus, memory_gib) of the `default` colima instance, or None."""
    if not list_json:
        return None
    try:
        rows = json.loads(list_json)
    except ValueError:
        return None
    if isinstance(rows, dict):
        rows = [rows]
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict) or row.get("name") != "default":
            continue
        try:
            cpus = int(row["cpus"])
            memory_gib = int(round(int(row["memory"]) / _GIB))
        except (KeyError, TypeError, ValueError):
            return None
        return cpus, memory_gib
    return None


def evaluate(record_text: Optional[str], list_json: Optional[str]) -> dict[str, Any]:
    """The Doctor's background-engine row. `state` is one of the four named states."""
    recorded = parse_record(record_text)
    running = parse_running(list_json)
    if recorded is None:
        return {"state": "unrecorded", "recorded": None, "running": running,
                "text": "Background engine: size not recorded (update Ostler to record it)"}
    if running is None:
        return {"state": "unknown", "recorded": recorded, "running": None,
                "text": "Background engine: couldn't check the running size"}
    rc, rm = recorded
    cpus, mem = running
    if cpus < rc or mem < rm:
        return {"state": "smaller", "recorded": recorded, "running": running,
                "text": (f"Background engine: {cpus} CPU / {mem} GB, smaller than "
                         f"installed ({rc} CPU / {rm} GB): restart Ostler to fix")}
    return {"state": "ok", "recorded": recorded, "running": running,
            "text": f"Background engine: {cpus} CPU / {mem} GB (installed size)"}


def read_inputs() -> tuple[Optional[str], Optional[str]]:
    """(record text, `colima list --json` text). Either is None when unreadable."""
    try:
        record = record_path().read_text(encoding="utf-8")
    except OSError:
        record = None
    binary = next((c for c in (COLIMA, "/usr/local/bin/colima") if os.access(c, os.X_OK)), None)
    listing = None
    if binary is not None:
        try:
            out = subprocess.run([binary, "list", "--json"], capture_output=True, text=True,
                                 timeout=_LIST_TIMEOUT_S, stdin=subprocess.DEVNULL, check=False)
            listing = out.stdout if out.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            listing = None
    return record, listing
