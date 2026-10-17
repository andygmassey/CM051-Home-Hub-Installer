"""walk #24: one transient 502 from /api/v1/hydration/status made
owner_digest_knows_the_owner CANNOT-RUN. 5xx is retried inside the budget; a
non-5xx and an exhausted budget still fail. Synthetic only."""
import importlib.util
import io
import os
import urllib.error

_p = os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib", "owner_digest.py")
_s = importlib.util.spec_from_file_location("owner_digest_under_test", _p)
od = importlib.util.module_from_spec(_s)
_s.loader.exec_module(od)

OK = {"overall_state": "running", "phases": [{"key": "contacts", "state": "done"}, {"key": "graph", "state": "done"}]}


def _err(code):
    return urllib.error.HTTPError("http://x", code, "e", {}, io.BytesIO(b""))


def _seq(*items):
    q = list(items)

    def fetch():
        v = q.pop(0)
        if isinstance(v, Exception):
            raise v
        return v
    return fetch


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def run(*items, budget=30):
    c = Clock()
    return od.hydration(fetch=_seq(*items), sleep=c.sleep, clock=c, budget_s=budget, backoff_s=2)


def test_502_then_200_is_hydrated_and_records_attempts():
    ready, detail = run(_err(502), OK)
    assert ready is True and "attempts=2" in detail and "statuses=502,200" in detail


def test_non_5xx_is_not_retried():
    ready, detail = run(_err(401), OK)
    assert ready is False and "attempts=1" in detail and "HTTP 401" in detail


def test_persistent_5xx_exhausts_the_budget():
    ready, detail = run(*[_err(502)] * 50, budget=10)
    assert ready is False and "budget" in detail and "HTTP 502" in detail


def test_200_first_time_is_one_attempt():
    ready, detail = run(OK)
    assert ready is True and "attempts=1" in detail


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
