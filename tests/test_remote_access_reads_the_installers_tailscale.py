"""Remote access reads and drives the INSTALLER's Tailscale (v1.0.106).

Andy's v1.0.105 walk: Settings said remote access was OFF while the
installer's tailscaled was connected. vendor/doctor/agent/remote_access.py
talks to that tailscaled through its own socket, with install.sh's own `up`
flags. This executes it with the tailscale CLI stubbed. Synthetic only.

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
AGENT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))
try:
    import remote_access as ra
except Exception as exc:
    print(f"CANNOT-RUN: could not import remote_access from {AGENT}: {exc}", file=sys.stderr)
    sys.exit(2)

fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


calls = []
backend = {"state": "Running"}


def fake_run(argv, capture_output, text, timeout):
    calls.append(argv)
    if "status" in argv:
        return SimpleNamespace(returncode=0, stdout=json.dumps({"BackendState": backend["state"]}), stderr="")
    if "down" in argv:
        backend["state"] = "Stopped"
    if "up" in argv:
        backend["state"] = "Running"
    return SimpleNamespace(returncode=0, stdout="", stderr="")


with tempfile.TemporaryDirectory() as td:
    os.environ["OSTLER_DIR"] = td
    ra._cli = lambda: "/fake/tailscale"
    ra.subprocess.run = fake_run
    check("no installer socket means not installed", ra.status()["installed"] is False)
    sock = Path(td) / "tailscale" / "tailscaled.sock"
    sock.parent.mkdir()
    sock.write_text("")
    st = ra.status()
    check("a Running backend reads as connected", st["installed"] and st["connected"])
    check("every call goes through the installer's socket",
          all(f"--socket={sock}" in c for c in calls))
    off = ra.set_enabled(False)
    check("turning off runs `down`", any(c[-1] == "down" for c in calls))
    check("and then reads as not connected", off["connected"] is False)
    on = ra.set_enabled(True)
    check("turning on runs `up` with install.sh's hostname flag",
          any(c[-2:] == ["up", "--hostname=ostler-hub"] for c in calls))
    check("and then reads as connected", on["connected"] is True)

inst = (REPO / "install.sh").read_text(errors="replace")
check("the flags match what install.sh used",
      ' up --hostname=ostler-hub ' in inst and ra.UP_ARGS == ("up", "--hostname=ostler-hub"))

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
