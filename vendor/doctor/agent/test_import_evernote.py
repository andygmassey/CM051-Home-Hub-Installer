"""Tests for the Evernote import endpoint (CM024 Block 3.3).

Covers the launch-scope brief's required 6 tests + module-level unit
coverage:

Required by brief (3 flag-gate + 3 endpoint integration):

* ``test_evernote_import_off_returns_404_on_get``
* ``test_evernote_import_off_returns_404_on_post``
* ``test_evernote_import_on_renders_page``
* ``test_post_starts_import_returns_job_id``
* ``test_post_invalid_path_returns_400``
* ``test_post_while_lock_held_returns_409``

Plus thorough unit tests for ``is_feature_enabled``, ``validate_enex_path``,
``lockfile_state``, ``_pid_alive``, ``current_running_job_id``,
``read_status``, ``read_tail``, and the supervisor wrapper
``import_evernote_runner.py``.

The tests do NOT actually fork ``ostler-knowledge``. The subprocess
is mocked via a recorder that captures the argv and returns a stub
``Popen`` handle with a chosen PID. End-to-end execution is covered
by Block 3.5 (Mac Studio smoke), not by this unit suite -- see the
brief for the split.
"""
from __future__ import annotations

import json
import os
import sys
import textwrap
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

import pytest

# ``import_evernote`` ships next to ``web_ui.py``; mirror the import
# path manipulation the rest of doctor/agent's tests use.
sys.path.insert(0, str(Path(__file__).parent))

import import_evernote as ie  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def features_off(monkeypatch, tmp_path):
    """Write a features.yaml with ``evernote_import: false`` and point
    the module at it. Default value matches the v1 launch posture."""
    features = tmp_path / "features.yaml"
    features.write_text("features:\n  evernote_import: false\n")
    monkeypatch.setenv("OSTLER_FEATURES_FILE", str(features))
    return features


@pytest.fixture
def features_on(monkeypatch, tmp_path):
    """Write a features.yaml with ``evernote_import: true`` and point
    the module at it."""
    features = tmp_path / "features.yaml"
    features.write_text("features:\n  evernote_import: true\n")
    monkeypatch.setenv("OSTLER_FEATURES_FILE", str(features))
    return features


@pytest.fixture
def tiny_enex(tmp_path) -> Path:
    """A minimal synthetic .enex file. The unit suite doesn't actually
    parse ENEX -- ``validate_enex_path`` only checks the file exists
    and ends ``.enex`` -- but a real on-disk file keeps the integration
    tests honest. The shape matches Evernote's export schema enough
    that a real ``ostler-knowledge convert`` invocation would not
    immediately reject it. End-to-end parse coverage lives in Block 3.5.

    Synthetic content uses the standard cast (Alex / Sam) per the
    cross-repo memory rule."""
    p = tmp_path / "tiny.enex"
    p.write_text(textwrap.dedent("""\
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
        <en-export export-date="20260513T120000Z" application="Evernote" version="10.x">
          <note>
            <title>Sample note for Alex</title>
            <content><![CDATA[<en-note>Sam said hi.</en-note>]]></content>
            <created>20260101T120000Z</created>
            <updated>20260101T120000Z</updated>
          </note>
        </en-export>
    """))
    return p


@pytest.fixture
def isolated_dirs(monkeypatch, tmp_path):
    """Redirect the module's default directories into a tmp dir so a
    test never reads or writes inside the operator's real
    ``~/.ostler``. Returns a dict of {name: Path}."""
    dirs = {
        "lock_dir": tmp_path / "locks",
        "log_dir": tmp_path / "logs",
        "state_dir": tmp_path / "state",
        "staging_dir": tmp_path / "data" / "knowledge-staging",
        "config_dir": tmp_path / "config",
    }
    for p in dirs.values():
        p.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(ie, "DEFAULT_LOCK_DIR", dirs["lock_dir"])
    monkeypatch.setattr(ie, "DEFAULT_LOG_DIR", dirs["log_dir"])
    monkeypatch.setattr(ie, "DEFAULT_STATE_DIR", dirs["state_dir"])
    monkeypatch.setattr(ie, "DEFAULT_STAGING_DIR", dirs["staging_dir"])
    monkeypatch.setattr(
        ie, "DEFAULT_FEATURES_FILE", dirs["config_dir"] / "features.yaml",
    )
    return dirs


class _RecorderSubprocess:
    """Stub for the ``subprocess`` module that records Popen calls.

    Returns a fake Popen handle whose ``pid`` is configurable. The
    handle is otherwise inert -- start_import never waits on it; the
    real supervisor wrapper handles waiting.
    """

    PIPE = -1
    STDOUT = -2
    DEVNULL = -3

    def __init__(self, *, pid: int = 99999):
        self.pid = pid
        self.calls: List[Dict[str, Any]] = []

    def Popen(self, argv, **kwargs):  # noqa: N802 (mirrors stdlib name)
        self.calls.append({"argv": list(argv), "kwargs": dict(kwargs)})

        class _Stub:
            def __init__(self, pid):
                self.pid = pid
        return _Stub(self.pid)


