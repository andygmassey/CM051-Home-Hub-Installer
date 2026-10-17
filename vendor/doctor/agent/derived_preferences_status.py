""""What you like" status row for Ostler Doctor (smart-prefs).

Sibling of the "Where your data came from" table (``render_source_status`` in
web_ui.py). That table answers "did each source read in"; this answers the one
question it cannot: did the preference-derivation engine run, and did it leave
anything for the "What you like" page and the assistant to read.

Why a separate row and not a sentinel in the hydrate directory: the source
table reads install-time hydrate sentinels, one per source, and this is not a
source and not install-time. It is a recurring LaunchAgent
(``com.ostler.derive-preferences``, written by install.sh
``_install_derive_preferences_agent``) whose runner writes its own counts-only
record after every pass to ``~/.ostler/state/derived-preferences.json``.

Three facts, each read without a subprocess (the Doctor has a fork budget, see
box_status.py) and without a network call:

* scheduled  -- the agent's plist exists in ~/Library/LaunchAgents, and its
                StartInterval.
* last run   -- when, and what the runner concluded.
* node count -- ``pwg:DerivedPreference`` nodes in the derived named graph,
                COUNTED BY THE RUNNER against the store at the end of that run.
                Graph presence is not the signal: an empty run still leaves a
                present graph (its run marker), so only the count says whether
                there is anything to show.

States, each distinct, none folded into another:

* ``not_scheduled``  no agent. The page will stay empty for ever.
* ``not_run``        scheduled, no record yet (the first pass is up to one
                     interval after install).
* ``written``        ran and wrote N preferences.
* ``empty``          ran, every reader worked, nothing met the evidence floor.
                     Honest zero, not a fault.
* ``not_written``    ran and kept the previous graph (a reader or the store
                     failed, or validation refused the set).
* ``cannot_start``   the runner could not load its dependencies.
* ``unreadable``     a record exists and could not be parsed. "Could not
                     check", never "nothing".

Never reads or shows a preference value: the record holds counts only.
Vendor-only (no HR015 equivalent: HR015 Doctor runs as a service with no
installer LaunchAgents to report on); see vendor/VENDOR_ONLY.tsv.
"""
from __future__ import annotations

import html
import json
import os
import plistlib
from pathlib import Path

LABEL = "com.ostler.derive-preferences"


def _ostler_dir() -> Path:
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    return Path(base) if base else Path.home() / ".ostler"


def status_path() -> Path:
    return _ostler_dir() / "state" / "derived-preferences.json"


def plist_path() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def read_derived_preferences_status(
    status_file: Path | None = None, plist_file: Path | None = None
) -> dict:
    """Counts-only status. Never raises."""
    status_file = status_file or status_path()
    plist_file = plist_file or plist_path()

    out: dict = {
        "scheduled": plist_file.is_file(),
        "interval_s": None,
        "status": "not_scheduled",
        "last_run_at": None,
        "node_count": None,
        "reason": "",
    }
    if out["scheduled"]:
        try:
            with plist_file.open("rb") as fh:
                iv = plistlib.load(fh).get("StartInterval")
            out["interval_s"] = int(iv) if iv is not None else None
        except Exception:  # noqa: BLE001 - interval is decoration
            pass

    if not status_file.is_file():
        if out["scheduled"]:
            out["status"] = "not_run"
        return out

    try:
        rec = json.loads(status_file.read_text(encoding="utf-8"))
        if not isinstance(rec, dict):
            raise ValueError("record is not an object")
    except Exception as exc:  # noqa: BLE001
        out["status"] = "unreadable"
        out["reason"] = f"{type(exc).__name__}"
        return out

    outcome = str(rec.get("outcome") or "")
    out["status"] = outcome if outcome in {
        "written", "empty", "not_written", "cannot_start", "failed"} else "unreadable"
    if out["status"] == "failed":
        out["status"] = "not_written"
    out["last_run_at"] = rec.get("last_run_at")
    n = rec.get("graph_node_count")
    out["node_count"] = int(n) if isinstance(n, int) else None
    out["reason"] = str(rec.get("reason") or "")
    if not out["scheduled"]:
        # A record from an earlier install with no agent now: nothing will
        # refresh it, so "up to date" would be a lie. Keep its count and time.
        out["status"] = "not_scheduled"
        out["reason"] = ""
    return out


_WORDS = {
    "not_scheduled": "not scheduled",
    "not_run": "not run yet",
    "written": "up to date",
    "empty": "ran, nothing to show yet",
    "not_written": "last run did not update",
    "cannot_start": "could not start",
    "unreadable": "record unreadable",
}
_COLOUR = {
    "written": "#2C4A2C",
    "empty": "rgba(236,232,225,0.55)",
    "not_run": "#5C4611",
    "not_scheduled": "#7A1F1F",
    "not_written": "#5C4611",
    "cannot_start": "#7A1F1F",
    "unreadable": "#7A1F1F",
}
_EXPLAIN = {
    "not_scheduled": "Nothing is set up to work out what you like, so the What "
                     "you like page will stay empty. Re-running the installer "
                     "sets it up.",
    "not_run": "It runs every few hours; the first pass has not happened yet.",
    "empty": "It ran and found too little to go on. Tastes need a few films "
             "with genre or director detail, which comes from the public "
             "look-ups you can turn on in setup.",
    "not_written": "The previous results were kept.",
    "cannot_start": "Re-running the installer reinstalls what it needs.",
}


def _every(interval_s) -> str:
    if not interval_s:
        return ""
    h = interval_s / 3600
    return f"every {h:g} hour{'s' if h != 1 else ''}" if h >= 1 else f"every {interval_s // 60} min"


def render_derived_preferences_status(status: dict | None = None) -> str:
    try:
        st = status if status is not None else read_derived_preferences_status()
    except Exception as exc:  # noqa: BLE001
        return ('<div class="section"><h2>What you like</h2>'
                f'<p class="muted">Could not read the status: {html.escape(type(exc).__name__)}. '
                "That is not the same as nothing having been worked out.</p></div>")
    key = st.get("status") or "unreadable"
    n = st.get("node_count")
    count = "&mdash;" if n is None or key in {"not_run", "unreadable"} else str(n)
    when = st.get("last_run_at")
    sched = "yes" if st.get("scheduled") else "no"
    every = _every(st.get("interval_s"))
    detail = st.get("reason") or _EXPLAIN.get(key, "")
    return (
        '<div class="section"><h2>What you like</h2>'
        '<p class="muted">Tastes Ostler works out from your saved preferences, '
        "on this Mac. Whether it is set up, when it last ran and how many it "
        "found.</p>"
        '<table class="src-table" style="width:100%;border-collapse:collapse">'
        '<thead><tr><th align="left">Scheduled</th><th align="left">Status</th>'
        '<th align="right">Tastes</th><th align="left">Last run</th></tr></thead><tbody>'
        "<tr>"
        f"<td>{html.escape(sched)}{(' (' + html.escape(every) + ')') if every else ''}</td>"
        f'<td><span style="color:{_COLOUR.get(key, "#5C4611")}">'
        f"{html.escape(_WORDS.get(key, key))}</span>"
        + (f'<div class="muted" style="font-size:0.85em">{html.escape(detail)}</div>' if detail else "")
        + "</td>"
        f'<td style="text-align:right">{count}</td>'
        f"<td>{html.escape(str(when)) if when else 'never'}</td>"
        "</tr></tbody></table></div>"
    )
