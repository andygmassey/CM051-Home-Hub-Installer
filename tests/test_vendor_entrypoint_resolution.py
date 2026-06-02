#!/usr/bin/env python3
"""Vendored-package console-script entrypoint-resolution guard.

The CX-83 / phantom-CLI class of bug: a vendored package declares a
console script in ``[project.scripts]`` (e.g.
``pwg-email-ingest = "src.cli:main"``) whose target module or attribute
does not actually exist. ``pip install`` happily writes a launcher
binary regardless; the failure surfaces only when a LaunchAgent or the
customer first invokes the CLI and it explodes with ``ImportError`` /
``exit 127``. Unit tests that never invoke the binary stay green; the
installer ships a dead CLI.

CM051's install.sh symlinks several such console scripts into
``/usr/local/bin`` (ostler-knowledge, ostler-recovery, pwg-email-ingest,
pwg-convo, ...) so the customer can invoke them without activating a
venv. If the declared ``module:attr`` is wrong, that symlink points at a
binary that dies on first run.

This guard statically resolves every ``[project.scripts]`` entry in each
vendored package's ``pyproject.toml`` to a real ``module:attr`` target:

  * the MODULE part (e.g. ``src.cli``) must resolve to a file on disk
    inside the package, honouring the package's declared layout
    (``tool.setuptools.packages.find`` with ``where``/``include``, or
    ``tool.setuptools.package-dir`` flat-package mapping); and
  * the ATTR part (e.g. ``cli`` / ``main``) must be defined at module
    top level (a ``def``, ``class`` or assignment) in that file.

It is the entrypoint-axis companion to test_vendor_import_resolution.py
(which checks intra-package imports). Network-free, dependency-free
(stdlib ast + tomllib). Exit 1 on any unresolved entrypoint.

Sibling-module imports pulled in transitively by the entrypoint module
are out of this guard's scope; those are covered by the import guard.
"""
from __future__ import annotations

import ast
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDOR = REPO_ROOT / "vendor"


def _package_roots(pyproject: dict, pkg_dir: Path) -> dict[str, Path]:
    """Map each importable top-level package name to its on-disk root
    directory, honouring the package's declared setuptools layout.

    Returns e.g. {'src': <pkg_dir>} for a ``where=["."]`` /
    ``include=["src*"]`` layout, or {'ostler_security': <pkg_dir>} for a
    ``package-dir = {"ostler_security": "."}`` flat layout. Falls back to
    treating every immediate child dir with an __init__.py as a package
    root (the setuptools auto-discovery default).
    """
    setuptools_cfg = pyproject.get("tool", {}).get("setuptools", {})
    roots: dict[str, Path] = {}

    # Explicit package-dir mapping (flat-package layout). e.g.
    # {"ostler_security": "."} means import name 'ostler_security'
    # resolves to files directly under pkg_dir/.
    package_dir = setuptools_cfg.get("package-dir")
    if isinstance(package_dir, dict):
        for import_name, rel in package_dir.items():
            base = pkg_dir if rel in (".", "") else pkg_dir / rel
            roots[import_name] = base.parent if rel in (".", "") else base
            # For {"pkg": "."} the module 'pkg.x' lives at pkg_dir/x.py,
            # so the *parent* of 'pkg' is pkg_dir.
            roots[import_name] = pkg_dir.parent if rel in (".", "") else (pkg_dir / rel).parent

    # find-based layout: where=[...] gives search dirs; the package
    # names found under them (matching include globs) are import roots.
    find_cfg = setuptools_cfg.get("packages", {})
    if isinstance(find_cfg, dict) and "find" in find_cfg:
        where = find_cfg["find"].get("where", ["."])
        for w in where:
            search = pkg_dir if w in (".", "") else pkg_dir / w
            if search.is_dir():
                for child in search.iterdir():
                    if (child / "__init__.py").is_file():
                        # 'src.cli' resolves under <search>/src/cli.py,
                        # so the import root for name 'src' is <search>.
                        roots[child.name] = search

    if not roots:
        # Auto-discovery fallback: immediate child packages of pkg_dir.
        for child in pkg_dir.iterdir():
            if child.is_dir() and (child / "__init__.py").is_file():
                roots[child.name] = pkg_dir

    return roots


