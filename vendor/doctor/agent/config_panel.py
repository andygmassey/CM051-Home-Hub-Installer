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
# may write. Anything not here is read-only. Keys are intentionally a
# small, conservative set: channel toggles, model selection, schedule
# times, and the privacy default. Editing these cannot corrupt the
# assistant daemon's live state because this is a Doctor-owned file.
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
    # -- Channels ----------------------------------------------------
    FieldSpec(
        key="imessage_enabled",
        kind="bool",
        label="iMessage",
        section="Channels",
        help="Let your assistant read and reply over iMessage.",
    ),
    FieldSpec(
        key="whatsapp_enabled",
        kind="bool",
        label="WhatsApp",
        section="Channels",
        help="Let your assistant read and reply over WhatsApp.",
    ),
    FieldSpec(
        key="email_enabled",
        kind="bool",
        label="Email",
        section="Channels",
        help="Let your assistant triage and reply to email.",
    ),
    # -- Model -------------------------------------------------------
    FieldSpec(
        key="assistant_model",
        kind="enum",
        label="Assistant model",
        section="Model",
        help="The local model your assistant uses to think and reply.",
        choices=(
            "qwen3.5:9b",
            "qwen2.5:14b",
            "qwen2.5:3b",
            "gemma4:e2b",
        ),
    ),
    # -- Schedule ----------------------------------------------------
    FieldSpec(
        key="morning_brief_time",
        kind="time",
        label="Morning brief",
        section="Schedule",
        help="When your assistant sends the morning brief (24h, HH:MM).",
    ),
    FieldSpec(
        key="evening_wrap_time",
        kind="time",
        label="Evening wrap",
        section="Schedule",
        help="When your assistant sends the evening wrap (24h, HH:MM).",
    ),
    # -- Privacy -----------------------------------------------------
    FieldSpec(
        key="default_privacy_level",
        kind="enum",
        label="Default privacy level",
        section="Privacy",
        help=(
            "The privacy level new conversations get by default. "
            "L3 is private by default and is never indexed for search."
        ),
        choices=("L0", "L1", "L2", "L3"),
    ),
    # -- Processing (resource throttle) ------------------------------
    # These map to the env knobs the tick wrappers + resource-tier lib
    # already consume. They are materialised into a sourced env file
    # (see the env bridge below) so a panel change actually changes
    # wrapper behaviour -- the contract the old panel was missing.
    FieldSpec(
        key="processing_preset",
        kind="enum",
        label="Processing speed",
        section="Processing",
        help=(
            "How hard Ostler works in the background. Overnight drains "
            "overnight and stays light by day; Gentle always stays light "
            "and never competes; Full speed runs at full width any time."
        ),
        choices=("overnight", "gentle", "full_speed"),
    ),
    FieldSpec(
        key="governor_enabled",
        kind="bool",
        label="Ease off when you are busy",
        section="Processing",
        help=(
            "Let Ostler automatically defer background work when your Mac "
            "is under load, so the things you are doing stay responsive."
        ),
    ),
    FieldSpec(
        key="quiet_hours_start",
        kind="time",
        label="Quiet hours start",
        section="Processing",
        help=(
            "Start of the overnight window when Ostler drains its full "
            "backlog (24h, HH:MM). Default 01:00."
        ),
    ),
    FieldSpec(
        key="quiet_hours_end",
        kind="time",
        label="Quiet hours end",
        section="Processing",
        help=(
            "End of the overnight window (24h, HH:MM). Outside this window "
            "Ostler only reads the last day or two. Default 06:00."
        ),
    ),
)

_FIELD_BY_KEY: dict[str, FieldSpec] = {f.key: f for f in EDITABLE_FIELDS}


