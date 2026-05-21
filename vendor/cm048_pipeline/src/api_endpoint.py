"""API endpoint for CM048 conversation processing.

Designed for integration into the Hub's unified API server
(ical-server.py). This module provides a request handler that can be
wired into the existing BaseHTTPRequestHandler routing.

Integration instructions:
---------------------------------------------------------------------------
1. Copy this file alongside the Hub API server, e.g.:
     ~/.ostler/api/cm048_api.py

2. In ical-server.py, add this import near the top:
     from cm048_api import handle_conversation_process

3. In the do_POST method's routing, add this block:
     elif path == '/api/v1/conversation/process':
         handle_conversation_process(self)

4. Ensure CM048 is installed in the same Python environment:
     cd /path/to/CM048
     pip install -e .

   Or alternatively, ensure the CM048 src/ directory is on PYTHONPATH.
---------------------------------------------------------------------------

The endpoint accepts:
  POST /api/v1/conversation/process
  Content-Type: application/json
  Body: {
    "transcript_path": "/path/to/transcript.md",
    "metadata_path": "/path/to/metadata.json"
  }

Returns:
  200 with job result on success (synchronous processing)
  202 with job_id for async mode (future enhancement)
  400 on validation errors
  500 on processing errors
"""
from __future__ import annotations

import json
import logging
import traceback
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from . import copy as _copy

logger = logging.getLogger(__name__)

# Maximum POST body size (1 MB, matching ical-server.py's limit)
MAX_POST_SIZE = 1_048_576


def handle_conversation_process(handler: BaseHTTPRequestHandler) -> None:
    """Handle POST /api/v1/conversation/process.

    Validates input paths, then either calls the CM048 pipeline
    directly (if importable) or shells out to the CLI.

    Args:
        handler: the BaseHTTPRequestHandler instance from ical-server.py
    """
    # --- Read and validate request body ---
    content_length = int(handler.headers.get("Content-Length", 0))
    if content_length == 0:
        _send_error(handler, 400, _copy.ERROR_EMPTY_REQUEST_BODY)
        return
    if content_length > MAX_POST_SIZE:
        _send_error(handler, 400, _copy.ERROR_REQUEST_BODY_TOO_LARGE)
        return

    content_type = handler.headers.get("Content-Type", "")
    if "application/json" not in content_type:
        _send_error(handler, 400, _copy.ERROR_CONTENT_TYPE_NOT_JSON)
        return

    try:
        raw = handler.rfile.read(content_length)
        body = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        _send_error(handler, 400, _copy.ERROR_INVALID_JSON.format(detail=exc))
        return

    transcript_path = body.get("transcript_path")
    metadata_path = body.get("metadata_path")

    if not transcript_path:
        _send_error(handler, 400, _copy.ERROR_MISSING_TRANSCRIPT_PATH)
        return
    if not metadata_path:
        _send_error(handler, 400, _copy.ERROR_MISSING_METADATA_PATH)
        return

    # --- Validate paths exist ---
    transcript_file = Path(transcript_path)
    metadata_file = Path(metadata_path)

    if not transcript_file.exists():
        _send_error(
            handler, 400,
            _copy.ERROR_TRANSCRIPT_NOT_FOUND.format(path=transcript_path),
        )
        return
    if not metadata_file.exists():
        _send_error(
            handler, 400,
            _copy.ERROR_METADATA_NOT_FOUND.format(path=metadata_path),
        )
        return

    # --- Validate metadata is valid JSON with required fields ---
    try:
        metadata = json.loads(metadata_file.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        _send_error(
            handler, 400,
            _copy.ERROR_INVALID_METADATA_JSON.format(detail=exc),
        )
        return

    if "conversation_id" not in metadata:
        _send_error(
            handler, 400, _copy.ERROR_METADATA_MISSING_CONVERSATION_ID,
        )
        return

    # --- Process ---
    # Optional parameters from request body
    dry_run = body.get("dry_run", False)
    no_sinks = body.get("no_sinks", False)

    try:
        result = _process_via_library(
            transcript_file, metadata_file, metadata,
            dry_run=dry_run, no_sinks=no_sinks,
        )
    except ImportError as exc:
        logger.error(
            "CM048 library not importable; install CM048 in this Python "
            "environment (pip install -e .) and re-deploy. Detail: %s",
            exc,
        )
        _send_error(handler, 503, _copy.ERROR_LIBRARY_UNAVAILABLE)
        return

    if result.get("error"):
        _send_json(handler, 500, result)
    else:
        _send_json(handler, 200, result)


def _process_via_library(
    transcript_file: Path,
    metadata_file: Path,
    metadata: dict,
    *,
    dry_run: bool = False,
    no_sinks: bool = False,
) -> dict:
    """Process using the CM048 Python library directly."""
    from src.processor import process
    from src.settings import load_settings, settings_from_env_override, ensure_directories

    settings = settings_from_env_override(load_settings())
    ensure_directories(settings)

    transcript = transcript_file.read_text()
    conv_id = metadata["conversation_id"]

    state = process(
        conv_id,
        transcript,
        metadata,
        settings,
        dry_run=dry_run,
        ingest_sinks=not no_sinks,
    )

    return {
        "conversation_id": conv_id,
        "status": "failed" if state.failed_step else "complete",
        "completed_steps": state.completed_steps,
        "failed_step": state.failed_step,
        "failure_reason": state.failure_reason,
    }


# --- HTTP helpers (compatible with ical-server.py's patterns) ---


def _send_json(
    handler: BaseHTTPRequestHandler,
    status: int,
    data: dict,
) -> None:
    """Send a JSON response."""
    body = json.dumps(data, indent=2).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _send_error(
    handler: BaseHTTPRequestHandler,
    status: int,
    message: str,
) -> None:
    """Send an error JSON response."""
    _send_json(handler, status, {"error": message})
