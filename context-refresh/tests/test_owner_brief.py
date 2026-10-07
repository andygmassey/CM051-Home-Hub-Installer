"""The owner brief: routines, priorities, tastes, autonomy and channel style.

CONTEXT.md is read first on every chat turn. This suite covers the sections
that make it a one-page brief on the owner, on top of the "About you" block
the #2654 suite already guards:

  Routines and priorities   pwg:Meeting timing + GET /api/v1/commitments
  Tastes                    GET /api/v1/preferences, Food / Music / Film & TV
  Autonomy calibration      confirmed + corrected facts, [autonomy] settings
  Channel style             pwg:userMessages / pwg:otherMessages counts

It runs the generator against a REAL SPARQL engine (pyoxigraph) holding a
SYNTHETIC seed, with the bearer-enforcing fake stores from the #2654 suite.
Every name below is fictional.

Four kinds of test:
  RENDER   each new section renders from seeded data
  HONEST   empty sources say "nothing stored"; failed ones COULD NOT BE READ
  CAP      the 6 KB cap holds on a large seed and keeps the contract lines
  PRIVACY  a seeded canary (L3 fact, message text, a secret in the same
           config file) never appears
"""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")
import pyoxigraph as ox  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_digest_knows_its_owner import (  # noqa: E402,F401  (env is a fixture)
    OWNER_ID, OWNER_NAME, PWG, STORE_TOKEN, _SCRIPT, _build, _gap_line, _lit,
    _n, _routes, _section, _seed_store, env,
)

# Strings that must NEVER reach the digest.
CANARY_MESSAGE_TEXT = "CANARY-MESSAGE-TEXT-7731"
CANARY_L3_FACT = "CANARY-L3-FACT-5520"
CANARY_L3_COUNT = "7771"            # an L3 thread's sent count
CANARY_GATEWAY_TOKEN = "CANARY-GATEWAY-TOKEN-9921"
CANARY_L3_COMMITMENT = "CANARY-L3-COMMITMENT-3308"
CANARY_L3_INTEREST = "CANARY-L3-INTEREST-4417"
CANARIES = (CANARY_MESSAGE_TEXT, CANARY_L3_FACT, CANARY_L3_COUNT,
            CANARY_GATEWAY_TOKEN, CANARY_L3_COMMITMENT, CANARY_L3_INTEREST)

_RDF_TYPE = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")


# ── Seed: the base #2654 graph plus the brief's sources ─────────────────────


def _brief_store(*, signals: bool = True, routines: bool = True,
                 asserted: bool = True) -> ox.Store:
    store = _seed_store()
    dg = ox.DefaultGraph()

    def add(s, p, o):
        store.add(ox.Quad(s, p if isinstance(p, ox.NamedNode) else _n(p), o, dg))

    owner = _n(f"user_{OWNER_ID}")
    today = datetime.now(timezone.utc).date()

    if routines:
        # Owner-attended meetings: Tuesdays x6 and Thursdays x4 at 10:00,
        # between 10 and 80 days ago, so the busiest days and the usual hour
        # are known and deterministic.
        made = {1: 0, 3: 0}
        want = {1: 6, 3: 4}
        for back in range(10, 80):
            day = today - timedelta(days=back)
            wd = day.weekday()
            if wd in want and made[wd] < want[wd]:
                made[wd] += 1
                m = ox.NamedNode(f"https://example.invalid/meeting/r{back}")
                add(m, _RDF_TYPE, _n("Meeting"))
                add(m, "meetingSummary", _lit(f"Routine block {back}"))
                add(m, "meetingDate", _lit(f"{day.isoformat()} 10:00:00+00:00"))
                add(m, "privacyLevel", _lit("L2"))
                add(m, "meetingAttendee", owner)

    if signals:
        # Per-channel sent / received counts, as linkedin_messages.py writes.
        def signal(sid, about, user_msgs, other_msgs, level="L2", extra=None):
            s = ox.NamedNode(f"https://example.invalid/signal/{sid}")
            add(s, _RDF_TYPE, _n("RelationshipSignal"))
            add(s, "signalType", _lit("linkedin_messaging"))
            add(s, "about", about)
            add(s, "userMessages", _lit(user_msgs))
            add(s, "otherMessages", _lit(other_msgs))
            add(s, "privacyLevel", _lit(level))
            if extra:
                add(s, "messageText", _lit(extra))

        mary = ox.NamedNode("https://example.invalid/person/mary")
        bob = ox.NamedNode("https://example.invalid/person/bob")
        tom = ox.NamedNode("https://example.invalid/person/tom")
        signal("b1", mary, 30, 90, extra=CANARY_MESSAGE_TEXT)
        signal("b2", bob, 10, 30)
        signal("b3", tom, int(CANARY_L3_COUNT), 5, level="L3")

    if asserted:
        # One more asserted fact the owner told the assistant, and an L3 one.
        af = ox.NamedNode("https://example.invalid/fact/asserted-2")
        add(af, _RDF_TYPE, _n("PersonFact"))
        add(af, "factText", _lit("the garden shed is blue"))
        add(af, "factSource", _lit("user_asserted"))
        add(af, "privacyLevel", _lit("L1"))
        add(af, "belongsToUser", owner)
        l3 = ox.NamedNode("https://example.invalid/fact/asserted-l3")
        add(l3, _RDF_TYPE, _n("PersonFact"))
        add(l3, "factText", _lit(CANARY_L3_FACT))
        add(l3, "factSource", _lit("user_asserted"))
        add(l3, "privacyLevel", _lit("L3"))
        add(l3, "belongsToUser", owner)
    return store


