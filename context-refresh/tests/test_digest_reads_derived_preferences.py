"""The digest's Preferences section shows DERIVED preferences ("What you like").

v1.0.121 trial box, measured: the derive job writes the derived named graph
and GET /api/v1/preferences/derived serves it (300 nodes), but the owner
digest read only GET /api/v1/preferences (the CM059 interest profile). The
walk probe derived_preferences_reach_digest_and_tool failed its digest arm on
exactly that: CONTEXT.md's "Preferences and things to keep in mind" named no
label the derived route serves.

The route payload here is built by the PRODUCER AS VENDORED in this repo
(vendor/cm041/assistant_api/derived_preferences.py
build_derived_preferences_response) from synthetic affinities, so the digest is
tested against the shape the shipped ical-server emits, not a hand-written one.
Every label is synthetic.

  RED      the trial-tree generator (pinned SHA) shows none of the derived
           labels while the route serves them
  GREEN    the fixed generator shows likes and dislikes, labelled as derived,
           and keeps the interest-profile lines
  PROBE    the walk probe's own predicate (names_any over the section) finds a
           served label in the GREEN digest and none in the RED one
  PRIVACY  an L3 item and an unreadable level never reach the digest
  HONEST   a degraded route is said out loud (inline, or on the gap line when
           the section is otherwise empty), a refused route reads COULD NOT BE
           READ, and neither is rendered as "no likes"
"""
from __future__ import annotations

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_digest_knows_its_owner import (  # noqa: E402,F401  (env is a fixture)
    SERVICE_TOKEN, STORE_TOKEN, _PREFERENCES, _REPO, _SCRIPT, _gap_line, _load,
    _oxigraph_server, _routes, _seed_store, _serve, env,
)

_VENDORED_ROUTE = _REPO / "vendor" / "cm041" / "assistant_api"
_PROBE_LIB = _REPO / "scripts" / "box_walk_probes" / "lib"

# The v1.0.121 trial tree (integration/v1.0.121-trial) before this fix. Pinned
# to a SHA, never to a moving ref.
_TRIAL_SHA = "7759d8f31c5660692b47b5d3e23dfe6131839a2c"

HEADING = "Preferences and things to keep in mind"
LIKES = ("Sichuan cooking", "Board games", "Coastal walks")
DISLIKE = "Coriander"
CANARY_L3 = "CANARY-L3-DERIVED-6612"
CANARY_BAD_LEVEL = "CANARY-UNREADABLE-LEVEL-4471"
DEGRADED_REASON = "no derived preferences materialized yet"


# ── The route payload, from the vendored producer ───────────────────────────


def _derived_payload() -> dict:
    sys.path.insert(0, str(_VENDORED_ROUTE))
    try:
        import derived_preferences as dp
    finally:
        sys.path.remove(str(_VENDORED_ROUTE))

    def view(label, strength, privacy="", category="food"):
        return dp.AffinityView(dimension=f"{category}.thing", subject=label,
                               strength=strength, confidence=0.8,
                               category=category, privacy=privacy)

    views = [
        view(LIKES[0], 0.71, privacy="L2"),
        view(LIKES[1], 0.64, category="hobby"),
        view(DISLIKE, -0.55, privacy="L1"),
        view(LIKES[2], 0.52, privacy="L0", category="outdoors"),
        # The real reader filters these in SPARQL; the digest must not rely
        # on that, so the fake reader hands them through.
        view(CANARY_L3, 0.99, privacy="L3"),
        view(CANARY_BAD_LEVEL, 0.98, privacy="LX"),
    ]

    class Reader:
        def get_derived_preferences(self, user_id, min_confidence=0.4, limit=8):
            return views[:limit]

    return dp.build_derived_preferences_response(Reader(), "jane", limit=8)


