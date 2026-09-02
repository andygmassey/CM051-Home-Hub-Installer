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


# ─── Enrichment context budget ────────────────────────────────────────────

# Fallback when the installer has not set a budget. Matches the daemon's own
# DEFAULT_NUM_CTX (crates/zeroclaw-providers/src/ollama.rs), which is the whole
# point: a background caller that requests a DIFFERENT window from the
# foreground daemon makes Ollama reload the model between the two sizes, which
# is the churn this module exists to stop.
_DEFAULT_ENRICH_NUM_CTX = 32768

# Below this a request cannot hold its own prompt. Mirrors the daemon's own
# floor so the two halves cannot disagree about what "too small" means.
_MIN_NUM_CTX = 2048


def resolve_enrich_num_ctx(default: int = _DEFAULT_ENRICH_NUM_CTX) -> int:
    """Return the context window a BACKGROUND enrichment request should use.

    WHY THIS IS NOT A CONSTANT. install.sh detects a resource tier and sets
    OSTLER_ENRICH_NUM_CTX per tier: unset on `high` (>=32 GB), 8192 on `low`,
    4096 on `floor`. A 16 GB Mac is `low`, and 16 GB is the installer's hard
    minimum, so the BASELINE supported machine wants 8192 here. Hardcoding
    32768 would ask the smallest supported box for four times its own budget,
    in the very code path added to be polite about resources.

    On `high` the variable is deliberately EMPTY, which means "no reduction":
    fall through to `default` so the background window matches the daemon's
    and no model reload happens between foreground and background turns.

    Garbage, empty, or below `_MIN_NUM_CTX` all fall back to `default`. A
    malformed budget must not silently shrink the window to something that
    truncates the prompt, because Ollama truncates SILENTLY.
    """
    raw = os.environ.get("OSTLER_ENRICH_NUM_CTX", "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    if value < _MIN_NUM_CTX:
        return default
    return value
