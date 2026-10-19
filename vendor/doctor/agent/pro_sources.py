"""Ostler Pro sources in the Doctor's "Where your data came from" table.

Andy, 2026-10-19: "Need to make sure it's obvious to the user that there are
other things if they upgrade to Pro." Pro connectors (Jira, Confluence, Slack,
Google Chat, Linear, GitHub, Notion) are always LISTED, never hidden, with a
small Pro badge, and say what they do. Spec:
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

ENT_ACTIVE = "active"     # Pro, or inside the post-lapse grace window
ENT_PAUSED = "paused"     # gate says paused: lapsed past grace, or never had Pro
ENT_UNKNOWN = "unknown"   # could not ask

UPGRADE_LINE = "Upgrade in the Ostler app on your iPhone."

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
    _cache["at"], _cache["value"] = now, value
    return value


def pro_source_rows(entitlement: str, shipped: frozenset = SHIPPED_PRO_CONNECTORS,
                    connected: frozenset = frozenset()) -> list:
    """One row per SHIPPED Pro connector that is not already in the ordinary
    table. ``connected``: ids that already have their own sentinel row, which
    then wins (a connected source is just a source).

    Row: {source, name, state, line, detail}. States:
      locked       no Pro: what it does, and where to upgrade
      not_connected  Pro, nothing set up yet
      paused       had it, Pro ended: data stays, renew to keep syncing
      unknown      could not ask the gate
    """
    rows = []
    for cid, name, example in PRO_CONNECTORS:
        if cid not in shipped or cid in connected:
            continue
        if entitlement == ENT_ACTIVE:
            state, line, detail = "not_connected", "Not connected yet", ""
        elif entitlement == ENT_PAUSED:
            # The gate cannot tell "never had Pro" from "Pro ended" by exit
            # code alone, so the row says both halves plainly and stays true
            # for either: nothing is deleted, and Pro is what syncs it.
            state, line, detail = "locked", "Part of Ostler Pro", f"{example} {UPGRADE_LINE}"
        else:
            state, line, detail = "unknown", "Could not check your Pro status", ""
        rows.append({"source": cid, "name": name, "state": state,
                     "line": line, "detail": detail})
    return rows


def paused_row(name: str) -> dict:
    """A CONNECTED Pro source after Pro ends. Used by the wiring PR, where the
    sentinel row exists and the gate reports paused."""
    return {"name": name, "state": "paused", "line": "Paused",
            "detail": "What Ostler already read stays readable. Renew to keep syncing."}


_BADGE = ('<span class="pro-badge" style="display:inline-block;margin-left:6px;'
          'padding:0 5px;border:1px solid #7A1F1F;border-radius:4px;'
          'font-size:11px;line-height:16px;color:#7A1F1F">Pro</span>')


def render_pro_rows_html(rows: list, columns: int = 6) -> str:
    """<tr> rows for the Doctor table. Muted, no colour fill, no icon."""
    out = []
    for r in rows:
        detail = (f'<div class="muted" style="font-size:0.85em">{html.escape(r["detail"])}</div>'
                  if r.get("detail") else "")
        out.append(
            "<tr>"
            f'<td>{html.escape(r["name"])}{_BADGE}</td>'
            f'<td colspan="{columns - 1}"><span class="muted">{html.escape(r["line"])}</span>{detail}</td>'
            "</tr>"
        )
    return "".join(out)
