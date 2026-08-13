"""
Ostler Doctor -- background-work Pause control (governor.env backend).

This is the module ``box_status.py`` already imports (``from pause_control
import read_state``) and the three Doctor routes ``GET /api/v1/pause``,
``POST /api/v1/pause`` and ``POST /api/v1/resume`` delegate to. Before it
existed that import fail-softed to a permanent ``paused: False``, so the Hub
header status chip and Governor page could never reflect a real pause even
though the shell engine was already honouring one. See
``docs/SPEC_governor_status_indicator.md``.

Mechanism -- reuse the SHIPPED, TESTED reader path
--------------------------------------------------
The five ``*-bundle-tick.sh`` wrappers, the wiki recompile tick and the CM059
editor tick all call ``ostler_resource_tier_is_paused`` in
``~/.ostler/lib/ostler-resource-tier.sh``, which reads exactly two keys from
``governor.env``:

* ``OSTLER_PAUSED``       -- ``1`` == paused, anything else == running.
* ``OSTLER_PAUSE_UNTIL``  -- optional epoch-seconds soft self-expiry.

So this module reads and writes those same two keys. Pausing here is honoured
by every background surface with ZERO new consumer wiring -- we deliberately do
NOT introduce a second ``processing.paused`` sentinel (which nothing reads) and
we do NOT bootout the LaunchAgents (racy, not self-expiring, misses the wiki
recompile + daemon cron). Live interactive chat is NEVER gated by this -- pause
only stops the background enrichment / ingest / recompile storm.

Expiry semantics mirror ``ostler-resource-tier.sh::ostler_resource_tier_is_paused``
EXACTLY, so the Python reader (chip / Governor page) and the shell reader
(every tick) can never disagree:

* ``OSTLER_PAUSED != "1"``           -> not paused.
* empty / ``forever`` ``PAUSE_UNTIL`` -> paused until an explicit resume.
* non-numeric ``PAUSE_UNTIL``        -> FAIL OPEN (not paused) so a bad value
                                         can never wedge background work off.
* numeric ``PAUSE_UNTIL``            -> paused while ``now < until``, else the
                                         window has elapsed -> auto-resumed.

Scope -> expiry map (what the Governor page Pause button offers):

* ``"hour"``       -> ``now + 3600``.
* ``"tonight"``    -> the next local 01:00 (start of the overnight off-peak
                      window the ticks drain their backlog in).
* ``"indefinite"`` -> no ``PAUSE_UNTIL`` (paused until the operator resumes).

The write is atomic (temp file + ``os.replace``, same primitive as
``config_panel._write_governor_env``) and KEY-PRESERVING: it rewrites only the
two pause keys and leaves ``OSTLER_THROTTLE_LEVEL`` (and any other operator
setting in the file) untouched, so a Governor-page pause never clobbers the
Settings-panel throttle choice.

British English throughout. Deliberately dependency-free at import time
(no yaml / fastapi / tomllib) so ``read_state`` on the ~1 Hz box-status poll
path can never fail on a missing optional dependency. The Settings-panel and
daemon-cron coherence mirrors are best-effort, lazily imported, and never
allowed to break the load-bearing ``governor.env`` write.
"""

from __future__ import annotations

import os
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional


# -- Default paths ----------------------------------------------------

DEFAULT_OSTLER_DIR = Path.home() / ".ostler"
DEFAULT_GOVERNOR_ENV = DEFAULT_OSTLER_DIR / "config" / "governor.env"

# The two keys the shell engine honours. Kept as constants so the writer,
# the reader and the tests never drift on a typo.
KEY_PAUSED = "OSTLER_PAUSED"
KEY_PAUSE_UNTIL = "OSTLER_PAUSE_UNTIL"

# Valid pause scopes the Governor page may request (plus a handful of
# forgiving aliases so a client typo does not 400 a pause).
SCOPE_HOUR = "hour"
SCOPE_TONIGHT = "tonight"
SCOPE_INDEFINITE = "indefinite"

_SCOPE_ALIASES = {
    "hour": SCOPE_HOUR,
    "1h": SCOPE_HOUR,
    "1hour": SCOPE_HOUR,
    "60m": SCOPE_HOUR,
    "an_hour": SCOPE_HOUR,
    "tonight": SCOPE_TONIGHT,
    "until_tonight": SCOPE_TONIGHT,
    "until-tonight": SCOPE_TONIGHT,
    "off_peak": SCOPE_TONIGHT,
    "indefinite": SCOPE_INDEFINITE,
    "forever": SCOPE_INDEFINITE,
    "until_resume": SCOPE_INDEFINITE,
    "": SCOPE_INDEFINITE,
}

