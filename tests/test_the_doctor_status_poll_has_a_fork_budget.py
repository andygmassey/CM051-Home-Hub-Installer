#!/usr/bin/env python3
"""A status poll must not fork once per probe, once per second, forever.

THE DEFECT. box_status() ran five subprocesses per call and the Hub WebView
polls it roughly once a second. Measured on a live box: 58,914 forks in about
40 hours, against a control of 0 to 44 for every comparable daemon on the same
machine. macOS calls that inefficient and SIGTERMs the daemon; KeepAlive
respawns it; every open Doctor tab is dropped mid-session. The exit code stays
0 throughout, which is why no health check we own could see it.

WHAT THIS ASSERTS, and it is deliberately about the CUSTOMER'S SESSION rather
than about a cache: over a minute of polling at the real poll rate, the daemon
must fork a bounded number of times, not an unbounded one. A cache is the
mechanism; surviving the minute is the property.

It counts real forks by wrapping subprocess.run, so it measures what the
kernel would see, not what the code intends.
"""
import pathlib, sys, time, unittest
from unittest import mock

AGENT = pathlib.Path(__file__).resolve().parents[1] / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))
import box_status  # noqa: E402

POLLS = 60          # one minute at the observed ~1 Hz poll rate
BUDGET = 12         # generous: five probes on the first poll, then refreshes


class ForkBudget(unittest.TestCase):
    def _count_forks(self, polls: int) -> int:
        calls = []
        real = box_status.subprocess.run

        def counting(*a, **kw):
            calls.append(a[0] if a else kw.get("args"))
            return real(*a, **kw)

        box_status._cache_clear()
        with mock.patch.object(box_status.subprocess, "run", counting):
            for _ in range(polls):
                box_status.box_status()
        return len(calls)

    def test_a_minute_of_polling_is_bounded(self):
        forks = self._count_forks(POLLS)
        print(f"\n  {POLLS} polls -> {forks} forks "
              f"({forks / POLLS:.2f} per poll, budget {BUDGET})")
        self.assertLessEqual(
            forks, BUDGET,
            f"{forks} forks for {POLLS} polls. Unbudgeted, this is {POLLS * 5} "
            f"and macOS kills the daemon for it.")

    def test_the_counter_can_actually_see_forks(self):
        """POSITIVE CONTROL.

        If the counter were broken it would report 0 for everything and this
        whole file would pass while measuring nothing. So call the UNCACHED
        probes directly and require a non-zero count.
        """
        calls = []
        real = box_status.subprocess.run

        def counting(*a, **kw):
            calls.append(a[0] if a else kw.get("args"))
            return real(*a, **kw)

        with mock.patch.object(box_status.subprocess, "run", counting):
            box_status._uncached__total_ram_bytes()
            box_status._uncached__ps_user_map()
        self.assertGreaterEqual(
            len(calls), 2,
            "the fork counter saw nothing while two real subprocesses ran, so "
            "every zero it reports elsewhere is meaningless")
        print(f"  control: {len(calls)} forks seen when 2 were forced")

    def test_the_first_poll_still_does_real_work(self):
        """A cache that returns nothing would also pass a fork budget.

        So require that the first poll DOES fork: the fix must be fewer forks,
        not a daemon that stopped measuring the box.
        """
        box_status._cache_clear()
        forks = self._count_forks(1)
        self.assertGreater(
            forks, 0,
            "the very first poll forked nothing, so the daemon is not actually "
            "reading the machine and the budget is being met by doing no work")
        print(f"  first poll forks: {forks} (must be > 0)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
