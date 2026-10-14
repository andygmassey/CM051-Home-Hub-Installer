"""Browser history catch-up: Safari and Chrome walk back past the install window.

The install reads five years (install.sh defaults OSTLER_SAFARI_BACKFILL_DAYS
and OSTLER_BROWSER_BACKFILL_DAYS to 1825). Before v1.0.108 nothing ever read
further back, so every visit older than five years never reached the
Browsing collection. This drives the SHIPPED extractors and the SHIPPED sink
(pwg_ingest.ingest_browser_history) over synthetic browser databases holding
ten years and more than 60,000 visits, with only the network edge faked: the
Ollama embedder and the Qdrant upsert, keyed by point id exactly like Qdrant.

Synthetic data only: example.com / example.org / example.net URLs, plus one
sensitive-looking domain under example.com to prove the blocklist still holds.
"""
from __future__ import annotations

import importlib
import json
import os
import signal
import sqlite3
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
VENDOR = REPO / "vendor"
LIB = REPO / "lib"
for p in (str(VENDOR), str(LIB)):
    if p not in sys.path:
        sys.path.insert(0, p)

MAC_EPOCH = 978307200
CHROME_EPOCH = 11644473600
DAY = 86400
NOW = time.time()

SAFARI_VISITS = 36_000     # over 10 years
CHROME_VISITS = 27_000     # over 9 years
SAFARI_YEARS = 10
CHROME_YEARS = 9
SENSITIVE_EVERY = 97       # every 97th visit is on a blocklisted domain
INSTALL_DAYS = 1825


def _url(kind: str, i: int) -> str:
    if i % SENSITIVE_EVERY == 0:
        return f"https://mybank.example.com/{kind}/{i}"
    return f"https://www.example.{('com', 'org', 'net')[i % 3]}/{kind}/page/{i}"


def _ts(i: int, n: int, years: int) -> float:
    """Visit 0 is a minute ago; visit n-1 is `years` back. Whole seconds."""
    return float(int(NOW - 60 - i * (years * 365 * DAY) / n))


def build_safari(path: Path) -> None:
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);"
        "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,"
        " visit_time REAL, title TEXT, redirect_source INTEGER);")
    con.executemany("INSERT INTO history_items VALUES (?,?,1)",
                    ((i, _url("s", i)) for i in range(SAFARI_VISITS)))
    con.executemany("INSERT INTO history_visits VALUES (?,?,?,?,NULL)",
                    ((i, i, _ts(i, SAFARI_VISITS, SAFARI_YEARS) - MAC_EPOCH, f"Page {i}")
                     for i in range(SAFARI_VISITS)))
    con.commit()
    con.close()


def build_chrome(path: Path) -> None:
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER,"
        " last_visit_time INTEGER);"
        "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER,"
        " from_visit INTEGER);")
    con.executemany("INSERT INTO urls VALUES (?,?,?,1,0)",
                    ((i, _url("c", i), f"Tab {i}") for i in range(CHROME_VISITS)))
    con.executemany("INSERT INTO visits VALUES (?,?,?,0)",
                    ((i, i, int((_ts(i, CHROME_VISITS, CHROME_YEARS) + CHROME_EPOCH) * 1_000_000))
                     for i in range(CHROME_VISITS)))
    con.commit()
    con.close()


def expected_ids(pwg, safari_db, chrome_db):
    """Every non-sensitive visit's point id, computed the way the sink does."""
    import uuid
    from datetime import datetime, timezone
    out = set()
    for kind, n, years, src in (("s", SAFARI_VISITS, SAFARI_YEARS, "safari_history"),
                                ("c", CHROME_VISITS, CHROME_YEARS, "chrome_history")):
        for i in range(n):
            url = _url(kind, i)
            if "bank" in url:
                continue
            ts = datetime.fromtimestamp(_ts(i, n, years), tz=timezone.utc).isoformat()
            out.add(str(uuid.uuid5(uuid.NAMESPACE_URL, f"browsing|{src}|{url}|{ts}")))
    return out