# The local hour the "until tonight" scope targets: the start of the overnight
# off-peak window the tick wrappers drain their full backlog in. Matches the
# 01:00 off-peak start the ingest ticks assume.
_TONIGHT_HOUR = 1


@dataclass
class PauseError(Exception):
    """Carries an HTTP status so the FastAPI handler maps cleanly.

    Mirrors ``config_panel.ConfigError`` so the web route can reuse the same
    ``except PauseError as exc: JSONResponse({"error": exc.detail}, exc.status)``
    shape.

    * 400 -- unknown / unusable pause scope.
    * 500 -- filesystem error writing the governor bridge file.
    """

    status: int
    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.detail


# -- Path resolution --------------------------------------------------


def governor_env_path() -> Path:
    """Resolve the governor bridge file both the Settings panel and the shell
    engine use.

    Resolution order keeps all three writers/readers (``config_panel`` writer,
    ``ostler-resource-tier.sh`` reader, this module) pointing at the SAME file
    on a real install, while letting a test relocate it:

    1. ``OSTLER_GOVERNOR_ENV_FILE`` -- exact file (matches ``config_panel``).
    2. ``OSTLER_GOVERNOR_SETTINGS`` -- exact file (matches the shell lib).
    3. ``OSTLER_CONFIG_FILE``       -- sibling ``governor.env`` (matches
       ``config_panel``'s default of placing it beside ``config.yaml``).
    4. ``OSTLER_HOME``              -- ``<home>/config/governor.env``.
    5. default                      -- ``~/.ostler/config/governor.env``.
    """
    raw = os.environ.get("OSTLER_GOVERNOR_ENV_FILE")
    if raw:
        return Path(raw)
    raw = os.environ.get("OSTLER_GOVERNOR_SETTINGS")
    if raw:
        return Path(raw)
    cfg = os.environ.get("OSTLER_CONFIG_FILE")
    if cfg:
        return Path(cfg).parent / "governor.env"
    home = os.environ.get("OSTLER_HOME")
    if home:
        return Path(home) / "config" / "governor.env"
    return DEFAULT_GOVERNOR_ENV


# -- governor.env parsing (mirrors the shell lib's defensive parser) ---


def _strip_export(line: str) -> str:
    """Strip a leading ``export `` from a KEY=VALUE line (shell parity)."""
    stripped = line.lstrip()
    if stripped.startswith("export "):
        return stripped[len("export ") :]
    return stripped


def _is_pause_key_line(line: str) -> bool:
    """True iff ``line`` assigns one of the two pause keys we own.

    Used by the key-preserving writer to drop existing pause assignments (so we
    never leave a duplicate) while keeping every other line -- throttle,
    comments, blanks, foreign keys.
    """
    body = _strip_export(line)
    return body.startswith(KEY_PAUSED + "=") or body.startswith(
        KEY_PAUSE_UNTIL + "="
    )


def _parse_values(text: str) -> dict[str, str]:
    """Parse the OSTLER_* assignments the same way the shell lib does.

    Only ``OSTLER_<A-Z0-9_>*=value`` lines are honoured; a leading ``export``
    is stripped and a single pair of matching surrounding quotes is removed.
    FIRST occurrence of a key wins, matching the shell's fill-if-unset loop.
    """
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        body = _strip_export(raw_line)
        if not body or body.startswith("#"):
            continue
        if "=" not in body:
            continue
        key, _, val = body.partition("=")
        # Only OSTLER_* uppercase/digit/underscore keys.
        if not key or not key.startswith("OSTLER_"):
            continue
        if not all(c.isupper() or c.isdigit() or c == "_" for c in key):
            continue
        # Strip a single pair of matching surrounding quotes.
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key not in values:  # first wins (shell parity)
            values[key] = val
    return values


# -- Reading ----------------------------------------------------------


def _human(epoch: int) -> str:
    """Render an expiry epoch as a short local time for the UI."""
    if epoch <= 0:
        return ""
    dt = datetime.fromtimestamp(epoch)
    if dt.date() == datetime.now().date():
        return dt.strftime("%H:%M")
    return dt.strftime("%a %H:%M")


