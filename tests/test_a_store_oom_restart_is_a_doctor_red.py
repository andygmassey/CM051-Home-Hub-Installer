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

Controls: a store never restarted is silent; a restart with no oom evidence
is still RED but names no cause; a restart days ago is silent; docker absent
is "could not check", never silence and never "all is well".

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
from __future__ import annotations

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


def run_rule(inspect_rows: list[str] | None, oom_events: list[str]) -> list[dict]:
    """inspect_rows None = no docker at all."""
    rule = getattr(dr, "check_store_restarts", None)
    if rule is None:
        return []
    with tempfile.TemporaryDirectory() as t:
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
        try:
            # The collector also tries absolute docker paths; force the stub.
            os.environ["OSTLER_DOCTOR_DOCKER_BIN"] = str(stub / "docker")
            return list(rule(None))
        finally:
            os.environ["PATH"] = old_path
            os.environ.pop("OSTLER_DOCTOR_DOCKER_BIN", None)


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
        [f"/ostler-oxigraph\t1\tfalse\t{iso(started)}",
         f"/ostler-qdrant\t0\tfalse\t{iso(NOW - timedelta(days=2))}"],
        [f"ostler-oxigraph\t{int(killed.timestamp())}"],
    )
    want = f"Your memory store restarted at {started.astimezone().strftime('%H:%M on %-d %b')}: not enough memory"
    if want in reds(found):
        ok(f"oxigraph OOM-killed then restarted (OOMKilled already cleared) -> RED {want!r}")
    else:
        bad(f"no RED {want!r}; got {[(f['severity'], f['title']) for f in found]}")
    if len(reds(found)) == 1:
        ok("control: the never-restarted qdrant raises nothing")
    else:
        bad(f"expected exactly one RED, got {reds(found)}")


def test_oomkilled_flag_alone_is_enough():
    started = NOW - timedelta(minutes=5)
    found = run_rule([f"/ostler-qdrant\t2\ttrue\t{iso(started)}"], [])
    if any(t.endswith(": not enough memory") for t in reds(found)):
        ok("State.OOMKilled=true with no event still names memory")
    else:
        bad(f"OOMKilled=true not reported as memory: {reds(found)}")


def test_restart_without_oom_evidence_names_no_cause():
    started = NOW - timedelta(hours=1)
    found = run_rule([f"/ostler-redis\t1\tfalse\t{iso(started)}"],
                     [f"ostler-wiki-compiler\t{int(started.timestamp())}"])
    r = reds(found)
    if r and not r[0].endswith("not enough memory") and r[0].startswith("Your memory store restarted at "):
        ok("a restart with no oom evidence FOR THAT STORE is RED with no invented cause (another container's oom is not blamed)")
    else:
        bad(f"wrong wording or silence: {r}")


def test_old_restart_is_silent():
    found = run_rule([f"/ostler-oxigraph\t3\tfalse\t{iso(NOW - timedelta(days=3))}"], [])
    if not reds(found):
        ok("control: a restart three days ago, store up since, raises no RED")
    else:
        bad(f"an old restart still RED: {reds(found)}")


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
