#!/usr/bin/env python3
"""Doctor string-catalogue completeness guard.

The .154-walk blocker: ``vendor/doctor/agent/web_ui.py`` was re-vendored
to a newer revision that imports a batch of Config-panel string
constants (``CONFIG_BTN_SAVE`` and 15 siblings) ``from web_ui_copy``,
but ``web_ui_copy.py`` was left at an older revision that never defined
them. Doctor (:8089) then crash-loops at import time with::

    ImportError: cannot import name 'CONFIG_BTN_SAVE' from 'web_ui_copy'

and because the packaged Hub's People / Timeline tabs read Doctor on
:8089, those panes render "LOAD FAILED" on a clean install -- even
though every surface returns 200 and the data is present.

The sibling guard ``test_vendor_import_resolution.py`` deliberately
resolves the imported *module* path only, never the imported *names*
(see its docstring), so it cannot catch a stale string catalogue. This
guard closes that gap for the one place it bit us, statically and
dependency-free: every NAME ``web_ui.py`` imports ``from web_ui_copy``
MUST be defined at module level in ``web_ui_copy.py``. The two halves
ship as a matched pair; if a future re-vendor bumps one and not the
other, CI fails here instead of a customer's Mac.

Network-free, stdlib ``ast`` only. The check is symmetric-agnostic: it
asserts coverage of imports, not that every catalogue entry is used.
"""
from __future__ import annotations

import ast
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AGENT_DIR = REPO_ROOT / "vendor" / "doctor" / "agent"
WEB_UI = AGENT_DIR / "web_ui.py"
WEB_UI_COPY = AGENT_DIR / "web_ui_copy.py"


def _names_imported_from(module_file: Path, sibling_module: str) -> set[str]:
    """Names pulled in via ``from <sibling_module> import a, b, ...``."""
    names: set[str] = set()
    tree = ast.parse(module_file.read_text(encoding="utf-8"),
                     filename=str(module_file))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == sibling_module:
            for alias in node.names:
                if alias.name == "*":
                    # A star-import sidesteps name-level checking; flag it
                    # so the catalogue contract stays explicit.
                    names.add("*")
                else:
                    names.add(alias.name)
    return names


def _names_defined_in(module_file: Path) -> set[str]:
    """Module-level bindings: assignments, def, class, and ``import x``."""
    defined: set[str] = set()
    tree = ast.parse(module_file.read_text(encoding="utf-8"),
                     filename=str(module_file))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    defined.add(tgt.id)
                elif isinstance(tgt, (ast.Tuple, ast.List)):
                    for elt in tgt.elts:
                        if isinstance(elt, ast.Name):
                            defined.add(elt.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            defined.add(node.target.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            defined.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                defined.add(alias.asname or alias.name.split(".")[0])
    return defined


class DoctorWebUiStringsComplete(unittest.TestCase):
    def test_files_present(self):
        self.assertTrue(WEB_UI.is_file(),
                        f"vendored Doctor web_ui.py missing at {WEB_UI}")
        self.assertTrue(WEB_UI_COPY.is_file(),
                        f"vendored Doctor web_ui_copy.py missing at {WEB_UI_COPY}")

    def test_no_star_import(self):
        imported = _names_imported_from(WEB_UI, "web_ui_copy")
        self.assertNotIn(
            "*", imported,
            "web_ui.py uses 'from web_ui_copy import *' -- name-level "
            "completeness cannot be guaranteed; import names explicitly.")

    def test_every_imported_string_is_defined(self):
        imported = _names_imported_from(WEB_UI, "web_ui_copy")
        self.assertTrue(
            imported,
            "expected web_ui.py to import names from web_ui_copy; found none "
            "-- has the catalogue split changed? Update this guard.")
        defined = _names_defined_in(WEB_UI_COPY)
        missing = sorted(imported - defined)
        self.assertFalse(
            missing,
            "web_ui_copy.py is missing string constant(s) that web_ui.py "
            "imports -- Doctor (:8089) will crash-loop at import time and the "
            "Hub People/Timeline tabs will read LOAD FAILED. Re-vendor "
            "web_ui_copy.py from the SAME Doctor revision as web_ui.py.\n"
            f"Missing: {missing}")


if __name__ == "__main__":
    unittest.main()
