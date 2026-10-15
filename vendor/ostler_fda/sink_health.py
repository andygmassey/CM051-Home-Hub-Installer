"""One cheap health probe for the model sink `pwg-convo` talks to.

Used by the catch-up adapters to tell a hung DOCUMENT (counts toward
quarantine) from a dead SINK (counts nothing) after a dispatch timeout.
Standard library only; never proxied; bounded to a few seconds.
"""
from __future__ import annotations

import os
import urllib.error
import urllib.request

DEFAULT_OLLAMA_URL = "http://localhost:11434"


def ollama_healthy(timeout: float = 5.0) -> bool:
    """True when Ollama answers ``/api/tags`` with a 2xx inside ``timeout``."""
    base = (os.environ.get("OSTLER_OLLAMA_URL") or DEFAULT_OLLAMA_URL).rstrip("/")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(base + "/api/tags", timeout=timeout) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False
