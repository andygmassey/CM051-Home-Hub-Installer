from __future__ import annotations

from typing import List, Optional

import os

import httpx


def _service_token():
    """Loopback service token the ical-server requires on every non-public route."""
    tok = (os.environ.get("PWG_SERVICE_TOKEN") or os.environ.get("OSTLER_SERVICE_TOKEN") or "").strip()
    if tok:
        return tok
    path = os.path.join(os.path.expanduser("~"), ".ostler", "secrets", "service_token")
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def fetch_events(api_url, days=30):
    """Fetch calendar events from the unified calendar API.

    Returns list of event dicts. Only events with both a UID and at least
    one attendee are included.
    """
    url = api_url.rstrip("/") + "/calendar"
    headers = {}
    token = _service_token()
    if token:
        headers["Authorization"] = "Bearer " + token
    resp = httpx.get(
        url, params={"days": str(days)}, headers=headers, timeout=30.0, trust_env=False
    )
    if resp.status_code in (401, 403):
        raise RuntimeError(
            "CANNOT-RUN: the calendar API at %s refused the request (%d); "
            "no service token was %s" % (url, resp.status_code, "accepted" if token else "found")
        )
    resp.raise_for_status()
    data = resp.json()
    events = data.get("events", [])
    # Filter to events with attendees and a UID
    return [e for e in events if e.get("attendees") and e.get("uid")]
