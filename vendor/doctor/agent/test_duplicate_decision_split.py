"""Doctor duplicate-decision endpoint: the ``split`` action (Andy 2026-06-12).

The wiki "One contact that looks like two people" card POSTs
``{action: "split", ids: [one_id]}``. Unlike merge/distinct (pairwise, 2+ ids),
split flags a SINGLE fused record for separation. These tests pin that the
endpoint accepts a single-id split, writes a ``split:`` entry, and still rejects
malformed payloads.
"""
import tempfile
from pathlib import Path

import duplicate_decision as dd


def test_split_accepts_single_id():
    norm = dd.validate_payload({"action": "split", "ids": ["fused1"]})
    assert norm == {"action": "split", "ids": ["fused1"]}


def test_split_writes_split_entry():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "duplicates.yaml"
        norm = dd.validate_payload({"action": "split", "ids": ["fused1"]})
        result = dd.write_decision(norm, path=path)
        assert {"split": ["fused1"]} in result["added"]
        text = path.read_text(encoding="utf-8")
        assert "split" in text and "fused1" in text


def test_split_is_idempotent():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "duplicates.yaml"
        norm = dd.validate_payload({"action": "split", "ids": ["fused1"]})
        dd.write_decision(norm, path=path)
        second = dd.write_decision(norm, path=path)
        assert second["added"] == []  # already recorded, not duplicated


def test_merge_still_needs_two_ids():
    for bad in ({"action": "merge", "ids": ["only_one"]},
                {"action": "distinct", "ids": ["only_one"]}):
        try:
            dd.validate_payload(bad)
            assert False, f"expected ValidationError for {bad}"
        except dd.ValidationError:
            pass


def test_split_still_validates_id_shape():
    try:
        dd.validate_payload({"action": "split", "ids": ["bad id!"]})
        assert False, "expected ValidationError for malformed id"
    except dd.ValidationError:
        pass
