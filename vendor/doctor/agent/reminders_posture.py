"""Reminders (EventKit) permission posture marker reader for Ostler Doctor.

Sibling of ``imessage_tcc_posture.py`` -- where that module reads a
one-shot install-time snapshot of the macOS AppleEvents permission for
Messages.app, this module reads the equivalent snapshot of the macOS
**Reminders** permission (EventKit) that the commitment -> Reminders
writer depends on.

Background
----------

When Ostler turns an extracted commitment ("you owe Alice the deck by
Friday") into a macOS Reminder, it writes through EventKit. macOS gates
that behind explicit consent (System Settings > Privacy & Security >
Reminders). If the operator has not granted it, the EventKit write is
refused (``EKAuthorizationStatus.denied`` / ``.restricted``, or never
prompted: ``.notDetermined``) and the reminder silently never appears.
The customer asked Ostler to remember something for them, Ostler said it
would, and nothing happened -- with no visible error.

This is the exact failure class the iMessage TCC tile already surfaces
for delivery; this tile surfaces it for commitment -> Reminders writes.

Marker contract
---------------

Written by the install-time / setup probe (mirrors the iMessage marker
in CM051 ``install.sh``) and refreshed on each ``--repair`` run. The
file lives at ``~/.ostler/reminders-posture/state.md`` and is a plain
Markdown document, not JSON, so the operator can read it directly with
``cat`` or ``less`` while debugging.

The first lines hold key-value pairs that this module parses::

    # Reminders (EventKit) posture (install-time snapshot)

    Source: install.sh probe at install time
    Status: granted
    Captured at: 2026-05-26T12:34:56Z
    Probe: EventKit EKEventStore authorizationStatus(for: .reminder)

    ...remainder is human prose describing the status and any
    remediation steps...

Recognised ``Status:`` values (the EKAuthorizationStatus cases, plus a
probe-failed catch-all):

* ``granted`` -- Reminders access is authorised. Commitment ->
  Reminders writes should work.
* ``denied`` -- The operator refused Reminders access. Writes will
  silently fail until they grant it in System Settings.
* ``restricted`` -- Access is blocked by a profile / parental controls
  / MDM policy; the operator may not be able to grant it themselves.
* ``not-determined`` -- macOS has not yet prompted for Reminders
  access. The first write (or a re-run of the setup) will trigger the
  prompt.
* ``check-failed`` -- The probe ran but returned an unrecognised
  result shape. ``stderr_fragment`` may carry a clue.

**Doctor-side reader only**. The marker is *written* by the installer /
setup probe; this module never writes. Per the soft-fall-through
convention the rest of Doctor's posture readers follow, a missing marker
file is **not** an error -- a fresh install before the probe has run, or
an install where commitment capture is not enabled, simply produces no
Doctor row, and the rendering layer falls through to an empty section.

Schema versioning
-----------------

The marker is plain Markdown rather than versioned JSON. We tolerate
unknown lines, new lines, and reordered lines as long as the ``Status:``
line is parseable. Truly malformed input produces the catch-all
``unknown`` status so Doctor still renders.
"""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Optional, TypedDict

logger = logging.getLogger(__name__)


class RemindersMarker(TypedDict, total=False):
    """Parsed shape of ``~/.ostler/reminders-posture/state.md``."""

    status: str
    captured_at: Optional[str]
    source: Optional[str]
    stderr_fragment: Optional[str]
    remediation: Optional[str]
    raw_text: str


# Status values written by the EventKit probe. Anything else maps to
# "unknown" so Doctor still renders a row (silent absence is more
# dangerous than a visible "I cannot tell").
_KNOWN_STATUSES = frozenset(
    {"granted", "denied", "restricted", "not-determined", "check-failed"}
)


def _posture_path() -> Path:
    """Return ``~/.ostler/reminders-posture/state.md``.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments;
    defaults to ``~/.ostler/``.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    return base / "reminders-posture" / "state.md"


def read_reminders_posture() -> Optional[RemindersMarker]:
    """Read the install-time Reminders (EventKit) posture marker.

    Returns:
        Parsed marker dict, or ``None`` when the marker file is
        absent, unreadable, or empty. Never raises -- Doctor must keep
        rendering even when the posture file is broken.
    """
    marker = _posture_path()
    if not marker.exists():
        return None
    try:
        raw = marker.read_text(encoding="utf-8")
    except OSError as exc:
        logger.warning(
            "Could not read Reminders posture marker %s: %s", marker, exc,
        )
        return None
    if not raw.strip():
        return None
    return _parse_marker(raw)


def _parse_marker(raw: str) -> RemindersMarker:
    """Parse the raw marker text into a structured dict.

    Extracts the ``Status:`` value, ``Captured at:`` timestamp, optional
    ``Source:`` line, and -- when present -- the ``## Remediation`` body
    block plus any fenced stderr fragment under ``## Status detail``.
    Unknown lines are tolerated; the parser never raises.
    """
    out: RemindersMarker = {"raw_text": raw, "status": "unknown"}

    for line in raw.splitlines():
        m = re.match(r"^Status:\s*(\S.*?)\s*$", line)
        if m:
            value = m.group(1).strip()
            out["status"] = value if value in _KNOWN_STATUSES else "unknown"
            continue
        m = re.match(r"^Captured at:\s*(\S.*?)\s*$", line)
        if m:
            out["captured_at"] = m.group(1).strip()
            continue
        m = re.match(r"^Source:\s*(\S.*?)\s*$", line)
        if m:
            out["source"] = m.group(1).strip()
            continue

    remediation = _extract_section(raw, "Remediation")
    if remediation:
        out["remediation"] = remediation

    stderr_fragment = _extract_fenced_block_after(raw, "Status detail")
    if stderr_fragment:
        out["stderr_fragment"] = stderr_fragment

    return out


def _extract_section(raw: str, heading_text: str) -> Optional[str]:
    """Return the body under ``## <heading_text>`` up to the next
    heading or EOF. ``None`` if the heading is absent.
    """
    pattern = re.compile(
        rf"(?:^|\n)##\s+{re.escape(heading_text)}\s*\n(.*?)(?=\n##\s+|\Z)",
        re.DOTALL,
    )
    m = pattern.search(raw)
    if not m:
        return None
    body = m.group(1).strip()
    return body or None


def _extract_fenced_block_after(raw: str, heading_text: str) -> Optional[str]:
    """Return the content of the first ```-fenced block following
    ``## <heading_text>``. ``None`` if the heading or fence is absent.
    """
    section = _extract_section(raw, heading_text)
    if not section:
        return None
    m = re.search(r"```\s*\n(.*?)\n```", section, re.DOTALL)
    if not m:
        return None
    return m.group(1).strip() or None
