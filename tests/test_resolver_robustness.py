"""Robustness / safety-net tests for IdentityResolver (#660, CX-126).

The O(n^2) `_fuzzy_match` scan can stall a large LinkedIn/Facebook import to
the 30s httpx timeout. TNM's in-memory candidate index removes the *trigger*;
this safety net guarantees that IF a resolver query ever fails anyway (timeout,
transport error, Oxigraph 5xx), the contact is NOT dropped by the import loop -
it degrades to "create as new" (a recoverable possible-duplicate) and the
degradation is logged and counted, never silent.

These tests drive the real resolver and mock only the network boundary
(`_client.post`). No real services, synthetic identities only (Rule 0).

Vendored into CM051 from CM041 9065c40 (the robustness half of CX-126). The
only change from the CM041-main copy is the sys.path shim below, which points
at the vendored `identity_resolver` package -- the divergent-twin discipline:
graft the diff, do not clean-re-vendor.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041"))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402


def _resolver_with_post(monkeypatch, side_effect):
    r = IdentityResolver("http://localhost:7878")
    monkeypatch.setattr(r._client, "post", side_effect)
    return r


class _FakeResp:
    """Minimal stand-in for an httpx.Response returning empty bindings."""

    def raise_for_status(self) -> None:  # noqa: D401 - matches httpx API
        return None

    def json(self) -> dict:
        return {"results": {"bindings": []}}


def test_fuzzy_tier_timeout_degrades_to_new_not_dropped(monkeypatch):
    """A timeout in the Tier-3 fuzzy query (the O(n^2) culprit) must not raise:
    the contact becomes a new person, preserved, and counted as degraded."""

    def boom(*_a, **_k):
        raise httpx.TimeoutException("simulated slow oxigraph")

    r = _resolver_with_post(monkeypatch, boom)
    # display_name only -> no strong identifiers -> reaches the fuzzy tier.
    ident = PersonIdentity(display_name="Mhairi Geraghty")

    result = r.resolve(ident)

    assert result.match_type == "new"  # created, NOT dropped
    assert result.person_uri is None
    assert "degraded" in result.details.lower()
    assert r.stats == {"total": 1, "degraded": 1}


def test_identifier_tier_timeout_also_degrades(monkeypatch):
    """Tier-1/2 identifier lookups sit outside TNM's fuzzy index, so the net
    must cover them too: an email-bearing contact whose find_by_identifier
    times out still degrades to new rather than dropping."""

    def boom(*_a, **_k):
        raise httpx.TimeoutException("simulated slow oxigraph")

    r = _resolver_with_post(monkeypatch, boom)
    ident = PersonIdentity(display_name="X Person", emails=["x@example.com"])

    result = r.resolve(ident)

    assert result.match_type == "new"
    assert r.stats["degraded"] == 1


def test_red_control_inner_tiers_raise_on_timeout(monkeypatch):
    """RED control: prove the *underlying* behaviour is to raise. Without the
    resolve() wrapper the exception would propagate and the import driver's
    loop would catch-and-skip the contact (the ~1,300-row silent loss). If
    this stops raising, the safety net is no longer load-bearing."""

    def boom(*_a, **_k):
        raise httpx.TimeoutException("simulated slow oxigraph")

    r = _resolver_with_post(monkeypatch, boom)
    ident = PersonIdentity(display_name="Mhairi Geraghty")

    with pytest.raises(httpx.TimeoutException):
        r._resolve_tiers(ident)


def test_success_path_is_not_falsely_degraded(monkeypatch):
    """Empty bindings = a genuine no-match -> new, but degraded must stay 0.
    The net must not paint healthy 'new' results as failures."""

    r = _resolver_with_post(monkeypatch, lambda *_a, **_k: _FakeResp())
    ident = PersonIdentity(display_name="Nobody Matches Here")

    result = r.resolve(ident)

    assert result.match_type == "new"
    assert r.stats == {"total": 1, "degraded": 0}


def test_summary_escalates_to_error_when_degraded(monkeypatch, caplog):
    """A degraded import must surface as ERROR, never pass silently."""

    def boom(*_a, **_k):
        raise httpx.ConnectError("oxigraph down")

    r = _resolver_with_post(monkeypatch, boom)
    r.resolve(PersonIdentity(display_name="A Contact"))

    with caplog.at_level(logging.ERROR):
        r.log_resolution_summary()

    assert any("DEGRADED" in rec.message for rec in caplog.records)
    assert r.resolution_summary() == {"total": 1, "degraded": 1}


def test_clean_run_summary_is_info_not_error(monkeypatch, caplog):
    """A clean run logs INFO and emits no ERROR."""

    r = _resolver_with_post(monkeypatch, lambda *_a, **_k: _FakeResp())
    r.resolve(PersonIdentity(display_name="Clean Contact"))

    with caplog.at_level(logging.INFO):
        r.log_resolution_summary()

    assert not any(rec.levelno >= logging.ERROR for rec in caplog.records)
    assert any("finished cleanly" in rec.message for rec in caplog.records)
