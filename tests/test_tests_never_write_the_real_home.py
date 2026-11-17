"""Tests never write the operator's real home (2026-11-17).

MEASURED on a developer Mac, 2026-11-17: three tests in this tree wrote the
operator's real ~/.ostler: the forget test left a forgotten_people.json
tombstone for a synthetic person plus a forget_audit.log line on every run, and
the two plain-script tests below left non_identifying_identifiers.json and
overwrote settling_progress.d shards. A per-file sweep of all 376 test files
with HOME at a stand-in found 19 files writing under it; the pytest-run ones
are covered by the conftest sandbox, and the six plain scripts are listed
below (each run by a workflow as `python tests/<name>.py`). Every writer resolves its path from HOME
at call time; nothing pointed HOME away from the real one.

WHAT THIS RUNS. Each culprit, in a child process whose HOME is a throwaway
directory standing in for the real one, with OSTLER_STATE_DIR / OSTLER_QUEUE_DIR
unset (an operator shell need not set them). Afterwards that directory must hold
nothing under .ostler. Then the guard itself: a generated test writes under a
stand-in "real home" and must be refused and failed.

RED on the unfixed tree (conftest without the sandbox, scripts without their
own HOME): every culprit case finds files under the stand-in home.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
_DROP = ("OSTLER_STATE_DIR", "OSTLER_QUEUE_DIR", "OSTLER_FORGET_TOMBSTONE_FILE",
         "PYTEST_ADDOPTS", "PYTEST_CURRENT_TEST")


def _child_env(home):
    env = {k: v for k, v in os.environ.items() if k not in _DROP}
    env["HOME"] = str(home)
    return env


def _written(home):
    root = Path(home) / ".ostler"
    return sorted(str(p.relative_to(home)) for p in root.rglob("*") if p.is_file()) if root.exists() else []


@pytest.fixture
def standin_home():
    # Not under pytest's tmp_path, and not inside the session sandbox this
    # process runs in: a fresh directory, as a real home would be.
    d = tempfile.mkdtemp(prefix="standin-home-")
    yield Path(d)
    import shutil
    shutil.rmtree(d, ignore_errors=True)


def test_forget_pytest_case_leaves_the_home_untouched(standin_home):
    r = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
         "tests/test_person_removal_audit.py::test_forget_records_the_person_before_the_erasure"],
        cwd=REPO, env=_child_env(standin_home), capture_output=True, text=True, timeout=600)
    assert "1 passed" in r.stdout, r.stdout[-2000:] + r.stderr[-2000:]
    assert _written(standin_home) == []


@pytest.mark.parametrize("script", [
    "tests/test_fda_refusal_surfaces.py",
    "tests/test_read_messages_are_not_no_data.py",
    "tests/test_every_conversation_produces_all_four_artefacts.py",
    "tests/test_people_carded_names_show_and_tiers_hold_in_every_path.py",
    "tests/test_pwg_convo_bin_owner_side_first.py",
    "tests/test_reply_debt_probe_names_the_missed_debt.py",
])
def test_plain_script_leaves_the_home_untouched(standin_home, script):
    r = subprocess.run([sys.executable, script], cwd=REPO, env=_child_env(standin_home),
                       capture_output=True, text=True, timeout=600)
    # 0 pass, 1 fail, 2 cannot-run: only "it never ran" is out of scope here.
    assert r.returncode in (0, 1, 2), r.stderr[-2000:]
    assert _written(standin_home) == []


def test_guard_refuses_and_fails_a_write_under_the_real_home(tmp_path):
    """Positive control: point the guard's REAL_HOME at a stand-in and write there."""
    fake_real = Path(tempfile.mkdtemp(prefix="standin-real-home-"))
    target = fake_real / ".ostler" / "state" / "probe.json"
    case = tmp_path / "test_guard_probe.py"
    case.write_text(
        "import os, conftest\n"
        "conftest.REAL_HOME = %r\n"
        "def test_writes_home():\n"
        "    try:\n"
        "        os.makedirs(os.path.dirname(%r), exist_ok=True)\n"
        "        open(%r, 'w').write('x')\n"
        "    except PermissionError:\n"
        "        pass\n" % (os.path.realpath(fake_real), str(target), str(target)))
    env = _child_env(tmp_path / "h")
    env["PYTHONPATH"] = str(REPO / "tests")
    r = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-p", "conftest",
         "--rootdir", str(tmp_path), "-c", os.devnull, str(case)],
        cwd=tmp_path, env=env, capture_output=True, text=True, timeout=300)
    try:
        assert r.returncode != 0, r.stdout[-2000:]
        assert "HOME GUARD" in r.stdout, r.stdout[-2000:]
        assert not target.exists(), "the guard reported the write but did not refuse it"
    finally:
        import shutil
        shutil.rmtree(fake_real, ignore_errors=True)