def _module_file(import_root: Path, dotted: str) -> Path | None:
    """Resolve dotted module (e.g. 'src.cli') under import_root to a
    .py file or package __init__.py, or None if it does not exist."""
    parts = dotted.split(".")
    as_module = import_root.joinpath(*parts).with_suffix(".py")
    if as_module.is_file():
        return as_module
    as_package = import_root.joinpath(*parts, "__init__.py")
    if as_package.is_file():
        return as_package
    return None


def _module_defines(pyfile: Path, attr: str) -> bool:
    """True if attr is defined at top level of pyfile (def/class/assign
    /import). AST-only; does not execute the module."""
    try:
        tree = ast.parse(pyfile.read_text(encoding="utf-8"), filename=str(pyfile))
    except SyntaxError:
        return False
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name == attr:
                return True
        elif isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id == attr:
                    return True
        elif isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name) and node.target.id == attr:
                return True
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                bound = alias.asname or alias.name.split(".")[0]
                if bound == attr:
                    return True
    return False


def _check_package(pkg_dir: Path) -> list[str]:
    failures: list[str] = []
    pyproject_path = pkg_dir / "pyproject.toml"
    if not pyproject_path.is_file():
        return failures
    try:
        pyproject = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        return [f"{pyproject_path.relative_to(REPO_ROOT)}: invalid TOML: {exc}"]

    scripts = pyproject.get("project", {}).get("scripts", {})
    if not scripts:
        return failures

    roots = _package_roots(pyproject, pkg_dir)
    rel_proj = pyproject_path.relative_to(REPO_ROOT)

    for script_name, target in scripts.items():
        if ":" not in target:
            failures.append(
                f"{rel_proj}: script '{script_name} = {target}' is not in "
                f"'module:attr' form")
            continue
        module, attr = target.split(":", 1)
        attr = attr.strip().split(".")[0]  # 'pkg.mod:obj.method' -> 'obj'
        top = module.split(".")[0]
        import_root = roots.get(top)
        if import_root is None:
            # Unknown top-level package name for this layout. Try every
            # known root as a fallback before declaring it unresolved.
            resolved = None
            for root in roots.values():
                f = _module_file(root, module)
                if f is not None:
                    resolved = f
                    break
            if resolved is None:
                failures.append(
                    f"{rel_proj}: script '{script_name} = {target}' -> "
                    f"module '{module}' not resolvable under declared "
                    f"package roots {sorted(roots)}")
                continue
            module_file = resolved
        else:
            module_file = _module_file(import_root, module)
            if module_file is None:
                failures.append(
                    f"{rel_proj}: script '{script_name} = {target}' -> "
                    f"module '{module}' has no file on disk")
                continue

        if not _module_defines(module_file, attr):
            failures.append(
                f"{rel_proj}: script '{script_name} = {target}' -> attribute "
                f"'{attr}' not defined at top level of "
                f"{module_file.relative_to(REPO_ROOT)}")

    return failures


def main() -> int:
    if not VENDOR.is_dir():
        print("no vendor/ directory; nothing to check")
        return 0

    pkg_dirs = sorted(
        p.parent for p in VENDOR.rglob("pyproject.toml")
    )
    if not pkg_dirs:
        print("no vendored pyproject.toml under vendor/")
        return 0

    all_failures: list[str] = []
    checked_any_scripts = False
    for pkg_dir in pkg_dirs:
        fails = _check_package(pkg_dir)
        rel = pkg_dir.relative_to(REPO_ROOT)
        pyproject = tomllib.loads((pkg_dir / "pyproject.toml").read_text(encoding="utf-8"))
        scripts = pyproject.get("project", {}).get("scripts", {})
        if not scripts:
            continue
        checked_any_scripts = True
        if fails:
            all_failures.extend(fails)
        else:
            names = ", ".join(sorted(scripts))
            print(f"entrypoint check: {rel} -- {len(scripts)} script(s) resolve ({names})")

    if not checked_any_scripts:
        print("no vendored packages declare [project.scripts]")
        return 0

    if all_failures:
        print("\nFAIL: unresolved console-script entrypoints in vendored code:",
              file=sys.stderr)
        for f in all_failures:
            print(f"  {f}", file=sys.stderr)
        print("\nFix the [project.scripts] target or add the missing "
              "module/attribute. A wrong entrypoint ships a dead CLI "
              "(the CX-83 class of bug).", file=sys.stderr)
        return 1

    print("vendor entrypoint-resolution guard: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
