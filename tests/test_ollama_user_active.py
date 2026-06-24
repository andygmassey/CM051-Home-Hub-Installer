#!/usr/bin/env python3
"""Tests for the cross-process user-active lease reader (CM051 vendor copy).

Background Ollama callers in the enrichment pipeline (cm048) and the
knowledge package (cm024) read a lease file the daemon refreshes on every
foreground chat turn, and yield while the user is active. This proves the
reader contract for the vendored helper:

(a) a fresh lease in the future causes a wait;
(b) a stale / absent / garbage lease returns immediately (crash-safe);
(c) a far-future (stuck) lease never deadlocks the batch -- max_wait caps it.

The two vendor copies (cm048_pipeline, cm024_knowledge) are byte-identical,
so testing one proves both; we load the cm048 copy by file path to avoid
package-import gymnastics.
"""
from __future__ import annotations

import importlib.util
import time
from pathlib import Path

import pytest

# Load the vendored helper directly by path (the two copies are identical).
_REPO = Path(__file__).resolve().parent.parent
_HELPER = _REPO / "vendor" / "cm048_pipeline" / "src" / "ollama_user_active.py"
_spec = importlib.util.spec_from_file_location("ollama_user_active_cm051", _HELPER)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)  # type: ignore[union-attr]
wait_until_user_idle = _mod.wait_until_user_idle


def test_copies_are_identical():
    """The cm048 and cm024 vendor copies must not drift."""
    other = _REPO / "vendor" / "cm024_knowledge" / "src" / "ollama_user_active.py"
    assert _HELPER.read_text() == other.read_text()


# (a) fresh lease in the future => waits
def test_future_lease_waits(tmp_path):
    lease = tmp_path / "ollama-user-active"
    lease.write_text(str(int((time.time() + 1.0) * 1000)), encoding="utf-8")

    start = time.monotonic()
    waited = wait_until_user_idle(poll=0.05, max_wait=3.0, path=lease)
    elapsed = time.monotonic() - start

    assert waited > 0.0
    assert elapsed >= 0.2


# (c) far-future lease must not deadlock
def test_future_lease_respects_max_wait(tmp_path):
    lease = tmp_path / "ollama-user-active"
    lease.write_text(str(int((time.time() + 3600) * 1000)), encoding="utf-8")

    start = time.monotonic()
    waited = wait_until_user_idle(poll=0.05, max_wait=0.3, path=lease)
    elapsed = time.monotonic() - start

    assert waited <= 0.5
    assert elapsed < 1.0


# (b) stale / absent / garbage => immediate
def test_absent_lease_returns_immediately(tmp_path):
    waited = wait_until_user_idle(poll=0.5, max_wait=5.0, path=tmp_path / "nope")
    assert waited == 0.0


def test_stale_lease_returns_immediately(tmp_path):
    lease = tmp_path / "ollama-user-active"
    lease.write_text(str(int((time.time() - 10) * 1000)), encoding="utf-8")
    assert wait_until_user_idle(poll=0.5, max_wait=5.0, path=lease) == 0.0


def test_garbage_lease_returns_immediately(tmp_path):
    lease = tmp_path / "ollama-user-active"
    lease.write_text("not-a-number", encoding="utf-8")
    assert wait_until_user_idle(poll=0.5, max_wait=5.0, path=lease) == 0.0


def test_empty_lease_returns_immediately(tmp_path):
    lease = tmp_path / "ollama-user-active"
    lease.write_text("", encoding="utf-8")
    assert wait_until_user_idle(poll=0.5, max_wait=5.0, path=lease) == 0.0


# (c) num_ctx present on the cm048 request body + lease checked before POST
def test_cm048_generate_sets_num_ctx_and_checks_lease(monkeypatch):
    import sys

    pkg_src = _REPO / "vendor" / "cm048_pipeline" / "src"
    sys.path.insert(0, str(pkg_src.parent))
    # Import as a package so the relative `from .ollama_user_active` works.
    import importlib
    oc = importlib.import_module("src.ollama_client")

    captured = {}

    class _FakeResp:
        def raise_for_status(self):
            return None

        def json(self):
            return {"response": "ok"}

    class _FakeClient:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def post(self, url, json):  # noqa: A002 - mirror httpx kwarg
            captured["body"] = json
            return _FakeResp()

    monkeypatch.setattr(oc.httpx, "Client", _FakeClient)
    waited_calls = {"n": 0}
    monkeypatch.setattr(
        oc, "wait_until_user_idle", lambda *a, **k: waited_calls.__setitem__("n", waited_calls["n"] + 1)
    , raising=False)
    # wait_until_user_idle is imported inside generate(); patch the source module too.
    import src.ollama_user_active as oua
    monkeypatch.setattr(oua, "wait_until_user_idle", lambda *a, **k: waited_calls.__setitem__("n", waited_calls["n"] + 1))

    client = oc.OllamaClient(base_url="http://127.0.0.1:65535")
    out = client.generate("test-model", "hello")

    assert out.raw_response == "ok"
    assert captured["body"]["options"]["num_ctx"] == 32768
    assert waited_calls["n"] == 1
