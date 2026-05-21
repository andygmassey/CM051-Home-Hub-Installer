"""Diagnostic-service transparent payload viewer.

Before the diagnostic service sends any data to the cloud, this module:
1. Captures the exact payload that will be sent
2. Presents it to the user for approval (via web UI or CLI)
3. Logs every payload to the audit log (whether approved or denied)
4. Provides a browsable history of all payloads ever sent

The user sees exactly what is being transmitted – every field,
in plain English. No hidden data. No trust required.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Optional

from .audit_log import AuditLog, EVENT_DIAGNOSTIC_PAYLOAD

logger = logging.getLogger(__name__)


# ── Payload sanitisation ─────────────────────────────────────────────

# These are the ONLY fields the diagnostic service is allowed to send.
# Anything not in this list is stripped before transmission.
ALLOWED_FIELDS = {
    "container_name",
    "container_state",
    "container_status",
    "container_image",
    "ollama_model_name",
    "ollama_model_size_gb",
    "disk_mount_point",
    "disk_total_gb",
    "disk_used_gb",
    "disk_free_gb",
    "disk_percent_used",
    "service_name",
    "service_status",
    "service_status_code",
    "os_version",
    "hostname",
    "ram_total_gb",
    "ram_available_gb",
    "ostler_version",
    "timestamp",
    "session_id",
    "question",  # The user's diagnostic question (they typed it, it's theirs)
}

# Fields that MUST NEVER be transmitted, even if somehow present
BLOCKED_FIELDS = {
    "contact_name",
    "display_name",
    "email",
    "phone",
    "linkedin_url",
    "conversation_content",
    "message_content",
    "calendar_event",
    "fact_text",
    "coaching_observation",
    "wiki_content",
    "passphrase",
    "encryption_key",
    "recovery_key",
    "api_key",
    "password",
    "token",
}


def sanitise_payload(payload: dict) -> dict:
    """Strip any fields not in the allowed list.

    This is a defence-in-depth measure – even if a bug adds
    personal data to the payload, this function removes it
    before transmission.

    Returns the sanitised payload (a new dict, original unchanged).
    """
    sanitised = {}
    blocked_found = []

    for key, value in payload.items():
        if key in BLOCKED_FIELDS:
            blocked_found.append(key)
            continue
        if key in ALLOWED_FIELDS:
            # RT-6 fix: enforce scalar values only – no nested dicts/lists
            # NF-2 fix: enforce max string length to limit exfiltration surface
            MAX_FIELD_LENGTH = 500  # generous for diagnostic text, blocks bulk data
            if isinstance(value, (str, int, float, bool, type(None))):
                if isinstance(value, str) and len(value) > MAX_FIELD_LENGTH:
                    logger.warning(
                        "Diagnostic payload: truncated oversized string in '%s' (%d chars)",
                        key, len(value),
                    )
                    value = value[:MAX_FIELD_LENGTH] + "...[truncated]"
                sanitised[key] = value
            else:
                logger.warning(
                    "Diagnostic payload: stripped non-scalar value in '%s' (type: %s)",
                    key, type(value).__name__,
                )
        else:
            # Unknown field – strip it and log
            logger.warning(
                "Diagnostic payload: stripped unknown field '%s'", key
            )

    if blocked_found:
        logger.error(
            "Diagnostic payload: BLOCKED personal data fields detected and stripped: %s",
            blocked_found,
        )

    return sanitised


# ── Payload approval flow ────────────────────────────────────────────


class PayloadViewer:
    """Manages the payload approval flow for diagnostic-service transmissions."""

    def __init__(self, audit_log: AuditLog):
        self.audit_log = audit_log
        self._pending: Optional[dict] = None

    def prepare(self, raw_payload: dict) -> dict:
        """Prepare a payload for user review.

        Sanitises the payload and stores it as pending.
        Returns the sanitised version for display to the user.
        """
        self._pending = sanitise_payload(raw_payload)
        return self._pending

    def approve(self) -> dict:
        """User approved the pending payload. Log and return it for sending.

        Raises ValueError if no payload is pending.
        """
        if self._pending is None:
            raise ValueError("No payload pending approval")

        payload = self._pending
        self._pending = None

        # Log to audit trail
        self.audit_log.log(
            event_type=EVENT_DIAGNOSTIC_PAYLOAD,
            source="diagnostic_web_ui",
            details={
                "action": "approved",
                "payload": payload,
                "field_count": len(payload),
            },
        )

        return payload

    def deny(self) -> None:
        """User denied the pending payload. Log and discard."""
        payload = self._pending
        self._pending = None

        self.audit_log.log(
            event_type=EVENT_DIAGNOSTIC_PAYLOAD,
            source="diagnostic_web_ui",
            details={
                "action": "denied",
                "payload": payload,
                "field_count": len(payload) if payload else 0,
            },
            success=False,
        )

    def history(self, limit: int = 20) -> list[dict]:
        """Retrieve history of all diagnostic-service payloads (sent and denied).

        Returns a list of audit log entries, most recent first.
        """
        return self.audit_log.diagnostic_payloads(limit=limit)


def format_payload_for_display(payload: dict) -> str:
    """Format a payload as a human-readable string for the web UI.

    Each field is shown on its own line with a plain English label.
    """
    labels = {
        "service_name": "Local service",
        "container_state": "Container state",
        "container_status": "Container status",
        "container_image": "Container image",
        "ollama_model_name": "AI model name",
        "ollama_model_size_gb": "AI model size (GB)",
        "disk_mount_point": "Disk path",
        "disk_total_gb": "Disk total (GB)",
        "disk_used_gb": "Disk used (GB)",
        "disk_free_gb": "Disk free (GB)",
        "disk_percent_used": "Disk usage (%)",
        "service_status": "Service status",
        "service_status_code": "HTTP status code",
        "os_version": "Operating system",
        "hostname": "Machine name",
        "ram_total_gb": "RAM total (GB)",
        "ram_available_gb": "RAM available (GB)",
        "ostler_version": "Ostler version",
        "timestamp": "Timestamp",
        "session_id": "Session ID",
        "question": "Your question",
    }

    lines = []
    for key, value in payload.items():
        label = labels.get(key, key)
        lines.append(f"{label}: {value}")

    return "\n".join(lines)