def _degraded_payload() -> dict:
    sys.path.insert(0, str(_VENDORED_ROUTE))
    try:
        import derived_preferences as dp
    finally:
        sys.path.remove(str(_VENDORED_ROUTE))

    class Empty:
        def get_derived_preferences(self, user_id, min_confidence=0.4, limit=8):
            return []

    out = dp.build_derived_preferences_response(Empty(), "jane", tier="all")
    assert out["degraded"] is True and out["items"] == []
    return out


def test_the_vendored_producer_payload_is_the_shape_under_test():
    """Control: the payload carries the served labels, a negative strength for
    the dislike, and privacy levels, so every assertion below is about the
    digest and not about a malformed fixture."""
    p = _derived_payload()
    assert p["degraded"] is False
    labels = {i["label"]: i for i in p["items"]}
    assert set(LIKES) | {DISLIKE, CANARY_L3, CANARY_BAD_LEVEL} == set(labels)
    assert labels[DISLIKE]["strength"] < 0
    assert labels[CANARY_L3]["privacy_level"] == "L3"
    assert "privacy_level" not in labels[LIKES[1]]


# ── A fake ical-server that can also refuse ─────────────────────────────────


def _ical(routes: dict, seen: list):
    """routes: path -> body (200) or (status, body)."""

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            seen.append(self.path)
            if (self.headers.get("Authorization") or "") != f"Bearer {SERVICE_TOKEN}":
                self._send(401, {"error": "unauthorised"})
                return
            got = routes.get(self.path.split("?", 1)[0], {})
            code, body = got if isinstance(got, tuple) else (200, got)
            self._send(code, body)

    return _serve(H)


def _build(env, module_path: Path, routes: dict, name: str):
    seen: list = []
    ox_srv = _oxigraph_server(_seed_store(), token=STORE_TOKEN)
    ical_srv = _ical(routes, seen)
    try:
        env.setenv("OXIGRAPH_URL", f"http://127.0.0.1:{ox_srv.server_address[1]}")
        env.setenv("OSTLER_ICAL_BASE_URL",
                   f"http://127.0.0.1:{ical_srv.server_address[1]}")
        gen = _load(module_path, name)
        return gen, gen.build_digest(), seen
    finally:
        ox_srv.shutdown()
        ical_srv.shutdown()


def _routes_with(derived) -> dict:
    r = _routes()
    r["/api/v1/preferences/derived"] = derived
    return r


def _pref_section(digest: str) -> str:
    if f"## {HEADING}" not in digest:
        return ""
    return digest.split(f"## {HEADING}", 1)[1].split("\n## ", 1)[0]


def _probe_names(section: str) -> int:
    """The walk probe's own predicate (derived_preferences_reach.names_any),
    over the labels the route serves with a positive strength."""
    sys.path.insert(0, str(_PROBE_LIB))
    try:
        import derived_preferences_reach as reach
    finally:
        sys.path.remove(str(_PROBE_LIB))
    served = [i["label"] for i in _derived_payload()["items"] if i["strength"] > 0]
    return reach.names_any(section, served)


