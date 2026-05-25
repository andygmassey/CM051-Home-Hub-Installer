from __future__ import annotations

from typing import List, Optional

import httpx


def fetch_events(api_url, days=30):
    """Fetch calendar events from the unified calendar API.

    Returns list of event dicts. Only events with both a UID and at least
    one attendee are included.
    """
    url = api_url.rstrip("/") + "/calendar"
    resp = httpx.get(url, params={"days": str(days)}, timeout=30.0)
    resp.raise_for_status()
    data = resp.json()
    events = data.get("events", [])
    # Filter to events with attendees and a UID
    return [e for e in events if e.get("attendees") and e.get("uid")]
