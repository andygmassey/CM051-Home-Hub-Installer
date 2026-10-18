"""Lane 31: meeting-history importer. All data synthetic."""
from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from meeting_import import importer  # noqa: E402
from meeting_import.adapters import parse_file  # noqa: E402
from meeting_import.model import Attendee  # noqa: E402
from meeting_import.people import resolve_attendees  # noqa: E402

VTT = """WEBVTT

1
00:00:03.120 --> 00:00:07.480
Alex Example: Welcome, let's review the synthetic roadmap.

2
00:00:08.000 --> 00:00:11.000
<v Sam Sample>I will send the draft on Friday.</v>
"""
SRT = """1
00:00:01,000 --> 00:00:04,000
Alex Example: First synthetic line.

2
00:00:05,000 --> 00:00:08,000
Sam Sample: Second synthetic line.
"""
OTTER_TXT = """Alex Example  0:03
Welcome to the synthetic call.
Sam Sample  0:09
Thanks, I will draft the notes.
"""
FIREFLIES = {"data": {"transcript": {
    "id": "ff-synth-001", "title": "Synthetic sync", "dateString": "2026-03-04T10:00:00.000Z",
    "duration": 30, "participants": ["alex@example.test", "sam@example.test"],
    "speakers": [{"id": 0, "name": "Alex Example"}, {"id": 1, "name": "Sam"}],
    "sentences": [{"speaker_name": "Alex Example", "text": "Hello synthetic world.", "start_time": 1.5},
                  {"speaker_name": "Sam", "text": "Agreed.", "start_time": 4.0}],
    "summary": {"overview": "Synthetic overview.", "action_items": "- Send the draft\n- Book the room",
                "shorthand_bullet": "- point one\n- point two"}}}}
GRANOLA = {"notes": [{"id": "gr-synth-001", "title": "Synthetic 1:1", "created_at": "2026-03-05T09:00:00Z",
    "attendees": [{"name": "Alex Example", "email": "alex@example.test"}, {"name": "Pat"}],
    "summary_markdown": "Short synthetic overview.\n\n## Decisions\n- Ship the draft\n\n## Next steps\n- Alex to send notes\n- Book the room",
    "transcript": [{"speaker": "Alex Example", "text": "Hi.", "start": 1.0}]}]}


def docx(path: Path, paras: list[str]) -> Path:
    body = "".join(f"<w:p><w:r><w:t>{p}</w:t></w:r></w:p>" for p in paras)
    xml = ('<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/'
           f'wordprocessingml/2006/main"><w:body>{body}</w:body></w:document>')
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("word/document.xml", xml)
    return path


class FakeDirectory:
    def __init__(self):
        self.created, self.name_calls, self.email_calls = [], [], []
        self.people = {"alex@example.test": "urn:p:alex"}
        self.names = {"sam sample": "urn:p:sam"}

    def find_by_email(self, e):
        self.email_calls.append(e)
        return self.people.get(e)

    def find_by_full_name(self, n):
        self.name_calls.append(n)
        return self.names.get(n.lower())


@pytest.fixture
def drop(tmp_path):
    r = tmp_path / "Imports"
    for d in ("granola", "otter", "fireflies", "transcripts"):
        (r / d).mkdir(parents=True)
    (r / "fireflies" / "a.json").write_text(json.dumps(FIREFLIES))
    (r / "granola" / "n.json").write_text(json.dumps(GRANOLA))
    (r / "otter" / "2026-03-06 planning.txt").write_text(OTTER_TXT)
    (r / "transcripts" / "2026-03-07 zoom.vtt").write_text(VTT)
    return r


# ---- adapters, per source and format ----
def test_vtt_name_prefix_and_voice_tag(tmp_path):
    p = tmp_path / "2026-03-07 standup.vtt"; p.write_text(VTT)
    m = parse_file("transcripts", p)[0]
    assert [u.speaker for u in m.utterances] == ["Alex Example", "Sam Sample"]
    assert m.started_at.startswith("2026-03-07") and m.utterances[0].start_s == 3.12

