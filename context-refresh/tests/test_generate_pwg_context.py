"""Tests for the context-refresh digest generator.

Exercises ``generate_pwg_context.build_digest`` with injected graph data so we
can assert the layout of CONTEXT.md without a live Oxigraph or ical-server.

Focus of this suite (the "reused everywhere" half of the learning loop): facts
the customer explicitly confirmed to the assistant -- pwg:PersonFact nodes with
pwg:factSource "user_asserted", banked by CM041's assert endpoint -- must
surface PROMINENTLY at the top of the digest, above anything mined or derived.

The script lives at ``bin/generate_pwg_context.py`` (no package), so we load it
by path with importlib, matching the repo's "drive the artefact directly"
test convention.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_SCRIPT = (
    Path(__file__).resolve().parent.parent / "bin" / "generate_pwg_context.py"
)


def _load_module():
    spec = importlib.util.spec_from_file_location("generate_pwg_context", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def gen():
    return _load_module()


# ── Helpers to inject graph data ─────────────────────────────────────────────


def _patch_sparql(monkeypatch, module, rows):
    """Make _sparql_select return ``rows`` (the user-asserted facts query)."""
    monkeypatch.setattr(module, "_sparql_select", lambda sparql: rows)


def _patch_hub(monkeypatch, module, mapping):
    """Stub the ical-server HTTP layer so mined sections have data."""

    def fake_get_json(path: str):
        for prefix, payload in mapping.items():
            if path.startswith(prefix):
                return payload
        return None

    monkeypatch.setattr(module, "_get_json", fake_get_json)


_MINED_HUB = {
    "/api/v1/suggestions": {
        "recent_meetings": [
            {"name": "Danny Kwan", "organisation": "Randstad",
             "last_contact": "2026-06-10"},
        ],
    },
    "/api/v1/timeline": {"items": []},
    "/api/v1/coach/recent": {"observations": []},
}


# ── Tests ────────────────────────────────────────────────────────────────────


def test_user_asserted_section_present_and_first(monkeypatch, gen):
    """A user_asserted fact renders a 'Confirmed by you' section, ahead of the
    mined 'People you interact with most' section, and includes the fact text."""
    _patch_sparql(monkeypatch, gen, [
        {"text": "Robin is your wife", "name": "Robin Carter",
         "rel": "wife", "created": "2026-06-16T09:00:00Z"},
    ])
    _patch_hub(monkeypatch, gen, _MINED_HUB)

    digest = gen.build_digest()
    assert digest is not None

    # (a) the section exists
    assert "## Confirmed by you" in digest
    # (c) the user-asserted fact text is included
    assert "Robin is your wife" in digest

    # (b) it lands BEFORE the mined People section
    confirmed_at = digest.index("## Confirmed by you")
    people_at = digest.index("## People you interact with most")
    assert confirmed_at < people_at

    # And above the digest's own per-section ordering generally: the confirmed
    # block precedes every mined heading present.
    for mined in ("## People you interact with most",):
        assert confirmed_at < digest.index(mined)


def test_user_asserted_section_omitted_when_none(monkeypatch, gen):
    """No user_asserted facts -> no 'Confirmed by you' header at all (and no
    empty section), but mined sections still render."""
    _patch_sparql(monkeypatch, gen, [])  # store reachable, simply nothing
    _patch_hub(monkeypatch, gen, _MINED_HUB)

    digest = gen.build_digest()
    assert digest is not None
    assert "## Confirmed by you" not in digest
    # mined content still present, proving the digest itself was built
    assert "## People you interact with most" in digest


def test_user_asserted_survives_unreachable_oxigraph(monkeypatch, gen):
    """If Oxigraph is unreachable (_sparql_select -> None), the section is
    omitted gracefully and the rest of the digest still builds."""
    monkeypatch.setattr(gen, "_sparql_select", lambda sparql: None)
    _patch_hub(monkeypatch, gen, _MINED_HUB)

    digest = gen.build_digest()
    assert digest is not None
    assert "## Confirmed by you" not in digest
    assert "## People you interact with most" in digest


def test_user_asserted_dedupes_and_caps(monkeypatch, gen):
    """Duplicate fact text collapses to one bullet; the section is capped."""
    rows = [{"text": "Robin is your wife"} for _ in range(3)]
    rows += [{"text": f"Fact number {i}"} for i in range(gen.MAX_USER_ASSERTED + 10)]
    _patch_sparql(monkeypatch, gen, rows)
    _patch_hub(monkeypatch, gen, _MINED_HUB)

    digest = gen.build_digest()
    assert digest is not None

    section = digest.split("## Confirmed by you", 1)[1]
    section = section.split("## People you interact with most", 1)[0]
    bullets = [ln for ln in section.splitlines() if ln.startswith("- ")]
    # de-duplicated: one "Robin" bullet, not three
    assert sum(1 for b in bullets if "Robin is your wife" in b) == 1
    # capped at MAX_USER_ASSERTED
    assert len(bullets) <= gen.MAX_USER_ASSERTED


def test_digest_none_when_nothing_anywhere(monkeypatch, gen):
    """No user-asserted facts and no mined data -> build_digest returns None so
    the caller leaves the prior CONTEXT.md untouched."""
    monkeypatch.setattr(gen, "_sparql_select", lambda sparql: None)
    monkeypatch.setattr(gen, "_get_json", lambda path: None)
    assert gen.build_digest() is None


# ── Calendar-by-owner section (travel/flight conflation fix) ─────────────────


def _patch_sparql_by_query(monkeypatch, module, *, calendar_rows=None,
                           user_asserted_rows=None):
    """Route _sparql_select by the query body so the calendar section and the
    user-asserted section get their own rows (both use _sparql_select)."""
    def fake(sparql: str):
        if 'pwg:factDomain "calendar"' in sparql:
            return calendar_rows or []
        return user_asserted_rows or []
    monkeypatch.setattr(module, "_sparql_select", fake)


def test_calendar_events_grouped_and_labelled_by_owner(monkeypatch, gen):
    """Two owners' flights with the SAME summary must render under distinct,
    labelled owner blocks -- the core anti-conflation guarantee."""
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[
        {"text": "Calendar event: 'Flight to Tokyo' on 01 August 2026",
         "valid": "2026-08-01T09:00:00", "level": "L1"},
        {"text": "Calendar event: 'Flight to Tokyo' on 01 August 2026",
         "owner": "Robin", "type": "family",
         "valid": "2026-08-01T09:00:00", "level": "L1"},
    ])
    _patch_hub(monkeypatch, gen, _MINED_HUB)

    digest = gen.build_digest()
    assert digest is not None
    assert "## Calendar events by owner" in digest
    # both owners labelled and distinct
    assert "**Your calendar:**" in digest
    assert "**Robin:**" in digest
    # the attribution guardrail text is present for the model
    assert "never merge two people's events" in digest
    # Robin's block owns her flight; it is not merged into "Your calendar"
    alison_at = digest.index("**Robin:**")
    yours_at = digest.index("**Your calendar:**")
    assert yours_at < alison_at  # operator's own diary rendered first


def test_calendar_l3_event_withheld(monkeypatch, gen):
    """An L3 (private) calendar event is never surfaced in the digest."""
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[
        {"text": "Calendar event: 'Secret trip' on 02 August 2026",
         "owner": "Work", "type": "work", "valid": "2026-08-02T00:00:00",
         "level": "L3"},
    ])
    _patch_hub(monkeypatch, gen, _MINED_HUB)
    digest = gen.build_digest()
    # section omitted entirely (only row was L3) and content absent
    assert "Secret trip" not in (digest or "")


def test_calendar_section_omitted_when_no_calendar_facts(monkeypatch, gen):
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[])
    _patch_hub(monkeypatch, gen, _MINED_HUB)
    digest = gen.build_digest()
    assert digest is not None
    assert "## Calendar events by owner" not in digest


# ── Retirement of the un-attributed upcoming section (BATCH1 #3 F1) ───────────


def test_upcoming_calendar_events_never_rendered_unattributed(monkeypatch, gen):
    """A future calendar-kind timeline row (which carries NO owner) must never
    surface under an un-labelled 'Upcoming meetings' heading. The section is
    retired: calendar events reach the brief only via the owner-labelled
    section, so a shared-calendar flight cannot leak as the operator's own."""
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[])
    _patch_hub(monkeypatch, gen, {
        "/api/v1/suggestions": {"recent_meetings": []},
        "/api/v1/timeline": {"items": [
            {"summary": "Partner's flight to Tokyo", "date": "2026-08-01",
             "kind": "calendar"},
        ]},
        "/api/v1/coach/recent": {"observations": []},
    })
    digest = gen.build_digest()
    # The un-attributed upcoming heading is gone entirely...
    assert "## Upcoming meetings" not in (digest or "")
    # ...and the leaky calendar summary does not reach the brief via this path.
    assert "Partner's flight to Tokyo" not in (digest or "")


