"""Walk #23: the wiki People/timeline "participants" line showed role tags
and a raw phone number. Synthetic data only (cast name, 555-01xx number).

The enrichment prompts show `{user_name} (user)` / `{other_name} (...)` as a
roster shape; the model copies the tags and the unresolved participant's
display is its raw number. Vendored cm048 now normalises the roster.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import enrichment_validation as ev

OWNER = "Jane"
NUMBER = "+1 555 0142"
PARTS = [
    {"id": "owner", "display": OWNER, "role": "user"},
    {"id": NUMBER, "display": NUMBER, "role": "other"},
]
BAD = (
    "## Summary\n\n### Participants\n"
    f"- {OWNER} (user) (user)\n"
    f"- {NUMBER} (other_name) (new acquaintance, ex-Acme)\n\n"
    "### Location\nRemote\n"
)


def _roster(text):
    sec = text.split("### Participants")[1].split("###")[0]
    return [l[2:] for l in sec.splitlines() if l.startswith("- ")]


def test_exact_reported_shape_is_cleaned():
    out = ev.sanitise_participants_section(BAD, PARTS, OWNER)
    assert _roster(out) == ["You", "an unknown contact"]
    for bad in ("(user)", "(other_name)", "555", "new acquaintance"):
        assert bad not in out
    assert "### Location\nRemote" in out


def test_control_old_text_has_the_defect():
    # the specimen really carries what the fix must remove
    assert "(user) (user)" in BAD and "(other_name)" in BAD and "555" in BAD


def test_single_line_comma_roster_and_dedupe():
    text = f"### Participants\n- {OWNER} (user), {OWNER} (user), {NUMBER} (other_name)\n"
    assert _roster(ev.sanitise_participants_section(text, PARTS, OWNER)) == [
        "You", "an unknown contact"]


def test_resolved_name_replaces_handle_and_email_is_unknown():
    parts = PARTS + [{"id": "+1 555 0143", "display": "Bob", "role": "other"}]
    text = "### Participants\n- +1 555 0143 (other_name)\n- bob@example.com\n"
    assert _roster(ev.sanitise_participants_section(text, parts, OWNER)) == [
        "Bob", "an unknown contact"]


def test_no_participants_section_is_untouched():
    t = "## Summary\n\nText (user) here\n"
    assert ev.sanitise_participants_section(t, PARTS, OWNER) == t


def test_both_enrich_paths_call_it():
    src = (Path(__file__).resolve().parent.parent / "vendor/cm048_pipeline/src/processor.py").read_text()
    assert src.count("enrichment_validation.sanitise_participants_section(") == 2