def test_srt(tmp_path):
    p = tmp_path / "x.srt"; p.write_text(SRT)
    assert len(parse_file("transcripts", p)[0].utterances) == 2

def test_docx_header_style_and_label_style(tmp_path):
    a = docx(tmp_path / "a.docx", ["Alex Example  0:03", "Hello.", "Sam Sample  0:09", "Hi."])
    b = docx(tmp_path / "b.docx", ["Alex Example: Hello.", "Sam Sample: Hi."])
    assert [u.speaker for u in parse_file("transcripts", a)[0].utterances] == ["Alex Example", "Sam Sample"]
    assert [u.text for u in parse_file("transcripts", b)[0].utterances] == ["Hello.", "Hi."]

def test_otter_txt_and_srt(tmp_path):
    p = tmp_path / "2026-03-06 call.txt"; p.write_text(OTTER_TXT)
    m = parse_file("otter", p)[0]
    assert m.title == "2026-03-06 call" and m.source_label == "Otter" and len(m.utterances) == 2
    s = tmp_path / "o.srt"; s.write_text(SRT)
    assert parse_file("otter", s)[0].source == "otter"

def test_fireflies_json(tmp_path):
    p = tmp_path / "f.json"; p.write_text(json.dumps(FIREFLIES))
    m = parse_file("fireflies", p)[0]
    assert m.source_id == "ff-synth-001" and m.ended_at.startswith("2026-03-04T10:30")
    assert [a.text for a in m.action_items] == ["Send the draft", "Book the room"]
    assert {a.email for a in m.attendees if a.email} == {"alex@example.test", "sam@example.test"}

def test_granola_json_and_markdown(tmp_path):
    p = tmp_path / "g.json"; p.write_text(json.dumps(GRANOLA))
    m = parse_file("granola", p)[0]
    assert [a.text for a in m.action_items] == ["Alex to send notes", "Book the room"]
    assert m.summary_topics[0][0] == "Decisions"
    md = tmp_path / "n.md"; md.write_text("---\nid: gr-md-1\ntitle: Synthetic note\n---\nOverview.\n## Action items\n- Do it\n")
    g = parse_file("granola", md)[0]
    assert g.source_id == "gr-md-1" and g.action_items[0].text == "Do it"

def test_garbage_raises_or_empties(tmp_path):
    p = tmp_path / "bad.json"; p.write_text("{not json")
    with pytest.raises(ValueError):
        parse_file("fireflies", p)
    e = tmp_path / "e.vtt"; e.write_text("WEBVTT\n")
    assert parse_file("transcripts", e) == []


# ---- attendee resolution ----
def test_existing_person_is_linked_unknown_first_name_is_not_minted():
    d = FakeDirectory()
    links = resolve_attendees((Attendee("Alex Example", "alex@example.test"), Attendee("Sam Sample"),
                               Attendee("Jordan"), Attendee("Speaker 1"), Attendee("Robin Nobody")), d)
    by = {l.name: l for l in links}
    assert by["Alex Example"].person_uri == "urn:p:alex" and by["Alex Example"].how == "email"
    assert by["Sam Sample"].person_uri == "urn:p:sam" and by["Sam Sample"].how == "full_name"
    assert by["Jordan"].person_uri is None and by["Jordan"].how == "single_name"
    assert "Jordan" not in d.name_calls and "Speaker 1" not in d.name_calls   # never even looked up
    assert by["Robin Nobody"].how == "unresolved" and by["Speaker 1"].how == "generic"
    assert not hasattr(d, "create") and d.created == []

def test_owner_is_not_linked_as_attendee():
    l = resolve_attendees((Attendee("Owen Owner", "owen@example.test"),), FakeDirectory(), owner_email="owen@example.test")
    assert l[0].how == "owner"


# ---- artefacts, labelling, privacy, todos ----
def run(drop, tmp_path, **kw):
    out = tmp_path / "Conversations"
    r = importer.import_all(root=drop, out_root=out, force=True, directory=FakeDirectory(),
                            reminders_db_path=tmp_path / "rem.db", **kw)
    return r, out

