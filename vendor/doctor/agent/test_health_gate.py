#!/usr/bin/env python3
"""Tests for the test-only OSTLER_TEST_DISABLE_HEALTH gate on the Doctor
health route (``GET /doctor/api/health``).

The (B-lite) upgrade brain (C1, ``upgrade_reconcile.rs``) polls the Doctor
health route for 60s after install.sh runs and rolls back if it never
returns 2xx. Matrix Row 6 needs to prove "install.sh exits 0 but the
daemon will not answer health, so the 60s poll times out and rollback
fires". To make that deterministic the health handler returns 503 when
``OSTLER_TEST_DISABLE_HEALTH == "1"``.

These tests prove three things:
  1. Env unset, the route is the unchanged 200 healthy body.
  2. ``OSTLER_TEST_DISABLE_HEALTH=1``, the route returns 503.
  3. Any other value (e.g. "0"), the route is 200 (only exactly "1" trips).

Everything is synthetic (PRODUCTISATION_CHECKLIST Rule 0): an in-process
FastAPI TestClient, no real daemon and no network.

Run: ``python3 -m pytest vendor/doctor/agent/test_health_gate.py -q``
(needs ``fastapi`` and ``httpx`` for TestClient) or bare
``python3 vendor/doctor/agent/test_health_gate.py``.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fastapi.testclient import TestClient  # noqa: E402

import web_ui  # noqa: E402

_ENV_VAR = "OSTLER_TEST_DISABLE_HEALTH"
_HEALTH_URL = "/doctor/api/health"

client = TestClient(web_ui.app)


def test_health_default_unset_returns_200(monkeypatch):
    """Env unset, exactly the original healthy body and a 200."""
    monkeypatch.delenv(_ENV_VAR, raising=False)
    resp = client.get(_HEALTH_URL)
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy", "service": "ostler-doctor"}


def test_health_gate_on_returns_503(monkeypatch):
    """OSTLER_TEST_DISABLE_HEALTH=1, the route returns 503 (Row 6 proof)."""
    monkeypatch.setenv(_ENV_VAR, "1")
    resp = client.get(_HEALTH_URL)
    assert resp.status_code == 503
    assert resp.json() == {
        "status": "unavailable",
        "service": "ostler-doctor",
        "test_gate": _ENV_VAR,
    }


def test_health_gate_non_one_returns_200(monkeypatch):
    """Any value other than exactly "1" is a no-op, so the route stays 200."""
    monkeypatch.setenv(_ENV_VAR, "0")
    resp = client.get(_HEALTH_URL)
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy", "service": "ostler-doctor"}


if __name__ == "__main__":
    import subprocess

    raise SystemExit(
        subprocess.call(
            [sys.executable, "-m", "pytest", __file__, "-q"]
        )
    )
