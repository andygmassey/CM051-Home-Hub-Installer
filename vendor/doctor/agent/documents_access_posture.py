"""Documents-folder access posture tile for Ostler Doctor.

Sibling of ``imessage_tcc_posture.py`` and ``reminders_posture.py``: like
them, Doctor only READS a record another component wrote.

v1.0.121 (NEW-121): this tile used to run a LIVE write probe from Doctor's
own python, an ``O_EXCL`` create in ``~/Documents/Ostler`` (or in
``~/Documents`` when that was absent) on every ``/doctor`` render. Doctor
is a launchd job whose program is the bundled python, so TCC charged each
probe to python3.11 as a Documents request: the shape the walk probe
``no_python_is_tcc_responsible`` fails on, and one that can put a bare
"python3.11 would like to access your Documents folder" prompt in front of
a customer from a page they merely opened.

The probe now runs in the hourly fda-rerun tick
(``ostler-assistant run-source fda-rerun`` -> sealed tick.sh ->
``~/.ostler/bin/ostler-fda``, function ``_ostler_documents_access_record``),
a fork+wait child of Ostler's signed Full-Disk-Access holder, and writes
``~/.ostler/state/documents_access.tsv``. This module reads that file and
nothing else: no write, no stat, no subprocess under ``~/Documents``.

Four states, as the writer records them
---------------------------------------

* ``granted-and-working`` -- the content root exists and a probe write
  into it succeeded.
* ``documents-denied`` -- the probe write was refused with a permission
  error. The state the customer must act on.
* ``not-yet-asked`` -- the root does not exist yet and its parent accepted
  a probe write. Deliberately NOT a denial; renders nothing.
* ``check-failed`` -- a non-permission error. Also what THIS reader
  reports when the file is missing, unparseable, of an unknown status or
  older than ``STATUS_MAX_AGE_SECONDS``: no current answer is "could not
  check", never a pass.

The writer never creates the root: when it is absent it probes the PARENT,
exactly as the old live probe did.
"""
from __future__ import annotations

import html
import logging
import os
import time
from typing import Optional, TypedDict

logger = logging.getLogger(__name__)

# Status values. Distinct constants so a caller can branch on the exact
# state; a two-state (ok / not-ok) predicate would read "not yet asked"
# as a failure on every fresh box.
STATUS_WORKING = "granted-and-working"
STATUS_DENIED = "documents-denied"
STATUS_NOT_ASKED = "not-yet-asked"
STATUS_CHECK_FAILED = "check-failed"
_KNOWN = (STATUS_WORKING, STATUS_DENIED, STATUS_NOT_ASKED, STATUS_CHECK_FAILED)

# The record the fda-rerun tick writes, resolved from HOME like the writer
# (the ostler-fda wrapper sets OSTLER_DIR="${HOME}/.ostler" itself).
STATUS_FILE_REL = os.path.join(".ostler", "state", "documents_access.tsv")
# The writer runs hourly. Six missed ticks is no longer a current answer.
STATUS_MAX_AGE_SECONDS = 6 * 3600


class DocumentsAccessMarker(TypedDict, total=False):
    """Result of reading the fda-rerun tick's record."""

    status: str
    docs_root: str
    probed_path: str
    detail: str
    # Set only when there is no current answer (missing, stale, garbled).
    reason: str


def _status_path() -> str:
    return os.path.join(os.path.expanduser("~"), STATUS_FILE_REL)


def read_documents_access(now: Optional[float] = None) -> DocumentsAccessMarker:
    """Read the Documents-access record. Never raises, never probes.

    Missing, unreadable, unparseable, unknown-status or stale is
    ``check-failed`` with a ``reason``: a check that has no current answer
    is not a pass.
    """
    path = _status_path()
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return {"status": STATUS_CHECK_FAILED,
                "reason": "not checked yet: the hourly background check has not run"}
    except OSError as exc:
        return {"status": STATUS_CHECK_FAILED,
                "reason": f"record unreadable ({type(exc).__name__})"}
    fields: dict = {}
    for line in lines:
        key, _, value = line.partition("\t")
        fields[key] = value
    try:
        recorded_at = int(fields.get("recorded_at", ""))
    except ValueError:
        return {"status": STATUS_CHECK_FAILED, "reason": "record carries no time"}
    age = (time.time() if now is None else now) - recorded_at
    if age > STATUS_MAX_AGE_SECONDS:
        return {"status": STATUS_CHECK_FAILED,
                "reason": f"last checked {int(age // 3600)} hours ago"}
    if age < -300:
        return {"status": STATUS_CHECK_FAILED, "reason": "record is dated in the future"}
    status = fields.get("status", "")
    if status not in _KNOWN:
        return {"status": STATUS_CHECK_FAILED,
                "reason": f"record has an unknown status ({status[:40]!r})"}
    marker: DocumentsAccessMarker = {
        "status": status,
        "docs_root": fields.get("docs_root", ""),
        "probed_path": fields.get("probed_path", ""),
        "detail": fields.get("detail", ""),
    }
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

# No current answer (record missing, stale or garbled). Same label as a
# check-failure; different words, because nothing was tried and failed.
_NO_ANSWER_DETAIL_FMT = (
    "Ostler has no current answer about your Documents folder ({reason}), "
    "so this was not checked. It is not a pass."
)
_NO_ANSWER_REMEDIATION = (
    "Ostler re-checks this in the background every hour. Open the Doctor "
    "dashboard again later; if this stays, run the Ostler installer again "
    "to repair it."
)

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


def render_documents_access_posture() -> str:
    """Render the Documents-access posture tile as static HTML.

    Reads the fda-rerun tick's record (:func:`read_documents_access`);
    never touches ``~/Documents`` itself.

    Returns the empty string when the state is ``not-yet-asked`` (a
    fresh box before install.sh's first Documents write), so Doctor
    falls through to no section rather than alarming the customer about
    a permission nobody has been asked for yet.

    A working state renders a green card; a denial an amber card with a
    How-to-fix block; a check-failure (or no current answer) a red card.
    The expand-collapse uses the native ``<details>`` element, so no
    JavaScript is needed.
    """
    marker = read_documents_access()
    status = marker.get("status")

    if status == STATUS_NOT_ASKED or status not in _STATUS_LABELS:
        return ""

    colour = _COLOURS[status]
    icon = _ICONS[status]
    status_label = _STATUS_LABELS[status]
    detail = _DETAILS[status]
    remediation = _REMEDIATION.get(status)
    if marker.get("reason"):
        detail = _NO_ANSWER_DETAIL_FMT.format(reason=marker["reason"])
        remediation = _NO_ANSWER_REMEDIATION

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
