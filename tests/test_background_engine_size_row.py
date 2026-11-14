#!/usr/bin/env python3
"""The Doctor's background-engine row says whether the running VM is the installed size.

Run as a script (exit 0 all pass, 1 a check failed, 2 cannot run), not under
pytest: pytest collects nothing from a __main__ script, which reads as a pass.

Crosses the bash/python boundary for real: the record is written by the
installer's own lib function (lib/ostler-vm-size.sh), then read by the Doctor.
Every arm has a control that must stay quiet. Throwaway state dir only.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "doctor" / "agent"))
try:
    import diagnostic_rules as rules
    import vm_size_row as row
except Exception as exc:  # cannot run, not a pass
    print(f"CANNOT-RUN: could not import the Doctor modules: {exc}")
    sys.exit(2)

FIXTURE = (ROOT / "tests" / "fixtures" / "vm_size_state_contract.txt").read_text()
GIB = 1024 ** 3
fails = 0
total = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global fails, total
    total += 1
    if cond:
        print(f"PASS: {name}")
    else:
        fails += 1
        print(f"FAIL: {name} {detail}")


def colima_list(cpus: int, mem_gib: int) -> str:
    return json.dumps([{"name": "default", "status": "Running", "cpus": cpus,
                        "memory": mem_gib * GIB}])


def snap(state_row):
    return SimpleNamespace(background_engine=state_row)


check("contract fixture parses to 3 CPU / 6 GiB", row.parse_record(FIXTURE) == (3, 6))
check("a zero or missing key is no record",
      row.parse_record("cpus=0\nmemory_gib=6") is None and row.parse_record("cpus=3") is None)

ok = row.evaluate(FIXTURE, colima_list(3, 6))
check("installed size running -> ok, named",
      ok["state"] == "ok" and ok["text"] == "Background engine: 3 CPU / 6 GB (installed size)", str(ok))
check("ok is silent in the Doctor", rules.check_background_engine_size(snap(ok)) == [])

# The Mini16 case: installed 3/6, restarted at 2/4.
small = row.evaluate(FIXTURE, colima_list(2, 4))
check("restarted at 2/4 after install chose 3/6 -> smaller", small["state"] == "smaller", str(small))
check("smaller names the fix", "restart Ostler to fix" in small["text"])
found = rules.check_background_engine_size(snap(small))
check("smaller raises one finding with a restart fix",
      len(found) == 1 and found[0]["fix_command"].endswith("colima start"), str(found))

# Memory-only shortfall: an `and` in place of `or` would call this ok.
mem_only = row.evaluate(FIXTURE, colima_list(3, 4))
check("memory-only shortfall (3/4 vs 3/6) is smaller", mem_only["state"] == "smaller", str(mem_only))

check("no record -> unrecorded, and no finding (older install)",
      row.evaluate(None, colima_list(2, 4))["state"] == "unrecorded"
      and rules.check_background_engine_size(snap(row.evaluate(None, colima_list(2, 4)))) == [])

unk = row.evaluate(FIXTURE, None)
check("colima silent -> unknown, never ok", unk["state"] == "unknown", str(unk))
check("unknown raises a finding, not silence",
      len(rules.check_background_engine_size(snap(unk))) == 1)

check("no snapshot attribute -> no finding (control)",
      rules.check_background_engine_size(SimpleNamespace()) == [])

# Cross-boundary: the installer's own writer, then the Doctor's reader.
with tempfile.TemporaryDirectory() as tmp:
    state = os.path.join(tmp, "state")
    script = (
        f'source "{ROOT}/lib/ostler-vm-size.sh"; OSTLER_VM_DISK_GIB=30; '
        f'OSTLER_VM_CPUS=3; OSTLER_VM_MEM_GIB=6; ostler_vm_record_size 3 6 installer'
    )
    rc = subprocess.run(["/bin/bash", "-c", script], env={"PATH": "/usr/bin:/bin",
                        "HOME": tmp, "OSTLER_STATE_DIR": state}, capture_output=True, text=True)
    check("installer writer runs", rc.returncode == 0, rc.stderr)
    os.environ["OSTLER_STATE_DIR"] = state
    try:
        record_text, _ = row.read_inputs()
        check("Doctor reads what the installer wrote (3 CPU / 6 GiB)",
              row.parse_record(record_text) == (3, 6), repr(record_text))
    finally:
        del os.environ["OSTLER_STATE_DIR"]

print(f"background_engine_size_row: {total} checks run, {fails} failed")
sys.exit(1 if fails else 0)
