"""Ostler Pro sources in the Doctor's "Where your data came from" table.

Andy, 2026-10-19: "Need to make sure it's obvious to the user that there are
other things if they upgrade to Pro." All new-data ingestion is Pro (Andy's
locked model, reaffirmed 19 Oct), so every connector is Pro, Instagram and
Telegram included. Connectors are always LISTED, never hidden, with a small
Pro badge, and say what they do. Spec:
~/walkdriver/PRO_DISCOVERABILITY_SPEC_2026-10-19.md

ONLY SHIPPED CONNECTORS GET A ROW. ``SHIPPED_PRO_CONNECTORS`` is the
availability flag and is EMPTY today: every connector importer is unwired, and
a row for a source the customer cannot connect is a roadmap leak. The PR that
wires a connector (connect sheet + its entry-point G7 gate) adds its id here,
and that PR's walk must show the row. With the set empty this module renders
nothing and forks nothing.

ENTITLEMENT IS NOT RE-DERIVED HERE. The single authority is
``ostler_fda/subscription_gate.py`` (the Apple receipt, walked through active,
grace and inactive). Its subprocess contract is ``--check``: exit 0 active or
grace, exit 3 paused, anything else fail-open. The Doctor is staged into its
own directory and cannot import it, so it asks the same question the
importers ask, the same way. A missing helper, a timeout or an unknown exit is
"unknown" and the row says "Could not check your Pro status", never "locked"
and never "paused": a check that could not run has not answered.

Pure apart from ``resolve_entitlement``; ``pro_source_rows`` takes the
entitlement as an argument so tests drive every state.
"""

from __future__ import annotations

import html
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

# (id, display name, one concrete example). Order is the table order.
PRO_CONNECTORS: tuple = (
    ("instagram", "Instagram",
     "Find what a friend sent you last spring: Ostler reads your Instagram messages."),
    ("telegram", "Telegram",
     "Pick up where a group chat left off: Ostler reads your Telegram chats."),
    ("jira", "Jira", "Ask why a feature was parked: Ostler reads your Jira history."),
    ("confluence", "Confluence",
     "Find the page where a decision was written down: Ostler reads your Confluence spaces."),
    ("slack", "Slack",
     "Ask what the team decided about the launch date: Ostler reads your Slack history."),
    ("google_chat", "Google Chat",
     "Pick up a thread you left last month: Ostler reads your Google Chat history."),
    ("linear", "Linear", "Ask what is still open on a project: Ostler reads your Linear issues."),
    ("github", "GitHub",
     "Ask why a change was made: Ostler reads the issues and reviews you took part in."),
    ("notion", "Notion", "Ask anything in your notes and docs: Ostler reads your Notion workspace."),
)

# THE AVAILABILITY FLAG. Empty until a connector is wired and walked.
SHIPPED_PRO_CONNECTORS: frozenset = frozenset()

# Sources with an export FILE import. Andy, 19 Oct: the first import of each
# is free, with or without Pro; later imports and all ongoing sync are Pro.
# Confluence, Linear and GitHub are token sync only, so nothing is free there.
EXPORT_IMPORT_SOURCES: frozenset = frozenset(
    {"instagram", "telegram", "jira", "slack", "google_chat", "notion"})

# ── SHARED COPY, VERBATIM (Andy, 19 Oct; CONNECTORS_BUILD_BRIEF bottom) ──
# The same words in the Doctor, installer, CLI and iOS. Do not reword here.
PRE_IMPORT_NOTE = ("Your first import from each app is free. To bring in newer history "
                   "later, or keep {source} up to date automatically, you'll need Ostler Pro.")
SECOND_IMPORT_REFUSAL = ("You've already imported your {source} history once, free. Bringing "
                         "in newer exports, and keeping {source} up to date automatically, is "
                         "part of Ostler Pro.")
STAYS_SEARCHABLE = "Everything you've already imported stays here, and you can still search it."
# Token-only sources have no free import, so the refusal's first clause would
# be false there. This is its second clause on its own; Archie to confirm.
SYNC_IS_PRO = "Keeping {source} up to date automatically is part of Ostler Pro."

ENT_ACTIVE = "active"     # Pro, or inside the post-lapse grace window
ENT_PAUSED = "paused"     # gate says paused: lapsed past grace, or never had Pro
ENT_UNKNOWN = "unknown"   # could not ask

# The Mac cannot sell Pro (App Store subscription, bought in the iOS app), so
# the [Upgrade to Pro] button becomes this line on the Mac.
UPGRADE_LINE = "Upgrade to Pro in the Ostler app on your iPhone."

