"""Tests for FDA -> PWG pipeline connector.

These tests mock the Oxigraph/Qdrant/Ollama HTTP calls and verify
that the ingestion logic correctly reads FDA JSON output and
generates the right SPARQL/Qdrant operations.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from ostler_fda.pwg_ingest import (
    _escape,
    _person_id_from_identifier,
    _person_uri,
    _update_last_contact,
    ingest_all,
    ingest_calendar,
    ingest_imessage,
    ingest_mail_contacts,
    ingest_photos_people,
)


class TestUtilities:
    """Test helper functions."""

    def test_escape_quotes(self):
        assert _escape('He said "hello"') == 'He said \\"hello\\"'

    def test_escape_backslash(self):
        assert _escape("path\\to\\file") == "path\\\\to\\\\file"

    def test_escape_newline(self):
        assert _escape("line1\nline2") == "line1\\nline2"

    def test_escape_carriage_return(self):
        """CR is spec-forbidden in STRING_LITERAL2 but the old escape
        missed it. An attacker-controlled CR could terminate the literal
        early and inject further SPARQL. Regression for Lester's audit
        blocker."""
        assert _escape("line1\rline2") == "line1\\rline2"

    def test_escape_crlf(self):
        assert _escape("a\r\nb") == "a\\r\\nb"

    def test_escape_tab(self):
        assert _escape("col1\tcol2") == "col1\\tcol2"

    def test_escape_backspace(self):
        assert _escape("oops\b") == "oops\\b"

    def test_escape_formfeed(self):
        assert _escape("page1\fpage2") == "page1\\fpage2"

    def test_escape_null_byte(self):
        """NUL has no ECHAR form — must go through UCHAR escape."""
        assert _escape("evil\x00payload") == "evil\\u0000payload"

    def test_escape_bell_control(self):
        """BEL (0x07) — another C0 control with no ECHAR form."""
        assert _escape("\x07") == "\\u0007"

    def test_escape_unit_separator(self):
        """0x1F (US) — the last C0 control."""
        assert _escape("\x1f") == "\\u001F"

    def test_escape_del(self):
        """DEL (0x7F) — post-printable control, also escaped."""
        assert _escape("x\x7fy") == "x\\u007Fy"

    def test_escape_dollar_sign_unchanged(self):
        """$ is valid inside a SPARQL string literal; escaping it with
        backslash would produce invalid ECHAR and break parsing. Lock
        in that we do NOT escape it."""
        assert _escape("Bob$") == "Bob$"

    def test_escape_at_sign_unchanged(self):
        """@ is valid inside a SPARQL string literal (same rationale
        as $)."""
        assert _escape("hello@world") == "hello@world"

    def test_escape_braces_unchanged(self):
        """{ and } are SPARQL syntax outside literals but plain chars
        inside them. Escaping with backslash would produce invalid
        ECHAR."""
        assert _escape("{x}") == "{x}"

    def test_escape_hostile_combined(self):
        """Adversarial name combining every escape path — ensures the
        escape function composes correctly."""
        hostile = 'Bob"; DROP{\n\r\t\x00}$@'
        escaped = _escape(hostile)
        # No raw forbidden chars remain in the output
        assert '"' not in escaped.replace('\\"', '')
        assert "\n" not in escaped
        assert "\r" not in escaped
        assert "\t" not in escaped
        assert "\x00" not in escaped
        # The escaped form is what a SPARQL parser can safely consume
        assert escaped == 'Bob\\"; DROP{\\n\\r\\t\\u0000}$@'

    def test_escape_well_formed_sparql_literal(self):
        """Wrap the escaped output in quotes and verify no unescaped
        literal-terminator survives. Lester's audit check: a hostile
        string must not produce SPARQL that a parser would read as
        'literal ends here, now execute this'."""
        hostile_names = [
            'Bob" . <urn:evil> <urn:p> "pwned',
            "Alice\r\n} INSERT DATA { <urn:evil> a <urn:Bad> . }",
            "\x00\x01\x02\x1fEvil\x7f",
            'Normal "name" with \\ slash',
        ]
        for name in hostile_names:
            escaped = _escape(name)
            literal = f'"{escaped}"'
            # Inside the quoted literal every " must be either (a) one
            # of the two outer terminators, or (b) part of a \" escape
            # sequence. If that equality fails there's a bare " in the
            # middle of the string that would terminate the literal
            # early and let the attacker inject SPARQL.
            total_quotes = literal.count('"')
            escape_sequences = literal.count('\\"')
            assert total_quotes == 2 + escape_sequences, (
                f"Hostile name produced unterminated literal: {literal!r}"
            )
            # No raw LF/CR (spec-forbidden)
            assert "\n" not in literal
            assert "\r" not in literal

    def test_person_id_deterministic(self):
        """Same identifier should always produce the same person ID."""
        id1 = _person_id_from_identifier("+447777123456")
        id2 = _person_id_from_identifier("+447777123456")
        assert id1 == id2

    def test_person_id_case_insensitive(self):
        id1 = _person_id_from_identifier("Alice@example.com")
        id2 = _person_id_from_identifier("alice@example.com")
        assert id1 == id2

    def test_person_id_different_for_different_identifiers(self):
        id1 = _person_id_from_identifier("+447777111111")
        id2 = _person_id_from_identifier("+447777222222")
        assert id1 != id2

    def test_person_uri_format(self):
        pid = _person_id_from_identifier("test@example.com")
        uri = _person_uri(pid)
        assert uri.startswith("https://pwg.dev/ontology#person_")
        assert pid in uri


class TestIngestImessage:
    """Test iMessage ingestion."""

    def test_skips_when_no_data(self, tmp_path):
        result = ingest_imessage(tmp_path)
        assert result["status"] == "skipped"

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._sparql_query", return_value=[])
    def test_creates_person_from_conversation(
        self, mock_query, mock_exists, mock_update, tmp_path
    ):
        conversations = [
            {
                "chat_id": "chat1",
                "display_name": None,
                "participants": ["+447777123456"],
                "message_count": 10,
                "first_message": "2025-01-01T00:00:00+00:00",
                "last_message": "2025-06-15T00:00:00+00:00",
                "is_group": False,
            }
        ]
        (tmp_path / "imessage_conversations.json").write_text(
            json.dumps(conversations)
        )

        result = ingest_imessage(tmp_path)
        assert result["status"] == "ok"
        assert result["people_created"] == 1
        assert mock_update.called

        # Check that the SPARQL contains the phone number
        sparql_calls = [str(c) for c in mock_update.call_args_list]
        sparql_text = " ".join(sparql_calls)
        assert "+447777123456" in sparql_text

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._sparql_query", return_value=[])
    def test_detects_phone_vs_email(
        self, mock_query, mock_exists, mock_update, tmp_path
    ):
        conversations = [
            {
                "chat_id": "c1",
                "participants": ["+447777123456"],
                "message_count": 5,
                "last_message": None,
                "is_group": False,
            },
            {
                "chat_id": "c2",
                "participants": ["alice@example.com"],
                "message_count": 5,
                "last_message": None,
                "is_group": False,
            },
        ]
        (tmp_path / "imessage_conversations.json").write_text(
            json.dumps(conversations)
        )

        ingest_imessage(tmp_path)

        sparql_calls = " ".join(str(c) for c in mock_update.call_args_list)
        assert '"phone"' in sparql_calls
        assert '"email"' in sparql_calls

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._sparql_query", return_value=[])
    def test_skips_empty_participants(
        self, mock_query, mock_exists, mock_update, tmp_path
    ):
        conversations = [
            {
                "chat_id": "c1",
                "participants": ["", None],
                "message_count": 5,
                "last_message": None,
                "is_group": False,
            },
        ]
        (tmp_path / "imessage_conversations.json").write_text(
            json.dumps(conversations)
        )

        result = ingest_imessage(tmp_path)
        assert result["people_created"] == 0


class TestIngestCalendar:
    """Test calendar attendee ingestion."""

    def test_skips_when_no_data(self, tmp_path):
        result = ingest_calendar(tmp_path)
        assert result["status"] == "skipped"

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_creates_attendees(
        self, mock_exists, mock_update, mock_last_contact, tmp_path
    ):
        events = [
            {
                "title": "Sprint Review",
                "start_date": "2025-06-15T10:00:00+00:00",
                "attendees": ["Alice Chen", "Bob Smith"],
            },
            {
                "title": "1:1 with Alice",
                "start_date": "2025-06-16T14:00:00+00:00",
                "attendees": ["Alice Chen"],
            },
        ]
        (tmp_path / "calendar_events.json").write_text(json.dumps(events))

        result = ingest_calendar(tmp_path)
        assert result["status"] == "ok"
        assert result["events_processed"] == 2
        assert result["unique_attendees"] == 2  # Alice counted once

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_skips_empty_attendees(
        self, mock_exists, mock_update, mock_last_contact, tmp_path
    ):
        events = [{"title": "Solo work", "attendees": [], "start_date": ""}]
        (tmp_path / "calendar_events.json").write_text(json.dumps(events))

        result = ingest_calendar(tmp_path)
        assert result["unique_attendees"] == 0


class TestIngestPhotos:
    """Test Photos face label ingestion."""

    def test_skips_when_no_data(self, tmp_path):
        result = ingest_photos_people(tmp_path)
        assert result["status"] == "skipped"

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_creates_people_from_faces(
        self, mock_exists, mock_update, mock_last_contact, tmp_path
    ):
        people = [
            {
                "name": "Alice Chen",
                "photo_count": 42,
                "first_seen": "2024-01-15T00:00:00+00:00",
                "last_seen": "2025-06-01T00:00:00+00:00",
                "is_key_face": True,
            },
            {
                "name": "Bob Smith",
                "photo_count": 8,
                "first_seen": "2025-03-01T00:00:00+00:00",
                "last_seen": "2025-05-01T00:00:00+00:00",
                "is_key_face": False,
            },
        ]
        (tmp_path / "photos_people.json").write_text(json.dumps(people))

        result = ingest_photos_people(tmp_path)
        assert result["status"] == "ok"
        assert result["people_created"] == 2

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_skips_unnamed_faces(self, mock_exists, mock_update, tmp_path):
        people = [
            {"name": "", "photo_count": 5},
            {"name": "Real Person", "photo_count": 10},
        ]
        (tmp_path / "photos_people.json").write_text(json.dumps(people))

        result = ingest_photos_people(tmp_path)
        assert result["people_created"] == 1


class TestUpdateLastContactSourceDispatch:
    """Per-source dispatch added in PR-D1b. The legacy aggregate
    pwg:lastContact was retired in CM041 PR-D1a; FDA now writes one of
    the per-source predicates depending on the source argument.

    Photos face-label last_seen is proximity (you appeared in a photo
    together) not a contact event, so it is intentionally absent from
    the predicate map and produces a debug-log no-op. Same discipline
    as the PR-A fix that stopped contact_syncer using vCard REV as a
    contact event.
    """

    @patch("ostler_fda.pwg_ingest._sparql_update")
    def test_calendar_source_writes_per_source_predicate(self, mock_update):
        _update_last_contact(
            "https://pwg.dev/ontology#person_abc",
            "2026-04-25T10:00:00+00:00",
            "calendar",
        )
        assert mock_update.called
        sparql = mock_update.call_args[0][0]
        assert "pwg:lastContactCalendar" in sparql
        # Legacy aggregate must not appear at all.
        assert "pwg:lastContact " not in sparql.replace(
            "pwg:lastContactCalendar", ""
        )

    @patch("ostler_fda.pwg_ingest._sparql_update")
    def test_imessage_source_writes_per_source_predicate(self, mock_update):
        """Pre-existing latent bug fix: the iMessage branch was
        previously writing into pwg:lastContact (the legacy aggregate)
        despite the source argument signalling iMessage. The migration
        corrects this alongside the calendar predicate move."""
        _update_last_contact(
            "https://pwg.dev/ontology#person_abc",
            "2026-04-25T10:00:00+00:00",
            "imessage",
        )
        assert mock_update.called
        sparql = mock_update.call_args[0][0]
        assert "pwg:lastContactIMessage" in sparql

    @patch("ostler_fda.pwg_ingest._sparql_update")
    def test_photos_source_is_noop(self, mock_update):
        """Photos are not a contact event - no predicate write."""
        _update_last_contact(
            "https://pwg.dev/ontology#person_abc",
            "2026-04-25T10:00:00+00:00",
            "photos",
        )
        assert not mock_update.called

    @patch("ostler_fda.pwg_ingest._sparql_update")
    def test_unknown_source_is_noop(self, mock_update):
        """Defensive: an unknown source value (e.g. typo, future
        addition that didn't update the dispatch map) produces a
        debug-log no-op rather than a silent write to the wrong
        predicate or a crash."""
        _update_last_contact(
            "https://pwg.dev/ontology#person_abc",
            "2026-04-25T10:00:00+00:00",
            "instagram",
        )
        assert not mock_update.called

    @patch("ostler_fda.pwg_ingest._sparql_update")
    def test_uses_atomic_filter_pattern(self, mock_update):
        """DELETE-INSERT-WHERE-FILTER ensures equal/older dates are
        no-ops without a Python-side comparison; matches the upsert
        shape used by CM041 meeting_syncer, CM046 email loader, and
        CM047 WhatsApp store."""
        _update_last_contact(
            "https://pwg.dev/ontology#person_abc",
            "2026-04-25T10:00:00+00:00",
            "calendar",
        )
        sparql = mock_update.call_args[0][0]
        assert "DELETE" in sparql
        assert "INSERT" in sparql
        assert "OPTIONAL" in sparql
        assert "BOUND(?old)" in sparql
        assert "?old < " in sparql or "?old<" in sparql
        assert "^^xsd:date" in sparql


class TestIngestMailContacts:
    """Test Apple Mail contact ingestion."""

    def test_skips_when_no_data(self, tmp_path):
        result = ingest_mail_contacts(tmp_path)
        assert result["status"] == "skipped"

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_creates_frequent_contacts(self, mock_exists, mock_update, tmp_path):
        contacts = {
            "alice@example.com": 25,
            "bob@example.com": 10,
            "newsletter@example.com": 2,  # Below threshold (3)
        }
        (tmp_path / "apple_mail_contacts.json").write_text(json.dumps(contacts))

        result = ingest_mail_contacts(tmp_path)
        assert result["status"] == "ok"
        assert result["people_created"] == 2  # newsletter skipped (count < 3)

    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    def test_creates_email_identifier(self, mock_exists, mock_update, tmp_path):
        contacts = {"alice@example.com": 10}
        (tmp_path / "apple_mail_contacts.json").write_text(json.dumps(contacts))

        ingest_mail_contacts(tmp_path)

        sparql_calls = " ".join(str(c) for c in mock_update.call_args_list)
        assert "alice@example.com" in sparql_calls
        assert '"email"' in sparql_calls
        assert "APPLE_MAIL" in sparql_calls


class TestIngestAll:
    """Test the master ingestion runner."""

    def test_handles_empty_directory(self, tmp_path):
        result = ingest_all(tmp_path)
        # All should be skipped (no data files)
        for source, status in result.items():
            assert status["status"] == "skipped"

    def test_handles_nonexistent_directory(self, tmp_path):
        result = ingest_all(tmp_path / "nonexistent")
        assert result["status"] == "error"

    @patch("ostler_fda.pwg_ingest.ingest_mail_contacts")
    @patch("ostler_fda.pwg_ingest.ingest_photos_people")
    @patch("ostler_fda.pwg_ingest.ingest_calendar")
    @patch("ostler_fda.pwg_ingest.ingest_imessage")
    def test_runs_all_four_ingestors(
        self, mock_im, mock_cal, mock_photos, mock_mail, tmp_path
    ):
        for mock in [mock_im, mock_cal, mock_photos, mock_mail]:
            mock.return_value = {"status": "ok"}

        result = ingest_all(tmp_path)
        assert "imessage" in result
        assert "calendar" in result
        assert "photos" in result
        assert "apple_mail" in result
        assert all(r["status"] == "ok" for r in result.values())

    @patch("ostler_fda.pwg_ingest.ingest_mail_contacts")
    @patch("ostler_fda.pwg_ingest.ingest_photos_people")
    @patch("ostler_fda.pwg_ingest.ingest_calendar")
    @patch("ostler_fda.pwg_ingest.ingest_imessage")
    def test_one_failure_doesnt_block_others(
        self, mock_im, mock_cal, mock_photos, mock_mail, tmp_path
    ):
        mock_im.side_effect = Exception("connection refused")
        mock_cal.return_value = {"status": "ok"}
        mock_photos.return_value = {"status": "ok"}
        mock_mail.return_value = {"status": "ok"}

        result = ingest_all(tmp_path)
        assert result["imessage"]["status"] == "error"
        assert result["calendar"]["status"] == "ok"
        assert result["photos"]["status"] == "ok"
        assert result["apple_mail"]["status"] == "ok"
