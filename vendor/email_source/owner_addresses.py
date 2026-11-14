"""The owner's own email addresses, for the email and reply-debt consumers.

Read order (see lib/owner_addresses.py for the writer):
  1. the owner state file ($OSTLER_DIR/state/owner_addresses.json, mode 0600),
     written at install from Accounts4 (every mail account, plus aliases);
  2. the explicit argument / OSTLER_USER_EMAIL, if the file holds no address.

Addresses are never logged from here.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Optional

_ADDR = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$")
_SPLIT = re.compile(r"[,\s;]+")


def _clean(raw) -> list[str]:
    out = []
    for part in _SPLIT.split(str(raw or "")):
        a = part.strip().strip("<>").lower()
        if _ADDR.match(a):
            out.append(a)
    return out


def state_path() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "state" / "owner_addresses.json"


def _from_file(path: Optional[Path]) -> list[str]:
    try:
        data = json.loads((path or state_path()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    return _clean(" ".join(str(a) for a in data.get("addresses") or []))


def owner_set(user_address: str = "", *, state: Optional[Path] = None) -> frozenset:
    """Every address that is the owner's. File first, then the argument/env."""
    from_file = _from_file(state)
    if from_file:
        return frozenset(from_file)
    if not user_address:
        user_address = os.environ.get("OSTLER_USER_EMAIL", "")
    return frozenset(_clean(user_address))
