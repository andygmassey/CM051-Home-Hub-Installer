#!/usr/bin/env python3
"""Vendored-package SYMBOL-resolution guard (v1018-D024).

WHY THIS EXISTS, AND WHY IT IS A SEPARATE FILE

``test_vendor_import_resolution.py`` resolves the MODULE path and says so in
its own docstring:

    It resolves the MODULE path (the part between ``from`` and ``import``),
    never the imported names, so ``from ostler_fda.pwg_ingest import
    ingest_browser_history`` checks that ``pwg_ingest`` exists, not the
    function symbol.

That limitation is exactly the D024 failure. On 2026-08-12 a three-file Doctor
graft went in and the third file's hunk did not apply: the vendored
``web_ui_copy.py`` had diverged and was shorter than upstream, so the patch had
no anchor and all 15 ``WHATSAPP_PAIR_*`` constants were missing. The MODULE
``web_ui_copy`` still existed, so the module-level guard was green, while
``web_ui.py`` imported 15 names that were not there. That ships a panel which
ImportErrors the first time a customer opens its own route.

Two of three files applying is not two thirds of a graft. It is a broken graft
with a green gate. It was caught by hand, by diffing referenced names against
defined names. This makes that check mechanical.

WHAT THIS ADDS OVER THE MODULE-LEVEL GUARD

1. SYMBOLS. For every intra-package ``from <mod> import a, b``, the target
   module is parsed and each name must actually be bound there.

2. BARE SIBLING IMPORTS. The module-level guard skips ``from web_ui_copy
   import x`` because a bare name is not statically distinguishable from a
   third-party import "without an external-dependency allowlist". True in
   general -- but NOT when a sibling file of that exact name sits next to the
   importer. ``vendor/doctor/agent/web_ui_copy.py`` next to
   ``vendor/doctor/agent/web_ui.py`` is unambiguous, and that is precisely the
   import shape the Doctor payload uses. Resolving only that case needs no
   allowlist and cannot collide with a third-party package, because a stdlib or
   pip module does not have a file sitting in the vendored directory.

WHAT IS DELIBERATELY NOT FLAGGED

A name is treated as bound if it is assigned, def'd, class'd, imported or
re-exported ANYWHERE at module scope, including inside ``if`` / ``try`` blocks,
because conditional definition is legitimate and a stricter rule would produce
false positives that get the guard switched off. ``import *`` in the target
makes its namespace unknowable statically, so such a target is skipped rather
than guessed at. Both exclusions are stated here rather than left silent.

Network-free, dependency-free (stdlib ast only).

Usage:
    test_vendor_symbol_resolution.py [--root <dir>]
``--root`` points the scan at an alternative tree, which is how the demonstrated
RED runs against a scratch copy without ever touching vendor/doctor.
"""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _module_file(base: Path, dotted: str) -> Path | None:
    """Resolve a dotted module path under base to a .py file, if any."""
    if not dotted:
        return None
    parts = dotted.split(".")
    as_module = base.joinpath(*parts).with_suffix(".py")
    if as_module.is_file():
        return as_module
    as_package = base.joinpath(*parts, "__init__.py")
    if as_package.is_file():
        return as_package
    return None


def _bound_names(path: Path) -> tuple[str, object]:
    """Every name bound at module scope in `path`.

    Returns ("ok", set) / ("star", None) / ("error", message).

    The three-way return exists because the first version of this returned a
    bare None for BOTH "star-import, unknowable" and "does not parse", and the
    caller skipped on None. That made the guard silently skip a provider that
    fails to parse -- which is precisely what a half-applied hunk leaves
    behind, and it is the exact case this guard was written to catch. Caught
    by running the demonstrated RED and getting rc=0: the mutation broke the
    file's syntax, the guard swallowed it, and reported success. A skip that
    reports nothing is indistinguishable from a pass.
    """
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        return ("error", f"does not parse ({exc.msg} at line {exc.lineno})")
    except OSError as exc:
        return ("error", f"unreadable ({exc})")

    names: set[str] = set()
    star = False

    def _collect_target(t: ast.AST) -> None:
        if isinstance(t, ast.Name):
            names.add(t.id)
        elif isinstance(t, (ast.Tuple, ast.List)):
            for e in t.elts:
                _collect_target(e)

    # Walk the whole tree: a definition inside `if` / `try` at module scope is
    # legitimate, and nested function bodies cannot shadow a module-level name
    # in a way that matters for an importer.
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                _collect_target(t)
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            _collect_target(node.target)
        elif isinstance(node, ast.ImportFrom):
            if any(a.name == "*" for a in node.names):
                star = True
            for a in node.names:
                names.add(a.asname or a.name)
        elif isinstance(node, ast.Import):
            for a in node.names:
                names.add(a.asname or a.name.split(".")[0])

    return ("star", None) if star else ("ok", names)


