"""iMessage TCC posture marker reader for Ostler Doctor.

Sibling of ``observability_posture.py`` -- where that module records
per-tick LaunchAgent health, this module *reads* a one-shot
install-time snapshot of macOS's AppleEvents permission state for
Messages.app.

Background
----------

macOS gates AppleEvents to Messages.app behind explicit consent
(System Settings > Privacy & Security > Automation). When the
operator has not authorised it, ``osascript`` delivery fails with
error -1743 (``errAEEventNotPermitted``) and conversations sent via
iMessage silently never leave the box. The cron-delivered morning
brief or pre-meeting brief just does not arrive; the customer has
no idea what is wrong.

Marker contract
---------------

Written by CM051 ``install.sh`` at install time (section 3.18 of
install.sh) and refreshed on every ``install.sh --repair`` run. The
file lives at ``~/.ostler/imessage-posture/state.md`` and is a
plain Markdown document, not JSON, because the operator may want to
read it directly with ``cat`` or ``less`` while debugging.

The first lines hold key-value pairs that this module parses::

    # iMessage TCC posture (install-time snapshot)

    Source: install.sh probe at install time
    Status: granted-and-working
    Captured at: 2026-05-26T12:34:56Z
    Probe: osascript "tell application \"Messages\" to count of accounts"
    Detection: exit-code + stderr regex (...)

    ...remainder is human prose describing the status and any
    remediation steps...

Recognised ``Status:`` values:

* ``granted-and-working`` -- Automation permission is granted; the
  probe succeeded. iMessage delivery should work.
* ``tcc-denied`` -- Automation permission was refused. iMessage
  delivery will silently fail (-1743). Operator must open System
  Settings > Privacy & Security > Automation and enable the
  Messages tick.
* ``check-failed`` -- The probe ran but returned an unrecognised
  result shape. ``stderr_fragment`` may carry a clue.

The Doctor surface renders a status row with status-appropriate
colour + a click-through ``<details>`` block carrying the full
remediation prose so the operator does not have to ``cat`` the
file separately.

**Doctor-side reader only**. The marker is *written* by install.sh;
this module never writes. The ostler-assistant daemon runs an
independent runtime probe and tracks ongoing health in its own
component table -- this snapshot is the install-time fact only.

Per the soft-fall-through convention that the rest of Doctor's
posture readers follow (``dashboard_components.py`` header
comment), a missing marker file is **not** an error: a fresh
install before install.sh has run, or an install where the
iMessage channel was not enabled, simply produces no Doctor row.
The rendering layer falls through to an empty section.

Schema versioning
-----------------

The marker is plain Markdown rather than versioned JSON. We tolerate
unknown lines, new lines, and reordered lines as long as the
``Status:`` line is parseable. Truly malformed input produces the
catch-all ``unknown`` status so Doctor still renders.
"""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Optional, TypedDict

logger = logging.getLogger(__name__)


class ImessageTccMarker(TypedDict, total=False):
    """Parsed shape of ``~/.ostler/imessage-posture/state.md``."""

    status: str
    captured_at: Optional[str]
    source: Optional[str]
    stderr_fragment: Optional[str]
    remediation: Optional[str]
    raw_text: str


# Status values written by install.sh. Anything else maps to "unknown"
# so Doctor still renders a row (silent absence is more dangerous
# than visible "I cannot tell").
_KNOWN_STATUSES = frozenset(
    {"granted-and-working", "tcc-denied", "check-failed"}
)


def _posture_path() -> Path:
    """Return ``~/.ostler/imessage-posture/state.md``.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments;
    defaults to ``~/.ostler/``.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    return base / "imessage-posture" / "state.md"


def read_imessage_tcc_posture() -> Optional[ImessageTccMarker]:
    """Read the install-time iMessage TCC posture marker.

    Returns:
        Parsed marker dict, or ``None`` when the marker file is
        absent, unreadable, or empty. Never raises -- Doctor must
        keep rendering even when the posture file is broken.
    """
    marker = _posture_path()
    if not marker.exists():
        return None
    try:
        raw = marker.read_text(encoding="utf-8")
    except OSError as exc:
        logger.warning(
            "Could not read iMessage TCC posture marker %s: %s", marker, exc,
        )
        return None
    if not raw.strip():
        return None
    return _parse_marker(raw)


def _parse_marker(raw: str) -> ImessageTccMarker:
    """Parse the raw marker text into a structured dict.

    The marker is plain Markdown written by ``install.sh``. We
    extract the ``Status:`` value, ``Captured at:`` timestamp,
    optional ``Source:`` line, and -- when present -- the
    ``## Remediation`` body block plus any fenced stderr fragment.
    Unknown lines are tolerated; the parser never raises.
    """
    out: ImessageTccMarker = {"raw_text": raw, "status": "unknown"}

    for line in raw.splitlines():
        m = re.match(r"^Status:\s*(\S.*?)\s*$", line)
        if m:
            value = m.group(1).strip()
            if value in _KNOWN_STATUSES:
                out["status"] = value
            else:
                out["status"] = "unknown"
            continue
        m = re.match(r"^Captured at:\s*(\S.*?)\s*$", line)
        if m:
            out["captured_at"] = m.group(1).strip()
            continue
        m = re.match(r"^Source:\s*(\S.*?)\s*$", line)
        if m:
            out["source"] = m.group(1).strip()
            continue

    # Remediation block (tcc-denied path in install.sh writes a
    # `## Remediation` heading). Capture body lines until the next
    # heading or end of file.
    remediation = _extract_section(raw, "Remediation")
    if remediation:
        out["remediation"] = remediation

    # Stderr fragment block (check-failed path writes a fenced
    # block under `## Status detail`). The fence is a generic
    # ```...``` so we capture only the content between the first
    # pair following the heading.
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
    ``## <heading_text>``. ``None`` if the heading or fence is
    absent.
    """
    section = _extract_section(raw, heading_text)
    if not section:
        return None
    m = re.search(r"```\s*\n(.*?)\n```", section, re.DOTALL)
    if not m:
        return None
    return m.group(1).strip() or None
