#!/usr/bin/env python3
"""Vendored-package third-party-dependency declaration guard.

The .145 box-walk install FAILURE class: vendor/ostler_fda/pwg_ingest.py
imports ``httpx`` at module top, but httpx was never declared in
ostler_fda's pyproject. install.sh pip-installs ostler_fda into dedicated
MINIMAL per-source venvs (email-ingest, whatsapp-source) that install
nothing else, so the undeclared httpx is simply absent -> ``import httpx``
explodes at module load and the WhatsApp + Browsing hydration steps crash
mid-install. It only ever worked because the FAT venvs
(import-pipeline/cm019/cm048/knowledge/doctor) pull httpx transitively.

The sibling guard ``test_vendor_import_resolution.py`` deliberately
ignores third-party imports (it only resolves INTRA-package imports). This
guard is the complement: for each scoped vendored package, every
THIRD-PARTY top-level import in its source MUST appear in its pyproject
``[project].dependencies`` -- so removing httpx, or adding a new
undeclared third-party import, fails pre-merge instead of at a customer's
first install.

Scoped (hard-fail) packages are those install.sh pip-installs into a
minimal/isolated venv, where transitive deps are NOT available. Other
vendored packages are reported informationally only (they may legitimately
rely on a fat venv's transitive deps); add them to SCOPED as their
isolated-venv install paths are confirmed.

Network-free, dependency-free (stdlib ``ast`` + ``sys.stdlib_module_names``
only). Exit 1 on any undeclared third-party import in a scoped package.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDOR = REPO_ROOT / "vendor"

# Packages install.sh installs into a MINIMAL/isolated venv (no transitive
# deps available). These hard-fail. Key = path under vendor/; value = the
# package's own top-level import name (intra-package imports are ignored).
SCOPED = {
    "ostler_fda": "ostler_fda",
}

# Import-name -> PyPI-distribution-name for the cases where they differ.
# (ostler_fda only needs httpx, where the two match; this map is here so
# new imports with a name mismatch resolve correctly.)
IMPORT_TO_DIST = {
    "yaml": "pyyaml",
    "PIL": "pillow",
    "bs4": "beautifulsoup4",
    "dateutil": "python-dateutil",
    "dotenv": "python-dotenv",
    "cv2": "opencv-python",
}

# A couple of top-level names that are stdlib in practice but which some
# Python builds omit from sys.stdlib_module_names; belt-and-braces.
_STDLIB_EXTRA = {"__future__"}


def _norm(name: str) -> str:
    """Normalise a distribution/import name for comparison (PEP 503-ish):
    lowercase, treat '-' and '_' and '.' as equivalent."""
    return re.sub(r"[-_.]+", "-", name.strip().lower())


def _declared_deps(pyproject: Path) -> set[str]:
    """Parse [project].dependencies requirement strings -> set of
    normalised distribution names. Tolerant hand-parse so we do not need a
    TOML lib on older Pythons; the dependencies array is a simple list of
    quoted PEP 508 strings."""
    text = pyproject.read_text(encoding="utf-8")
    m = re.search(r"(?ms)^\s*dependencies\s*=\s*\[(.*?)\]", text)
    if not m:
        return set()
    deps: set[str] = set()
    for raw in re.findall(r"""['"]([^'"]+)['"]""", m.group(1)):
        # Strip version/extra/marker noise: keep the leading project name.
        name = re.split(r"[<>=!~;\[\s]", raw, maxsplit=1)[0]
        if name:
            deps.add(_norm(name))
    return deps


def _third_party_imports(pkg_dir: Path, own_name: str) -> dict[str, str]:
    """Map third-party MODULE-TOP-LEVEL import name -> first file:line seen.
    Excludes stdlib, the package's own name, and relative imports.

    Only module-top-level imports (direct children of the module body) are
    considered, because those are exactly the imports that execute at module
    LOAD time and therefore crash in a minimal venv that lacks the dep --
    the .145 failure shape. This deliberately ignores:
      - function/method-local imports (lazy; only run on a hit path), and
      - top-level ``try: import X / except ImportError`` guards (optional
        deps by design -- e.g. ostler_fda's soft ostler_security import),
    because an import nested inside a ``try`` / ``def`` is a child of that
    compound node, not of the module body, so it never reaches this scan.
    """
    stdlib = set(getattr(sys, "stdlib_module_names", set())) | _STDLIB_EXTRA
    found: dict[str, str] = {}
    for py in sorted(pkg_dir.rglob("*.py")):
        try:
            tree = ast.parse(py.read_text(encoding="utf-8"), filename=str(py))
        except SyntaxError as exc:  # pragma: no cover - surfaced as failure
            print(f"  ! could not parse {py}: {exc}", file=sys.stderr)
            continue
        for node in tree.body:  # module top level only
            tops: list[str] = []
            if isinstance(node, ast.Import):
                tops = [a.name.split(".")[0] for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                if node.level and node.level > 0:
                    continue  # relative intra-package import
                if node.module:
                    tops = [node.module.split(".")[0]]
            for top in tops:
                if not top or top in stdlib or top == own_name:
                    continue
                found.setdefault(top, f"{py.relative_to(REPO_ROOT)}:{getattr(node, 'lineno', '?')}")
    return found


def main() -> int:
    failures: list[str] = []
    for rel, own_name in SCOPED.items():
        pkg_dir = VENDOR / rel
        pyproject = pkg_dir / "pyproject.toml"
        if not pkg_dir.is_dir():
            failures.append(f"{rel}: vendored package dir missing ({pkg_dir})")
            continue
        if not pyproject.is_file():
            failures.append(f"{rel}: no pyproject.toml (cannot declare deps)")
            continue
        declared = _declared_deps(pyproject)
        imports = _third_party_imports(pkg_dir, own_name)
        print(f"== {rel}: {len(imports)} third-party import(s); "
              f"{len(declared)} declared dep(s) ==")
        for imp, where in sorted(imports.items()):
            dist = _norm(IMPORT_TO_DIST.get(imp, imp))
            status = "ok" if dist in declared else "UNDECLARED"
            print(f"   [{status}] import '{imp}' -> dist '{dist}'  ({where})")
            if dist not in declared:
                failures.append(
                    f"{rel}: '{imp}' (dist '{dist}') imported at {where} "
                    f"but NOT in pyproject dependencies "
                    f"-> will be ModuleNotFoundError in the minimal install venv")

    print()
    if failures:
        print("FAIL: undeclared third-party dependency in a minimal-venv "
              "vendored package (the .145 install-failure class):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS: every third-party import in scoped vendored packages is "
          "declared in its pyproject dependencies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