# ---------------------------------------------------------------------------
# is_feature_enabled
# ---------------------------------------------------------------------------


class TestIsFeatureEnabled:

    def test_missing_file_returns_false(self, tmp_path, monkeypatch):
        missing = tmp_path / "no-such-features.yaml"
        monkeypatch.setenv("OSTLER_FEATURES_FILE", str(missing))
        assert ie.is_feature_enabled() is False

    def test_flag_off_returns_false(self, features_off):
        assert ie.is_feature_enabled() is False

    def test_flag_on_returns_true(self, features_on):
        assert ie.is_feature_enabled() is True

    def test_missing_key_returns_false(self, tmp_path, monkeypatch):
        f = tmp_path / "features.yaml"
        f.write_text("features:\n  other_feature: true\n")
        monkeypatch.setenv("OSTLER_FEATURES_FILE", str(f))
        assert ie.is_feature_enabled() is False

    def test_non_boolean_value_returns_false(self, tmp_path, monkeypatch):
        f = tmp_path / "features.yaml"
        f.write_text('features:\n  evernote_import: "yes please"\n')
        monkeypatch.setenv("OSTLER_FEATURES_FILE", str(f))
        # Anything that is not literal True returns False -- the bare
        # string "yes please" should not silently enable the flag.
        assert ie.is_feature_enabled() is False

    def test_malformed_yaml_returns_false(self, tmp_path, monkeypatch):
        f = tmp_path / "features.yaml"
        f.write_text("features:\n  evernote_import: : :\n")
        monkeypatch.setenv("OSTLER_FEATURES_FILE", str(f))
        assert ie.is_feature_enabled() is False

    def test_top_level_list_returns_false(self, tmp_path, monkeypatch):
        f = tmp_path / "features.yaml"
        f.write_text("- evernote_import\n")
        monkeypatch.setenv("OSTLER_FEATURES_FILE", str(f))
        assert ie.is_feature_enabled() is False


# ---------------------------------------------------------------------------
# validate_enex_path
# ---------------------------------------------------------------------------


class TestValidateEnexPath:

    def test_happy_path_returns_resolved(self, tiny_enex):
        resolved = ie.validate_enex_path(str(tiny_enex))
        assert resolved == tiny_enex.resolve()

    def test_non_string_400(self):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.validate_enex_path(12345)
        assert ei.value.status == 400

    def test_empty_400(self):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.validate_enex_path("   ")
        assert ei.value.status == 400

    def test_nonexistent_400(self, tmp_path):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.validate_enex_path(str(tmp_path / "missing.enex"))
        assert ei.value.status == 400
        assert "not found" in ei.value.detail

    def test_wrong_extension_400(self, tmp_path):
        not_enex = tmp_path / "export.zip"
        not_enex.write_text("not an enex")
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.validate_enex_path(str(not_enex))
        assert ei.value.status == 400
        assert ".enex" in ei.value.detail

    def test_uppercase_extension_accepted(self, tmp_path):
        big = tmp_path / "EXPORT.ENEX"
        big.write_text("upper case")
        resolved = ie.validate_enex_path(str(big))
        assert resolved == big.resolve()

    def test_expands_tilde(self, tmp_path, monkeypatch):
        # ``~`` should be honoured so the operator can paste
        # ``~/Downloads/export.enex`` straight from a terminal.
        enex = tmp_path / "homed.enex"
        enex.write_text("ok")
        monkeypatch.setenv("HOME", str(tmp_path))
        resolved = ie.validate_enex_path("~/homed.enex")
        assert resolved == enex.resolve()


# ---------------------------------------------------------------------------
# _pid_alive
# ---------------------------------------------------------------------------


class TestPidAlive:

    def test_negative_zero_false(self):
        assert ie._pid_alive(0) is False
        assert ie._pid_alive(-1) is False
        assert ie._pid_alive("not an int") is False
        assert ie._pid_alive(None) is False

    def test_current_process_alive(self):
        assert ie._pid_alive(os.getpid()) is True

    def test_definitely_dead_pid_false(self):
        # PID 1 (init) is always alive on macOS so we can't use it as
        # a "dead PID" canary. Use a PID well above the kernel's
        # PID_MAX so the lookup definitely fails.
        assert ie._pid_alive(2**30) is False


# ---------------------------------------------------------------------------
# lockfile_state + current_running_job_id
# ---------------------------------------------------------------------------


