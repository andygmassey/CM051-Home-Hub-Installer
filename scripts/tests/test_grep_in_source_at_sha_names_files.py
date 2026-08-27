"""First test coverage for the `grep_in_source_at_sha` proof kind.

🔴 WHY THIS FILE EXISTS AT ALL, AND IT IS NOT THE FEATURE IT TESTS.

Measured on origin/main 16d8cc04 before writing a line of it:

    grep_in_source_at_sha  mentioned in scripts/tests/  : 0 files
    grep_in_installer      mentioned in scripts/tests/  : 1 file, 6 times   (CONTROL)
    `--skip-source-at-sha` passed by the existing suite  : 46 times

82 tests pass in that suite and NOT ONE exercises this primitive -- the suite
hands the verifier `--skip-source-at-sha` and the whole function is stepped
over. So everything #1091 landed in it (the `path_hint` alias, the `_PROOF_KEYS`
whitelist, the self-describing discard, the `scope=` label) shipped with no
test that can tell whether it works. That is the #704 / #707 / #734 shape: the
fix landed, the test did not.

WHAT IS UNDER TEST HERE
-----------------------------------------------------------------------------
A whole-tree row reports `hits=N` and nothing else. N cannot tell a reader that
the matches are inside the GATE THAT HUNTS THE PATTERN rather than in the code
that implements it -- `verify_launchagent_pycache_guard.py` carries
PYTHONPYCACHEPREFIX 16 times as a PATTERN. ORM's residual on #1091. The fix
names the surviving files; these arms prove it names them, and prove the naming
is scoped to whole-tree rows where it carries information.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
VERIFIER = REPO / "scripts" / "verify_cut_manifest.py"


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   capture_output=True)


@pytest.fixture
def source_repo(tmp_path: Path) -> Path:
    """The cm051 checkout ITSELF, as a real git repo.

    `this-repo` resolves to the checkout under verification (verify_cut_manifest
    :104) -- deliberately, so a worktree is never graded against whatever branch
    the primary clone was left on. So the fixture repo IS the cm051 dir.
    """
    r = tmp_path / "cm051"
    (r / "cut-manifests").mkdir(parents=True)
    (r / "install.sh").write_text("#!/bin/bash\n")
    (r / "cut-manifests" / "permanent.yaml").write_text("version: permanent\nentries: []\n")
    _git(r, "init", "-q")
    _git(r, "config", "user.email", "t@example.test")
    _git(r, "config", "user.name", "t")
    # The implementation: carries the identifier once, for real.
    (r / "coordinator.swift").write_text('let k = "MARKER_TOKEN"\n')
    # The gate that HUNTS the identifier: carries it three times, as a pattern.
    # This is the file whose presence a bare `hits=` count cannot disclose.
    (r / "verify_marker_guard.py").write_text(
        'PAT = "MARKER_TOKEN"\n'
        'if "MARKER_TOKEN" in text:  # MARKER_TOKEN\n'
        '    pass\n'
    )
    _git(r, "add", "-A")
    _git(r, "commit", "-qm", "seed")
    return r


def _run_entry(tmp_path: Path, source_repo: Path, proof: dict) -> dict:
    """Invoke the verifier on a single-entry manifest, return the JSON result."""
    cm051 = source_repo
    entry = {"id": "row-under-test", "title": "names the files",
             "incident": "x", "proof": proof}
    import yaml  # noqa: PLC0415  -- optional dep, same as the suite it joins
    (cm051 / "cut-manifests" / "v9.9.9.yaml").write_text(
        yaml.safe_dump({"version": "v9.9.9", "entries": [entry]}))
    app = tmp_path / "App"
    (app / "Contents").mkdir(parents=True)
    (app / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
    proc = subprocess.run(
        [sys.executable, str(VERIFIER),
         "--cm051-dir", str(cm051), "--app-path", str(app),
         "--version", "v9.9.9", "--json"],
        capture_output=True, text=True,
    )
    # CANNOT-RUN is neither pass nor fail: if the verifier could not be driven
    # at all, say so loudly rather than letting an empty parse read as a result.
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        pytest.fail("CANNOT-RUN: verifier emitted no JSON.\n"
                    f"stdout={proc.stdout[-2000:]}\nstderr={proc.stderr[-2000:]}")
    rows = [r for r in payload.get("results", []) if r["id"] == "row-under-test"]
    assert rows, f"row absent from results: {payload}"
    return rows[0]


def test_whole_tree_row_names_the_matching_files(tmp_path, source_repo):
    """THE POINT: a whole-tree row must disclose WHICH files answered."""
    row = _run_entry(tmp_path, source_repo, {
        "kind": "grep_in_source_at_sha",
        "pattern": "MARKER_TOKEN",
        "must_match": True,
    })
    assert row["status"] == "PASS", row
    detail = row["detail"]
    assert "whole-tree" in detail, detail
    # Both files must be named -- the implementation AND the gate that hunts it.
    assert "coordinator.swift" in detail, detail
    assert "verify_marker_guard.py" in detail, (
        "the gate that CARRIES the pattern as a pattern is exactly the file a "
        "bare hit count hides; it must be named. detail=" + detail)


def test_a_bare_count_alone_is_not_enough(tmp_path, source_repo):
    """CONTROL on the claim: the row really does have >1 file behind its count.

    If the fixture only ever produced one file, the arm above would pass for a
    reason that has nothing to do with disclosure.
    """
    row = _run_entry(tmp_path, source_repo, {
        "kind": "grep_in_source_at_sha",
        "pattern": "MARKER_TOKEN",
        "must_match": True,
    })
    # 🔴 `hits` IS A LINE COUNT, NOT AN OCCURRENCE COUNT -- `git grep -c`
    # reports matching LINES. The guard file carries MARKER_TOKEN three times
    # but on only two lines, so it scores 2, not 3. I asserted 4 here and the
    # test corrected me. Worth stating beyond this file: every `hits=N` in a
    # cut manifest verdict is lines, so "16 hits in the pycache guard" is 16
    # LINES of that gate, not 16 mentions.
    assert "hits=3" in row["detail"], row["detail"]
    # 2 files behind that 3 -- otherwise the disclosure arm above would pass
    # for a reason unrelated to disclosure.
    assert row["detail"].count(",") >= 1, row["detail"]


def test_path_scoped_row_does_not_list_files(tmp_path, source_repo):
    """CONTROL the other way: a scoped row already names its file in `scope=`.

    Repeating it in a bracket list would be noise, and noise trains a reader to
    skip the line -- which is how the disclosure stops working.
    """
    row = _run_entry(tmp_path, source_repo, {
        "kind": "grep_in_source_at_sha",
        "pattern": "MARKER_TOKEN",
        "path_hint": "coordinator.swift",
        "must_match": True,
    })
    assert row["status"] == "PASS", row
    assert "path=coordinator.swift" in row["detail"], row["detail"]
    assert " in [" not in row["detail"], (
        "a scoped row must not repeat its own path as a file list. detail="
        + row["detail"])


def test_path_hint_is_honoured_not_silently_dropped(tmp_path, source_repo):
    """#1091's central fix, which until now had NO test.

    `path_hint:` is the spelling four live manifest rows use. Before #1091 the
    reader looked only for `path`, so the hint was accepted by the YAML and
    ignored -- the row whole-tree grepped and could be satisfied by anything.
    Scoping to a file that does NOT contain the pattern must FAIL.
    """
    row = _run_entry(tmp_path, source_repo, {
        "kind": "grep_in_source_at_sha",
        "pattern": "MARKER_TOKEN",
        "path_hint": "verify_marker_guard.py",
        "must_match": False,   # assert ABSENCE in a file that HAS it -> FAIL
    })
    assert row["status"] == "FAIL", (
        "must_match:false over a file that contains the pattern has to fail; "
        "a PASS here means path_hint was dropped and something else was read. "
        f"detail={row['detail']}")
