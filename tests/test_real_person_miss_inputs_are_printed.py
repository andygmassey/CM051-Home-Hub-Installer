"""walk #25: anchor=False printed no classifier inputs, so a load timeout could
not be told from a product non-answer. Hashes, counts and seconds only."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib"))
import hub_screens as hs  # noqa: E402

LABEL = "chat: a real person's compiled page renders with their name"


def _facts(rp, asks=None):
    f = hs._good()
    f["person_link"]["real_person"] = rp
    if asks is not None:
        f["person_link"]["asks"] = asks
    return f


def _detail(f, label=LABEL):
    return [r for r in hs.judge(f) if r[0] == label][0][2]


def test_anchor_false_with_a_linked_person_prints_every_input():
    mi = hs.miss_inputs("robbie-wang", ["/People/lizzie-li/"], 1, 812, 31.4)
    d = _detail(_facts({"checked": True, "anchor": False, "any_person_link": True, "miss_inputs": mi}))
    for needle in ("any_person_link=True", "new_person_links=1", "expected_sha8=" + hs._sha8("robbie-wang"),
                   "linked_sha8s=" + hs._sha8("lizzie-li"), "reply_len=812", "elapsed=31.4s of 240s",
                   "timed_out=False"):
        assert needle in d, (needle, d)
    assert "robbie" not in d.casefold() and "lizzie" not in d.casefold()


def test_a_wait_that_ran_out_reads_as_timed_out():
    mi = hs.miss_inputs("robbie-wang", [], 0, 0, 240.2)
    assert mi["timed_out"] is True and mi["any_person_link"] is False
    d = _detail(_facts({"checked": True, "anchor": False, "miss_inputs": mi}))
    assert "timed_out=True" in d and "any_person_link=False" in d and "linked_sha8s=-" in d


def test_a_verdict_also_carries_the_inputs():
    mi = hs.miss_inputs("robbie-wang", ["/People/lizzie-li/"], 1, 100, 20)
    lm = hs.classify_link_miss("robbie-wang", ["/People/lizzie-li/"], False)
    d = _detail(_facts({"checked": True, "anchor": False, "link_miss": lm, "miss_inputs": mi}))
    assert "assistant_linked_wrong_person" in d and "reply_len=100" in d


def test_each_ask_reports_status_and_elapsed_when_one_did_not_reply():
    asks = [{"replied": True, "anchor": True, "status": "got", "elapsed_s": 12.0},
            {"replied": False, "anchor": False, "status": "timed-out", "elapsed_s": 240.1},
            {"replied": True, "anchor": True, "status": "got", "elapsed_s": 9.5}]
    d = _detail(_facts({"checked": True, "anchor": True, "page": {"state": "rendered", "heading_names_person": True}}, asks),
                "chat: every one of 3 replies carries an in-app person link")
    assert "2 of 3" in d and "timed-out 240.1s" in d and "got 12.0s" in d


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
