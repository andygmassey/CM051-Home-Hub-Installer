"""User settings loader for CM048.

Reads user preferences from a YAML file (defaults to
~/.ostler/settings.yaml under the two-zone layout; legacy
installs at ~/.pwg/settings.yaml are migrated on first
``load_settings`` call) and provides typed accessors. Falls back
to sensible defaults when the file is missing or fields are absent.

No PyPI `pydantic` dependency required -- this module sticks to stdlib
+ PyYAML so it can run in a lean venv.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from . import ostler_paths

try:
    import yaml  # type: ignore
except ImportError as exc:  # pragma: no cover
    # Hard-fail: silently downgrading to ``yaml = None`` means the
    # settings file is read as zero-bytes and every user customisation
    # vanishes -- they get hardcoded defaults with no indication that
    # their config wasn't loaded. The encryption-fallback fix in
    # commit cf4709d established the pattern for security-critical
    # imports; PyYAML is config-critical (not security-critical) but
    # the same hard-fail-loud principle applies. Pair with
    # ostler_security.posture.record_posture() at boot so a partial
    # install is loud, not silent.
    # See HR015/artefacts/2026-04-30/SILENT_FALLBACK_AUDIT_2026-04-30.md F6.
    raise RuntimeError(
        "CM048 settings module requires PyYAML. Install it with "
        "`pip install pyyaml` (or `pip install -e .` if you're using "
        "the package's pyproject.toml dependencies)."
    ) from exc


CoachingTone = Literal["direct", "supportive", "configurable"]
RedactionMode = Literal["mask", "keep"]
JobPriority = Literal["high", "medium", "low", "deferred"]


@dataclass
class RedactionPolicy:
    """Per-category redaction policy. Credentials and safeguarding
    are non-configurable — they're hardcoded."""

    financial: RedactionMode = "mask"
    medical: RedactionMode = "mask"
    legal: RedactionMode = "mask"
    contact_info: RedactionMode = "mask"
    policy_version: str = "default@1.0"


@dataclass
class WorkGeofence:
    enabled: bool = False
    addresses: list[str] = field(default_factory=list)
    radius_m: int = 100


@dataclass
class Settings:
    """Top-level user settings."""

    user_id: str = ""
    user_display_name: str = ""
    locale: str = "en-GB"
    coaching_tone: CoachingTone = "supportive"
    redaction: RedactionPolicy = field(default_factory=RedactionPolicy)
    work_geofence: WorkGeofence = field(default_factory=WorkGeofence)

    # LLM endpoints
    ollama_url: str = "http://localhost:11434"
    ollama_classify_model: str = "qwen3.5:9b"
    ollama_enrich_model: str = "qwen3.5:35b-a3b"
    ollama_fact_model: str = "qwen3.5:35b-a3b"
    ollama_relationship_model: str = "qwen3.5:35b-a3b"
    ollama_coach_model: str = "qwen3.5:35b-a3b"

    # Storage
    qdrant_url: str = "http://localhost:6333"
    oxigraph_url: str = "http://localhost:7878"
    qdrant_conversations_collection: str = "conversations"

    # Paths -- two-zone layout per
    # /tmp/tnm_brief_two_zone_architecture_2026-05-02.md.
    # Engine-room state under ~/.ostler/, customer-facing
    # artefacts under ~/Documents/Ostler/.
    processing_state_dir: Path = field(
        default_factory=ostler_paths.processing_dir
    )
    output_conversations_dir: Path = field(
        default_factory=ostler_paths.conversations_dir
    )
    coach_db_path: Path = field(
        default_factory=ostler_paths.coach_db_path
    )
    settings_path: Path = field(
        default_factory=ostler_paths.settings_yaml_path
    )

    def __post_init__(self) -> None:
        # Productisation guard (rebrand sweep PR-3 / audit P1-5):
        # the previous default of ``user_id = ""`` propagated empty
        # strings into every downstream call site. The shipping
        # path expects a real customer identifier from settings.yaml
        # or the OSTLER_USER_ID env var; an empty default lets a
        # mis-configured deploy run silently with no scope per user.
        # Fail loud at construction time -- callers must supply a
        # value (test fixtures already do; load_settings now
        # surfaces YAML / env values into the constructor before
        # this validation runs).
        if not self.user_id or not self.user_id.strip():
            raise ValueError(
                "user_id must be set. Provide it via settings.yaml "
                "(`user_id: <value>`) or the OSTLER_USER_ID env var."
            )


_FLAT_KEYS: tuple[str, ...] = (
    "user_id",
    "user_display_name",
    "locale",
    "coaching_tone",
    "ollama_url",
    "ollama_classify_model",
    "ollama_enrich_model",
    "ollama_fact_model",
    "ollama_relationship_model",
    "ollama_coach_model",
    "qdrant_url",
    "oxigraph_url",
    "qdrant_conversations_collection",
)

_PATH_KEYS: tuple[str, ...] = (
    "processing_state_dir",
    "output_conversations_dir",
    "coach_db_path",
)


