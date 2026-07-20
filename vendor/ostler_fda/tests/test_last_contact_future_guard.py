"""Calendar future-date guard for last-contact writes.

ingest_calendar iterates every event in the FDA calendar export with no
date filter, and _update_last_contact had no future guard, so an upcoming
meeting (calendars routinely carry future events) was written to
pwg:lastContactCalendar and surfaced by the assistant as "last contact"
with a future date. _update_last_contact now rejects any timestamp after
today for every source, comparing derived YYYY-MM-DD strings (sidesteps
tz-aware/naive subtraction errors). Future meetings remain visible via
the Meeting nodes ingest_calendar also emits -- this guard only stops
them poisoning the last-contact signal.

Ported from HR015 ostler_fda commit 7f7710f (graft, held pin a15d82f).
"""
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from ostler_fda.pwg_ingest import _update_last_contact


@patch("ostler_fda.pwg_ingest._sparql_update")
def test_future_dated_event_is_rejected(mock_update):
    """A future-dated event (an upcoming meeting in a calendar export)
    is never a last contact. The writer must short-circuit before any
    SPARQL update, otherwise the future date wins the read-side max()
    and the assistant reports it as 'last contact'."""
    future = (
        datetime.now(timezone.utc) + timedelta(days=7)
    ).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    _update_last_contact(
        "https://pwg.dev/ontology#person_abc",
        future,
        "calendar",
    )
    assert not mock_update.called


@patch("ostler_fda.pwg_ingest._sparql_update")
def test_today_is_accepted(mock_update):
    """Today is a valid last-contact date (the boundary is inclusive of
    today, exclusive of tomorrow)."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%dT09:00:00+00:00")
    _update_last_contact(
        "https://pwg.dev/ontology#person_abc",
        today,
        "calendar",
    )
    assert mock_update.called


@patch("ostler_fda.pwg_ingest._sparql_update")
def test_past_dated_event_is_still_accepted(mock_update):
    """Regression guard: the future-date check must not reject past
    (the normal case) or non-calendar sources."""
    past = "2026-04-25T10:00:00+00:00"
    _update_last_contact(
        "https://pwg.dev/ontology#person_abc",
        past,
        "calendar",
    )
    assert mock_update.called
