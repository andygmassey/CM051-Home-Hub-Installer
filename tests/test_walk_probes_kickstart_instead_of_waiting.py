"""Two walk probes kickstart their job instead of waiting on an hourly / 15-minute tick.

people_count_agreement waited up to 4200 s for com.ostler.fda-rerun (StartInterval 3600)
to run people_index. settling_json_refreshes waited 1000 s for a second tick of
com.creativemachines.ostler.settling-refresh (StartInterval 900). With the walk allowing
writes (OSTLER_WALK_READ_ONLY=0) each now issues ONE `launchctl kickstart` and waits on the
job's own completion marker with a short bound.

launchctl is a STUB on PATH-independent absolute path (OSTLER_PROBE_LAUNCHCTL): it records its
argv and, for the positive controls only, makes the marker advance. The real launchctl is
never called. Synthetic data only.

Per probe: (a) the kickstart is issued exactly once, with the right label;
(b) POSITIVE: the marker advances and the probe passes in seconds (the default bounds are
thousands of seconds, so a pass in seconds is proof it did not wait for the tick);
(c) NEGATIVE: a kick the job accepts but never acts on (dead indexer / dead refresher) still
FAILs, never PASSes; (d) read-only and unset modes issue NO kickstart; a refused kick falls
back to the old wait and is never a pass.

PROBE_SUBJECT_PEOPLE / PROBE_SUBJECT_SETTLING=<path> run another copy of the probe (the RED:
origin/main's, placed beside the probe so ../lib/probe.sh resolves).
"""
from __future__ import annotations

import http.server
import json
import os
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parent
PROBES = ROOT / "scripts" / "box_walk_probes" / "probes"
SETTLING = Path(os.environ.get("PROBE_SUBJECT_SETTLING") or PROBES / "settling_json_refreshes.sh")


def verdict(text):
    return next((ln.split("VERDICT:")[1].strip() for ln in text.splitlines() if "VERDICT:" in ln), "NONE")


def make_stub(tmp_path, kick_rc=0, on_kick=":"):
    """A launchctl that answers `print` as an idle, loaded job and records `kickstart`."""
    log = tmp_path / "launchctl.log"
    stub = tmp_path / "launchctl-stub"
    stub.write_text(
        "#!/bin/bash\n"
        'printf "%s\\n" "$*" >> "' + str(log) + '"\n'
        'case "$1" in\n'
        '  print) echo "state = not running"; echo "runs = 1"; exit 0 ;;\n'
        "  kickstart) " + on_kick + "; exit " + str(kick_rc) + " ;;\n"
        "esac\nexit 0\n")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    return stub, log


def kicks(log):
    if not log.exists():
        return []
    return [ln for ln in log.read_text().splitlines() if ln.startswith("kickstart")]


# ---------------------------------------------------------------- settling_json_refreshes

def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def settling_doc(ts):
    return json.dumps({
        "schema": 2, "percent": 40, "displayed_percent": 40, "population_key": "synthetic",
        "fresh_for_seconds": 1800, "summary": {"percent": 40, "text": "40% done."},
        "channels": [], "history_filling": False, "eta_seconds": None,
        "eta_display": "About 2 days", "computed_at": iso(ts), "basis": "synthetic"}) + "\n"


class Served:
    def __init__(self, root):
        h = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=str(root), **k)  # noqa: E731
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/settling.json" % self.srv.server_address[1]

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def run_settling(tmp_path, advance, read_only="0", kick_rc=0, wait_s=1000, kick_wait=6, timeout=60):
    web = tmp_path / "web"
    web.mkdir()
    now = time.time()
    (web / "settling.json").write_text(settling_doc(now - 600))
    (tmp_path / "advanced.json").write_text(settling_doc(now - 5))
    on_kick = 'cp "%s" "%s"' % (tmp_path / "advanced.json", web / "settling.json") if advance else ":"
    stub, log = make_stub(tmp_path, kick_rc, on_kick)
    tok = tmp_path / "tok"
    tok.write_text("synthetic-token\n")
    home = tmp_path / "home"
    home.mkdir()
    srv = Served(web)
    env = dict(os.environ, HOME=str(home), OSTLER_BOX_HOST="", OSTLER_SETTLING_URL=srv.url,
               OSTLER_PROBE_TOKEN_PATH=str(tok), OSTLER_PROBE_LAUNCHCTL=str(stub),
               OSTLER_SETTLING_REFRESH_WAIT_S=str(wait_s), OSTLER_SETTLING_KICK_WAIT_S=str(kick_wait),
               OSTLER_SETTLING_KICK_STEP_S="1", NO_PROXY="127.0.0.1",
               # no scope file: the probe grades as BLOCKING, so a stall is FAIL not ADVISORY
               OSTLER_PROMOTE_SCOPE_FILE=str(tmp_path / "no-scope-file.tsv"))
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        env.pop(k, None)
    if read_only is None:
        env.pop("OSTLER_WALK_READ_ONLY", None)
    else:
        env["OSTLER_WALK_READ_ONLY"] = read_only
    t0 = time.time()
    try:
        r = subprocess.run(["bash", str(SETTLING)], env=env, capture_output=True, text=True, timeout=timeout)
    finally:
        srv.close()
    text = r.stdout + r.stderr
    return verdict(text), text, time.time() - t0, kicks(log)


