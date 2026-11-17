"""The digest declares its destination by model route (Archie ruling, 2026-11-18).

CONTEXT.md is injected into the system prompt of whichever model answers, so
every gated read the digest makes carries X-Ostler-Destination:

  every configured model on this Mac        -> owner_own_brief
  any cloud model reachable, or unknown     -> cloud_model
  never absent

Unknown (no readable config, no fallback, a non-loopback model, a ":cloud"
model, a model route, a named fallback that is not loopback) fails closed to
cloud_model.

Synthetic config only. No real host, key or name appears here.
"""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import urllib.request
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "generate_pwg_context.py"
HDR = "X-Ostler-Destination"

ON_BOX = """
[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://localhost:11434"
model = "qwen-synthetic:9b"
timeout_secs = 300
"""

CLOUD_MODEL_ENTRY = """
[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://localhost:11434"
model = "qwen-synthetic:9b"

[providers.models.remote]
base_url = "https://api.example.invalid/v1"
model = "synthetic-cloud"
"""

CLOUD_FALLBACK = """
[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://localhost:11434"
model = "qwen-synthetic:9b"

[reliability]
fallback_providers = ["anthropic"]
"""

CLOUD_TAG = """
[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://localhost:11434"
model = "qwen-synthetic:cloud"
"""

ROUTES = """
[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://localhost:11434"
model = "qwen-synthetic:9b"

[[providers.model_routes]]
hint = "x"
provider = "ollama"
"""


def _load(name: str, source: str | None = None):
    """Import the generator as a fresh module (optionally from mutated source)."""
    spec = importlib.util.spec_from_file_location(name, _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    code = source if source is not None else _SCRIPT.read_text(encoding="utf-8")
    exec(compile(code, str(_SCRIPT), "exec"), mod.__dict__)
    return mod


@pytest.fixture
def home(tmp_path, monkeypatch):
    """Isolated HOME and OSTLER_DIR so no real config is read."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / ".ostler"))
    (tmp_path / ".ostler" / "assistant-config").mkdir(parents=True)
    return tmp_path


def _write_config(home: Path, text: str) -> None:
    (home / ".ostler" / "assistant-config" / "config.toml").write_text(text, encoding="utf-8")


class _Capture:
    """Stands in for urlopen: records every request's headers, answers 200 {}."""

    def __init__(self) -> None:
        self.headers: list[dict[str, str]] = []

    def __call__(self, req, timeout=None):
        self.headers.append({k.lower(): v for k, v in req.header_items()})
        body = io.BytesIO(json.dumps({}).encode())

        class _Resp:
            status = 200

            def read(self_inner):
                return body.getvalue()

            def __enter__(self_inner):
                return self_inner

            def __exit__(self_inner, *exc):
                return False

        return _Resp()


def _declared_by_one_read(mod, monkeypatch) -> str | None:
    cap = _Capture()
    monkeypatch.setattr(urllib.request, "urlopen", cap)
    mod._get_json("/api/v1/synthetic-probe")
    assert cap.headers, "the generator made no request"
    return cap.headers[-1].get(HDR.lower())


def _assert_declares(mod, monkeypatch, expected: str) -> None:
    """The contract every test shares: the read carries the expected destination."""
    got = _declared_by_one_read(mod, monkeypatch)
    assert got == expected, f"read declared {got!r}, expected {expected!r}"


# ── the pure route, both parsers ─────────────────────────────────────────────

@pytest.fixture(params=["tomllib", "minimal"])
def parser(request, monkeypatch):
    if request.param == "minimal":
        monkeypatch.setitem(sys.modules, "tomllib", None)   # forces ImportError
    return request.param


@pytest.mark.parametrize("config, expected", [
    (ON_BOX, "owner_own_brief"),
    (CLOUD_MODEL_ENTRY, "cloud_model"),
    (CLOUD_FALLBACK, "cloud_model"),
    (CLOUD_TAG, "cloud_model"),
    (ROUTES, "cloud_model"),
    ("this is not toml [[[", "cloud_model"),
    ("", "cloud_model"),
    (None, "cloud_model"),
])
def test_route_follows_the_models(config, expected, parser):
    mod = _load("route_" + parser)
    assert mod.route_destination(config) == expected


# ── the declaration on the wire ──────────────────────────────────────────────

def test_on_box_route_declares_owner_own_brief_on_every_read(home, monkeypatch):
    _write_config(home, ON_BOX)
    mod = _load("wire_on_box")
    _assert_declares(mod, monkeypatch, "owner_own_brief")


def test_cloud_route_declares_cloud_model_on_every_read(home, monkeypatch):
    _write_config(home, CLOUD_MODEL_ENTRY)
    mod = _load("wire_cloud")
    _assert_declares(mod, monkeypatch, "cloud_model")


def test_missing_config_declares_cloud_model(home, monkeypatch):
    # No config written at all: unknown route, fail closed.
    mod = _load("wire_missing")
    _assert_declares(mod, monkeypatch, "cloud_model")


def test_every_read_carries_a_destination_never_none(home, monkeypatch):
    _write_config(home, ON_BOX)
    mod = _load("wire_never_none")
    cap = _Capture()
    monkeypatch.setattr(urllib.request, "urlopen", cap)
    for path in ("/api/v1/a", "/api/v1/b?x=1", "/api/v1/c"):
        mod._get_json(path)
    assert len(cap.headers) == 3
    assert all(h.get(HDR.lower()) in ("owner_own_brief", "cloud_model") for h in cap.headers)


# ── mutant: a generator that drops the header must be caught ─────────────────

def test_mutant_that_drops_the_header_is_caught(home, monkeypatch):
    _write_config(home, ON_BOX)
    real = _SCRIPT.read_text(encoding="utf-8")
    needle = 'DESTINATION_HEADER: declared_destination()}'
    assert real.count(needle) == 1, "mutant anchor not found"
    mutant = real.replace(', ' + needle, '}')
    assert mutant != real, "mutation did not apply"
    mod = _load("mutant_no_header", source=mutant)
    # The shared contract must FAIL on the mutant: this is the control.
    with pytest.raises(AssertionError):
        _assert_declares(mod, monkeypatch, "owner_own_brief")
