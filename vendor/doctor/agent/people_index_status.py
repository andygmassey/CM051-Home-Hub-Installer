"""People search status row for Ostler Doctor (v1.0.126, item h).

The people search index (the Qdrant ``people`` collection behind the People
tab, the Hub People card and people search) is filled by the people sweep, the
last step of the hourly com.ostler.fda-rerun tick
(``ostler_fda.pwg_ingest.ingest_people_to_qdrant``). The sweep writes a
counts-only record to ``~/.ostler/state/people-index.json`` as it goes: how
many people it knows, how many still have no current vector (the backlog), and
the backlog at the end of each of its last few passes.

v1.0.125 walk: on a first-run box the backlog grew 240 -> 1789 in 70 minutes
and nothing customer-facing said so. This row says it.

States, each distinct, none folded into another:

* ``not_run``         no record yet (the first pass has not reached this step).
* ``searchable``      backlog 0: everyone the graph holds can be found.
* ``catching_up``     backlog > 0 (amber): "Making N people searchable".
* ``falling_behind``  the end-of-pass backlog GREW on each of the last three
                      passes in a row (red). Catching up on a big first import
                      shrinks it pass by pass; three rises in a row means the
                      index is not keeping up and will not on its own.
* ``could_not_check`` the sweep could not read the graph or the stored points
                      on its latest pass (amber), so it does not know.
* ``unreadable``      a record exists and could not be parsed. "Could not
                      check", never a number.

Counts only: the record never holds a name. Vendor-only (no HR015
equivalent: the record is written by the vendored ostler_fda sweep); see
vendor/VENDOR_ONLY.tsv.
"""
from __future__ import annotations

import html
import json
import os
from pathlib import Path

GREEN = "#2C4A2C"
AMBER = "#5C4611"
RED = "#7A1F1F"

# How many end-of-pass rises in a row make the row red.
GROWTH_PASSES_FOR_RED = 3


def _ostler_dir() -> Path:
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    return Path(base) if base else Path.home() / ".ostler"


def status_path() -> Path:
    explicit = os.environ.get("OSTLER_PEOPLE_INDEX_STATE")
    return Path(explicit) if explicit else _ostler_dir() / "state" / "people-index.json"


def _int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _grew_each_of_last(history: list, n: int) -> bool:
    backlogs = [_int(h.get("backlog")) for h in history if isinstance(h, dict)]
    if len(backlogs) < n + 1 or any(b is None for b in backlogs[-(n + 1):]):
        return False
    tail = backlogs[-(n + 1):]
    return all(tail[i] < tail[i + 1] for i in range(n))


def read_people_index_status(status_file: Path | None = None) -> dict:
    """Counts-only status. Never raises."""
    status_file = status_file or status_path()
    out = {"status": "not_run", "backlog": None, "total": None,
           "updated_at": None, "phase": None}
    if not status_file.is_file():
        return out
    try:
        rec = json.loads(status_file.read_text(encoding="utf-8"))
        if not isinstance(rec, dict):
            raise ValueError("record is not an object")
    except Exception:  # noqa: BLE001
        out["status"] = "unreadable"
        return out
    out["backlog"] = _int(rec.get("backlog"))
    out["total"] = _int(rec.get("total"))
    out["updated_at"] = rec.get("updated_at")
    out["phase"] = rec.get("phase")
    history = rec.get("history") if isinstance(rec.get("history"), list) else []
    if _grew_each_of_last(history, GROWTH_PASSES_FOR_RED):
        out["status"] = "falling_behind"
        last = _int(history[-1].get("backlog")) if isinstance(history[-1], dict) else None
        if out["backlog"] is None:
            out["backlog"] = last
    elif out["backlog"] is None:
        out["status"] = "could_not_check"
    elif out["backlog"] > 0:
        out["status"] = "catching_up"
    else:
        out["status"] = "searchable"
    return out


_COLOUR = {
    "not_run": AMBER,
    "searchable": GREEN,
    "catching_up": AMBER,
    "falling_behind": RED,
    "could_not_check": AMBER,
    "unreadable": AMBER,
}


def _people(n: int) -> str:
    return "{:,} {}".format(n, "person" if n == 1 else "people")


def _words(st: dict) -> tuple[str, str]:
    key = st.get("status")
    backlog, total = st.get("backlog"), st.get("total")
    if key == "searchable":
        return (f"All {_people(total or 0)} are searchable", "")
    if key == "catching_up":
        return (f"Making {_people(backlog)} searchable",
                "New people become searchable a few hundred at a time. "
                "This finishes on its own.")
    if key == "falling_behind":
        return (f"{_people(backlog or 0)} not yet searchable, and the number is growing",
                "This has grown on each of the last three hourly checks, so it "
                "is not keeping up on its own.")
    if key == "not_run":
        return ("Not checked yet", "The first check runs within an hour of setup.")
    if key == "could_not_check":
        return ("Could not check how many people are searchable",
                "The last check could not read your people. It tries again every hour.")
    return ("Could not check how many people are searchable",
            "The record of the last check could not be read.")


def render_people_index_status(status: dict | None = None) -> str:
    try:
        st = status if status is not None else read_people_index_status()
    except Exception as exc:  # noqa: BLE001
        return ('<div class="section"><h2>People search</h2>'
                f'<p class="muted">Could not check: {html.escape(type(exc).__name__)}. '
                "That is not the same as everyone being searchable.</p></div>")
    key = st.get("status") or "unreadable"
    line, detail = _words(st)
    when = st.get("updated_at")
    return (
        '<div class="section"><h2>People search</h2>'
        '<p class="muted">Whether everyone Ostler knows can be found in People '
        "and search on this Mac.</p>"
        '<table class="src-table" style="width:100%;border-collapse:collapse">'
        '<thead><tr><th align="left">Status</th><th align="left">Last checked</th>'
        "</tr></thead><tbody><tr>"
        f'<td><span style="color:{_COLOUR.get(key, AMBER)}">{html.escape(line)}</span>'
        + (f'<div class="muted" style="font-size:0.85em">{html.escape(detail)}</div>' if detail else "")
        + "</td>"
        f"<td>{html.escape(str(when)) if when else 'never'}</td>"
        "</tr></tbody></table></div>"
    )