class TestLockfileState:

    def test_no_file_returns_none(self, tmp_path):
        assert ie.lockfile_state(_lock_dir=tmp_path) is None

    def test_alive_lock(self, tmp_path):
        lock = tmp_path / ie.LOCK_FILENAME
        lock.write_text(json.dumps({
            "job_id": "20260513T120000Z-aabbccdd",
            "pid": os.getpid(),
            "started_at": "2026-05-13T12:00:00+00:00",
        }))
        out = ie.lockfile_state(_lock_dir=tmp_path)
        assert out is not None
        assert out["alive"] is True
        assert out["job_id"] == "20260513T120000Z-aabbccdd"

    def test_dead_lock(self, tmp_path):
        lock = tmp_path / ie.LOCK_FILENAME
        lock.write_text(json.dumps({
            "job_id": "20260513T120000Z-aabbccdd",
            "pid": 2**30,  # safely dead
            "started_at": "2026-05-13T12:00:00+00:00",
        }))
        out = ie.lockfile_state(_lock_dir=tmp_path)
        assert out["alive"] is False

    def test_malformed_json_returns_none(self, tmp_path):
        lock = tmp_path / ie.LOCK_FILENAME
        lock.write_text("not json {{")
        assert ie.lockfile_state(_lock_dir=tmp_path) is None


class TestCurrentRunningJobId:

    def test_no_lock_returns_none(self, tmp_path):
        assert ie.current_running_job_id(_lock_dir=tmp_path) is None

    def test_alive_lock_returns_job_id(self, tmp_path):
        lock = tmp_path / ie.LOCK_FILENAME
        lock.write_text(json.dumps({
            "job_id": "20260513T120000Z-abcdef01",
            "pid": os.getpid(),
            "started_at": "2026-05-13T12:00:00+00:00",
        }))
        assert (
            ie.current_running_job_id(_lock_dir=tmp_path)
            == "20260513T120000Z-abcdef01"
        )

    def test_dead_lock_returns_none(self, tmp_path):
        lock = tmp_path / ie.LOCK_FILENAME
        lock.write_text(json.dumps({
            "job_id": "20260513T120000Z-abcdef01",
            "pid": 2**30,
            "started_at": "2026-05-13T12:00:00+00:00",
        }))
        assert ie.current_running_job_id(_lock_dir=tmp_path) is None


# ---------------------------------------------------------------------------
# start_import
# ---------------------------------------------------------------------------