def test_settling_kicks_the_refresh_job_once_and_passes_in_seconds(tmp_path):
    v, text, took, k = run_settling(tmp_path, advance=True)
    assert v.startswith("PASS"), text
    assert len(k) == 1 and "com.creativemachines.ostler.settling-refresh" in k[0], k
    assert took < 40, "did not use the kick; took %.1fs against a 1000 s default wait" % took


def test_settling_dead_refresher_kick_accepted_but_no_advance_is_a_fail(tmp_path):
    v, text, took, k = run_settling(tmp_path, advance=False)
    assert v.startswith("FAIL"), text
    assert "did not advance" in text, text
    assert len(k) == 1, k
    assert took < 40, took


def test_settling_read_only_and_unset_modes_issue_no_kickstart(tmp_path):
    for i, mode in enumerate(("1", None)):
        sub = tmp_path / ("m%d" % i)
        sub.mkdir()
        v, text, took, k = run_settling(sub, advance=True, read_only=mode, wait_s=2)
        assert k == [], (mode, k)
        assert took >= 2, "read-only must still wait the old interval (%.1fs)" % took
        assert v.startswith("FAIL"), text    # nothing refreshed it: the old behaviour, unchanged


def test_settling_refused_kick_falls_back_to_the_old_wait_and_never_passes(tmp_path):
    v, text, took, k = run_settling(tmp_path, advance=False, kick_rc=1, wait_s=2)
    assert len(k) == 1, k
    assert took >= 2, took
    assert v.startswith("FAIL"), text


# ---------------------------------------------------------------- people_count_agreement
# The people half needs pyoxigraph (the shipped stand-in graph). Guarded per test, not at
# module level, so the settling tests above can never be skipped with it; the workflow
# refuses any SKIPPED line and counts the passes.

def _people():
    pytest.importorskip("pyoxigraph")
    import test_people_count_waits_for_the_embed_drain as m
    return m


@pytest.fixture()
def world():
    m = _people()
    w = m.World()
    m.base.server.QDRANT_URL = w.qdrant
    yield w
    w.close()


def run_people(world, tmp_path, mode="0", kick_rc=0, on_kick=None, **kw):
    m = _people()
    stub, log = make_stub(tmp_path, kick_rc)
    extra = {"OSTLER_PROBE_LAUNCHCTL": str(stub), "OSTLER_PEOPLE_KICK_WAIT_S": "6"}
    if mode is None:
        extra["OSTLER_WALK_READ_ONLY"] = ""
    else:
        extra["OSTLER_WALK_READ_ONLY"] = mode
    watcher = None
    if on_kick:
        def watch():
            end = time.time() + 120
            while time.time() < end:
                if kicks(log):
                    on_kick()
                    return
                time.sleep(0.2)
        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
    subject = os.environ.get("PROBE_SUBJECT_PEOPLE")
    v, text, took = m.run_probe(world, tmp_path, probe=Path(subject) if subject else None,
                                extra=extra, timeout=90, **kw)
    return v, text, took, kicks(log)


def test_people_kicks_fda_rerun_once_and_passes_when_the_marker_advances(world, tmp_path):
    m = _people()
    home = m.lagging_world(world, tmp_path)

    def indexer_runs():           # what the real people_index run does: the vector lands, the marker stamps
        world.point("c", "Mary Jones")
        m.write_marker(home, "ok")
    v, text, took, k = run_people(world, tmp_path, on_kick=indexer_runs, drain_wait=3000)
    assert v.startswith("PASS"), text
    assert len(k) == 1 and "com.ostler.fda-rerun" in k[0], k
    assert "kickstarted com.ostler.fda-rerun once" in text, text
    assert took < 60, "did not use the kick; took %.1fs against a 3000 s bound" % took


def test_people_dead_indexer_kick_accepted_but_marker_never_advances_is_a_fail(world, tmp_path):
    m = _people()
    home = m.lagging_world(world, tmp_path)
    m.write_marker(home, "ok", ts=time.time() - 3 * 3600)        # last success 3 intervals ago
    v, text, took, k = run_people(world, tmp_path, drain_wait=3000)
    assert v.startswith("FAIL"), text
    assert "vector indexer is not running" in text, text
    assert len(k) == 1, k
    assert took < 60, took


def test_people_live_indexer_that_does_not_advance_in_the_short_bound_is_cannot_run(world, tmp_path):
    m = _people()
    home = m.lagging_world(world, tmp_path)
    m.write_marker(home, "ok", ts=time.time() - 600)             # alive, within cadence
    v, text, took, k = run_people(world, tmp_path, drain_wait=3000)
    assert v.startswith("CANNOT-RUN"), text
    assert "NO DRAIN SIGNAL ARRIVED" in text, text
    assert len(k) == 1, k


def test_people_read_only_and_unset_modes_issue_no_kickstart(world, tmp_path):
    m = _people()
    m.lagging_world(world, tmp_path)
    for i, mode in enumerate(("1", None)):
        sub = tmp_path / ("m%d" % i)
        sub.mkdir()
        v, text, took, k = run_people(world, sub, mode=mode, drain_wait=4)
        assert k == [], (mode, k)
        assert v.startswith("CANNOT-RUN"), text
        assert "kickstarted" not in text, text


def test_people_refused_kick_falls_back_and_is_never_a_pass(world, tmp_path):
    m = _people()
    m.lagging_world(world, tmp_path)
    v, text, took, k = run_people(world, tmp_path, kick_rc=1, drain_wait=5)
    assert len(k) == 1, k
    assert "was refused" in text, text
    assert v.startswith("CANNOT-RUN"), text
