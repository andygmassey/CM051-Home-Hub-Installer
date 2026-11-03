"""The 7-day digest never carries an L3 meeting from /api/v1/timeline.

End to end across the seam that was open: the REAL generator
(context-refresh/bin/generate_pwg_context.py, ``_meetings_section``) asks the
REAL vendored route handler logic (``api_timeline`` over a real SPARQL engine,
rdflib) for the timeline, and the generated CONTEXT.md text is searched for the
L3 meeting's summary. Only the HTTP hop is replaced: the fake ``_get_json``
parses the path the digest actually requested and passes ``outbound`` the way
the route does, so a digest that stops asking ``outbound=1`` fails here.

The digest's own second source (``_meeting_rows``) is pinned to nothing so the
timeline route is the ONLY path that can put a meeting in the text.
Synthetic data only.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_vendored_timeline_outbound_l3 as T  # noqa: E402  (fixture + engine)

server = T.server
_SCRIPT = HERE.parent / "context-refresh" / "bin" / "generate_pwg_context.py"


def _gen():
    spec = importlib.util.spec_from_file_location("generate_pwg_context", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def digest_text(monkeypatch, tmp_path):
    for key in ("USER_ID", "USER_NAME", "USER_EMAIL", "WIKI_OPERATOR_NAME",
                "WIKI_OPERATOR_EMAILS", "OSTLER_OXIGRAPH_TOKEN", "OXIGRAPH_TOKEN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "no-ostler-dir"))
    gen = _gen()
    requested = []

    def fake_get_json(path):
        requested.append(path)
        u = urlparse(path)
        if u.path != "/api/v1/timeline":
            return None
        q = parse_qs(u.query)
        outbound = (q.get("outbound") or [""])[0].strip().lower() in ("1", "true", "yes")
        with patch.object(server, "query_google_calendar", return_value=[]), \
                patch.object(server, "_sparql_select", side_effect=T._engine()), \
                patch.object(server, "_timeline_conversations",
                             side_effect=lambda **k: ([], None)):
            return server.api_timeline(days=7, outbound=outbound)

    monkeypatch.setattr(gen, "_get_json", fake_get_json)
    monkeypatch.setattr(gen, "_sparql_select", lambda sparql: [])
    return "\n".join(gen._meetings_section()), requested


def test_l3_meeting_never_in_the_generated_context(digest_text):
    text, requested = digest_text
    assert any("/api/v1/timeline" in p for p in requested), requested
    assert "L3 secret meeting" not in text
    assert "L1 meeting with an L3 attendee" not in text
    assert "untagged meeting, untagged attendee" not in text


def test_l1_control_reaches_the_generated_context(digest_text):
    text, _ = digest_text
    assert "L1 control lunch" in text
