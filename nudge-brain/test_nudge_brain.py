"""Unit tests for the pure pieces of the proactive nudge brain (v1.0.1 #669).

Covers the judge (lead-time window + counterpart requirement) and the block
renderer. Network/LLM paths are intentionally not exercised here (they belong to
an on-box integration test, per the brief's verification gates).
"""

import datetime as _dt

import nudge_brain as nb

NOW = _dt.datetime(2026, 6, 11, 12, 0, 0, tzinfo=_dt.timezone.utc)


def _meeting(mins_out, **kw):
    start = (NOW + _dt.timedelta(minutes=mins_out)).isoformat()
    m = {"start": start, "title": "Sync", "person_slug": "patrick"}
    m.update(kw)
    return m


def test_minutes_until_parses_z_and_offset():
    assert abs(nb.minutes_until((NOW + _dt.timedelta(minutes=90)).isoformat(), NOW) - 90) < 0.01
    assert nb.minutes_until("not-a-time", NOW) is None


def test_judge_fires_only_in_window():
    fire, _ = nb.judge(_meeting(90), NOW)
    assert fire
    # too soon
    fire, reason = nb.judge(_meeting(5), NOW)
    assert not fire and "too soon" in reason
    # too far out
    fire, reason = nb.judge(_meeting(600), NOW)
    assert not fire and "too far" in reason


def test_judge_requires_human_counterpart():
    m = _meeting(90)
    m.pop("person_slug")
    fire, reason = nb.judge(m, NOW)
    assert not fire and "counterpart" in reason
    # an attendee (no slug) is enough to pass the prefilter
    m["attendee"] = "Patrick Eastwood"
    fire, _ = nb.judge(m, NOW)
    assert fire


def test_judge_unparseable_start():
    fire, reason = nb.judge({"start": "garbage", "person_slug": "x"}, NOW)
    assert not fire and "unparseable" in reason


def test_render_block_shapes_body():
    body = nb.render_block("Patrick", "http://hub/wiki/people/patrick", ["Runs Acme.", "Last time, you discussed Q3."])
    lines = body.splitlines()
    assert lines[0] == "Patrick in a bit."
    assert "Runs Acme." in body
    assert "Last time, you discussed Q3." in body
    assert lines[-1].startswith("More: http://hub/wiki/people/patrick")


def test_render_block_drops_empty_and_missing_wiki():
    body = nb.render_block("Mel", None, ["", "  ", "One real fact."])
    assert "More:" not in body          # no wiki url
    assert body.count("\n") == 1        # header + one real fact only
    assert "One real fact." in body


def test_render_block_no_name():
    body = nb.render_block("", None, [])
    assert body == "Coming up."