# install.sh stages ostler_fda into ${OSTLER_DIR}/fda-module (install.sh:9085).
_DEFAULT_GATE = Path.home() / ".ostler" / "fda-module" / "ostler_fda" / "subscription_gate.py"

_CACHE_SECONDS = 60.0
_cache: dict = {"at": None, "value": None}


def resolve_entitlement(gate_path: Optional[Path] = None,
                        runner: Callable = subprocess.run,
                        clock: Callable[[], float] = time.monotonic) -> str:
    """Ask the G7 gate. Cached for a minute (the Doctor polls; see the fork
    budget in box_status.py). Never raises."""
    now = clock()
    if _cache["at"] is not None and now - _cache["at"] < _CACHE_SECONDS:
        return _cache["value"]
    path = Path(gate_path) if gate_path else Path(
        os.environ.get("OSTLER_SUBSCRIPTION_GATE", str(_DEFAULT_GATE)))
    value = ENT_UNKNOWN
    if path.is_file():
        try:
            rc = runner([sys.executable, str(path), "--check"],
                        capture_output=True, timeout=10).returncode
            value = {0: ENT_ACTIVE, 3: ENT_PAUSED}.get(rc, ENT_UNKNOWN)
        except Exception:  # noqa: BLE001  timeout, exec failure: not an answer
            value = ENT_UNKNOWN
    if value != ENT_UNKNOWN:
        # Only a real answer is cached; "could not ask" is asked again on
        # the next load, so Try again means it.
        _cache["at"], _cache["value"] = now, value
    return value


def pro_source_rows(entitlement: str, shipped: frozenset = SHIPPED_PRO_CONNECTORS,
                    connected: frozenset = frozenset()) -> list:
    """One row per SHIPPED Pro connector that is not already in the ordinary
    table. ``connected``: ids that already have their own sentinel row, which
    then wins (a connected source is just a source; see ``lapsed_row``).

    Row: {source, name, state, line, detail, retry}. States:
      try_free       no Pro, export source: what it does + the pre-import note
      locked         no Pro, token-only source: what it does + sync is Pro
      not_connected  Pro, nothing set up yet
      unknown        could not ask the gate: never shown as refused; Try again
    """
    rows = []
    for cid, name, example in PRO_CONNECTORS:
        if cid not in shipped or cid in connected:
            continue
        retry = False
        if entitlement == ENT_ACTIVE:
            state, line, detail = "not_connected", "Not connected yet", ""
        elif entitlement == ENT_PAUSED:
            if cid in EXPORT_IMPORT_SOURCES:
                state, line, detail = "try_free", example, PRE_IMPORT_NOTE.format(source=name)
            else:
                state, line = "locked", example
                detail = f"{SYNC_IS_PRO.format(source=name)} {UPGRADE_LINE}"
        else:
            state, line, detail, retry = "unknown", "Could not check your Pro status", "", True
        rows.append({"source": cid, "name": name, "state": state,
                     "line": line, "detail": detail, "retry": retry})
    return rows


def lapsed_row(source: str, name: str) -> dict:
    """A source that HAS imported, seen without Pro (lapsed, or a second
    import refused). Used by the wiring PR on the source's own row."""
    if source in EXPORT_IMPORT_SOURCES:
        line = SECOND_IMPORT_REFUSAL.format(source=name)
    else:
        line = SYNC_IS_PRO.format(source=name)
    return {"source": source, "name": name, "state": "paused", "line": line,
            "detail": f"{STAYS_SEARCHABLE} {UPGRADE_LINE}", "retry": False}


_BADGE = ('<span class="pro-badge" style="display:inline-block;margin-left:6px;'
          'padding:0 5px;border:1px solid var(--ostler-accent, #7A1F1F);border-radius:4px;'
          'font-size:11px;line-height:16px;color:var(--ostler-accent, #7A1F1F)">Pro</span>')


def render_pro_rows_html(rows: list, columns: int = 6) -> str:
    """<tr> rows for the Doctor table. Muted, no colour fill, no icon."""
    out = []
    for r in rows:
        detail = (f'<div class="muted" style="font-size:0.85em">{html.escape(r["detail"])}</div>'
                  if r.get("detail") else "")
        if r.get("retry"):
            # An empty href reloads the page, which asks the gate again
            # (unknown answers are not cached).
            detail += '<div style="font-size:0.85em"><a href="">Try again</a></div>'
        out.append(
            "<tr>"
            f'<td style="white-space:nowrap">{html.escape(r["name"])}{_BADGE}</td>'
            f'<td colspan="{columns - 1}"><span class="muted">{html.escape(r["line"])}</span>{detail}</td>'
            "</tr>"
        )
    return "".join(out)
