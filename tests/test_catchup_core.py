"""Full-history catch-up: the shared machinery (lib/ostler_catchup.py).

What has to be true for Andy's v1.0.108 MUST ("it was supposed to work as you
described"), independent of any one source:

  * a walk reaches the OLDEST item, however many ticks it takes;
  * a tick is bounded by its budget and stops on a busy machine without
    spending anything;
  * a kill at ANY point loses nothing and puts no item into a keyed sink twice;
  * the quiet-machine predicate is #2869's, number for number.

Synthetic data only: items are integers with timestamps, nothing else.
"""
from __future__ import annotations

import importlib.util
import json
import os
import random
import re
import signal
import subprocess
import sys
import textwrap
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib" / "ostler_catchup.py"
ICAL = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"

N_ITEMS = 12_000          # spread over 20 years
YEARS = 20
NOW = datetime(2026, 10, 15, tzinfo=timezone.utc)


def _load():
    if not LIB.is_file():
        pytest.fail(f"no catch-up core at {LIB.relative_to(REPO)}: nothing walks history backwards")
    spec = importlib.util.spec_from_file_location("ostler_catchup", LIB)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ostler_catchup"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def oc(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    monkeypatch.delenv("OSTLER_DIR", raising=False)
    monkeypatch.delenv("OSTLER_CATCHUP_STATE_DIR", raising=False)
    return _load()


def _stamp(i: int) -> datetime:
    """Item 0 is the newest; item N-1 is YEARS back."""
    return NOW - timedelta(seconds=int(i * (YEARS * 365 * 86400) / N_ITEMS))


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def _make_adapter(oc, sink, *, clock=None, cost=0.0, fail_once_at=None, source="fx",
                  batch_size=25, n=N_ITEMS, install_edge=0):
    """Newest-to-oldest over n integer items; the cursor is the next index.

    install_edge: items [0, install_edge) belong to the install window and the
    walk starts below them, as every real adapter does."""

    class Fx(oc.Adapter):
        pass

    a = Fx()
    a.source = source
    a.doctor_row = "fixture_row"
    a.batch_size = batch_size
    state = {"failed": False, "process_calls": 0}

    def start_cursor():
        return install_edge

    def next_batch(cursor, limit):
        lo = int(cursor)
        hi = min(n, lo + limit)
        items = list(range(lo, hi))
        oldest = oc.to_iso(_stamp(hi - 1)) if items else None
        return oc.Batch(items=items, next_cursor=hi, oldest_at=oldest, exhausted=hi >= n)

    def key(item):
        return f"fx:{item}"

    def process(item):
        state["process_calls"] += 1
        if fail_once_at is not None and item == fail_once_at and not state["failed"]:
            state["failed"] = True
            return False
        sink[key(item)] = sink.get(key(item), 0) + 1
        if clock is not None:
            clock.t += cost
        return True

    a.start_cursor = start_cursor
    a.next_batch = next_batch
    a.key = key
    a.process = process
    a.state = state
    return a


def test_walk_reaches_the_oldest_item_across_bounded_ticks(oc):
    sink = {}
    clock = FakeClock()
    adapter = _make_adapter(oc, sink, clock=clock, cost=1.0, install_edge=2000)
    per_tick = []
    for _ in range(1000):
        before = len(sink)
        s = oc.run([adapter], budget_seconds=300, clock=clock, busy=lambda: None)
        per_tick.append(len(sink) - before)
        clock.t += 10_000  # the next tick, four hours later
        if s["sources"]["fx"]["complete"]:
            break
    expected = N_ITEMS - 2000
    assert len(sink) == expected, f"{len(sink)} of {expected} pre-install items reached the sink"
    assert all(v == 1 for v in sink.values()), "an item reached the sink twice"
    # Bounded: never more than budget / cost items in one tick.
    assert max(per_tick) <= 300, f"a tick processed {max(per_tick)} items on a 300-item budget"
    wm = json.loads((oc.state_dir() / "fx.json").read_text())
    assert wm["complete"] is True
    assert wm["oldest_at"] == oc.to_iso(_stamp(N_ITEMS - 1)), "watermark did not reach the oldest item"
    assert wm["doctor_row"] == "fixture_row"
    print(f"\n[bounded cost] {len(per_tick)} ticks, items per tick max={max(per_tick)} "
          f"on budget=300s at 1s/item, total={len(sink)}")


