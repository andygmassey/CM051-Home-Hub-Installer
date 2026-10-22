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
    d = {
        "dimension": view.dimension,
        "label": view.subject,
        "strength": round(float(view.strength), 4),
        "confidence": round(float(view.confidence), 4),
        "intensity": view.intensity,
        "because": list(view.because),
    }
    # Only when the evidence carried a level: consumers apply their L2 handling.
    if getattr(view, "privacy", ""):
        d["privacy_level"] = view.privacy
    return d


def build_derived_preferences_response(
    reader,
    user_id: str,
    limit: int = 8,
    min_confidence: float = 0.4,
    now: Optional[datetime] = None,
    tier: Optional[str] = None,
) -> dict:
    """Build the endpoint payload. Never raises; degrades loudly instead.

    ``tier``: ``broad`` (types of things: genres, cuisines, topics), ``specific``
    (single things) or ``all`` (every tier, broad first). The round-robin by
    category applies within the tier. A reader without ``get_mixed_preferences``
    ignores the tier and serves the plain ranked read.

    ``None`` means the caller did not ask: it reads ``broad``, and if that is
    EMPTY it serves ``all`` and says so (``"tier": "all", "tier_fallback": true``).
    An upgraded box holds a graph written before tiers until the next derive run;
    without the fallback the first look after an update would be empty. An
    EXPLICIT ``broad`` stays strict.
    """
    defaulted = tier is None
    tier = tier or "broad"
    ts = _now_iso(now)
    try:
        # Prefer the category-interleaved read: ranked by confidence alone, one
        # wide category (every TV series, every site) owns the whole list.
        mixed = getattr(reader, "get_mixed_preferences", None)
        if mixed is not None:
            views = mixed(user_id, min_confidence=min_confidence, limit=limit, tier=tier)
        else:
            views = reader.get_derived_preferences(
                user_id, min_confidence=min_confidence, limit=limit
            )
        fell_back = False
        if not views and defaulted and mixed is not None and tier == "broad":
            views = mixed(user_id, min_confidence=min_confidence, limit=limit, tier="all")
            fell_back = bool(views)
    except Exception as exc:  # dependency down: degrade, do not 200 []
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": f"derived graph unavailable: {type(exc).__name__}",
        }

    if not views:  # empty graph is NOT a healthy empty result
        reason = (
            "no derived preferences materialized yet"
            if tier == "all"
            else f"no derived preferences materialized yet in the {tier} tier (tier=all shows every tier)"
        )
        return {
            "generated_at": ts,
            "items": [],
            "degraded": True,
            "cannot_check": reason,
        }

    out = {
        "generated_at": ts,
        "items": [_item(v) for v in views],
        "degraded": False,
    }
    if fell_back:
        out["tier"] = "all"
        out["tier_fallback"] = True
    return out