def _not_paused(path: Path) -> dict[str, Any]:
    return {
        "paused": False,
        "expiry": None,
        "indefinite": False,
        "expiry_human": "",
        "scope": None,
        "governor_env_path": str(path),
    }


def read_state(path: Optional[Path] = None) -> dict[str, Any]:
    """Return the current pause state for the chip / Governor page.

    Shape (a superset of the fallback ``box_status._pause`` returns, so the
    header chip keeps working)::

        {"paused": bool, "expiry": int|None, "indefinite": bool,
         "expiry_human": str, "scope": str|None, "governor_env_path": str}

    Never raises and never writes: this runs on the ~1 Hz box-status poll, so a
    missing file, an unreadable file or a malformed value all degrade to a
    well-formed "not paused" payload (fail open -- the exact posture the shell
    lib takes) rather than 500-ing the poll or self-healing on the read path.
    """
    p = path or governor_env_path()
    try:
        if not p.is_file():
            return _not_paused(p)
        text = p.read_text(encoding="utf-8")
    except OSError:
        return _not_paused(p)

    values = _parse_values(text)
    if values.get(KEY_PAUSED, "0") != "1":
        return _not_paused(p)

    until_raw = values.get(KEY_PAUSE_UNTIL, "").strip()
    # Empty or "forever" -> paused until an explicit resume.
    if until_raw in ("", "forever"):
        return {
            "paused": True,
            "expiry": None,
            "indefinite": True,
            "expiry_human": "",
            "scope": SCOPE_INDEFINITE,
            "governor_env_path": str(p),
        }
    # Non-numeric -> fail open (never wedge background work off forever).
    if not until_raw.isdigit():
        return _not_paused(p)

    until = int(until_raw)
    if time.time() >= until:
        # Window elapsed -> auto-resumed. Report resumed; do NOT rewrite the
        # file here (this is the hot read path and the file also carries the
        # throttle choice). The next set_pause/resume tidies the stale line.
        return _not_paused(p)

    return {
        "paused": True,
        "expiry": until,
        "indefinite": False,
        "expiry_human": _human(until),
        "scope": SCOPE_HOUR if (until - time.time()) <= 3600 + 1 else SCOPE_TONIGHT,
        "governor_env_path": str(p),
    }


# -- Scope -> expiry --------------------------------------------------


def _next_tonight_epoch(now: Optional[float] = None) -> int:
    """Epoch of the next local ``_TONIGHT_HOUR``:00 (today if still ahead)."""
    base = datetime.now() if now is None else datetime.fromtimestamp(now)
    target = base.replace(hour=_TONIGHT_HOUR, minute=0, second=0, microsecond=0)
    if base >= target:
        target = target + timedelta(days=1)
    return int(target.timestamp())


def normalise_scope(scope: Optional[str]) -> str:
    """Map a client-supplied scope (or alias) to a canonical scope."""
    key = (scope or "").strip().lower()
    canonical = _SCOPE_ALIASES.get(key)
    if canonical is None:
        raise PauseError(400, f"Unknown pause scope: {scope!r}.")
    return canonical


def compute_expiry(scope: str, now: Optional[float] = None) -> Optional[int]:
    """Return the ``OSTLER_PAUSE_UNTIL`` epoch for a scope, or ``None`` for an
    indefinite pause (no expiry line)."""
    canonical = normalise_scope(scope)
    if canonical == SCOPE_INDEFINITE:
        return None
    if canonical == SCOPE_HOUR:
        base = time.time() if now is None else now
        return int(base) + 3600
    return _next_tonight_epoch(now)


# -- Writing (atomic + key-preserving) --------------------------------


_HEADER = (
    "# Ostler background-work settings.\n"
    "# OSTLER_PAUSED / OSTLER_PAUSE_UNTIL written by the Doctor Governor\n"
    "# controls; read by ~/.ostler/lib/ostler-resource-tier.sh on the next\n"
    "# background tick. Do not hand-edit while the Doctor is open.\n"
)


