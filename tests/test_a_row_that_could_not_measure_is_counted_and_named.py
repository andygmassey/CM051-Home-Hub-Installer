#!/usr/bin/env python3
"""A row that could not measure must be COUNTED, NAMED, and still block.

TWO DEFECTS, ONE CLASS, BOTH MEASURED 2026-09-06.

(1) THE SUMMARY LINE DID NOT CARRY CANNOT-RUN. Driven end-to-end through the
    real main() with two rows, one CANNOT-RUN and one PASS:

        CANNOT-RUN  row-cannot-run   probe could not measure
        PASS        row-passes       probe measured fine
        === Summary: 1 PASS  0 FAIL  0 SKIP  (2 total) ===

    1 + 0 + 0 = 1. The total says 2. The row was rendered above and it blocked
    the cut correctly -- the exit code was 1 -- but the ONE line a CI log tail
    keeps, and the one a tired operator reads, said "1 PASS 0 FAIL 0 SKIP" and
    looked like a clean run.

    #713 gave SKIP a named block because a bare skip COUNT reads as "nothing to
    report". CANNOT-RUN had no count AT ALL, which is a rung below the thing
    #713 fixed. This is not hypothetical for long: #1626 routes a live row --
    the assistant-grounding probe -- into that status, and the reason that PR
    exists is that the finding stayed invisible for a whole manifest run.

(2) check_grep_in_source_at_sha CALLED A TIMEOUT A FAILURE. The same defect
    #1626 fixed in check_box_walk_probe, one function up, in the same file:

        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            return Result(..., "grep_in_source_at_sha", "FAIL", ...)

    An AST walk over every handler in that file catching TimeoutExpired found
    six: two already split correctly (_gh_api_json, _fetch_asset_content), one
    fixed by #1626, and three still combined. This takes the second of the
    three. `git grep` over a whole tree at a sha is a cold-object read; a repo
    just fetched, or on a network volume, is slow for reasons that say nothing
    about the code being searched.

THE DISTINCTION THAT MUST SURVIVE, and it is why the handler is SPLIT and not
WIDENED: git NOT ON DISK stays a FAIL. That row names a proof this machine
cannot perform at all. Only "it ran and did not finish" is CANNOT-RUN.

AND THE HALF THAT IS EASY TO LOSE: making CANNOT-RUN visible must not make it
soft. Arm 9 pins the exit code at 1 for the same run arm 7 reads the counts
from. Delete either and the other alone is satisfiable by a regression.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
SUBJECT = REPO / "scripts" / "verify_cut_manifest.py"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def cant(msg):
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    sys.exit(2)


if not SUBJECT.is_file():
    cant(f"no verify_cut_manifest.py at {SUBJECT}")

try:
    import yaml  # noqa: F401
except ImportError:
    cant("PyYAML is not installed, so main() cannot read a manifest and the "
         "end-to-end arms would report a reporting defect that is really a "
         "missing dependency")

spec = importlib.util.spec_from_file_location("vcm", SUBJECT)
vcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcm)

work = pathlib.Path(tempfile.mkdtemp())

# ---------------------------------------------------------------------------
# PART ONE -- check_grep_in_source_at_sha, driven directly.
# ---------------------------------------------------------------------------
# A repo the resolver will accept: target "this-repo" resolves straight to
# cm051_dir, and the function SKIPs unless .git is there.
repo = work / "repo"
(repo / ".git").mkdir(parents=True)

fakebin = work / "fakebin"
fakebin.mkdir()


# 🔴 PREPEND to PATH, NEVER REPLACE IT, AND CALL sleep BY ABSOLUTE PATH.
# First draft did neither: PATH was set to the planted directory alone, so the
# fake git's own `#!/bin/bash` script could not find `sleep`, died at 127
# instantly, and the three timeout arms tested a FAST ERROR while claiming to
# test a timeout. The MUST-MISS arm at the bottom is the only thing that said
# so -- the timeout arms themselves just reported FAIL, which is exactly what
# they report when the fix is absent. A must-miss is not paperwork.
def plant_git(body: str) -> None:
    g = fakebin / "git"
    g.write_text(body)
    g.chmod(0o755)


def with_path(extra_first: str | None):
    """Return an env-restoring context: PATH with only what we planted, or none."""
    return extra_first


def run_check(proof: dict):
    entry = {"id": "row-source", "title": "source proof", "proof": proof}
    return vcm.check_grep_in_source_at_sha(entry, {"cm051_dir": repo})


_saved_path = os.environ["PATH"]

# Squeeze both caps so "slow" is reachable in a test rather than in a minute.
vcm.GIT_SHOW_TIMEOUT_SECONDS = 2
vcm.GIT_GREP_TIMEOUT_SECONDS = 2

print("== git ran and did not finish: CANNOT-RUN, not FAIL ==")
plant_git("#!/bin/bash\nexec /bin/sleep 30\n")
os.environ["PATH"] = str(fakebin) + os.pathsep + _saved_path

r = run_check({"pattern": "anything"})           # whole-tree -> git grep
if r.status == "CANNOT-RUN":
    ok("git grep killed at its cap reports CANNOT-RUN")
elif r.status == "FAIL":
    bad("git grep killed at its cap still reports FAIL -- an instrument error "
        "goes onto the cut-blocker list beside real defects")
else:
    bad(f"git grep killed at its cap reports {r.status!r}")

r_show = run_check({"pattern": "anything", "path": "install.sh"})   # -> git show
if r_show.status == "CANNOT-RUN":
    ok("git show killed at its cap reports CANNOT-RUN (BOTH git calls, not just one)")
else:
    bad(f"git show killed at its cap reports {r_show.status!r} -- the handler "
        f"covers both invocations and only one was proved")

if "NOTHING was measured" in r.detail:
    ok("the detail says NOTHING was measured, so the row cannot be read as a verdict")
else:
    bad(f"the detail does not say the proof measured nothing: {r.detail!r}")

print("== CONTROL: the status is a measurement, not a blanket ==")
# git grep exit 1 == "no match", which is a real completed measurement. With
# must_match False that is the PASS case: proof that a timeout and a clean
# result do not collapse into the same answer.
plant_git("#!/bin/bash\nexit 1\n")
r_ok = run_check({"pattern": "anything", "must_match": False})
if r_ok.status == "PASS":
    ok("CONTROL: a git that COMPLETES inside the cap still PASSES, so CANNOT-RUN "
       "above is a measurement and not a blanket")
else:
    bad(f"CONTROL: a completing git reports {r_ok.status!r} ({r_ok.detail!r})")

print("== git NOT ON DISK is still a FAIL, and must not be softened ==")
os.environ["PATH"] = str(work / "empty-no-such-dir")
r_missing = run_check({"pattern": "anything"})
if r_missing.status == "FAIL":
    ok("git absent FAILs: the row names a proof this machine cannot perform at all")
else:
    bad(f"git absent reports {r_missing.status!r} -- softening this would let a "
        f"row claim a proof that was never available")

print("== MUST-MISS: the sleeper genuinely exceeds the cap ==")
os.environ["PATH"] = str(fakebin) + os.pathsep + _saved_path
plant_git("#!/bin/bash\nexec /bin/sleep 30\n")
_t0 = time.time()
try:
    subprocess.run([str(fakebin / "git"), "--version"], capture_output=True,
                   check=False, timeout=2)
    bad("MUST-MISS: the sleeper did not time out at a 2s cap, so the arms above "
        "never exercised a real timeout")
except subprocess.TimeoutExpired:
    ok(f"MUST-MISS: the sleeper genuinely exceeds a 2s cap "
       f"({time.time() - _t0:.1f}s), so the arms above exercised a real timeout "
       f"rather than a fast error")
os.environ["PATH"] = _saved_path

# ---------------------------------------------------------------------------
# PART TWO -- the summary line, driven end-to-end through the real main().
# ---------------------------------------------------------------------------
# Deliberately produced via the PRE-EXISTING exit-78 path, NOT via the git fix
# above. If this arm used my own change to manufacture its CANNOT-RUN it would
# be measuring the fix with the fix.
e2e = work / "e2e"
cm051 = e2e / "cm051"
(cm051 / "cut-manifests").mkdir(parents=True)
(cm051 / "install.sh").write_text("#!/bin/bash\n# fake installer\n")
probes = cm051 / "scripts" / "box_walk_probes"
probes.mkdir(parents=True)


def plant_probe(name: str, body: str) -> None:
    p = probes / f"{name}.sh"
    p.write_text(body)
    p.chmod(0o755)


plant_probe("unreadable", "#!/bin/bash\necho 'VERDICT: CANNOT-RUN -- unreadable'\nexit 78\n")
plant_probe("fine", "#!/bin/bash\necho ok\nexit 0\n")

app = e2e / "OstlerInstaller.app"
macos = app / "Contents" / "Resources" / "Ostler.app" / "Contents" / "MacOS"
macos.mkdir(parents=True)
import plistlib
with (app / "Contents" / "Resources" / "Ostler.app" / "Contents" / "Info.plist").open("wb") as fh:
    plistlib.dump({"CFBundleExecutable": "ostler-hub"}, fh)
(macos / "ostler-hub").write_bytes(b"BEGIN\nfake\nEND\n")


def write_manifest(name: str, entries: list) -> None:
    import yaml as _y
    (cm051 / "cut-manifests" / name).write_text(_y.safe_dump({"entries": entries}))


ROW_CANNOT = "row-that-could-not-measure"
ROW_PASS = "row-that-measured"


def run_main(entries: list):
    write_manifest("permanent.yaml", [])
    write_manifest("v1.0.0.yaml", entries)
    env = {k: v for k, v in os.environ.items() if k != "DAEMON_VERSION"}
    env["OSTLER_BOX_HOST"] = "probe@example.invalid"
    return subprocess.run(
        [sys.executable, str(SUBJECT), "--cm051-dir", str(cm051),
         "--app-path", str(app), "--skip-source-at-sha"],
        capture_output=True, check=False, text=True, env=env)


ENTRY_CANNOT = {"id": ROW_CANNOT, "title": "probe could not measure",
                "proof": {"kind": "box_walk_probe", "probe": "unreadable"}}
ENTRY_PASS = {"id": ROW_PASS, "title": "probe measured fine",
              "proof": {"kind": "box_walk_probe", "probe": "fine"}}

print("== the summary line carries CANNOT-RUN, and the counts close ==")
mixed = run_main([ENTRY_CANNOT, ENTRY_PASS])
summary_lines = [ln for ln in mixed.stdout.splitlines() if "=== Summary:" in ln]
if not summary_lines:
    cant("main() printed no summary line at all, so there is nothing to measure "
         f"(rc={mixed.returncode}); stderr tail: {mixed.stderr.strip()[-400:]!r}")
summary = summary_lines[0]

if "CANNOT-RUN" in summary:
    ok(f"the summary line carries CANNOT-RUN: {summary.strip()}")
else:
    bad(f"the summary line has no CANNOT-RUN count, so an unmeasured row is "
        f"invisible on the one line a log tail keeps: {summary.strip()}")

import re as _re
nums = {w: int(n) for n, w in _re.findall(
    r"(\d+)\s+(PASS|FAIL|SKIP|CANNOT-RUN)", summary)}
m_total = _re.search(r"\((\d+) total", summary)
if not m_total:
    bad(f"the summary line states no total, so the arithmetic cannot be checked: {summary!r}")
else:
    total = int(m_total.group(1))
    counted = sum(nums.values())
    if counted == total:
        ok(f"the counts close: {' + '.join(f'{v} {k}' for k, v in nums.items())} "
           f"= {total} total")
    else:
        bad(f"the counts do not close: {nums} sums to {counted} but the total "
            f"says {total} -- a row is in the denominator and in none of the "
            f"statuses")

print("== the unmeasured rows are NAMED, not just counted ==")
named = [ln for ln in mixed.stdout.splitlines()
         if ROW_CANNOT in ln and ln.strip().startswith("-")]
if named:
    ok(f"the CANNOT-RUN row is named in a block, as #713 required for SKIP: "
       f"{named[0].strip()[:90]}")
else:
    bad(f"the CANNOT-RUN row {ROW_CANNOT!r} is counted but never named, which is "
        f"the exact shape #713 fixed for SKIP")

print("== VISIBILITY MUST NOT COST BLOCKING ==")
if mixed.returncode == 1:
    ok("the same run still exits 1: CANNOT-RUN is relabelled and counted, NOT "
       "downgraded to something that lets a cut through")
else:
    bad(f"the run exits {mixed.returncode}, not 1 -- making CANNOT-RUN visible "
        f"has made it soft, which is worse than the defect")

print("== CONTROL: a clean run says 0 CANNOT-RUN and exits 0 ==")
clean = run_main([ENTRY_PASS])
clean_summary = [ln for ln in clean.stdout.splitlines() if "=== Summary:" in ln]
if not clean_summary:
    cant(f"the control run printed no summary (rc={clean.returncode})")
if "0 CANNOT-RUN" in clean_summary[0] and clean.returncode == 0:
    ok("CONTROL: an all-PASS run reports 0 CANNOT-RUN and exits 0, so the count "
       "above is a measurement and the block is not unconditional")
else:
    bad(f"CONTROL: clean run rc={clean.returncode}, summary "
        f"{clean_summary[0].strip()!r} -- expected 0 CANNOT-RUN and rc=0")
if "COULD NOT MEASURE" in clean.stdout:
    bad("CONTROL: the clean run printed the CANNOT-RUN block with nothing in it")
else:
    ok("CONTROL: the clean run prints no empty CANNOT-RUN block")

shutil.rmtree(work, ignore_errors=True)

print(f"\n== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
