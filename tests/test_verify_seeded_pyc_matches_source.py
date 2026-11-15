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


# ---- 2026-11-04: candidate 41770746721 read 2233 of 2233 untouched .pyc as STALE.
# The runner's /usr/bin/python3 (3.9.6) recomputed hashes written by the bundled
# 3.11.15, and _imp.source_hash differs across CPython versions. The arms below
# pin the RED demo (exactly one mutated .py gives exactly one STALE), refuse to
# judge a .pyc another interpreter wrote, and prove --interpreter-in-root uses
# the interpreter inside the root or says CANNOT-RUN.
import importlib.util
import os
import stat


def run_out(root, *extra, env=None):
    return subprocess.run([sys.executable, str(GATE), str(root), *extra],
                          capture_output=True, text=True, env=env)


def test_red_demo_one_mutated_py_gives_exactly_one_stale():
    root, pkg = seeded_tree()
    (pkg / "b.py").write_text("def f():\n    return 3\n")
    p = run_out(root, "--require", "/ostler_fda/")
    assert p.returncode == 1, p.stdout
    assert "examined 2 hash-based .pyc with a source; 1 compiled from different bytes" in p.stdout, p.stdout
    stale = [l for l in p.stdout.splitlines() if l.strip().startswith("STALE:")]
    assert stale == ["  STALE: App/ostler_fda/b.py"], stale


def _foreign_magic():
    m = bytearray(importlib.util.MAGIC_NUMBER)
    m[0] = (m[0] - 1) % 256  # a different CPython bytecode version, same \r\n tail
    return bytes(m)


def test_a_pyc_from_another_interpreter_is_cannot_run_never_stale():
    root, pkg = seeded_tree()
    pyc = pkg / "__pycache__" / "a.cpython-311.pyc"
    data = pyc.read_bytes()
    pyc.write_bytes(_foreign_magic() + data[4:])
    p = run_out(root, "--require", "/ostler_fda/")
    assert p.returncode == 2, p.stdout
    assert "STALE" not in p.stdout, p.stdout
    assert "written by another interpreter" in p.stdout, p.stdout


def test_interpreter_in_root_missing_is_cannot_run():
    root, _ = seeded_tree()
    p = run_out(root, "--require", "/ostler_fda/", "--interpreter-in-root")
    assert p.returncode == 2, p.stdout
    assert "found 0 executable python3.11" in p.stdout, p.stdout


def _bundle_interpreter(root):
    """An executable named python3.11 inside the root that records it ran, then
    runs the current interpreter (whose magic the seeded .pyc carry)."""
    bindir = root / "App" / "python" / "bin"
    bindir.mkdir(parents=True)
    marker = root / "bundled-ran"
    exe = bindir / "python3.11"
    exe.write_text(f'#!/bin/sh\n: > "{marker}"\nexec "{sys.executable}" "$@"\n')
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return marker


def test_interpreter_in_root_reexecs_the_bundled_interpreter():
    root, _ = seeded_tree()
    marker = _bundle_interpreter(root)
    env = {k: v for k, v in os.environ.items() if k != "OSTLER_ARM9_REEXECED"}
    p = run_out(root, "--require", "/ostler_fda/", "--interpreter-in-root", env=env)
    assert p.returncode == 0, p.stdout + p.stderr
    assert marker.exists(), "the bundled interpreter was never run"
    assert "recomputing with App/python/bin/python3.11" in p.stdout, p.stdout


def test_interpreter_in_root_still_catches_one_mutated_py():
    root, pkg = seeded_tree()
    _bundle_interpreter(root)
    (pkg / "a.py").write_text("X = 9\n")
    env = {k: v for k, v in os.environ.items() if k != "OSTLER_ARM9_REEXECED"}
    p = run_out(root, "--require", "/ostler_fda/", "--interpreter-in-root", env=env)
    assert p.returncode == 1, p.stdout
    assert [l for l in p.stdout.splitlines() if "STALE:" in l] == ["  STALE: App/ostler_fda/a.py"], p.stdout
