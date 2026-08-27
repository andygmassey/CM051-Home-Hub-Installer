#!/usr/bin/env python3
"""grep_in_source_at_sha must measure the CODE, not the prose describing itself.

WHY THIS FILE EXISTS
────────────────────
2026-08-26. v1.0.46 shipped a bricked installer while the cut manifest row
named `v1046-c-the-bricking-fix-is-in-the-pinned-source` was GREEN.

Three defects stacked:

  1. The row wrote `path_hint:`; the reader consumed `proof.get("path")`. The
     key was silently dropped, so a targeted single-file check became a
     whole-tree `git grep`.
  2. The row's own pattern ('PYTHONPYCACHEPREFIX') appears in the manifest that
     declares the row. Measured at the pinned sha d297cc59: five hits in
     cut-manifests/v1.0.46.yaml alone, plus cut-deferrals.yaml,
     cuts/DEFECTS_ROLLFORWARD.md and cuts/v1.0.46/cut.env. `must_match: true`
     was therefore satisfied by documentation, with the fix entirely absent.
  3. `this-repo` resolved through --git-common-dir to the PRIMARY clone, which
     is on whatever branch a developer left it on — not the ref being cut.

Each test below fails on the pre-fix behaviour and passes on the fixed one.
Run: python3 -m unittest tests.test_grep_row_cannot_be_satisfied_by_its_own_manifest
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import verify_cut_manifest as vcm  # noqa: E402


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   capture_output=True)


def _make_repo(tmp: Path) -> Path:
    """A miniature CM051: one real source file, one manifest describing it."""
    repo = tmp / "repo"
    (repo / "gui" / "scripts").mkdir(parents=True)
    (repo / "cut-manifests").mkdir(parents=True)
    _git_init(repo)
    return repo


def _git_init(repo: Path) -> None:
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.invalid")
    _git(repo, "config", "user.name", "Test")


def _commit_all(repo: Path, msg: str) -> None:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", msg)


SENTINEL = "PYTHONPYCACHEPREFIX"


class SelfSatisfyingRowTest(unittest.TestCase):
    """The v1.0.46 defect, reproduced exactly, then held shut."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.dir if False else self._tmp.name)
        self.repo = _make_repo(self.tmp)
        # The manifest MENTIONS the sentinel (as the real one does, in the
        # pattern field and in the prose). The source file does NOT carry it —
        # i.e. the fix is absent, which is what v1.0.46 actually shipped.
        (self.repo / "cut-manifests" / "v1.0.46.yaml").write_text(
            "version: v1.0.46\n"
            "entries:\n"
            "  - id: c-the-bricking-fix-is-in-the-pinned-source\n"
            "    proof:\n"
            "      kind: grep_in_source_at_sha\n"
            f"      pattern: '{SENTINEL}'\n"
            f"    incident: the fix sets {SENTINEL} before compileall runs\n"
        )
        (self.repo / "gui" / "scripts" / "sign-python-bundle.sh").write_text(
            "#!/bin/sh\n# no fix here\ncompileall\n"
        )
        _commit_all(self.repo, "manifest mentions the sentinel; source does not")
        self.ctx = {"cm051_dir": self.repo}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, proof: dict) -> vcm.Result:
        return vcm.check_grep_in_source_at_sha(
            {"id": "row", "title": "t", "proof": proof}, self.ctx)

    def test_whole_tree_row_is_not_satisfied_by_its_own_manifest(self) -> None:
        """THE v1.0.46 DEFECT. Pre-fix this returned PASS from the manifest alone."""
        r = self._run({"kind": "grep_in_source_at_sha",
                       "pattern": SENTINEL, "must_match": True})
        self.assertEqual(
            r.status, "FAIL",
            "a row whose only matches are in cut-manifests/ must NOT pass — "
            f"that is documentation, not code. detail={r.detail}")
        self.assertIn("DISCARDED", r.detail,
                      "the verdict must SAY it threw matches away, not do it silently")

    def test_real_code_hit_still_passes(self) -> None:
        """Control: the predicate is not simply broken-to-red."""
        (self.repo / "gui" / "scripts" / "sign-python-bundle.sh").write_text(
            f"#!/bin/sh\nexport {SENTINEL}=/tmp/x\ncompileall\n")
        _commit_all(self.repo, "the fix actually lands in code")
        r = self._run({"kind": "grep_in_source_at_sha",
                       "pattern": SENTINEL, "must_match": True})
        self.assertEqual(r.status, "PASS",
                         f"a genuine code hit must pass. detail={r.detail}")

    def test_path_hint_is_honoured_not_silently_dropped(self) -> None:
        """path_hint must target the file, not widen to the whole tree."""
        r = self._run({"kind": "grep_in_source_at_sha", "pattern": SENTINEL,
                       "must_match": True,
                       "path_hint": "gui/scripts/sign-python-bundle.sh"})
        self.assertEqual(
            r.status, "FAIL",
            "path_hint names a file that does NOT carry the sentinel, so the "
            f"row must fail. Pre-fix it was ignored and the tree matched. detail={r.detail}")
        self.assertIn("path=gui/scripts/sign-python-bundle.sh", r.detail,
                      "the verdict must name the scope it actually examined")

    def test_unknown_proof_key_is_refused_loudly(self) -> None:
        """A typo must not silently become a wider check."""
        r = self._run({"kind": "grep_in_source_at_sha", "pattern": SENTINEL,
                       "must_match": True, "path_hnit": "gui/scripts/x.sh"})
        self.assertEqual(r.status, "FAIL")
        self.assertIn("unknown proof key", r.detail)


class RepoResolutionTest(unittest.TestCase):
    """`this-repo` must be the checkout under verification, not the primary clone."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_worktree_resolves_to_itself_not_the_primary_checkout(self) -> None:
        primary = self.tmp / "primary"
        (primary / "gui").mkdir(parents=True)
        _git_init(primary)
        (primary / "gui" / "f.sh").write_text("old\n")
        _commit_all(primary, "base")
        _git(primary, "branch", "stale-branch")
        # Primary sits on a branch WITHOUT the fix, exactly as the real clone did.
        _git(primary, "checkout", "-q", "stale-branch")

        wt = self.tmp / "wt"
        _git(primary, "worktree", "add", "-q", "-b", "cut-ref", str(wt))
        (wt / "gui" / "f.sh").write_text("THE_FIX_IS_HERE\n")
        _commit_all(wt, "the fix, on the ref being cut")

        resolved = vcm.resolve_source_repo("this-repo", wt)
        self.assertEqual(
            Path(resolved).resolve(), wt.resolve(),
            "a worktree is the ref under test; resolving to the primary clone "
            "reads whatever branch a developer left it on")

        r = vcm.check_grep_in_source_at_sha(
            {"id": "row", "title": "t",
             "proof": {"kind": "grep_in_source_at_sha",
                       "pattern": "THE_FIX_IS_HERE", "must_match": True,
                       "path": "gui/f.sh"}},
            {"cm051_dir": wt})
        self.assertEqual(r.status, "PASS",
                         f"the fix is on the ref under test. detail={r.detail}")


if __name__ == "__main__":
    unittest.main()
