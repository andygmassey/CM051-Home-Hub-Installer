"""Configuration loaded from environment variables and optional .env file."""
from __future__ import annotations

import logging
import os
from typing import Optional

logger = logging.getLogger(__name__)


def _load_dotenv(path: str = ".env") -> None:
    """Load key=value pairs from a .env file into os.environ.

    Simple parser -- no dependency on python-dotenv.  Supports blank lines,
    ``#`` comments, and optional quoting of values with single or double
    quotes.  Does NOT override variables that are already set in the
    environment.
    """
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            # Strip matching quotes
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            # Do not override existing env vars
            if key not in os.environ:
                os.environ[key] = value


# Load .env from the same directory as this config file, then from cwd
_config_dir = os.path.dirname(os.path.abspath(__file__))
_load_dotenv(os.path.join(_config_dir, ".env"))
_load_dotenv()  # also try cwd


# -- CardDAV ------------------------------------------------------------------
CARDDAV_URL: str = os.environ.get("CARDDAV_URL", "")
CARDDAV_USERNAME: str = os.environ.get("CARDDAV_USERNAME", "")
CARDDAV_PASSWORD: str = os.environ.get("CARDDAV_PASSWORD", "")

# -- Storage ------------------------------------------------------------------
QDRANT_URL: str = os.environ.get("QDRANT_URL", "")
QDRANT_COLLECTION: str = os.environ.get("QDRANT_COLLECTION", "people")
OXIGRAPH_URL: str = os.environ.get("OXIGRAPH_URL", "")

# -- Embedding ----------------------------------------------------------------
EMBED_OLLAMA_URL: str = os.environ.get("EMBED_OLLAMA_URL", "")
EMBED_MODEL: str = os.environ.get("EMBED_MODEL", "nomic-embed-text")
EMBED_BATCH_SIZE: int = int(os.environ.get("EMBED_BATCH_SIZE", "50"))

# -- State / Resolution -------------------------------------------------------
STATE_FILE: str = os.environ.get("STATE_FILE", "./state.json")
# DEFAULT_COUNTRY_CODE: installer should set this via DEFAULT_COUNTRY_CODE env var
# based on the customer's locale. None means phone-number normalisation falls back
# to international-format parsing only (no local-number disambiguation).
# Previously defaulted to 852 (Hong Kong) which is wrong for customers elsewhere.
_raw_country_code = os.environ.get("DEFAULT_COUNTRY_CODE")
DEFAULT_COUNTRY_CODE: Optional[int] = int(_raw_country_code) if _raw_country_code else None
if DEFAULT_COUNTRY_CODE is None:
    logger.warning(
        "DEFAULT_COUNTRY_CODE is not set; phone-number normalisation will use "
        "international format only. Set DEFAULT_COUNTRY_CODE in the environment "
        "or .env file (e.g. DEFAULT_COUNTRY_CODE=44 for UK, 1 for US)."
    )
DEFAULT_PRIVACY_LEVEL: str = os.environ.get("DEFAULT_PRIVACY_LEVEL", "L2")

# -- User ---------------------------------------------------------------------
USER_ID: str = os.environ.get("USER_ID", "")


def validate_required(
    *,
    require_carddav: bool = False,
    require_qdrant: bool = False,
    require_oxigraph: bool = False,
    require_embed: bool = False,
    _values: Optional[dict] = None,
) -> None:
    """Validate required env vars at module entry-point time.

    Two layers of check:

    1. Pair-coupling (always runs): if `CARDDAV_URL` is set, both
       `CARDDAV_USERNAME` and `CARDDAV_PASSWORD` must be non-empty.
       Setting a URL without credentials is a config error regardless
       of which module is calling -- the customer hit a partial install
       where the URL stuck but the credentials did not, and we want a
       clear error rather than a downstream 401 / connection-refused.

    2. Required-by-this-entry-point (opt-in via flags): the module's
       main() declares which URLs it actually uses. A module that
       does not talk to Qdrant should not hard-fail because
       `QDRANT_URL` is unset.

    The `_values` kwarg is for tests only -- it bypasses the
    module-level snapshot so each branch can be exercised without
    reload trickery. Real callers leave it unset.

    Raises ``RuntimeError`` with a single concatenated message
    listing every problem; never returns partial diagnostics.

    See ``/tmp/silent_fail_audit_2026-05-04.md`` HIGH-4.
    """
    cfg = _values if _values is not None else {
        "CARDDAV_URL": CARDDAV_URL,
        "CARDDAV_USERNAME": CARDDAV_USERNAME,
        "CARDDAV_PASSWORD": CARDDAV_PASSWORD,
        "QDRANT_URL": QDRANT_URL,
        "OXIGRAPH_URL": OXIGRAPH_URL,
        "EMBED_OLLAMA_URL": EMBED_OLLAMA_URL,
    }
    errors: list[str] = []

    # 1. Pair-coupling: setting CARDDAV_URL without credentials is an
    #    obvious config error -- the partial-install case the audit
    #    flagged.
    if cfg["CARDDAV_URL"] and (
        not cfg["CARDDAV_USERNAME"] or not cfg["CARDDAV_PASSWORD"]
    ):
        errors.append(
            "CARDDAV_URL is set but CARDDAV_USERNAME or CARDDAV_PASSWORD "
            "is empty -- set all three or none"
        )

    # 2. Required-by-this-entry-point: hard-require the URL (and, for
    #    CardDAV, the creds too) when the caller declares it uses them.
    if require_carddav:
        if (
            not cfg["CARDDAV_URL"]
            or not cfg["CARDDAV_USERNAME"]
            or not cfg["CARDDAV_PASSWORD"]
        ):
            errors.append(
                "CARDDAV_URL, CARDDAV_USERNAME and CARDDAV_PASSWORD must all "
                "be set for this entry point"
            )
    if require_qdrant and not cfg["QDRANT_URL"]:
        errors.append("QDRANT_URL must be set for this entry point")
    if require_oxigraph and not cfg["OXIGRAPH_URL"]:
        errors.append("OXIGRAPH_URL must be set for this entry point")
    if require_embed and not cfg["EMBED_OLLAMA_URL"]:
        errors.append("EMBED_OLLAMA_URL must be set for this entry point")

    if errors:
        raise RuntimeError(
            "contact_syncer config invalid:\n  - " + "\n  - ".join(errors)
        )
