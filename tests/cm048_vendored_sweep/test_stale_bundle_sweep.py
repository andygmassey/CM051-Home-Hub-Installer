"""The stale-bundle sweep can never hang the pipeline.

THE DEFECT (measured on the v1.0.111 walk box)
-----------------------------------------------
After step 09 wrote the bundle, ``_remove_stale_bundle_folders`` ran
``Path(root).glob("*/*-<short id>")`` over EVERY date folder under
~/Documents/Ostler/Conversations. Under the Hub's launchd agent an
opendir on a folder carrying a com.apple.macl label blocks forever
(os_scandir -> __opendir2 -> open$NOCANCEL), so ``pwg-convo process``
never exited, the Hub's 900s subprocess timeout fired, and the
conversation was marked failed although its bundle had been written.

WHAT THIS FILE PINS
-------------------
(a) A sweep whose filesystem access blocks forever cannot stop
    ``process()`` returning with the state recorded as complete.
(b) A relocated bundle (a participant joined, so the folder name
    changed) still loses its old artefacts, found from the recorded
    location, with the conversations tree unlistable.
(c) A different conversation sharing the 8-hex suffix is untouched.
(d) Nothing lists the conversations root or anything under it.
(e) The sweep thread is a daemon: a stuck sweep cannot hold the CLI
    process open at interpreter exit.

The environment the defect lives in is "listing the conversations tree
does not return". Every test except (d) models it as a listing that
raises or blocks; (d) records listings instead, so a single one fails it.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

from src import processor
from test_update_reprocess import (  # noqa: F401  (pytest fixtures)
    CONV_ID,
    V1,
    V2,
    _metadata,
    bundle_files,
    fakes,
    run,
    settings,
)

# CM051 port: the vendored tree, so test (e) imports the SHIPPED processor.
REPO = Path(__file__).resolve().parent.parent.parent / "vendor" / "cm048_pipeline"


def _under(path, root: Path) -> bool:
    if isinstance(path, int) or path is None:
        return False
    try:
        p = Path(os.fsdecode(path)).absolute()
    except TypeError:
        return False
    return p == root or root in p.parents


class ListingGuard:
    """Intercepts every way Python lists a directory, for paths at or
    under the conversations root. ``mode`` is "record", "raise" or
    "block" (sleep on an Event nobody sets during the test)."""

    def __init__(self, monkeypatch, root: Path, mode: str):
        self.root = root.absolute()
        self.mode = mode
        self.calls: list[str] = []
        self.never = threading.Event()
        for owner, name in (
            (Path, "glob"), (Path, "rglob"), (Path, "iterdir"),
            (os, "scandir"), (os, "listdir"), (os, "walk"),
        ):
            real = getattr(owner, name)
            monkeypatch.setattr(owner, name, self._wrap(real, name, owner is Path))

    def _wrap(self, real, name, is_method):
        guard = self

        def wrapper(*args, **kwargs):
            target = args[0] if args else kwargs.get("path", kwargs.get("top", "."))
            if _under(target, guard.root):
                guard.calls.append(f"{name}({target})")
                if guard.mode == "raise":
                    raise PermissionError(f"opendir refused: {target}")
                if guard.mode == "block":
                    guard.never.wait()
            return real(*args, **kwargs)

        return wrapper


@pytest.fixture
def release_blocked():
    events: list[threading.Event] = []
    yield events
    # Only so leaked daemon threads finish after the test, never during it.
    for e in events:
        e.set()


def _grow(md: dict) -> dict:
    md["participants"].append({"id": "other:sam", "display": "Sam", "role": "other"})
    return md


def _folders(settings) -> set[Path]:
    return {p.parent for p in settings.output_conversations_dir.glob("*/*/summary.md")}


def _run_in_thread(fn, limit: float):
    box: dict = {}

    def target():
        try:
            box["value"] = fn()
        except BaseException as exc:  # surfaced below
            box["error"] = exc

    t = threading.Thread(target=target, daemon=True)
    start = time.monotonic()
    t.start()
    t.join(limit)
    return t.is_alive(), time.monotonic() - start, box


# (a) ─────────────────────────────────────────────────────────────────


def test_a_sweep_that_blocks_forever_cannot_stop_process_returning(
    fakes, settings, monkeypatch, release_blocked
):
    run(settings, V1)
    (old,) = _folders(settings)
    root = settings.output_conversations_dir

    # Every listing of the tree blocks (the measured macl opendir), and so
    # does any read of the OLD bundle's files (the sweep's own access).
    guard = ListingGuard(monkeypatch, root, "block")
    release_blocked.append(guard.never)
    real_read_text = Path.read_text

    def read_text(self, *a, **k):
        if old in Path(self).absolute().parents:
            guard.never.wait()
        return real_read_text(self, *a, **k)

    monkeypatch.setattr(Path, "read_text", read_text)

    alive, elapsed, box = _run_in_thread(
        lambda: processor.process(CONV_ID, V2, _grow(_metadata()), settings), 30
    )
    assert not alive, "process() never returned: the sweep hung the pipeline"
    assert "error" not in box, box.get("error")
    state = box["value"]
    assert state.failed_step is None, state.failure_reason
    assert "09_bundle" in state.completed_steps
    assert elapsed < 15, f"process() took {elapsed:.1f}s"
    on_disk = json.loads(
        (settings.processing_state_dir / CONV_ID / "state.json").read_text()
    )
    assert on_disk["failed_step"] is None
    assert "09_bundle" in on_disk["completed_steps"]


# (b) ─────────────────────────────────────────────────────────────────


def test_b_relocated_bundle_is_removed_from_its_recorded_location(
    fakes, settings, monkeypatch
):
    run(settings, V1)
    (old,) = _folders(settings)
    guard = ListingGuard(monkeypatch, settings.output_conversations_dir, "raise")
    run(settings, V2, participants=_grow(_metadata())["participants"])
    monkeypatch.undo()
    assert guard.calls == []
    assert not old.exists(), sorted(p.name for p in old.iterdir())
    (new,) = _folders(settings)
    assert new != old
    assert "Room 4B" in (new / "summary.md").read_text()


# (c) ─────────────────────────────────────────────────────────────────


def test_c_another_conversation_sharing_the_suffix_is_untouched(
    fakes, settings, monkeypatch
):
    run(settings, V1)
    (old,) = _folders(settings)
    # A different conversation whose folder ends in the same 8-hex suffix,
    # in the same date folder (a short-id collision, synthesised).
    other = old.parent / f"someone-else{old.name[old.name.rindex('-'):]}"
    other.mkdir()
    body = '---\nconversation_id: "a-different-conversation"\n---\nsynthetic\n'
    for name in ("summary.md", "transcript.md", "todos.md"):
        (other / name).write_text(body)

    ListingGuard(monkeypatch, settings.output_conversations_dir, "raise")
    run(settings, V2, participants=_grow(_metadata())["participants"])
    monkeypatch.undo()

    assert not old.exists()
    for name in ("summary.md", "transcript.md", "todos.md"):
        assert (other / name).read_text() == body


# (d) ─────────────────────────────────────────────────────────────────


def test_d_nothing_lists_the_conversations_tree(fakes, settings, monkeypatch):
    guard = ListingGuard(monkeypatch, settings.output_conversations_dir, "record")
    run(settings, V1)
    run(settings, V2, participants=_grow(_metadata())["participants"])
    monkeypatch.undo()
    assert guard.calls == []
    assert len(_folders(settings)) == 1


def test_d_no_record_means_no_sweep_and_no_listing(fakes, settings, monkeypatch, caplog):
    """A state dir from before the location was recorded: nothing to go
    on, so nothing is removed and the tree is never listed to find it."""
    run(settings, V1)
    (old,) = _folders(settings)
    (settings.processing_state_dir / CONV_ID / processor.BUNDLE_LOCATION_FILE).unlink()
    guard = ListingGuard(monkeypatch, settings.output_conversations_dir, "record")
    caplog.set_level("INFO", logger=processor.logger.name)
    run(settings, V2, participants=_grow(_metadata())["participants"])
    monkeypatch.undo()
    assert guard.calls == []
    assert old.exists()
    assert "no recorded earlier bundle location" in caplog.text


# (e) ─────────────────────────────────────────────────────────────────


def test_e_a_stuck_sweep_thread_cannot_hold_the_process_open(tmp_path):
    script = (
        "import threading, sys\n"
        "from src import processor\n"
        "processor._STALE_SWEEP_TIMEOUT_SECONDS = 0.5\n"
        "never = threading.Event()\n"
        "processor._remove_stale_bundle_folders = lambda *a, **k: never.wait()\n"
        "processor._sweep_stale_bundles_bounded(\n"
        "    sys.argv[1], 'c', [sys.argv[1] + '/x/y'], keep=sys.argv[1] + '/x/z')\n"
        "print('returned', flush=True)\n"
    )
    start = time.monotonic()
    try:
        out = subprocess.run(
            [sys.executable, "-c", script, str(tmp_path)],
            cwd=REPO, capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        pytest.fail("interpreter did not exit: the sweep thread is not a daemon")
    assert out.returncode == 0, out.stderr
    assert "returned" in out.stdout
    assert time.monotonic() - start < 15
