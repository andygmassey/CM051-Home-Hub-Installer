#!/usr/bin/env python3
"""#657 item 3: contact_syncer -> identity_resolver vendor-integrity guard.

contact_syncer's GDPR people importers (facebook_friends, dedup, ...) reach
identity_resolver via a CROSS-package import resolved by a sys.path hack
("add the parent dir so identity_resolver is importable"). install.sh stages
the two as SIBLINGS in PIPELINE_DIR (~/.ostler/import-pipeline/): it cp's
contact_syncer there (install.sh ~L7016) and, separately and conditionally,
identity_resolver next to it (~L7025). The DMG Makefile stages both into the
.app Resources root (gui/Makefile ~L735 required-Resources loop).

The existing static guard (tests/test_vendor_import_resolution.py) DELIBERATELY
cannot see this: its docstring's "Known limitation" excludes cross-package
imports resolved via sys.path injection. So if a future re-vendor moves or
drops identity_resolver, contact_syncer would `ImportError` only at customer
runtime -- and the GDPR people path (LinkedIn connections + FB friends ->
pwg:Person) would go dark with NO parse error, exactly the failure mode the
#657 brief item 3 calls out.

This guard mirrors the install staging into a temp dir and asserts every
`from identity_resolver.X import ...` that contact_syncer actually uses
RESOLVES on that staged layout. It resolves MODULE specs (importlib
find_spec), never executes them, so it needs none of identity_resolver's
third-party runtime deps (phonenumbers, qdrant_client, ...). A RED control
removes identity_resolver from the staged layout and asserts the guard then
fails -- proving it detects the unstaged class.

Synthetic / structural only: stages real vendored *source* into a temp dir,
reads no archive data, writes nothing outside the temp dir. Pure stdlib.
"""

from __future__ import annotations

import ast
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONTACT_SYNCER_SRC = REPO / "contact_syncer"
IDENTITY_RESOLVER_SRC = REPO / "vendor" / "cm041" / "identity_resolver"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def cross_package_modules(pkg_dir: Path, other_pkg: str) -> set[str]:
    """Every `other_pkg.X` module referenced by `from other_pkg.X import ...`
    or `import other_pkg.X` across pkg_dir/*.py. Returns dotted module paths."""
    found: set[str] = set()
    for py in sorted(pkg_dir.glob("*.py")):
        tree = ast.parse(py.read_text(encoding="utf-8"), filename=str(py))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                if node.module and (
                    node.module == other_pkg
                    or node.module.startswith(other_pkg + ".")
                ):
                    found.add(node.module)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name == other_pkg or alias.name.startswith(
                        other_pkg + "."
                    ):
                        found.add(alias.name)
    return found


def modules_resolve(modules: set[str], search_root: Path) -> list[str]:
    """Return the subset of `modules` whose source file is NOT staged under
    `search_root`. This is a pure filesystem resolution of the dotted module
    path -- `identity_resolver.models` -> `identity_resolver/models.py` (or
    `identity_resolver/models/__init__.py`) -- so it tests STAGING INTEGRITY
    (is the vendored file where contact_syncer's sys.path hack would find it)
    without importing/executing any package `__init__` or its third-party
    runtime deps. That is exactly the right semantics for a vendor-integrity
    guard: the customer-runtime ImportError we are guarding against is "the
    file was not staged", not "a dependency is missing"."""
    unresolved: list[str] = []
    for mod in sorted(modules):
        parts = mod.split(".")
        as_module = search_root.joinpath(*parts).with_suffix(".py")
        as_package = search_root.joinpath(*parts) / "__init__.py"
        if not as_module.is_file() and not as_package.is_file():
            unresolved.append(mod)
    return unresolved


def stage(tmp: Path, *, include_identity_resolver: bool) -> Path:
    """Mirror install.sh PIPELINE_DIR: contact_syncer + identity_resolver as
    siblings. The RED control omits identity_resolver."""
    pipeline = tmp / "import-pipeline"
    pipeline.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        CONTACT_SYNCER_SRC,
        pipeline / "contact_syncer",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
    if include_identity_resolver:
        shutil.copytree(
            IDENTITY_RESOLVER_SRC,
            pipeline / "identity_resolver",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
    return pipeline


def main() -> None:
    if not CONTACT_SYNCER_SRC.is_dir():
        fail(f"contact_syncer source not found at {CONTACT_SYNCER_SRC}")
    if not IDENTITY_RESOLVER_SRC.is_dir():
        fail(f"identity_resolver source not found at {IDENTITY_RESOLVER_SRC}")
    if not (IDENTITY_RESOLVER_SRC / "__init__.py").is_file():
        fail("identity_resolver is not a package (no __init__.py)")

    needed = cross_package_modules(CONTACT_SYNCER_SRC, "identity_resolver")
    if not needed:
        fail(
            "no `identity_resolver.*` imports found in contact_syncer -- the "
            "cross-package coupling this guard protects has vanished; either "
            "the wiring changed (update this test) or contact_syncer was gutted"
        )
    print(f"PASS: contact_syncer references {len(needed)} identity_resolver "
          f"module(s): {', '.join(sorted(needed))}")

    # GREEN: staged like the installer, every cross-package module resolves.
    with tempfile.TemporaryDirectory() as td:
        pipeline = stage(Path(td), include_identity_resolver=True)
        unresolved = modules_resolve(needed, pipeline)
        if unresolved:
            fail(
                "with identity_resolver staged as a sibling (the real install "
                f"layout) these modules still do NOT resolve: {unresolved}. "
                "contact_syncer would ImportError at customer runtime and the "
                "GDPR people path would go dark with no parse error."
            )
        print("PASS: every identity_resolver.* module resolves on the staged "
              "PIPELINE_DIR layout (contact_syncer + identity_resolver siblings)")

    # RED control: drop identity_resolver; the same modules must now fail to
    # resolve, proving the guard detects the unstaged/moved class.
    with tempfile.TemporaryDirectory() as td:
        pipeline = stage(Path(td), include_identity_resolver=False)
        unresolved = modules_resolve(needed, pipeline)
        if not unresolved:
            fail(
                "RED control: identity_resolver was NOT staged yet its modules "
                "still resolved -- the guard cannot detect a missing "
                "identity_resolver (it may be leaking from the real sys.path)"
            )
        print("PASS: red-control -- without identity_resolver staged, the "
              f"cross-package imports fail to resolve ({len(unresolved)} module(s))")

    print("\nALL CONTACT_SYNCER -> IDENTITY_RESOLVER VENDOR-INTEGRITY TESTS PASSED")


if __name__ == "__main__":
    main()