def _check_package(pkg_name: str, pkg_dir: Path, root: Path) -> list[str]:
    failures: list[str] = []
    for pyfile in sorted(pkg_dir.rglob("*.py")):
        try:
            tree = ast.parse(pyfile.read_text(encoding="utf-8"),
                             filename=str(pyfile))
        except (SyntaxError, OSError):
            continue  # the module-level guard already reports syntax errors
        try:
            rel = pyfile.relative_to(root)
        except ValueError:
            rel = pyfile

        for node in ast.walk(tree):
            if not isinstance(node, ast.ImportFrom):
                continue
            if any(a.name == "*" for a in node.names):
                continue

            target: Path | None = None
            shown = ""
            if node.level and node.level >= 1:
                base = pyfile.parent
                for _ in range(node.level - 1):
                    base = base.parent
                if node.module:
                    target = _module_file(base, node.module)
                    shown = "." * node.level + node.module
            elif node.module:
                if node.module == pkg_name or node.module.startswith(pkg_name + "."):
                    sub = node.module[len(pkg_name):].lstrip(".")
                    target = _module_file(pkg_dir, sub) if sub else None
                    shown = node.module
                else:
                    # BARE SIBLING: only resolved when a file of that exact
                    # name sits beside the importer. See the module docstring
                    # for why this needs no third-party allowlist.
                    sibling = pyfile.parent / (node.module.split(".")[0] + ".py")
                    if sibling.is_file() and "." not in node.module:
                        target = sibling
                        shown = node.module

            if target is None or not target.is_file():
                continue  # module existence is the other guard's job

            status, payload = _bound_names(target)
            try:
                tgt_rel = target.relative_to(root)
            except ValueError:
                tgt_rel = target
            if status == "error":
                failures.append(
                    f"{rel}: 'from {shown} import ...' -> provider {tgt_rel} "
                    f"{payload}. A provider that will not parse cannot define "
                    f"anything it is imported for, and a half-applied hunk is "
                    f"a common way to produce one."
                )
                continue
            if status == "star":
                continue  # namespace unknowable, stated in the docstring
            bound = payload

            # `from <package> import <submodule>` is legal Python even when
            # __init__.py never imports it, so a package target must also
            # accept its own submodules as bound names.
            #
            # Found by running this guard against the real tree before
            # trusting it: it reported 6 "missing" names in
            # cm052/adapters that are all files on disk
            # (chatgpt_export.py, zeroclaw_sessions.py, ...). That was the
            # guard being wrong, not the tree. A guard shipped with known
            # false positives gets switched off, and then it protects
            # nothing at all.
            if target.name == "__init__.py":
                pkg_root = target.parent
                bound = set(bound) | {
                    p.stem for p in pkg_root.glob("*.py") if p.name != "__init__.py"
                } | {
                    d.name for d in pkg_root.iterdir()
                    if d.is_dir() and (d / "__init__.py").is_file()
                }

            missing = [a.name for a in node.names if a.name not in bound]
            if missing:
                failures.append(
                    f"{rel}: 'from {shown} import ...' -> {tgt_rel} does not "
                    f"define: {', '.join(sorted(missing))}"
                )
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(REPO_ROOT),
                    help="tree to scan (default: repo root). Used to run the "
                         "demonstrated RED against a scratch copy.")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    vendor = root / "vendor"

    if not vendor.is_dir():
        print(f"no vendor/ under {root}; nothing to check")
        return 0

    packages: list[Path] = []
    for init in vendor.rglob("__init__.py"):
        pkg_dir = init.parent
        if not (pkg_dir.parent / "__init__.py").is_file():
            packages.append(pkg_dir)

    # A guard whose denominator is zero passes by finding nothing. Say the
    # number out loud every run so a collapsed scan is visible rather than
    # silently green.
    scanned = 0
    all_failures: list[str] = []
    for pkg_dir in sorted(packages):
        scanned += 1
        all_failures.extend(_check_package(pkg_dir.name, pkg_dir, root))

    print(f"symbol-resolution check: {scanned} vendored package root(s) scanned")
    if scanned == 0:
        print("FAIL: scanned zero packages -- the denominator is broken, so a "
              "green result here would mean nothing", file=sys.stderr)
        return 1

    if all_failures:
        print("\nSYMBOL RESOLUTION FAILURES "
              "(a consumer imports a name its provider does not define --\n"
              "this is the partial-graft shape: the module applied, the "
              "symbols did not):\n", file=sys.stderr)
        for f in all_failures:
            print(f"  {f}", file=sys.stderr)
        print(f"\n{len(all_failures)} unresolved symbol import(s)", file=sys.stderr)
        return 1

    print("all intra-package imported symbols resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
