"""Security-posture self-attestation.

Each long-running Ostler service calls record_posture() at startup to
write a JSON marker describing whether encryption is actually
on or off RIGHT NOW. Ostler Doctor reads these markers to show a
single source of truth on the dashboard, so the user can verify at
a glance that every service is running in its full security mode.

This is the lighter cousin of a full security dashboard – the file
is the contract, the dashboard wiring is downstream.

Marker contract (JSON at ~/.ostler/security-posture/<service>.json):
    {
        "service": "ical-server",
        "encryption": "enabled" | "disabled",
        "reason": null | "no_key" | "no_module" | "...",
        "key_source": null | "OSTLER_DB_KEY",
        "backend": null | "sqlcipher" | "plaintext",
        "pid": <int>,
        "timestamp": "<ISO-8601 UTC>",
        "schema_version": 1,
    }

The marker is rewritten on every service start. Stale markers from a
crashed previous run are overwritten on next start; consumers should
treat the marker as a snapshot of the LAST successful boot, not as
proof the service is currently up. Pair with a liveness check.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

POSTURE_SCHEMA_VERSION = 1


def _posture_dir() -> Path:
    """Return ~/.ostler/security-posture/, creating it if missing.

    Honours $OSTLER_HOME for tests and non-default deployments;
    defaults to ~/.ostler/.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    posture = base / "security-posture"
    posture.mkdir(parents=True, exist_ok=True)
    return posture


def record_posture(
    service: str,
    encryption: str,
    reason: Optional[str] = None,
    key_source: Optional[str] = None,
    backend: Optional[str] = None,
) -> Path:
    """Write the security-posture marker for `service`.

    Args:
        service: Short identifier matching the deployed service name
            (e.g. "ical-server", "whatsapp-bridge", "cm048-ingest").
        encryption: "enabled" or "disabled".
        reason: When encryption is disabled, why. Free-form short
            string. Recommended values: "no_key", "no_module",
            "explicit_opt_out". None when encryption is enabled.
        key_source: Which env var supplied the key. Recommended
            value: "OSTLER_DB_KEY". None when disabled.
        backend: Storage backend in use. "sqlcipher" or "plaintext".

    Returns:
        Path to the written marker file.

    Never raises – writes the marker on a best-effort basis. A failed
    posture write is logged at WARNING but does not block service
    startup. The marker is a diagnostic, not load-bearing.
    """
    if encryption not in ("enabled", "disabled"):
        raise ValueError(
            f"encryption must be 'enabled' or 'disabled', got {encryption!r}"
        )
    payload = {
        "service": service,
        "encryption": encryption,
        "reason": reason,
        "key_source": key_source,
        "backend": backend,
        "pid": os.getpid(),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "schema_version": POSTURE_SCHEMA_VERSION,
    }
    marker = _posture_dir() / f"{service}.json"
    try:
        # Write atomically so a partial crash doesn't leave a corrupt
        # marker that confuses Doctor. tempfile + rename is overkill
        # for a 200-byte JSON; write to .tmp and rename.
        tmp = marker.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, indent=2) + "\n")
        tmp.replace(marker)
    except OSError as exc:
        logger.warning(
            "Could not write security-posture marker at %s: %s",
            marker, exc,
        )
    return marker


def read_posture(service: str) -> Optional[dict]:
    """Read the security-posture marker for `service`, or None if
    no marker exists or it is unreadable / malformed.

    Used by Doctor to render the security-posture dashboard tile.
    """
    marker = _posture_dir() / f"{service}.json"
    if not marker.exists():
        return None
    try:
        data = json.loads(marker.read_text())
    except (OSError, ValueError) as exc:
        logger.warning("Could not read posture marker %s: %s", marker, exc)
        return None
    if not isinstance(data, dict):
        return None
    return data


def all_postures() -> dict[str, dict]:
    """Return all known posture markers keyed by service name.

    Skips markers that fail to parse. Doctor uses this to render
    the cross-service overview.
    """
    out: dict[str, dict] = {}
    for marker in _posture_dir().glob("*.json"):
        if marker.suffix != ".json":
            continue
        service = marker.stem
        data = read_posture(service)
        if data is not None:
            out[service] = data
    return out
