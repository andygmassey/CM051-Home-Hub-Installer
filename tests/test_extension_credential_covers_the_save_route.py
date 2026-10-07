"""The browser-extension credential opens exactly two POST paths on loopback.

Lane 6 added "Save to Knowledge", a second WRITE from the same extension, at
/api/safari/save. A Hub-only customer (no paired iPhone) authenticates with
the per-install extension token, so without this the button would 401 for
exactly the customer it matters most to. The narrowness is the design, so
this pins what must stay CLOSED as hard as what opens.
"""
import importlib.util
import os
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")

REPO = Path(__file__).resolve().parents[1]
PROXY = REPO / "vendor" / "doctor" / "agent" / "proxy.py"
TOKEN = "ext-token-for-test"


@pytest.fixture(scope="module")
def proxy():
    spec = importlib.util.spec_from_file_location("doctor_proxy_lane6", PROXY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _req(method="POST", host="127.0.0.1"):
    return types.SimpleNamespace(method=method, client=types.SimpleNamespace(host=host))


@pytest.fixture(autouse=True)
def _token():
    with patch.dict(os.environ, {"OSTLER_EXTENSION_TOKEN": TOKEN}):
        yield


@pytest.mark.parametrize("path", ["/api/safari/ingest", "/api/safari/save"])
def test_both_extension_writes_are_admitted(proxy, path):
    assert proxy._is_extension_credential(_req(), TOKEN, path) is True


@pytest.mark.parametrize("path", [
    "/api/v1/browsing/search", "/api/v1/people", "/api/v1/timeline", "/api/v1/memory",
    "/api/safari/save/", "/api/safari/saved", "/api/safari/save/x", "/api/safari",
    "/api/safari/ingest/extra", "/API/SAFARI/SAVE",
])
def test_every_other_path_stays_closed_to_the_extension_token(proxy, path):
    assert proxy._is_extension_credential(_req(), TOKEN, path) is False


@pytest.mark.parametrize("path", ["/api/safari/ingest", "/api/safari/save"])
def test_reads_remote_callers_and_wrong_tokens_are_refused(proxy, path):
    assert proxy._is_extension_credential(_req("GET"), TOKEN, path) is False
    assert proxy._is_extension_credential(_req(host="192.0.2.5"), TOKEN, path) is False
    assert proxy._is_extension_credential(_req(), "wrong", path) is False
    assert proxy._is_extension_credential(_req(), "", path) is False


def test_no_token_configured_admits_nothing(proxy):
    with patch.dict(os.environ, {"OSTLER_EXTENSION_TOKEN": ""}):
        assert proxy._is_extension_credential(_req(), TOKEN, "/api/safari/save") is False