@pytest.fixture()
def trial_module(tmp_path) -> Path:
    try:
        src = subprocess.run(
            ["git", "-C", str(_REPO), "show",
             f"{_TRIAL_SHA}:context-refresh/bin/generate_pwg_context.py"],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
    except (subprocess.CalledProcessError, OSError) as exc:
        # CANNOT-RUN is not PASS: fail loudly rather than skip.
        pytest.fail(f"CANNOT-RUN: trial-tree generator not readable at "
                    f"{_TRIAL_SHA} (needs full history): {exc}")
    out = tmp_path / "generate_pwg_context_trial.py"
    out.write_text(src, encoding="utf-8")
    return out


# ── RED: the trial tree ─────────────────────────────────────────────────────


def test_red_trial_generator_never_shows_a_derived_preference(env, trial_module):
    gen, digest, seen = _build(env, trial_module, _routes_with(_derived_payload()),
                               "gen_trial")
    assert digest is not None
    section = _pref_section(digest)
    # The interest profile DID reach it, so the section is alive...
    assert "Trail running" in section
    # ...and the route was never asked, and no served label appears.
    assert not any(p.startswith("/api/v1/preferences/derived") for p in seen)
    for label in (*LIKES, DISLIKE):
        assert label not in digest
    assert _probe_names(section) == 0


# ── GREEN: the fixed generator ──────────────────────────────────────────────


def test_green_derived_likes_and_dislikes_are_shown_and_labelled(env):
    gen, digest, seen = _build(env, _SCRIPT, _routes_with(_derived_payload()),
                               "gen_green")
    section = _pref_section(digest)
    likes = [l for l in section.splitlines()
             if l.startswith("- What you like (derived from your history): ")]
    dislikes = [l for l in section.splitlines()
                if l.startswith("- Not keen on (derived from your history): ")]
    assert len(likes) == 1 and len(dislikes) == 1, section
    for label in LIKES:
        assert label in likes[0]
    assert DISLIKE in dislikes[0] and DISLIKE not in likes[0]
    # The CM059 interest-profile lines are kept, below the derived ones.
    assert "- Trail running (Sport)" in section
    assert section.index("What you like") < section.index("Trail running")
    # The route is asked in the tier the walk probe reads.
    asked = [p for p in seen if p.startswith("/api/v1/preferences/derived")]
    assert len(asked) == 1 and "tier=all" in asked[0]
    # The walk probe's own predicate now finds served labels.
    assert _probe_names(section) == len(LIKES)
    assert not [f for f in gen._FAILURES if "derived" in f]


def test_privacy_l3_and_unreadable_levels_never_reach_the_digest(env):
    _, digest, _ = _build(env, _SCRIPT, _routes_with(_derived_payload()),
                          "gen_privacy")
    assert CANARY_L3 not in digest
    assert CANARY_BAD_LEVEL not in digest
    # Control: the same payload's L0, L1, L2 and unlevelled items did reach it.
    for label in (*LIKES, DISLIKE):
        assert label in digest


# ── HONEST: degraded and refused routes ─────────────────────────────────────


def test_degraded_route_is_said_inline_when_the_section_has_other_content(env):
    gen, digest, _ = _build(env, _SCRIPT, _routes_with(_degraded_payload()),
                            "gen_degraded")
    section = _pref_section(digest)
    assert f"- Derived preferences: could not check ({DEGRADED_REASON})" in section
    assert "What you like (derived" not in section
    assert "- Trail running (Sport)" in section
    # A degraded 200 is not a refused read: the exit code is not moved.
    assert not [f for f in gen._FAILURES if "derived" in f]


def test_degraded_route_with_nothing_else_is_on_the_gap_line_not_a_fake(env):
    routes = _routes_with(_degraded_payload())
    routes["/api/v1/preferences"] = {"interests": []}
    _, digest, _ = _build(env, _SCRIPT, routes, "gen_degraded_empty")
    assert _pref_section(digest) == ""
    gap = _gap_line(digest, HEADING)
    assert gap == (f"- {HEADING}: nothing stored. Derived preferences could not "
                   f"be checked ({DEGRADED_REASON}).")


def test_refused_route_reads_could_not_be_read(env):
    routes = _routes_with((500, {"error": "internal"}))
    gen, digest, _ = _build(env, _SCRIPT, routes, "gen_refused")
    gap = _gap_line(digest, HEADING)
    assert "COULD NOT BE READ" in gap and "/api/v1/preferences/derived" in gap
    assert "HTTP 500" in gap
    assert [f for f in gen._FAILURES if "/api/v1/preferences/derived" in f]
    # The interest profile still renders; the failure does not blank it.
    assert "- Trail running (Sport)" in _pref_section(digest)


def test_interest_profile_fixture_is_the_one_the_owner_suite_uses():
    """Control: the 'kept' assertions above read a real interest from the
    shared fixture, not a string this file invented."""
    assert any(i["subject"] == "Trail running" for i in _PREFERENCES["interests"])