def test_four_artefacts_labels_privacy_and_links(drop, tmp_path):
    r, out = run(drop, tmp_path)
    assert r["imported"] == 4 and r["failed"] == 0
    f = next(Path(x) for x in r["folders"] if "2026-03-04" in x)
    assert f.parent.name == "2026-03-04" and f.parent.parent == out
    s, t, td = [(f / n).read_text() for n in ("summary.md", "transcript.md", "todos.md")]
    assert "From Fireflies: Synthetic overview." in s and "(from Fireflies)" in s
    assert "**Alex Example:** Hello synthetic world." in t
    assert "Send the draft" in td and "from Fireflies" in td and "status: extracted" in td
    assert "privacy_level: L2" in s and 'source_app: "Fireflies"' in s
    assert "linked_person_1" in s and "urn:p:alex" in s
    assert not (tmp_path / "rem.db").exists()          # nothing queued for Reminders

def test_private_flag_makes_l3(drop, tmp_path):
    r, _ = run(drop, tmp_path, privacy_level="L3")
    assert all("privacy_level: L3" in (Path(x) / "summary.md").read_text() for x in r["folders"])

def test_reminders_only_on_opt_in(drop, tmp_path):
    run(drop, tmp_path, push_reminders=True)
    assert (tmp_path / "rem.db").exists()

def test_no_summary_is_said_plainly(drop, tmp_path):
    r, _ = run(drop, tmp_path)
    f = next(Path(x) for x in r["folders"] if "2026-03-07" in x)
    s = (f / "summary.md").read_text()
    assert "supplied no summary" in s and 'summary_origin: "none"' in s


# ---- idempotency + flag ----
def snapshot(root):
    return {str(p.relative_to(root)): p.read_text() for p in sorted(root.rglob("*")) if p.is_file()}

def test_reimport_is_idempotent_even_after_a_person_appears(drop, tmp_path):
    _, out = run(drop, tmp_path)
    first = snapshot(out)
    d = FakeDirectory(); d.names["robin nobody"] = "urn:p:robin"
    importer.import_all(root=drop, out_root=out, force=True, directory=d, reminders_db_path=tmp_path / "rem.db")
    second = snapshot(out)
    assert first.keys() == second.keys()               # same folders, no duplicates
    assert len([k for k in second if k.endswith("summary.md")]) == 4

def test_flag_off_by_default(drop, tmp_path, monkeypatch):
    monkeypatch.delenv(importer.FLAG, raising=False)
    r = importer.import_all(root=drop, out_root=tmp_path / "o")
    assert r["status"] == "disabled" and not (tmp_path / "o").exists()
    monkeypatch.setenv(importer.FLAG, "1")
    assert importer.enabled()


# ---- Granola, official public API v1 schema (docs.granola.ai/api-reference/openapi.json,
# fetched 2026-10-18: Note, User, CalendarEvent, Transcript, Speaker). Values synthetic.
GRANOLA_V1 = {
    "id": "not_AAAAAAAAAAAAA1", "object": "note", "title": "Synthetic quarterly review",
    "owner": {"name": "Owen Owner", "email": "owen@example.test"},
    "created_at": "2026-03-10T09:58:00Z", "updated_at": "2026-03-10T11:00:00Z", "deleted_at": None,
    "web_url": "https://notes.granola.ai/d/00000000-0000-0000-0000-000000000000",
    "calendar_event": {"event_title": "Synthetic quarterly review",
                       "invitees": [{"email": "alex@example.test"}, {"email": "robin@example.test"}],
                       "organiser": "owen@example.test", "calendar_event_id": "synthetic_evt_1",
                       "scheduled_start_time": "2026-03-10T10:00:00Z",
                       "scheduled_end_time": "2026-03-10T10:30:00Z"},
    "attendees": [{"name": "Owen Owner", "email": "owen@example.test"},
                  {"name": "Alex Example", "email": "alex@example.test"}],
    "folder_membership": [], "space_membership": [],
    "summary_text": "Plain synthetic summary.",
    "summary_markdown": "Synthetic overview line.\n\n### Budget\n- Hold spend flat\n\n### Action items\n- Alex to circulate the deck",
    "transcript": [
        {"speaker": {"source": "microphone", "attribution": "me"}, "text": "Shall we start?",
         "start_time": "2026-03-10T10:00:05Z", "end_time": "2026-03-10T10:00:07Z"},
        {"speaker": {"source": "speaker", "attribution": "them", "name": "Alex Example"},
         "text": "Yes, deck is ready.", "start_time": "2026-03-10T10:01:10Z", "end_time": "2026-03-10T10:01:14Z"},
        {"speaker": {"source": "microphone", "diarization_label": "Speaker B"},
         "text": "One more point.", "start_time": "2026-03-10T10:02:00Z", "end_time": "2026-03-10T10:02:03Z"},
    ],
}

