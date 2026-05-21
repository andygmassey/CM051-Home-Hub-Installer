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

# -- Photos -------------------------------------------------------------------
# Extracted vCard PHOTOs are written as files (raw bytes, not base64) and
# referenced by path. L2 data like everything else in the People Graph —
# stays local.
PHOTO_DIR: str = os.environ.get(
    "PHOTO_DIR", os.path.expanduser("~/.pwg/people/photos")
)

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
# Display name as it appears in platform exports (FROM fields, sender headers,
# etc.). Used to disambiguate the user's own messages from other participants.
# Must be provided either via env or an explicit --user-name flag — we refuse
# to fall back to a hardcoded name so the CLI doesn't silently tag another
# user's data under the developer's identity (productisation rule).
USER_DISPLAY_NAME: str = os.environ.get("USER_DISPLAY_NAME", "") or os.environ.get("PWG_USER_NAME", "")
