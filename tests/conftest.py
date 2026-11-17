"""Keep the Person-removal audit out of the real home directory.

Writers that can remove a Person append to ~/.ostler/logs/person-deletions.jsonl
(person_audit.py). Any test that drives one of them must not write to the
developer's or CI runner's real log, so every test gets a private path.

HOME SANDBOX AND WRITE GUARD (2026-11-17). Three tests in this tree wrote the
operator's REAL ~/.ostler/state on a developer Mac: the forget test (a
forgotten_people.json tombstone and ~/.ostler/queue/forget_audit.log), and two
plain-script tests (non_identifying_identifiers.json, settling_progress.d
shards). Each writer resolves its path from HOME at call time, so the fix is on
the test side: before any test module is imported, HOME and the OSTLER_* state
variables point at a private session directory (import-time constants such as
ical-server's _RECOMPILE_QUEUE_DIR then bind inside it too). An audit hook then
REFUSES (PermissionError) and FAILS any test write under the real home (taken
from the password database, not from $HOME) outside this checkout, and FAILS
any write anywhere outside the sandbox, the temp roots and this checkout. tests/test_tests_never_write_the_real_home.py
holds both halves shut.
"""
import os
import pwd
import shutil
import sys
import tempfile

import pytest

REAL_HOME = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), os.pardir))
_SESSION_ENV = ("HOME", "OSTLER_STATE_DIR", "OSTLER_QUEUE_DIR")
_saved_env = {}
_sandbox = []
_writes = []          # (nodeid, verdict, path)
_current = ["<session>"]


def _temp_roots():
    roots = {os.path.realpath(tempfile.gettempdir()), "/tmp", "/private/tmp", "/dev"}
    roots.add("/private/var/folders")
    return tuple(sorted(roots))


def _verdict(path):
    """None when the write is allowed, else a short reason."""
    if not isinstance(path, (str, bytes, os.PathLike)):
        return None
    try:
        rp = os.path.realpath(os.fsdecode(path))
    except (TypeError, ValueError):
        return None
    if _sandbox and (rp == _sandbox[0] or rp.startswith(_sandbox[0] + os.sep)):
        return None
    if rp == REPO or rp.startswith(REPO + os.sep):
        return None
    if rp == REAL_HOME or rp.startswith(REAL_HOME + os.sep):
        return "REAL_HOME"
    if rp.startswith(tuple(r + os.sep for r in _temp_roots())):
        return None
    return "OUTSIDE_SANDBOX"


def _audit(event, args):
    if not _sandbox:
        return
    try:
        if event == "open":
            path, mode, flags = args
            writes = (isinstance(mode, str) and any(c in mode for c in "wax+")) or (
                isinstance(flags, int)
                and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC))
            targets = (path,) if writes else ()
        elif event in ("os.remove", "os.rmdir", "os.mkdir"):
            # dir_fd-relative (shutil.rmtree) names a bare entry: not resolvable here.
            targets = () if any(isinstance(a, int) and a >= 0 for a in args[1:]) else args[:1]
        elif event == "os.rename":
            fds = [a for a in args[2:4] if isinstance(a, int) and a >= 0]
            targets = () if fds else args[:2]
        else:
            return
        hits = [(r, os.fsdecode(t)) for t in targets for r in [_verdict(t)] if r]
    except Exception:  # a guard bug must never break the code under test
        return
    for reason, path in hits:
        _writes.append((_current[0], reason, path))
        if reason == "REAL_HOME":
            # Refuse it: the operator's home is never written, even once.
            raise PermissionError("HOME GUARD: refused a test write under the real home: "
                                  + path.replace(REAL_HOME, "<real home>"))


def pytest_configure(config):
    root = os.path.realpath(tempfile.mkdtemp(prefix="cm051-test-home-"))
    _sandbox.append(root)
    for key in _SESSION_ENV:
        _saved_env[key] = os.environ.get(key)
    os.environ["HOME"] = root
    os.environ["OSTLER_STATE_DIR"] = os.path.join(root, ".ostler", "state")
    os.environ["OSTLER_QUEUE_DIR"] = os.path.join(root, ".ostler", "queue")
    sys.addaudithook(_audit)


def pytest_unconfigure(config):
    for key, value in _saved_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    if _sandbox:
        root = _sandbox.pop()
        shutil.rmtree(root, ignore_errors=True)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item, nextitem):
    _current[0] = item.nodeid
    yield
    _current[0] = "<session>"


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    if call.when != "teardown":
        return
    mine = sorted({(r, p) for n, r, p in _writes if n == item.nodeid})
    if mine:
        rep = outcome.get_result()
        rep.outcome = "failed"
        rep.longrepr = (
            "HOME GUARD: this test wrote %d path(s) outside the sandbox:\n" % len(mine)
            + "\n".join("  %s %s" % (r, p.replace(REAL_HOME, "<real home>")) for r, p in mine[:20]))


@pytest.fixture(autouse=True)
def _private_person_deletion_log(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "person-deletions.jsonl"))


@pytest.fixture(autouse=True)
def _reminder_fixture_dates_are_not_stale(request, monkeypatch):
    """The older cm048_reminder tests carry fixed 2026-10 source dates; the
    30-day staleness cutoff would turn them red as the calendar moves. They
    test other rules, so the cutoff is off for them. The gate's own test
    (test_cm048_reminder_title_quality_gate.py) sets the env var itself."""
    name = request.module.__name__
    if name.startswith("test_cm048_reminder") and "quality_gate" not in name:
        monkeypatch.setenv("OSTLER_TODO_MAX_AGE_DAYS", "0")


@pytest.fixture(autouse=True)
def _private_people_index_record(tmp_path, monkeypatch):
    """The people sweep writes its backlog record to ~/.ostler/state/people-index.json
    (pwg_ingest._people_index_state_path). Any test that drives the sweep must not
    write the developer's or runner's real one."""
    monkeypatch.setenv("OSTLER_PEOPLE_INDEX_STATE", str(tmp_path / "people-index.json"))
