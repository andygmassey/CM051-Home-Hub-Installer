"""Unit tests for contact_syncer parsing functions.

Tests pure parsing only — no Oxigraph, Qdrant, or network calls needed.
Uses tempfile for fixture data.
"""
from __future__ import annotations

import csv
import json
import os
import tempfile
from typing import Any, Dict, List

import pytest

from contact_syncer.twitter_contacts import parse_twitter_contacts
from contact_syncer.google_calendar import (
    parse_ics,
    _extract_datetime,
    _extract_param,
    _extract_mailto,
)
from contact_syncer.facebook_friends import (
    parse_friends_json,
    _fix_mojibake as fb_fix_mojibake,
    _split_name,
)
from contact_syncer.facebook_events import parse_events
from contact_syncer.instagram_social import (
    parse_close_friends,
    parse_followers,
    parse_following,
)
from contact_syncer.whatsapp_contacts import parse_whatsapp_contacts
from contact_syncer.linkedin_messages import parse_messages_csv, group_conversations


# ── Helpers ─────────────────────────────────────────────────────────


def _write_tmp(content: str, suffix: str = ".json") -> str:
    """Write content to a temp file and return its path."""
    f = tempfile.NamedTemporaryFile(mode="w", suffix=suffix, delete=False, encoding="utf-8")
    f.write(content)
    f.close()
    return f.name


# ── Twitter contacts ────────────────────────────────────────────────


class TestTwitterContacts:
    def test_parse_with_ytd_prefix(self):
        content = (
            # Test numbers drawn from reserved-for-fiction ranges:
            # +44 7700 900xxx is Ofcom's drama-range UK mobile (never
            # connects). +852 5555 xxxx is an obviously-fake HK pattern.
            # +1 212 555 xxxx is NANPA's fiction prefix (555 in US/Canada).
            'window.YTD.contact.part0 = '
            + json.dumps([
                {"contact": {"phoneNumbers": ["+85255550123", "+447700900123"], "emails": ["a@example.com"]}},
                {"contact": {"phoneNumbers": ["+12125551234"]}},
            ])
        )
        path = _write_tmp(content, suffix=".js")
        try:
            phones = parse_twitter_contacts(path)
            assert len(phones) == 3
            assert "+12125551234" in phones
            assert "+447700900123" in phones
            assert "+85255550123" in phones
        finally:
            os.unlink(path)

    def test_parse_empty_file(self):
        path = _write_tmp("window.YTD.contact.part0 = []", suffix=".js")
        try:
            assert parse_twitter_contacts(path) == []
        finally:
            os.unlink(path)

    def test_parse_no_json_bracket(self):
        path = _write_tmp("not valid at all", suffix=".js")
        try:
            assert parse_twitter_contacts(path) == []
        finally:
            os.unlink(path)

    def test_parse_deduplicates_phones(self):
        content = (
            'window.YTD.contact.part0 = '
            + json.dumps([
                {"contact": {"phoneNumbers": ["+1234"]}},
                {"contact": {"phoneNumbers": ["+1234", "+5678"]}},
            ])
        )
        path = _write_tmp(content, suffix=".js")
        try:
            phones = parse_twitter_contacts(path)
            assert phones == ["+1234", "+5678"]
        finally:
            os.unlink(path)


class TestTwitterPhoneNormalization:
    """Test the phone normalization logic used in find_person_by_phone.

    We test the digit-stripping and last-8-digit logic without calling
    Oxigraph, by replicating the normalization inline.
    """

    @staticmethod
    def _normalize(phone: str) -> str | None:
        digits_only = "".join(c for c in phone if c.isdigit())
        if len(digits_only) < 8:
            return None
        return digits_only[-8:]

    def test_parenthetical_country_code(self):
        assert self._normalize("(001)2125551234") == "25551234"

    def test_e164_format(self):
        assert self._normalize("+85255550123") == "55550123"

    def test_uk_local(self):
        assert self._normalize("07700900123") == "00900123"

    def test_short_number_returns_none(self):
        assert self._normalize("1234") is None


# ── Google Calendar ICS ─────────────────────────────────────────────