class TestStartImport:

    def test_happy_path_returns_job_id(self, isolated_dirs, tiny_enex):
        rec = _RecorderSubprocess(pid=12345)
        out = ie.start_import(
            tiny_enex,
            _now=datetime(2026, 5, 13, 12, 0, 0, tzinfo=timezone.utc),
            _subprocess=rec,
            _binary="/tmp/fake-ostler-knowledge",
            _runner=Path("/tmp/fake-runner.py"),
        )
        assert out["status"] == "started"
        assert out["job_id"].startswith("20260513T120000Z-")
        assert len(rec.calls) == 1
        # Lockfile was written with the subprocess pid.
        lock_path = isolated_dirs["lock_dir"] / ie.LOCK_FILENAME
        assert lock_path.is_file()
        lock = json.loads(lock_path.read_text())
        assert lock["pid"] == 12345
        assert lock["job_id"] == out["job_id"]
        assert lock["log_path"].endswith(".log")
        assert Path(lock["log_path"]).is_file()  # log opened by start_import

    def test_passes_correct_argv_to_runner(self, isolated_dirs, tiny_enex):
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec,
            _binary="/usr/local/bin/ostler-knowledge",
            _runner=Path("/runner.py"),
            _python="/usr/bin/python3",
        )
        argv = rec.calls[0]["argv"]
        # Wrapper args first, then ``--`` sentinel, then the actual
        # binary + ostler-knowledge command.
        assert argv[0] == "/usr/bin/python3"
        assert argv[1] == "/runner.py"
        assert "--state" in argv
        assert "--lock" in argv
        assert "--job-id" in argv
        assert "--enex-path" in argv
        assert "--" in argv
        sentinel = argv.index("--")
        assert argv[sentinel + 1] == "/usr/local/bin/ostler-knowledge"
        assert argv[sentinel + 2] == "convert"
        assert "--source" in argv[sentinel + 2:]
        assert "evernote" in argv[sentinel + 2:]

    def test_chains_embed_phase_after_convert(self, isolated_dirs, tiny_enex):
        # The gap-closer: convert alone leaves the wiki Knowledge section
        # empty. start_import must chain an embed phase (via the runner's
        # --and-then sentinel) so the markdown lands in Qdrant.
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec,
            _binary="/usr/local/bin/ostler-knowledge",
            _runner=Path("/runner.py"),
            _python="/usr/bin/python3",
        )
        argv = rec.calls[0]["argv"]
        assert "--and-then" in argv, "embed phase must be chained after convert"
        # convert comes before the sentinel, embed after it.
        andthen = argv.index("--and-then")
        assert "convert" in argv[:andthen]
        embed_phase = argv[andthen + 1:]
        assert embed_phase[0] == "/usr/local/bin/ostler-knowledge"
        assert embed_phase[1] == "embed"
        # Embeds into the source's collection with the 768-dim Hub model,
        # or the upsert dimension-mismatches and Knowledge stays empty.
        assert "--collection" in embed_phase
        assert "evernote_knowledge" in embed_phase
        assert "--embedding-model" in embed_phase
        assert "nomic-embed-text" in embed_phase

    def test_embed_phase_caps_compartment_level_to_exclude_l3(
        self, isolated_dirs, tiny_enex,
    ):
        # Privacy gate: the embed phase must pass --max-compartment-level 2
        # so L3 ("private") notes are never indexed into the searchable
        # collection. The wiki Knowledge reader does not re-filter by level,
        # so this is the only barrier between a private note and the wiki.
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec,
            _binary="/usr/local/bin/ostler-knowledge",
            _runner=Path("/runner.py"), _python="/usr/bin/python3",
        )
        argv = rec.calls[0]["argv"]
        embed_phase = argv[argv.index("--and-then") + 1:]
        assert "--max-compartment-level" in embed_phase
        cap = embed_phase[embed_phase.index("--max-compartment-level") + 1]
        assert cap == "2", f"expected L3 excluded (cap 2), got {cap!r}"

    def test_compartment_cap_overridable_via_env(
        self, isolated_dirs, tiny_enex, monkeypatch,
    ):
        # An operator on a single-user box may opt their full corpus into
        # search; the env var widens the cap. A garbled value must NOT widen
        # it (fail-safe to the default).
        monkeypatch.setenv("OSTLER_KNOWLEDGE_MAX_COMPARTMENT_LEVEL", "3")
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec, _binary="/x",
            _runner=Path("/runner.py"), _python="/usr/bin/python3",
        )
        embed_phase = rec.calls[0]["argv"]
        cap = embed_phase[embed_phase.index("--max-compartment-level") + 1]
        assert cap == "3"

        monkeypatch.setenv("OSTLER_KNOWLEDGE_MAX_COMPARTMENT_LEVEL", "garbled")
        rec2 = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec2, _binary="/x",
            _runner=Path("/runner.py"), _python="/usr/bin/python3",
        )
        embed2 = rec2.calls[0]["argv"]
        cap2 = embed2[embed2.index("--max-compartment-level") + 1]
        assert cap2 == "2", "garbled override must fall back to safe default"

    def test_source_param_selects_collection(self, isolated_dirs, tiny_enex):
        # A non-evernote source reuses the same path with its own
        # <source>_knowledge collection (forward-compat for Notion/Obsidian).
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, source="notion", _subprocess=rec,
            _binary="/usr/local/bin/ostler-knowledge",
            _runner=Path("/runner.py"), _python="/usr/bin/python3",
        )
        argv = rec.calls[0]["argv"]
        assert "notion" in argv[argv.index("--") + 1:argv.index("--and-then")]
        assert "notion_knowledge" in argv[argv.index("--and-then"):]

    def test_passes_start_new_session(self, isolated_dirs, tiny_enex):
        rec = _RecorderSubprocess()
        ie.start_import(
            tiny_enex, _subprocess=rec,
            _binary="/x", _runner=Path("/y"),
        )
        kwargs = rec.calls[0]["kwargs"]
        # Detaching the process so it survives Doctor restart is the
        # contract for "background-job survival" in the brief.
        assert kwargs.get("start_new_session") is True

    def test_409_when_lock_held(self, isolated_dirs, tiny_enex):
        # Plant a live lockfile under our current PID so the alive
        # check returns True.
        lock_path = isolated_dirs["lock_dir"] / ie.LOCK_FILENAME
        lock_path.write_text(json.dumps({
            "job_id": "20260513T100000Z-deadbeef",
            "pid": os.getpid(),
            "started_at": "2026-05-13T10:00:00+00:00",
        }))
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.start_import(
                tiny_enex, _subprocess=_RecorderSubprocess(),
                _binary="/x", _runner=Path("/y"),
            )
        assert ei.value.status == 409
        assert "in progress" in ei.value.detail

    def test_stale_lock_is_reclaimed(self, isolated_dirs, tiny_enex):
        lock_path = isolated_dirs["lock_dir"] / ie.LOCK_FILENAME
        lock_path.write_text(json.dumps({
            "job_id": "20260513T100000Z-deadbeef",
            "pid": 2**30,
            "started_at": "2026-05-13T10:00:00+00:00",
        }))
        rec = _RecorderSubprocess(pid=55555)
        out = ie.start_import(
            tiny_enex, _subprocess=rec,
            _binary="/x", _runner=Path("/y"),
        )
        # New job_id, and the lockfile now points at the new PID.
        assert out["status"] == "started"
        lock = json.loads(lock_path.read_text())
        assert lock["pid"] == 55555


# ---------------------------------------------------------------------------
# read_status
# ---------------------------------------------------------------------------


def _write_state(state_dir: Path, job_id: str, payload: Dict[str, Any]):
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / f"{ie.STATE_FILENAME_PREFIX}{job_id}.json"
    path.write_text(json.dumps(payload))
    return path


def _write_lock(lock_dir: Path, payload: Dict[str, Any]):
    lock_dir.mkdir(parents=True, exist_ok=True)
    path = lock_dir / ie.LOCK_FILENAME
    path.write_text(json.dumps(payload))
    return path


