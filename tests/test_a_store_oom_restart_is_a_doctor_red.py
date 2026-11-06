#!/usr/bin/env python3
"""A data store killed for memory and restarted must be a Doctor RED. It was silent.

THE DEFECT, MEASURED ON THE v1.0.125 BOX (ORM, 2026-11-06)
----------------------------------------------------------
In the shipped 4 GiB VM the kernel made 9 OOM kills from 03:16Z: 7 wiki
compiler pythons (838-960 MB RSS), 1 mkdocs (wiki-site) and, at about 10:24Z,
the OXIGRAPH store. `restart: unless-stopped` brought the container back, so
every probe answered and nothing a customer could see said the knowledge graph
had just gone down. A store kill is a data-path outage.

WHAT THIS RUNS
--------------
The REAL Doctor collector and rule against a stub `docker` on PATH: the stub
answers `docker inspect` (RestartCount, OOMKilled, StartedAt) and
`docker events --filter event=oom` the way the engine does. Docker clears
State.OOMKilled when it restarts the container, so the oom EVENT is the
evidence that survives the restart; both are exercised.

RED needs evidence of a NEW restart: an oom event for that store, or its
RestartCount rising past the count the Doctor last recorded
(state/doctor/store-restarts.json). A bare "RestartCount > 0 and StartedAt
recent" is what every reboot looks like, so it must stay silent (Archie, #3364).
Controls: the reboot case, the first-ever look (baseline only), a store never
restarted, an old restart; docker absent or a store missing from the inspect
is "could not check", never silence and never "all is well".

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
AGENT = REPO / "vendor" / "doctor" / "agent"
if not AGENT.is_dir():
    print(f"CANNOT-RUN: {AGENT} missing. Nothing was checked.", file=sys.stderr)
    raise SystemExit(2)
sys.path.insert(0, str(AGENT))
try:
    import diagnostic_rules as dr  # noqa: E402
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: could not import the Doctor rules: {exc}", file=sys.stderr)
    raise SystemExit(2)

PASS = 0
FAIL = 0


def ok(m: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok   {m}")


def bad(m: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL {m}")


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000000Z")


def run_rule(inspect_rows: list[str] | None, oom_events: list[str],
             state: dict | None = None, state_dir: str | None = None) -> list[dict]:
    """inspect_rows None = no docker at all. state seeds the Doctor's recorded
    restart counts; state_dir lets two runs share one state."""
    rule = getattr(dr, "check_store_restarts", None)
    if rule is None:
        return []
    with tempfile.TemporaryDirectory() as t:
        sd = state_dir or str(Path(t) / "state")
        if state is not None:
            (Path(sd) / "doctor").mkdir(parents=True, exist_ok=True)
            (Path(sd) / "doctor" / "store-restarts.json").write_text(json.dumps(state))
        stub = Path(t) / "bin"
        stub.mkdir()
        if inspect_rows is not None:
            (Path(t) / "inspect.txt").write_text("".join(r + "\n" for r in inspect_rows))
            (Path(t) / "events.txt").write_text("".join(e + "\n" for e in oom_events))
            d = stub / "docker"
            d.write_text(f"""#!/bin/bash
case "$1" in
  inspect) cat "{t}/inspect.txt"; exit 0 ;;
  events)  cat "{t}/events.txt"; exit 0 ;;