def test_granola_official_v1_note(tmp_path):
    p = tmp_path / "note.json"; p.write_text(json.dumps(GRANOLA_V1))
    m = parse_file("granola", p)[0]
    # speaker is an OBJECT in the official schema, never a string
    assert [u.speaker for u in m.utterances] == ["Me", "Alex Example", "Speaker B"]
    assert [u.start_s for u in m.utterances] == [5.0, 70.0, 120.0]   # relative to the scheduled start
    assert m.started_at == "2026-03-10T10:00:00Z" and m.ended_at == "2026-03-10T10:30:00Z"
    assert m.source_id == "not_AAAAAAAAAAAAA1"
    emails = {a.email for a in m.attendees}
    assert {"alex@example.test", "robin@example.test", "owen@example.test"} <= emails
    assert len([a for a in m.attendees if a.email == "alex@example.test"]) == 1  # invitee deduped
    assert [a.text for a in m.action_items] == ["Alex to circulate the deck"]
    assert m.summary_topics[0][0] == "Budget"

def test_granola_v1_list_page_and_summary_text_fallback(tmp_path):
    n = dict(GRANOLA_V1, summary_markdown=None, transcript=None)
    p = tmp_path / "page.json"; p.write_text(json.dumps({"notes": [n], "hasMore": False, "cursor": None}))
    m = parse_file("granola", p)[0]
    assert m.summary_overview == "Plain synthetic summary." and m.utterances == ()

# Granola Settings > Profile > Generate CSV (docs.granola.ai/help-center/sharing/exporting-notes):
# "title, note summary, transcript, and other basic details for each note". Column
# NAMES are not documented: these headers are ASSUMED, matched case-insensitively.
GRANOLA_CSV = (
    'Title,Created At,Attendees,Summary,Transcript\n'
    '"Synthetic hiring sync",2026-03-12T14:00:00Z,"Alex Example <alex@example.test>; Sam Sample",'
    '"Overview of the synthetic sync.\n\n## Next steps\n- Sam to draft the role",'
    '"Me: Thanks for joining.\nAlex Example: Happy to."\n'
)

def test_granola_csv_export(tmp_path):
    p = tmp_path / "granola-export.csv"; p.write_text(GRANOLA_CSV)
    ms = parse_file("granola", p)
    assert len(ms) == 1
    m = ms[0]
    assert m.title == "Synthetic hiring sync" and m.started_at.startswith("2026-03-12")
    assert [u.speaker for u in m.utterances] == ["Me", "Alex Example"]
    assert [a.text for a in m.action_items] == ["Sam to draft the role"]
    assert {a.email for a in m.attendees if a.email} == {"alex@example.test"}
    assert "Sam Sample" in {a.name for a in m.attendees}

def test_granola_csv_without_a_transcript_column_is_refused_loudly(tmp_path):
    p = tmp_path / "other.csv"; p.write_text("Foo,Bar\n1,2\n")
    with pytest.raises(ValueError):
        parse_file("granola", p)


