"""The owner gate covers the proxied WRITE routes (and every method on them).

The proxy forwards the caller's own bearer, or substitutes Doctor's service token
when one is configured (proxy.py: the service-token branch). Either way, a local
account that is not the owner must not reach the gateway through the Doctor.

Arms: another local account gets 403 on memory correct, memory assert and safari
ingest, and on a GET of memory, and the stub gateway records 0 calls; the owner's
own process passes and the gateway is called once; the Safari extension running as
the owner (Chrome) is still admitted to ingest, and the gateway is called once.
Synthetic data only; the outbound call is a stub (httpx.AsyncClient.request).
"""
from __future__ import annotations

import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).parent))

LOOPBACK = ("127.0.0.1", 50000)
MEMORY_CORRECT = "/api/v1/memory/correct/abc123"
MEMORY_ASSERT = "/api/v1/memory/assert"
SAFARI_INGEST = "/api/safari/ingest"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


@pytest.fixture(autouse=True)
def _sandboxed_home(tmp_path, monkeypatch):
    """Sandboxed HOME: nothing in these arms may touch the real ~/.ostler."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / ".ostler"))
    return tmp_path


@pytest.fixture
def stub_gateway(monkeypatch):
    """Record every outbound gateway call; answer 200 with a small body."""
    calls: list[str] = []

    async def _fake_request(self, method, url, **kwargs):
        calls.append(f"{method} {url}")
        return httpx.Response(200, content=b'{"ok": true}',
                              headers={"content-type": "application/json"},
                              request=httpx.Request(method, url))

    monkeypatch.setattr(httpx.AsyncClient, "request", _fake_request)
    monkeypatch.setenv("DOCTOR_GATEWAY_URL", "http://127.0.0.1:8000")
    monkeypatch.delenv("OSTLER_DOCTOR_ORACLE_FALLBACK", raising=False)
    return calls


def _peer(monkeypatch, *, uid=None, command="/usr/bin/python3"):
    import owner_peer
    owner = owner_peer.owner_uid()
    peer_uid = owner if uid is None else uid
    monkeypatch.setattr(owner_peer, "_lookup",
                        lambda *a, **k: owner_peer.Peer(pid=1, uid=peer_uid, command=command))


def _client(web_ui):
    from fastapi.testclient import TestClient
    return TestClient(web_ui.app, client=LOOPBACK)


@pytest.mark.real_owner_gate
@pytest.mark.parametrize("method,path,body", [
    ("POST", MEMORY_CORRECT, {"text": "x"}),
    ("POST", MEMORY_ASSERT, {"text": "x"}),
    ("POST", SAFARI_INGEST, {"url": "https://example.com/"}),
    ("GET", "/api/v1/memory", None),
])
def test_another_local_account_is_refused_and_gateway_sees_nothing(
        method, path, body, stub_gateway, monkeypatch):
    import web_ui
    _peer(monkeypatch, uid=__import__("owner_peer").owner_uid() + 1)
    r = _client(web_ui).request(method, path, json=body)
    assert r.status_code == 403
    assert r.json().get("refused_on") == "peer-not-owner"
    assert stub_gateway == []


@pytest.mark.real_owner_gate
def test_owner_process_reaches_memory_correct(stub_gateway, monkeypatch):
    # THIS TREE: the vendored Doctor proxies ONLY /api/safari/ingest (proxy.py
    # DEFAULT_PROXY_PATHS). Upstream also proxies the memory routes. So here the
    # owner gets 404 on memory correct, and the gateway is not called. A change to
    # the path list must update this arm.
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).post(MEMORY_CORRECT, json={"text": "x"})
    assert r.status_code == 404
    assert stub_gateway == []


@pytest.mark.real_owner_gate
def test_safari_extension_running_as_owner_is_still_admitted(stub_gateway, monkeypatch):
    """The browser extension runs inside the owner's Chrome: same uid, not a forwarder.
    The owner gate must admit it, and the gateway must be reached once."""
    import web_ui
    _peer(monkeypatch, command=CHROME)
    r = _client(web_ui).post(SAFARI_INGEST, json={"url": "https://example.com/"},
                             headers={"Authorization": "Bearer not-a-paired-token"})
    assert r.status_code == 200, r.text
    assert len(stub_gateway) == 1 and "/api/safari/ingest" in stub_gateway[0]


@pytest.mark.real_owner_gate
def test_tunnel_forwarder_as_owner_is_refused(stub_gateway, monkeypatch):
    # A tailscale relay onto loopback runs as the owner's uid too. It must not pass.
    import web_ui
    _peer(monkeypatch, command="/usr/local/bin/tailscaled")
    r = _client(web_ui).post(MEMORY_CORRECT, json={"text": "x"})
    assert r.status_code == 403
    assert r.json().get("refused_on") == "peer-is-forwarder"
    assert stub_gateway == []
