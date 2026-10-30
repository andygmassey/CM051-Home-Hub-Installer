#!/usr/bin/env python3
"""Doctor spawns no subprocess that touches a TCC-protected path (NEW-121).

MEASURED on the v1.0.120 box: com.ostler.doctor (the bundled python, a launchd
job) ran `tmutil isexcluded` on ~/.ostler, ~/Documents/Ostler and ~/.colima.
TCC charged the reads to python3.11, and the ~/Documents/Ostler one made a
NON-preflight SystemPolicyDocumentsFolder request: the shape that can show a
customer "python3 would like to access your Documents folder".

Three proofs, each with a control:

  1. BEHAVIOUR. check_time_machine_exclusion() is CALLED under an audit hook
     that records every process spawn and an os.stat wrapper that records
     every stat. A fake tmutil is on PATH (the real one is never run). It must
     spawn nothing and stat nothing under ~/Documents. RED at origin/main
     1a9aea59: it spawned tmutil with ~/Documents/Ostler in argv.
     Control: the hook DOES record a spawn the test makes itself.
  2. CONTRACT. The writer (_ostler_tm_status_record, extracted from the
     ostler-fda wrapper in install.sh and run under /bin/bash with the fake
     tmutil) and the reader (the Doctor rule) agree, end to end: excluded is
     silent, included names the folder, garbled is "could not check", a
     missing or stale file is "could not check", never a pass.
  3. SWEEP RATCHET. Every subprocess call site in vendor/doctor/agent is
     pinned below with what it runs. A new call site, or any literal argv
     naming a tool that reads file metadata or app data (tmutil, mdls, xattr,
     sqlite3, osascript, defaults, plutil, tccutil...), fails until it is
     swept for protected paths and added to the table.

Synthetic HOME under a temp dir; nothing on the real box is read.
"""
from __future__ import annotations

import ast
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
INSTALL_SH = REPO / "install.sh"

failures: list[str] = []
passes = 0


def check(cond: bool, msg: str) -> None:
    global passes
    if cond:
        passes += 1
        print(f"PASS: {msg}")
    else:
        failures.append(msg)
        print(f"FAIL: {msg}")


# ── shared fixture ──────────────────────────────────────────────────────────
WORK = Path(tempfile.mkdtemp(prefix="doctor-tcc-"))
HOME = WORK / "home"
(HOME / ".ostler").mkdir(parents=True)
(HOME / "Documents" / "Ostler").mkdir(parents=True)
(HOME / ".colima").mkdir(parents=True)
BIN = WORK / "bin"
BIN.mkdir()
ARGV_LOG = WORK / "tmutil-argv.log"
FAKE_TMUTIL = BIN / "tmutil"
FAKE_TMUTIL.write_text(
    "#!/bin/bash\n"
    'printf "%s\\n" "$*" >> "' + str(ARGV_LOG) + '"\n'
    'case "${FAKE_TM:-excluded}" in\n'
    '  excluded) printf "[Excluded]  %s\\n" "$2" ;;\n'
    '  included) [[ "$2" == "${FAKE_TM_INCLUDED:-}" ]] && printf "[Included]  %s\\n" "$2" || printf "[Excluded]  %s\\n" "$2" ;;\n'
    '  garbled)  echo garbled ;;\n'
    '  errors)   echo "tmutil: could not read the exclusion list." >&2; exit 1 ;;\n'
    "esac\n"
)
FAKE_TMUTIL.chmod(0o755)
os.environ["HOME"] = str(HOME)
os.environ["PATH"] = f"{BIN}{os.pathsep}{os.environ.get('PATH', '')}"
sys.path.insert(0, str(AGENT))

SPAWNS: list[str] = []
STATS: list[str] = []
_REAL_STAT = os.stat


def _audit(event: str, args) -> None:
    if event in ("subprocess.Popen", "os.posix_spawn", "os.system", "os.exec", "os.spawn"):
        SPAWNS.append(f"{event} {args!r}")


sys.addaudithook(_audit)


def _recording_stat(path, *a, **kw):
    STATS.append(os.fspath(path) if not isinstance(path, int) else str(path))
    return _REAL_STAT(path, *a, **kw)


import diagnostic_rules as rules  # noqa: E402

DOCS = str(HOME / "Documents")
STATUS = HOME / ".ostler" / "state" / "time_machine_exclusion.tsv"