# ---- Otter, layouts from Otter's own "Export conversations" article
# (help.otter.ai/hc/en-us/articles/360047733634, updated 2026-10-10, "Export
# Examples" image read 2026-10-18). Filenames are "<Title>_otter_ai.<ext>";
# TXT has no title line, "Name  m:ss" headers, a footer. Values synthetic.
OTTER_TXT_REAL = """Alex Example  0:00
Thanks for joining the synthetic sync, the roadmap is the first item and we have a lot to cover today.

Speaker 1  0:40
Agreed. I will send the draft on Friday.

Sam Sample  1:05
Sounds good.

Transcribed by https://otter.ai
"""

def test_otter_txt_documented_layout(tmp_path):
    p = tmp_path / "Synthetic Weekly Call_otter_ai.txt"; p.write_text(OTTER_TXT_REAL)
    m = parse_file("otter", p)[0]
    assert m.title == "Synthetic Weekly Call"
    assert [u.speaker for u in m.utterances] == ["Alex Example", "Speaker 1", "Sam Sample"]
    assert [u.start_s for u in m.utterances] == [0, 40, 65]
    assert all("otter.ai" not in u.text for u in m.utterances)      # footer is not speech
    assert {a.name for a in m.attendees} == {"Alex Example", "Sam Sample"}  # "Speaker 1" is not a person

def test_otter_docx_documented_layout(tmp_path):
    p = docx(tmp_path / "Synthetic Weekly Call_otter_ai.docx", [
        "Synthetic Weekly Call", "Fri, Feb 20, 2026 3:34PM • 1:38",
        "SUMMARY KEYWORDS", "roadmap, drafts, synthetic data",
        "SPEAKERS", "Speaker 1, Alex Example",
        "Alex Example  00:00", "Thanks for joining.",
        "Speaker 1  00:40", "I will send the draft.",
        "Transcribed by https://otter.ai"])
    m = parse_file("otter", p)[0]
    assert m.title == "Synthetic Weekly Call"
    assert m.started_at == "2026-02-20T15:34:00" and m.ended_at == "2026-02-20T15:35:38"
    assert [u.speaker for u in m.utterances] == ["Alex Example", "Speaker 1"]
    assert [a.name for a in m.attendees] == ["Alex Example"]
    assert m.utterances[-1].text == "I will send the draft."

def test_otter_srt_name_prefix_and_title(tmp_path):
    p = tmp_path / "Synthetic Weekly Call_otter_ai.srt"
    p.write_text("1\n00:00:00,096 --> 00:00:03,036\nAlex Example: And earlier, I\nhave a synthetic point,\n\n"
                 "2\n00:00:03,096 --> 00:00:06,576\nand it continues here\n")
    m = parse_file("otter", p)[0]
    assert m.title == "Synthetic Weekly Call"
    assert [u.speaker for u in m.utterances] == ["Alex Example", "Alex Example"]


# ---- Fireflies, official GraphQL schema (docs.fireflies.ai/schema/transcript,
# /schema/sentence, /schema/summary, /schema/meeting-attendee, read 2026-10-18).
# Sentence.start_time is type String. Values synthetic.
FIREFLIES_V = {"data": {"transcript": {
    "id": "SYNTH01FF", "title": "Synthetic pipeline review", "dateString": "2026-03-14T16:00:00.000Z",
    "date": 1773504000000, "duration": 42.5, "organizer_email": "alex@example.test",
    "user": {"email": "owen@example.test", "name": "Owen Owner"},
    "participants": ["alex@example.test", "robin@example.test", "owen@example.test"],
    "meeting_attendees": [{"displayName": "Alex Example", "email": "alex@example.test", "name": "Alex Example"},
                          {"displayName": "Robin Sample", "email": "robin@example.test", "name": None}],
    "speakers": [{"id": "0", "name": "Alex Example"}, {"id": "1", "name": "Owen Owner"}],
    "sentences": [
        {"index": 0, "text": "Let us begin.", "raw_text": "let us begin", "start_time": "2.48",
         "end_time": "3.9", "speaker_id": "0", "speaker_name": "Alex Example"},
        {"index": 1, "text": "I have the numbers.", "raw_text": "i have the numbers", "start_time": "65.2",
         "end_time": "67.0", "speaker_id": "1", "speaker_name": "Owen Owner"}],
    "summary": {"overview": "Synthetic pipeline overview.", "gist": "One line.",
                "action_items": "**Alex Example**\nShare the revised forecast (01:05)\nBook the review room (02:10)\n\n**Owen Owner**\nSend the numbers (03:00)",
                "topics_discussed": ["Forecast", "Hiring"], "keywords": "forecast, hiring"}}}}