def _apply_env_overrides_to_data(data: dict) -> None:
    """Mutate `data` in place with `OSTLER_*` env-var overrides so
    they are visible to ``Settings.__post_init__`` validation.

    Mirrors ``settings_from_env_override`` for callers that hit the
    fresh-load path; the post-construction helper below stays for
    backward compatibility with code that constructs a Settings
    instance another way.
    """
    if (v := os.environ.get("OSTLER_USER_ID")) is not None:
        data["user_id"] = v
    if (v := os.environ.get("OSTLER_USER_DISPLAY_NAME")) is not None:
        data["user_display_name"] = v
    if (v := os.environ.get("OSTLER_OLLAMA_URL")) is not None:
        data["ollama_url"] = v
    if (v := os.environ.get("OSTLER_QDRANT_URL")) is not None:
        data["qdrant_url"] = v
    if (v := os.environ.get("OSTLER_OXIGRAPH_URL")) is not None:
        data["oxigraph_url"] = v
    if (v := os.environ.get("OSTLER_STATE_DIR")) is not None:
        data["processing_state_dir"] = v


def load_settings(path: Path | None = None) -> Settings:
    """Load settings from YAML file + env overrides.

    Reads YAML (or starts with an empty dict if the file is missing),
    applies ``OSTLER_*`` env overrides on top, then constructs the
    Settings dataclass via keyword args so ``__post_init__`` validation
    sees the final user_id value. A missing user_id (no YAML, no env)
    raises ``ValueError`` rather than returning a silently-broken
    default.

    Runs the ~/.pwg/ -> ~/.ostler/ first-launch migration before
    resolving any paths. The migration is sentinel-gated and
    idempotent, so calling load_settings on every CLI invocation
    is cheap once the migration has completed.
    """
    # Best-effort migration. Failures are logged inside the
    # migration helper and do not block settings loading: in the
    # worst case we fall through to the new defaults pointing at
    # an empty ~/.ostler/, which is the same shape a fresh install
    # would have.
    if path is None:
        ostler_paths.migrate_pwg_dotdir_if_needed()

    target = path or ostler_paths.settings_yaml_path()

    data: dict = {}
    if target.exists():
        # PyYAML availability is asserted at import time (see top of
        # file); no runtime nil-check needed here.
        with open(target) as fh:
            data = yaml.safe_load(fh) or {}

    # Env overrides take precedence so a deploy with no YAML but
    # ``OSTLER_USER_ID`` set still constructs cleanly.
    _apply_env_overrides_to_data(data)

    kwargs: dict = {}
    for key in _FLAT_KEYS:
        if key in data:
            kwargs[key] = data[key]
    for key in _PATH_KEYS:
        if key in data:
            kwargs[key] = Path(data[key]).expanduser()
    if "settings_path" in data:
        kwargs["settings_path"] = Path(data["settings_path"]).expanduser()
    else:
        kwargs["settings_path"] = target

    redaction = data.get("redaction") or {}
    if redaction:
        kwargs["redaction"] = RedactionPolicy(
            financial=redaction.get("financial", "mask"),
            medical=redaction.get("medical", "mask"),
            legal=redaction.get("legal", "mask"),
            contact_info=redaction.get("contact_info", "mask"),
            policy_version=redaction.get("policy_version", "default@1.0"),
        )

    geo = data.get("work_geofence") or {}
    if geo:
        kwargs["work_geofence"] = WorkGeofence(
            enabled=bool(geo.get("enabled", False)),
            addresses=list(geo.get("addresses") or []),
            radius_m=int(geo.get("radius_m", 100)),
        )

    return Settings(**kwargs)


def ensure_directories(settings: Settings) -> None:
    """Create state / output / coach-db parent directories if missing."""
    settings.processing_state_dir.mkdir(parents=True, exist_ok=True)
    settings.output_conversations_dir.mkdir(parents=True, exist_ok=True)
    settings.coach_db_path.parent.mkdir(parents=True, exist_ok=True)


# Env-var overrides for test harness and CI.
#
# Path-related env vars follow a two-name precedence chain:
#   1. OSTLER_<NAME>     (productised, takes priority)
#   2. PWG_<NAME>        (legacy, kept for back-compat with early
#                         beta installs that already set these)
#
# Same shape as the CM042 Gap 1 chain (OSTLER_TRANSCRIPTS_DIR >
# CM042_TRANSCRIPT_DIR > UserDefaults > default).
def settings_from_env_override(s: Settings) -> Settings:
    def _path_env(*names: str) -> str | None:
        for name in names:
            v = os.environ.get(name)
            if v is not None:
                return v
        return None

    if (v := os.environ.get("OSTLER_USER_ID")) is not None:
        s.user_id = v
    if (v := os.environ.get("OSTLER_USER_DISPLAY_NAME")) is not None:
        s.user_display_name = v
    if (v := os.environ.get("OSTLER_OLLAMA_URL")) is not None:
        s.ollama_url = v
    if (v := os.environ.get("OSTLER_QDRANT_URL")) is not None:
        s.qdrant_url = v
    if (v := os.environ.get("OSTLER_OXIGRAPH_URL")) is not None:
        s.oxigraph_url = v

    if (v := _path_env("OSTLER_PROCESSING_DIR", "OSTLER_STATE_DIR",
                       "PWG_PROCESSING_DIR")) is not None:
        s.processing_state_dir = Path(v).expanduser()
    if (v := _path_env("OSTLER_CONVERSATIONS_DIR",
                       "PWG_CONVERSATIONS_DIR")) is not None:
        s.output_conversations_dir = Path(v).expanduser()
    if (v := _path_env("OSTLER_COACH_DB_PATH",
                       "PWG_COACH_DB_PATH")) is not None:
        s.coach_db_path = Path(v).expanduser()
    return s
