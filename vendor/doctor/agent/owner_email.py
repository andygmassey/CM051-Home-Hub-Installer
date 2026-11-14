"""The owner's own email addresses, as the Doctor sees them.

The file is written by the installer (CM051 lib/owner_addresses.py) and by the
Doctor setter below. Both write mode 0600, atomically. Addresses are never
logged. Absent file: None. Corrupt file: status "unreadable".
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Optional

_ADDR = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$")


def owner_file() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "state" / "owner_addresses.json"


def read_owner_state(path: Optional[Path] = None) -> Optional[dict]:
    p = path or owner_file()
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"status": "unreadable", "addresses": []}
    if not isinstance(data, dict):
        return {"status": "unreadable", "addresses": []}
    addrs = [str(a).strip().lower() for a in data.get("addresses") or []]
    addrs = [a for a in addrs if _ADDR.match(a)]
    status = data.get("status") if data.get("status") in ("ok", "none", "unreadable") else "unreadable"
    return {"status": status, "addresses": addrs}


def write_owner_addresses(addresses, path: Optional[Path] = None) -> None:
    """The Doctor setter. Refuses anything that is not an address."""
    clean = []
    for a in addresses:
        v = str(a).strip().lower()
        if not _ADDR.match(v):
            raise ValueError("not an email address")
        clean.append(v)
    p = path or owner_file()
    p.parent.mkdir(parents=True, exist_ok=True)
    payload = {"schema": 1, "status": "ok" if clean else "none", "addresses": sorted(set(clean))}
    fd, tmp = tempfile.mkstemp(prefix=".owner_addresses.", dir=str(p.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, sort_keys=True)
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
