#!/usr/bin/env python3
"""Vendored-package import-resolution guard.

The missing-chat_token.py class of bug: a vendored module imports a
sibling module (``from doctor_agent.chat_token import issue_chat_token``)
that was never vendored, so the import explodes only at customer runtime
when that code path first runs. Unit tests that never hit the path stay
green; the installer ships broken.

This guard statically resolves every INTRA-PACKAGE import in each
vendored Python package and fails if the referenced module does not
exist on disk inside that package. It deliberately ignores third-party
and stdlib imports (httpx, json, ...) -- only ``from <pkg>.x`` /
``from .x`` / ``import <pkg>.x`` are checked, where ``<pkg>`` is the
vendored package's own top-level name.

It resolves the MODULE path (the part between ``from`` and ``import``),
never the imported names, so ``from ostler_fda.pwg_ingest import
ingest_browser_history`` checks that ``pwg_ingest`` exists, not the
function symbol.

Scope: every package root under vendor/ (a directory with __init__.py
whose parent has none), including nested ones such as
vendor/doctor/agent and vendor/cm041/contact_syncer.

Known limitation: a bare ``from chat_token import x`` resolved via a
runtime ``sys.path.insert`` hack (rather than ``from <pkg>.chat_token``)
is NOT statically distinguishable from a third-party import without an
external-dependency allowlist, so it is out of this guard's static
scope; that shape is covered by the per-package vendor import smoke
tests (the optional import-time checks in vendor/*/test_vendor_*.sh).

Network-free, dependency-free (stdlib ast only). Exit 1 on any
unresolved intra-package import.
"""
from __future__ import annotations

import ast
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDOR = REPO_ROOT / "vendor"


def _module_exists(base: Path, dotted: str) -> bool:
    """True if dotted (relative to base, e.g. 'a.b') resolves to a
    module file base/a/b.py or a package base/a/b/__init__.py."""
    if not dotted:
        return True  # 'from . import x' with no module part: base itself
    parts = dotted.split(".")
    as_module = base.joinpath(*parts).with_suffix(".py")
    as_package = base.joinpath(*parts, "__init__.py")
    return as_module.is_file() or as_package.is_file()


def _check_package(pkg_name: str, pkg_dir: Path) -> list[str]:
    failures: list[str] = []
    for pyfile in sorted(pkg_dir.rglob("*.py")):
        try:
            tree = ast.parse(pyfile.read_text(encoding="utf-8"),
                             filename=str(pyfile))
        except SyntaxError as exc:
            failures.append(f"{pyfile.relative_to(REPO_ROOT)}: syntax error: {exc}")
            continue
        rel = pyfile.relative_to(REPO_ROOT)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                if node.level and node.level >= 1:
                    # Relative import: climb (level-1) dirs from the file.
                    base = pyfile.parent
                    for _ in range(node.level - 1):
                        base = base.parent
                    if node.module:
                        if not _module_exists(base, node.module):
                            failures.append(
                                f"{rel}: 'from {'.' * node.level}{node.module} import ...'"
                                f" -> unresolved module")
                    else:
                        # from . import name1, name2  -> each is a submodule
                        for alias in node.names:
                            if not _module_exists(base, alias.name):
                                failures.append(
                                    f"{rel}: 'from {'.' * node.level} import {alias.name}'"
                                    f" -> unresolved submodule")
                elif node.module and (
                    node.module == pkg_name
                    or node.module.startswith(pkg_name + ".")
                ):
                    sub = node.module[len(pkg_name):].lstrip(".")
                    if not _module_exists(pkg_dir, sub):
                        failures.append(
                            f"{rel}: 'from {node.module} import ...' -> unresolved module")
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    name = alias.name
                    if name == pkg_name or name.startswith(pkg_name + "."):
                        sub = name[len(pkg_name):].lstrip(".")
                        if not _module_exists(pkg_dir, sub):
                            failures.append(
                                f"{rel}: 'import {name}' -> unresolved module")
    return failures


def main() -> int:
    if not VENDOR.is_dir():
        print("no vendor/ directory; nothing to check")
        return 0

    # A package root is a directory with __init__.py whose parent has
    # none (the top of an importable package chain). This finds nested
    # roots like vendor/doctor/agent and vendor/cm041/contact_syncer,
    # not just direct children of vendor/. Keyed by full path so that
    # duplicate basenames (three different vendor/.../src roots) do not
    # collide and silently drop coverage.
    packages: list[Path] = []
    for init in VENDOR.rglob("__init__.py"):
        pkg_dir = init.parent
        if not (pkg_dir.parent / "__init__.py").is_file():
            packages.append(pkg_dir)
    if not packages:
        print("no vendored Python packages under vendor/")
        return 0

    all_failures: list[str] = []
    for pkg_dir in sorted(packages):
        rel = pkg_dir.relative_to(REPO_ROOT)
        fails = _check_package(pkg_dir.name, pkg_dir)
        if fails:
            all_failures.extend(fails)
        else:
            print(f"import-resolution check: {rel} -- all intra-package imports resolve")

    # Baseline ratchet: pre-existing failures are frozen so the guard
    # lands green and only NEW regressions fail it. The list can only
    # shrink (a stale entry that no longer fails is itself an error).
    baseline_path = Path(__file__).resolve().parent / "vendor_import_resolution_baseline.txt"
    baseline: set[str] = set()
    if baseline_path.is_file():
        for line in baseline_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                baseline.add(line)

    failure_set = set(all_failures)
    new_failures = sorted(failure_set - baseline)
    stale_baseline = sorted(baseline - failure_set)

    if stale_baseline:
        print("\nFAIL: stale vendor-import baseline entries (no longer failing -- "
              "remove them so the baseline only shrinks):", file=sys.stderr)
        for f in stale_baseline:
            print(f"  {f}", file=sys.stderr)
        return 1

    if new_failures:
        print("\nFAIL: NEW unresolved intra-package imports in vendored code:",
              file=sys.stderr)
        for f in new_failures:
            print(f"  {f}", file=sys.stderr)
        print("\nVendor the missing module(s) or fix the import.", file=sys.stderr)
        return 1

    if baseline:
        print(f"note: {len(baseline)} pre-existing unresolved import(s) baselined "
              f"(tracked debt, see vendor_import_resolution_baseline.txt)")
    print("vendor import-resolution guard: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