def _taste(subject, domain, score, polarity="like", privacy="L2"):
    return {"subject": subject, "domain": domain, "polarity": polarity,
            "privacy": privacy, "score": score}


_BRIEF_INTERESTS = [
    _taste("Ramen", "Food", 0.95),
    _taste("Sourdough", "Food", 0.85),
    _taste("Coriander", "Food", 0.60, polarity="dislike"),
    _taste("Fennel", "Food", 0.40),            # fourth Food item: over the cap
    _taste("Jazz", "Music", 0.90),
    _taste("Folk", "Music", 0.70),
    _taste("Noir", "Film & TV", 0.80),
    _taste("Trail running", "Sport", 0.75),     # not a taste domain
    _taste(CANARY_L3_INTEREST, "Food", 0.99, privacy="L3"),
]

_COMMITMENTS = {"commitments": [
    {"action": "Send Mary the revised floor plan", "owner": "user",
     "due": "2099-01-15", "status": "open", "source": "2026-09-30"},
    {"action": "Renew the boat insurance", "owner": "user",
     "due": "2020-01-01", "status": "open", "source": ""},
    {"action": "Sort the loft", "owner": "user", "due": "",
     "status": "open", "source": ""},
    {"action": CANARY_L3_COMMITMENT, "owner": "user", "due": "",
     "status": "open", "source": "", "privacy_level": "L3"},
], "count": 4, "privacy_level": "L2"}

_MEMORY = {"facts": [
    {"id": "fact_a", "object": "Lives in Fictionville", "source": "manual",
     "corrected": False},
    {"id": "fact_b", "object": "Works four days a week",
     "source": "user_correction", "corrected": True},
], "count": 2}


def _brief_routes(**over) -> dict:
    routes = _routes()
    routes["/api/v1/preferences"] = {"interests": _BRIEF_INTERESTS}
    routes["/api/v1/commitments"] = _COMMITMENTS
    routes["/api/v1/memory"] = _MEMORY
    routes.update(over)
    return routes


def _write_config(env_, *, autonomy: bool = True):
    """The assistant config the installer writes. The [gateway] table carries
    a secret on a real box; the generator must never print it."""
    from os import environ
    cfg_dir = Path(environ["OSTLER_DIR"]) / "assistant-config"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    body = ('[gateway]\npaired_tokens = ["%s"]\n' % CANARY_GATEWAY_TOKEN)
    if autonomy:
        body += ('\n[autonomy]\nlevel = "supervised"\n'
                 'auto_approve = ["pwg_people"]\n'
                 'non_cli_excluded_tools = ["shell", "file_write", "browser", '
                 '"calculator"]\n')
    (cfg_dir / "config.toml").write_text(body, encoding="utf-8")


@pytest.fixture()
def brief(env):
    _write_config(env)
    store = _brief_store()
    gen, digest = _build(env, _SCRIPT, store, routes=_brief_routes())
    assert digest is not None
    return gen, digest


# ── RENDER: each new section from seeded data ────────────────────────────────


def test_routines_and_priorities_render(brief):
    _, digest = brief
    sec = _section(digest, "Routines and priorities")
    routine = next(ln for ln in sec.splitlines() if ln.startswith("- Routines:"))
    assert "busiest Tuesday and Thursday" in routine, routine
    assert "around 10:00" in routine, routine
    assert "Timing only" in routine
    opens = [ln for ln in sec.splitlines() if ln.startswith("- Open:")]
    # Soonest upcoming first, then overdue, then undated.
    assert opens[0].startswith("- Open: Send Mary the revised floor plan (due 2099-01-15)")
    assert opens[1].startswith("- Open: Renew the boat insurance (due 2020-01-01)")
    assert opens[2] == "- Open: Sort the loft"
    # Routines name no meeting title or attendee.
    assert "Routine block" not in sec and "Mary Smith" not in routine


