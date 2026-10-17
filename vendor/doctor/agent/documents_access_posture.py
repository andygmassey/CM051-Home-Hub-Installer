"""Documents-folder access posture probe + tile for Ostler Doctor.

Sibling of ``imessage_tcc_posture.py`` and ``reminders_posture.py``.
Where those READ an install-time marker that install.sh wrote, this
module runs a LIVE write probe at Doctor render time against the
user-facing content root (``~/Documents/Ostler``).

Why a live probe rather than an install-time marker
---------------------------------------------------

Ostler's bundled interpreter writes the customer's personal wiki and
their conversation records under ``~/Documents/Ostler``. macOS gates
writes into the Documents folder behind the Files and Folders consent
category (System Settings > Privacy and Security > Files and Folders).
On install the operator meets a bare macOS prompt -- it can read as
coming from ``python3.11``, the bundled helper -- asking to access the
Documents folder. A careful customer who declines an unexplained
prompt leaves Ostler unable to write their wiki or save their
conversation records, and catch-up plus wiki writes then fail
silently with no visible error.

install.sh now pre-explains that prompt before it appears (the
Documents pre-explain, section 7 of install.sh). This module is the
other half: it surfaces the state in Doctor so a denial is never
silent. A live probe is used because the permission can be granted at
install and revoked later, which an install-time snapshot cannot
catch -- the same reason the Reminders tile has a runtime half beside
its install-time one.

Four states, each distinct
---------------------------

* ``granted-and-working`` -- the content root exists and a probe write
  into it succeeds. Ostler is saving the wiki and conversation records.
* ``documents-denied`` -- a probe write is refused with a permission
  error (``EPERM`` / ``EACCES``). macOS is blocking Ostler from the
  Documents folder; the wiki and conversation records cannot be
  written. This is the state the customer must act on.
* ``not-yet-asked`` -- the content root does not exist yet but its
  parent (``~/Documents``) accepts a probe write. install.sh has not
  reached its first Documents write, so no decision has been made.
  Deliberately NOT a denial: reporting denial here would cry wolf on a
  fresh box.
* ``check-failed`` -- the probe hit a non-permission error (a full
  disk, a read-only volume, a missing parent). Reported honestly as
  "could not check" rather than folded into pass or fail.

**Doctor-side only, and it never creates the content root.** When the
root is absent the probe writes into the PARENT, so this background
reader cannot itself trigger the very macOS prompt install.sh exists
to pre-explain. The probe file is uniquely named, written with
``O_EXCL``, and removed immediately.
"""
from __future__ import annotations

import errno
import html
import logging
import os
from pathlib import Path
from typing import Callable, Optional, TypedDict

logger = logging.getLogger(__name__)

# Status values. Distinct constants so a caller can branch on the exact
# state; a two-state (ok / not-ok) predicate would read "not yet asked"
# as a failure on every fresh box.
STATUS_WORKING = "granted-and-working"
STATUS_DENIED = "documents-denied"
STATUS_NOT_ASKED = "not-yet-asked"
STATUS_CHECK_FAILED = "check-failed"

# Probe files are hidden and PID-stamped so two concurrent Doctor polls
# never collide on the same name.
_PROBE_PREFIX = ".ostler-doctor-access-probe-"


class DocumentsAccessMarker(TypedDict, total=False):
    """Result of a single live probe."""

    status: str
    docs_root: str
    probed_path: str
    errno: Optional[int]


def _documents_root() -> Path:
    """Return ``~/Documents/Ostler``.

    Honours ``OSTLER_DOCUMENTS_DIR`` for tests and non-default
    deployments, matching the override install.sh reads for the same
    tree (``OSTLER_WIKI_DIR`` / ``OSTLER_CONVERSATIONS_DIR`` hang off
    this root).
    """
    override = os.environ.get("OSTLER_DOCUMENTS_DIR")
    if override:
        return Path(override)
    return Path(os.path.expanduser("~/Documents/Ostler"))


def _default_write_probe(directory: Path) -> None:
    """Write-and-remove a tiny probe file in ``directory``.

    Raises ``OSError`` (``PermissionError`` is a subclass) when the
    write is refused -- which is exactly what a macOS TCC denial of the
    Documents folder produces (``EPERM``), and what a ``chmod 000``
    directory produces (``EACCES``). ``O_EXCL`` keeps the attempt a
    genuine create so the permission check actually runs.
    """
    probe = Path(directory) / (_PROBE_PREFIX + str(os.getpid()))
    fd = os.open(str(probe), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, b"ostler documents access probe\n")
    finally:
        os.close(fd)
    # Best-effort cleanup; the WRITE is what we measured, so a failed
    # unlink does not change the verdict.
    try:
        os.unlink(str(probe))
    except OSError:
        pass


def probe_documents_access(
    docs_root: Optional[os.PathLike] = None,
    *,
    _write_probe: Optional[Callable[[Path], None]] = None,
) -> DocumentsAccessMarker:
    """Live-probe whether Ostler can write to the Documents content root.

    Args:
        docs_root: content root to probe. Defaults to
            ``~/Documents/Ostler`` (or ``OSTLER_DOCUMENTS_DIR``).
        _write_probe: injectable write function, for tests. Defaults to
            a real create-write-remove. Never raises out of this
            function; a broken probe is reported as ``check-failed``.

    Returns:
        A :class:`DocumentsAccessMarker`. Never raises -- Doctor must
        keep rendering even when the probe itself is broken.
    """
    root = Path(docs_root) if docs_root is not None else _documents_root()
    write_probe = _write_probe or _default_write_probe

    marker: DocumentsAccessMarker = {"docs_root": str(root)}

    root_exists = root.exists()
    # When the root is absent we probe the PARENT, never create the
    # root: creating it is install.sh's job (behind its pre-explain),
    # and doing it from this background reader would fire the macOS
    # prompt we are here to keep from being a surprise.
    target = root if root_exists else root.parent
    marker["probed_path"] = str(target)

    try:
        write_probe(target)
    except PermissionError as exc:
        marker["status"] = STATUS_DENIED
        marker["errno"] = getattr(exc, "errno", None)
        return marker
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EPERM):
            marker["status"] = STATUS_DENIED
        else:
            # A full disk, a read-only volume or a missing parent is not
            # a permission refusal. Say "could not check", do not claim
            # a denial we did not measure.
            marker["status"] = STATUS_CHECK_FAILED
        marker["errno"] = exc.errno
        return marker

    marker["status"] = STATUS_WORKING if root_exists else STATUS_NOT_ASKED
    return marker