@pytest.fixture(scope="module")
def dbs(tmp_path_factory):
    d = tmp_path_factory.mktemp("browsers")
    s, c = d / "History.db", d / "ChromeHistory"
    build_safari(s)
    build_chrome(c)
    return s, c


class Sink:
    """Keyed like Qdrant: an upsert by id replaces. `writes` counts every
    upsert so a repeat is visible even though the store cannot hold one."""

    def __init__(self):
        self.points = {}
        self.writes = {}

    def upsert(self, collection, points):
        for p in points:
            if not p.get("vector"):
                continue
            self.points[p["id"]] = p["payload"]
            self.writes[p["id"]] = self.writes.get(p["id"], 0) + 1
        return len([p for p in points if p.get("vector")])


@pytest.fixture()
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    monkeypatch.delenv("OSTLER_DIR", raising=False)
    monkeypatch.setenv("OSTLER_SAFARI_BACKFILL_DAYS", str(INSTALL_DAYS))
    monkeypatch.setenv("OSTLER_BROWSER_BACKFILL_DAYS", str(INSTALL_DAYS))
    from ostler_fda import pwg_ingest
    sink = Sink()
    monkeypatch.setattr(pwg_ingest, "_ollama_embed_batch", lambda texts: [[0.1, 0.2, 0.3] for _ in texts])
    monkeypatch.setattr(pwg_ingest, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(pwg_ingest, "_qdrant_upsert_points", sink.upsert)
    try:
        import ostler_catchup
        importlib.reload(ostler_catchup)
    except ImportError:
        pass   # origin/main: no core; the install-only measurement still runs
    return pwg_ingest, sink


def install_path(pwg, safari_db, chrome_db, tmp_path):
    """What the shipped install does: extract_all's two browser arms at
    1825 days, then install.sh's hydrate_browsing ingest of the same dir."""
    from ostler_fda import chrome_history, safari_history
    fda = tmp_path / "fda"
    fda.mkdir(exist_ok=True)
    s = safari_history.extract_history(safari_db, since_days=INSTALL_DAYS)
    c = chrome_history.extract_history(chrome_db, since_days=INSTALL_DAYS)
    (fda / "safari_history.json").write_text(json.dumps(safari_history.to_timeline_entries(s), default=str))
    (fda / "chrome_history.json").write_text(json.dumps(chrome_history.to_timeline_entries(c), default=str))
    return pwg.ingest_browser_history(fda)


def _catchup_adapters(safari_db, chrome_db):
    try:
        from ostler_fda import catchup_browser
    except ImportError as exc:
        pytest.fail(f"no browser catch-up ({exc}): nothing reads history older than "
                    f"{INSTALL_DAYS} days")
    return [catchup_browser.SafariAdapter(db_path=safari_db),
            catchup_browser.ChromeAdapter(db_path=chrome_db)]


def test_install_window_alone_misses_everything_older_than_five_years(env, dbs, tmp_path):
    pwg, sink = env
    safari_db, chrome_db = dbs
    want = expected_ids(pwg, safari_db, chrome_db)
    install_path(pwg, safari_db, chrome_db, tmp_path)
    got = set(sink.points)
    print(f"\n[install only] {len(got & want)} of {len(want)} non-sensitive visits reached "
          f"the Browsing collection ({SAFARI_VISITS + CHROME_VISITS} visits in the fixture)")
    assert got <= want
    assert len(got) < len(want), "fixture does not exceed the install window"


def test_install_plus_catchup_reads_every_visit_once(env, dbs, tmp_path):
    pwg, sink = env
    safari_db, chrome_db = dbs
    want = expected_ids(pwg, safari_db, chrome_db)
    install_path(pwg, safari_db, chrome_db, tmp_path)
    after_install = dict(sink.writes)
    import ostler_catchup as oc
    ticks = 0
    while True:
        ticks += 1
        s = oc.run(_catchup_adapters(safari_db, chrome_db), budget_seconds=1e9, busy=lambda: None)
        if all(v["complete"] for v in s["sources"].values()) or ticks > 5:
            break
    missing = want - set(sink.points)
    print(f"\n[install + catch-up] {len(want) - len(missing)} of {len(want)} non-sensitive visits; "
          f"ticks={ticks}")
    assert not missing, f"{len(missing)} visits never reached the sink"
    assert set(sink.points) <= want, "a sensitive or unknown visit reached the sink"
    assert not any("bank" in p["url"] for p in sink.points.values()), "blocklist bypassed"
    catchup_writes = {k: v - after_install.get(k, 0) for k, v in sink.writes.items()}
    assert max(catchup_writes.values()) <= 1, "catch-up wrote one visit twice"
    for name in ("browsing_safari", "browsing_chrome"):
        wm = json.loads((oc.state_dir() / f"{name}.json").read_text())
        assert wm["complete"] and wm["doctor_row"] == "browsing"
        assert wm["oldest_at"] is not None
    sw = json.loads((oc.state_dir() / "browsing_safari.json").read_text())
    years_back = (NOW - __import__("datetime").datetime.fromisoformat(
        sw["oldest_at"].replace("Z", "+00:00")).timestamp()) / (365 * DAY)
    assert years_back > 9.9, f"Safari watermark only reaches {years_back:.1f} years back"


def test_a_window_that_lands_partly_is_retried_not_marked_done(env, dbs, monkeypatch):
    pwg, sink = env
    safari_db, chrome_db = dbs
    real = sink.upsert
    calls = {"n": 0}

    def flaky(collection, points):
        calls["n"] += 1
        if calls["n"] == 3:
            return real(collection, points[: len(points) // 2])   # half landed
        return real(collection, points)

    monkeypatch.setattr(pwg, "_qdrant_upsert_points", flaky)
    import ostler_catchup as oc
    s = oc.run(_catchup_adapters(safari_db, chrome_db)[:1], budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["browsing_safari"]["reason"] == "item_failed"
    assert not s["sources"]["browsing_safari"]["complete"]
    s2 = oc.run(_catchup_adapters(safari_db, chrome_db)[:1], budget_seconds=1e9, busy=lambda: None)
    assert s2["sources"]["browsing_safari"]["complete"]


def test_unreadable_chrome_is_cannot_run_and_safari_still_completes(env, dbs, monkeypatch):
    pwg, sink = env
    safari_db, chrome_db = dbs
    from ostler_fda import chrome_history

    def denied(*a, **k):
        raise PermissionError("Full Disk Access")

    monkeypatch.setattr(chrome_history, "oldest_visit", denied)
    import ostler_catchup as oc
    s = oc.run(_catchup_adapters(safari_db, chrome_db), budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["browsing_chrome"]["reason"] == "read_failed:PermissionError"
    assert s["sources"]["browsing_chrome"]["complete"] is False
    assert s["sources"]["browsing_safari"]["complete"] is True


def test_factory_honours_consent_and_skips_an_absent_chrome(env, monkeypatch, tmp_path):
    from ostler_fda import catchup_browser, chrome_history
    monkeypatch.setattr(chrome_history, "DEFAULT_HISTORY_PATH", tmp_path / "no-chrome" / "History")
    monkeypatch.setenv("OSTLER_FDA_SOURCES", "safari_history,chrome_history")
    assert [a.source for a in catchup_browser.adapters()] == ["browsing_safari"]
    present = tmp_path / "History"
    present.write_text("")
    monkeypatch.setattr(chrome_history, "DEFAULT_HISTORY_PATH", present)
    assert [a.source for a in catchup_browser.adapters()] == ["browsing_safari", "browsing_chrome"]
    monkeypatch.setenv("OSTLER_FDA_SOURCES", "calendar")
    assert catchup_browser.adapters() == [], "catch-up read a browser the customer did not pick"


def test_a_visit_on_a_window_boundary_lands_in_exactly_one_window(env, tmp_path):
    pwg, sink = env
    from ostler_fda import catchup_browser
    db = tmp_path / "edge.db"
    con = sqlite3.connect(db)
    con.executescript(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);"
        "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,"
        " visit_time REAL, title TEXT, redirect_source INTEGER);")
    a = catchup_browser.SafariAdapter(db_path=db, now=NOW, window_days=30)
    edge = a.start_cursor()["end"]
    times = [edge - 30 * DAY, edge - 60 * DAY, edge - 30 * DAY + 0.5, edge - 1]
    for i, t in enumerate(times):
        con.execute("INSERT INTO history_items VALUES (?,?,1)", (i, f"https://www.example.com/e/{i}"))
        con.execute("INSERT INTO history_visits VALUES (?,?,?,?,NULL)", (i, i, t - MAC_EPOCH, "e"))
    con.commit()
    con.close()
    import ostler_catchup as oc
    oc.run([a], budget_seconds=1e9, busy=lambda: None)
    assert len(sink.points) == 4 and max(sink.writes.values()) == 1, sink.writes


_KILL_FIXTURE = textwrap.dedent('''
    """Runner for the kill test: the shipped adapters, with only the network
    edge replaced by a file-backed keyed sink (sqlite, id PRIMARY KEY)."""
    import os, signal, sqlite3
    from pathlib import Path
    from ostler_fda import catchup_browser, pwg_ingest

    DB = os.environ["FX_SINK"]
    KILL_AT = int(os.environ.get("FX_KILL_AT_UPSERT", "-1"))

    def _upsert(collection, points):
        con = sqlite3.connect(DB)
        con.execute("CREATE TABLE IF NOT EXISTS p (id TEXT PRIMARY KEY)")
        con.execute("CREATE TABLE IF NOT EXISTS w (id TEXT)")
        con.executemany("INSERT OR REPLACE INTO p VALUES (?)", [(x["id"],) for x in points])
        con.executemany("INSERT INTO w VALUES (?)", [(x["id"],) for x in points])
        con.execute("CREATE TABLE IF NOT EXISTS c (n INTEGER)")
        con.execute("INSERT INTO c VALUES (1)")
        con.commit()
        n = con.execute("SELECT COUNT(*) FROM c").fetchone()[0]
        con.close()
        if n == KILL_AT:
            os.kill(os.getpid(), signal.SIGKILL)   # the sink has it, the ledger does not
        return len(points)

    pwg_ingest._ollama_embed_batch = lambda texts: [[0.1, 0.2] for _ in texts]
    pwg_ingest._qdrant_ensure_collection = lambda *a, **k: None
    pwg_ingest._qdrant_upsert_points = _upsert

    def adapters():
        return [catchup_browser.SafariAdapter(db_path=Path(os.environ["FX_SAFARI"])),
                catchup_browser.ChromeAdapter(db_path=Path(os.environ["FX_CHROME"]))]
''')


def test_sigkill_mid_walk_then_restart_loses_nothing_and_duplicates_nothing(env, dbs, tmp_path):
    pwg, _ = env
    safari_db, chrome_db = dbs
    fx = tmp_path / "fx"
    fx.mkdir()
    (fx / "browser_kill_fixture.py").write_text(_KILL_FIXTURE)
    e = dict(os.environ)
    e.update({"PYTHONPATH": os.pathsep.join([str(LIB), str(VENDOR), str(fx)]),
              "OSTLER_HOME": str(tmp_path / "killhome"),
              "FX_SINK": str(tmp_path / "sink.sqlite"),
              "FX_SAFARI": str(safari_db), "FX_CHROME": str(chrome_db),
              "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000", "OSTLER_INTERACTIVE_TTL_SECS": "0"})
    cmd = [sys.executable, "-m", "ostler_catchup", "run", "--family", "browser",
           "--adapters", "browser_kill_fixture:adapters", "--budget-seconds", "600"]
    r1 = subprocess.run(cmd, env=dict(e, FX_KILL_AT_UPSERT="7"), capture_output=True, text=True, timeout=600)
    assert r1.returncode == -signal.SIGKILL, f"no kill: rc={r1.returncode} {r1.stderr[-400:]}"
    r2 = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=600)
    assert r2.returncode == 0, r2.stderr[-800:]
    con = sqlite3.connect(tmp_path / "sink.sqlite")
    distinct = con.execute("SELECT COUNT(*) FROM p").fetchone()[0]
    writes = con.execute("SELECT COUNT(*) FROM w").fetchone()[0]
    repeated = con.execute("SELECT COUNT(*) FROM (SELECT id FROM w GROUP BY id HAVING COUNT(*) > 1)").fetchone()[0]
    ids = {row[0] for row in con.execute("SELECT id FROM p")}
    con.close()
    # The walk covers everything older than the edge (and the 1825-day edge
    # itself), so it must hold every expected id older than five years.
    from datetime import datetime, timezone
    import uuid
    older = set()
    for kind, n, years, src in (("s", SAFARI_VISITS, SAFARI_YEARS, "safari_history"),
                                ("c", CHROME_VISITS, CHROME_YEARS, "chrome_history")):
        for i in range(n):
            t = _ts(i, n, years)
            url = _url(kind, i)
            if "bank" in url or t >= NOW - INSTALL_DAYS * DAY - 3600:
                continue
            ts = datetime.fromtimestamp(t, tz=timezone.utc).isoformat()
            older.add(str(uuid.uuid5(uuid.NAMESPACE_URL, f"browsing|{src}|{url}|{ts}")))
    lost = older - ids
    print(f"\n[kill] distinct={distinct} writes={writes} ids-written-twice={repeated} "
          f"older-than-edge={len(older)} lost={len(lost)}")
    assert not lost, f"{len(lost)} visits lost across the kill"
    # One window was in flight: at most its visits are rewritten (keyed, so
    # the store still holds each once), and nothing else repeats.
    assert repeated <= max(1, writes - distinct)
    assert writes - distinct <= 2_000, f"{writes - distinct} repeated writes: more than the one window in flight"


def test_bounded_cost_measured(env, dbs):
    pwg, sink = env
    safari_db, chrome_db = dbs
    import ostler_catchup as oc
    from ostler_fda import catchup_browser
    a = catchup_browser.SafariAdapter(db_path=safari_db)
    cur = a.start_cursor()
    b = a.next_batch(cur, 6)
    t0 = time.perf_counter()
    visits = 0
    for w in b.items:
        before = len(sink.points)
        assert a.process(w)
        visits += len(sink.points) - before
    dt = time.perf_counter() - t0
    per_window = dt / len(b.items)
    print(f"\n[bounded cost] {len(b.items)} Safari windows of 30 days, {visits} visits, "
          f"{per_window * 1000:.0f} ms per window ({visits / len(b.items):.0f} visits per window) "
          f"with the embedder faked; a 1800 s tick at this rate reads "
          f"~{int(1800 / max(per_window, 1e-6))} windows. Real Ollama embedding cost is NOT INSTRUMENTED here.")
    assert per_window < 5


def test_install_registers_the_browser_runner_in_the_venv_that_has_ostler_fda():
    """The runner is what export-scan drives; without the registration the
    adapters above never run on a customer's Mac."""
    src = (REPO / "install.sh").read_text(encoding="utf-8")
    i = src.find("_ostler_catchup_register 20-browser")
    assert i != -1, "install.sh never registers the browser catch-up runner"
    block = src[i:i + 600]
    assert "services/email-ingest/.venv/bin/python3" in block      # where ostler_fda is pip-installed
    assert '"ostler_fda.catchup_browser:adapters" 1' in block      # slot=1: it embeds via Ollama
    for var in ("OSTLER_SAFARI_BACKFILL_DAYS=", "OSTLER_BROWSER_BACKFILL_DAYS=", "OSTLER_FDA_SOURCES="):
        assert var in block, var
    # Registered only after ostler_fda installed into that venv.
    assert src.rfind('ok "$MSG_OK_OSTLER_FDA_INSTALLED_VENV"', 0, i) > src.rfind("_ostler_pip_install_pkg \"$EMAIL_INGEST_VENV/bin/pip\"", 0, i) > 0