def test_tastes_render_with_stored_score(brief):
    _, digest = brief
    sec = _section(digest, "Tastes")
    assert "- Food: Ramen (0.95); Sourdough (0.85); dislikes Coriander (0.60)" in sec
    assert "Fennel" not in sec            # capped at three per domain
    assert "- Music: Jazz (0.90); Folk (0.70)" in sec
    assert "- Film and TV: Noir (0.80)" in sec
    assert "Trail running" not in sec     # not a taste domain ...
    # ... and it stays in the older section, which no longer repeats tastes.
    prefs = _section(digest, "Preferences and things to keep in mind")
    assert "Trail running (Sport)" in prefs and "Ramen" not in prefs


def test_autonomy_calibration_renders(brief):
    _, digest = brief
    sec = _section(digest, "Autonomy calibration")
    # 2 asserted facts in the seed (boat + shed); the L3 one is not counted.
    assert "has confirmed 2 fact(s) and corrected 1 (at least)" in sec
    assert "- Stored setting level = supervised" in sec
    assert "auto_approve" in sec
    assert "Chat is configured without 4 tools, including shell, file_write, browser." in sec
    assert "No other permission is recorded here" in sec


def test_autonomy_invents_no_rule_without_stored_settings(env):
    """No [autonomy] table: the section reports counts only and states that
    no limit is stored. It never supplies a default of its own."""
    _write_config(env, autonomy=False)
    _, digest = _build(env, _SCRIPT, _brief_store(), routes=_brief_routes())
    sec = _section(digest, "Autonomy calibration")
    assert "Stored setting" not in sec and "Chat is configured" not in sec
    assert "confirmed 2 fact(s)" in sec


def test_channel_style_renders_counts_only(brief):
    _, digest = brief
    sec = _section(digest, "Channel style")
    # 30 + 10 sent, 90 + 30 received, two L2 threads; the L3 thread is out.
    assert "- LinkedIn messages: the owner sent 40, received 120 (25% yours) across 2 thread(s)" in sec
    assert "Length, formality, emoji and language: not measured" in sec


# ── HONEST: empty and failed sources ─────────────────────────────────────────


def test_empty_sources_say_nothing_stored(env):
    """Every source behind the new sections answers and holds nothing."""
    store = ox.Store()           # an empty graph
    routes = _routes()
    routes["/api/v1/preferences"] = {"interests": []}
    routes["/api/v1/commitments"] = {"commitments": [], "count": 0}
    routes["/api/v1/memory"] = {"facts": [], "count": 0}
    _write_config(env, autonomy=False)
    _, digest = _build(env, _SCRIPT, store, routes=routes)
    assert digest is not None
    for heading in ("Routines and priorities", "Tastes", "Channel style",
                    "Autonomy calibration"):
        assert _gap_line(digest, heading).endswith("nothing stored."), heading
        assert f"## {heading}" not in digest


def test_failed_store_reads_are_could_not_be_read(env):
    """A refused store (wrong bearer) is UNKNOWN, never "nothing stored"."""
    _write_config(env)
    _, digest = _build(env, _SCRIPT, _brief_store(), routes=_brief_routes(),
                       store_token="a-different-token")
    assert digest is not None
    for heading in ("Channel style", "Autonomy calibration"):
        line = _gap_line(digest, heading)
        assert "COULD NOT BE READ" in line and "HTTP 401" in line, (heading, line)
        assert "nothing stored" not in line


def test_failed_commitments_read_is_not_nothing_stored(env):
    """/api/v1/commitments answers 503 (Oxigraph down behind it): the
    Routines section keeps what it has and declares the refused read."""
    class _Down(dict):
        pass

    import http.server  # noqa: F401  (route table cannot express a 503)
    _write_config(env)
    routes = _brief_routes()
    del routes["/api/v1/commitments"]            # fixture answers {} (no list)
    _, digest = _build(env, _SCRIPT, _brief_store(routines=False),
                       routes=routes)
    sec = _section(digest, "Routines and priorities") \
        if "## Routines and priorities" in digest else ""
    assert "- Open:" not in sec
    # A body with no "commitments" list is no data, not an inferred zero.


def test_unreadable_config_is_could_not_be_read(env, tmp_path):
    from os import environ
    cfg_dir = Path(environ["OSTLER_DIR"]) / "assistant-config"
    (cfg_dir / "config.toml").mkdir(parents=True)    # a directory, not a file
    store = ox.Store()
    routes = _routes()
    routes["/api/v1/memory"] = {"facts": [], "count": 0}
    _, digest = _build(env, _SCRIPT, store, routes=routes)
    line = _gap_line(digest, "Autonomy calibration")
    assert "COULD NOT BE READ" in line and "config.toml" in line, line


# ── CAP: 6 KB with a large seed; the contract lines survive ──────────────────


