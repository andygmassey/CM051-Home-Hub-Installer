#!/usr/bin/env python3
"""no_person_holds_two_contact_cards must not call a STALE contacts/diff report a miss.

The Hub serves a cached /api/v1/contacts/diff report (ical-server.py
_contacts_diff_cached) that can predate the walk seed, so a seeded duplicate
pair is absent from it and the probe read that as UNREVIEWED (false FAIL).
Now: wait (bounded) for as_of > seed time and refreshing false; on expiry the
verdict is CANNOT-RUN with as_of in the detail, never FAIL and never PASS.

Runs the REAL judge (DECLARED[13]) and the REAL wait loop with a stubbed fetch
and a fake clock. Synthetic data only. Exit 0 all pass, 1 any fail.
"""
import copy
import datetime as dt
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import customer_read as cr  # noqa: E402

SEED = 1_800_000_000.0


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat(timespec="seconds")


def verdict13(extra, reviewed):
    f = copy.deepcopy(cr._good())
    f["people_rows"] += ["Jane Doe\n+44 7700 900008", "John Doe\n+44 7700 900008"]
    f["duplicate_review_phones"] = reviewed
    f.update(extra)
    out = [r for r in cr.judge(f) if r[0] == cr.DECLARED[13]]
    assert len(out) == 1, out
    return out[0]


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def wait(responses, seed_ts=SEED, bound=720, poll=15):
    c = Clock()
    seq = list(responses)
    calls = []

    def fetch():
        calls.append(c.t)
        return seq.pop(0) if len(seq) > 1 else seq[0]

    diff, stale = cr.wait_for_fresh_diff(fetch, seed_ts, bound, poll, sleep=c.sleep, clock=c.now)
    return diff, stale, calls


STALE = {"as_of": iso(SEED - 300), "refreshing": False, "items": []}
FRESH = {"as_of": iso(SEED + 60), "refreshing": False, "items": []}

CASES = []


def case(label):
    def deco(fn):
        CASES.append((label, fn))
        return fn
    return deco


@case("judge: stale report + missing card -> CANNOT-RUN (main says FAIL)")
def _():
    v = verdict13({"duplicate_review_stale": "stale report after 720s", "duplicate_review_as_of": iso(SEED - 300),
                   "duplicate_review_refreshing": False, "duplicate_review_seed_ts": SEED}, [])
    return v[1] is None and iso(SEED - 300) in v[2] and "refreshing=False" in v[2], v


@case("judge: fresh report + missing card -> still FAIL (control: a real miss is caught)")
def _():
    v = verdict13({"duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False,
                   "duplicate_review_seed_ts": SEED}, [])
    return v[1] is False and iso(SEED + 60) in v[2], v


@case("judge: fresh report + card -> PASS, as_of and refreshing recorded")
def _():
    v = verdict13({"duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False,
                   "duplicate_review_seed_ts": SEED}, ["447700900008"])
    return v[1] is True and "refreshing=False" in v[2], v


@case("wait: stale for the whole bound -> stale reason, as_of kept, polled repeatedly")
def _():
    diff, stale, calls = wait([STALE])
    return bool(stale) and "not later than the seed" in stale and diff["as_of"] == STALE["as_of"] and len(calls) > 10, (stale, len(calls))


@case("wait: stale, then a post-seed report arrives -> settled, no stale")
def _():
    diff, stale, calls = wait([STALE, STALE, FRESH])
    return stale is None and diff is FRESH and len(calls) == 3, (stale, len(calls))


@case("wait: post-seed as_of but refreshing=true never clears -> stale")
def _():
    busy = dict(FRESH, refreshing=True)
    diff, stale, _ = wait([busy])
    return bool(stale) and "refreshing" in stale, stale


@case("wait: refreshing=true then false -> settled")
def _():
    diff, stale, _ = wait([dict(FRESH, refreshing=True), FRESH])
    return stale is None, stale


@case("wait: still 'preparing' for the whole bound -> stale")
def _():
    diff, stale, _ = wait([{"preparing": True, "items": [], "degraded": True}])
    return bool(stale) and "preparing" in stale, stale


@case("wait: as_of missing or unparseable with a seed time -> stale, never trusted")
def _():
    r1 = wait([{"refreshing": False, "items": []}], bound=60)[1]
    r2 = wait([{"as_of": "garbage", "refreshing": False, "items": []}], bound=60)[1]
    return bool(r1) and bool(r2), (r1, r2)


@case("wait: no seed time recorded -> only refreshing is required (settled on first read)")
def _():
    diff, stale, calls = wait([STALE], seed_ts=None)
    return stale is None and len(calls) == 1, (stale, len(calls))


@case("wait: as_of equal to the seed second is not 'later' -> stale")
def _():
    return bool(wait([dict(STALE, as_of=iso(SEED))], bound=60)[1]), None


@case("wiring (static; collect needs a browser): seed time flows seed -> probe -> main -> collect -> wait")
def _():
    root = os.path.dirname(HERE)
    rd = lambda *p: open(os.path.join(root, *p)).read()
    cr_src = rd("scripts", "box_walk_probes", "lib", "customer_read.py")
    got = (".walk-contact-cards-seed-ts" in rd("scripts", "box_walk_probes", "lib", "contact_cards_seed.sh"),
           ".walk-contact-cards-seed-ts" in rd("scripts", "box_walk_probes", "probes", "hub_screens_customer_read.sh")
           and "--seed-ts-file" in rd("scripts", "box_walk_probes", "probes", "hub_screens_customer_read.sh"),
           'a.get("--seed-ts-file")' in cr_src and "seed_ts=seed_ts" in cr_src,
           "wait_for_fresh_diff(_fetch, seed_ts)" in cr_src)
    return all(got), got


def main():
    bad = 0
    for label, fn in CASES:
        try:
            ok, got = fn()
        except Exception as exc:  # a missing function on main is a FAIL, not a crash
            ok, got = False, "{}: {}".format(type(exc).__name__, exc)
        bad += not ok
        print("%s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  (got %r)" % (got,)))
    print("%d case(s), %d failed" % (len(CASES), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
