"""Response builder for GET /api/v1/preferences/derived (Chunk 5, producer side).

This is the single source of truth for the endpoint's JSON CONTRACT. The
ical-server route and any Rust client bind to the shape produced here and tested
against contract/derived_preferences_response.example.json.

Silent-empty rule (checklist): a missing/empty/failed dependency MUST NOT return
`{"items": []}` as if it were a healthy empty result. Unavailable -> degraded
with cannot_check; empty -> degraded with a reason. Only a real, non-empty read
returns degraded=false.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

CONTRACT_VERSION = "derived-preferences.v1"


def _now_iso(now: Optional[datetime]) -> str:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _item(view) -> dict:
    return {
        "dimension": view.dimension,
        "label": view.subject,
        "strength": round(float(view.strength), 4),
        "confidence": round(float(view.confidence), 4),
        "intensity": view.intensity,
        "because": list(view.because),
    }


def build_derived_preferences_response(
    reader,
    user_id: str,
    limit: int = 8,
    min_confidence: float = 0.4,
    now: Optional[datetime] = None,
) -> dict:
    """Build the endpoint payload. Never raises; degrades loudly instead."""
    ts = _now_iso(now)
    try:
        views = reader.get_derived_preferences(
            user_id, min_confidence=min_confidence, limit=limit
        )
    except Exception as exc:  # dependency down: degrade, do not 200 []
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": f"derived graph unavailable: {type(exc).__name__}",
        }

    if not views:  # empty graph is NOT a healthy empty result
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": "no derived preferences materialized yet",
        }

    return {
        "generated_at": ts,
        "items": [_item(v) for v in views],
        "degraded": False,
    }