class TestGoogleCalendar:
    def test_parse_minimal_vevent(self):
        ics = (
            "BEGIN:VCALENDAR\n"
            "BEGIN:VEVENT\n"
            "SUMMARY:Team standup\n"
            "DTSTART:20251109T103000Z\n"
            "DTEND:20251109T110000Z\n"
            "UID:abc123@example.com\n"
            "END:VEVENT\n"
            "END:VCALENDAR\n"
        )
        path = _write_tmp(ics, suffix=".ics")
        try:
            events = parse_ics(path)
            assert len(events) == 1
            e = events[0]
            assert e["summary"] == "Team standup"
            assert e["dtstart"] == "2025-11-09T10:30:00+00:00"
            assert e["uid"] == "abc123@example.com"
        finally:
            os.unlink(path)

    def test_parse_date_only_event(self):
        ics = (
            "BEGIN:VCALENDAR\n"
            "BEGIN:VEVENT\n"
            "SUMMARY:All day event\n"
            "DTSTART;VALUE=DATE:20251225\n"
            "DTEND;VALUE=DATE:20251226\n"
            "UID:xmas@example.com\n"
            "END:VEVENT\n"
            "END:VCALENDAR\n"
        )
        path = _write_tmp(ics, suffix=".ics")
        try:
            events = parse_ics(path)
            assert len(events) == 1
            assert events[0]["dtstart"] == "2025-12-25T00:00:00+00:00"
        finally:
            os.unlink(path)

    def test_parse_attendees(self):
        ics = (
            "BEGIN:VCALENDAR\n"
            "BEGIN:VEVENT\n"
            "SUMMARY:Meeting\n"
            "DTSTART:20251001T090000Z\n"
            "ATTENDEE;CN=Jane Doe:mailto:jane@example.com\n"
            "ATTENDEE;CN=Test User:mailto:testuser@example.com\n"
            "END:VEVENT\n"
            "END:VCALENDAR\n"
        )
        path = _write_tmp(ics, suffix=".ics")
        try:
            # Without user_name, both attendees are included
            events = parse_ics(path)
            assert len(events[0]["attendees"]) == 2

            # With user_name, the user is filtered out
            events = parse_ics(path, user_name="Test User")
            assert len(events) == 1
            assert len(events[0]["attendees"]) == 1
            assert events[0]["attendees"][0]["name"] == "Jane Doe"
            assert events[0]["attendees"][0]["email"] == "jane@example.com"
        finally:
            os.unlink(path)

    def test_extract_datetime_local(self):
        assert _extract_datetime("DTSTART;TZID=Europe/London:20251109T103000") == "2025-11-09T10:30:00+00:00"

    def test_extract_mailto(self):
        assert _extract_mailto("ATTENDEE;CN=Bob:mailto:bob@example.com") == "bob@example.com"

    def test_extract_param(self):
        assert _extract_param("ATTENDEE;CN=Bob Smith;RSVP=TRUE:mailto:bob@example.com", "CN") == "Bob Smith"


# ── Facebook Friends ────────────────────────────────────────────────


class TestFacebookFriends:
    def test_parse_friends_v2_wrapper(self):
        data = {"friends_v2": [
            {"name": "Alice Smith", "timestamp": 1609459200},
            {"name": "Bob Jones", "timestamp": 1609545600},
        ]}
        path = _write_tmp(json.dumps(data))
        try:
            friends = parse_friends_json(path)
            assert len(friends) == 2
            assert friends[0]["name"] == "Alice Smith"
        finally:
            os.unlink(path)

    def test_parse_raw_list(self):
        data = [{"name": "Charlie Brown", "timestamp": 0}]
        path = _write_tmp(json.dumps(data))
        try:
            friends = parse_friends_json(path)
            assert len(friends) == 1
        finally:
            os.unlink(path)

    def test_fix_mojibake(self):
        # "Jose\u0301" encoded via Latin-1 double-encoding
        mangled = "Jos\u00c3\u00a9"
        assert fb_fix_mojibake(mangled) == "Jos\u00e9"

    def test_split_name_single(self):
        assert _split_name("Madonna") == ("Madonna", None)

    def test_split_name_multi(self):
        assert _split_name("John Paul Jones") == ("John", "Paul Jones")


# ── Facebook Events ─────────────────────────────────────────────────


class TestFacebookEvents:
    def test_parse_invitations_and_own(self, tmp_path):
        inv = {"events_invited_v2": [
            {"name": "Birthday Party", "start_timestamp": 1609459200, "end_timestamp": 1609466400},
        ]}
        own = {"your_events_v2": [
            {"name": "My Gig", "start_timestamp": 1609545600, "end_timestamp": 0,
             "place": {"name": "The Venue"}, "description": "A fun gig"},
        ]}
        (tmp_path / "event_invitations.json").write_text(json.dumps(inv))
        (tmp_path / "your_events.json").write_text(json.dumps(own))

        events = parse_events(str(tmp_path))
        assert len(events) == 2
        names = {e["name"] for e in events}
        assert "Birthday Party" in names
        assert "My Gig" in names
        # Check source tags
        sources = {e["name"]: e["source"] for e in events}
        assert sources["Birthday Party"] == "facebook_invitation"
        assert sources["My Gig"] == "facebook_event"

    def test_parse_empty_dir(self, tmp_path):
        events = parse_events(str(tmp_path))
        assert events == []


# ── Instagram Social ────────────────────────────────────────────────


