"""walk #24: any_person_link=true but not the chosen slug. Instrumented, not
guessed: heading matches -> harness slug mismatch (CANNOT-RUN); heading differs
-> assistant_linked_wrong_person (FAIL, PRODUCT). Cast names only."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib"))
import hub_screens as hs  # noqa: E402

LABEL = "chat: a real person's compiled page renders with their name"


def _facts(link_miss):
    f = hs._good()
    f["person_link"]["real_person"] = {"checked": True, "anchor": False, "any_person_link": True,
                                       "link_miss": link_miss}
    return f


def _row(f):
    return [r for r in hs.judge(f) if r[0] == LABEL][0]


def test_heading_matches_is_a_harness_cannot_run():
    lm = hs.classify_link_miss("robbie-wang-2", ["/People/robbie-wang/"], True)
    assert lm["classification"] == "slug_format_mismatch"
    name, ok, detail = _row(_facts(lm))
    assert ok is None and "CANNOT-RUN (harness)" in detail


def test_heading_differs_is_a_product_fail():
    lm = hs.classify_link_miss("robbie-wang", ["/People/lizzie-li/"], False)
    assert lm["classification"] == "assistant_linked_wrong_person"
    name, ok, detail = _row(_facts(lm))
    assert ok is False and "assistant_linked_wrong_person" in detail and "PRODUCT" in detail


def test_record_is_hash_only():
    lm = hs.classify_link_miss("robbie-wang", ["/People/lizzie-li/", "/People/wei-zhang/"], False)
    flat = repr(lm) + repr(_row(_facts(lm)))
    assert "robbie" not in flat.casefold() and "lizzie" not in flat.casefold() and "zhang" not in flat.casefold()
    assert len(lm["expected_slug_sha8"]) == 8 and len(lm["linked_slug_sha8s"]) == 2
    assert lm["expected_slug_sha8"] == hs._sha8("robbie-wang")


def test_a_true_anchor_is_unaffected():
    f = hs._good()
    assert _row(f)[1] is True


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
