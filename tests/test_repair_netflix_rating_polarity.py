"""Tests for repair_netflix_rating_polarity.plan_for_point.

Pure decision logic only -- no Qdrant needed. See the module docstring for
why the marker check has to run before the rating_type check, not after.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from repair_netflix_rating_polarity import (  # noqa: E402
    MARKER_KEY,
    plan_for_point,
)


def _payload(rating_type, marker=None, **extra_extra):
    extra = {"type": "rating", "platform": "Netflix", "rating_type": rating_type}
    if marker is not None:
        extra[MARKER_KEY] = marker
    extra.update(extra_extra)
    return {
        "preference_type": "Like" if rating_type in ("thumbs_up", "two_thumbs_up") else "Dislike",
        "strength": 0.0,
        "subject": "Some Show",
        "category": "tv_show",
        "extra": extra,
    }


def test_two_thumbs_down_reclassifies_to_like_thumbs_up():
    plan = plan_for_point(_payload("two_thumbs_down"))
    assert plan["action"] == "set_payload"
    assert plan["payload"]["preference_type"] == "Like"
    assert plan["payload"]["strength"] == 0.35
    assert plan["payload"]["extra"]["rating_type"] == "thumbs_up"
    assert plan["payload"]["extra"][MARKER_KEY] is True


def test_thumbs_up_reclassifies_to_dislike_thumbs_down():
    plan = plan_for_point(_payload("thumbs_up"))
    assert plan["action"] == "set_payload"
    assert plan["payload"]["preference_type"] == "Dislike"
    assert plan["payload"]["strength"] == -0.35
    assert plan["payload"]["extra"]["rating_type"] == "thumbs_down"
    assert plan["payload"]["extra"][MARKER_KEY] is True


def test_thumbs_down_unmarked_is_deleted_not_rated():
    plan = plan_for_point(_payload("thumbs_down"))
    assert plan["action"] == "delete"


def test_two_thumbs_up_was_already_correct_and_is_untouched():
    plan = plan_for_point(_payload("two_thumbs_up"))
    assert plan["action"] == "skip"


def test_non_rating_point_with_no_rating_type_is_untouched():
    """A viewing-history point: extra carries no rating_type at all."""
    payload = {
        "preference_type": "Like",
        "strength": 0.3,
        "extra": {"type": "view", "platform": "Netflix"},
    }
    plan = plan_for_point(payload)
    assert plan["action"] == "skip"


def test_control_already_repaired_two_thumbs_down_is_not_touched_again():
    """CONTROL (the whole reason the marker exists): a record already
    reclassified from two_thumbs_down now carries rating_type='thumbs_up'
    AND the marker. Without checking the marker FIRST, this looks
    identical to a genuinely-wrong, never-repaired thumbs_up record and
    would be flipped straight back to a dislike."""
    payload = _payload("thumbs_up", marker=True)
    plan = plan_for_point(payload)
    assert plan["action"] == "skip"


def test_control_already_repaired_thumbs_up_is_not_touched_again():
    """Same control, the other reclassified direction: now reads
    rating_type='thumbs_down' with the marker -- must not be re-flipped,
    and critically must NOT be deleted either (it would look identical to
    a genuine not-rated row by label alone)."""
    payload = _payload("thumbs_down", marker=True)
    plan = plan_for_point(payload)
    assert plan["action"] == "skip"


def test_other_extra_keys_survive_a_reclassification():
    """A profile name or any other extra key must not be dropped by the
    reclassify action -- only rating_type and the marker change."""
    payload = _payload("two_thumbs_down", profile="Family")
    plan = plan_for_point(payload)
    assert plan["action"] == "set_payload"
    assert plan["payload"]["extra"]["profile"] == "Family"
    assert plan["payload"]["extra"]["platform"] == "Netflix"


def test_other_top_level_payload_keys_survive_a_reclassification():
    payload = _payload("thumbs_up")
    plan = plan_for_point(payload)
    assert plan["payload"]["subject"] == "Some Show"
    assert plan["payload"]["category"] == "tv_show"


def test_non_netflix_rating_type_shaped_like_wrong_label_is_still_a_dict_not_crash():
    """CONTROL: extra that is not a dict (malformed data) must skip
    cleanly, never raise."""
    plan = plan_for_point({"preference_type": "Like", "strength": 0.1, "extra": "not-a-dict"})
    assert plan["action"] == "skip"
