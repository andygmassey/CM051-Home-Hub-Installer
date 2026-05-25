from __future__ import annotations

import os


def _load_dotenv(path):
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
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            if key not in os.environ:
                os.environ[key] = value


_config_dir = os.path.dirname(os.path.abspath(__file__))
_load_dotenv(os.path.join(_config_dir, ".env"))
_load_dotenv(".env")

CALENDAR_API_URL = os.environ.get("CALENDAR_API_URL", "http://localhost:8089")
QDRANT_URL = os.environ.get("QDRANT_URL", "")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "people")
OXIGRAPH_URL = os.environ.get("OXIGRAPH_URL", "")
EMBED_OLLAMA_URL = os.environ.get("EMBED_OLLAMA_URL", "")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
STATE_FILE = os.environ.get("MEETING_STATE_FILE", "./meeting_state.json")
USER_ID = os.environ.get("USER_ID", "")
# Comma-separated list of the user's own email addresses (filtered from attendees)
OWNER_EMAILS = [
    e.strip().lower()
    for e in os.environ.get("OWNER_EMAILS", os.environ.get("OWNER_EMAIL", "")).split(",")
    if e.strip()
]
DEFAULT_COUNTRY_CODE = int(os.environ.get("DEFAULT_COUNTRY_CODE", "852"))
