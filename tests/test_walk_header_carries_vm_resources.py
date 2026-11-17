#!/usr/bin/env python3
"""The walk record carries the VM's resources at walk START and END.

A FAIL on a memory-starved box is attributable only if the record shows what the VM had: its cpus,
memory and disk (colima) and vm_stat's free pages. The helper lib/walk_vm_resources.sh is read-only
and is called at both ends of run_box_walk.sh.

Checks:
  - run_box_walk.sh calls walk_vm_resources at walk START (after the header) and at walk END
  - the helper, run with a fake colima and a fake vm_stat, prints cpus, memory, disk and Pages free
  - a missing colima is "not measured", never a zero
  - RED before the change: on main there is no helper and no call, so the first check fails

Stubs only (fake colima, fake vm_stat on PATH); no real VM is touched. Exit 0 pass, 1 fail.
"""
import os
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BOX = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes")
RUNNER = os.path.join(BOX, "run_box_walk.sh")
LIB = os.path.join(BOX, "lib", "walk_vm_resources.sh")


def fake_bin(d, colima=True):
    if colima:
        with open(os.path.join(d, "colima"), "w") as fh:
            fh.write('#!/bin/sh\necho \'{"name":"default","cpus":2,"memory":4294967296,"disk":32212254720,"status":"Running"}\'\n')
        os.chmod(os.path.join(d, "colima"), stat.S_IRWXU)
    with open(os.path.join(d, "vm_stat"), "w") as fh:
        fh.write("#!/bin/sh\necho 'Mach Virtual Memory Statistics: (page size of 16384 bytes)'\necho 'Pages free:                 6714.'\n")
    os.chmod(os.path.join(d, "vm_stat"), stat.S_IRWXU)


def run_helper(colima=True):
    d = tempfile.mkdtemp(prefix="vmres-")
    fake_bin(d, colima=colima)
    env = {"PATH": d + ":/usr/bin:/bin", "HOME": d}
    out = subprocess.run(["bash", "-c", '. "$L"; walk_vm_resources "walk start"'],
                         env=dict(env, L=LIB), capture_output=True, text=True)
    return out.stdout


def main():
    bad = []
    with open(RUNNER, encoding="utf-8") as fh:
        runner = fh.read()
    start = runner.find('walk_vm_resources "walk start"')
    end = runner.find('walk_vm_resources "walk end"')
    header = runner.find("BOX WALK -- %s probes")
    if start == -1 or end == -1:
        bad.append("run_box_walk.sh must call walk_vm_resources at walk START and at walk END")
    elif not header < start:
        bad.append("the START resources must be printed with the header, before the probes")
    if not os.path.isfile(LIB):
        bad.append("lib/walk_vm_resources.sh is missing")
    else:
        out = run_helper()
        for field in ("cpus=", "memory=", "disk=", "Pages free="):
            if field not in out:
                bad.append("the header must carry %s (got: %r)" % (field, out[:160]))
        gone = run_helper(colima=False)
        if "colima: not measured" not in gone or "cpus=0" in gone:
            bad.append("CONTROL: with colima absent the VM must read not measured, never a zero")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the walk record carries cpus, memory, disk and vm_stat free pages at start and end; absent colima is not measured")
    return 0


if __name__ == "__main__":
    sys.exit(main())
