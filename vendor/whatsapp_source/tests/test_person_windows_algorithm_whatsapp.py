"""Algorithm tests for the WhatsApp person_windows (carried from CM040 #15, same as CM048 #127).

Written RED first. Synthetic person ids and synthetic timestamps only.
Pure: input is normalised message rows; no store, no chat.db, no network.

Coverage:
  - windowed counts 30/90/365, sent vs received, by message timestamp
  - messages after "today" are not counted
  - naive datetimes are refused (naive export times are local, not UTC)
  - group messages are excluded
  - reciprocity is min/max of sent and received (0 when nothing sent)
  - active months: months (of 12) with at least one inbound AND one outbound
  - median owner reply latency from inbound to the next owner message
  - replies after the cap (7 days) do not count toward the median
  - last contact is the latest message of either direction
  - a person with no messages in a window reports 0, and no messages at all
    reports None for reciprocity and latency (unknown is not zero)
  - contract shape is stable (fixture pinned on the graph writer side)
"""
from __future__ import annotations

import json
import pathlib
from datetime import datetime, timedelta, timezone

import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT))
sys.path.insert(0, str(_REPO_ROOT / "vendor"))  # package __init__ imports ostler_fda

from vendor.whatsapp_source.person_windows import (
    Msg,
    contract_row,
    windowed,
)

TODAY = datetime(2026, 11, 15, 12, 0, tzinfo=timezone.utc)


def m(pid, days_ago, from_owner, *, hours=0, channel="imessage", group=False):
    ts = TODAY - timedelta(days=days_ago) + timedelta(hours=hours)
    return Msg(person_id=pid, channel=channel, ts=ts, from_owner=from_owner, group=group)


def by(rows):
    return {r["person_id"]: r for r in rows}


# --- counts and windows -----------------------------------------------------

def test_counts_by_window_split_sent_and_received():
    msgs = [
        m("p1", 5, True), m("p1", 5, False),        # inside 30
        m("p1", 60, True),                          # inside 90 only
        m("p1", 200, False),                        # inside 365 only
        m("p1", 400, True),                         # outside 365
    ]
    r = by(windowed(msgs, TODAY))["p1"]
    assert (r["sent_30"], r["recv_30"]) == (1, 1)
    assert (r["sent_90"], r["recv_90"]) == (2, 1)
    assert (r["sent_365"], r["recv_365"]) == (2, 2)


def test_messages_after_today_are_not_counted():
    msgs = [m("p1", -2, True), m("p1", 1, False)]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["sent_30"] == 0
    assert r["recv_30"] == 1
    assert r["last_contact_days"] == 1.0


def test_naive_datetime_is_refused():
    naive = Msg(person_id="p1", channel="imessage",
                ts=datetime(2026, 11, 10, 9, 0), from_owner=True, group=False)
    with pytest.raises(ValueError):
        windowed([naive], TODAY)


def test_group_messages_are_excluded():
    msgs = [m("p1", 3, True, group=True), m("p1", 3, False, group=True)]
    r = by(windowed(msgs, TODAY))
    assert "p1" not in r or r["p1"]["sent_365"] == 0


# --- reciprocity ------------------------------------------------------------

def test_reciprocity_is_min_over_max():
    msgs = [m("p1", 1, True)] * 4 + [m("p1", 2, False)] * 2
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["reciprocity_365"] == pytest.approx(0.5)


def test_reciprocity_is_zero_when_one_sided_and_none_when_empty_window():
    one_sided = [m("p1", 1, False)] * 3
    r = by(windowed(one_sided, TODAY))["p1"]
    assert r["reciprocity_365"] == 0.0
    r2 = by(windowed([m("p2", 500, True)], TODAY))["p2"]
    assert r2["reciprocity_365"] is None


# --- active months ----------------------------------------------------------

def test_active_months_counts_only_two_way_months():
    msgs = [
        m("p1", 10, True), m("p1", 9, False),       # two-way this month
        m("p1", 40, True),                          # one-way month
        m("p1", 70, True), m("p1", 69, False),      # two-way
    ]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["active_months_12"] == 2


# --- reply latency ----------------------------------------------------------

def test_median_reply_latency_in_minutes():
    msgs = [
        m("p1", 2, False, hours=0),
        m("p1", 2, True, hours=1),                  # 60 min
        m("p1", 1, False, hours=0),
        m("p1", 1, True, hours=3),                  # 180 min
        m("p1", 0, False, hours=-3),
        m("p1", 0, True, hours=-1),                 # 120 min
    ]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["median_reply_min_365"] == pytest.approx(120.0)
    assert r["reply_pairs_365"] == 3


def test_replies_beyond_seven_days_do_not_count():
    msgs = [m("p1", 20, False, hours=0), m("p1", 20, True, hours=24 * 8)]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["reply_pairs_365"] == 0
    assert r["median_reply_min_365"] is None


# --- last contact and unknowns ---------------------------------------------

def test_last_contact_is_latest_either_direction():
    msgs = [m("p1", 30, True), m("p1", 4, False), m("p1", 9, True)]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["last_contact_days"] == 4.0


def test_no_messages_means_no_row_not_zero_contact():
    assert windowed([], TODAY) == []


# --- contract ---------------------------------------------------------------

def test_contract_row_has_fixed_keys_and_no_names():
    r = contract_row(windowed([m("p1", 1, True), m("p1", 1, False)], TODAY)[0])
    expected = {
        "person_id", "sent_30", "recv_30", "sent_90", "recv_90", "sent_365", "recv_365",
        "reciprocity_365", "active_months_12", "median_reply_min_365", "reply_pairs_365",
        "last_contact_days",
    }
    assert set(r.keys()) == expected


def test_contract_fixture_matches_module():
    from vendor.whatsapp_source.person_windows import contract_snapshot
    path = pathlib.Path(__file__).parent / "fixtures" / "person_windows_contract.json"
    assert json.loads(path.read_text()) == contract_snapshot()


# --- edges the first mutant pass showed were unpinned -----------------------

def test_window_is_strict_at_the_boundary():
    r = by(windowed([m("p1", 30, True)], TODAY))["p1"]
    assert r["sent_30"] == 0
    assert r["sent_90"] == 1


def test_reply_latency_runs_from_the_first_unanswered_inbound():
    msgs = [
        m("p1", 3, False, hours=0),
        m("p1", 2, False, hours=0),
        m("p1", 2, True, hours=1),                  # 25 h after the first, 1 h after the second
    ]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["median_reply_min_365"] == pytest.approx(25 * 60.0)


def test_active_months_ignore_messages_older_than_a_year():
    msgs = [m("p1", 370, True), m("p1", 370, False)]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["active_months_12"] == 0


def test_median_not_mean_when_one_reply_is_slow():
    msgs = []
    for d, h in ((4, 1), (3, 1), (2, 10)):
        msgs += [m("p1", d, False, hours=0), m("p1", d, True, hours=h)]
    r = by(windowed(msgs, TODAY))["p1"]
    assert r["median_reply_min_365"] == pytest.approx(60.0)
