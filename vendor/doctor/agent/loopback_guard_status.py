"""Local AI privacy guard (loopback guard) status for Ostler Doctor and the Hub.

v1.0.126, CM051 lib/ostler-loopback-guard.sh. The guard is a pf anchor plus a
root LaunchDaemon (com.ostler.loopback-guard) that refuses other macOS accounts
a connection to the local AI engine (:11434 and its runner ports). Every 300 s
the daemon re-applies the anchor, self-tests it, and writes a key=value status
file (root-owned, world-readable). This module only READS that file: Doctor is
not root and must never touch pf.

Three answers, never two:

* ``active``          verdict=ok and checked within ``STATUS_MAX_AGE_SECONDS``.
* ``not-active``      the daemon's own verdict is fail; ``reason`` says why.
* ``could-not-check`` no file, unreadable, garbled, unknown verdict or stale.
                      No current answer is not a pass.

``read_loopback_guard`` feeds the Doctor tile here and the ``privacy_guard``
field of ``/api/v1/box-status``, which the Hub reads through its existing
Doctor proxy.
"""
from __future__ import annotations

import html
import os
import time
from typing import Optional, TypedDict

STATUS_ACTIVE = "active"
STATUS_NOT_ACTIVE = "not-active"
STATUS_COULD_NOT_CHECK = "could-not-check"

DEFAULT_STATUS_FILE = "/Library/Application Support/Ostler/loopback-guard/status"
# The daemon writes every 300 s. Three missed ticks is no longer current.
STATUS_MAX_AGE_SECONDS = 900


class LoopbackGuardStatus(TypedDict, total=False):
    status: str
    reason: str
    checked_at: int
    assistant_uid: str


def _status_path() -> str:
    return os.environ.get("OSTLER_LG_STATUS_FILE") or DEFAULT_STATUS_FILE


def read_loopback_guard(now: Optional[float] = None) -> LoopbackGuardStatus:
    """Read the guard daemon's status file. Never raises, never probes."""
    path = _status_path()
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return {"status": STATUS_COULD_NOT_CHECK,
                "reason": "the privacy guard is not installed on this Mac"}
    except OSError as exc:
        return {"status": STATUS_COULD_NOT_CHECK,
                "reason": f"status unreadable ({type(exc).__name__})"}
    fields: dict = {}
    for line in lines:
        key, sep, value = line.partition("=")
        if sep:
            fields[key] = value  # last one wins, as the shell reader does
    try:
        checked_at = int(fields.get("checked_at", ""))
    except ValueError:
        return {"status": STATUS_COULD_NOT_CHECK, "reason": "status carries no time"}
    age = (time.time() if now is None else now) - checked_at
    if age > STATUS_MAX_AGE_SECONDS:
        return {"status": STATUS_COULD_NOT_CHECK,
                "reason": f"last checked {int(age // 60)} minutes ago", "checked_at": checked_at}
    if age < -300:
        return {"status": STATUS_COULD_NOT_CHECK, "reason": "status is dated in the future"}
    verdict = fields.get("verdict", "")
    if verdict == "ok":
        return {"status": STATUS_ACTIVE, "checked_at": checked_at,
                "assistant_uid": fields.get("assistant_uid", "none")}
    if verdict == "fail":
        return {"status": STATUS_NOT_ACTIVE, "checked_at": checked_at,
                "reason": fields.get("reason", "") or "no reason recorded"}
    return {"status": STATUS_COULD_NOT_CHECK,
            "reason": f"status has an unknown verdict ({verdict[:40]!r})"}


# ── Customer-facing copy (British English, light brand, no em dashes) ──
_SECTION_TITLE = "Local AI privacy guard"
_LABELS = {
    STATUS_ACTIVE: "On",
    STATUS_NOT_ACTIVE: "Off: other accounts on this Mac could reach the local AI engine",
    STATUS_COULD_NOT_CHECK: "Could not check the privacy guard",
}
_DETAILS = {
    STATUS_ACTIVE: (
        "Other user accounts on this Mac cannot connect to Ostler's local AI "
        "engine. It was last checked {minutes} minutes ago."
    ),
    STATUS_NOT_ACTIVE: (
        "The guard that keeps the local AI engine private to your account is "
        "not working ({reason}). Your own use of Ostler is unaffected."
    ),
    STATUS_COULD_NOT_CHECK: (
        "Ostler has no current answer about its privacy guard ({reason}), so "
        "this was not checked. It is not a pass."
    ),
}
_REMEDIATION = (
    "Run the Ostler installer again and approve the administrator prompt. "
    "It switches the guard back on without touching your data."
)
_COLOURS = {STATUS_ACTIVE: "#2C4A2C", STATUS_NOT_ACTIVE: "#7A1F1F", STATUS_COULD_NOT_CHECK: "#7A1F1F"}
_ICONS = {STATUS_ACTIVE: "&#10003;", STATUS_NOT_ACTIVE: "&#9888;", STATUS_COULD_NOT_CHECK: "&#9888;"}


def box_status_field(now: Optional[float] = None) -> dict:
    """The ``privacy_guard`` field of /api/v1/box-status (the Hub's feed)."""
    st = read_loopback_guard(now)
    return {"status": st.get("status"), "reason": st.get("reason", ""),
            "checked_at": st.get("checked_at")}


def render_loopback_guard_status(now: Optional[float] = None) -> str:
    st = read_loopback_guard(now)
    status = st.get("status", STATUS_COULD_NOT_CHECK)
    if status == STATUS_ACTIVE:
        minutes = int(max(0, (time.time() if now is None else now) - st.get("checked_at", 0)) // 60)
        detail = _DETAILS[status].format(minutes=minutes)
    else:
        detail = _DETAILS[status].format(reason=st.get("reason", ""))
    how_to_fix = ""
    if status != STATUS_ACTIVE:
        how_to_fix = (
            '\n                <details style="margin-top:8px">'
            '\n                    <summary style="cursor:pointer;font-size:12px">How to fix</summary>'
            f'\n                    <div class="status-detail">{html.escape(_REMEDIATION)}</div>'
            "\n                </details>"
        )
    return f"""
    <div class="section" id="loopbackGuardSection">
        <div class="section-title">{html.escape(_SECTION_TITLE)}</div>
        <div class="status-grid">
        <div class="status-card">
            <div class="status-indicator" style="background:{_COLOURS[status]}">{_ICONS[status]}</div>
            <div class="status-info">
                <div class="status-name">{html.escape(_LABELS[status])}</div>
                <div class="status-detail">{html.escape(detail)}</div>{how_to_fix}
            </div>
        </div>
        </div>
    </div>"""
