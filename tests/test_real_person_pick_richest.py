"""Fix: the walk's real-person chooser prefers the person the graph knows most
about, so the assistant can resolve them. Synthetic names only."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib"))
import real_person_pick as rpp  # noqa: E402

PAGES = "index.md\nrobbie-wang.md\nlizzie-li.md\nwei-zhang.md\n"


def _pick(rows):
    return rpp.pick(json.dumps({"people": rows}), PAGES, "", [])[0]


def test_richest_wins_over_recency_order():
    ch = _pick([{"name": "Robbie Wang", "fact_count": 0},
                {"name": "Lizzie Li", "fact_count": 41},
                {"name": "Wei Zhang", "fact_count": 7}])
    assert ch and ch[0] == "Lizzie Li"


def test_alternate_count_field_names():
    ch = _pick([{"name": "Robbie Wang", "interaction_count": 2},
                {"name": "Wei Zhang", "interaction_count": 9}])
    assert ch and ch[0] == "Wei Zhang"


def test_tie_and_no_counts_keep_recency_order():
    assert _pick([{"name": "Robbie Wang"}, {"name": "Lizzie Li"}])[0] == "Robbie Wang"
    assert _pick([{"name": "Robbie Wang", "fact_count": 3},
                  {"name": "Lizzie Li", "fact_count": 3}])[0] == "Robbie Wang"


def test_richest_without_a_page_is_still_rejected():
    ch = _pick([{"name": "Robbie Wang", "fact_count": 1},
                {"name": "Nopage Person", "fact_count": 99}])
    assert ch and ch[0] == "Robbie Wang"