def test_install_window_items_are_never_reprocessed(oc):
    sink = {}
    adapter = _make_adapter(oc, sink, install_edge=5000)
    oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    assert not any(int(k.split(":")[1]) < 5000 for k in sink), "catch-up re-read the install window"
    assert len(sink) == N_ITEMS - 5000


def test_a_busy_machine_spends_nothing_and_moves_nothing(oc):
    sink = {}
    adapter = _make_adapter(oc, sink)
    s = oc.run([adapter], budget_seconds=1e9, busy=lambda: "load")
    assert sink == {}
    assert s["reason"] == "busy:load"
    wm = json.loads((oc.state_dir() / "fx.json").read_text())
    assert "cursor" not in wm, "a busy tick moved the cursor"
    assert wm["last_tick"]["reason"] == "busy:load"


def test_busy_mid_batch_leaves_the_cursor_and_resumes_without_duplicates(oc):
    sink = {}
    calls = {"n": 0}

    def busy_after_ten():
        calls["n"] += 1
        return "interactive" if calls["n"] == 12 else None

    adapter = _make_adapter(oc, sink)
    oc.run([adapter], budget_seconds=1e9, busy=busy_after_ten)
    wm = json.loads((oc.state_dir() / "fx.json").read_text())
    assert wm.get("cursor") in (None, 0) or "cursor" not in wm
    assert 0 < len(sink) < 25
    oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    assert len(sink) == N_ITEMS
    assert all(v == 1 for v in sink.values())


def test_a_failed_item_holds_the_cursor_then_retries(oc):
    sink = {}
    adapter = _make_adapter(oc, sink, fail_once_at=1013)
    s1 = oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    assert s1["sources"]["fx"]["reason"] == "item_failed"
    assert "fx:1013" not in sink
    wm = json.loads((oc.state_dir() / "fx.json").read_text())
    assert wm["cursor"] == 1000, f"cursor moved past a failed item: {wm['cursor']}"
    s2 = oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    assert s2["sources"]["fx"]["complete"]
    assert len(sink) == N_ITEMS and all(v == 1 for v in sink.values())
    assert s2["sources"]["fx"]["skipped"] == 13, "the ledger did not skip the items already done"


def test_a_corrupt_watermark_restarts_the_walk_but_the_ledger_prevents_duplicates(oc):
    sink = {}
    adapter = _make_adapter(oc, sink)
    clock = FakeClock()
    adapter2 = _make_adapter(oc, sink, clock=clock, cost=1.0)
    oc.run([adapter2], budget_seconds=500, clock=clock, busy=lambda: None)
    done = len(sink)
    (oc.state_dir() / "fx.json").write_text("{not json")
    oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    assert len(sink) == N_ITEMS and all(v == 1 for v in sink.values())
    assert done > 0


def test_a_batch_that_reads_nothing_and_does_not_move_cannot_spin(oc):
    class Stuck(oc.Adapter):
        source = "stuck"

        def start_cursor(self):
            return "x"

        def next_batch(self, cursor, limit):
            return oc.Batch(items=[], next_cursor="x", oldest_at=None, exhausted=False)

        def key(self, item):
            return str(item)

        def process(self, item):
            return True

    t0 = time.monotonic()
    oc.run([Stuck()], budget_seconds=5, busy=lambda: None)   # first batch sets the cursor
    s = oc.run([Stuck()], budget_seconds=5, busy=lambda: None)
    assert time.monotonic() - t0 < 4, "an empty, unmoving batch spun until the budget ran out"
    assert s["sources"]["stuck"]["complete"]


def test_round_robin_does_not_let_one_source_starve_another(oc):
    sink = {}
    clock = FakeClock()
    a = _make_adapter(oc, sink, clock=clock, cost=1.0, source="first")
    b = _make_adapter(oc, sink, clock=clock, cost=1.0, source="second")
    oc.run([a, b], budget_seconds=200, clock=clock, busy=lambda: None)
    firsts = sum(1 for k in sink if k.startswith("fx:"))
    assert a.state["process_calls"] > 0 and b.state["process_calls"] > 0, (
        f"first={a.state['process_calls']} second={b.state['process_calls']}")
    assert firsts > 0


