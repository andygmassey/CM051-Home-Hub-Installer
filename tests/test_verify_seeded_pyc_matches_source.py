"""verify_seeded_pyc_matches_source.py: a .py edited after seeding is caught.

Synthetic package, compiled the way the DMG is (unchecked-hash). Arms: a clean
tree passes; ONE byte edited in a .py fails; an empty tree and a missing
--require fragment are CANNOT-RUN (2), never a pass.
"""
from __future__ import annotations

import py_compile
import subprocess
import sys
import tempfile
from pathlib import Path

GATE = Path(__file__).resolve().parent.parent / "scripts" / "verify_seeded_pyc_matches_source.py"


def run(root, *extra):
    return subprocess.run([sys.executable, str(GATE), str(root), *extra],
                           capture_output=True, text=True).returncode


def seeded_tree():
    root = Path(tempfile.mkdtemp(prefix="pyc-gate-"))
    pkg = root / "App" / "ostler_fda"
    pkg.mkdir(parents=True)
    for name, body in (("a.py", "X = 1\n"), ("b.py", "def f():\n    return 2\n")):
        (pkg / name).write_text(body)
        py_compile.compile(str(pkg / name), cfile=str(pkg / "__pycache__" / (name[:-3] + ".cpython-311.pyc")),
                           invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH, doraise=True)
    return root, pkg


def test_a_clean_seeded_tree_passes():
    root, _ = seeded_tree()
    assert run(root, "--require", "/ostler_fda/") == 0


def test_one_byte_edited_after_seeding_fails():
    root, pkg = seeded_tree()
    (pkg / "a.py").write_text("X = 2\n")
    assert run(root, "--require", "/ostler_fda/") == 1


def test_nothing_to_examine_is_cannot_run():
    assert run(Path(tempfile.mkdtemp())) == 2


def test_a_required_tree_with_no_pyc_is_cannot_run():
    root, _ = seeded_tree()
    assert run(root, "--require", "/not_there/") == 2
