"""walk #26: a real-person ask timed out at 241.6s against a fixed 240s (reply
slow, not wrong). The wait is a budget from this walk's own measured turns,
ends on the done frame, is capped, and prints budget/inputs/elapsed."""
import os
import sys

_R = os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes")
sys.path.insert(0, os.path.join(_R, "lib"))
import hub_screens as hs  # noqa: E402

LABEL = "chat: a real person's compiled page renders with their name"


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def test_budget_floor_scale_and_cap():
    assert hs.chat_wait_budget([])["budget_s"] == 240
    b = hs.chat_wait_budget([100, 110, 120])          # p90 = 120 -> 3 x 120 = 360
    assert b["budget_s"] == 360 and b["p90_s"] == 120 and b["turns"] == 3
    assert hs.chat_wait_budget([30, 40])["budget_s"] == 240        # floor holds
    c = hs.chat_wait_budget([400, 500])
    assert c["budget_s"] == 600 and c["capped"] is True            # hard cap


def test_a_reply_at_250s_is_waited_for():
    """RED today: a fixed 240s wait gives up at 240. With a budget sized from
    earlier ~110s turns (330s) the 250s reply is received."""
    c = Clock()
    b = hs.chat_wait_budget([100, 105, 110])
    w = hs.wait_for_reply(lambda: c() >= 250, b["budget_s"], clock=c, sleep=c.sleep)
    assert w["state"] == "done" and 249 <= w["elapsed_s"] <= 256
    c2 = Clock()   # and the fixed 240s wait of the old code does time out on the same reply
    assert hs.wait_for_reply(lambda: c2() >= 250, 240, clock=c2, sleep=c2.sleep)["state"] == "timeout"


def test_a_reply_that_never_arrives_ends_at_the_cap_with_elapsed():
    c = Clock()
    b = hs.chat_wait_budget([400, 500])
    w = hs.wait_for_reply(lambda: False, b["budget_s"], clock=c, sleep=c.sleep)
    assert w["state"] == "timeout" and 600 <= w["elapsed_s"] <= 603
    f = hs._good()
    f["person_link"]["real_person"] = {"checked": True, "anchor": False,
                                       "wait": {"state": w["state"], "elapsed_s": w["elapsed_s"], "budget": b}}
    row = [r for r in hs.judge(f) if r[0] == LABEL][0]
    assert row[1] is None and "CANNOT-RUN (harness)" in row[2]
    assert "budget=600" in row[2] and "elapsed={}s".format(w["elapsed_s"]) in row[2] and "state=timeout" in row[2]


def test_the_done_frame_ends_the_wait():
    assert hs.frame_is_done('{"type": "done", "full_response": "x"}') is True
    assert hs.frame_is_done(b'{"type":"done"}') is True
    assert hs.frame_is_done('{"type": "chunk"}') is False and hs.frame_is_done("not json") is False


def test_no_probe_suggests_a_machine_floor():
    p = os.path.join(_R, "probes", "assistant_grounds_the_opening_turn.sh")
    text = open(p).read()
    assert "SPEC DECISION" not in text and "minimum supported machine" not in text


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
