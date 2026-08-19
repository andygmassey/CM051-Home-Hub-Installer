"""
Ostler Doctor -- daemon cron pause bridge (Batch-2 review #6 F1).

The Doctor Settings "Pause background work" control has two jobs:

1. Pause the SHELL-layer enrichment/ingest/wiki-recompile ticks. That is
   done by ``config_panel._write_governor_env`` writing ``OSTLER_PAUSED=1``
   into ``governor.env``, which every ``*-tick.sh`` sources.

2. Pause the ASSISTANT DAEMON'S OWN embedded cron scheduler -- the one
   that fires the morning brief (09:00) and evening wrap (18:00). THIS
   module does that. Without it, a Pause set at 08:45 still let the 09:00
   brief fire, because the shell governor never reaches the Rust daemon.

Why it works this way (verified against the daemon source)
----------------------------------------------------------
The daemon (``ostler-assistant`` / zeroclaw) reads its config from
``~/.ostler/assistant-config/config.toml``. Two facts about the shipped
daemon decide the mechanism:

* The scheduler supervisor is only spawned when ``[cron].enabled`` is
  true, and that is read ONCE at daemon start
  (``crates/zeroclaw-runtime/src/daemon/mod.rs``:
  ``if config.cron.enabled { spawn scheduler }``). The running scheduler
  holds a *cloned* ``Config`` by value, so mutating the daemon's live
  config over the HTTP API does NOT reach the running loop -- the change
  only takes effect on a daemon restart, when ``sync_declarative_jobs``
  reconciles ``[[cron.jobs]]`` (and per-job ``enabled``) into the DB and
  the supervisor re-reads ``[cron].enabled``.

* The per-tick fire query is ``WHERE enabled = 1 AND next_run <= now``.

So the honest, daemon-side way to stop the fire from CM051 (which cannot
rebuild the Rust daemon) is: set ``[cron].enabled = false`` in
``config.toml`` and restart the daemon in place with
``launchctl kickstart -k`` -- the same idiom ``install.sh`` already uses
after Full-Disk-Access grants. On restart the scheduler supervisor sees
``enabled = false`` and never starts; nothing fires until the operator
resumes (which sets it back to true and restarts again).

Fail-closed discipline
----------------------
Editing the daemon's live TOML is delicate -- a malformed file would
break the daemon. So every edit is validated by re-parsing the RESULT
with ``tomllib`` and asserting (a) it still parses, (b) ``cron.enabled``
is the value we intended, and (c) the ``[[cron.jobs]]`` are preserved
byte-for-byte in count. If any check fails we DO NOT write and raise,
leaving ``config.toml`` untouched (the shell-layer pause still applies).
If there is no daemon config, or no cron jobs to pause, this is a no-op.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

try:  # Python 3.11+
    import tomllib  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - old interpreters
    tomllib = None  # type: ignore


# The canonical LaunchAgent label for the assistant daemon (matches
# install.sh and assistant-agent/launchd/*.plist). Overridable for tests
# / non-default deployments.
DEFAULT_ASSISTANT_LABEL = "com.creativemachines.ostler.assistant"


@dataclass
class DaemonCronError(Exception):
    """Raised when the daemon cron gate cannot be applied safely.

    Carries an HTTP status so the FastAPI route maps cleanly, matching
    ``config_panel.ConfigError``.
    """

    status: int
    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.detail


def assistant_config_file() -> Path:
    """Resolve the daemon's ``config.toml`` path.

    ``OSTLER_ASSISTANT_CONFIG_FILE`` wins (tests / non-default installs),
    then ``OSTLER_HOME`` (``<home>/assistant-config/config.toml``), then
    the ``~/.ostler`` default. Kept independent of the Doctor YAML path so
    a test that points the YAML at a tmp dir does not accidentally touch
    the real daemon config unless it also sets this override.
    """
    raw = os.environ.get("OSTLER_ASSISTANT_CONFIG_FILE")
    if raw:
        return Path(raw)
    home = os.environ.get("OSTLER_HOME")
    if home:
        return Path(home) / "assistant-config" / "config.toml"
    return Path.home() / ".ostler" / "assistant-config" / "config.toml"


# ── TOML edit (surgical, text-level, tomllib-validated) ──────────────


_CRON_HEADER_RE = None  # lazily compiled below to avoid import-time cost


def _is_table_header(line: str) -> bool:
    s = line.strip()
    return s.startswith("[") and not s.startswith("[[") or s.startswith("[[")


def set_cron_enabled_text(text: str, enabled: bool) -> str:
    """Return ``text`` with ``[cron].enabled`` set to ``enabled``.

    Text-level so we never reformat the operator's file. Three cases:

    * a ``[cron]`` table with an ``enabled = ...`` line -> flip the value;
    * a ``[cron]`` table without one -> insert ``enabled`` after the header;
    * no ``[cron]`` table but at least one ``[[cron.jobs]]`` -> insert a
      ``[cron]`` table (with ``enabled``) immediately BEFORE the first
      ``[[cron.jobs]]`` header, because TOML forbids defining ``[cron]``
      after its ``cron.jobs`` array has been opened.

    The caller validates the result with ``tomllib`` before writing.
    """
    val = "true" if enabled else "false"
    lines = text.splitlines(keepends=True)

    # Locate the [cron] table header (exact table, not [cron.something]).
    cron_hdr_idx: Optional[int] = None
    first_cron_jobs_idx: Optional[int] = None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s == "[cron]":
            cron_hdr_idx = i
        if first_cron_jobs_idx is None and s == "[[cron.jobs]]":
            first_cron_jobs_idx = i

    if cron_hdr_idx is not None:
        # Scan the [cron] table body for an `enabled` key up to the next
        # table header.
        j = cron_hdr_idx + 1
        while j < len(lines):
            s = lines[j].strip()
            if s.startswith("[") :  # next table starts
                break
            if s.startswith("enabled") and "=" in s:
                indent = lines[j][: len(lines[j]) - len(lines[j].lstrip())]
                nl = "\n" if lines[j].endswith("\n") else ""
                lines[j] = f"{indent}enabled = {val}{nl}"
                return "".join(lines)
            j += 1
        # No `enabled` key inside [cron]: insert one right after the header.
        hdr_nl = "\n" if lines[cron_hdr_idx].endswith("\n") else "\n"
        lines.insert(cron_hdr_idx + 1, f"enabled = {val}{hdr_nl}")
        return "".join(lines)

    if first_cron_jobs_idx is not None:
        # No [cron] table yet: inject a managed one before the first job.
        block = f"[cron]\nenabled = {val}\n\n"
        lines.insert(first_cron_jobs_idx, block)
        return "".join(lines)

    # Nothing cron-related in the file: caller treats this as a no-op.
    return text


# ── Daemon restart (in-place, best-effort, test-injectable) ──────────


def _restart_daemon() -> dict:
    """Restart the assistant daemon in place so it re-reads config.toml.

    ``OSTLER_SKIP_DAEMON_RESTART=1`` skips the restart entirely (tests on
    a box with no daemon). ``OSTLER_ASSISTANT_RESTART_CMD`` overrides the
    command (tests capture it); it is shlex-split and run WITHOUT a shell.
    Otherwise the canonical ``launchctl kickstart -k gui/<uid>/<label>``
    is used -- the same call install.sh makes after an FDA grant.

    Returns a small status dict; never raises (a failed restart leaves the
    config change to take effect at the next natural daemon start, and the
    shell-layer pause is already active).
    """
    if os.environ.get("OSTLER_SKIP_DAEMON_RESTART") == "1":
        return {"restarted": False, "reason": "skipped"}

    override = os.environ.get("OSTLER_ASSISTANT_RESTART_CMD")
    if override:
        cmd = shlex.split(override)
    else:
        label = os.environ.get("OSTLER_ASSISTANT_LABEL", DEFAULT_ASSISTANT_LABEL)
        cmd = [
            "launchctl",
            "kickstart",
            "-k",
            f"gui/{os.getuid()}/{label}",
        ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"restarted": False, "reason": f"restart failed: {exc}"}
    if proc.returncode != 0:
        return {
            "restarted": False,
            "reason": f"restart exit {proc.returncode}: {proc.stderr.strip()}",
        }
    return {"restarted": True, "reason": "kickstart ok"}


def _atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent), prefix=".config-", suffix=".toml.tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise DaemonCronError(500, f"Could not write daemon config: {exc}")


# ── Public entry point ───────────────────────────────────────────────


def apply_pause_to_cron(
    paused: bool, *, config_path: Optional[Path] = None
) -> dict:
    """Reflect the operator Pause into the daemon's cron scheduler.

    Sets ``[cron].enabled = false`` when ``paused`` (``= true`` when
    resumed) in the daemon ``config.toml`` and restarts the daemon so the
    scheduler supervisor re-reads it. A Pause set at 08:45 therefore stops
    the 09:00 brief, which the shell-layer governor alone could not do.

    No-ops (``changed=False``, no restart) when there is no daemon config,
    no cron jobs to pause, or the gate is already in the desired state.
    Fail-closed: an edit that would not round-trip through ``tomllib`` is
    rejected and ``config.toml`` is left untouched.
    """
    p = config_path or assistant_config_file()
    if not p.is_file():
        return {"changed": False, "reason": "no daemon config"}

    if tomllib is None:  # pragma: no cover - old interpreters
        raise DaemonCronError(
            500, "Python 3.11+ (tomllib) is required to gate the daemon cron."
        )

    try:
        original_text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise DaemonCronError(500, f"Could not read daemon config: {exc}")

    try:
        data = tomllib.loads(original_text)
    except tomllib.TOMLDecodeError as exc:
        # Never edit a file we cannot parse.
        raise DaemonCronError(500, f"Daemon config is not valid TOML: {exc}")

    cron = data.get("cron")
    jobs = cron.get("jobs", []) if isinstance(cron, dict) else []
    has_cron_table = isinstance(cron, dict)
    # Nothing scheduled -> nothing to pause; don't gratuitously add a
    # [cron] table or restart the daemon.
    if not jobs and not has_cron_table:
        return {"changed": False, "reason": "no cron jobs"}

    desired = not paused
    current = bool(cron.get("enabled", True)) if has_cron_table else True
    if current == desired:
        return {"changed": False, "reason": "already in desired state"}

    new_text = set_cron_enabled_text(original_text, desired)
    if new_text == original_text:
        return {"changed": False, "reason": "no edit applied"}

    # Fail-closed validation: the result must parse, carry the intended
    # cron.enabled, and preserve every declarative job.
    try:
        new_data = tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as exc:
        raise DaemonCronError(
            500, f"Refusing to write: edited daemon config is invalid TOML: {exc}"
        )
    new_cron = new_data.get("cron", {})
    if not isinstance(new_cron, dict) or bool(new_cron.get("enabled", True)) != desired:
        raise DaemonCronError(
            500, "Refusing to write: cron.enabled did not take the intended value."
        )
    if len(new_cron.get("jobs", [])) != len(jobs):
        raise DaemonCronError(
            500, "Refusing to write: cron job count changed during the edit."
        )

    _atomic_write(p, new_text)
    restart = _restart_daemon()
    return {
        "changed": True,
        "paused": paused,
        "cron_enabled": desired,
        "config_path": str(p),
        "restart": restart,
    }
