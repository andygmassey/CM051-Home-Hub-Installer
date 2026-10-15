"""ONE health predicate for everything `pwg-convo` writes to.

Used by the catch-up adapters to tell a hung DOCUMENT (counts toward
quarantine) from a dead SINK (counts nothing) after a dispatch timeout.

The sink is Ollama (model) AND the Qdrant and Oxigraph stores behind the store
proxy. The likely day-one outage is the colima VM: Ollama up, stores down. So
the predicate is both:

  * Ollama answers ``/api/tags`` (checked here), and
  * the stores answer 2xx through the proxy with the install credential. THAT
    check is NOT re-implemented here: its canonical home is
    ``bin/ostler-engine-supervisor.sh --probe-ports`` (the supervisor's own
    port-judged predicate, the walk predicate), which this module runs. One
    implementation, so the supervisor and the catch-up cannot drift.

Anything that cannot be judged (supervisor missing or too old for the
subcommand, no credential yet) is NOT healthy: a dispatch timeout is then read
as the sink's fault and counts no attempt, which only ever delays a retry.
Standard library only; never proxied; every call bounded.
"""
from __future__ import annotations

import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

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


def _supervisor() -> Path:
    override = os.environ.get("OSTLER_ENGINE_SUPERVISOR", "").strip()
    if override:
        return Path(override)
    home = os.environ.get("OSTLER_DIR", "").strip() or str(Path.home() / ".ostler")
    return Path(home) / "bin" / "ostler-engine-supervisor.sh"


def stores_answer(timeout: float = 30.0) -> bool:
    """True when the supervisor's canonical check says Qdrant AND Oxigraph
    answer 2xx through the proxy credential (exit 0). 1 = a store is down;
    2, a missing supervisor or any error = could not judge: not healthy."""
    sup = _supervisor()
    if not sup.is_file():
        return False
    try:
        r = subprocess.run(["/bin/bash", str(sup), "--probe-ports"], capture_output=True,
                           timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def sink_healthy() -> bool:
    """Ollama AND the stores. Both must answer."""
    return ollama_healthy() and stores_answer()
