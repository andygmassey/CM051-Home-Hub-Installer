"""
Ostler Doctor -- Configuration panel backend (backlog #261).

Reads and (for a small whitelist of clearly-safe fields) writes the
customer-editable Ostler settings file at
``~/.ostler/config/config.yaml``. The Doctor "Configuration" surface
lets the customer view and adjust safe settings without hand-editing
YAML.

Design notes
------------
* Same conventions as ``import_evernote.py``: YAML via PyYAML, an
  ``OSTLER_HOME`` / ``OSTLER_CONFIG_FILE`` env override so tests point
  at a tmp file, and an errors class that carries an HTTP status so the
  FastAPI route in ``web_ui.py`` can map cleanly.

* This module deliberately governs ONLY a Doctor-owned settings file in
  ``~/.ostler/config/``. It never touches the assistant daemon's live
  TOML config -- corrupting that risks the running daemon, so it is out
  of scope by design (see backlog #261 safety valve).

* Secrets are NEVER rendered. Any field whose key looks secret-like
  (token / key / password / secret / credential) is reported as
  presence-only ("set" / "not set") and is never returned as a value
  and never writable through this panel.

* The editable set is a strict whitelist. Anything not on the whitelist
  is read-only: it is displayed (non-secret) but cannot be written. A
  write to an unknown or non-whitelisted field is rejected.

* Writes are atomic (temp file + os.replace) and preserve any keys the
  panel does not understand, so a newer config file written by another
  tool is never clobbered.
"""

from __future__ import annotations

import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

import yaml  # PyYAML, listed in doctor/agent/requirements.txt


# -- Default paths ----------------------------------------------------

DEFAULT_OSTLER_DIR = Path.home() / ".ostler"
DEFAULT_CONFIG_FILE = DEFAULT_OSTLER_DIR / "config" / "config.yaml"


def _config_file() -> Path:
    """Resolve the config.yaml path.

    ``OSTLER_CONFIG_FILE`` wins (tests, non-default deployments), then
    ``OSTLER_HOME`` (matching ``imessage_tcc_posture.py``), then the
    home-dir default.
    """
    raw = os.environ.get("OSTLER_CONFIG_FILE")
    if raw:
        return Path(raw)
    home = os.environ.get("OSTLER_HOME")
    if home:
        return Path(home) / "config" / "config.yaml"
    return DEFAULT_CONFIG_FILE


def _governor_env_file() -> Path:
    """Resolve the path of the shell-sourceable governor bridge file.

    This is the file the background-work engine
    (``~/.ostler/lib/ostler-resource-tier.sh``) actually reads. The panel
    writes YAML for humans AND this KEY=VALUE file for the engine, which
    closes the writer/reader gap that made the old Config page a no-op.

    ``OSTLER_GOVERNOR_ENV_FILE`` wins; otherwise it sits beside the
    resolved ``config.yaml`` so a test that relocates the config also
    relocates the bridge file.
    """
    raw = os.environ.get("OSTLER_GOVERNOR_ENV_FILE")
    if raw:
        return Path(raw)
    return _config_file().parent / "governor.env"


# -- Errors -----------------------------------------------------------


@dataclass
class ConfigError(Exception):
    """Carries an HTTP status so the FastAPI handler maps cleanly.

    Mirrors ``import_evernote.EvernoteImportError`` /
    ``wiki_correct.ValidationError``.

    * 400 -- bad request body / unknown field / failed validation
    * 403 -- attempt to write a read-only or secret field
    * 500 -- filesystem error reading or writing the config file
    """

    status: int
    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.detail


# -- Secret detection -------------------------------------------------

# Any field key matching one of these substrings is treated as a secret:
# never rendered as a value, never writable through the panel.
_SECRET_KEY_PATTERNS = re.compile(
    r"(token|secret|password|passwd|api[_-]?key|\bkey\b|credential)",
    re.IGNORECASE,
)


def is_secret_key(key: str) -> bool:
    """True iff ``key`` looks secret-like and must never be rendered."""
    return bool(_SECRET_KEY_PATTERNS.search(key))