# ── Customer-facing copy ───────────────────────────────────────────
# Co-located with the reader (rather than in web_ui_copy.py) because
# this whole tile is CM051-only: it probes ~/Documents/Ostler, the
# customer content layout the installer creates, which upstream HR015
# Doctor -- running as a service -- has no equivalent of. British
# English, light brand, no em dashes. "python3.11" is named on purpose:
# it is the literal, otherwise unexplained string the customer meets in
# the macOS prompt, so naming it is what makes the row actionable.
_SECTION_TITLE = "Your Documents folder"

_STATUS_LABELS = {
    STATUS_WORKING: "Working",
    STATUS_DENIED: "Ostler cannot write to your Documents folder",
    STATUS_CHECK_FAILED: "Could not check Documents access",
}

_DETAILS = {
    STATUS_WORKING: (
        "Ostler can write to your Documents folder. Your personal wiki "
        "and your conversation records are saved under Documents/Ostler, "
        "on this Mac. They are yours and they stay on this machine."
    ),
    STATUS_DENIED: (
        "macOS is blocking Ostler from writing to your Documents folder, "
        "so your personal wiki and your conversation records cannot be "
        "written. Anything already written stays, and nothing leaves this "
        "Mac."
    ),
    STATUS_CHECK_FAILED: (
        "Ostler tried to write a test file under Documents/Ostler and the "
        "attempt failed for a reason that was not a permission refusal. "
        "Your wiki and conversation records may or may not be saving."
    ),
}

_REMEDIATION = {
    STATUS_DENIED: (
        "Open System Settings, then Privacy and Security, then Files and "
        "Folders. Find the Ostler row -- it may be listed as "
        "\"python3.11\", the bundled helper Ostler uses to write your "
        "files -- and switch on access to your Documents folder. Your wiki "
        "and conversation records will be written from then on."
    ),
    STATUS_CHECK_FAILED: (
        "Check that the disk holding your home folder is not full or "
        "read-only, then open the Doctor dashboard again to re-check."
    ),
}

_HOW_TO_FIX_LABEL = "How to fix"

# Status-dependent colour + icon, matching the iMessage and Reminders
# tiles. A denial is amber, not red: it is squarely customer-fixable in
# System Settings (the Files and Folders toggle), which is the same
# class the Reminders tile paints amber. A check-failure is red: an
# untrustworthy snapshot the customer cannot straightforwardly remedy.
_COLOURS = {
    STATUS_WORKING: "#2C4A2C",
    STATUS_DENIED: "#5C4611",
    STATUS_CHECK_FAILED: "#7A1F1F",
}
_ICONS = {
    STATUS_WORKING: "&#10003;",
    STATUS_DENIED: "&#9888;",
    STATUS_CHECK_FAILED: "&#9888;",
}


def render_documents_access_posture(
    docs_root: Optional[os.PathLike] = None,
    *,
    _write_probe: Optional[Callable[[Path], None]] = None,
) -> str:
    """Render the Documents-access posture tile as static HTML.

    Returns the empty string when the state is ``not-yet-asked`` (a
    fresh box before install.sh's first Documents write), so Doctor
    falls through to no section rather than alarming the customer about
    a permission nobody has been asked for yet. Mirrors the
    fall-through the iMessage and Reminders tiles use for an absent
    marker.

    A working state renders a green card; a denial an amber card with a
    How-to-fix block; a check-failure a red card. The expand-collapse
    uses the native ``<details>`` element, so no JavaScript is needed.
    """
    marker = probe_documents_access(docs_root, _write_probe=_write_probe)
    status = marker.get("status")

    if status == STATUS_NOT_ASKED or status not in _STATUS_LABELS:
        return ""

    colour = _COLOURS[status]
    icon = _ICONS[status]
    status_label = _STATUS_LABELS[status]
    detail = _DETAILS[status]
    remediation = _REMEDIATION.get(status)

    how_to_fix = ""
    if remediation:
        how_to_fix = (
            '\n                <details style="margin-top:8px">'
            '\n                    <summary style="cursor:pointer;font-size:12px;'
            "color:rgba(236,232,221,0.50);font-family:'IBM Plex Mono','SF Mono',"
            'Menlo,monospace;letter-spacing:0.04em">'
            f"\n                        {html.escape(_HOW_TO_FIX_LABEL)}"
            "\n                    </summary>"
            f'\n                    <div class="status-detail">{html.escape(remediation)}</div>'
            "\n                </details>"
        )

    tile = f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{colour}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{html.escape(status_label)}</div>
                <div class="status-detail">{html.escape(detail)}</div>{how_to_fix}
            </div>
        </div>"""

    return f"""
    <div class="section" id="documentsAccessPostureSection">
        <div class="section-title">{html.escape(_SECTION_TITLE)}</div>
        <div class="status-grid">{tile}</div>
    </div>"""