def _large_store() -> ox.Store:
    store = _brief_store()
    dg = ox.DefaultGraph()
    for i in range(300):
        p = ox.NamedNode(f"https://example.invalid/person/bulk{i}")
        store.add(ox.Quad(p, _RDF_TYPE, _n("Person"), dg))
        store.add(ox.Quad(p, _n("displayName"), _lit(f"Bulk Person {i}"), dg))
        store.add(ox.Quad(p, _n("organization"), _lit(f"Org {i % 40}"), dg))
        store.add(ox.Quad(p, _n("privacyLevel"), _lit("L2"), dg))
        s = ox.NamedNode(f"https://example.invalid/signal/bulk{i}")
        store.add(ox.Quad(s, _RDF_TYPE, _n("RelationshipSignal"), dg))
        store.add(ox.Quad(s, _n("signalType"), _lit(f"channel_{i % 6}"), dg))
        store.add(ox.Quad(s, _n("about"), p, dg))
        store.add(ox.Quad(s, _n("totalMessages"), _lit(10 + i), dg))
        store.add(ox.Quad(s, _n("userMessages"), _lit(5 + i), dg))
        store.add(ox.Quad(s, _n("otherMessages"), _lit(5 + i), dg))
        store.add(ox.Quad(s, _n("privacyLevel"), _lit("L2"), dg))
    return store


def test_size_cap_holds_on_a_large_seed(env):
    _write_config(env)
    routes = _brief_routes()
    routes["/api/v1/preferences"] = {"interests": _BRIEF_INTERESTS + [
        _taste(f"Interest {i} " + "x" * 30, d, 0.5)
        for i in range(150) for d in ("Food", "Music", "Film & TV", "Sport")
    ]}
    routes["/api/v1/commitments"] = {"commitments": [
        {"action": f"Task {i} " + "y" * 120, "owner": "user",
         "due": f"2099-02-{1 + i % 27:02d}", "status": "open", "source": ""}
        for i in range(80)], "count": 80}
    _, digest = _build(env, _SCRIPT, _large_store(), routes=routes)
    assert len(digest.encode("utf-8")) <= 6000, len(digest.encode("utf-8"))
    # The contract the BLOCKING walk probe reads is never what gets cut.
    about = _section(digest, "About you")
    assert "- Work: ExampleCo, Initech" in about
    # The tool-routing footer is not what gets cut either.
    assert "## Looking something up" in digest
    assert digest.rstrip().endswith("are the route to the graph.")


def test_cap_drops_whole_sections_and_says_so(env):
    """A tight cap drops the lowest-priority sections whole, in order, and
    declares each one rather than clipping mid-section."""
    env.setenv("OSTLER_CONTEXT_MAX_CHARS", "2400")
    _write_config(env)
    _, digest = _build(env, _SCRIPT, _brief_store(), routes=_brief_routes(),
                       name="gen_tight")
    assert len(digest) <= 2400
    assert "Left out to fit the size cap" in digest
    left_out = next(ln for ln in digest.splitlines()
                    if ln.startswith("- Left out to fit the size cap"))
    assert "Key organisations" in left_out
    # Whatever is named as left out has no heading in the body.
    for name in ("Key organisations", "Preferences and things to keep in mind"):
        if name in left_out:
            assert f"## {name}" not in digest
    assert "## About you" in digest and "- Work:" in digest
    assert "digest truncated" not in digest


def test_about_you_and_work_contract_still_holds(brief):
    _, digest = brief
    assert "## About you" in digest
    about = _section(digest, "About you")
    work = [ln for ln in about.splitlines() if ln.startswith("- Work:")]
    assert work == ["- Work: ExampleCo, Initech"], about
    # About you is the first content section, so it is never the one dropped.
    assert digest.index("## About you") < digest.index("## Autonomy calibration")


# ── PRIVACY: no L3, no message text, no secret from the shared config ────────


def test_no_canary_reaches_the_digest(brief):
    _, digest = brief
    for canary in CANARIES:
        assert canary not in digest, f"leaked: {canary}"
    # The seeded message-text predicate is never read by any query.
    assert "messageText" not in digest


def test_no_canary_reaches_the_digest_when_the_cap_is_tight(env):
    env.setenv("OSTLER_CONTEXT_MAX_CHARS", "2400")
    _write_config(env)
    _, digest = _build(env, _SCRIPT, _brief_store(), routes=_brief_routes(),
                       name="gen_tight2")
    for canary in CANARIES:
        assert canary not in digest


def test_generator_never_reads_message_text_predicates():
    """Static guard: the brief reads counts only. No query in the generator
    names a message-body predicate."""
    src = _SCRIPT.read_text(encoding="utf-8")
    for banned in ("messageText", "messageBody", "pwg:text", "utterance"):
        assert banned not in src.replace("utterances for the extractor", ""), banned
