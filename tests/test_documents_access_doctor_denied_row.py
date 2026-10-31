#!/usr/bin/env python3
"""Tests for the Documents-access posture tile in the Doctor dashboard.

The launch-blocker this guards: Ostler writes the customer's wiki and
conversation records under ~/Documents/Ostler, behind the macOS
Files-and-Folders consent. A denial must be visible in Doctor, and told
apart from a fresh box that has not been asked yet (not-yet-asked) and
from a working box.

v1.0.121 (NEW-121): the probe no longer runs in Doctor. The hourly
fda-rerun tick runs ``_ostler_documents_access_record`` (in the ostler-fda
wrapper install.sh writes) as a child of the signed FDA holder and writes
~/.ostler/state/documents_access.tsv; Doctor only reads it. So these tests
drive the REAL writer (extracted from install.sh, run under /bin/bash with
set -Eeuo pipefail) into the REAL reader and renderer:

  * working, not-yet-asked, denied by a REAL chmod-000 directory (the
    boundary the defect lives on), and check-failed (a missing parent);
  * no record, a stale record and a garbled record are all "could not
    check", never a pass and never silent.

Everything is synthetic: a temp HOME, no real Hub, no real home folder.
Run: ``python3 tests/test_documents_access_doctor_denied_row.py``.
"""

import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "vendor" / "doctor" / "agent"))

import documents_access_posture as dap  # noqa: E402

_WRAPPER = re.search(r"<<'FDAEOF'\n(.*?)\nFDAEOF\n", (_REPO / "install.sh").read_text(), re.S)
_FN = re.search(r"^_ostler_documents_access_record\(\) \{\n.*?^\}\n",
                _WRAPPER.group(1) if _WRAPPER else "", re.S | re.M)


def _home():
    tmp = tempfile.mkdtemp(prefix="docs-access-")
    home = Path(tmp) / "home"
    (home / ".ostler").mkdir(parents=True)
    (home / "Documents").mkdir()
    os.environ["HOME"] = str(home)
    os.environ.pop("OSTLER_DOCUMENTS_DIR", None)
    return home


def _run_writer(home: Path, docs_dir: str = "") -> None:
    assert _FN is not None, "_ostler_documents_access_record not found in the ostler-fda wrapper"
    script = Path(home.parent) / "writer.sh"
    script.write_text("set -Eeuo pipefail\ntrap 'echo ABORTED >&2' ERR\n"
                      f'OSTLER_DIR="{home}/.ostler"\n' + _FN.group(0)
                      + "_ostler_documents_access_record || true\necho REACHED\n")
    env = dict(os.environ, HOME=str(home))
    if docs_dir:
        env["OSTLER_DOCUMENTS_DIR"] = docs_dir
    p = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True)
    assert p.stdout.strip().endswith("REACHED") and "ABORTED" not in p.stderr, (p.stdout, p.stderr)


def _record(home: Path) -> str:
    return (home / ".ostler" / "state" / "documents_access.tsv").read_text()


def test_wrapper_calls_the_writer():
    assert _WRAPPER is not None
    body = _WRAPPER.group(1)
    assert "\n_ostler_documents_access_record || true\n" in body
    assert body.find("_ostler_documents_access_record || true") < body.find("_fda_rc=0")


def test_working_when_root_exists_and_writable():
    home = _home()
    root = home / "Documents" / "Ostler"
    root.mkdir()
    _run_writer(home)
    assert dap.read_documents_access()["status"] == dap.STATUS_WORKING, _record(home)
    assert [p for p in root.iterdir() if p.name.startswith(".ostler-access-probe-")] == [], \
        "probe file not cleaned up"
    assert "Working" in dap.render_documents_access_posture()


def test_not_yet_asked_when_root_absent_and_root_not_created():
    home = _home()
    _run_writer(home)
    assert dap.read_documents_access()["status"] == dap.STATUS_NOT_ASKED, _record(home)
    assert not (home / "Documents" / "Ostler").exists(), "the writer created the root"
    assert dap.render_documents_access_posture() == ""


def test_denied_real_chmod_drives_real_writer():
    if os.geteuid() == 0:
        print("CANNOT-RUN: root ignores chmod 000; denied-by-chmod not exercised")
        return
    home = _home()
    root = home / "Documents" / "Ostler"
    root.mkdir()
    root.chmod(0)
    try:
        _run_writer(home)
    finally:
        root.chmod(stat.S_IRWXU)
    m = dap.read_documents_access()
    assert m["status"] == dap.STATUS_DENIED, _record(home)
    html = dap.render_documents_access_posture()
    assert "Ostler cannot write to your Documents folder" in html and "How to fix" in html
    # The fix names what System Settings shows for the identity that writes
    # ~/Documents/Ostler (the signed daemon, display name "Ostler"), not the
    # python3.11 row that no longer makes the request.
    assert "Full Disk Access" in html and "make sure Ostler is switched on" in html, html
    assert "python3.11" not in html, html


def test_check_failed_on_non_permission_error():
    home = _home()
    missing = home / "nowhere" / "deeper" / "Ostler"
    _run_writer(home, docs_dir=str(missing))
    assert dap.read_documents_access()["status"] == dap.STATUS_CHECK_FAILED, _record(home)


def test_no_record_is_could_not_check():
    _home()
    m = dap.read_documents_access()
    assert m["status"] == dap.STATUS_CHECK_FAILED and "not checked yet" in m["reason"], m
    html = dap.render_documents_access_posture()
    assert "Could not check Documents access" in html and "It is not a pass" in html, html


def test_stale_record_is_could_not_check():
    home = _home()
    (home / "Documents" / "Ostler").mkdir()
    _run_writer(home)
    p = home / ".ostler" / "state" / "documents_access.tsv"
    old = int(time.time()) - dap.STATUS_MAX_AGE_SECONDS - 60
    p.write_text(re.sub(r"^recorded_at\t\d+", f"recorded_at\t{old}", p.read_text(), flags=re.M))
    m = dap.read_documents_access()
    assert m["status"] == dap.STATUS_CHECK_FAILED and "hours ago" in m["reason"], m


def test_garbled_record_is_could_not_check():
    home = _home()
    (home / ".ostler" / "state").mkdir(parents=True)
    (home / ".ostler" / "state" / "documents_access.tsv").write_text(
        f"recorded_at\t{int(time.time())}\nstatus\tgreat\n")
    m = dap.read_documents_access()
    assert m["status"] == dap.STATUS_CHECK_FAILED and "unknown status" in m["reason"], m


def main():
    failures = []
    for name, fn in sorted(dict(globals()).items()):
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
