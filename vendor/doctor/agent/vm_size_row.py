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
import shutil
import subprocess
from pathlib import Path
from typing import Any, Optional

_GIB = 1024 ** 3
_LIST_TIMEOUT_S = 10


def colima_bin(candidates: Optional[list[str]] = None) -> str:
    """The colima binary that exists, in order of preference.

    Apple Silicon Homebrew is /opt/homebrew, Intel Homebrew is /usr/local, and a
    customer's PATH may hold either. The Doctor's fix commands must name the one
    that is really there, so this resolves it instead of hard-coding one prefix.
    With none found it returns the bare name, which the shell resolves (or fails
    on, visibly) rather than a guessed path.
    """
    if candidates is None:
        candidates = [
            shutil.which("colima") or "",
            os.path.join(os.environ.get("HOMEBREW_PREFIX", ""), "bin", "colima")
            if os.environ.get("HOMEBREW_PREFIX") else "",
            "/opt/homebrew/bin/colima",
            "/usr/local/bin/colima",
        ]
    for c in candidates:
        if c and os.access(c, os.X_OK) and os.path.isfile(c):
            return c
    return "colima"


def fix_command_smaller() -> str:
    c = colima_bin()
    return f"{c} stop && {c} start"


def fix_command_unknown() -> str:
    return f"{colima_bin()} list"


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
    """(cpus, memory_gib) of the `default` colima instance, or None.

    `colima list --json` is NDJSON: one object per line, one line per profile.
    It is parsed line by line. A whole-text json.loads raises on two profiles and
    made the row "unknown" on every Mac with more than one. A line that is not
    JSON is skipped; the default's own line must still be complete.
    """
    if not list_json:
        return None
    rows: list = []
    for line in list_json.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, list):  # a JSON array on one line, the older shape
            rows.extend(parsed)
        elif isinstance(parsed, dict):
            rows.append(parsed)
    for row in rows:
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
                "text": "Background engine: VM size record missing, sized from host"}
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
    binary = colima_bin()
    listing = None
    if os.path.isabs(binary) and os.access(binary, os.X_OK):
        try:
            out = subprocess.run([binary, "list", "--json"], capture_output=True, text=True,
                                 timeout=_LIST_TIMEOUT_S, stdin=subprocess.DEVNULL, check=False)
            listing = out.stdout if out.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            listing = None
    return record, listing