def _render_merged(existing: str, paused: bool, until: Optional[int]) -> str:
    """Rewrite only the two pause keys, preserving every other line.

    Existing ``OSTLER_PAUSED`` / ``OSTLER_PAUSE_UNTIL`` assignments are dropped
    (so we never leave a stale or duplicate line that the first-wins shell
    parser would honour over ours); throttle, comments and foreign keys survive
    untouched. Both keys are then appended exactly once.
    """
    kept: list[str] = []
    for line in existing.splitlines():
        if _is_pause_key_line(line):
            continue
        kept.append(line)

    body = "\n".join(kept).rstrip("\n")
    if not body.strip():
        body = _HEADER.rstrip("\n")

    until_val = "" if until is None else str(int(until))
    tail = (
        f"export {KEY_PAUSED}={'1' if paused else '0'}\n"
        f"export {KEY_PAUSE_UNTIL}={until_val}\n"
    )
    return body + "\n" + tail


def _atomic_write_text(path: Path, text: str) -> None:
    """Atomically replace ``path`` with ``text`` (temp file + os.replace)."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(
            dir=str(path.parent), prefix=".governor-", suffix=".env.tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as exc:
        raise PauseError(500, f"Could not write governor settings file: {exc}")


def _mirror_settings_panel(paused: bool) -> None:
    """Best-effort: keep the Settings-panel checkbox + daemon cron coherent.

    A Governor-page pause should also (a) show as ticked on the Settings panel
    and (b) suppress the daemon-embedded 09:00 brief / 18:00 wrap, exactly like
    a Settings-panel pause does. Both are best-effort and LAZILY imported:

    * ``config_panel``'s governor.env writer graft is not upstreamed to the
      Doctor source repo, and ``daemon_cron`` is a vendor-only module -- either
      import can legitimately be absent (e.g. running from the source tree). A
      failure here must NEVER break the load-bearing ``governor.env`` write
      above, so everything is swallowed.

    We mirror ``background_paused`` into ``config.yaml`` DIRECTLY (via
    ``config_panel``'s own ``_load_raw`` + ``_atomic_write``) rather than
    through ``write_config`` -- ``write_config`` would rewrite ``governor.env``
    from scratch and drop the ``OSTLER_PAUSE_UNTIL`` we just wrote.

    ``OSTLER_PAUSE_SKIP_MIRROR=1`` disables both mirrors -- used by the unit
    tests so they exercise the governor.env write in isolation without
    touching ``config.yaml`` or invoking ``launchctl`` via ``daemon_cron``.
    """
    if os.environ.get("OSTLER_PAUSE_SKIP_MIRROR", "").strip() in ("1", "true", "yes"):
        return
    try:  # config.yaml checkbox coherence
        import config_panel as _cp  # type: ignore

        cfg_path = _cp._config_file()
        current = _cp._load_raw(cfg_path)
        if bool(current.get("background_paused", False)) != paused:
            current["background_paused"] = paused
            _cp._atomic_write(cfg_path, current)
    except Exception:
        pass

    try:  # daemon brief / wrap coherence
        from daemon_cron import apply_pause_to_cron  # type: ignore

        apply_pause_to_cron(paused)
    except Exception:
        pass


def set_pause(
    scope: str, path: Optional[Path] = None, now: Optional[float] = None
) -> dict[str, Any]:
    """Pause background work for ``scope`` and return the fresh state."""
    until = compute_expiry(scope, now=now)  # raises PauseError(400) on bad scope
    p = path or governor_env_path()
    existing = ""
    try:
        if p.is_file():
            existing = p.read_text(encoding="utf-8")
    except OSError:
        existing = ""
    _atomic_write_text(p, _render_merged(existing, paused=True, until=until))
    _mirror_settings_panel(True)
    return read_state(p)


def resume(path: Optional[Path] = None) -> dict[str, Any]:
    """Resume background work (clear the pause) and return the fresh state.

    Idempotent: resuming when not paused is a no-op that still returns the
    correct not-paused state. Writes ``OSTLER_PAUSED=0`` and clears
    ``OSTLER_PAUSE_UNTIL`` while preserving the throttle choice.
    """
    p = path or governor_env_path()
    existing = ""
    try:
        if p.is_file():
            existing = p.read_text(encoding="utf-8")
    except OSError:
        existing = ""
    _atomic_write_text(p, _render_merged(existing, paused=False, until=None))
    _mirror_settings_panel(False)
    return read_state(p)


if __name__ == "__main__":  # function-verification entrypoint
    import json

    print(json.dumps(read_state(), indent=2))