# -- Whitelist of editable fields -------------------------------------
#
# Each entry describes ONE clearly-safe, flat top-level field the panel
# may write. Anything not here is read-only. The set is intentionally
# minimal: only the two background-work controls (Pause + Throttle) that
# are actually wired through to the engine live here. Editing these
# cannot corrupt the assistant daemon's live state because this is a
# Doctor-owned file.
#
# ``kind`` drives both the rendered control and the validator:
#   bool   -- checkbox; accepts true/false
#   enum   -- dropdown; value must be in ``choices``
#   time   -- HH:MM 24h time string
#
# ``label`` and ``help`` are display copy. ``section`` groups fields in
# the rendered panel.

@dataclass(frozen=True)
class FieldSpec:
    key: str
    kind: str
    label: str
    section: str
    help: str = ""
    choices: tuple[str, ...] = ()


EDITABLE_FIELDS: tuple[FieldSpec, ...] = (
    # -- Background work ---------------------------------------------
    # The two controls Andy asked for: a Pause and a throttle. Both are
    # written straight through to the shell governor via governor.env, so
    # they take effect on the next background tick -- no daemon restart.
    FieldSpec(
        key="background_paused",
        kind="bool",
        label="Pause background work",
        section="Background work",
        help=(
            "Stop the background catch-up (conversation ingest, wiki "
            "refresh, summaries) until you switch this off. Chatting with "
            "your assistant still works while paused."
        ),
    ),
    FieldSpec(
        key="background_throttle",
        kind="enum",
        label="Background work speed",
        section="Background work",
        help=(
            "How hard the background catch-up may push your Mac. "
            "'gentle' eases off and saves the heavy work for overnight; "
            "'balanced' matches the work to your hardware (recommended); "
            "'full' runs it as fast as possible."
        ),
        choices=("gentle", "balanced", "full"),
    ),
    # NOTE: the earlier Channels / Model / Schedule / Privacy controls
    # were REMOVED (Batch-2 review #6 F6). They wrote keys into
    # config.yaml that NO daemon reads -- the assistant daemon's live
    # state lives in ~/.ostler/assistant-config/config.toml, not here --
    # so they were dead controls that silently did nothing and compounded
    # the confusion around the (real, wired) Pause + Throttle controls
    # above. Rather than ship a panel where two controls work and six do
    # nothing, the dead controls are gone. Wiring them through to the
    # daemon TOML (channels have consent implications; brief times are the
    # daemon's cron schedule) is a separate, larger piece of work. The
    # channels remain editable via `ostler-assistant setup channels
    # --interactive`, which the installer already points customers to.
)

_FIELD_BY_KEY: dict[str, FieldSpec] = {f.key: f for f in EDITABLE_FIELDS}


# Section display order for the rendered panel. Only the "Background
# work" section survives -- it holds the two controls (Pause + Throttle)
# that actually reach the engine. The Channels / Model / Schedule /
# Privacy sections were removed with their dead controls (see the note in
# EDITABLE_FIELDS).
SECTION_ORDER: tuple[str, ...] = (
    "Background work",
)


_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


# -- Read -------------------------------------------------------------


def _load_raw(path: Optional[Path] = None) -> dict[str, Any]:
    """Load the config file as a dict.

    A missing file is an empty config (the panel renders defaults /
    "not set"). Malformed YAML or a non-mapping document raises
    ``ConfigError(500)`` so the panel surfaces the problem rather than
    silently writing over a file it could not parse.
    """
    p = path or _config_file()
    if not p.is_file():
        return {}
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(500, f"Could not read config file: {exc}")
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ConfigError(500, f"Config file is not valid YAML: {exc}")
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ConfigError(500, "Config file root must be a mapping.")
    return data


