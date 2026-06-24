"""Cross-process "user-active lease" reader for background Ollama callers.

The Ostler daemon (Rust) refreshes a lease file on every foreground chat
turn so background batch jobs (wiki recompile, this enrichment pipeline)
can yield their Ollama (:11434) slots to the user. This is the *reader*
half of the contract; the daemon owns the *writer* half.

Contract (agreed with the daemon side, Archie):

- Path: ``~/.ostler/run/ollama-user-active``.
- Format: a single integer = epoch-MILLIS "active until" (TTL ~8s,
  refreshed per foreground turn).
- Semantics: before starting a *new* background Ollama request, read the
  file; while ``now_ms < active_until``, sleep briefly and re-check. Never
  preempt an in-flight call.

Crash-safety: a missing or garbage lease file is treated as "idle" so a
background batch is never blocked by the daemon being absent, and a
stuck/far-future lease can never deadlock the run (``max_wait`` caps the
total yield).

Pure stdlib so it can be vendored / duplicated per repo without adding a
cross-repo dependency. Intentionally identical to the copies in the wiki
compiler (CM044) and the cm024 knowledge package -- three small copies,
no shared dep, no version-drift coupling.
"""
from __future__ import annotations

import os
import time
from pathlib import Path

# Default lease path. Override with OSTLER_USER_ACTIVE_LEASE for tests or
# non-standard layouts.
_DEFAULT_LEASE = "~/.ostler/run/ollama-user-active"


def _lease_path() -> Path:
    raw = os.environ.get("OSTLER_USER_ACTIVE_LEASE", _DEFAULT_LEASE)
    return Path(raw).expanduser()


def _read_active_until_ms(path: Path) -> int | None:
    """Return the lease's epoch-millis value, or None if absent/garbage."""
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, NotADirectoryError, IsADirectoryError, PermissionError, OSError):
        return None
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def wait_until_user_idle(
    poll: float = 0.5,
    max_wait: float = 30.0,
    *,
    path: Path | None = None,
) -> float:
    """Block while the user is active, then return.

    Reads the lease file and, while ``now_ms < active_until``, sleeps for
    ``poll`` seconds and re-checks. Returns the number of seconds spent
    waiting (0.0 if the user was idle).

    Args:
        poll: seconds between re-checks while the user is active.
        max_wait: hard cap on total wait so a stuck/far-future lease can
            never deadlock a batch run. Returns once exceeded even if the
            lease still reads active.
        path: override the lease path (test seam).

    Never raises on a missing/garbage lease -- that is treated as idle and
    returns immediately.
    """
    lease = path if path is not None else _lease_path()
    waited = 0.0
    while True:
        active_until = _read_active_until_ms(lease)
        if active_until is None:
            return waited
        now_ms = time.time() * 1000.0
        if now_ms >= active_until:
            return waited
        if waited >= max_wait:
            return waited
        step = min(poll, max(0.0, max_wait - waited))
        if step <= 0:
            return waited
        time.sleep(step)
        waited += step