def test_fireflies_official_schema(tmp_path):
    p = tmp_path / "ff.json"; p.write_text(json.dumps(FIREFLIES_V))
    m = parse_file("fireflies", p)[0]
    assert [u.start_s for u in m.utterances] == [2.48, 65.2]          # String start_time -> seconds
    assert m.ended_at.startswith("2026-03-14T16:42:30")
    by_email = {a.email: a.name for a in m.attendees if a.email}
    assert by_email["alex@example.test"] == "Alex Example" and "robin@example.test" in by_email
    assert len([a for a in m.attendees if a.name == "Alex Example"]) == 1   # speaker + attendee merged
    assert [(a.text, a.assignee) for a in m.action_items] == [
        ("Share the revised forecast", "Alex Example"), ("Book the review room", "Alex Example"),
        ("Send the numbers", "Owen Owner")]

def test_fireflies_string_start_time_renders(tmp_path):
    d = tmp_path / "Imports"; (d / "fireflies").mkdir(parents=True)
    (d / "fireflies" / "ff.json").write_text(json.dumps(FIREFLIES_V))
    r, out = run(d, tmp_path)
    assert r["imported"] == 1 and r["failed"] == 0
    t = (Path(r["folders"][0]) / "transcript.md").read_text()
    assert "[01:05] **Owen Owner:** I have the numbers." in t

def test_fireflies_unrecognised_json_is_refused(tmp_path):
    p = tmp_path / "x.json"; p.write_text(json.dumps({"something": "else"}))
    with pytest.raises(ValueError):
        parse_file("fireflies", p)


# ---- Fathom, official OpenAPI (developers.fathom.ai/api-reference/openapi.yaml,
# read 2026-10-18): GET /meetings?include_transcript=true&include_summary=true
# &include_action_items=true -> {"items": [Meeting], "next_cursor", "limit"}.
# TranscriptItem.timestamp is "HH:MM:SS"; speaker is {display_name,
# matched_calendar_invitee_email}. Values synthetic.
FATHOM_PAGE = {"limit": 10, "next_cursor": None, "items": [{
    "title": "Synthetic onboarding call", "meeting_title": "Onboarding: Example Co", "meeting_type": None,
    "recording_id": 900000001, "url": "https://fathom.video/calls/0", "share_url": "https://fathom.video/share/0",
    "created_at": "2026-03-16T09:31:00Z", "scheduled_start_time": "2026-03-16T09:30:00Z",
    "scheduled_end_time": "2026-03-16T10:00:00Z", "recording_start_time": "2026-03-16T09:31:10Z",
    "recording_end_time": "2026-03-16T09:58:40Z", "calendar_invitees_domains_type": "one_or_more_external",
    "shared_with": None, "transcript_language": "en",
    "recorded_by": {"name": "Owen Owner", "email": "owen@example.test", "email_domain": "example.test", "team": None},
    "calendar_invitees": [
        {"name": "Owen Owner", "email": "owen@example.test", "email_domain": "example.test", "is_external": False,
         "matched_speaker_display_name": "Owen Owner"},
        {"name": "Alex Example", "email": "alex@example.test", "email_domain": "example.test", "is_external": True,
         "matched_speaker_display_name": "Alex Example"}],
    "transcript": [
        {"speaker": {"display_name": "Owen Owner", "matched_calendar_invitee_email": "owen@example.test"},
         "text": "Welcome aboard.", "timestamp": "00:00:04"},
        {"speaker": {"display_name": "Alex Example", "matched_calendar_invitee_email": "alex@example.test"},
         "text": "Glad to be here.", "timestamp": "00:01:12"}],
    "default_summary": {"template_name": "general",
                        "markdown_formatted": "## Meeting Purpose\nSynthetic onboarding.\n\n## Key Takeaways\n- Access is set up\n"},
    "action_items": [
        {"description": "Send the welcome pack", "user_generated": False, "completed": False,
         "recording_timestamp": "00:10:45", "recording_playback_url": "https://fathom.video/calls/0?timestamp=645",
         "assignee": {"name": "Owen Owner", "email": "owen@example.test", "team": None}},
        {"description": "Already done item", "user_generated": True, "completed": True,
         "recording_timestamp": "00:12:00", "recording_playback_url": "https://fathom.video/calls/0?timestamp=720",
         "assignee": {"name": None, "email": None, "team": None}}],
    "highlights": [], "crm_matches": None}]}

