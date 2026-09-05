#!/usr/bin/env python3
"""A manifest row's `min_hits` floor, driven against real git checkouts.

WHY THIS EXISTS.

MEASURED on cut-manifests/v1.0.71.yaml, 2026-09-05:

    entries                                    38
    proof kind grep_in_source_at_sha           38   (there is no other kind)
    patterns that are a bare identifier in a code file   10
    of those, sitting at exactly 1 definition + 1 use     3

For those three, deleting the single remaining call leaves a DEAD DEFINITION
that still satisfies `must_match: true`. That is precisely the shape of the
defect row v1064-ae is named after: a guard that existed and was never called,
while "every audit that started from the guarded function came back clean".

`min_hits` raises the floor from "appears at all" to "appears at least N times".

BE HONEST ABOUT THE LIMIT, because a proof primitive that oversells itself is
the thing being fixed here. A count is STILL a presence check. `min_hits: 2`
proves a definition is not alone in its file; it does NOT prove the second
occurrence is ever reached. A behavioural claim still needs a test that drives
it. This closes the cheapest regression, not the class.

Exit: 0 all arms pass, 1 a real failure, 2 CANNOT-RUN.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "scripts"))

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ok    %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  FAIL  %s" % msg, file=sys.stderr)


def cannot(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    print("A check that could not run has not passed.", file=sys.stderr)
    sys.exit(2)


if not shutil.which("git"):
    cannot("git is not on PATH; this test drives real checkouts")

try:
    import verify_cut_manifest as V
except Exception as exc:
    cannot("could not import verify_cut_manifest: %s: %s" % (type(exc).__name__, exc))

if not hasattr(V, "check_grep_in_source_at_sha"):
    cannot("verify_cut_manifest has no check_grep_in_source_at_sha")

if "min_hits" not in V._PROOF_KEYS:
    bad("min_hits is not in _PROOF_KEYS, so any row using it is refused as an "
        "unknown key before the floor can ever be applied")
    print("\n%d passed, %d failed" % (PASS, FAIL))
    sys.exit(1)
ok("min_hits is a recognised proof key")

WORK = Path(tempfile.mkdtemp(prefix="minhits-"))


def _git(*args, cwd):
    r = subprocess.run(["git", "-C", str(cwd)] + list(args),
                       capture_output=True, text=True)
    if r.returncode != 0:
        cannot("git %s failed in %s: %s" % (" ".join(args), cwd, r.stderr.strip()[:200]))
    return r.stdout


def make_repo(name, body):
    d = WORK / name
    d.mkdir(parents=True)
    _git("init", "-q", cwd=d)
    _git("config", "user.email", "t@example.invalid", cwd=d)
    _git("config", "user.name", "t", cwd=d)
    (d / "subject.py").write_text(body, encoding="utf-8")
    _git("add", "subject.py", cwd=d)
    _git("commit", "-qm", "fixture", cwd=d)
    return d


# One occurrence: the definition, and nothing calls it. This is the dead
# definition the floor exists to catch.
DEAD = make_repo("dead", "def _guard():\n    return True\n")
# Two occurrences: a definition and a call.
LIVE = make_repo("live", "def _guard():\n    return True\n\n\nif _guard():\n    pass\n")

n_dead = (DEAD / "subject.py").read_text().count("_guard")
n_live = (LIVE / "subject.py").read_text().count("_guard")
if n_dead != 1 or n_live != 2:
    cannot("fixtures are not the shape this test assumes (dead=%d live=%d)" % (n_dead, n_live))
ok("CONTROL: fixtures carry the pattern %d and %d time(s), so the floor has "
   "something to discriminate" % (n_dead, n_live))


def run(repo, **proof):
    p = {"kind": "grep_in_source_at_sha", "target": "this-repo",
         "pattern": "_guard", "path_hint": "subject.py"}
    p.update(proof)
    entry = {"id": "t", "title": "t", "proof": p}
    return V.check_grep_in_source_at_sha(entry, {"cm051_dir": repo, "app_path": None})


# ── ARM 1: CONTROL. Without min_hits, one hit still passes ─────────────────
# Every one of the 38 live rows omits min_hits. If this regressed, the change
# would break the whole manifest rather than raise its floor.
r = run(DEAD)
if r.status == "PASS":
    ok("CONTROL: a row with no min_hits still passes on a single hit, so the "
       "38 existing rows are unaffected")
else:
    bad("a row without min_hits now %s on one hit: this change breaks every "
        "existing manifest row (%s)" % (r.status, r.detail[:120]))

# ── ARM 2: THE DEFECT. A dead definition must not satisfy a floor of 2 ─────
r = run(DEAD, min_hits=2)
if r.status == "FAIL":
    ok("a definition with no remaining use FAILS min_hits=2, which is the "
       "regression a bare must_match cannot see")
else:
    bad("a dead definition %s against min_hits=2; the floor is not being "
        "applied (%s)" % (r.status, r.detail[:140]))

# ── ARM 3: CONTROL. The floor must be satisfiable, or arm 2 proves nothing ─
r = run(LIVE, min_hits=2)
if r.status == "PASS":
    ok("CONTROL: a definition plus a use PASSES min_hits=2, so arm 2 is a "
       "measurement and not a floor that refuses everything")
else:
    bad("a live definition+use %s against min_hits=2; the floor refuses valid "
        "code (%s)" % (r.status, r.detail[:140]))

# ── ARM 4: contradictory instructions are refused, not guessed at ──────────
r = run(LIVE, min_hits=2, must_match=False)
if r.status == "FAIL" and "contradictory" in r.detail:
    ok("min_hits with must_match:false is refused as contradictory rather than "
       "silently resolved one way")
else:
    bad("min_hits with must_match:false gave %s (%s); a floor on a pattern that "
        "must not occur has no honest reading" % (r.status, r.detail[:120]))

# ── ARM 5: the value itself is validated ───────────────────────────────────
for bogus in (0, -1, "two", 1.5, True):
    r = run(LIVE, min_hits=bogus)
    if r.status == "FAIL":
        ok("min_hits=%r is refused" % (bogus,))
    else:
        bad("min_hits=%r was accepted (%s); a floor nobody validated is a floor "
            "that can be silently disabled" % (bogus, r.status))

# ── ARM 6: the unknown-key guard still bites ───────────────────────────────
# Adding a key to the whitelist is exactly the edit that could widen it by
# accident. This is the must-miss for arm 1.
r = run(LIVE, min_hitz=2)
if r.status == "FAIL" and "unknown proof key" in r.detail:
    ok("a misspelled key is still refused, so widening the whitelist did not "
       "disable it")
else:
    bad("a misspelled proof key gave %s (%s); the whitelist no longer refuses "
        "instructions it does not understand" % (r.status, r.detail[:120]))

shutil.rmtree(WORK, ignore_errors=True)
print()
print("%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
