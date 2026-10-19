"""Parse a Google Takeout "Keep" export into markdown notes.

Background
==========

Google Keep has no consumer read API. Takeout (takeout.google.com, product
"Keep") is the owner-initiated route: free, no developer verification.

Layout (UNVERIFIED against a real export)
=========================================

From community parsers, not from a Google spec page. Every field below is
UNVERIFIED until a real export is opened; the parser reads each with a
fallback and reports a file it cannot read, per file, without aborting::

    Takeout/Keep/
        <note title or timestamp>.json   one per note (UNVERIFIED)
        <note title or timestamp>.html   rendered twin, ignored
        <attachment>.png / .jpg / .3gp   (UNVERIFIED)
        Labels.txt                       one label per line (UNVERIFIED)

Note JSON (UNVERIFIED)::

    {"title": "...", "textContent": "...",
     "listContent": [{"text": "...", "isChecked": false}],
     "labels": [{"name": "..."}],
     "annotations": [{"url": "...", "title": "...", "source": "WEBLINK"}],
     "attachments": [{"filePath": "...", "mimetype": "image/png"}],
     "sharees": [{"email": "...", "isOwner": false, "type": "WRITER"}],
     "color": "DEFAULT", "isTrashed": false, "isPinned": false,
     "isArchived": false,
     "createdTimestampUsec": 1675263845000000,
     "userEditedTimestampUsec": 1675263845000000}

Aliases accepted (the first is the documented name, the rest are guesses at
a rename and UNVERIFIED): ``textContent | text | content``,
``listContent | list | items``, ``createdTimestampUsec | createdTimestamp |
created``, ``userEditedTimestampUsec | updatedTimestampUsec | updated``.

Policy
======

* Trashed notes are skipped (the owner deleted them). Archived notes are kept
  and marked ``archived: true``.
* A checklist renders as markdown task items; unchecked items stay ``- [ ]``.
* ``privacy_level: L2`` on every note, matching ``apple_notes`` and CM024's
  PrivacyClassifier default for knowledge content.
* Sharee emails are recorded in frontmatter ONLY. A sharee is not minted as a
  Person: sharing a shopping list is weak evidence of a relationship and the
  people graph has better sources for the same addresses.
* Output file name is ``<slug>-<id>.md`` with ``id`` derived from the source
  file name plus the creation time, so a re-run of the same export rewrites
  nothing: an unchanged note is not touched (counted ``unchanged``).

Persistence is NOT done here. The markdown tree is the staged, re-runnable
artefact. Making it searchable needs the knowledge pipeline to take a
markdown directory (see the wiring list in the PR); ``universal_import``'s
Apple Notes leg documents the same deferral and the same reason.

Privacy of output: logs, errors and ``--json`` are counts and relative file
names only. No titles, no bodies.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, List, Optional

logger = logging.getLogger(__name__)

SOURCE = "google_keep"
PRIVACY_L2 = "L2"

_TEXT_KEYS = ("textContent", "text", "content")
_LIST_KEYS = ("listContent", "list", "items")
_CREATED_KEYS = ("createdTimestampUsec", "createdTimestamp", "created")
_EDITED_KEYS = ("userEditedTimestampUsec", "updatedTimestampUsec", "updated")


@dataclass
class FileError:
    path: str
    reason: str      # missing | unreadable | bad_json | unexpected_shape
    detail: str = ""

    def to_dict(self) -> dict:
        return {"path": self.path, "reason": self.reason, "detail": self.detail}


@dataclass
class KeepNote:
    source_file: str
    title: str
    text: str
    items: List[dict]                 # {"text": str, "checked": bool}
    labels: List[str]
    links: List[dict]                 # {"url": str, "title": str}
    attachments: List[dict]           # {"file": str, "mimetype": str, "present": bool}
    sharees: List[str]
    created: Optional[datetime]
    edited: Optional[datetime]
    pinned: bool
    archived: bool
    color: str

    @property
    def note_id(self) -> str:
        created = self.created.isoformat() if self.created else ""
        return hashlib.sha1(f"{self.source_file}|{created}".encode("utf-8")).hexdigest()[:12]


@dataclass
class KeepExport:
    root: Path
    notes: List[KeepNote] = field(default_factory=list)
    trashed_skipped: int = 0
    empty_skipped: int = 0
    errors: List[FileError] = field(default_factory=list)


def _first(d: dict, keys) -> Any:
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def _usec(value: Any) -> Optional[datetime]:
    if isinstance(value, str) and value.strip().isdigit():
        value = int(value.strip())
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        if isinstance(value, str):
            try:
                iso = value.strip()
                iso = iso[:-1] + "+00:00" if iso.endswith("Z") else iso
                dt = datetime.fromisoformat(iso)
                return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
            except ValueError:
                return None
        return None
    n = float(value)
    if n > 1e17:
        n /= 1e9
    elif n > 1e14:
        n /= 1e6
    elif n > 1e11:
        n /= 1e3
    try:
        return datetime.fromtimestamp(n, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def find_keep_root(export_root: Path) -> Optional[Path]:
    root = Path(export_root)
    for c in (root, root / "Keep", root / "Takeout" / "Keep"):
        if c.is_dir() and c.name == "Keep":
            return c
    if root.is_dir():
        for child in sorted(root.iterdir()):
            c = child / "Takeout" / "Keep"
            if c.is_dir():
                return c
    return None


def _load_note(path: Path, root: Path, export: KeepExport) -> Optional[KeepNote]:
    rel = path.name
    try:
        data = json.loads(path.read_bytes().decode("utf-8-sig"))
    except OSError as exc:
        export.errors.append(FileError(rel, "unreadable", type(exc).__name__))
        return None
    except (UnicodeDecodeError, ValueError) as exc:
        export.errors.append(FileError(rel, "bad_json", type(exc).__name__))
        return None
    if not isinstance(data, dict):
        export.errors.append(FileError(rel, "unexpected_shape", "not_object"))
        return None
    if data.get("isTrashed") is True:
        export.trashed_skipped += 1
        return None
    # A JSON in Keep/ that is not a note (no note field at all) is reported,
    # not silently treated as an empty note.
    note_fields = ("title",) + _TEXT_KEYS + _LIST_KEYS + _CREATED_KEYS
    if not any(k in data for k in note_fields):
        export.errors.append(FileError(rel, "unexpected_shape", "no_note_fields"))
        return None

    title = data.get("title") if isinstance(data.get("title"), str) else ""
    text = _first(data, _TEXT_KEYS)
    text = text if isinstance(text, str) else ""
    items: List[dict] = []
    raw_items = _first(data, _LIST_KEYS)
    if isinstance(raw_items, list):
        for it in raw_items:
            if isinstance(it, dict) and isinstance(it.get("text"), str):
                items.append({"text": it["text"], "checked": bool(it.get("isChecked") or it.get("checked"))})
    elif raw_items is not None:
        export.errors.append(FileError(rel, "unexpected_shape", "list_not_list"))
    labels = []
    for lb in data.get("labels") or []:
        if isinstance(lb, dict) and isinstance(lb.get("name"), str):
            labels.append(lb["name"])
        elif isinstance(lb, str):
            labels.append(lb)
    links = []
    for an in data.get("annotations") or []:
        if isinstance(an, dict) and isinstance(an.get("url"), str):
            links.append({"url": an["url"], "title": str(an.get("title") or "")})
    attachments = []
    for at in data.get("attachments") or []:
        if isinstance(at, dict):
            fp = str(at.get("filePath") or at.get("file") or "")
            attachments.append({"file": fp, "mimetype": str(at.get("mimetype") or ""),
                                "present": bool(fp) and (root / fp).exists()})
    sharees = []
    for sh in data.get("sharees") or []:
        if isinstance(sh, dict) and isinstance(sh.get("email"), str) and not sh.get("isOwner"):
            sharees.append(sh["email"].strip().lower())

    if not (title.strip() or text.strip() or items or links or attachments):
        export.empty_skipped += 1
        return None
    return KeepNote(
        source_file=path.name, title=title.strip(), text=text, items=items,
        labels=labels, links=links, attachments=attachments, sharees=sharees,
        created=_usec(_first(data, _CREATED_KEYS)),
        edited=_usec(_first(data, _EDITED_KEYS)),
        pinned=bool(data.get("isPinned")), archived=bool(data.get("isArchived")),
        color=str(data.get("color") or ""),
    )


def parse_export(export_root: Path) -> KeepExport:
    root = find_keep_root(Path(export_root))
    if root is None:
        raise FileNotFoundError("no Keep/ directory under the export")
    export = KeepExport(root=root)
    for path in sorted(root.glob("*.json")):
        note = _load_note(path, root, export)
        if note is not None:
            export.notes.append(note)
    return export


def _slug(value: str) -> str:
    v = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return v[:48].strip("-") or "note"


def _yaml_str(value: str) -> str:
    # JSON string literals are valid YAML double-quoted scalars, and escape
    # newlines, so a title cannot inject a frontmatter key.
    return json.dumps(value, ensure_ascii=False)


def render_markdown(note: KeepNote) -> str:
    fm = [
        "---",
        f"title: {_yaml_str(note.title or 'Untitled note')}",
        f"source: {SOURCE}",
        f"source_file: {_yaml_str(note.source_file)}",
        f"note_id: {note.note_id}",
        f"privacy_level: {PRIVACY_L2}",
    ]
    if note.created:
        fm.append(f"created: {note.created.isoformat()}")
    if note.edited:
        fm.append(f"updated: {note.edited.isoformat()}")
    if note.labels:
        fm.append("tags: [" + ", ".join(_yaml_str(x) for x in note.labels) + "]")
    if note.sharees:
        fm.append("shared_with: [" + ", ".join(_yaml_str(x) for x in note.sharees) + "]")
    if note.pinned:
        fm.append("pinned: true")
    if note.archived:
        fm.append("archived: true")
    fm.append("---")
    body: List[str] = [f"# {note.title or 'Untitled note'}", ""]
    if note.text.strip():
        body += [note.text.rstrip(), ""]
    for it in note.items:
        mark = "x" if it["checked"] else " "
        body.append(f"- [{mark}] {it['text'].strip()}")
    if note.items:
        body.append("")
    if note.links:
        body.append("## Links")
        for ln in note.links:
            body.append(f"- [{ln['title'] or ln['url']}]({ln['url']})")
        body.append("")
    if note.attachments:
        body.append("## Attachments")
        for at in note.attachments:
            state = "" if at["present"] else " (not in export)"
            body.append(f"- {at['file'] or 'unnamed'} {at['mimetype']}{state}".rstrip())
        body.append("")
    return "\n".join(fm) + "\n\n" + "\n".join(body).rstrip() + "\n"


def note_filename(note: KeepNote) -> str:
    return f"{_slug(note.title or Path(note.source_file).stem)}-{note.note_id}.md"


def write_markdown(export: KeepExport, out_dir: Path) -> dict:
    """Write one markdown file per note. Unchanged files are not rewritten."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    created = updated = unchanged = 0
    for note in export.notes:
        path = out_dir / note_filename(note)
        text = render_markdown(note)
        if path.exists():
            if path.read_text(encoding="utf-8") == text:
                unchanged += 1
                continue
            updated += 1
        else:
            created += 1
        tmp = path.with_suffix(".md.tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
    return {"notes_created": created, "notes_updated": updated, "notes_unchanged": unchanged}


def stats(export: KeepExport) -> dict:
    return {
        "notes": len(export.notes),
        "checklists": sum(1 for n in export.notes if n.items),
        "archived": sum(1 for n in export.notes if n.archived),
        "trashed_skipped": export.trashed_skipped,
        "empty_skipped": export.empty_skipped,
        "file_errors": len(export.errors),
    }


def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    import sys

    ap = argparse.ArgumentParser(prog="ostler-google-keep-takeout",
                                 description="Convert a Google Takeout 'Keep' export to markdown notes.")
    ap.add_argument("--export-path", type=Path, required=True)
    ap.add_argument("--output-dir", type=Path, default=None,
                    help="Markdown destination (default ~/.ostler/imports/keep/markdown).")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    result: dict = {"status": "ok", "errors": []}
    try:
        export = parse_export(args.export_path)
    except FileNotFoundError:
        print("google-keep-takeout: no Keep export found at that path", file=sys.stderr)
        result["status"] = "not_found"
        if args.json:
            print(json.dumps(result))
        return 0
    except Exception as exc:  # noqa: BLE001
        result["status"] = "error"
        result["errors"].append(type(exc).__name__)
        if args.json:
            print(json.dumps(result))
        return 1
    result.update(stats(export))
    result["file_error_list"] = [e.to_dict() for e in export.errors]
    for e in export.errors:
        print(f"google-keep-takeout: {e.path}: {e.reason}"
              + (f" ({e.detail})" if e.detail else ""), file=sys.stderr)
    out = args.output_dir or (Path.home() / ".ostler" / "imports" / "keep" / "markdown")
    try:
        result.update(write_markdown(export, out))
    except OSError as exc:
        result["status"] = "write_error"
        result["errors"].append(type(exc).__name__)
    if args.json:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