class TestInstagramSocial:
    def test_parse_close_friends(self):
        data = {"relationships_close_friends": [
            {"string_list_data": [{"value": "bestmate", "timestamp": 1700000000, "href": "https://www.instagram.com/bestmate"}]},
        ]}
        path = _write_tmp(json.dumps(data))
        try:
            results = parse_close_friends(path)
            assert len(results) == 1
            assert results[0]["username"] == "bestmate"
            assert results[0]["timestamp"] == 1700000000
        finally:
            os.unlink(path)

    def test_parse_followers_bare_list(self):
        data = [
            {"string_list_data": [{"value": "fan1", "timestamp": 1600000000, "href": ""}]},
            {"string_list_data": [{"value": "fan2", "timestamp": 1600000001, "href": ""}]},
        ]
        path = _write_tmp(json.dumps(data))
        try:
            results = parse_followers(path)
            assert len(results) == 2
            assert results[0]["username"] == "fan1"
            # Should construct URL when href is empty
            assert "instagram.com/fan1" in results[0]["profile_url"]
        finally:
            os.unlink(path)

    def test_parse_following(self):
        data = {"relationships_following": [
            {"string_list_data": [{"value": "celeb", "timestamp": 1650000000, "href": "https://www.instagram.com/celeb"}]},
        ]}
        path = _write_tmp(json.dumps(data))
        try:
            results = parse_following(path)
            assert len(results) == 1
            assert results[0]["username"] == "celeb"
        finally:
            os.unlink(path)


# ── WhatsApp Contacts ──────────────────────────────────────────────


class TestWhatsAppContacts:
    def test_parse_contacts(self):
        data = {"wa_contacts": ["+85255550123", "+447700900123", "", "+85255550123"]}
        path = _write_tmp(json.dumps(data))
        try:
            phones = parse_whatsapp_contacts(path)
            # Should deduplicate and exclude empty strings
            assert len(phones) == 2
            assert "+447700900123" in phones
            assert "+85255550123" in phones
        finally:
            os.unlink(path)

    def test_parse_empty_contacts(self):
        data = {"wa_contacts": []}
        path = _write_tmp(json.dumps(data))
        try:
            assert parse_whatsapp_contacts(path) == []
        finally:
            os.unlink(path)


# ── LinkedIn Messages ──────────────────────────────────────────────


class TestLinkedInMessages:
    def _write_csv(self, rows: List[Dict[str, str]]) -> str:
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False,
                                        encoding="utf-8", newline="")
        fieldnames = ["CONVERSATION ID", "FROM", "SENDER PROFILE URL",
                      "DATE", "SUBJECT", "CONTENT"]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
        f.close()
        return f.name

    def test_parse_messages_csv(self):
        rows = [
            {"CONVERSATION ID": "c1", "FROM": "Alice", "SENDER PROFILE URL": "https://linkedin.com/in/alice",
             "DATE": "2025-03-01 10:00:00 UTC", "SUBJECT": "Hello", "CONTENT": "Hi there"},
            {"CONVERSATION ID": "c1", "FROM": "Test User", "SENDER PROFILE URL": "",
             "DATE": "2025-03-01 10:05:00 UTC", "SUBJECT": "Hello", "CONTENT": "Hey Alice"},
        ]
        path = self._write_csv(rows)
        try:
            parsed = parse_messages_csv(path)
            assert len(parsed) == 2
            assert parsed[0]["FROM"] == "Alice"
        finally:
            os.unlink(path)

    def test_group_conversations(self):
        rows = [
            {"CONVERSATION ID": "c1", "FROM": "Alice", "SENDER PROFILE URL": "",
             "DATE": "2025-03-01 10:00:00 UTC", "SUBJECT": "Hi", "CONTENT": "Hello"},
            {"CONVERSATION ID": "c1", "FROM": "Test User", "SENDER PROFILE URL": "",
             "DATE": "2025-03-01 10:05:00 UTC", "SUBJECT": "Hi", "CONTENT": "Hey"},
            {"CONVERSATION ID": "c1", "FROM": "Alice", "SENDER PROFILE URL": "",
             "DATE": "2025-03-02 09:00:00 UTC", "SUBJECT": "Hi", "CONTENT": "Follow up"},
        ]
        convos = group_conversations(rows, user_name="Test User")
        assert "c1" in convos
        c = convos["c1"]
        assert c["total_messages"] == 3
        assert c["user_message_count"] == 1
        assert c["other_message_count"] == 2
        assert len(c["participants"]) == 2

    def test_group_skips_empty_conversation_id(self):
        rows = [
            {"CONVERSATION ID": "", "FROM": "Alice", "SENDER PROFILE URL": "",
             "DATE": "", "SUBJECT": "", "CONTENT": "orphan"},
        ]
        convos = group_conversations(rows)
        assert len(convos) == 0

    def test_parse_csv_skips_empty_content(self):
        rows_data = [
            {"CONVERSATION ID": "c1", "FROM": "Alice", "SENDER PROFILE URL": "",
             "DATE": "2025-01-01 00:00:00 UTC", "SUBJECT": "", "CONTENT": ""},
        ]
        path = self._write_csv(rows_data)
        try:
            parsed = parse_messages_csv(path)
            assert len(parsed) == 0
        finally:
            os.unlink(path)