def _coerce_display(value: Any) -> str:
    """Render a non-secret scalar for display."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def read_config_view(path: Optional[Path] = None) -> dict[str, Any]:
    """Return the panel's view model.

    Shape::

        {
          "config_path": "<expanded path>",
          "exists": bool,
          "editable": [
            {"key", "kind", "label", "section", "help", "choices",
             "value", "is_set"}
          ],
          "read_only": [
            {"key", "value" | None, "is_secret", "is_set"}
          ],
        }

    ``editable`` lists every whitelisted field in section order, with the
    current value (or ``None`` if unset). ``read_only`` lists every other
    top-level key found in the file: non-secret keys carry their value
    (presence + value), secret-looking keys carry ``value: null`` and
    ``is_secret: true`` so the panel shows "set" / "not set" only.

    NOTE: secret values are never placed in the returned structure.
    """
    raw = _load_raw(path)

    editable: list[dict[str, Any]] = []
    for spec in EDITABLE_FIELDS:
        present = spec.key in raw
        value = raw.get(spec.key)
        editable.append(
            {
                "key": spec.key,
                "kind": spec.kind,
                "label": spec.label,
                "section": spec.section,
                "help": spec.help,
                "choices": list(spec.choices),
                "value": value if present else None,
                "is_set": present,
            }
        )

    read_only: list[dict[str, Any]] = []
    for key in sorted(raw.keys()):
        if key in _FIELD_BY_KEY:
            continue  # surfaced under editable
        secret = is_secret_key(key)
        value = raw[key]
        is_set = value is not None and value != ""
        read_only.append(
            {
                "key": key,
                # Presence-only for secrets: value is withheld entirely.
                "value": None if secret else _coerce_display(value),
                "is_secret": secret,
                "is_set": bool(is_set),
            }
        )

    return {
        "config_path": str(_config_file()),
        "exists": bool(raw) or (path or _config_file()).is_file(),
        "editable": editable,
        "read_only": read_only,
    }


# -- Validate + write -------------------------------------------------


def _validate_one(spec: FieldSpec, value: Any) -> Any:
    """Validate + normalise a single whitelisted field value.

    Raises ``ConfigError(400)`` on any failure. Returns the normalised
    value to persist.
    """
    if spec.kind == "bool":
        if isinstance(value, bool):
            return value
        if isinstance(value, str) and value.lower() in ("true", "false"):
            return value.lower() == "true"
        raise ConfigError(400, f"{spec.key} must be true or false.")

    if spec.kind == "enum":
        if not isinstance(value, str) or value not in spec.choices:
            allowed = ", ".join(spec.choices)
            raise ConfigError(
                400, f"{spec.key} must be one of: {allowed}."
            )
        return value

    if spec.kind == "time":
        if not isinstance(value, str) or not _TIME_RE.match(value):
            raise ConfigError(
                400, f"{spec.key} must be a 24h time, HH:MM (e.g. 09:00)."
            )
        return value

    # Unreachable for known specs; defensive.
    raise ConfigError(400, f"{spec.key} has an unknown field type.")


def validate_updates(updates: Any) -> dict[str, Any]:
    """Validate a dict of ``{field_key: value}`` updates.

    Rejects (in order): non-dict body, empty body, unknown keys,
    secret-looking keys, then per-field validation. Returns the
    normalised dict ready to merge.
    """
    if not isinstance(updates, dict):
        raise ConfigError(400, "Request body must be a JSON object.")
    if not updates:
        raise ConfigError(400, "No fields to update.")

    normalised: dict[str, Any] = {}
    for key, value in updates.items():
        if is_secret_key(key):
            # Defence in depth: a secret-looking key can never be
            # written through the panel even if it somehow appeared in
            # the whitelist.
            raise ConfigError(
                403, f"{key} is a protected field and cannot be edited here."
            )
        spec = _FIELD_BY_KEY.get(key)
        if spec is None:
            raise ConfigError(
                403, f"{key} is read-only and cannot be edited here."
            )
        normalised[key] = _validate_one(spec, value)
    return normalised


def _atomic_write(path: Path, data: dict[str, Any]) -> None:
    """Write ``data`` as YAML to ``path`` atomically."""
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.safe_dump(data, default_flow_style=False, sort_keys=True)
    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent), prefix=".config-", suffix=".yaml.tmp"
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
        raise ConfigError(500, f"Could not write config file: {exc}")


# -- Governor bridge (the file the background-work engine reads) ------
#
# The old defect: the panel wrote config.yaml that NO daemon read, so
# toggles silently did nothing. The background-work engine is a shell
# library that reads environment variables, so the contract between panel
# (Python writer) and engine (shell reader) is a tiny KEY=VALUE file it
# sources. We regenerate it from the full merged config on every write so
# it always matches config.yaml.

# Throttle levels understood by the shell engine's OSTLER_THROTTLE_LEVEL.
_THROTTLE_LEVELS: tuple[str, ...] = ("gentle", "balanced", "full")


def render_governor_env(config: dict[str, Any]) -> str:
    """Render the governor settings as a shell-sourceable KEY=VALUE file.

    Only the two background-work controls are emitted; everything else in
    config.yaml is irrelevant to the shell engine. Unknown/blank values
    fall back to safe defaults (not paused, balanced) so a partial config
    never produces a malformed bridge file.
    """
    paused = bool(config.get("background_paused", False))
    throttle = config.get("background_throttle", "balanced")
    if throttle not in _THROTTLE_LEVELS:
        throttle = "balanced"
    return (
        "# Ostler background-work settings.\n"
        "# Written by the Doctor Settings panel; read by\n"
        "# ~/.ostler/lib/ostler-resource-tier.sh on the next background tick.\n"
        "# Do not hand-edit while the Settings panel is open.\n"
        f"export OSTLER_PAUSED={'1' if paused else '0'}\n"
        f"export OSTLER_THROTTLE_LEVEL={throttle}\n"
    )


def _write_governor_env(config: dict[str, Any], path: Optional[Path] = None) -> None:
    """Atomically write the governor bridge file the shell engine reads."""
    p = path or _governor_env_file()
    p.parent.mkdir(parents=True, exist_ok=True)
    text = render_governor_env(config)
    fd, tmp = tempfile.mkstemp(
        dir=str(p.parent), prefix=".governor-", suffix=".env.tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, p)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ConfigError(500, f"Could not write governor settings file: {exc}")


def write_config(updates: Any, path: Optional[Path] = None) -> dict[str, Any]:
    """Validate ``updates`` and merge them into the config file.

    Reads the existing file first and preserves every key the panel does
    not understand, so a newer/foreign config is never clobbered. After
    persisting config.yaml, regenerates the ``governor.env`` bridge so the
    background-work engine actually consumes the pause/throttle choices.
    Returns the fresh panel view model (so the client re-renders from
    authority).
    """
    p = path or _config_file()
    normalised = validate_updates(updates)
    current = _load_raw(p)
    current.update(normalised)
    _atomic_write(p, current)
    _write_governor_env(current)
    # If this write touched the Pause control, reflect it into the
    # assistant daemon's OWN cron scheduler too -- not just the shell
    # governor. The shell governor.env above stops the *-tick.sh
    # enrichment/ingest jobs; this stops the daemon-embedded cron that
    # fires the morning brief / evening wrap. Without it a Pause set at
    # 08:45 would still let the 09:00 brief fire (Batch-2 review #6 F1).
    if "background_paused" in normalised:
        # Local import: daemon_cron needs tomllib (3.11+) and is only
        # exercised on the write path, so a module-load failure never
        # breaks the read view.
        from daemon_cron import DaemonCronError, apply_pause_to_cron

        try:
            apply_pause_to_cron(bool(normalised["background_paused"]))
        except DaemonCronError as exc:
            # Surface as a ConfigError so the existing FastAPI handler
            # maps it and the operator is told the daemon cron could not
            # be paused (the shell-layer pause is already in force). We
            # fail loud rather than silently leaving the brief armed.
            raise ConfigError(exc.status, exc.detail)
    return read_config_view(p)