esac
exit 0
""")
            d.chmod(0o755)
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{stub}:/usr/bin:/bin"
        os.environ["OSTLER_STATE_DIR"] = sd
        try:
            os.environ["OSTLER_DOCTOR_DOCKER_BIN"] = str(stub / "docker")
            return list(rule(None))
        finally:
            os.environ["PATH"] = old_path
            os.environ.pop("OSTLER_DOCTOR_DOCKER_BIN", None)
            os.environ.pop("OSTLER_STATE_DIR", None)


def all_three(**rows: str) -> list[str]:
    """inspect rows for all three stores; unspecified ones never restarted."""
    base = {n: f"/{n}\t0\tfalse\t{iso(NOW - timedelta(days=2))}"
            for n in ("ostler-qdrant", "ostler-oxigraph", "ostler-redis")}
    base.update({k.replace("_", "-"): v for k, v in rows.items()})
    return list(base.values())


def reds(found: list[dict]) -> list[str]:
    return [f["title"] for f in found if f.get("severity") == "critical"]


NOW = datetime.now(tz=timezone.utc)


def test_rule_exists_and_is_registered():
    rule = getattr(dr, "check_store_restarts", None)
    if rule is None:
        bad("diagnostic_rules has no check_store_restarts: a store restarted by the OOM killer is invisible (the 125 defect)")
        return
    if rule in getattr(dr, "ALL_RULES", []):
        ok("check_store_restarts exists and is in ALL_RULES, so the Doctor page runs it")
    else:
        bad("check_store_restarts exists but is not in ALL_RULES: unwired")


def test_oxigraph_oom_restart_is_a_red_naming_memory():
    started = NOW - timedelta(minutes=30)
    killed = started - timedelta(seconds=2)
    found = run_rule(
        all_three(ostler_oxigraph=f"/ostler-oxigraph\t1\tfalse\t{iso(started)}"),
        [f"ostler-oxigraph\t{int(killed.timestamp())}"],
        state={"ostler-oxigraph": {"count": 1}, "ostler-qdrant": {"count": 0}, "ostler-redis": {"count": 0}},
    )
    want = f"Your memory store restarted at {started.astimezone().strftime('%H:%M on %-d %b')}: not enough memory"
    if want in reds(found) and len(reds(found)) == 1:
        ok(f"oxigraph oom event (OOMKilled already cleared, count unchanged) -> one RED {want!r}")
    else:
        bad(f"want exactly {want!r}; got {[(f['severity'], f['title']) for f in found]}")


def test_oomkilled_flag_alone_is_enough():
    started = NOW - timedelta(minutes=5)
    found = run_rule(all_three(ostler_qdrant=f"/ostler-qdrant\t2\ttrue\t{iso(started)}"), [],
                     state={"ostler-qdrant": {"count": 2}})
    if any(t.endswith(": not enough memory") for t in reds(found)):
        ok("State.OOMKilled=true with no event still names memory")
    else:
        bad(f"OOMKilled=true not reported as memory: {reds(found)}")


def test_count_delta_without_oom_is_red_with_no_cause():
    started = NOW - timedelta(hours=1)
    found = run_rule(all_three(ostler_redis=f"/ostler-redis\t2\tfalse\t{iso(started)}"),
                     [f"ostler-wiki-compiler\t{int(started.timestamp())}"],
                     state={"ostler-redis": {"count": 1}, "ostler-qdrant": {"count": 0}, "ostler-oxigraph": {"count": 0}})
    r = reds(found)
    if len(r) == 1 and r[0].startswith("Your memory store restarted at ") and not r[0].endswith("not enough memory"):
        ok("RestartCount rose 1 -> 2 with no oom evidence for THAT store: RED, no invented cause")
    else:
        bad(f"count delta: {r}")


def test_reboot_is_silent():
    # After a Mac or VM reboot every store has a fresh StartedAt and its old
    # RestartCount; nothing was killed. Recorded count == current count.
    started = NOW - timedelta(minutes=3)
    found = run_rule(
        [f"/ostler-qdrant\t1\tfalse\t{iso(started)}",
         f"/ostler-oxigraph\t1\tfalse\t{iso(started)}",
         f"/ostler-redis\t0\tfalse\t{iso(started)}"],
        [], state={"ostler-qdrant": {"count": 1}, "ostler-oxigraph": {"count": 1}, "ostler-redis": {"count": 0}})
    if not reds(found):
        ok("control: a reboot (fresh StartedAt, unchanged RestartCount, no oom) raises no RED")
    else:
        bad(f"false RED after a reboot: {reds(found)}")


def test_first_look_records_a_baseline_and_is_silent():
    with tempfile.TemporaryDirectory() as t:
        started = NOW - timedelta(minutes=3)
        rows = all_three(ostler_oxigraph=f"/ostler-oxigraph\t3\tfalse\t{iso(started)}")
        found = run_rule(rows, [], state=None, state_dir=t)
        f = Path(t) / "doctor" / "store-restarts.json"
        rec = json.loads(f.read_text()) if f.exists() else {}
        if not reds(found) and rec.get("ostler-oxigraph", {}).get("count") == 3:
            ok("first look: no RED, baseline count 3 recorded")
        else:
            bad(f"first look: reds={reds(found)} state={rec}")
        rows2 = all_three(ostler_oxigraph=f"/ostler-oxigraph\t4\tfalse\t{iso(NOW)}")
        found2 = run_rule(rows2, [], state=None, state_dir=t)
        found3 = run_rule(rows2, [], state=None, state_dir=t)
        if len(reds(found2)) == 1 and len(reds(found3)) == 1:
            ok("the next restart (3 -> 4) is RED and STAYS RED on the following look")
        else:
            bad(f"delta after baseline: {reds(found2)} then {reds(found3)}")


def test_old_restart_is_silent():
    found = run_rule(all_three(ostler_oxigraph=f"/ostler-oxigraph\t3\tfalse\t{iso(NOW - timedelta(days=3))}"), [],
                     state={"ostler-oxigraph": {"count": 3}, "ostler-qdrant": {"count": 0}, "ostler-redis": {"count": 0}})
    if not reds(found):
        ok("control: a restart three days ago, already recorded, raises no RED")
    else:
        bad(f"an old restart still RED: {reds(found)}")


def test_a_store_missing_from_inspect_is_could_not_check():
    found = run_rule([f"/ostler-oxigraph\t0\tfalse\t{iso(NOW - timedelta(days=1))}"], [],
                     state={"ostler-oxigraph": {"count": 0}})
    warn = [f for f in found if f.get("severity") == "warning" and "could not check" in f["title"].lower()]
    names = " ".join(f["detail"] for f in warn)
    if len(warn) == 2 and "search index" in names and "short-term cache" in names and not reds(found):
        ok("partial inspect: qdrant and redis each get a 'could not check' row, oxigraph none")
    else:
        bad(f"partial inspect produced {[(f['severity'], f['title'], f['detail'][:60]) for f in found]}")


def test_docker_absent_is_could_not_check():
    found = run_rule(None, [])
    if any(f.get("severity") == "warning" and "could not check" in f["title"].lower() for f in found) and not reds(found):
        ok("no docker: a 'could not check' warning, not silence and not a RED")
    else:
        bad(f"docker absent produced {[(f['severity'], f['title']) for f in found]}")


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            print(name)
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                bad(f"{name} raised {type(exc).__name__}: {exc}")
    print(f"\n=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
