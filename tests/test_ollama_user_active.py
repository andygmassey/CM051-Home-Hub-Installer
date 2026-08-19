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


# ─── Tier-aware enrichment context budget ─────────────────────────────────
#
# THE DEFECT THESE PROVE. The first version of this PR hardcoded
# num_ctx=32768 at all three background call sites. install.sh detects a
# resource tier and sets OSTLER_ENRICH_NUM_CTX per tier: unset on `high`
# (>=32 GB), 8192 on `low`, 4096 on `floor`. A 16 GB Mac is `low`, and 16 GB
# is the installer's HARD MINIMUM (ERR-02-PREREQ-RAM-LOW), so the BASELINE
# supported machine wants 8192 here. The hardcoded literal asked the smallest
# supported box for four times its own budget, in the code path added to be
# polite about resources.
#
# Every assertion below FAILS against that literal.

resolve_enrich_num_ctx = _mod.resolve_enrich_num_ctx


def test_low_tier_budget_is_honoured(monkeypatch):
    """16 GB Mac = tier `low` = 8192. The literal 32768 fails this."""
    monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "8192")
    assert resolve_enrich_num_ctx() == 8192


def test_floor_tier_budget_is_honoured(monkeypatch):
    monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "4096")
    assert resolve_enrich_num_ctx() == 4096


def test_high_tier_empty_means_no_reduction(monkeypatch):
    """`high` sets the variable to EMPTY on purpose: fall back to the daemon's
    own default so foreground and background agree and Ollama never reloads."""
    monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "")
    assert resolve_enrich_num_ctx() == 32768


def test_unset_falls_back_to_daemon_default(monkeypatch):
    monkeypatch.delenv("OSTLER_ENRICH_NUM_CTX", raising=False)
    assert resolve_enrich_num_ctx() == 32768


def test_garbage_budget_does_not_shrink_the_window(monkeypatch):
    """A malformed budget must not silently truncate the prompt. Ollama
    truncates SILENTLY, so failing open to the larger window is the safe
    direction here."""
    monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "not-a-number")
    assert resolve_enrich_num_ctx() == 32768


def test_absurdly_small_budget_is_refused(monkeypatch):
    """Mirrors the daemon's own >=2048 floor so the two halves cannot
    disagree about what 'too small' means."""
    monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "512")
    assert resolve_enrich_num_ctx() == 32768


def test_cm048_request_body_carries_the_tier_budget(monkeypatch):
    """End-to-end on the real request body: the 8192 budget must reach the
    wire. This is the assertion the hardcoded literal cannot pass."""
    import sys

    pkg_src = _REPO / "vendor" / "cm048_pipeline" / "src"
    sys.path.insert(0, str(pkg_src.parent))
    try:
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
        import src.ollama_user_active as oua
        monkeypatch.setattr(oua, "wait_until_user_idle", lambda *a, **k: 0.0)
        monkeypatch.setenv("OSTLER_ENRICH_NUM_CTX", "8192")

        client = oc.OllamaClient(base_url="http://127.0.0.1:65535")
        client.generate("test-model", "hello")

        assert captured["body"]["options"]["num_ctx"] == 8192
    finally:
        # Leaving this on sys.path pollutes every later test in the session
        # with a generic `src` package. That exact class of leak cost a whole
        # debugging session on HR015 #427.
        if str(pkg_src.parent) in sys.path:
            sys.path.remove(str(pkg_src.parent))