class TestReadStatus:

    def test_invalid_job_id_400(self, tmp_path):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.read_status("../etc/passwd")
        assert ei.value.status == 400

    def test_unknown_job_id_404(self, tmp_path):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.read_status(
                "20260513T120000Z-aabbccdd",
                _state_dir=tmp_path / "state",
                _lock_dir=tmp_path / "locks",
            )
        assert ei.value.status == 404

    def test_terminal_state_returned_verbatim(self, tmp_path):
        job_id = "20260513T120000Z-aabbccdd"
        state = {
            "job_id": job_id,
            "status": "succeeded",
            "exit_code": 0,
            "started_at": "2026-05-13T12:00:00+00:00",
            "completed_at": "2026-05-13T12:30:00+00:00",
            "log_path": "/tmp/log",
        }
        _write_state(tmp_path / "state", job_id, state)
        out = ie.read_status(
            job_id,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
        )
        assert out == state

    def test_running_synthesised_from_lockfile(self, tmp_path):
        job_id = "20260513T120000Z-aabbccdd"
        _write_lock(tmp_path / "locks", {
            "job_id": job_id,
            "pid": os.getpid(),
            "started_at": "2026-05-13T12:00:00+00:00",
            "log_path": "/tmp/log",
            "enex_path": "/tmp/x.enex",
        })
        out = ie.read_status(
            job_id,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
        )
        assert out["status"] == "running"
        assert out["job_id"] == job_id
        assert out["exit_code"] is None
        assert out["log_path"] == "/tmp/log"

    def test_dead_lock_no_state_synthesises_failed(self, tmp_path):
        job_id = "20260513T120000Z-aabbccdd"
        _write_lock(tmp_path / "locks", {
            "job_id": job_id,
            "pid": 2**30,
            "started_at": "2026-05-13T12:00:00+00:00",
            "log_path": "/tmp/log",
        })
        out = ie.read_status(
            job_id,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
            _now=datetime(2026, 5, 13, 12, 30, 0, tzinfo=timezone.utc),
        )
        assert out["status"] == "failed"
        assert out["completed_at"] == "2026-05-13T12:30:00+00:00"
        assert "runner exited" in out.get("note", "")

    def test_lockfile_for_different_job_id_404(self, tmp_path):
        _write_lock(tmp_path / "locks", {
            "job_id": "20260513T120000Z-DIFFREN1",
            "pid": os.getpid(),
            "started_at": "2026-05-13T12:00:00+00:00",
        })
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.read_status(
                "20260513T120000Z-aabbccdd",
                _state_dir=tmp_path / "state",
                _lock_dir=tmp_path / "locks",
            )
        assert ei.value.status == 404


# ---------------------------------------------------------------------------
# read_tail
# ---------------------------------------------------------------------------


class TestReadTail:

    def test_invalid_job_id_400(self):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.read_tail("not a real job id")
        assert ei.value.status == 400

    def test_unknown_job_id_404(self, tmp_path):
        with pytest.raises(ie.EvernoteImportError) as ei:
            ie.read_tail(
                "20260513T120000Z-aabbccdd",
                _state_dir=tmp_path / "state",
                _lock_dir=tmp_path / "locks",
            )
        assert ei.value.status == 404

    def test_returns_last_n_lines(self, tmp_path):
        log_path = tmp_path / "import.log"
        log_path.write_text("\n".join(f"line {i}" for i in range(200)))
        job_id = "20260513T120000Z-aabbccdd"
        _write_state(tmp_path / "state", job_id, {
            "job_id": job_id,
            "status": "succeeded",
            "log_path": str(log_path),
        })
        out = ie.read_tail(
            job_id, lines=50,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
        )
        assert out.count("\n") == 49
        assert out.endswith("line 199")
        assert "line 150" in out
        assert "line 149" not in out

    def test_log_file_missing_returns_empty(self, tmp_path):
        job_id = "20260513T120000Z-aabbccdd"
        _write_state(tmp_path / "state", job_id, {
            "job_id": job_id,
            "status": "succeeded",
            "log_path": str(tmp_path / "nonexistent.log"),
        })
        out = ie.read_tail(
            job_id,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
        )
        assert out == ""

    def test_running_job_uses_lockfile_log_path(self, tmp_path):
        log_path = tmp_path / "running.log"
        log_path.write_text("running line 1\nrunning line 2\n")
        job_id = "20260513T120000Z-aabbccdd"
        _write_lock(tmp_path / "locks", {
            "job_id": job_id,
            "pid": os.getpid(),
            "started_at": "2026-05-13T12:00:00+00:00",
            "log_path": str(log_path),
        })
        out = ie.read_tail(
            job_id,
            _state_dir=tmp_path / "state",
            _lock_dir=tmp_path / "locks",
        )
        assert "running line 1" in out
        assert "running line 2" in out


# ---------------------------------------------------------------------------
# FastAPI route integration
# ---------------------------------------------------------------------------