def run_rule() -> tuple[list[dict], list[str], list[str]]:
    SPAWNS.clear()
    STATS.clear()
    # The rule ships on macOS only; CI runs this on ubuntu, so it is judged as
    # on a Mac (off a Mac with no status file it is "not applicable").
    real_platform = sys.platform
    sys.platform = "darwin"
    os.stat = _recording_stat
    try:
        out = rules.check_time_machine_exclusion(None)
    finally:
        os.stat = _REAL_STAT
        sys.platform = real_platform
    return out, list(SPAWNS), list(STATS)


# ── 1. behaviour: the rule spawns nothing and stats nothing in Documents ───
# Control first: the hook sees a spawn this test makes.
SPAWNS.clear()
subprocess.run(["/bin/echo", "control"], capture_output=True)
check(any("/bin/echo" in s for s in SPAWNS),
      "control: the audit hook records a process spawn (so 0 below is a measurement)")
os.stat = _recording_stat
os.path.isdir(DOCS)
os.stat = _REAL_STAT
check(any(p.startswith(DOCS) for p in STATS),
      "control: the stat recorder sees a stat under ~/Documents")

for fake in ("excluded", "garbled"):
    os.environ["FAKE_TM"] = fake
    ARGV_LOG.unlink(missing_ok=True)
    findings, spawns, stats = run_rule()
    argv = ARGV_LOG.read_text() if ARGV_LOG.exists() else ""
    check(spawns == [], f"[{fake}] check_time_machine_exclusion spawns no process (got {spawns[:3]})")
    check(DOCS not in argv,
          f"[{fake}] no tmutil argv names a ~/Documents path (argv log: {argv.strip()[:200]!r})")
    check(not any(p.startswith(DOCS) for p in stats),
          f"[{fake}] the rule stats nothing under ~/Documents "
          f"(got {[p for p in stats if p.startswith(DOCS)][:3]})")

# ── 2. contract: the real writer feeds the real reader ─────────────────────
wrapper = re.search(r"<<'FDAEOF'\n(.*?)\nFDAEOF\n", INSTALL_SH.read_text(), re.S)
check(wrapper is not None, "the ostler-fda wrapper heredoc is found in install.sh")
fn = ""
if wrapper:
    m = re.search(r"^_ostler_tm_status_record\(\) \{\n.*?^\}\n", wrapper.group(1), re.S | re.M)
    check(m is not None, "_ostler_tm_status_record is defined inside the ostler-fda wrapper")
    fn = m.group(0) if m else ""
    check("\n_ostler_tm_status_record || true\n" in wrapper.group(1),
          "the wrapper CALLS _ostler_tm_status_record (non-fatal)")
    check(wrapper.group(1).find("_ostler_tm_status_record || true")
          < wrapper.group(1).find("_fda_rc=0"),
          "the status is recorded BEFORE the long extract")


def run_writer(fake: str, included: str = "") -> int:
    script = WORK / "writer.sh"
    script.write_text(
        "set -Eeuo pipefail\ntrap 'echo ABORTED >&2' ERR\n"
        f'OSTLER_DIR="{HOME}/.ostler"\n' + fn + "_ostler_tm_status_record || true\necho REACHED\n"
    )
    env = dict(os.environ, FAKE_TM=fake, FAKE_TM_INCLUDED=included)
    p = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True)
    return 0 if p.stdout.strip().endswith("REACHED") and "ABORTED" not in p.stderr else 1


def titles(findings):
    return [(f["severity"], f["title"]) for f in findings]


