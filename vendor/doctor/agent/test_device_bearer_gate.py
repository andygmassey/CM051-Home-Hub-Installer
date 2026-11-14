"""The Doctor gate admits the owner peer OR a valid paired-device bearer (RED first).

The paired iPhone reaches the Doctor over the tailnet: tailscaled relays the
connection, so the owner check sees a forwarder. A VALID bearer, checked against
the CURRENT pairing store (the gateway oracle, asked on every request), admits the
device on the iOS routes. A static credential is never a pair bearer. Everything
else gets 403. Sandboxed HOME; the pairing oracle and the outbound gateway call
are stubs. Synthetic tokens built at runtime.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).parent))

# The shipped Doctor plist sets DOCTOR_PROXY_PATHS (install.sh) and proxies the
# memory routes. Pin that list before web_ui is imported so the memory routes exist.
SHIPPED_PROXY_PATHS = "/api/safari/ingest,/api/safari/save,/api/v1/browsing/search,/api/v1/hub/health,/api/v1/timeline,/api/v1/people,/api/v1/people/search,/api/v1/people/context,/api/v1/person/{slug}/timeline,/api/v1/people/stale,/api/v1/people/recent,/api/v1/people/birthdays,/api/v1/suggestions,/api/v1/calendar,/api/v1/calendar/today,/api/v1/conversation/process,/api/v1/conversation/status/{id},/api/v1/email/recent,/api/v1/ingest/ios,/api/v1/health/day,/api/v1/recording/active,/api/v1/coach/recent,/api/v1/people/{slug}/forget,/api/v1/decisions,/api/v1/topics,/api/v1/topics/{slug}/mentions,/api/v1/commitments,/api/v1/hydration/status,/api/v1/subscription/receipt,/api/v1/memory,/api/v1/memory/correct/{id},/api/v1/memory/assert,/api/v1/contacts/diff,/api/v1/minors,/api/v1/minors/suggestions,/api/v1/people/{slug}/minor,/api/v1/people/{slug}/minor-suggestion/dismiss"
os.environ.setdefault("DOCTOR_PROXY_PATHS", SHIPPED_PROXY_PATHS)

LOOPBACK = ("127.0.0.1", 50000)
TAILSCALED = "/usr/local/bin/tailscaled"
PYTHON = "/usr/bin/python3"
DEVICE = "device" + "-token-" + "one"
STATIC = "static" + "-admin-" + "token"
IOS_CALLS = [
    ("POST", "/api/v1/auth/chat-token", {}),
    ("GET", "/api/v1/suggestions", None),
    ("POST", "/api/v1/wiki/correct", {"text": "x"}),
    ("GET", "/api/v1/memory", None),
    ("POST", "/api/v1/memory/correct/abc", {"text": "x"}),
    ("POST", "/api/v1/memory/assert", {"text": "x"}),
]


@pytest.fixture(autouse=True)
def _sandboxed(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / ".ostler"))
    monkeypatch.setenv("DOCTOR_GATEWAY_URL", "http://127.0.0.1:8000")
    monkeypatch.delenv("OSTLER_ADMIN_TOKEN", raising=False)
    monkeypatch.delenv("OSTLER_MACHINE_ADMIN_TOKEN", raising=False)
    monkeypatch.delenv("OSTLER_EXTENSION_TOKEN", raising=False)
    return tmp_path


@pytest.fixture
def pairing(monkeypatch):
    """The current pairing store: a set of valid device bearers. Revoke by removing."""
    import proxy
    state = {"valid": {DEVICE}, "asked": 0}

    async def _oracle(token, validator_url=None, client=None):
        state["asked"] += 1
        return token in state["valid"]

    monkeypatch.setattr(proxy, "_is_paired_bearer", _oracle)
    return state


@pytest.fixture
def gateway(monkeypatch):
    calls: list[str] = []

    async def _fake(self, method, url, **kwargs):
        calls.append(f"{method} {url}")
        return httpx.Response(200, content=b'{"ok": true}',
                              headers={"content-type": "application/json"},
                              request=httpx.Request(method, url))

    monkeypatch.setattr(httpx.AsyncClient, "request", _fake)
    return calls


def _peer(monkeypatch, *, command=TAILSCALED, uid=None):
    import owner_peer
    peer_uid = owner_peer.owner_uid() if uid is None else uid
    monkeypatch.setattr(owner_peer, "_lookup",
                        lambda *a, **k: owner_peer.Peer(pid=1, uid=peer_uid, command=command))


def _client(web_ui, host=LOOPBACK):
    from fastapi.testclient import TestClient
    return TestClient(web_ui.app, client=host)


def _bearer(token):
    return {"Authorization": f"Bearer {token}"}


# --- tailnet (forwarder) with a valid device bearer passes ------------------

@pytest.mark.real_owner_gate
def test_tailnet_valid_bearer_passes_memory_correct(monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).post("/api/v1/memory/correct/abc", json={"text": "x"}, headers=_bearer(DEVICE))
    assert r.status_code == 200, r.text
    assert len(gateway) == 1


@pytest.mark.real_owner_gate
@pytest.mark.parametrize("method,path,body", [IOS_CALLS[2], IOS_CALLS[3]])
def test_tailnet_valid_bearer_is_not_refused_by_the_gate(method, path, body, monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).request(method, path, json=body, headers=_bearer(DEVICE))
    assert r.status_code != 403, r.text
    assert "refused_on" not in (r.json() if r.headers.get("content-type", "").startswith("application/json") else {})


# --- no bearer, another account, revoked, static: 403 -----------------------

@pytest.mark.real_owner_gate
@pytest.mark.parametrize("method,path,body", IOS_CALLS)
def test_tailnet_without_bearer_is_refused(method, path, body, monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).request(method, path, json=body)
    assert r.status_code == 403
    assert r.json().get("refused_on") == "peer-is-forwarder"
    assert gateway == []


@pytest.mark.real_owner_gate
def test_revoked_bearer_is_refused_at_once(monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch)
    client = _client(web_ui)
    assert client.post("/api/v1/memory/correct/abc", json={"text": "x"}, headers=_bearer(DEVICE)).status_code == 200
    pairing["valid"].discard(DEVICE)                       # the device is unpaired
    r = client.post("/api/v1/memory/correct/abc", json={"text": "x"}, headers=_bearer(DEVICE))
    assert r.status_code == 403
    assert len(gateway) == 1                               # only the pre-revocation call


@pytest.mark.real_owner_gate
def test_another_local_account_is_refused_without_a_bearer(monkeypatch, pairing, gateway):
    import owner_peer
    import web_ui
    _peer(monkeypatch, command=PYTHON, uid=owner_peer.owner_uid() + 1)
    r = _client(web_ui).post("/api/v1/memory/correct/abc", json={"text": "x"})
    assert r.status_code == 403
    assert r.json().get("refused_on") == "peer-not-owner"
    assert gateway == []


@pytest.mark.real_owner_gate
def test_owner_peer_passes_without_a_bearer(monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch, command=PYTHON)
    r = _client(web_ui).post("/api/v1/memory/correct/abc", json={"text": "x"})
    assert r.status_code == 200
    assert len(gateway) == 1


@pytest.mark.real_owner_gate
def test_static_token_is_never_a_pair_bearer(monkeypatch, pairing, gateway):
    # The worst case: the pairing oracle would say yes to ANY token. The Doctor must
    # still refuse the static admin token as a pair bearer.
    import proxy
    import web_ui
    monkeypatch.setenv("OSTLER_ADMIN_TOKEN", STATIC)

    async def _yes(token, validator_url=None, client=None):
        return True

    monkeypatch.setattr(proxy, "_is_paired_bearer", _yes)
    _peer(monkeypatch)
    r = _client(web_ui).post("/api/v1/memory/correct/abc", json={"text": "x"}, headers=_bearer(STATIC))
    assert r.status_code == 403
    assert gateway == []


# --- census: over the tailnet, with no credential, nothing but the public payload ---

@pytest.mark.real_owner_gate
def test_census_every_route_is_refused_over_the_tailnet_without_a_credential(monkeypatch, pairing, gateway):
    import web_ui
    from starlette.routing import Route
    _peer(monkeypatch)
    client = _client(web_ui)
    public = {"/api/v1/hydration/status"}
    checked = 0
    for route in web_ui.app.routes:
        if not isinstance(route, Route) or route.path in public:
            continue
        concrete = re.sub(r"\{[^}]+\}", "x", route.path)
        for method in sorted((route.methods or set()) - {"HEAD", "OPTIONS"}):
            r = client.request(method, concrete, json={} if method != "GET" else None)
            assert r.status_code == 403, f"{method} {route.path} reached the handler over the tailnet: {r.status_code}"
            assert r.json().get("refused_on") == "peer-is-forwarder", f"{method} {route.path}"
            checked += 1
    assert checked > 50, f"the census must cover the whole app, checked {checked}"
    assert gateway == []


@pytest.mark.real_owner_gate
def test_only_the_public_payload_is_reachable_over_the_tailnet(monkeypatch, pairing, gateway):
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).get("/api/v1/hydration/status")
    assert r.json().get("refused_on") is None


@pytest.mark.real_owner_gate
def test_chat_token_stays_owner_only_over_the_tailnet(monkeypatch, pairing, gateway):
    # DECISION PENDING (coordinator). The Companion calls chat-token once, BEFORE it
    # holds a bearer, and the route vends a credential, so a bearer gate there is
    # circular. Until that is decided, chat-token is owner-only: a valid bearer
    # does not admit a tailnet request to it.
    import web_ui
    _peer(monkeypatch)
    r = _client(web_ui).post("/api/v1/auth/chat-token", json={}, headers=_bearer(DEVICE))
    assert r.status_code == 403
    assert r.json().get("refused_on") == "peer-is-forwarder"
