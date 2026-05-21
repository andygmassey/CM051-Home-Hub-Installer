"""Structured JSON logging for CM048.

Adds conversation_id, step, component, and user_id to every log record
so logs are machine-parseable for monitoring, alerting, and debugging.

Usage:
    from src.log import configure_logging
    configure_logging(verbose=True, user_id="your_user_id")

All existing logger.info/warning/error calls continue to work —
the formatter wraps them in JSON automatically.
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone


class StructuredFormatter(logging.Formatter):
    """Emit each log record as a single-line JSON object."""

    def __init__(self, user_id: str = "unknown"):
        super().__init__()
        self.user_id = user_id

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "component": record.name,
            "msg": record.getMessage(),
            "user_id": self.user_id,
        }
        # Add conversation_id if set on the record (via extra= or filter)
        if hasattr(record, "conversation_id"):
            entry["conversation_id"] = record.conversation_id
        if hasattr(record, "step"):
            entry["step"] = record.step
        if record.exc_info and record.exc_info[1]:
            entry["error"] = str(record.exc_info[1])
            entry["error_type"] = type(record.exc_info[1]).__name__
        return json.dumps(entry, ensure_ascii=False)


class PlainFormatter(logging.Formatter):
    """Human-readable format for terminal/verbose mode."""

    def __init__(self):
        super().__init__(
            fmt="%(asctime)s %(levelname)s %(name)s: %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )


def configure_logging(
    *,
    verbose: bool = False,
    user_id: str = "unknown",
    json_mode: bool = False,
) -> None:
    """Set up logging for the pipeline.

    Args:
        verbose: if True, set DEBUG level; otherwise INFO.
        user_id: included in every structured log entry.
        json_mode: if True, emit JSON lines; otherwise human-readable.
    """
    root = logging.getLogger()
    root.setLevel(logging.DEBUG if verbose else logging.INFO)

    # Remove existing handlers to avoid duplicates on re-configure
    for h in root.handlers[:]:
        root.removeHandler(h)

    handler = logging.StreamHandler(sys.stderr)
    if json_mode:
        handler.setFormatter(StructuredFormatter(user_id=user_id))
    else:
        handler.setFormatter(PlainFormatter())

    root.addHandler(handler)

    # Suppress noisy httpx/httpcore debug logs unless verbose
    if not verbose:
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
