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
OTTER_TXT = """Synthetic planning call
Alex Example  0:03
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
    assert m.title == "Synthetic planning call" and m.source_label == "Otter" and len(m.utterances) == 2
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