# ── the kill tests: a real process, SIGKILLed ─────────────────────────────────

_FIXTURE_MODULE = textwrap.dedent('''
    """Synthetic catch-up source for the kill test. Sink: one file per key
    (a keyed upsert, like a CM048 state dir) plus an append-only write log."""
    import os, signal
    from pathlib import Path
    import ostler_catchup as oc

    N = int(os.environ["FX_N"])
    SINK = Path(os.environ["FX_SINK"])
    KILL_AT = int(os.environ.get("FX_KILL_AT_WRITE", "-1"))

    class Fx(oc.Adapter):
        source = "killfx"
        doctor_row = "fixture_row"
        batch_size = 40

        def start_cursor(self):
            return 0

        def next_batch(self, cursor, limit):
            lo = int(cursor); hi = min(N, lo + limit)
            return oc.Batch(items=list(range(lo, hi)), next_cursor=hi,
                            oldest_at="2006-01-01T00:00:00Z" if hi >= N else None,
                            exhausted=hi >= N)

        def key(self, item):
            return "k%06d" % item

        def process(self, item):
            SINK.mkdir(parents=True, exist_ok=True)
            (SINK / self.key(item)).write_text("x")
            with open(SINK.parent / "writes.log", "a") as fh:
                fh.write(self.key(item) + "\\n")
            n = sum(1 for _ in open(SINK.parent / "writes.log"))
            if n == KILL_AT:
                # The worst moment: the sink has it, the ledger does not.
                os.kill(os.getpid(), signal.SIGKILL)
            return True

    def adapters():
        return [Fx()]
''')


def _cli_env(tmp_path, n, kill_at=-1):
    fx_dir = tmp_path / "fxmod"
    fx_dir.mkdir(exist_ok=True)
    (fx_dir / "killfx_adapter.py").write_text(_FIXTURE_MODULE)
    env = dict(os.environ)
    env.update({
        "PYTHONPATH": f"{LIB.parent}{os.pathsep}{fx_dir}",
        "OSTLER_HOME": str(tmp_path / "home"),
        "FX_N": str(n), "FX_SINK": str(tmp_path / "out" / "sink"),
        "FX_KILL_AT_WRITE": str(kill_at),
        "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000",
        "OSTLER_INTERACTIVE_TTL_SECS": "0",
    })
    env.pop("OSTLER_DIR", None)
    return env


def _cli(env, budget=600):
    return subprocess.run(
        [sys.executable, "-m", "ostler_catchup", "run", "--family", "killfx",
         "--adapters", "killfx_adapter:adapters", "--budget-seconds", str(budget)],
        env=env, capture_output=True, text=True, timeout=300)


def _writes(tmp_path):
    log = tmp_path / "out" / "writes.log"
    lines = log.read_text().split() if log.exists() else []
    from collections import Counter
    return Counter(lines)


def test_kill_between_sink_and_ledger_repeats_one_keyed_write_and_loses_nothing(tmp_path):
    _load()
    n = 2_000
    r1 = _cli(_cli_env(tmp_path, n, kill_at=517))
    assert r1.returncode == -signal.SIGKILL, f"the kill did not happen: rc={r1.returncode} {r1.stderr[-400:]}"
    r2 = _cli(_cli_env(tmp_path, n))
    assert r2.returncode == 0, r2.stderr[-800:]
    writes = _writes(tmp_path)
    sink = sorted(p.name for p in (tmp_path / "out" / "sink").iterdir())
    assert len(sink) == n, f"{len(sink)} of {n} keys reached the sink after a kill"
    assert len(set(sink)) == n, "the keyed sink holds a duplicate"
    repeated = {k: c for k, c in writes.items() if c > 1}
    assert list(repeated.values()) == [2], f"expected exactly one repeated write, got {repeated}"
    assert list(repeated) == ["k000516"], repeated   # the in-flight item, nothing else
    print(f"\n[kill] sink={len(sink)} distinct of {n}; repeated writes={repeated}")


