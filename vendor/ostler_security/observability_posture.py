"""Observability-posture self-attestation for hourly LaunchAgents.

Sibling of ``posture.py`` -- where ``posture.py`` records security
posture (encryption on / off, key source, backend) so Ostler Doctor
can render a "is this Mac secure right now?" tile, this module
records observability posture (did the last LaunchAgent tick
succeed? what did it process?) so Doctor can render a "are the
hourly jobs healthy?" tile.

The two are deliberately separated:

- A security marker is rewritten on service start and answers
  "is encryption on?".
- An observability marker is rewritten on every LaunchAgent tick
  and answers "did the last tick succeed and what did it touch?".

Different domains, different write cadence, different consumers.

Marker contract (JSON at
``~/.ostler/observability-posture/<service>.json``):

::

    {
      "service": "email-ingest",
      "last_tick_at": "<ISO-8601 UTC>",
      "last_tick_status": "success" | "fda_denied" | "mailbox_unreadable"
                        | "extract_failed" | "other",
      "last_error_message": null | "<truncated string>",
      "mail_count_processed_this_tick": <int>,
      "oldest_processed": null | "<ISO-8601 UTC>",
      "newest_processed": null | "<ISO-8601 UTC>",
      "pid": <int>,
      "schema_version": 1
    }

Field shape mirrors the spec in
``andygmassey/HR015-Gaming-PC#48`` review comment by Andy
(2026-05-01) for the email-ingest LaunchAgent. Future LaunchAgents
that need different observability metrics can either reuse this
shape (rename ``mail_count_processed_this_tick`` cheaply with one
caller) or grow a sibling function. We chose literal-to-spec over
premature generalisation; a second caller will reveal the right
abstraction.

**Doctor wiring is a separate PR** (per Andy's review comment): this
module writes the marker, but no Doctor surface reads it yet. The
contract lives here so Doctor can pick it up without a coordinated
change.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

OBSERVABILITY_POSTURE_SCHEMA_VERSION = 1

# Cap so a long traceback in last_error_message can't bloat the
# marker file. 1 KiB is plenty for a one-line summary; full
# tracebacks belong in the LaunchAgent stderr log, not the marker.
_ERROR_MESSAGE_LIMIT = 1024
_ERROR_TRUNCATION_SUFFIX = "... [truncated]"

# Allowed status values. Andy's spec lists five; catch-all is
# "other" so a caller cannot accidentally type a typo and have it
# silently accepted as a new status.
_ALLOWED_STATUSES = frozenset(
    {"success", "fda_denied", "mailbox_unreadable", "extract_failed", "other"}
)


def _posture_dir() -> Path:
    """Return ``~/.ostler/observability-posture/``, creating it if missing.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments;
    defaults to ``~/.ostler/``.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    posture = base / "observability-posture"
    posture.mkdir(parents=True, exist_ok=True)
    return posture


def _truncate(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    if len(value) <= _ERROR_MESSAGE_LIMIT:
        return value
    keep = _ERROR_MESSAGE_LIMIT - len(_ERROR_TRUNCATION_SUFFIX)
    return value[:keep] + _ERROR_TRUNCATION_SUFFIX


def _iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def record_observability_posture(
    service: str,
    *,
    last_tick_at: datetime,
    last_tick_status: str,
    last_error_message: Optional[str] = None,
    mail_count_processed_this_tick: int = 0,
    oldest_processed: Optional[datetime] = None,
    newest_processed: Optional[datetime] = None,
) -> Path:
    """Write the observability-posture marker for ``service``.

    Args:
        service: Short identifier matching the deployed service
            name (e.g. "email-ingest", "wiki-recompile").
        last_tick_at: When this tick fired. Pass UTC.
        last_tick_status: One of "success", "fda_denied",
            "mailbox_unreadable", "extract_failed", "other". A typo
            is rejected with ValueError so a future caller cannot
            silently invent a new status.
        last_error_message: For non-success statuses, the human-
            readable failure summary. Truncated to 1 KiB so a long
            traceback cannot bloat the marker; the full traceback
            goes to the LaunchAgent stderr log.
        mail_count_processed_this_tick: Email-ingest-specific. Other
            services pass 0.
        oldest_processed: Email-ingest-specific. Backward edge of
            the two-checkpoint progressive backfill. ``None`` once
            the backfill has consumed the entire mailbox history.
        newest_processed: Email-ingest-specific. Forward edge.

    Returns:
        Path to the written marker file.

    Never raises (other than the ValueError on bad status). Marker
    write failures are logged at WARNING. The marker is a
    diagnostic, not load-bearing -- the tick should still succeed
    even if Doctor can't read its status afterwards.
    """
    if last_tick_status not in _ALLOWED_STATUSES:
        raise ValueError(
            f"last_tick_status must be one of {sorted(_ALLOWED_STATUSES)}, "
            f"got {last_tick_status!r}"
        )

    payload = {
        "service": service,
        "last_tick_at": _iso(last_tick_at),
        "last_tick_status": last_tick_status,
        "last_error_message": _truncate(last_error_message),
        "mail_count_processed_this_tick": int(mail_count_processed_this_tick),
        "oldest_processed": _iso(oldest_processed),
        "newest_processed": _iso(newest_processed),
        "pid": os.getpid(),
        "schema_version": OBSERVABILITY_POSTURE_SCHEMA_VERSION,
    }

    marker = _posture_dir() / f"{service}.json"
    try:
        tmp = marker.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        tmp.replace(marker)
    except OSError as exc:
        logger.warning(
            "Could not write observability-posture marker at %s: %s",
            marker, exc,
        )
    return marker


def read_observability_posture(service: str) -> Optional[dict]:
    """Read the observability-posture marker for ``service``, or None.

    Used by Doctor to render the per-service tile. Returns ``None``
    when the marker is missing, unreadable, or malformed JSON.
    """
    marker = _posture_dir() / f"{service}.json"
    if not marker.exists():
        return None
    try:
        data = json.loads(marker.read_text())
    except (OSError, ValueError) as exc:
        logger.warning(
            "Could not read observability-posture marker %s: %s", marker, exc,
        )
        return None
    if not isinstance(data, dict):
        return None
    return data


def all_observability_postures() -> dict[str, dict]:
    """Return every observability-posture marker keyed by service name.

    Skips markers that fail to parse. Doctor uses this for the
    cross-service overview alongside ``posture.all_postures()``.
    """
    out: dict[str, dict] = {}
    for marker in _posture_dir().glob("*.json"):
        if marker.suffix != ".json":
            continue
        service = marker.stem
        data = read_observability_posture(service)
        if data is not None:
            out[service] = data
    return out
