"""One-time backfill of ``pwg:meetingAllDay`` onto Meeting nodes written before I22.

I22 made ``ingest_calendar`` record the calendar's own all-day flag. Meeting
nodes written before that carry no flag, so the Timeline reads an old all-day
event as timed. The hourly tick already re-ingests whatever the extract window
covers (the Meeting URI is a stable uuid5, so the flag lands on the same node);
this reaches the rows OUTSIDE that window, once, with a wide re-read.

Rules, all tested:
  - ADDS the flag only where a Meeting has none. Never deletes, never rewrites
    a flag already there, never creates a Meeting or a Person.
  - Idempotent: a second run finds nothing unflagged that it can match.
  - Fail-soft: any failure returns a status and writes no marker, so the next
    tick retries. It never raises into the tick.
  - Logs counts only: no title, attendee or date is ever put in the result.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

PWG = "https://schema.ostler.ai/ontology#"
MARKER_NAME = "allday_backfill_v1.done"
_CHUNK = 200


def meeting_uri(title: str, start_date: str) -> str:
    """The URI ``ingest_calendar`` gives a Meeting. Keep in step with it."""
    meeting_id = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"https://schema.ostler.ai/meeting/{title}|{start_date}",
    )
    return f"{PWG}meeting_{meeting_id}"


def _start_text(value) -> str:
    # The extract is stored with json.dumps(..., default=str), so a datetime
    # reaches ingest_calendar as str(datetime). Do the same here.
    return value if isinstance(value, str) else str(value) if isinstance(value, datetime) else ""


def backfill_all_day(events: list, query: Callable[[str], list],
                     update: Callable[[str], None]) -> dict:
    """Set the flag on unflagged Meeting nodes that match an extracted event."""
    rows = query(
        "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"
        "SELECT ?m WHERE { ?m a pwg:Meeting ; pwg:source \"calendar_fda\" . "
        "FILTER NOT EXISTS { ?m pwg:meetingAllDay ?f } }"
    )
    unflagged = {r["m"]["value"] for r in rows}
    want: dict[str, bool] = {}
    for ev in events:
        flag = ev.get("is_all_day")
        start = _start_text(ev.get("start_date"))
        if not isinstance(flag, bool) or not start:
            continue
        uri = meeting_uri(ev.get("title", ""), start)
        if uri in unflagged and uri not in want:
            want[uri] = flag
    triples = [
        f'<{u}> pwg:meetingAllDay "{"true" if f else "false"}"^^xsd:boolean'
        for u, f in want.items()
    ]
    for i in range(0, len(triples), _CHUNK):
        update(
            "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            "INSERT DATA {\n  " + " .\n  ".join(triples[i:i + _CHUNK]) + " .\n}"
        )
    return {
        "unflagged_before": len(unflagged),
        "set_all_day": sum(1 for f in want.values() if f),
        "set_timed": sum(1 for f in want.values() if not f),
        "unmatched": len(unflagged) - len(want),
    }


def run_once(state_dir: Path, *, since_days: int = 1825, future_days: int = 30,
             extract: Optional[Callable[..., list]] = None,
             query: Optional[Callable[[str], list]] = None,
             update: Optional[Callable[[str], None]] = None) -> dict:
    """Run the backfill unless its marker exists. Never raises."""
    marker = Path(state_dir) / MARKER_NAME
    try:
        if marker.exists():
            return {"status": "already_done"}
        if extract is None:
            from .calendar import extract_events as extract
        if query is None or update is None:
            from . import pwg_ingest
            query, update = pwg_ingest._sparql_query, pwg_ingest._sparql_update
        try:
            events = [e if isinstance(e, dict) else e.__dict__
                      for e in extract(since_days=since_days, future_days=future_days)]
        except PermissionError:
            return {"status": "cannot_run", "reason": "no_fda"}
        except FileNotFoundError:
            return {"status": "cannot_run", "reason": "calendar_not_found"}
        counts = backfill_all_day(events, query, update)
        counts["events"] = len(events)
        # An empty read with unflagged rows is a calendar that could not be
        # read, not a calendar with nothing to say: retry next tick.
        if not events and counts["unflagged_before"]:
            return {"status": "cannot_run", "reason": "empty_extract", **counts}
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps(counts, sort_keys=True) + "\n", encoding="utf-8")
        return {"status": "ok", **counts}
    except Exception as exc:  # fail-soft: the tick must not notice
        return {"status": "error", "error": type(exc).__name__}