# Section display order for the rendered panel.
SECTION_ORDER: tuple[str, ...] = (
    "Channels", "Model", "Schedule", "Privacy", "Processing",
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


def write_config(updates: Any, path: Optional[Path] = None) -> dict[str, Any]:
    """Validate ``updates`` and merge them into the config file.

    Reads the existing file first and preserves every key the panel does
    not understand, so a newer/foreign config is never clobbered. Returns
    the fresh panel view model (so the client re-renders from authority).

    After persisting the YAML, materialise the processing-relevant
    settings into the sourced env file the tick wrappers load
    (``sync_env_file``). This is the contract that makes a panel change
    actually change wrapper behaviour.
    """
    p = path or _config_file()
    normalised = validate_updates(updates)
    current = _load_raw(p)
    current.update(normalised)
    _atomic_write(p, current)
    sync_env_file(current)
    return read_config_view(p)


# -- Throttle env bridge (resource throttle: Parts 0, 2, 3) -----------
#
# The Config panel historically wrote ``config.yaml`` that no daemon or
# wrapper read, so toggles silently did nothing. The tick wrappers and
# the launchd-driven background jobs are env-driven, so we materialise
# the processing-relevant settings into a single sourced shell env file
# (``~/.ostler/config/ostler.env``) that every tick wrapper loads at the
# top. Whichever knob the panel writes, the wrappers consume it.

DEFAULT_ENV_FILE = DEFAULT_OSTLER_DIR / "config" / "ostler.env"

_DEFAULT_PRESET = "overnight"

# Each preset is a COMPLETE posture, mapped to the exact env names the
# wrappers + ``ostler-resource-tier.sh`` already consume:
#   overnight   -- the shipped default: drain overnight, stay light by day.
#   gentle      -- always light, yields to any real load, never competes.
#   full_speed  -- run any time at full width, effectively never defer.
_PRESET_ENV: dict[str, dict[str, str]] = {
    "overnight": {
        "OSTLER_INGEST_OFFPEAK_ONLY": "1",
        "OSTLER_INGEST_DAYTIME_SINCE_DAYS": "2",
    },
    "gentle": {
        "OSTLER_INGEST_OFFPEAK_ONLY": "1",
        "OSTLER_INGEST_DAYTIME_SINCE_DAYS": "1",
        "OSTLER_LOADAVG_CEILING": "0.4",
        "WIKI_LLM_WORKERS": "1",
        "OLLAMA_NUM_PARALLEL": "2",
    },
    "full_speed": {
        "OSTLER_INGEST_OFFPEAK_ONLY": "0",
        "OSTLER_INGEST_DAYTIME_SINCE_DAYS": "30",
        "OSTLER_LOADAVG_CEILING": "99",
    },
}


def _env_file(path: Optional[Path] = None) -> Path:
    """Resolve the sourced env-file path the wrappers load.

    ``OSTLER_ENV_FILE`` wins (tests, non-default deployments), then
    ``OSTLER_HOME``, then the home-dir default. Mirrors ``_config_file``.
    """
    if path is not None:
        return path
    raw = os.environ.get("OSTLER_ENV_FILE")
    if raw:
        return Path(raw)
    home = os.environ.get("OSTLER_HOME")
    if home:
        return Path(home) / "config" / "ostler.env"
    return DEFAULT_ENV_FILE


def _hour_of(value: Any, default: int) -> int:
    """Coerce an ``HH:MM`` config value to an integer hour (0-23).

    The off-peak window the wrappers gate on is hour-granular, so the
    minutes are intentionally dropped. Anything unparseable falls back
    to ``default`` so a malformed value can never wedge the window.
    """
    if isinstance(value, str) and _TIME_RE.match(value):
        try:
            return int(value.split(":", 1)[0])
        except (ValueError, IndexError):
            return default
    return default


def build_env_map(raw: dict[str, Any]) -> dict[str, str]:
    """Derive the env knob map from a raw config dict.

    The result is the union of the chosen preset's knobs, the governor
    on/off toggle, and the quiet-hours window. Returns a flat
    ``{NAME: value}`` map of plain strings.
    """
    preset = raw.get("processing_preset")
    if preset not in _PRESET_ENV:
        preset = _DEFAULT_PRESET
    env: dict[str, str] = dict(_PRESET_ENV[preset])

    # Governor toggle (defaults ON when unset). False disables the
    # load-aware defer entirely.
    governor = raw.get("governor_enabled")
    env["OSTLER_RESOURCE_GOVERNOR"] = "0" if governor is False else "1"

    # Quiet hours -> off-peak window bounds the wrappers read.
    start = _hour_of(raw.get("quiet_hours_start"), 1)
    end = _hour_of(raw.get("quiet_hours_end"), 6)
    env["OSTLER_INGEST_OFFPEAK_START_HOUR"] = str(start)
    env["OSTLER_INGEST_OFFPEAK_END_HOUR"] = str(end)

    return env


def build_env_lines(raw: dict[str, Any]) -> list[str]:
    """Render the env file body as a list of lines.

    Each knob becomes an ``export NAME=value`` line so the values reach
    the python pipelines the wrappers spawn, not just the wrapper shell.
    """
    lines = [
        "# Ostler processing settings -- generated by the Doctor Config",
        "# panel. Sourced by every background tick wrapper. Do not edit by",
        "# hand; your changes are overwritten on the next save.",
    ]
    for name, value in sorted(build_env_map(raw).items()):
        lines.append(f"export {name}={value}")
    return lines


def sync_env_file(
    raw: dict[str, Any], path: Optional[Path] = None
) -> Path:
    """Materialise the processing settings into the sourced env file.

    Atomic write (temp + ``os.replace``). Returns the path written.
    """
    p = _env_file(path)
    body = "\n".join(build_env_lines(raw)) + "\n"
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        dir=str(p.parent), prefix=".ostler-env-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, p)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ConfigError(500, f"Could not write env file: {exc}")
    return p
