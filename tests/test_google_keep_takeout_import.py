"""Google Takeout "Keep" importer (vendor/ostler_fda/google_keep_takeout.py).

PINS: a Keep export becomes one markdown note per live note, with
frontmatter carrying privacy_level L2; trashed notes never appear; a
checklist keeps its unchecked items as open tasks; a re-run rewrites
nothing; a corrupt or non-note JSON is reported per file and never aborts
the rest; a title cannot inject a frontmatter key.

Fixtures follow the community-documented layout, UNVERIFIED against a real
export. Synthetic content only; addresses on example.com.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "vendor"))

from ostler_fda import google_keep_takeout as gk  # noqa: E402

USEC = 1675263845 * 10**6  # 2023-02-01T15:04:05Z, epoch microseconds


def _note(keep: Path, name: str, data) -> None:
    keep.mkdir(parents=True, exist_ok=True)
    (keep / name).write_text(data if isinstance(data, str) else json.dumps(data))


def build(root: Path) -> Path:
    keep = root / "Takeout" / "Keep"
    _note(keep, "Shopping.json", {
        "title": "Shopping", "textContent": "",
        "listContent": [{"text": "Milk", "isChecked": False}, {"text": "Bread", "isChecked": True}],
        "labels": [{"name": "Home"}],
        "sharees": [{"email": "jane.smith@example.com", "isOwner": False, "type": "WRITER"},
                    {"email": "alex.doe@example.com", "isOwner": True, "type": "OWNER"}],
        "isTrashed": False, "isArchived": False, "isPinned": True,
        "createdTimestampUsec": USEC, "userEditedTimestampUsec": USEC + 60_000_000,
    })
    _note(keep, "Book ideas.json", {
        "title": "Book ideas", "textContent": "Ask the club about the next pick\nmaybe a novel",
        "annotations": [{"url": "https://example.com/book", "title": "A book", "source": "WEBLINK"}],
        "attachments": [{"filePath": "img-1.png", "mimetype": "image/png"}],
        "isArchived": True, "createdTimestampUsec": USEC,
    })
    (keep / "img-1.png").write_bytes(b"\x89PNG synthetic")
    _note(keep, "Old.json", {"title": "Deleted thought", "textContent": "gone",
                             "isTrashed": True, "createdTimestampUsec": USEC})
    _note(keep, "Shopping.html", "<html>ignored twin</html>")
    return root


def test_live_notes_become_markdown_and_trash_is_skipped(tmp_path):
    ex = gk.parse_export(build(tmp_path))
    assert sorted(n.title for n in ex.notes) == ["Book ideas", "Shopping"]
    assert ex.trashed_skipped == 1 and ex.errors == []
    out = tmp_path / "md"
    r = gk.write_markdown(ex, out)
    assert r == {"notes_created": 2, "notes_updated": 0, "notes_unchanged": 0}
    texts = {p.name: p.read_text() for p in out.glob("*.md")}
    assert len(texts) == 2
    assert not any("Deleted thought" in t for t in texts.values())
    shopping = next(t for n, t in texts.items() if n.startswith("shopping-"))
    assert shopping.startswith("---\n") and "privacy_level: L2" in shopping
    assert "- [ ] Milk" in shopping and "- [x] Bread" in shopping
    assert 'shared_with: ["jane.smith@example.com"]' in shopping   # owner excluded
    assert 'tags: ["Home"]' in shopping and "pinned: true" in shopping
    assert "created: 2023-02-01T15:04:05+00:00" in shopping
    book = next(t for n, t in texts.items() if n.startswith("book-ideas-"))
    assert "archived: true" in book
    assert "- [A book](https://example.com/book)" in book
    assert "img-1.png image/png" in book and "(not in export)" not in book


def test_second_run_rewrites_nothing(tmp_path):
    root = build(tmp_path)
    out = tmp_path / "md"
    gk.write_markdown(gk.parse_export(root), out)
    before = {p.name: p.stat().st_mtime_ns for p in out.glob("*.md")}
    r = gk.write_markdown(gk.parse_export(root), out)
    assert r == {"notes_created": 0, "notes_updated": 0, "notes_unchanged": 2}
    assert {p.name: p.stat().st_mtime_ns for p in out.glob("*.md")} == before


def test_an_edited_note_updates_in_place(tmp_path):
    root = build(tmp_path)
    out = tmp_path / "md"
    gk.write_markdown(gk.parse_export(root), out)
    p = root / "Takeout/Keep/Book ideas.json"
    d = json.loads(p.read_text())
    d["textContent"] += "\nand a second line"
    p.write_text(json.dumps(d))
    r = gk.write_markdown(gk.parse_export(root), out)
    assert r == {"notes_created": 0, "notes_updated": 1, "notes_unchanged": 1}
    assert len(list(out.glob("*.md"))) == 2


def test_per_file_errors_and_renamed_fields(tmp_path):
    root = build(tmp_path)
    keep = root / "Takeout/Keep"
    _note(keep, "Broken.json", "{ nope")
    _note(keep, "Labels.json", ["not", "a", "note"])
    _note(keep, "Settings.json", {"theme": "dark"})
    _note(keep, "Renamed.json", {"title": "Renamed", "text": "body via alias",
                                 "items": [{"text": "Task", "checked": False}],
                                 "created": "2023-02-01T15:04:05Z"})
    ex = gk.parse_export(root)
    errs = {(e.path, e.reason, e.detail) for e in ex.errors}
    assert errs == {("Broken.json", "bad_json", "JSONDecodeError"),
                    ("Labels.json", "unexpected_shape", "not_object"),
                    ("Settings.json", "unexpected_shape", "no_note_fields")}
    ren = next(n for n in ex.notes if n.title == "Renamed")
    assert ren.text == "body via alias" and ren.items == [{"text": "Task", "checked": False}]
    assert ren.created is not None and ren.created.year == 2023


def test_a_title_cannot_inject_frontmatter(tmp_path):
    keep = tmp_path / "Keep"
    _note(keep, "x.json", {"title": "Hi\nprivacy_level: L0", "textContent": "t",
                           "createdTimestampUsec": USEC})
    ex = gk.parse_export(tmp_path)
    md = gk.render_markdown(ex.notes[0])
    fm = md.split("\n---\n", 1)[0]
    assert [ln for ln in fm.splitlines() if ln.startswith("privacy_level:")] == ["privacy_level: L2"]


def test_cli_counts_only(tmp_path, capsys):
    root = build(tmp_path)
    out = tmp_path / "md"
    assert gk.main(["--export-path", str(root), "--output-dir", str(out), "--json"]) == 0
    res = json.loads(capsys.readouterr().out)
    assert (res["status"], res["notes"], res["trashed_skipped"], res["notes_created"]) == ("ok", 2, 1, 2)
    assert "Shopping" not in json.dumps(res) and "example.com" not in json.dumps(res)
    assert gk.main(["--export-path", str(tmp_path / "nothing"), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "not_found"