@pytest.fixture
def fastapi_client(monkeypatch, isolated_dirs):
    """Spin up FastAPI's TestClient against the real Doctor app.

    Patches the subprocess module so POST /api/v1/import/evernote does
    not actually fork ostler-knowledge. The recorder is exposed via
    the returned tuple so tests can assert on the captured argv.
    """
    from fastapi.testclient import TestClient
    import web_ui

    # Use the test process's own PID so the lockfile's liveness probe
    # passes -- the real subprocess is mocked, so without this the
    # stub PID would always read as dead and read_status would mark
    # the job as failed.
    rec = _RecorderSubprocess(pid=os.getpid())
    monkeypatch.setattr(ie, "subprocess", rec)
    monkeypatch.setattr(
        ie, "DEFAULT_OSTLER_KNOWLEDGE_BIN", "/tmp/fake-ostler-knowledge",
    )

    client = TestClient(web_ui.app)
    return client, rec


# ── 3 flag-gate tests (required by brief) ───────────────────────────


def test_evernote_import_off_returns_404_on_get(features_off, fastapi_client):
    """Flag off → GET /import-evernote returns 404."""
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    assert resp.status_code == 404
    assert resp.json() == {"error": "feature_disabled"}


def test_evernote_import_off_returns_404_on_post(features_off, fastapi_client, tiny_enex):
    """Flag off → POST /api/v1/import/evernote returns 404 even with a
    valid body. The flag must short-circuit BEFORE validation so the
    customer sees a uniform 404 regardless of input correctness."""
    client, _ = fastapi_client
    resp = client.post(
        "/api/v1/import/evernote",
        json={"enex_path": str(tiny_enex)},
    )
    assert resp.status_code == 404
    assert resp.json() == {"error": "feature_disabled"}


def test_evernote_import_on_renders_page(features_on, fastapi_client):
    """Flag on -> GET /import-evernote returns 200 + the page HTML."""
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    assert resp.status_code == 200
    assert "Import Evernote" in resp.text
    assert resp.headers["content-type"].startswith("text/html")


# ── Block 3.4 UI render tests ────────────────────────────────────────


def test_page_renders_form_when_no_active_job(features_on, fastapi_client, isolated_dirs):
    """Flag on + no lockfile -> the page boots in form mode.

    The server passes ``null`` to ``INITIAL_JOB_ID`` so the JS shows
    the path-input form rather than the reattach panel. The form
    element + the input id must appear in the rendered HTML so an
    operator on a fresh page can paste a path and submit.
    """
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    assert resp.status_code == 200
    body = resp.text
    assert 'id="importForm"' in body
    assert 'id="enexPath"' in body
    # INITIAL_JOB_ID = null means the JS hits the showForm() branch.
    assert "const INITIAL_JOB_ID = null" in body


def test_page_reattaches_when_lockfile_alive(features_on, fastapi_client, isolated_dirs):
    """Flag on + alive lockfile -> the page boots straight into the
    polling panel by embedding the job_id into the JS bootstrap.

    Reattach is the brief's spec for the "customer closed the tab
    mid-import" case. The job_id must be JSON-escaped (string literal)
    so the JS const is valid even if some future job_id format
    contains characters that would otherwise terminate the literal.
    """
    job_id = "20260513T120000Z-abcdef01"
    _write_lock(isolated_dirs["lock_dir"], {
        "job_id": job_id,
        "pid": os.getpid(),
        "started_at": "2026-05-13T12:00:00+00:00",
        "log_path": "/tmp/log",
        "enex_path": "/tmp/x.enex",
    })
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    assert resp.status_code == 200
    body = resp.text
    # The bootstrap line embeds the job_id as a JS string literal.
    assert f'const INITIAL_JOB_ID = "{job_id}"' in body


def test_page_does_not_reattach_to_stale_lockfile(features_on, fastapi_client, isolated_dirs):
    """Flag on + dead lockfile -> the page boots in form mode, not
    reattach mode. A stale lock pointing to a dead PID has already
    been "abandoned"; the next import will reclaim it. The UI should
    not pretend the abandoned job is still running."""
    _write_lock(isolated_dirs["lock_dir"], {
        "job_id": "20260513T120000Z-deaddead",
        "pid": 2**30,  # safely dead
        "started_at": "2026-05-13T12:00:00+00:00",
    })
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    assert resp.status_code == 200
    assert "const INITIAL_JOB_ID = null" in resp.text


def test_page_polling_cadence_matches_brief(features_on, fastapi_client):
    """The launch-scope brief mandates status polled every 5s, tail
    every 10s. Bake those values into the JS contract so a future
    accidental edit fails this test rather than silently degrading
    the UX during a long import."""
    client, _ = fastapi_client
    resp = client.get("/import-evernote")
    body = resp.text
    assert "const STATUS_POLL_MS = 5000" in body
    assert "const TAIL_POLL_MS = 10000" in body