def test_fathom_official_meeting_list(tmp_path):
    p = tmp_path / "meetings.json"; p.write_text(json.dumps(FATHOM_PAGE))
    m = parse_file("fathom", p)[0]
    assert m.source_label == "Fathom" and m.source_id == "900000001"
    assert m.started_at == "2026-03-16T09:31:10Z" and m.ended_at == "2026-03-16T09:58:40Z"
    assert [(u.speaker, u.start_s) for u in m.utterances] == [("Owen Owner", 4), ("Alex Example", 72)]
    assert {a.email for a in m.attendees} == {"owen@example.test", "alex@example.test"}
    assert [(a.text, a.assignee) for a in m.action_items] == [("Send the welcome pack", "Owen Owner")]
    assert [t[0] for t in m.summary_topics] == ["Meeting Purpose", "Key Takeaways"]

def test_fathom_is_a_drop_folder_source(tmp_path):
    d = tmp_path / "Imports"; (d / "fathom").mkdir(parents=True)
    (d / "fathom" / "meetings.json").write_text(json.dumps(FATHOM_PAGE))
    r, out = run(d, tmp_path)
    assert r["imported"] == 1 and r["failed"] == 0
    s = (Path(r["folders"][0]) / "summary.md").read_text()
    assert 'source_app: "Fathom"' in s and "privacy_level: L2" in s

def test_fathom_unrecognised_json_is_refused(tmp_path):
    p = tmp_path / "x.json"; p.write_text(json.dumps({"items": [{"nope": 1}]}))
    with pytest.raises(ValueError):
        parse_file("fathom", p)


# ---- customer path: a flat ~/Downloads, detected by content, plus the record
# the Doctor's source table reads (key=value, ~/.ostler/state/hydrate/<source>.done).
from meeting_import.adapters import detect  # noqa: E402

def test_detect_by_content_and_documented_names(tmp_path):
    (tmp_path / "Synthetic Weekly Call_otter_ai.txt").write_text(OTTER_TXT_REAL)
    (tmp_path / "ff.json").write_text(json.dumps(FIREFLIES_V))
    (tmp_path / "fathom.json").write_text(json.dumps(FATHOM_PAGE))
    (tmp_path / "granola-note.json").write_text(json.dumps(GRANOLA_V1))
    (tmp_path / "granola-export.csv").write_text(GRANOLA_CSV)
    (tmp_path / "package.json").write_text(json.dumps({"name": "x", "version": "1"}))   # not a meeting
    (tmp_path / "holiday.docx").write_bytes(b"PK")                                       # never guessed
    (tmp_path / "budget.csv").write_text("Title,Summary\nx,y\n")                         # no Granola name
    got = {p.name: detect(p) for p in tmp_path.iterdir()}
    assert got == {"Synthetic Weekly Call_otter_ai.txt": "otter", "ff.json": "fireflies",
                   "fathom.json": "fathom", "granola-note.json": "granola",
                   "granola-export.csv": "granola", "package.json": None,
                   "holiday.docx": None, "budget.csv": None}

