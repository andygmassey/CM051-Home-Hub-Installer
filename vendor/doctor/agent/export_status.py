"""Your data exports: per-platform import state for the Doctor.

The Downloads export watcher (install.sh, ostler-scan-exports) keeps one
high-water mark per platform in ``state/export-scan/high_water.tsv``:

    label<TAB>epoch<TAB>date_source

``epoch`` is the newest export date imported successfully for that platform
and ``date_source`` is ``name`` (the date is in the export's file name) or
``mtime`` (the newest file date inside the export). The writer is
``_es_mark_raise`` in install.sh; the contract test drives that real function
and reads its output through ``read_high_water`` here.

Three honest states, never blended:
  ok          the file parsed. A platform with no row is "Never imported".
  absent      no file yet: nothing has ever been imported on this Mac.
  unreadable  the file exists and could not be read or parsed. Every row says
              "couldn't check", because absence of a row is then unknown.

The platform list is ``export_platforms.tsv`` beside this module, the one table
shared with installer Q11 and checked by tests/test_export_platforms_match_q11.py.
"""

from __future__ import annotations

import html
import os
from datetime import datetime, timezone
from pathlib import Path

PLATFORMS_FILE = Path(__file__).resolve().with_name("export_platforms.tsv")
STALE_AFTER_DAYS = 90

NEVER = "Never imported"
UNCHECKED = "couldn't check"
ARRIVES_DEFAULT = "Arrives by email when it's ready."
HOW_IT_ARRIVES_TAIL = "Save it to Downloads and Ostler imports it automatically."
SOURCE_WORDS = {"name": "from the export's file name", "mtime": "from the file's date"}


def ostler_dir() -> Path:
    return Path(os.environ.get("OSTLER_DIR") or (Path.home() / ".ostler"))


def high_water_path() -> Path:
    return ostler_dir() / "state" / "export-scan" / "high_water.tsv"


def load_platforms(path: Path = PLATFORMS_FILE) -> list[dict]:
    """The shared table, one dict per platform, in file order."""
    rows = []
    lines = path.read_text(encoding="utf-8").splitlines()
    header = None
    for line in lines:
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        if header is None:
            header = cells
            continue
        if len(cells) != len(header):
            raise ValueError(f"export_platforms.tsv row has {len(cells)} cells, want {len(header)}")
        rows.append(dict(zip(header, cells)))
    return rows


def read_high_water(path: Path | None = None) -> dict:
    """Read the watcher's store. Never raises; returns a status dict.

    {"status": "ok"|"absent"|"unreadable", "marks": {label: (epoch, source)},
     "error": str|None}
    """
    p = path or high_water_path()
    if not p.exists():
        return {"status": "absent", "marks": {}, "error": None}
    marks: dict[str, tuple[int, str]] = {}
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return {"status": "unreadable", "marks": {}, "error": f"{type(exc).__name__}"}
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        cells = line.split("\t")
        if len(cells) != 3 or not cells[1].isdigit():
            return {"status": "unreadable", "marks": {},
                    "error": f"line {n} is not label, epoch, source"}
        marks[cells[0]] = (int(cells[1]), cells[2])  # last row wins, as the writer's awk does
    return {"status": "ok", "marks": marks, "error": None}


def collect_import_state() -> dict:
    """What the snapshot carries: the store read, once per Doctor tick."""
    return read_high_water()


def _date(epoch: int) -> str:
    d = datetime.fromtimestamp(epoch, tz=timezone.utc)
    return f"{d.day} {d.strftime('%b %Y')}"  # no %-d: BSD strftime does not take it


def _arrives(row: dict) -> str:
    wait = (row.get("wait_quote") or "").strip()
    head = f"Arrives by email {wait}." if wait else ARRIVES_DEFAULT
    return f"{head} {HOW_IT_ARRIVES_TAIL}"


def platform_rows(state: dict, platforms: list[dict] | None = None) -> list[dict]:
    """One row per platform: label, last import text, source words, link."""
    platforms = platforms if platforms is not None else load_platforms()
    rows = []
    for p in platforms:
        pid = p["id"]
        if state["status"] == "unreadable":
            last, source = UNCHECKED, ""
        elif pid in state["marks"]:
            epoch, src = state["marks"][pid]
            last, source = _date(epoch), SOURCE_WORDS.get(src, "")
        else:
            last, source = NEVER, ""
        rows.append({"id": pid, "display": p["display"], "last": last,
                     "source": source, "request_url": p["request_url"],
                     "arrives": _arrives(p)})
    return rows


def render_export_section(state: dict | None = None, platforms: list[dict] | None = None) -> str:
    """The "Your data exports" section. Separate from the always-on sources table."""
    state = state if state is not None else collect_import_state()
    rows = platform_rows(state, platforms)
    if state["status"] == "unreadable":
        intro = ("Doctor could not read its record of your data exports, so it cannot say "
                 "which exports have been imported. This is not the same as none having been "
                 "imported.")
    else:
        intro = ("The GDPR exports you can request from each platform, and when Ostler last "
                 "imported one. Request an export, save it to Downloads, and Ostler imports it.")
    body = []
    for r in rows:
        when = html.escape(r["last"])
        if r["source"]:
            when += f' <span class="muted" style="font-size:0.85em">({html.escape(r["source"])})</span>'
        body.append(
            "<tr>"
            f'<td>{html.escape(r["display"])}</td>'
            f"<td>{when}</td>"
            f'<td><a href="{html.escape(r["request_url"], quote=True)}" target="_blank" '
            f'rel="noopener noreferrer">Request your data</a></td>'
            f'<td class="muted">{html.escape(r["arrives"])}</td>'
            "</tr>"
        )
    return (
        '<div class="section"><h2>Your data exports</h2>'
        f'<p class="muted">{html.escape(intro)}</p>'
        '<table class="src-table" style="width:100%;border-collapse:collapse">'
        '<thead><tr><th align="left">Platform</th><th align="left">Last imported</th>'
        '<th align="left">Request</th><th align="left">How it arrives</th></tr></thead>'
        "<tbody>" + "".join(body) + "</tbody></table></div>"
    )


def stale_findings(state: dict, now: datetime | None = None,
                   platforms: list[dict] | None = None) -> list[dict]:
    """Findings for the age rule: one per platform imported over 90 days ago,
    and one if the store could not be read."""
    now = now or datetime.now(timezone.utc)
    if state["status"] == "unreadable":
        return [{
            "severity": "info",
            "title": "Doctor couldn't check your data exports",
            "detail": ("Doctor could not read its record of your GDPR exports, so it cannot "
                       "say when each was last imported. This is not a sign that anything is wrong "
                       "with your data."),
            "fix": "Send this report so we can fix the check",
            "fix_command": None,
            "risk": "low",
            "category": "configuration",
        }]
    findings = []
    by_id = {p["id"]: p for p in (platforms if platforms is not None else load_platforms())}
    for pid, (epoch, _src) in state["marks"].items():
        days = (now - datetime.fromtimestamp(epoch, tz=timezone.utc)).days
        if days <= STALE_AFTER_DAYS or pid not in by_id:
            continue
        p = by_id[pid]
        findings.append({
            "severity": "info",
            "title": f"Your {p['display']} export was last imported {days} days ago",
            "detail": ("A newer export may hold more recent contacts, messages or activity. "
                       f"Request one from {p['display']}: {p['request_url']}"),
            "fix": f"Request a new {p['display']} export",
            "fix_command": None,
            "risk": "low",
            "category": "configuration",
        })
    return findings