def test_render_dashboard_omits_link_when_flag_off():
    """Direct render-dashboard contract test. The footer link to
    /import-evernote must only appear when the caller passes
    import_evernote_enabled=True. Tested at the renderer rather than
    via the route to keep the assertion narrow.
    """
    import web_ui as wu
    from status_collector import SystemSnapshot
    snapshot = SystemSnapshot(
        timestamp="2026-05-13T12:00:00", hostname="test-host",
        os_version="darwin 25", docker_version=None, ollama_version=None,
        docker_containers=[], ollama_models=[], services=[],
        disk_usage=[], network_checks=[],
    )
    off = wu.render_dashboard(snapshot, [], import_evernote_enabled=False)
    on = wu.render_dashboard(snapshot, [], import_evernote_enabled=True)
    assert '/import-evernote' not in off
    assert '/import-evernote' in on
    assert 'Import Evernote' in on


# ── 3 endpoint integration tests (required by brief) ─────────────────


def test_post_starts_import_returns_job_id(features_on, fastapi_client, tiny_enex):
    """Flag on + valid path → 200 + ``{job_id, status: "started"}`` and
    the lockfile lands on disk so a subsequent GET /status reattaches."""
    client, rec = fastapi_client
    resp = client.post(
        "/api/v1/import/evernote",
        json={"enex_path": str(tiny_enex)},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "started"
    assert body["job_id"].startswith("2") and len(body["job_id"]) == 25
    # The recorder captured the runner argv.
    assert len(rec.calls) == 1
    argv = rec.calls[0]["argv"]
    assert any(str(tiny_enex) in arg for arg in argv)
    # GET /status reattaches via the lockfile.
    status_resp = client.get(f"/api/v1/import/evernote/{body['job_id']}/status")
    assert status_resp.status_code == 200
    assert status_resp.json()["status"] == "running"


def test_post_invalid_path_returns_400(features_on, fastapi_client, tmp_path):
    """Flag on + non-existent path → 400 with a descriptive error.
    Tests the validate_enex_path -> EvernoteImportError -> JSON 400
    pipeline end-to-end."""
    client, _ = fastapi_client
    resp = client.post(
        "/api/v1/import/evernote",
        json={"enex_path": str(tmp_path / "does-not-exist.enex")},
    )
    assert resp.status_code == 400
    assert "not found" in resp.json()["error"]


def test_post_while_lock_held_returns_409(
    features_on, fastapi_client, isolated_dirs, tiny_enex,
):
    """Flag on + live lockfile → 409. Background-job survival means a
    customer who closed their tab mid-import must not be able to
    accidentally double-start the importer."""
    _write_lock(isolated_dirs["lock_dir"], {
        "job_id": "20260513T100000Z-aabbccdd",
        "pid": os.getpid(),
        "started_at": "2026-05-13T10:00:00+00:00",
    })
    client, _ = fastapi_client
    resp = client.post(
        "/api/v1/import/evernote",
        json={"enex_path": str(tiny_enex)},
    )
    assert resp.status_code == 409
    assert "in progress" in resp.json()["error"]


# ── Bonus: GET status + tail end-to-end ──────────────────────────────


def test_get_status_flag_off_returns_404(features_off, fastapi_client):
    client, _ = fastapi_client
    resp = client.get("/api/v1/import/evernote/20260513T120000Z-aabbccdd/status")
    assert resp.status_code == 404
    assert resp.json() == {"error": "feature_disabled"}


def test_get_tail_flag_off_returns_404(features_off, fastapi_client):
    client, _ = fastapi_client
    resp = client.get("/api/v1/import/evernote/20260513T120000Z-aabbccdd/tail")
    assert resp.status_code == 404


def test_get_status_invalid_job_id_400(features_on, fastapi_client):
    client, _ = fastapi_client
    resp = client.get("/api/v1/import/evernote/..%2Fetc%2Fpasswd/status")
    # FastAPI rejects the percent-encoded slash before our handler
    # sees it (404 in the routing layer). Either 400 from us or 404
    # from FastAPI is acceptable -- the contract is "no traversal".
    assert resp.status_code in (400, 404)


def test_get_tail_returns_plain_text(
    features_on, fastapi_client, isolated_dirs, tmp_path,
):
    log_path = tmp_path / "actual.log"
    log_path.write_text("one\ntwo\nthree\n")
    job_id = "20260513T120000Z-aabbccdd"
    _write_state(isolated_dirs["state_dir"], job_id, {
        "job_id": job_id,
        "status": "succeeded",
        "log_path": str(log_path),
    })
    client, _ = fastapi_client
    resp = client.get(f"/api/v1/import/evernote/{job_id}/tail")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    assert "one" in resp.text
    assert "three" in resp.text


# ---------------------------------------------------------------------------
# Supervisor wrapper (import_evernote_runner.py)
# ---------------------------------------------------------------------------


class TestRunner:
    """Drive the supervisor wrapper by running it as a real subprocess.

    The wrapper is stdlib-only so it can run inside any Doctor venv.
    Exercising it as a real subprocess covers argparse + atomic write
    + lockfile removal in one shot.
    """

    @staticmethod
    def _runner_argv(state, lock, job_id, log_path, enex_path, started_at, cmd):
        return [
            sys.executable,
            str(Path(ie.__file__).parent / "import_evernote_runner.py"),
            "--state", str(state),
            "--lock", str(lock),
            "--job-id", job_id,
            "--log-path", str(log_path),
            "--enex-path", str(enex_path),
            "--started-at", started_at,
            "--",
            *cmd,
        ]

    def test_succeeded_writes_state_and_removes_lock(self, tmp_path):
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        log_path = tmp_path / "log.log"
        log_path.write_text("")
        argv = self._runner_argv(
            state, lock,
            "20260513T120000Z-aabbccdd",
            log_path, "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", ""],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        assert state.is_file()
        data = json.loads(state.read_text())
        assert data["status"] == "succeeded"
        assert data["exit_code"] == 0
        assert data["job_id"] == "20260513T120000Z-aabbccdd"
        assert "completed_at" in data
        assert not lock.exists()

    def test_failed_writes_failed_state(self, tmp_path):
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        argv = self._runner_argv(
            state, lock,
            "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", "raise SystemExit(1)"],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        # The wrapper exits with the same code as the wrapped command
        # so launchd / supervisor scripts can chain on its exit code.
        assert result.returncode == 1
        data = json.loads(state.read_text())
        assert data["status"] == "failed"
        assert data["exit_code"] == 1
        assert not lock.exists()

    def test_command_not_found_writes_127(self, tmp_path):
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        argv = self._runner_argv(
            state, lock,
            "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [str(tmp_path / "definitely-not-installed")],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        assert result.returncode == 127
        data = json.loads(state.read_text())
        assert data["status"] == "failed"
        assert data["exit_code"] == 127
        assert not lock.exists()

    def test_two_phases_run_in_sequence_on_success(self, tmp_path):
        # convert --and-then embed: both phases run when the first
        # exits 0. Each phase touches a marker so we can prove ordering.
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        m1 = tmp_path / "phase1.marker"
        m2 = tmp_path / "phase2.marker"
        argv = self._runner_argv(
            state, lock, "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", f"open(r'{m1}','w').close()",
             "--and-then",
             sys.executable, "-c", f"open(r'{m2}','w').close()"],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        assert m1.exists() and m2.exists(), "both phases must run on success"
        data = json.loads(state.read_text())
        assert data["status"] == "succeeded"
        assert data["phases_total"] == 2
        assert data["phase_index"] == 1

    def test_second_phase_skipped_when_first_fails(self, tmp_path):
        # The whole point of the chain: a failed convert must NOT run
        # embed against a half-written staging tree.
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        m2 = tmp_path / "phase2.marker"
        argv = self._runner_argv(
            state, lock, "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", "raise SystemExit(3)",
             "--and-then",
             sys.executable, "-c", f"open(r'{m2}','w').close()"],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        assert result.returncode == 3
        assert not m2.exists(), "embed must NOT run when convert fails"
        data = json.loads(state.read_text())
        assert data["status"] == "failed"
        assert data["exit_code"] == 3
        assert data["phase_index"] == 0

    def test_last_phase_failure_degrades_to_partial(self, tmp_path):
        # convert succeeds, embed (last phase) fails -> the notes ARE
        # imported, only search indexing failed (Qdrant/Ollama down). That
        # is a degraded success, NOT a hard failure: status must be
        # 'partial' with a human note, so Doctor shows amber + "search
        # pending" rather than red "failed".
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        m1 = tmp_path / "phase1.marker"
        argv = self._runner_argv(
            state, lock, "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", f"open(r'{m1}','w').close()",
             "--and-then",
             sys.executable, "-c", "raise SystemExit(4)"],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        # Wrapper still propagates the real exit code for supervisors.
        assert result.returncode == 4
        assert m1.exists(), "convert (phase 1) must have run"
        data = json.loads(state.read_text())
        assert data["status"] == "partial", (
            "embed-phase failure after a good convert is a degraded "
            "success, not a hard failure"
        )
        assert data["exit_code"] == 4
        assert data["phase_index"] == 1
        assert data["phases_total"] == 2
        assert data.get("note"), "partial state must carry a human note"
        assert not lock.exists()

    def test_single_phase_failure_stays_failed(self, tmp_path):
        # A single-phase run (no --and-then) keeps the original contract:
        # a non-zero exit is a hard failure, never 'partial'. Guards against
        # the degrade logic leaking into the back-compatible one-command path.
        import subprocess as real_sub
        state = tmp_path / "state.json"
        lock = tmp_path / "import-evernote.lock"
        lock.write_text("placeholder")
        argv = self._runner_argv(
            state, lock, "20260513T120000Z-aabbccdd",
            tmp_path / "log.log", "/tmp/x.enex",
            "2026-05-13T12:00:00+00:00",
            [sys.executable, "-c", "raise SystemExit(2)"],
        )
        result = real_sub.run(argv, capture_output=True, timeout=10)
        assert result.returncode == 2
        data = json.loads(state.read_text())
        assert data["status"] == "failed"
        assert data["phases_total"] == 1