def test_flat_downloads_end_to_end_with_doctor_record(tmp_path):
    dl = tmp_path / "Downloads"; dl.mkdir()
    (dl / "Synthetic Weekly Call_otter_ai.txt").write_text(OTTER_TXT_REAL)
    (dl / "ff.json").write_text(json.dumps(FIREFLIES_V))
    (dl / "fathom.json").write_text(json.dumps(FATHOM_PAGE))
    (dl / "granola-export.csv").write_text(GRANOLA_CSV)
    (dl / "package.json").write_text(json.dumps({"name": "x"}))
    state = tmp_path / "hydrate"
    out = tmp_path / "Conversations"
    r = importer.import_all(root=dl, loose=True, out_root=out, force=True, directory=FakeDirectory(),
                            reminders_db_path=tmp_path / "rem.db", sentinel_dir=state)
    assert r["imported"] == 4 and r["failed"] == 0 and r["by_source"] == {
        "otter": 1, "fireflies": 1, "fathom": 1, "granola": 1}
    for f in map(Path, r["folders"]):
        assert {"summary.md", "transcript.md", "todos.md"} <= {p.name for p in f.iterdir()}
        assert f.parent.parent == out and len(f.parent.name) == 10
    rec = dict(l.split("=", 1) for l in (state / "meetings.done").read_text().splitlines())
    assert rec["source"] == "meetings" and rec["status"] == "ok" and rec["item_count"] == "4"
    assert rec["payload"] == "fathom=1 fireflies=1 granola=1 otter=1"

def test_doctor_record_says_no_data_and_error_honestly(tmp_path):
    dl = tmp_path / "Downloads"; dl.mkdir()
    state = tmp_path / "hydrate"
    importer.import_all(root=dl, loose=True, out_root=tmp_path / "o", force=True, sentinel_dir=state)
    rec = dict(l.split("=", 1) for l in (state / "meetings.done").read_text().splitlines())
    assert rec["status"] == "no_data" and rec["item_count"] == "0"
    (dl / "broken_otter_ai.docx").write_bytes(b"not a zip")
    importer.import_all(root=dl, loose=True, out_root=tmp_path / "o", force=True, sentinel_dir=state)
    rec = dict(l.split("=", 1) for l in (state / "meetings.done").read_text().splitlines())
    assert rec["status"] == "error" and rec["failed"] == "1"


def test_cli_end_to_end_export_files_to_four_artefacts(tmp_path):
    """The real entry point, in a child process, flag ON, sandboxed HOME."""
    import os, subprocess
    dl = tmp_path / "Downloads"; dl.mkdir()
    (dl / "granola-export.csv").write_text(GRANOLA_CSV)
    (dl / "Synthetic Weekly Call_otter_ai.txt").write_text(OTTER_TXT_REAL)
    (dl / "ff.json").write_text(json.dumps(FIREFLIES_V))
    (dl / "fathom.json").write_text(json.dumps(FATHOM_PAGE))
    out = tmp_path / "Conversations"
    env = dict(os.environ, OSTLER_HOME=str(tmp_path / ".ostler"),
               OSTLER_MEETING_IMPORT_ENABLED="1", PYTHONPATH=str(ROOT))
    off = subprocess.run([sys.executable, "-m", "meeting_import", "--loose", str(dl), "--out", str(out)],
                         env=dict(env, OSTLER_MEETING_IMPORT_ENABLED="0"), capture_output=True, text=True, cwd=ROOT)
    assert off.returncode == 0 and '"disabled"' in off.stdout and not out.exists()   # flag OFF control
    r = subprocess.run([sys.executable, "-m", "meeting_import", "--loose", str(dl), "--out", str(out)],
                       env=env, capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stderr
    res = json.loads(r.stdout.strip().splitlines()[-1])
    assert res["imported"] == 4 and res["failed"] == 0
    bundles = sorted(p.parent for p in out.rglob("summary.md"))
    assert len(bundles) == 4
    for b in bundles:
        s, t, td = [(b / n).read_text() for n in ("summary.md", "transcript.md", "todos.md")]
        for doc in (s, t, td):
            assert doc.startswith("---") and "privacy_level: L2" in doc and "conversation_id:" in doc
        assert "imported_from:" in s and t.strip()
    rec = (tmp_path / ".ostler" / "state" / "hydrate" / "meetings.done").read_text()
    assert "status=ok" in rec and "item_count=4" in rec
