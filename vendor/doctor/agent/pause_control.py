"""
Ostler Doctor -- Pause control backend (resource throttle, Part 1).

Lets the customer pause all BACKGROUND processing (the five tick
wrappers + the wiki recompile) from the Doctor UI. Live chat and the
assistant daemon's foreground turns are never paused -- only the
background ingest / enrich / recompile work that can hammer the box on
first-run / onboarding week.

Mechanism: a sentinel file at ``~/.ostler/run/processing.paused`` whose
first line is the expiry epoch (UTC seconds):

* a positive integer    -> paused until that epoch
* ``0`` (or empty)      -> paused indefinitely, until the user resumes

Every tick wrapper checks this file at the top (via
``lib/ostler-runtime.sh``) and exits 0 if it is present and unexpired.
Resume deletes the sentinel.

Conventions mirror ``config_panel.py``: an ``OSTLER_HOME`` /
``OSTLER_RUN_DIR`` / ``OSTLER_PAUSE_SENTINEL`` env override so tests can
point at a tmp file, and a ``PauseError`` carrying an HTTP status so the
FastAPI route maps cleanly. British English throughout.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional


# -- Default paths ----------------------------------------------------

DEFAULT_OSTLER_DIR = Path.home() / ".ostler"
DEFAULT_SENTINEL = DEFAULT_OSTLER_DIR / "run" / "processing.paused"

# Valid pause scopes the UI may request.
SCOPE_HOUR = "hour"
SCOPE_TONIGHT = "tonight"
SCOPE_INDEFINITE = "indefinite"
VALID_SCOPES = (SCOPE_HOUR, SCOPE_TONIGHT, SCOPE_INDEFINITE)

# The quiet-hours start the "until tonight" scope targets. The wrappers
# drain their full backlog from this hour; pausing "until tonight" hands
# back control until the overnight window opens.
_TONIGHT_HOUR = 1


@dataclass
class PauseError(Exception):
    """Carries an HTTP status so the FastAPI handler maps cleanly."""

    status: int
    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.detail


def sentinel_path() -> Path:
    """Resolve the pause sentinel path.

    ``OSTLER_PAUSE_SENTINEL`` wins (tests), then ``OSTLER_RUN_DIR``, then
    ``OSTLER_HOME``, then the home-dir default.
    """
    raw = os.environ.get("OSTLER_PAUSE_SENTINEL")
    if raw:
        return Path(raw)
    run_dir = os.environ.get("OSTLER_RUN_DIR")
    if run_dir:
        return Path(run_dir) / "processing.paused"
    home = os.environ.get("OSTLER_HOME")
    if home:
        return Path(home) / "run" / "processing.paused"
    return DEFAULT_SENTINEL


def _next_tonight_epoch(now: Optional[float] = None) -> int:
    """Epoch of the next local ``_TONIGHT_HOUR``:00.

    If it is currently before that hour, target today; otherwise target
    tomorrow.
    """
    base = datetime.now() if now is None else datetime.fromtimestamp(now)
    target = base.replace(
        hour=_TONIGHT_HOUR, minute=0, second=0, microsecond=0
    )
    if base >= target:
        target = target + timedelta(days=1)
    return int(target.timestamp())


def compute_expiry(scope: str, now: Optional[float] = None) -> int:
    """Return the expiry epoch for a scope. ``0`` means indefinite."""
    if scope not in VALID_SCOPES:
        raise PauseError(400, f"Unknown pause scope: {scope!r}.")
    if scope == SCOPE_INDEFINITE:
        return 0
    if scope == SCOPE_HOUR:
        base = time.time() if now is None else now
        return int(base) + 3600
    # tonight
    return _next_tonight_epoch(now)


def _read_expiry(path: Path) -> Optional[int]:
    """Read the expiry epoch from the sentinel, or None if unreadable.

    ``0`` / empty / non-numeric all read as indefinite (returned as 0).
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    first = text.strip().splitlines()[0].strip() if text.strip() else ""
    if first in ("", "0", "never", "forever"):
        return 0
    try:
        return int(first)
    except ValueError:
        # Unparseable -> treat as indefinite (honour the pause intent;
        # the Resume control always clears it).
        return 0


def _human(epoch: int) -> str:
    """Render an expiry epoch as a short local time for the UI."""
    if epoch <= 0:
        return ""
    dt = datetime.fromtimestamp(epoch)
    # Show the time, plus the date if it is not today.
    if dt.date() == datetime.now().date():
        return dt.strftime("%H:%M")
    return dt.strftime("%a %H:%M")


def read_state(path: Optional[Path] = None) -> dict[str, Any]:
    """Return the current pause state for the UI.

    Auto-clears an expired sentinel so the state is self-healing even if
    no tick has run since expiry. Shape::

        {"paused": bool, "expiry": int|None, "indefinite": bool,
         "expiry_human": str, "sentinel_path": str}
    """
    p = path or sentinel_path()
    if not p.is_file():
        return {
            "paused": False,
            "expiry": None,
            "indefinite": False,
            "expiry_human": "",
            "sentinel_path": str(p),
        }

    expiry = _read_expiry(p)
    if expiry is None:
        # Present but unreadable -- report paused-indefinite rather than
        # silently claiming "not paused" (the file exists for a reason).
        return {
            "paused": True,
            "expiry": 0,
            "indefinite": True,
            "expiry_human": "",
            "sentinel_path": str(p),
        }

    if expiry > 0 and time.time() >= expiry:
        # Expired: self-heal and report resumed.
        try:
            p.unlink()
        except OSError:
            pass
        return {
            "paused": False,
            "expiry": None,
            "indefinite": False,
            "expiry_human": "",
            "sentinel_path": str(p),
        }

    return {
        "paused": True,
        "expiry": expiry,
        "indefinite": expiry == 0,
        "expiry_human": _human(expiry),
        "sentinel_path": str(p),
    }


def write_pause(
    scope: str, path: Optional[Path] = None, now: Optional[float] = None
) -> dict[str, Any]:
    """Write the pause sentinel for ``scope`` and return the new state."""
    p = path or sentinel_path()
    expiry = compute_expiry(scope, now=now)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        # One integer line: the expiry epoch (0 == indefinite). A second
        # comment line records the scope for human inspection.
        p.write_text(f"{expiry}\n# scope={scope}\n", encoding="utf-8")
    except OSError as exc:
        raise PauseError(500, f"Could not write pause sentinel: {exc}")
    return read_state(p)


def clear_pause(path: Optional[Path] = None) -> dict[str, Any]:
    """Resume: delete the sentinel. Idempotent."""
    p = path or sentinel_path()
    try:
        if p.is_file():
            p.unlink()
    except OSError as exc:
        raise PauseError(500, f"Could not clear pause sentinel: {exc}")
    return read_state(p)