if fn:
    STATUS.unlink(missing_ok=True)
    out, _, _ = run_rule()
    check(any("Could not check" in t for _, t in titles(out)),
          f"no status file yet: 'could not check', never a pass ({titles(out)})")

    check(run_writer("excluded") == 0, "writer (excluded) runs to the end under set -Eeuo pipefail, bash 3.2")
    body = STATUS.read_text() if STATUS.exists() else ""
    check(body.count("folder\texcluded\t") == 3,
          f"writer records 3 excluded folders ({body!r})")
    out, spawns, _ = run_rule()
    check(out == [] and spawns == [], f"excluded on all three: no finding, no spawn ({titles(out)})")

    run_writer("included", str(HOME / "Documents" / "Ostler"))
    out, _, _ = run_rule()
    check(any("Documents/Ostler is NOT excluded" in t for _, t in titles(out))
          and not any("secrets folder" in t for _, t in titles(out)),
          f"included ~/Documents/Ostler is named, the others are not ({titles(out)})")
    run_writer("included", str(HOME / ".ostler"))
    out, _, _ = run_rule()
    check(any(t == "Ostler's secrets folder is NOT excluded from Time Machine" for _, t in titles(out)),
          f"included ~/.ostler uses the secrets-folder title ({titles(out)})")

    for fake in ("garbled", "errors"):
        run_writer(fake)
        out, _, _ = run_rule()
        check(any(s == "warning" and "Could not check" in t for s, t in titles(out))
              and not any("NOT excluded" in t for _, t in titles(out)),
              f"{fake} tmutil: 'could not check' warning, no false 'NOT excluded' ({titles(out)})")

    # A stale answer is not a current one.
    run_writer("excluded")
    old = STATUS.read_text().replace(
        STATUS.read_text().splitlines()[0],
        f"recorded_at\t{int(time.time()) - rules.TM_STATUS_MAX_AGE_SECONDS - 60}")
    STATUS.write_text(old)
    out, _, _ = run_rule()
    check(any("Could not check" in t for _, t in titles(out)),
          f"stale status file: 'could not check' ({titles(out)})")

    # A folder that does not exist: recorded absent, nothing to back up.
    os.rmdir(HOME / ".colima")
    run_writer("excluded")
    check("folder\tabsent\t" + str(HOME / ".colima") in STATUS.read_text(),
          "writer records a missing folder as absent")
    out, _, _ = run_rule()
    check(out == [], f"absent folder is skipped, not 'could not check' ({titles(out)})")
    (HOME / ".colima").mkdir()

# ── 3. sweep ratchet: every Doctor subprocess call site, pinned ────────────
# file -> number of spawn call sites. Each row was swept for the path it
# touches (the PR body carries the table). A change here needs the sweep.
PINNED = {
    "box_status.py": 5,             # sysctl, vm_stat, ps, top, bash <~/.ostler/lib tier lib>
    "daemon_cron.py": 1,            # launchctl kickstart
    "diagnostic_rules.py": 2,       # launchctl print x2
    "import_evernote.py": 1,        # python runner on a CUSTOMER-CHOSEN path (see PR: oa route owed)
    "import_evernote_runner.py": 1, # ostler-knowledge convert/embed phases
    "import_notion.py": 1,          # same shape as evernote
    "import_obsidian.py": 1,        # same shape as evernote
    "remote_access.py": 1,          # tailscale --socket ~/.ostler/tailscale
    "routine_status.py": 1,         # launchctl print
    "status_collector.py": 2,       # docker ps, docker version
    "test_health_gate.py": 1,       # pytest (dev-only __main__)
}
METADATA_TOOLS = {"tmutil", "mdls", "mdfind", "xattr", "sqlite3", "osascript", "defaults",
                  "plutil", "tccutil", "ls", "cat", "find", "stat", "du", "open", "mdutil"}
SPAWN_ATTRS = {"run", "Popen", "call", "check_output", "check_call", "system", "popen",
               "posix_spawn", "posix_spawnp", "execv", "execvp", "execve", "spawnv"}
found: dict[str, int] = {}
literal_tools: list[tuple[str, int, str]] = []
for py in sorted(AGENT.glob("*.py")):
    tree = ast.parse(py.read_text(), filename=str(py))
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        if node.func.attr not in SPAWN_ATTRS or not isinstance(node.func.value, ast.Name):
            continue
        if node.func.value.id not in ("subprocess", "sub", "os"):
            continue
        if node.func.value.id == "os" and node.func.attr in ("run", "call"):
            continue
        found[py.name] = found.get(py.name, 0) + 1
        if node.args and isinstance(node.args[0], ast.List) and node.args[0].elts:
            first = node.args[0].elts[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                literal_tools.append((py.name, node.lineno, first.value))
check(found == PINNED, f"Doctor spawn call sites match the swept table (found {found})")
bad = [t for t in literal_tools if os.path.basename(t[2]) in METADATA_TOOLS]
check(bad == [], f"no Doctor call site spawns a metadata/app-data tool (got {bad})")
check(len(literal_tools) >= 5,
      f"control: the AST scan reads literal argv (saw {len(literal_tools)}: {literal_tools})")

print(f"denominator: {passes + len(failures)} checks, {len(failures)} failed")
sys.exit(1 if failures else 0)