def test_random_external_kills_never_lose_or_duplicate(tmp_path):
    _load()
    n = 3_000
    env = _cli_env(tmp_path, n)
    rng = random.Random(20261015)
    kills = 0
    for attempt in range(60):
        p = subprocess.Popen(
            [sys.executable, "-m", "ostler_catchup", "run", "--family", "killfx",
             "--adapters", "killfx_adapter:adapters", "--budget-seconds", "600"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p.wait(timeout=rng.uniform(0.05, 0.6))
        except subprocess.TimeoutExpired:
            p.send_signal(signal.SIGKILL)
            p.wait()
            kills += 1
            continue
        if p.returncode == 0:
            st = json.loads((tmp_path / "home" / "state" / "catchup" / "killfx.json").read_text())
            if st.get("complete"):
                break
    sink = {p.name for p in (tmp_path / "out" / "sink").iterdir()}
    writes = _writes(tmp_path)
    extra = sum(c - 1 for c in writes.values())
    assert len(sink) == n, f"{len(sink)} of {n} after {kills} kills"
    assert extra <= kills, f"{extra} repeated writes from {kills} kills: more than one per kill"
    assert kills >= 3, f"only {kills} kills landed; the test did not exercise the restart path"
    print(f"\n[random kills] kills={kills} repeated keyed writes={extra} distinct={len(sink)}/{n}")


# ── the quiet-machine predicate ──────────────────────────────────────────────

def test_the_load_ceiling_is_2869s_number(oc):
    src = ICAL.read_text(encoding="utf-8")
    m = re.search(r"^CONVERSATION_RETRY_MAX_LOAD_PER_CORE\s*=\s*([0-9.]+)", src, re.M)
    assert m, "ical-server.py no longer declares CONVERSATION_RETRY_MAX_LOAD_PER_CORE"
    assert float(m.group(1)) == oc.MAX_LOAD_PER_CORE, (
        f"#2869 says {m.group(1)}, catch-up says {oc.MAX_LOAD_PER_CORE}: the two quiet checks drifted")
    # Same predicate shape: load1 / cpu_count compared with the ceiling.
    assert "load1 / max(os.cpu_count() or 1, 1) >" in src


def test_busy_reason_sees_load_install_and_live_chat(oc, monkeypatch, tmp_path):
    home = Path(os.environ["OSTLER_HOME"])
    cores = os.cpu_count() or 1
    monkeypatch.setattr(os, "getloadavg", lambda: (0.1 * cores, 0, 0))
    assert oc.busy_reason() is None
    monkeypatch.setattr(os, "getloadavg", lambda: (0.9 * cores, 0, 0))
    assert oc.busy_reason() == "load"
    monkeypatch.setattr(os, "getloadavg", lambda: (0.1 * cores, 0, 0))

    marker = home / "state" / "install-in-progress"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("")
    assert oc.busy_reason() == "installing"
    old = time.time() - 7 * 3600
    os.utime(marker, (old, old))
    assert oc.busy_reason() is None, "an aborted install's 7-hour-old marker blocked catch-up"

    ws = tmp_path / "ws"
    ws.mkdir()
    monkeypatch.setenv("OSTLER_STATE_DIR", str(ws))
    (ws / "interactive-chat.active").write_text("")
    assert oc.busy_reason() == "interactive"


def test_status_command_prints_counts_only(tmp_path):
    _load()
    env = _cli_env(tmp_path, 100)
    assert _cli(env).returncode == 0
    r = subprocess.run([sys.executable, "-m", "ostler_catchup", "status", "--json"],
                       env=env, capture_output=True, text=True, timeout=60)
    rows = json.loads(r.stdout)
    assert rows and rows[0]["source"] == "killfx" and rows[0]["complete"] is True
    assert rows[0]["items_done"] == 100


def test_measured_overhead_per_item(oc):
    """Bounded cost of the machinery itself, measured: a no-op sink."""
    sink = {}
    adapter = _make_adapter(oc, sink, batch_size=200)
    t0 = time.perf_counter()
    oc.run([adapter], budget_seconds=1e9, busy=lambda: None)
    dt = time.perf_counter() - t0
    per_item_ms = dt * 1000 / N_ITEMS
    print(f"\n[overhead] {N_ITEMS} items in {dt:.2f}s = {per_item_ms:.3f} ms/item (ledger commit + bookkeeping)")
    assert len(sink) == N_ITEMS
    assert per_item_ms < 50, f"{per_item_ms:.1f} ms of bookkeeping per item"
