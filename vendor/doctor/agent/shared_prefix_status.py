"""Homebrew prefix ownership row for Ostler Doctor (same-shape sweep 2026-11-14).

The GUI admin shell used to chown /opt/homebrew to the owner on every install.
It now creates the prefix for the owner only when it is absent, and never
changes an existing one. This module only READS the owner of /opt/homebrew and
says what it means:

* ``absent``   no prefix. No row. (A fresh Mac: the installer creates it.)
* ``info``     owned by the account Ostler runs under. INFO only. Ostler did
               not chown it and will not change it, and an earlier chown cannot
               be reverted (the original owner was never recorded). No auto-fix.
* ``refused``  owned by ANOTHER account. Ostler will not take it. The row names
               no account. The fix is for that account to install Ostler, or
               for its owner to do it.
* ``could-not-check``  the path is unreadable. Never a pass.

Vendor-only: see vendor/VENDOR_ONLY.tsv.
"""
from __future__ import annotations

import html
import os
from typing import Optional

STATUS_ABSENT = "absent"
STATUS_INFO = "info"
STATUS_REFUSED = "refused"
STATUS_COULD_NOT_CHECK = "could-not-check"

DEFAULT_PREFIX = "/opt/homebrew"

_LABELS = {
    STATUS_INFO: "Homebrew is shared on this Mac",
    STATUS_REFUSED: "Homebrew belongs to another account",
    STATUS_COULD_NOT_CHECK: "Homebrew ownership could not be checked",
}
_DETAILS = {
    STATUS_INFO: (
        "Homebrew is owned by the account Ostler runs under. Ostler will not "
        "change its ownership. Nothing to fix."
    ),
    STATUS_REFUSED: (
        "Homebrew on this Mac belongs to another account, so Ostler did not "
        "change it. Install Ostler from that account, or ask that account's "
        "owner to do it."
    ),
    STATUS_COULD_NOT_CHECK: (
        "Ostler could not read who owns Homebrew ({reason}). This was not "
        "checked. It is not a pass."
    ),
}
_COLOURS = {STATUS_INFO: "#4A4A4A", STATUS_REFUSED: "#7A1F1F", STATUS_COULD_NOT_CHECK: "#7A1F1F"}
_ICONS = {STATUS_INFO: "&#8505;", STATUS_REFUSED: "&#9888;", STATUS_COULD_NOT_CHECK: "&#9888;"}


def classify_prefix(owner_uid: Optional[int], current_uid: int) -> str:
    """Pure. ``owner_uid`` None means the prefix does not exist."""
    if owner_uid is None:
        return STATUS_ABSENT
    if owner_uid == current_uid:
        return STATUS_INFO
    return STATUS_REFUSED


def read_prefix_owner(path: Optional[str] = None) -> tuple:
    """(owner_uid or None, reason). Never raises; reads only."""
    p = path or os.environ.get("OSTLER_SHARED_PREFIX_PATH") or DEFAULT_PREFIX
    try:
        return os.stat(p).st_uid, ""
    except FileNotFoundError:
        return None, ""
    except (OSError, ValueError) as exc:
        return None, f"{type(exc).__name__}"


def shared_prefix_status(path: Optional[str] = None, current_uid: Optional[int] = None) -> dict:
    uid = os.getuid() if current_uid is None else current_uid
    owner, err = read_prefix_owner(path)
    if err:
        return {"status": STATUS_COULD_NOT_CHECK, "reason": err}
    return {"status": classify_prefix(owner, uid), "reason": ""}


def render_shared_prefix_status(path: Optional[str] = None, current_uid: Optional[int] = None) -> str:
    """HTML row for the Doctor page. Empty string when there is no prefix."""
    st = shared_prefix_status(path, current_uid)
    status = st["status"]
    if status == STATUS_ABSENT:
        return ""
    detail = _DETAILS[status].format(reason=st.get("reason", ""))
    return f"""
    <div class="section" id="sharedPrefixSection">
        <div class="section-title">Homebrew</div>
        <div class="status-grid">
        <div class="status-card">
            <div class="status-indicator" style="background:{_COLOURS[status]}">{_ICONS[status]}</div>
            <div class="status-info">
                <div class="status-name">{html.escape(_LABELS[status])}</div>
                <div class="status-detail">{html.escape(detail)}</div>
            </div>
        </div>
        </div>
    </div>"""
