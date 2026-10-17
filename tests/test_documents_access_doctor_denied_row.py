#!/usr/bin/env python3
"""Tests for the Documents-access posture tile in the Doctor dashboard.

The launch-blocker this guards: Ostler's bundled interpreter writes the
customer's wiki + conversation records under ~/Documents/Ostler, behind
the macOS Files-and-Folders consent prompt. A customer who declines it
leaves those writes failing SILENTLY. The Doctor tile must surface a
DENIED state, and must tell it apart from a fresh box that has not been
asked yet (not-yet-asked) and from a working box.

Proves ``probe_documents_access`` classifies all four states, and
``render_documents_access_posture`` renders a denied row ONLY when the
state is denied -- never on a working or not-yet-asked box.

Everything is synthetic (PRODUCTISATION_CHECKLIST Rule 0): real tmp dirs
stand in for ~/Documents/Ostler, no real Hub, no real home folder. The
denied state is exercised two ways -- a REAL chmod-000 directory driving
the REAL probe to a real EACCES (the boundary the defect lives on, not a
mock of it), and an injected writer for the EPERM/ENOSPC distinction a
chmod cannot force deterministically.

Run: ``python3 tests/test_documents_access_doctor_denied_row.py`` (bare,
no deps) or under pytest.
"""

import errno
import os
import stat
import sys
import tempfile
from pathlib import Path

# The module is vendor-only and lives inside the Doctor agent package.
_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "vendor" / "doctor" / "agent"))

import documents_access_posture as dap  # noqa: E402


# ── probe classifier ───────────────────────────────────────────────

def test_working_when_root_exists_and_writable():
    """Real root dir + real probe write -> granted-and-working."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()
        marker = dap.probe_documents_access(root)
        assert marker["status"] == dap.STATUS_WORKING, marker
        # The probe must leave no litter behind.
        leftovers = [p for p in root.iterdir() if p.name.startswith(dap._PROBE_PREFIX)]
        assert leftovers == [], "probe file not cleaned up: %r" % leftovers


def test_not_yet_asked_when_root_absent_but_parent_writable():
    """Root absent, parent (Documents) writable -> not-yet-asked.

    This is the fresh-box state. It must NOT read as denied: install.sh
    simply has not reached its first Documents write. And the probe must
    NOT create the root (that would fire the very macOS prompt the
    installer pre-explains).
    """
    with tempfile.TemporaryDirectory() as tmp:
        parent = Path(tmp)  # stands in for ~/Documents
        root = parent / "Ostler"  # absent
        marker = dap.probe_documents_access(root)
        assert marker["status"] == dap.STATUS_NOT_ASKED, marker
        assert not root.exists(), "probe must not create the content root"


def test_denied_simulated_eperm_when_root_exists():
    """Injected EPERM on an existing root -> documents-denied."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()

        def refuse(_directory):
            raise PermissionError(errno.EPERM, "Operation not permitted")

        marker = dap.probe_documents_access(root, _write_probe=refuse)
        assert marker["status"] == dap.STATUS_DENIED, marker
        assert marker["errno"] == errno.EPERM, marker


def test_denied_at_install_simulated_when_root_absent():
    """Root absent AND the parent write is refused -> documents-denied.

    This is denial at install time: the mkdir of ~/Documents/Ostler was
    itself refused, so the root was never created. It must NOT be
    misread as not-yet-asked.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"  # absent

        def refuse(_directory):
            raise PermissionError(errno.EPERM, "Operation not permitted")

        marker = dap.probe_documents_access(root, _write_probe=refuse)
        assert marker["status"] == dap.STATUS_DENIED, marker


def test_denied_real_chmod_drives_real_probe():
    """A REAL chmod-000 directory drives the REAL probe to a real EACCES.

    Exercises the shipped _default_write_probe against a genuinely
    refused write, so the test is not green by mocking the boundary the
    defect lives on. Skipped where chmod cannot deny (root, or a volume
    that ignores mode bits).
    """
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        print("SKIP: running as root; chmod cannot deny a write")
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()
        os.chmod(root, 0)
        try:
            # Confirm chmod actually denies on this FS before trusting it.
            try:
                probe = root / (dap._PROBE_PREFIX + "control")
                fd = os.open(str(probe), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.close(fd)
                os.unlink(str(probe))
                print("SKIP: this filesystem ignores chmod 000; cannot force a real denial")
                return
            except PermissionError:
                pass
            marker = dap.probe_documents_access(root)
            assert marker["status"] == dap.STATUS_DENIED, marker
            assert marker.get("errno") in (errno.EACCES, errno.EPERM), marker
        finally:
            os.chmod(root, stat.S_IRWXU)


def test_check_failed_on_non_permission_error():
    """A non-permission OSError (e.g. ENOSPC) -> check-failed, not denied.

    The denied/check-failed split is the control that proves the denied
    verdict comes from the permission errno, not from any failed write.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()

        def no_space(_directory):
            raise OSError(errno.ENOSPC, "No space left on device")

        marker = dap.probe_documents_access(root, _write_probe=no_space)
        assert marker["status"] == dap.STATUS_CHECK_FAILED, marker


# ── render ──────────────────────────────────────────────────────────

_DENIED_TITLE = dap._STATUS_LABELS[dap.STATUS_DENIED]
_WORKING_TITLE = dap._STATUS_LABELS[dap.STATUS_WORKING]


def _refuse(_directory):
    raise PermissionError(errno.EPERM, "Operation not permitted")


def test_render_denied_row_present():
    """Denied state -> a denied row with the remediation path."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()
        html = dap.render_documents_access_posture(root, _write_probe=_refuse)
        assert _DENIED_TITLE in html, html
        assert "Files and Folders" in html, "remediation path missing: %r" % html
        assert "documentsAccessPostureSection" in html, html


def test_render_working_has_no_denied_row():
    """Working state -> a working row, and NOT the denied row."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"
        root.mkdir()
        html = dap.render_documents_access_posture(root)  # real writer, succeeds
        assert _WORKING_TITLE in html, html
        assert _DENIED_TITLE not in html, "working box must not show the denied row"


def test_render_not_yet_asked_is_empty():
    """Not-yet-asked -> empty string, so Doctor falls through to no row.

    Distinct from both working and denied: no section at all, matching
    the iMessage/Reminders tiles' absent-marker fall-through.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Ostler"  # absent, parent writable
        html = dap.render_documents_access_posture(root)
        assert html == "", "fresh box should render no Documents row, got %r" % html


def main():
    failures = []
    g = dict(globals())
    for name, fn in sorted(g.items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("ok: %s" % name)
            except AssertionError as exc:
                print("FAIL: %s: %s" % (name, exc), file=sys.stderr)
                failures.append(name)
    if failures:
        print("\n%d FAILURE(S)" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("\nALL DOCUMENTS-ACCESS DOCTOR ROW TESTS PASSED")


if __name__ == "__main__":
    main()