def test_recent_meetings_still_render(monkeypatch, gen):
    """Past meeting-kind timeline rows (genuine meeting history, not calendar
    diary entries) still render under 'Recent meetings'."""
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[])
    _patch_hub(monkeypatch, gen, {
        "/api/v1/suggestions": {"recent_meetings": []},
        "/api/v1/timeline": {"items": [
            {"summary": "Standup with Danny", "date": "2026-06-10",
             "kind": "meeting"},
        ]},
        "/api/v1/coach/recent": {"observations": []},
    })
    digest = gen.build_digest()
    assert digest is not None
    assert "## Recent meetings" in digest
    assert "Standup with Danny" in digest


def test_l3_calendar_kind_timeline_row_withheld(monkeypatch, gen):
    """Even were a calendar-kind row L3, it is withheld; combined with the
    retirement above, no un-attributed calendar entry can reach the brief."""
    _patch_sparql_by_query(monkeypatch, gen, calendar_rows=[])
    _patch_hub(monkeypatch, gen, {
        "/api/v1/suggestions": {"recent_meetings": []},
        "/api/v1/timeline": {"items": [
            {"summary": "Private offsite", "date": "2026-08-01",
             "kind": "calendar", "privacy_level": "L3"},
        ]},
        "/api/v1/coach/recent": {"observations": []},
    })
    digest = gen.build_digest()
    assert "Private offsite" not in (digest or "")
